import Foundation

/// Claude Code's own session logs — the source that needs no credentials at all.
///
/// Two jobs: the trophy figures (every turn ever, priced at list) and the live context reading.
///
/// **Nothing keeps individual turns.** An earlier version parsed all eleven thousand of them
/// into an array, held it, and wrote every one into the cache file; a warm refresh peaked at
/// 120 MB and a cold one at 256 MB, for a menu-bar app whose baseline is 11 MB. None of that
/// detail is ever displayed — the interface asks for totals per model, per day, and per hour.
/// So each file is reduced to those buckets as it is read, and only the buckets are kept or
/// stored. Merging two files is adding dictionaries together.
///
/// **This must never touch the main thread.** The tree here is 159 MB and its newest file
/// changes every few seconds while you work. A full re-read on the main actor every refresh is
/// what made the menu bar stop responding to clicks.
actor Transcript {

    static let shared = Transcript()

    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// One file's contribution, already reduced. Keys are absolute — a day number and an hour
    /// number since the epoch in local time — so a cached bucket stays valid as time passes and
    /// merging never needs to re-bucket anything.
    private struct Digest {
        var perModel: [String: (turns: Int, input: Int, output: Int, cacheWrite: Int, cacheRead: Int)] = [:]
        var perDay: [Int: Double] = [:]
        var perHour: [Int: Double] = [:]
        var latest: (at: Date, model: String, contextTokens: Int)?

        mutating func merge(_ other: Digest) {
            for (m, v) in other.perModel {
                var cur = perModel[m] ?? (0, 0, 0, 0, 0)
                cur.turns += v.turns; cur.input += v.input; cur.output += v.output
                cur.cacheWrite += v.cacheWrite; cur.cacheRead += v.cacheRead
                perModel[m] = cur
            }
            for (d, c) in other.perDay { perDay[d, default: 0] += c }
            for (h, c) in other.perHour { perHour[h, default: 0] += c }
            if let o = other.latest, latest == nil || o.at > latest!.at { latest = o }
        }
    }

    private struct FileCache {
        let modified: Date
        let size: Int
        /// Byte offset just past the last complete line parsed. Session logs are appended to
        /// while you work, so the live file changes on every sweep; without this its twenty-odd
        /// megabytes are re-read each time.
        let parsedUpTo: Int
        let digest: Digest
    }

    private var cache: [String: FileCache] = [:]
    private var loadedFromDisk = false
    private var lastSaved = Date.distantPast
    /// Prices are baked into the digest, so a price change has to invalidate it.
    private var pricingStamp = ""

    struct Result: Sendable {
        var trophy: Trophy
        var context: Double?
    }

    // MARK: Sweep

    func refresh(pricing: Pricing) -> Result {
        // Set the stamp before loading: `loadDisk` validates the file against it, and the
        // first call of a fresh process starts with an empty stamp. Comparing before assigning
        // meant that branch always won and the disk cache was never read at all — a cache that
        // was written every launch and loaded on none of them.
        let stamp = Self.stamp(pricing)
        if !pricingStamp.isEmpty, stamp != pricingStamp {
            cache.removeAll()              // prices changed mid-run; stored costs are stale
            loadedFromDisk = true
        }
        pricingStamp = stamp
        loadDisk()

        let fm = FileManager.default
        var seen = Set<String>()
        var total = Digest()
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
                    total.merge(hit.digest)
                    continue
                }

                // Appended to, and the part already read has not moved: parse only the tail.
                // A rewrite or truncation falls through to a full re-read, because the offset
                // we hold no longer means anything.
                if let hit = cache[key], size >= hit.parsedUpTo, hit.parsedUpTo > 0 {
                    var digest = hit.digest
                    let (fresh, end) = Self.digest(url, from: hit.parsedUpTo, pricing: pricing)
                    digest.merge(fresh)
                    cache[key] = FileCache(modified: modified, size: size,
                                           parsedUpTo: end, digest: digest)
                    total.merge(digest)
                    changed = true
                    continue
                }

                let (digest, end) = Self.digest(url, from: 0, pricing: pricing)
                cache[key] = FileCache(modified: modified, size: size,
                                       parsedUpTo: end, digest: digest)
                total.merge(digest)
                changed = true
            }
        }
        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
            changed = true
        }
        if changed { saveDiskThrottled() }

        return Self.assemble(total, pricing: pricing)
    }

    // MARK: Parsing

    /// Reduces one file (or the tail of one) straight into buckets. Returns the offset just past
    /// the last complete line.
    private static func digest(_ url: URL, from offset: Int, pricing: Pricing) -> (Digest, Int) {
        var d = Digest()
        let zone = Double(TimeZone.current.secondsFromGMT())

        let end = LineScanner.scan(url, marker: "\"usage\"", from: offset) { line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>",
                  let u = msg["usage"] as? [String: Any],
                  let ts = o["timestamp"] as? String,
                  let at = ISO8601DateFormatter.parse(ts)
            else { return }

            let input = u["input_tokens"] as? Int ?? 0
            let output = u["output_tokens"] as? Int ?? 0
            let cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = u["cache_read_input_tokens"] as? Int ?? 0

            var m = d.perModel[model] ?? (0, 0, 0, 0, 0)
            m.turns += 1; m.input += input; m.output += output
            m.cacheWrite += cacheWrite; m.cacheRead += cacheRead
            d.perModel[model] = m

            let cost = pricing.cost(model: model, input: input, output: output,
                                    cacheWrite: cacheWrite, cacheRead: cacheRead)
            // Integer arithmetic, not Calendar and DateFormatter: calling either once per turn
            // cost most of a five-second sweep, and neither does anything here that an offset
            // and a division cannot.
            let local = at.timeIntervalSince1970 + zone
            d.perDay[Int(floor(local / 86400)), default: 0] += cost
            d.perHour[Int(floor(local / 3600)), default: 0] += cost

            if d.latest == nil || at > d.latest!.at {
                d.latest = (at, model, input + cacheWrite + cacheRead)
            }
        }
        return (d, end)
    }

    private static func assemble(_ d: Digest, pricing: Pricing) -> Result {
        var t = Trophy()
        var byModel: [(String, Int, Double)] = []

        for (model, v) in d.perModel {
            t.turns += v.turns
            t.tokens.input += v.input; t.tokens.output += v.output
            t.tokens.cacheWrite += v.cacheWrite; t.tokens.cacheRead += v.cacheRead
            let cost = pricing.cost(model: model, input: v.input, output: v.output,
                                    cacheWrite: v.cacheWrite, cacheRead: v.cacheRead)
            t.equivalentUSD += cost
            byModel.append((model, v.turns, cost))
        }
        t.byModel = byModel.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1, $0.2) }
        t.days = d.perDay.count

        let zone = Double(TimeZone.current.secondsFromGMT())
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        t.byDay = d.perDay.keys.sorted().map { day in
            (dayFmt.string(from: Date(timeIntervalSince1970: Double(day) * 86400 - zone)),
             d.perDay[day] ?? 0)
        }
        // Empty hours keep their slot: a gap is information, and closing it up would make a
        // quiet night look busy.
        let thisHour = Int(floor((Date().timeIntervalSince1970 + zone) / 3600))
        t.byHour = (0..<24).reversed().map { back in
            let h = thisHour - back
            return (Date(timeIntervalSince1970: Double(h) * 3600 - zone), d.perHour[h] ?? 0)
        }
        t.subscriptionUSD = pricing.subscriptionMonthlyUSD * Double(max(t.days, 1)) / 30.0

        var ctx: Double?
        if let l = d.latest, Date().timeIntervalSince(l.at) < 6 * 3600 {
            ctx = min(100, Double(l.contextTokens) / contextWindow(for: l.model) * 100)
        }
        return Result(trophy: t, context: ctx)
    }

    private static func contextWindow(for model: String) -> Double {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_CONTEXT_WINDOW"],
           let v = Double(s) { return v }
        return model.contains("haiku") ? 200_000 : 1_000_000
    }

    // MARK: Disk cache

    private static var diskCache: URL {
        // `.first` rather than `[0]`: the array is never empty in practice, but a cache path is
        // not worth a trap if it ever is.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("PWE AI Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript-cache.json")
    }

    /// Prices are folded into the stored costs, so the cache is only valid for the price list
    /// that produced it.
    private static func stamp(_ p: Pricing) -> String {
        p.models.keys.sorted().map { k in
            let r = p.models[k]!
            return "\(k):\(r.input)/\(r.output)/\(r.cacheWriteMultiple)/\(r.cacheReadMultiple)"
        }.joined(separator: "|") + "|sub:\(p.subscriptionMonthlyUSD)"
    }

    private func loadDisk() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.diskCache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 2,
              root["pricing"] as? String == pricingStamp,
              let files = root["files"] as? [String: [String: Any]] else { return }

        for (path, entry) in files {
            guard let modified = entry["m"] as? Double,
                  let size = entry["s"] as? Int else { continue }
            var d = Digest()
            for (model, v) in (entry["models"] as? [String: [Int]] ?? [:]) where v.count == 5 {
                d.perModel[model] = (v[0], v[1], v[2], v[3], v[4])
            }
            for (k, v) in (entry["days"] as? [String: Double] ?? [:]) {
                if let key = Int(k) { d.perDay[key] = v }
            }
            for (k, v) in (entry["hours"] as? [String: Double] ?? [:]) {
                if let key = Int(k) { d.perHour[key] = v }
            }
            if let l = entry["latest"] as? [String: Any],
               let at = l["at"] as? Double, let model = l["model"] as? String,
               let ctx = l["ctx"] as? Int {
                d.latest = (Date(timeIntervalSince1970: at), model, ctx)
            }
            cache[path] = FileCache(modified: Date(timeIntervalSince1970: modified),
                                    size: size, parsedUpTo: entry["p"] as? Int ?? 0, digest: d)
        }
    }

    /// Throttled hard. The live session file changes on every sweep, so an unconditional save
    /// rewrites the cache every twenty seconds for something whose only job is to make the
    /// *next launch* fast. Five minutes is far more often than launches happen.
    private func saveDiskThrottled(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 300 else { return }
        lastSaved = Date()
        var files: [String: Any] = [:]
        for (path, entry) in cache {
            var e: [String: Any] = ["m": entry.modified.timeIntervalSince1970,
                                    "s": entry.size, "p": entry.parsedUpTo]
            e["models"] = entry.digest.perModel.mapValues {
                [$0.turns, $0.input, $0.output, $0.cacheWrite, $0.cacheRead]
            }
            e["days"] = Dictionary(uniqueKeysWithValues: entry.digest.perDay.map { (String($0.key), $0.value) })
            e["hours"] = Dictionary(uniqueKeysWithValues: entry.digest.perHour.map { (String($0.key), $0.value) })
            if let l = entry.digest.latest {
                e["latest"] = ["at": l.at.timeIntervalSince1970, "model": l.model, "ctx": l.contextTokens]
            }
            files[path] = e
        }
        let root: [String: Any] = ["version": 2, "pricing": pricingStamp, "files": files]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: Self.diskCache, options: .atomic)
    }

    /// Write the cache out now, throttle or no throttle. Called on quit.
    func flush() { saveDiskThrottled(force: true) }

    // MARK: Rate limit fallback

    /// The most recent 429 — the only place a real reset time is recorded locally, and the
    /// offline fallback when the usage endpoint is unreachable. Cached: these files run to nine
    /// megabytes each, and the answer changes a few times a week.
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
        // Only the tail of each file. A rate limit you hit days ago is not the one you are
        // waiting out, and reading these logs end to end for it cost 88 MB.
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }).prefix(6) {
            LineScanner.scanTail(url, marker: "quotaLimits", tailBytes: 4 << 20) { line in
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let q = o["quotaLimits"] as? [String: Any],
                      let secs = q["resetsAt"] as? Double else { return }
                let at = Date(timeIntervalSince1970: secs)
                if best == nil || at > best!.0 {
                    best = (at, q["rateLimitType"] as? String ?? "five_hour")
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
