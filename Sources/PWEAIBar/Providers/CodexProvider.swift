import Foundation

/// Codex quota, read straight out of its own session logs. No credentials, no network — the CLI
/// writes a `rate_limits` object into every rollout file, which beats any endpoint: it cannot be
/// rate-limited and cannot expire.
///
/// The trap is that those objects are not all the same thing. They carry a `limit_id`, and a
/// team account emits at least two kinds:
///
///   `codex`    the real quota — `primary` is the 5-hour window, `secondary` the weekly
///   `premium`  the add-on credit pool, whose `primary` is null and whose only content is
///              `rate_limit_reached_type: workspace_member_credits_depleted`
///
/// Taking whichever landed last reports "额度耗尽" while the actual quota sits at 95 % — the two
/// records interleave, and the newest file is as likely to hold one as the other. So each kind is
/// tracked separately: the quota comes from `codex`, and a depleted credit pool is reported as
/// the separate fact it is.
actor CodexProvider {

    static let shared = CodexProvider()


    static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    /// Two windows when the log has them, plus the credit pool when it is exhausted.
    func windows() -> [QuotaWindow] {
        var quota: [String: Any]?      // newest `limit_id: codex`
        var credits: [String: Any]?    // newest record whose pool is spent

        var observed = Date.distantPast
        for (url, mtime) in Self.recentFiles(12) {
            guard let rl = Self.lastRateLimits(in: url) else { continue }
            if observed == .distantPast { observed = mtime }
            let id = rl["limit_id"] as? String ?? ""

            if id == "codex", quota == nil, rl["primary"] is [String: Any] {
                quota = rl
            }
            if credits == nil,
               let reached = rl["rate_limit_reached_type"] as? String,
               reached.contains("credits") {
                credits = rl
            }
            if quota != nil && credits != nil { break }
        }

        var out: [QuotaWindow] = []

        if let rl = quota {
            if let w = Self.window(rl, key: "primary", id: "codex_5h", title: "五小时窗口", observed: observed) { out.append(w) }
            if let w = Self.window(rl, key: "secondary", id: "codex_7d", title: "周窗口", observed: observed) { out.append(w) }
        }

        if credits != nil {
            // A spent add-on pool is a standing fact, not a window: no percentage, no reset.
            // `Snapshot.overall` deliberately leaves windows shaped like this out of the
            // menu-bar colour, so it cannot pin the mark red for weeks.
            out.append(QuotaWindow(id: "codex_credits", provider: .codex, channel: .codex,
                                   title: "附加额度", percent: nil, severity: .critical,
                                   note: "已用尽", observedAt: observed))
        }

        if out.isEmpty {
            return []
        }
        return out
    }

    private static func window(_ rl: [String: Any], key: String,
                               id: String, title: String, observed: Date) -> QuotaWindow? {
        guard let n = rl[key] as? [String: Any],
              let pct = (n["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (n["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }

        // A window past its reset has already rolled over. The log still holds the old high,
        // and showing it would claim you are nearly out when you are not.
        if let r = reset, r < Date() {
            return QuotaWindow(id: id, provider: .codex, channel: .codex, title: title,
                               percent: 0, severity: .normal, resetsAt: nil,
                               observedAt: observed)
        }
        let band = Health.grade(pct, warm: Channel.codex.warm, hot: Channel.codex.hot)
        // Graded locally: unlike Claude, Codex ships a bare percentage with no severity of
        // its own, so these bands are our thresholds and not the provider's judgement.
        return QuotaWindow(id: id, provider: .codex, channel: .codex, title: title,
                           percent: pct,
                           severity: band == .hot ? .critical : band == .warm ? .warning : .normal,
                           resetsAt: reset, observedAt: observed, gradedBy: .local)
    }

    // MARK: Reading the logs

    private static func recentFiles(_ limit: Int) -> [(URL, Date)] {
        guard let e = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, d))
        }
        return Array(files.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// The last `rate_limits` in the file — records are appended as the session runs, so the
    /// final one is that session's most recent reading.
    private static func lastRateLimits(in url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let hit = dig(o, for: "rate_limits") { return hit }
        }
        return nil
    }

    private static func dig(_ any: Any, for key: String) -> [String: Any]? {
        if let d = any as? [String: Any] {
            if let hit = d[key] as? [String: Any] { return hit }
            for v in d.values { if let h = dig(v, for: key) { return h } }
        } else if let a = any as? [Any] {
            for v in a { if let h = dig(v, for: key) { return h } }
        }
        return nil
    }
}
