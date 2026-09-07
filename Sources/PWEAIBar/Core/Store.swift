import AppKit
import Combine
import SwiftUI

/// Assembles one snapshot from every source and decides how often to do it again.
///
/// The cadence is the whole point of this file. A menu-bar app runs all day, so every cost gets
/// multiplied by tens of thousands: the quota endpoint is cached and never polled faster than
/// its own limits allow, the transcripts are only re-read when their newest file actually
/// changed, and the loop slows to a crawl when nothing is running or nobody is at the keyboard.
@MainActor
final class Store: ObservableObject {

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var claudeRefreshing = false
    @Published private(set) var loggedIn = true
    @Published private(set) var blocker: ClaudeProvider.Blocker = .none

    var onSnapshot: ((Snapshot) -> Void)?

    private let claude: ClaudeProvider
    private let rules: RuleEngine
    private let readEvents: () async -> [AgentEvent]
    private let readLocal: () async -> Transcript.Result
    private let readCodex: () async -> ([QuotaWindow], String?)
    private let deliver: (RuleEngine.Alert, Bool) async -> Bool
    private let tracks: () -> (claude: Bool, codex: Bool)
    private let tracksExtra: (Provider) -> Bool
    private let readExtras: ([Provider]) async -> ExtraStore.Result
    private let observe: ([QuotaWindow]) async -> [QuotaWindow]
    private func tracks(extra p: Provider) -> Bool { tracksExtra(p) }
    private let eventInterval: TimeInterval
    private var eventTimer: Timer?
    private var eventsInFlight = false
    private var deliveries = Set<String>()
    private var retryDelivery: [String: Date] = [:]

    init(claude: ClaudeProvider = ClaudeProvider(), rules: RuleEngine? = nil,
         readEvents: (() async -> [AgentEvent])? = nil,
         readLocal: (() async -> Transcript.Result)? = nil,
         readCodex: (() async -> ([QuotaWindow], String?))? = nil,
         deliver: ((RuleEngine.Alert, Bool) async -> Bool)? = nil,
         tracks: (() -> (claude: Bool, codex: Bool))? = nil,
         tracksExtra: ((Provider) -> Bool)? = nil,
         readExtras: (([Provider]) async -> ExtraStore.Result)? = nil,
         observe: (([QuotaWindow]) async -> [QuotaWindow])? = nil,
         eventInterval: TimeInterval = 1,
         lastActivity: Date = Date()) {
        self.claude = claude; self.rules = rules ?? RuleEngine()
        self.readEvents = readEvents ?? { await HookEventReader.shared.events() }
        self.readCodex = readCodex ?? {
            let rows = await CodexProvider.shared.windows()
            return (rows, await CodexProvider.shared.plan)
        }
        if let readLocal { self.readLocal = readLocal }
        else {
            let pricing = Pricing.load()
            self.readLocal = { await Transcript.shared.refresh(pricing: pricing) }
        }
        self.deliver = deliver ?? { await Notifier.shared.deliver($0, away: $1) }
        self.tracks = tracks ?? { (Prefs.shared.trackClaude, Prefs.shared.trackCodex) }
        self.tracksExtra = tracksExtra ?? { p in MainActor.assumeIsolated { Prefs.shared.tracks(p) } }
        self.readExtras = readExtras ?? { await ExtraStore.shared.read($0) }
        // Injectable so a test never writes to the real cache directory.
        self.observe = observe ?? { await History.shared.observe($0) }
        self.eventInterval = eventInterval
        self.lastActivity = lastActivity
    }
    private var timer: Timer?
    private var settleTimer: Timer?
    private var lastSettleAt = Date.distantPast
    private var inFlight = false
    private var sweepVersion = 0
    private var claudeUpdateVersion = 0
    private var lastActivity = Date()

