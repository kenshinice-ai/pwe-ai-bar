import Foundation

/// Codex quota, read straight out of its own session logs. No credentials, no network — the
/// CLI already writes a `rate_limits` object into every rollout file, which is a better source
/// than any endpoint because it cannot be rate-limited and cannot expire.
///
/// The catch is that plans differ in what they populate. On a team plan `primary` and
/// `secondary` come back null and the real state lives in `rate_limit_reached_type` — an
/// exhausted credit pool is a state, not a percentage, and this returns it as one rather than
/// inventing a ratio to fill a progress bar with.
enum CodexProvider {

    static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    static func window() -> QuotaWindow? {
        guard let e = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, d))
        }
        // Only the newest handful: an old rollout's limits are worse than no limits.
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let rl = rateLimits(in: url) else { continue }
            return build(rl)
        }
        return nil
    }

    private static func rateLimits(in url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let hit = dig(o, for: "rate_limits") { return hit }
        }
        return nil
    }

    private static func dig(_ any: Any, for key: String) -> [String: Any]? {
        guard let d = any as? [String: Any] else {
            if let a = any as? [Any] { for v in a { if let h = dig(v, for: key) { return h } } }
            return nil
        }
        if let hit = d[key] as? [String: Any] { return hit }
        for v in d.values { if let h = dig(v, for: key) { return h } }
        return nil
    }

    private static func build(_ rl: [String: Any]) -> QuotaWindow {
        var w = QuotaWindow(id: "codex", provider: .codex, channel: .codex, title: "Codex")

        // A window past its reset has already rolled over; showing its old high would mislead.
        func read(_ key: String) -> (Double, Date?)? {
            guard let n = rl[key] as? [String: Any],
                  let pct = (n["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (n["resets_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let r = reset, r < Date() { return (0, nil) }
            return (pct, reset)
        }

        if let (pct, reset) = read("primary") ?? read("secondary") {
            w.percent = pct
            w.resetsAt = reset
            w.severity = Health.grade(pct, warm: Channel.codex.warm, hot: Channel.codex.hot) == .hot
                ? .critical : (pct >= Channel.codex.warm ? .warning : .normal)
            return w
        }

        // No ratio available. Report the state the CLI actually recorded.
        if let reached = rl["rate_limit_reached_type"] as? String, !reached.isEmpty {
            w.severity = .critical
            w.note = reached.contains("credits") ? "额度耗尽" : "已限流"
            return w
        }
        if let credits = rl["credits"] as? [String: Any] {
            if (credits["unlimited"] as? Bool) == true { w.note = "无限"; return w }
            if let bal = (credits["balance"] as? NSNumber)?.doubleValue {
                w.note = String(format: "余 %.0f", bal)
                w.severity = bal <= 0 ? .critical : .normal
                return w
            }
        }
        w.note = "—"
        return w
    }
}
