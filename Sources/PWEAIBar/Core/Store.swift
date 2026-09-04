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

    private let claude = ClaudeProvider()
    private let rules = RuleEngine()
    private var pricing = Pricing.load()
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

    func start() {
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

            if Prefs.shared.trackClaude {
                let (windows, stale) = await claude.windows()
                snap.windows += windows
                snap.stale = stale
                loggedIn = await claude.loggedIn
                blocker = await claude.blocker
            }
            if Prefs.shared.trackCodex {
                snap.windows += await CodexProvider.shared.windows()
            }

            // Both of these read hundreds of megabytes of session logs. They are actors on
            // purpose: doing this work on the main thread is what made the menu bar stop
            // answering clicks while Claude Code was running.
            let local = await Transcript.shared.refresh(pricing: pricing)
            snap.trophy = local.trophy
            snap.contextPercent = local.context
            snap.events = HookProvider.events()
            snap.updatedAt = Date()

            // "Something is happening" is what keeps the fast cadence alive: a session event,
            // or a turn that landed in the last few minutes. Not the context reading — that
            // stays valid for six hours and would hold the fast loop open all afternoon.
            let recentTurn = local.lastTurnAt.map { Date().timeIntervalSince($0) < 300 } ?? false
            let recentEvent = snap.events.first.map { Date().timeIntervalSince($0.at) < 300 } ?? false
            if recentTurn || recentEvent { lastActivity = Date() }

            let alerts = rules.evaluate(snap)
            let away = rules.isAway
            for a in alerts { Notifier.shared.deliver(a, away: away) }

            snapshot = snap
            onSnapshot?(snap)
        }
    }

    /// Only used by `--stress`, which needs a snapshot that real data will never produce.
    func injectForTesting(_ s: Snapshot) {
        snapshot = s
        timer?.invalidate()
        timer = nil
    }

    func saveToken(_ t: String) {
        Task { await claude.useOwnToken(t); refresh() }
    }

    func enableRealQuota() {
        Task { await claude.enableSharedKeychain(); refresh() }
    }
    func clearAttention() { rules.clearAttention() }
}