    /// Live, idle, and asleep are three different jobs. 20 s keeps the bar honest while you work;
    /// 5 min is plenty when nothing has moved; a sleeping Mac gets nothing at all and one fresh
    /// read on wake rather than a backlog of missed ticks.
    private var interval: TimeInterval {
        let quiet = Date().timeIntervalSince(lastActivity)
        if quiet > 60 * 60 { return 900 }      // nothing for an hour: check quarter-hourly
        if quiet > 15 * 60 { return 300 }
        return 20
    }

    func start(observeSystem: Bool = true) {
        if observeSystem {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
            // The cache save is throttled to five minutes, so without this the last stretch of a
            // session is re-parsed on next launch. Quitting is exactly when it is free to write.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    Task { await Transcript.shared.flush() }
                    Task { await History.shared.flush(force: true) }
                }
        }
        pollEvents()
        eventTimer?.invalidate()
        let timer = Timer(timeInterval: eventInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollEvents() }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.schedule()
            }
        }
        // `.common`, not the default mode. A default-mode timer stops firing while a menu or a
        // popover is tracking — which is exactly when the panel is open in front of you and its
        // numbers are the thing you are looking at.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh(forceClaude: Bool = false) {
        // One sweep at a time. Clicking the icon asks for a refresh, and a burst of clicks
        // used to stack sweeps that each re-read the whole log tree.
        guard !inFlight else { if forceClaude { refreshClaudeOnly() }; return }
        inFlight = true
        sweepVersion += 1
        let sweep = sweepVersion
        Task { @MainActor in
            defer { if sweep == sweepVersion { inFlight = false } }
            var snap = Snapshot()

            if tracks().claude {
                await updateClaude(force: forceClaude)
            } else {
                snapshot.windows.removeAll { $0.provider == .claude }
                snapshot.claudeDetails = .init(); snapshot.plans[.claude] = nil
                snapshot.stale = false
            }
            if tracks().codex {
                let (rows, plan) = await readCodex()
                snap.windows += rows
                snap.plans[.codex] = plan
            }
            // The other five, in parallel and each on its own clock. None of them may hold up
            // the two that this app is actually about.
            let extras = Provider.allCases.filter {
                $0 != .claude && $0 != .codex && $0.unavailableReason == nil && tracks(extra: $0)
            }
            if !extras.isEmpty {
                let result = await readExtras(extras)
                snap.windows += result.windows
                snap.plans.merge(result.plans) { _, new in new }
                for (p, connection) in result.connections {
                    // Only the states worth a row. "Connected" needs no explanation and
                    // "not installed" is not this panel's business.
                    switch connection {
                    case .signedOut, .unavailable, .unsupported:
                        snap.connections[p] = connection.word
                    case .connected, .notInstalled:
                        break
                    }
                }
            }

            // Both of these read hundreds of megabytes of session logs. They are actors on
            // purpose: doing this work on the main thread is what made the menu bar stop
            // answering clicks while Claude Code was running.
            // Record what every window reads before anything downstream looks at them, so the
            // pace they report is measured rather than averaged over the whole window.
            snap.windows = await observe(snap.windows)
            let local = await readLocal()
            snap.trophy = local.trophy
            snap.contextPercent = local.context
            snap.windows += snapshot.windows(of: .claude)
            snap.claudeDetails = snapshot.claudeDetails
            snap.plans[.claude] = snapshot.plans[.claude]
            snap.stale = snapshot.stale
            snap.events = snapshot.events
            snap.updatedAt = Date()

            // "Something is happening" is what keeps the fast cadence alive: a session event,
            // or a turn that landed in the last few minutes. Not the context reading — that
            // stays valid for six hours and would hold the fast loop open all afternoon.
            let recentTurn = local.lastTurnAt.map { Date().timeIntervalSince($0) < 300 } ?? false
            let recentEvent = snap.events.first.map { Date().timeIntervalSince($0.at) < 300 } ?? false
            if recentTurn || recentEvent { lastActivity = Date() }

            guard sweep == sweepVersion else { return }
            snapshot = snap
            onSnapshot?(snap)
            dispatchAlerts()
        }
    }

    /// Claude publishes independently of slow providers and transcript statistics.
    private func updateClaude(force: Bool) async {
        claudeRefreshing = true
        claudeUpdateVersion += 1
        let update = claudeUpdateVersion
        let reading = await claude.windows(force: force)
        let details = await claude.details
        let windows = await observe(reading.windows)
        let login = await claude.loggedIn
        let failure = await claude.blocker
        guard update == claudeUpdateVersion else { return }
        loggedIn = login; blocker = failure
        if tracks().claude {
            snapshot.windows.removeAll { $0.provider == .claude }
            snapshot.windows += windows
            snapshot.claudeDetails = details
            snapshot.plans[.claude] = details.plan
            snapshot.stale = reading.stale
            onSnapshot?(snapshot)
            dispatchAlerts()
        }
        claudeRefreshing = false
    }

    func refreshClaudeOnly() {
        guard tracks().claude, !claudeRefreshing else { return }
        claudeRefreshing = true
        Task { await updateClaude(force: true) }
    }

    /// Only used by `--stress`, which needs a snapshot that real data will never produce.
    func injectForTesting(_ s: Snapshot) {
        snapshot = s
        stop()
    }

    func stop() {
        sweepVersion += 1; claudeUpdateVersion += 1
        inFlight = false; claudeRefreshing = false
        timer?.invalidate(); timer = nil
        eventTimer?.invalidate(); eventTimer = nil
        settleTimer?.invalidate(); settleTimer = nil
    }

    private func pollEvents() {
        guard !eventsInFlight else { return }
        eventsInFlight = true
        Task { @MainActor in
            defer { eventsInFlight = false }
            let events = await readEvents()
            if events.map(\.key) != snapshot.events.map(\.key) {
                snapshot.events = events
                lastActivity = Date()
                scheduleSettle()
                onSnapshot?(snapshot)
            }
            dispatchAlerts()
        }
    }

    /// A turn just landed, so the figure is about to move: ask again once the server has had a
    /// moment to count it.
    ///
    /// The heartbeat is what stops the number going stale. This is what makes it arrive when
    /// something actually happened, rather than on whatever grid the cache TTL was on — five
    /// minutes late while you work, fifteen once the app had decided you were idle. It is also
    /// the half of the cadence that lets the other half be slow: the provider can wait five
    /// minutes between polls precisely because it no longer has to guess when a turn ended.
    ///
    /// Debounced, and deliberately not on the shorter side of it. A burst of tool calls is one
    /// piece of news, not nine, and this app has already learned what happens to an endpoint
    /// asked 1,440 times a day.
    private func scheduleSettle() {
        guard settleTimer == nil, Date().timeIntervalSince(lastSettleAt) > 90 else { return }
        let t = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.settleTimer = nil
                self.lastSettleAt = Date()
                self.refresh(forceClaude: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    private func dispatchAlerts() {
        let alerts = rules.evaluate(snapshot)
        let ids = Set(alerts.map(\.id))
        retryDelivery = retryDelivery.filter { ids.contains($0.key) }
        for alert in alerts {
            guard !deliveries.contains(alert.id), (retryDelivery[alert.id] ?? .distantPast) <= Date() else { continue }
            deliveries.insert(alert.id)
            let away = rules.isAway
            Task { @MainActor in
                let accepted = await deliver(alert, away)
                deliveries.remove(alert.id)
                if accepted { rules.acknowledge(alert); retryDelivery.removeValue(forKey: alert.id) }
                else { retryDelivery[alert.id] = Date().addingTimeInterval(60) }
            }
        }
    }

    func saveToken(_ t: String) async -> ClaudeProvider.TokenUpdate {
        claudeUpdateVersion += 1
        let result = await claude.useOwnToken(t)
        await updateClaude(force: false)
        return result
    }

    func enableRealQuota() {
        claudeUpdateVersion += 1
        Task { await claude.enableSharedKeychain(); await updateClaude(force: true) }
    }
}
