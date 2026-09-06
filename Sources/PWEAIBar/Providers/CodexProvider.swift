import Foundation

/// Codex quota, read straight out of its own session logs. No credentials, no network — the CLI
/// writes a `rate_limits` object into every rollout file, which beats any endpoint: it cannot be
/// rate-limited and cannot expire.
///
/// The trap is that those objects are not all the same thing. They carry a `limit_id`, and a
/// team account emits at least two kinds:
///
///   `codex`    the real quota — `primary` is the 5-hour window, `secondary` the weekly
///   `premium`  the add-on credit pool, whose windows are null and whose only content is
///              `rate_limit_reached_type: workspace_member_credits_depleted`
///
/// Taking whichever landed last reports "额度耗尽" while the actual quota sits at 95 %: the two
/// interleave inside a single file, so it is not enough to pick the newest file either. Each
/// kind is reduced separately, by the event's own timestamp rather than the file's mtime, and a
/// spent credit pool is reported as the separate fact it is — and only while it is recent.
actor CodexProvider {
    /// Only this one talks to the machine. The live server is opt-in rather than a default, so
    /// a test that forgets to pass one cannot silently spawn a process and assert against
    /// whatever the developer's own account happens to say today.
    static let shared = CodexProvider(server: .shared)
    static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private let root: URL
    private let now: () -> Date
    private let tailBytes: Int
    private let server: CodexAppServer?
    private var live: CodexAppServer.Reading?
    /// When the reading in hand was actually taken, and when we last tried. Kept apart on
    /// purpose: a failed attempt used to overwrite the success time, so a miss *extended* the
    /// life of the value it failed to replace and the panel went on showing it as current.
    private var liveAt: Date?
    private var attemptedAt: Date?
    private(set) var plan: String?
    private(set) var resetCredits = 0

    init(root: URL = CodexProvider.sessions, now: @escaping () -> Date = Date.init,
         tailBytes: Int = 4 << 20, server: CodexAppServer? = nil) {
        self.root = root; self.now = now; self.tailBytes = tailBytes; self.server = server
    }

    /// Ask the app server first, fall back to the logs. The logs are a record of the last time
    /// Codex ran; the server answers for right now, and carries the plan and the reset credits
    /// that never reach a rollout file. Spawning a process is not free, so the answer is held
    /// for a while — shorter once a window is close enough to matter.
    func windows() async -> [QuotaWindow] {
        if let reading = await liveReading(), !reading.windows.isEmpty {
            plan = reading.planType
            resetCredits = reading.resetCredits
            let date = now()
            // Held-over readings are marked as what they are. Two things used to be reported as
            // current here that were not: a value kept after a failed refresh, and a value whose
            // own window has since rolled over. The second is worse — past its reset it is not
            // stale, it is describing a window that no longer exists.
            return reading.windows.map { window in
                var w = window
                let age = date.timeIntervalSince(w.observedAt)
                if let reset = w.resetsAt, reset <= date {
                    w.percent = nil; w.note = "待确认"; w.severity = .normal
                    w.confirmedExhausted = false; w.isStale = true
                } else if age > ttl(reading) {
                    w.isStale = true
                }
                return w
            }
        }
        return logWindows()
    }

    private func liveReading() async -> CodexAppServer.Reading? {
        if let live, let at = liveAt, now().timeIntervalSince(at) < ttl(live) { return live }
        guard let server else { return nil }
        // Back off from *attempting*, separately from how long a success stays good. A machine
        // without Codex should not spawn a process it does not have on every refresh; a machine
        // whose last attempt failed should not have that failure make its old figure look newer.
        if let attemptedAt, now().timeIntervalSince(attemptedAt) < 60, live == nil { return nil }
        attemptedAt = now()
        guard let fresh = await server.read(), !fresh.windows.isEmpty else { return live }
        live = fresh; liveAt = now()
        return fresh
    }

    private func ttl(_ reading: CodexAppServer.Reading) -> TimeInterval {
        let band = reading.windows.map(\.band).max() ?? .calm
        let soon = reading.windows.compactMap(\.resetsAt)
            .map { $0.timeIntervalSince(now()) }.filter { $0 > 0 }.min() ?? .infinity
        return band == .hot || soon < 600 ? 60 : band == .warm ? 120 : 300
    }

    private struct Record {
        let value: [String: Any]
        let at: Date
    }

    private func logWindows() -> [QuotaWindow] {
        let date = now()
        var pools: [String: Record] = [:]
        for url in recentFiles(12) {
            LineScanner.scanTail(url, marker: "rate_limits", tailBytes: tailBytes) { line in
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let ts = o["timestamp"] as? String,
                      let at = ISO8601DateFormatter.parse(ts), at <= date,
                      let rl = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any]
                        ?? o["rate_limits"] as? [String: Any] else { return }
                // Older rollouts have no limit_id. Accept them only if they contain a quota.
                let id = rl["limit_id"] as? String ?? "codex"
                guard id == "codex" || id == "premium" else { return }
                if id == "codex", !["primary", "secondary"].contains(where: {
                    Self.validWindow(rl[$0] as? [String: Any])
                }) { return }
                if id == "premium", rl["primary"] == nil && rl["rate_limit_reached_type"] == nil {
                    return
                }
                if let old = pools[id], old.at > at { return }
                pools[id] = Record(value: rl, at: at)
            }
        }
        var out: [QuotaWindow] = []
        if let q = pools["codex"] {
            out = ["primary", "secondary"].compactMap {
                Self.window(q.value, key: $0, observed: q.at, now: date)
            }
        }
        if let c = pools["premium"], date.timeIntervalSince(c.at) < 3600,
           let reached = c.value["rate_limit_reached_type"] as? String,
           reached.contains("credits") {
            out.append(QuotaWindow(id: "codex_credits", provider: .codex, channel: .codex,
                                   title: "附加额度", percent: nil, severity: .critical,
                                   note: "已用尽", observedAt: c.at, confirmedExhausted: true))
        }
        if out.isEmpty {
            out.append(QuotaWindow(id: "codex_unknown", provider: .codex, channel: .codex,
                                   title: "额度", percent: nil, note: "暂无有效读数",
                                   observedAt: date, isStale: true))
        }
        return out
    }

    private static func validWindow(_ n: [String: Any]?) -> Bool {
        guard let pct = (n?["used_percent"] as? NSNumber)?.doubleValue else { return false }
        return pct.isFinite && pct >= 0 && pct <= 100
    }

    static func windowName(minutes: Int?, key: String) -> String {
        // Chinese numerals for the two everyone has, so Codex's rows read the same as Claude's;
        // digits for anything unusual, where being exact matters more than matching.
        switch minutes {
        case .some(300):                       return "五小时窗口"
        case .some(10080):                     return "周窗口"
        case .some(let m) where m <= 60:       return "\(m) 分钟窗口"
        case .some(let m) where m < 1440:      return "\(m / 60) 小时窗口"
        case .some(let m) where m % 1440 == 0: return "\(m / 1440) 天窗口"
        default: return key == "primary" ? "短窗口" : "长窗口"
        }
    }

    private static func window(_ rl: [String: Any], key: String,
                               observed: Date, now: Date) -> QuotaWindow? {
        guard let n = rl[key] as? [String: Any], validWindow(n),
              let pct = (n["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (n["window_minutes"] as? NSNumber)?.intValue
        let reset = (n["resets_at"] as? NSNumber).flatMap { v -> Date? in
            v.doubleValue.isFinite ? Date(timeIntervalSince1970: v.doubleValue) : nil
        }
        let expired = reset.map { $0 <= now } ?? false
        return QuotaWindow(id: "codex_\(minutes.map(String.init) ?? key)", provider: .codex,
                           channel: .codex, title: windowName(minutes: minutes, key: key),
                           percent: expired ? nil : pct, resetsAt: reset,
                           note: expired ? "待确认" : nil, observedAt: observed,
                           gradedBy: .local, isStale: expired,
                           confirmedExhausted: !expired && pct >= 100,
                           windowLength: minutes.map { TimeInterval($0) * 60 })
    }

    private func recentFiles(_ limit: Int) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
