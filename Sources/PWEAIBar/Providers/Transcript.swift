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

    /// What one file contributed, remembered so an unchanged file is never read twice — and
    /// so a growing one is only read from where we stopped.
    private struct FileCache {
        let modified: Date
        let size: Int
        /// Byte offset just past the last complete line we parsed. A session log is appended to
        /// while you work, so the live file changes on every sweep; without this its whole
        /// twenty-odd megabytes are re-read each time, which was the last two and a half
        /// seconds of the refresh.
        let parsedUpTo: Int
        let turns: [Turn]
    }

    private var cache: [String: FileCache] = [:]
    private var loadedFromDisk = false

    /// Where the parsed aggregate lives between launches.
    ///
    /// The in-memory cache makes the second sweep of a session instant, but the first one still
    /// re-read 159 MB — every launch, and every reboot. Turns are small and there are only about
    /// eleven thousand of them, so the whole parse result fits in a few hundred kilobytes on
    /// disk. Keyed by modification date and size, exactly like the in-memory copy, so a file
    /// that changed is still re-read and one that did not is never touched.
    private static var diskCache: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWE AI Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript-cache.json")
    }

    /// Rows are `[epochSeconds, modelIndex, input, output, cacheWrite, cacheRead]`, with the
    /// model names held once in their own list. Storing the model string on every row would
    /// triple the file for no gain.
    private func loadDisk() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.diskCache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1,
              let models = root["models"] as? [String],
              let files = root["files"] as? [String: [String: Any]] else { return }

        for (path, entry) in files {
            guard let modified = entry["m"] as? Double,
                  let size = entry["s"] as? Int,
                  let rows = entry["t"] as? [[Double]] else { continue }
            let turns: [Turn] = rows.compactMap { r in
                guard r.count == 6, Int(r[1]) < models.count else { return nil }
                return Turn(at: Date(timeIntervalSince1970: r[0]), model: models[Int(r[1])],
                            input: Int(r[2]), output: Int(r[3]),
                            cacheWrite: Int(r[4]), cacheRead: Int(r[5]))
            }
            cache[path] = FileCache(modified: Date(timeIntervalSince1970: modified),
                                    size: size,
                                    parsedUpTo: entry["p"] as? Int ?? 0,
                                    turns: turns)
        }
    }

    private func saveDisk() {
        var models: [String] = []
        var index: [String: Int] = [:]
        var files: [String: [String: Any]] = [:]
        for (path, entry) in cache {
            let rows: [[Double]] = entry.turns.map { t in
                let i: Int
                if let hit = index[t.model] { i = hit }
                else { i = models.count; index[t.model] = i; models.append(t.model) }
                return [t.at.timeIntervalSince1970, Double(i), Double(t.input),
                        Double(t.output), Double(t.cacheWrite), Double(t.cacheRead)]
            }
            files[path] = ["m": entry.modified.timeIntervalSince1970, "s": entry.size,
                           "p": entry.parsedUpTo, "t": rows]
        }
        let root: [String: Any] = ["version": 1, "models": models, "files": files]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: Self.diskCache, options: .atomic)
    }

    struct Result: Sendable {
        var trophy: Trophy
        var context: Double?
    }

    func refresh(pricing: Pricing) -> Result {
        loadDisk()
        let fm = FileManager.default
        var seen = Set<String>()
        var all: [Turn] = []
        var changed = false

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

                // Appended to, and the part we already read has not moved: parse only the tail.
                // A rewrite or truncation (size below where we stopped) falls through to a full
                // re-read, because the offsets we hold no longer mean anything.
                if let hit = cache[key], size >= hit.parsedUpTo, hit.parsedUpTo > 0 {
                    let (fresh, end) = Self.parse(url, from: hit.parsedUpTo)
                    let turns = hit.turns + fresh
                    cache[key] = FileCache(modified: modified, size: size,
                                           parsedUpTo: end, turns: turns)
                    all += turns
                    changed = true
                    continue
                }

                let (turns, end) = Self.parse(url, from: 0)
                cache[key] = FileCache(modified: modified, size: size,
                                       parsedUpTo: end, turns: turns)
                all += turns
                changed = true
            }
        }
        // Drop files that have gone away, so the cache cannot grow forever.
        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
            changed = true
        }
        if changed { saveDisk() }

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
    /// Returns the turns found from `offset` onward, and the offset just past the last
    /// **complete** line — a log being written to can end mid-line, and resuming from inside
    /// one would produce garbage on the next sweep.
    private static func parse(_ url: URL, from offset: Int) -> ([Turn], Int) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              offset <= data.count else { return ([], 0) }
        var out: [Turn] = []
        var end = offset

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            let usage = Array("\"usage\"".utf8)
            var lineStart = offset
            var i = offset

            while i < count {
                guard base[i] == 0x0A else { i += 1; continue }
                let length = i - lineStart
                if length > 40, contains(base + lineStart, length, usage) {
                    let slice = Data(bytes: base + lineStart, count: length)
                    if let turn = decode(slice) { out.append(turn) }
                }
                i += 1
                lineStart = i
                end = i                       // only ever advances past a real newline
            }
        }
        return (out, end)
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

        // Integer arithmetic, not Calendar and DateFormatter.
        //
        // The obvious version calls `DateFormatter.string(from:)` and `Calendar.dateInterval`
        // once per turn. At eleven thousand turns that alone accounted for most of a five-second
        // sweep — both are far heavier than they look, and neither is doing anything here that
        // an offset and a division cannot. Only the handful of distinct days that survive ever
        // get formatted.
        let offset = Double(TimeZone.current.secondsFromGMT())
        let nowLocal = Date().timeIntervalSince1970 + offset
        let thisHour = floor(nowLocal / 3600)

        var perModel: [String: (Int, Double)] = [:]
        var perDay: [Int: Double] = [:]
        var perHour: [Int: Double] = [:]

        var latest: (Date, String, Int)?
        for turn in turns {
            let c = pricing.cost(model: turn.model, input: turn.input, output: turn.output,
                                 cacheWrite: turn.cacheWrite, cacheRead: turn.cacheRead)
            t.equivalentUSD += c
            t.tokens.input += turn.input; t.tokens.output += turn.output
            t.tokens.cacheWrite += turn.cacheWrite; t.tokens.cacheRead += turn.cacheRead

            var m = perModel[turn.model] ?? (0, 0); m.0 += 1; m.1 += c; perModel[turn.model] = m

            let local = turn.at.timeIntervalSince1970 + offset
            perDay[Int(floor(local / 86400)), default: 0] += c
            let hour = Int(floor(local / 3600))
            if Double(hour) > thisHour - 24 { perHour[hour, default: 0] += c }

            if latest == nil || turn.at > latest!.0 {
                latest = (turn.at, turn.model, turn.input + turn.cacheWrite + turn.cacheRead)
            }
        }

        t.days = perDay.count
        t.byModel = perModel.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.usd > $1.usd }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        t.byDay = perDay.keys.sorted().map { d in
            (dayFmt.string(from: Date(timeIntervalSince1970: Double(d) * 86400 - offset)),
             perDay[d] ?? 0)
        }
        // Empty hours keep their slot: a gap is information, and closing it up would make a
        // quiet night look busy.
        t.byHour = (0..<24).reversed().map { back in
            let h = Int(thisHour) - back
            return (Date(timeIntervalSince1970: Double(h) * 3600 - offset), perHour[h] ?? 0)
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
    /// offline fallback when the usage endpoint is unreachable.
    ///
    /// Byte-scanned and cached, for the same reason the main parse is: these files run to nine
    /// megabytes each, and the naive String version cost three seconds on every refresh — while
    /// answering a question whose answer changes a few times a week.
    private static var rateLimitCache: (at: Date, value: (resetsAt: Date, kind: String)?)?

    static func lastRateLimit() -> (resetsAt: Date, kind: String)? {
        if let c = rateLimitCache, Date().timeIntervalSince(c.at) < 300 { return c.value }

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
        let needle = Array("quotaLimits".utf8)
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }).prefix(6) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var lineStart = 0, i = 0
                while i <= raw.count {
                    guard i == raw.count || base[i] == 0x0A else { i += 1; continue }
                    let length = i - lineStart
                    if length > 40, contains(base + lineStart, length, needle),
                       let o = try? JSONSerialization.jsonObject(
                           with: Data(bytes: base + lineStart, count: length)) as? [String: Any],
                       let q = o["quotaLimits"] as? [String: Any],
                       let secs = q["resetsAt"] as? Double {
                        let at = Date(timeIntervalSince1970: secs)
                        if best == nil || at > best!.0 {
                            best = (at, q["rateLimitType"] as? String ?? "five_hour")
                        }
                    }
                    i += 1
                    lineStart = i
                }
            }
        }
        rateLimitCache = (Date(), best)
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
