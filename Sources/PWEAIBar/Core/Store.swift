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
        self.eventInterval = eventInterval
        self.lastActivity = lastActivity
    }
    private var timer: Timer?
    private var inFlight = false
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

    func refresh() {
        // One sweep at a time. Clicking the icon asks for a refresh, and a burst of clicks
        // used to stack sweeps that each re-read the whole log tree.
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            var snap = Snapshot()

            if tracks().claude {
                let (windows, stale) = await claude.windows()
                snap.windows += windows
                snap.stale = stale
                loggedIn = await claude.loggedIn
                blocker = await claude.blocker
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
            }

            // Both of these read hundreds of megabytes of session logs. They are actors on
            // purpose: doing this work on the main thread is what made the menu bar stop
            // answering clicks while Claude Code was running.
            let local = await readLocal()
            snap.trophy = local.trophy
            snap.contextPercent = local.context
            snap.events = snapshot.events
            snap.updatedAt = Date()

            // "Something is happening" is what keeps the fast cadence alive: a session event,
            // or a turn that landed in the last few minutes. Not the context reading — that
            // stays valid for six hours and would hold the fast loop open all afternoon.
            let recentTurn = local.lastTurnAt.map { Date().timeIntervalSince($0) < 300 } ?? false
            let recentEvent = snap.events.first.map { Date().timeIntervalSince($0.at) < 300 } ?? false
            if recentTurn || recentEvent { lastActivity = Date() }

            snapshot = snap
            onSnapshot?(snap)
            dispatchAlerts()
        }
    }

    /// Only used by `--stress`, which needs a snapshot that real data will never produce.
    func injectForTesting(_ s: Snapshot) {
        snapshot = s
        stop()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        eventTimer?.invalidate(); eventTimer = nil
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
                onSnapshot?(snapshot)
            }
            dispatchAlerts()
        }
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
        let result = await claude.useOwnToken(t)
        blocker = await claude.blocker
        loggedIn = await claude.loggedIn
        refresh()
        return result
    }

    func enableRealQuota() {
        Task { await claude.enableSharedKeychain(); refresh() }
    }
}
