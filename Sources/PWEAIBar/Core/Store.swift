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

    var onSnapshot: ((Snapshot) -> Void)?

    private let claude = ClaudeProvider()
    private let rules = RuleEngine()
    private var pricing = Pricing.load()
    private var timer: Timer?
    private var lastActivity = Date()

    /// Live, idle, and asleep are three different jobs. 20 s keeps the bar honest while you work;
    /// 5 min is plenty when nothing has moved; a sleeping Mac gets nothing at all and one fresh
    /// read on wake rather than a backlog of missed ticks.
    private var interval: TimeInterval {
        Date().timeIntervalSince(lastActivity) > 15 * 60 ? 300 : 20
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.schedule()
            }
        }
    }

    func refresh() {
        Task { @MainActor in
            var snap = Snapshot()

            if Prefs.shared.trackClaude {
                let (windows, stale) = await claude.windows()
                snap.windows += windows
                snap.stale = stale
                loggedIn = await claude.loggedIn
            }
            if Prefs.shared.trackCodex, let w = CodexProvider.window() {
                snap.windows.append(w)
            }

            let local = Transcript.refresh(pricing: pricing)
            snap.trophy = local.trophy
            snap.contextPercent = local.context
            snap.events = HookProvider.events()
            snap.updatedAt = Date()

            // "Something is happening" is what keeps the fast cadence alive.
            if snap.events.first.map({ Date().timeIntervalSince($0.at) < 300 }) == true
                || (snap.contextPercent ?? 0) > 0 {
                lastActivity = Date()
            }

            let alerts = rules.evaluate(snap)
            let away = rules.isAway
            for a in alerts { Notifier.shared.deliver(a, away: away) }

            snapshot = snap
            onSnapshot?(snap)
        }
    }

    func reloadPricing() { pricing = Pricing.load(); refresh() }
    func clearAttention() { rules.clearAttention() }
}
