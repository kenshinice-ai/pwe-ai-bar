import Foundation

/// Reads Claude Code's own session logs — the source that needs no credentials at all.
///
/// Two jobs: the trophy figures (every turn ever, priced at API list) and the live context
/// reading (the newest turn's input + cache tokens against the model's window). Scanning
/// thousands of files on every refresh would be wasteful, so the full sweep is cached against
/// the newest modification date in the tree and only redone when something actually changed.
enum Transcript {

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private struct Turn {
        let at: Date, model: String
        let input, output, cacheWrite, cacheRead: Int
    }

    private static var cachedTrophy: Trophy?
    private static var cachedStamp: Date?
    private static var cachedContext: Double?

    /// Newest mtime anywhere in the tree — the cheap way to ask "did anything change".
    private static func stamp() -> Date? {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let d, newest == nil || d > newest! { newest = d }
        }
        return newest
    }

    /// Context window per model. Values the Models API would confirm; `CLAUDE_CONTEXT_WINDOW`
    /// overrides for anything unusual.
    private static func window(for model: String) -> Double {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_CONTEXT_WINDOW"],
           let v = Double(s) { return v }
        return model.contains("haiku") ? 200_000 : 1_000_000
    }

    static func refresh(pricing: Pricing) -> (trophy: Trophy, context: Double?) {
        let now = stamp()
        if let c = cachedTrophy, cachedStamp == now { return (c, cachedContext) }

        var turns: [Turn] = []
        var latest: (Date, String, Int)?     // when, model, input+cache — the live context

        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard line.contains("\"usage\""),
                          let data = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          o["type"] as? String == "assistant",
                          let msg = o["message"] as? [String: Any],
                          let model = msg["model"] as? String, model != "<synthetic>",
                          let u = msg["usage"] as? [String: Any],
                          let ts = o["timestamp"] as? String,
                          let at = ISO8601DateFormatter.parse(ts)
                    else { continue }

                    let i  = u["input_tokens"] as? Int ?? 0
                    let ou = u["output_tokens"] as? Int ?? 0
                    let cw = u["cache_creation_input_tokens"] as? Int ?? 0
                    let cr = u["cache_read_input_tokens"] as? Int ?? 0
                    turns.append(Turn(at: at, model: model, input: i, output: ou,
                                      cacheWrite: cw, cacheRead: cr))
                    if latest == nil || at > latest!.0 { latest = (at, model, i + cw + cr) }
                }
            }
        }

        var t = Trophy()
        t.turns = turns.count
        t.days = Set(turns.map { dayKey($0.at) }).count

        var perModel: [String: (Int, Double)] = [:]
        var perDay: [String: Double] = [:]
        for turn in turns {
            let c = pricing.cost(model: turn.model, input: turn.input, output: turn.output,
                                 cacheWrite: turn.cacheWrite, cacheRead: turn.cacheRead)
            t.equivalentUSD += c
            t.tokens.input += turn.input; t.tokens.output += turn.output
            t.tokens.cacheWrite += turn.cacheWrite; t.tokens.cacheRead += turn.cacheRead
            var m = perModel[turn.model] ?? (0, 0); m.0 += 1; m.1 += c; perModel[turn.model] = m
            perDay[dayKey(turn.at), default: 0] += c
        }
        t.byModel = perModel.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.usd > $1.usd }
        t.byDay = perDay.map { ($0.key, $0.value) }.sorted { $0.day < $1.day }
        // Subscription cost over the same span, so the multiple compares like with like.
        t.subscriptionUSD = pricing.subscriptionMonthlyUSD * Double(max(t.days, 1)) / 30.0

        var ctx: Double?
        if let l = latest, Date().timeIntervalSince(l.0) < 6 * 3600 {
            ctx = min(100, Double(l.2) / window(for: l.1) * 100)
        }

        cachedTrophy = t; cachedStamp = now; cachedContext = ctx
        return (t, ctx)
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    /// The most recent 429, if any — the only place Claude Code records a real reset time
    /// locally. Used as the offline fallback when the usage endpoint is unreachable.
    static func lastRateLimit() -> (resetsAt: Date, kind: String)? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var best: (Date, String)?
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("quotaLimits") {
                guard let data = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let q = o["quotaLimits"] as? [String: Any],
                      let secs = q["resetsAt"] as? Double else { continue }
                let at = Date(timeIntervalSince1970: secs)
                let kind = q["rateLimitType"] as? String ?? "five_hour"
                if best == nil || at > best!.0 { best = (at, kind) }
            }
        }
        return best
    }
}

extension ISO8601DateFormatter {
    static func parse(_ s: String) -> Date? {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return b.date(from: s)
    }
}
