import AppKit
import Foundation

/// Persist reception and delivery separately: a failed notification stays in the outbox.
@MainActor
final class RuleEngine {
    struct Alert: Codable, Identifiable {
        enum Kind: String, Codable { case threshold, exhausted, reset, resetExpected, waiting, finished, failed }
        let id: String
        let kind: Kind
        let title: String
        let body: String
        let provider: Provider
        let urgent: Bool
        let subject: String
        let createdAt: Date
    }

    /// What each window looked like last time, so a threshold can be *crossed* rather than
    /// merely observed.
    struct Memory: Codable {
        var band: Int
        var exhausted: Bool
        var at: Date
    }
    private struct State: Codable {
        var pendingResets: [String: Date] = [:]
        var seenEvents: [String: Date] = [:]
        var outbox: [String: Alert] = [:]
        var lastFired: [String: Date] = [:]
        /// Persisted, and that is the point. Held only in memory, every relaunch re-seeded the
        /// baseline from whatever was true at that moment — so a window that filled up while
        /// the app was restarting had no "before" to be compared against, and the one alert
        /// worth sending was the one that could never fire.
        var memory: [String: Memory] = [:]
    }
    private var state: State
    private let defaults: UserDefaults
    private let now: () -> Date
    private let away: () -> Bool
    private let remaining: () -> Bool

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         away: @escaping () -> Bool = RuleEngine.systemIsAway,
         remaining: (() -> Bool)? = nil) {
        self.defaults = defaults; self.now = now; self.away = away
        self.remaining = remaining ?? { Prefs.shared.showRemaining }
        if let data = defaults.data(forKey: "alertStateV2"),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
            state.pendingResets = (defaults.dictionary(forKey: "pendingResets") as? [String: Double] ?? [:])
                .mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    nonisolated static func systemIsAway() -> Bool {
        let types: [CGEventType] = CGEventType(rawValue: ~0).map { [$0] }
            ?? [.mouseMoved, .keyDown, .scrollWheel]
        return (types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0) > 300
    }
    var isAway: Bool { away() }

    func evaluate(_ snap: Snapshot) -> [Alert] {
        let date = now()
        var changed = false
        func enqueue(_ alert: Alert, quiet: Bool = false) {
            guard state.outbox[alert.id] == nil else { return }
            let topic = "\(alert.kind.rawValue):\(alert.subject)"
            if quiet, let last = state.lastFired[topic], date.timeIntervalSince(last) < 900 { return }
            state.outbox[alert.id] = alert
            state.lastFired[topic] = date
            changed = true
        }
        for w in snap.windows {
            let key = w.observationKey
            // Migrate the old per-window promises, including Claude's two historical aliases.
            // `observationBase` is the key this window had before readings were separated by
            // account. Without it in the list, the first reading that arrives with an account
            // attached silently abandons every promise made under the old key — including the
            // one alert people actually wait for, "你可以继续了".
            let aliases = [w.id, w.observationBase]
                + (w.id == "five_hour" ? ["session"] : w.id == "seven_day" ? ["weekly_all"] : [])
            for alias in aliases {
                if let old = state.pendingResets.removeValue(forKey: alias) {
                    state.pendingResets[key] = state.pendingResets[key] ?? old; changed = true
                }
            }
            let fresh = w.canNotify(at: date) && !(w.provider == .claude && snap.stale)
            let seen = state.memory[key]
            if fresh, seen?.band != w.band.rawValue || seen?.exhausted != w.confirmedExhausted {
                state.memory[key] = Memory(band: w.band.rawValue,
                                           exhausted: w.confirmedExhausted, at: date)
                changed = true
            }
            if fresh, w.band >= .warm, let reset = w.resetsAt, reset > date,
               state.pendingResets[key] == nil || state.pendingResets[key]! > date {
                if state.pendingResets[key] != reset { state.pendingResets[key] = reset; changed = true }
            }
            // Reset promises are kept whether or not a fresh reading arrived. Codex only writes a
            // reading when Codex runs, so waiting for confirmation means the one alert you were
            // actually waiting for — "you can start again" — is the one that never comes. Say the
            // time has passed, and say that it is the clock talking rather than a measurement.
            if let at = state.pendingResets[key], at <= date {
                if fresh, w.observedAt >= at, w.band == .calm, w.percent != nil {
                    enqueue(Alert(id: "reset:\(key):\(at.timeIntervalSince1970)", kind: .reset,
                                  title: "额度已重置", body: "\(w.provider.name) \(w.title)已重置，可以继续了",
                                  provider: w.provider, urgent: false, subject: key, createdAt: date))
                } else if date.timeIntervalSince(at) >= 120 {
                    enqueue(Alert(id: "reset-expected:\(key):\(at.timeIntervalSince1970)", kind: .resetExpected,
                                  title: "额度应该重置了",
                                  body: "\(w.provider.name) \(w.title)的重置时间已过，新读数到了再确认",
                                  provider: w.provider, urgent: false, subject: key, createdAt: date))
                }
            }
            guard fresh, let seen, let previous = Health(rawValue: seen.band) else { continue }
            let wasExhausted = seen.exhausted
            if w.confirmedExhausted, !wasExhausted {
                enqueue(Alert(id: "exhausted:\(key):\(w.observedAt.timeIntervalSince1970)", kind: .exhausted,
                              title: "\(w.provider.name) \(w.title)已用尽", body: resetText(w, at: date),
                              provider: w.provider, urgent: true, subject: key, createdAt: date))
            } else if w.band > previous, w.band >= .warm {
                let value = Readout.text(w, remaining: remaining())
                enqueue(Alert(id: "threshold:\(key):\(w.observedAt.timeIntervalSince1970)", kind: .threshold,
                              title: "\(w.provider.name) \(w.title)\(w.band == .hot ? "接近上限" : "额度预警")",
                              body: "\(remaining() ? "剩余" : "已用") \(value) · \(resetText(w, at: date))",
                              provider: w.provider, urgent: w.band == .hot, subject: key, createdAt: date), quiet: true)
            }
        }
        for e in snap.events {
            // A newer event resolves/supersedes any still-undelivered alert for this session.
            let subject = "\(e.provider.rawValue):\(e.id)"
            for (id, alert) in state.outbox where alert.subject == subject
                && [.waiting, .finished, .failed].contains(alert.kind) && id != "event:\(e.key)" {
                state.outbox.removeValue(forKey: id); changed = true
            }
            guard state.seenEvents[e.key] == nil, e.at <= date else { continue }
            state.seenEvents[e.key] = e.at; changed = true
            // Waiting remains actionable for its full lifetime, including after sleep/restart.
            let maxAge: TimeInterval = e.kind == .waiting ? 1800 : 120
            guard date.timeIntervalSince(e.at) < maxAge else { continue }
            let kind: Alert.Kind
            let title: String
            switch e.kind {
            case .waiting: kind = .waiting; title = "\(e.provider.name) 在等你"
            case .finished:
                guard isAway else { continue }
                kind = .finished; title = "任务完成"
            case .failed: kind = .failed; title = "会话出错"
            case .answered: continue
            }
            enqueue(Alert(id: "event:\(e.key)", kind: kind, title: title, body: e.text,
                          provider: e.provider, urgent: kind != .finished, subject: subject, createdAt: e.at))
        }
        let seen = state.seenEvents.filter { date.timeIntervalSince($0.value) < 86400 }
        let pending = state.pendingResets.filter { date.timeIntervalSince($0.value) < 86400 }
        let fired = state.lastFired.filter { date.timeIntervalSince($0.value) < 86400 }
        // A week is long enough to survive a holiday and short enough that a window the vendor
        // renamed does not keep a baseline for ever.
        let memory = state.memory.filter { abs(date.timeIntervalSince($0.value.at)) < 7 * 86400 }
        if memory.count != state.memory.count { changed = true }
        state.memory = memory
        let outbox = state.outbox.filter { _, a in
            let life: TimeInterval = a.kind == .reset || a.kind == .resetExpected ? 86400
                : a.kind == .waiting ? 1800 : 120
            return date.timeIntervalSince(a.createdAt) < life
        }
        if seen.count != state.seenEvents.count || pending.count != state.pendingResets.count
            || fired.count != state.lastFired.count || outbox.count != state.outbox.count { changed = true }
        state.seenEvents = seen; state.pendingResets = pending; state.lastFired = fired; state.outbox = outbox
        if changed { save() }
        return state.outbox.values.filter { alert in
            // An expected reset is a claim about the clock, and the clock has already passed it.
            guard alert.kind == .reset else { return true }
            // A delayed delivery must still be true when retried. Missing data keeps it queued.
            return snap.windows.contains { w -> Bool in
                let key: String = w.observationKey
                guard key == alert.subject, w.percent != nil, w.band == .calm else { return false }
                guard w.canNotify(at: date) else { return false }
                return !(w.provider == .claude && snap.stale)
            }
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    /// Acknowledgment means the OS accepted the notification, not that the human answered.
    func acknowledge(_ alert: Alert) {
        guard state.outbox.removeValue(forKey: alert.id) != nil else { return }
        if alert.kind == .reset || alert.kind == .resetExpected {
            state.pendingResets.removeValue(forKey: alert.subject)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "alertStateV2") }
    }

    private func resetText(_ w: QuotaWindow, at date: Date) -> String {
        guard let at = w.resetsAt, at > date else { return "留意剩余额度" }
        let mins = max(1, Int(ceil(at.timeIntervalSince(date) / 60)))
        return "\(mins) 分钟后重置"
    }
}
