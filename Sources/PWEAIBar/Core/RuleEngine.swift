import AppKit
import Foundation

/// Decides when to speak.
///
/// Everything here exists to avoid the failure mode that makes people turn a monitor off: it
/// notices something once and then keeps saying it. Four rules do the work — fire on the
/// crossing rather than the reading, hold a quiet period per topic, check whether the human is
/// even at the keyboard, and defer to Do Not Disturb.
@MainActor
final class RuleEngine {

    struct Alert {
        enum Kind { case threshold, exhausted, reset, waiting, finished, failed }
        let kind: Kind
        let title: String
        let body: String
        let provider: Provider
        let urgent: Bool
    }

    private var bands: [String: Health] = [:]        // last band seen, per window id
    private var lastFired: [String: Date] = [:]      // quiet period, per topic
    private var seenEvents: Set<String> = []

    /// Windows we owe a "you're clear" for, kept across launches.
    ///
    /// This is the one alert nobody else sends, and the gap between hitting a limit and it
    /// resetting is measured in hours — plenty of time to quit the app, reboot, or have it
    /// relaunch at login. Holding the promise only in memory meant the app would routinely
    /// forget the very thing it exists to tell you.
    private var pendingResets: [String: Date] {
        get {
            (UserDefaults.standard.dictionary(forKey: "pendingResets") as? [String: Double] ?? [:])
                .mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.mapValues { $0.timeIntervalSince1970 },
                                      forKey: "pendingResets")
        }
    }

    private let quiet: TimeInterval = 15 * 60
    /// No keyboard or mouse for this long and we treat you as away from the desk.
    private let awayAfter: TimeInterval = 5 * 60

    var isAway: Bool {
        // `~0` is kCGAnyInputEventType. It is not a declared case, and the only reason the
        // force-unwrap that used to be here never crashed is that the imported enum happens to
        // accept undeclared raw values — which is not a promise. Falling back to the union of
        // three concrete event types costs one extra call and cannot trap.
        let any = CGEventType(rawValue: ~0)
        let idle: CFTimeInterval
        if let any {
            idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        } else {
            idle = [CGEventType.mouseMoved, .keyDown, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
                .min() ?? 0
        }
        return idle > awayAfter
    }

    private var remainingWord: String {
        Prefs.shared.showRemaining ? "剩 " : "到 "
    }

    func evaluate(_ snap: Snapshot) -> [Alert] {
        var out: [Alert] = []
        let now = Date()

        for w in snap.windows {
            let band = w.band
            let previous = bands[w.id]
            bands[w.id] = band

            // Remember to come back when this window rolls over — the one alert nobody else
            // sends, and the one that actually gives you time back.
            if band >= .warm, let reset = w.resetsAt, reset > now {
                var p = pendingResets
                p[w.id] = reset
                pendingResets = p
            }

            guard let previous else { continue }        // first sight is not a crossing
            guard band > previous else { continue }     // only upward crossings speak

            if band == .hot {
                out.append(Alert(
                    kind: .exhausted,
                    title: "\(w.title)用尽",
                    body: reset(w) ?? "等待重置",
                    provider: w.provider, urgent: true))
            } else if band == .warm {
                out.append(Alert(
                    kind: .threshold,
                    // Same convention as everything else. An alert that says "到 89%" while
                    // the panel says "剩余 11%" makes the user do the subtraction to work out
                    // whether the two are even talking about the same thing.
                    title: "\(w.provider.name) \(w.title) \(remainingWord)\(Readout.text(w, remaining: Prefs.shared.showRemaining))",
                    body: reset(w) ?? "留意剩余额度",
                    provider: w.provider, urgent: false))
            }
        }

        // Reset arrivals — the alert nobody else sends, and the one that actually gives time
        // back. Only acted on when we can see the window it was promised about: with no data at
        // all we cannot tell "reset" from "cannot reach the endpoint", and the promise is worth
        // keeping until we can.
        if !snap.windows.isEmpty {
            var pending = pendingResets
            for (id, at) in pending where at <= now {
                pending.removeValue(forKey: id)
                guard let w = snap.windows.first(where: { $0.id == id }) else { continue }
                guard w.band == .calm else { continue }        // reset, and genuinely clear
                out.append(Alert(kind: .reset,
                                 title: "额度已重置",
                                 body: "\(w.provider.name) \(w.title)已重置，可以继续了",
                                 provider: w.provider, urgent: false))
            }
            // Anything promised about a window that no longer exists is dropped after a day,
            // so the list cannot accumulate forever.
            pending = pending.filter { now.timeIntervalSince($0.value) < 86400 }
            pendingResets = pending
        }

        // Session events. Keyed by session id + kind so a re-fired hook stays silent.
        for e in snap.events {
            let key = "\(e.id)-\(e.kind.rawValue)-\(Int(e.at.timeIntervalSince1970))"
            guard !seenEvents.contains(key) else { continue }
            seenEvents.insert(key)
            if seenEvents.count > 400 { seenEvents.removeAll() }
            guard now.timeIntervalSince(e.at) < 120 else { continue }   // no backlog on launch

            switch e.kind {
            case .waiting:
                out.append(Alert(kind: .waiting, title: "\(e.provider.name) 在等你",
                                 body: e.text, provider: e.provider, urgent: true))
            case .finished:
                // Only worth saying when you are not sitting there watching it finish.
                if isAway {
                    out.append(Alert(kind: .finished, title: "任务完成",
                                     body: e.text, provider: e.provider, urgent: false))
                }
            case .failed:
                out.append(Alert(kind: .failed, title: "会话出错",
                                 body: e.text, provider: e.provider, urgent: true))
            }
        }

        return out.filter { allow($0, now: now) }
    }

    private func allow(_ a: Alert, now: Date) -> Bool {
        let topic = "\(a.kind)-\(a.provider.rawValue)"
        if let last = lastFired[topic], now.timeIntervalSince(last) < quiet, !a.urgent {
            return false
        }
        lastFired[topic] = now
        return true
    }

    private func reset(_ w: QuotaWindow) -> String? {
        guard let at = w.resetsAt else { return nil }
        let mins = Int(at.timeIntervalSinceNow / 60)
        guard mins > 0 else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return mins < 60 ? "\(mins) 分钟后重置" : "\(f.string(from: at)) 重置"
    }

    /// Called when the user answers, so a fresh prompt from the same session can speak again.
    func clearAttention() { seenEvents.removeAll() }
}
