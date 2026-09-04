import Foundation

/// Claude Code's own session logs — the source that needs no credentials at all.
///
/// Two jobs: the trophy figures (every turn ever, priced at list) and the live context reading.
///
/// **This must never touch the main thread.** The tree here is 159 MB across thousands of files,
/// and while you are actually using Claude Code its newest file changes every few seconds. A
/// full re-read on the main actor every refresh is what made the menu bar stop responding to
/// clicks — the icon was drawing fine, the app just was not listening. So the whole thing is an
/// actor off the main thread, and it re-parses only the files whose modification date or size
/// actually moved, keeping per-file aggregates for everything else.
actor Transcript {

    static let shared = Transcript()

    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct Turn: Sendable {
        let at: Date, model: String
        let input, output, cacheWrite, cacheRead: Int
    }

    /// What one file contributed, remembered so an unchanged file is never read twice.
    private struct FileCache {
        let modified: Date
        let size: Int
        let turns: [Turn]
    }

    private var cache: [String: FileCache] = [:]

    struct Result: Sendable {
        var trophy: Trophy
        var context: Double?
    }

    func refresh(pricing: Pricing) -> Result {
        let fm = FileManager.default
        var seen = Set<String>()
        var all: [Turn] = []

        if let e = fm.enumerator(at: Self.root,
                                 includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                 options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let key = url.path
                seen.insert(key)
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = rv?.contentModificationDate ?? .distantPast
                let size = rv?.fileSize ?? 0

                if let hit = cache[key], hit.modified == modified, hit.size == size {
                    all += hit.turns                      // untouched since last sweep
                    continue
                }
                let turns = Self.parse(url)
                cache[key] = FileCache(modified: modified, size: size, turns: turns)
                all += turns
            }
        }
        // Drop files that have gone away, so the cache cannot grow forever.
        for key in cache.keys where !seen.contains(key) { cache.removeValue(forKey: key) }

        return Self.summarise(all, pricing: pricing)
    }

    // MARK: Parsing

    /// Byte-level, on purpose.
    ///
    /// The obvious version — read the file as a `String`, `split` on newlines, test each line
    /// with `contains` — takes minutes across a 159 MB tree. Swift's `String` comparison is
    /// Unicode-correct, which means grapheme-cluster work on every one of several million
    /// lines, and almost all of that work is spent rejecting lines we do not want. Scanning
    /// raw bytes for an ASCII marker and only decoding the survivors turns the same sweep into
    /// a couple of seconds. The file is memory-mapped so a big log is never fully resident.
    private static func parse(_ url: URL) -> [Turn] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [Turn] = []

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            let usage = Array("\"usage\"".utf8)
            var lineStart = 0
            var i = 0

            while i <= count {
                guard i == count || base[i] == 0x0A else { i += 1; continue }
                let length = i - lineStart
                if length > 40, contains(base + lineStart, length, usage) {
                    let slice = Data(bytes: base + lineStart, count: length)
                    if let turn = decode(slice) { out.append(turn) }
                }
                i += 1
                lineStart = i
            }
        }
        return out
    }

    /// Naive substring search over bytes. The needle is seven bytes and the haystack is one
    /// line, so anything cleverer would cost more to set up than it saves.
    private static func contains(_ hay: UnsafePointer<UInt8>, _ n: Int, _ needle: [UInt8]) -> Bool {
        let m = needle.count
        guard m <= n else { return false }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if hay[i] == first {
                var k = 1
                while k < m, hay[i + k] == needle[k] { k += 1 }
                if k == m { return true }
            }
            i += 1
        }
        return false
    }

    private static func decode(_ line: Data) -> Turn? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "assistant",
              let msg = o["message"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let u = msg["usage"] as? [String: Any],
              let ts = o["timestamp"] as? String,
              let at = ISO8601DateFormatter.parse(ts)
        else { return nil }
        return Turn(at: at, model: model,
                    input: u["input_tokens"] as? Int ?? 0,
                    output: u["output_tokens"] as? Int ?? 0,
                    cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheRead: u["cache_read_input_tokens"] as? Int ?? 0)
    }

    private static func summarise(_ turns: [Turn], pricing: Pricing) -> Result {
        var t = Trophy()
        t.turns = turns.count

        let cal = Calendar.current
        var perModel: [String: (Int, Double)] = [:]
        var perDay: [String: Double] = [:]
        var perHour: [Date: Double] = [:]
        var days = Set<String>()

        let topOfHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"

        var latest: (Date, String, Int)?
        for turn in turns {
            let c = pricing.cost(model: turn.model, input: turn.input, output: turn.output,
                                 cacheWrite: turn.cacheWrite, cacheRead: turn.cacheRead)
            t.equivalentUSD += c
            t.tokens.input += turn.input; t.tokens.output += turn.output
            t.tokens.cacheWrite += turn.cacheWrite; t.tokens.cacheRead += turn.cacheRead

            var m = perModel[turn.model] ?? (0, 0); m.0 += 1; m.1 += c; perModel[turn.model] = m
            let day = dayFmt.string(from: turn.at)
            days.insert(day); perDay[day, default: 0] += c
            if turn.at > topOfHour.addingTimeInterval(-23 * 3600),
               let h = cal.dateInterval(of: .hour, for: turn.at)?.start {
                perHour[h, default: 0] += c
            }
            if latest == nil || turn.at > latest!.0 {
                latest = (turn.at, turn.model, turn.input + turn.cacheWrite + turn.cacheRead)
            }
        }

        t.days = days.count
        t.byModel = perModel.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.usd > $1.usd }
        t.byDay = perDay.map { ($0.key, $0.value) }.sorted { $0.day < $1.day }
        // Empty hours keep their slot: a gap is information, and closing it up would make a
        // quiet night look busy.
        t.byHour = (0..<24).reversed().map { back in
            let h = topOfHour.addingTimeInterval(-Double(back) * 3600)
            return (h, perHour[h] ?? 0)
        }
        t.subscriptionUSD = pricing.subscriptionMonthlyUSD * Double(max(t.days, 1)) / 30.0

        var ctx: Double?
        if let l = latest, Date().timeIntervalSince(l.0) < 6 * 3600 {
            ctx = min(100, Double(l.2) / contextWindow(for: l.1) * 100)
        }
        return Result(trophy: t, context: ctx)
    }

    private static func contextWindow(for model: String) -> Double {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_CONTEXT_WINDOW"],
           let v = Double(s) { return v }
        return model.contains("haiku") ? 200_000 : 1_000_000
    }

    /// The most recent 429 — the only place a real reset time is recorded locally, and the
    /// offline fallback when the usage endpoint is unreachable. Scans only recently-touched
    /// files: an old rate limit is not news.
    static func lastRateLimit() -> (resetsAt: Date, kind: String)? {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var recent: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            recent.append((url, d))
        }
        var best: (Date, String)?
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }).prefix(8) {
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
