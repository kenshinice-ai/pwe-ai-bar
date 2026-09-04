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
    private var pendingResets: [String: Date] = [:]  // windows we owe a "you're clear" for
    private var seenEvents: Set<String> = []

    private let quiet: TimeInterval = 15 * 60
    /// No keyboard or mouse for this long and we treat you as away from the desk.
    private let awayAfter: TimeInterval = 5 * 60

    var isAway: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: .init(rawValue: ~0)!)
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
                pendingResets[w.id] = reset
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

        // Reset arrivals.
        for (id, at) in pendingResets where at <= now {
            pendingResets.removeValue(forKey: id)
            let w = snap.windows.first { $0.id == id }
            if (w?.band ?? .calm) == .calm {
                out.append(Alert(kind: .reset,
                                 title: "额度已重置",
                                 body: "\(w?.title ?? "窗口")已重置，可以继续了",
                                 provider: w?.provider ?? .claude, urgent: false))
            }
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
