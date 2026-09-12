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

    /// Codex writes its own rollout logs, and until 1.4.0 nothing read them for usage: the Codex
    /// provider opens the same files but only ever looks at `rate_limits`, which is the quota bar
    /// and nothing else. So every turn spent in gpt-6-astra, gpt-5.6-sol or gpt-5.6-luna was
    /// invisible — not merely unpriced, absent: no model row, no turns, no tokens.
    private static let codexRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    /// The two logs are different formats, so each needs its own reducer; everything downstream
    /// works on the buckets they both produce.
    private enum Source: CaseIterable {
        case claude, codex
        var root: URL { self == .claude ? Transcript.root : Transcript.codexRoot }
    }

    /// One file's contribution, already reduced. Keys are absolute — a day number and an hour
    /// number since the epoch in local time — so a cached bucket stays valid as time passes and
    /// merging never needs to re-bucket anything.
    /// One model's contribution to one day.
    struct Counts: Equatable {
        var turns = 0, input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var usd = 0.0
        static func += (l: inout Counts, r: Counts) {
            l.turns += r.turns; l.input += r.input; l.output += r.output
            l.cacheWrite += r.cacheWrite; l.cacheRead += r.cacheRead; l.usd += r.usd
        }
    }

    struct Digest {
        /// Day number → model → counts. Kept two-dimensional so the trophy page can be asked
        /// for a date range: totals per model and per token kind used to be a single all-time
        /// sum, which meant a range could only ever have moved the headline figures while
        /// "by model" and "Token" silently stayed all-time — more confusing than not offering
        /// a range at all. Bounded by days × models, which is a few thousand rows at worst.
        var perDayModel: [Int: [String: Counts]] = [:]
        var perHour: [Int: Double] = [:]
        var latest: (at: Date, model: String, contextTokens: Int)?

        mutating func add(day: Int, model: String, _ c: Counts) {
            perDayModel[day, default: [:]][model, default: Counts()] += c
        }

        mutating func merge(_ other: Digest) {
            for (day, models) in other.perDayModel {
                for (m, v) in models { perDayModel[day, default: [:]][m, default: Counts()] += v }
            }
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
        /// Codex only: root turn id → model.
        ///
        /// The model is named once in a `turn_context` line and the turns that follow carry only
        /// the id, so a tail parse starting past that line has nothing to attribute to. Sessions
        /// here run to hundreds of megabytes with a handful of context lines in them, so carrying
        /// the map is a few entries per file and re-reading to find it is not an option.
        var models: [String: String] = [:]
    }

    private var cache: [String: FileCache] = [:]
    private var loadedFromDisk = false
    private var lastSaved = Date.distantPast
    /// Prices are baked into the digest, so a price change has to invalidate it.
    private var pricingStamp = ""

    struct Result: Sendable {
        var trophy: Trophy
        var context: Double?
        /// When the newest turn landed. The refresh loop uses it to tell "you are working" from
        /// "you walked away", which the context reading cannot: that one stays valid for six
        /// hours, so keying the fast cadence off it kept a laptop polling every twenty seconds
        /// for most of an afternoon after the last thing you typed.
        var lastTurnAt: Date?
    }

    // MARK: Sweep

    func refresh(pricing: Pricing, range: TrophyRange = .all,
                 subscription: Subscription? = nil) -> Result {
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

        for source in Source.allCases {
            guard let e = fm.enumerator(at: source.root,
                                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
              autoreleasepool {
                let key = url.path
                seen.insert(key)
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = rv?.contentModificationDate ?? .distantPast
                let size = rv?.fileSize ?? 0

                if let hit = cache[key], hit.modified == modified, hit.size == size {
                    total.merge(hit.digest)
                    return
                }

                /// One file, from an offset, with whatever the last pass learned about it.
                func read(from offset: Int, carrying models: [String: String])
                    -> (Digest, Int, [String: String]) {
                    switch source {
                    case .claude:
                        let (d, end) = Self.digest(url, from: offset, pricing: pricing)
                        return (d, end, [:])
                    case .codex:
                        var known = models
                        let (d, end) = Self.codexDigest(url, from: offset, pricing: pricing,
                                                        models: &known)
                        return (d, end, known)
                    }
                }

                // Appended to, and the part already read has not moved: parse only the tail.
                // A rewrite or truncation falls through to a full re-read, because the offset
                // we hold no longer means anything.
                if let hit = cache[key], size >= hit.parsedUpTo, hit.parsedUpTo > 0 {
                    var digest = hit.digest
                    let (fresh, end, models) = read(from: hit.parsedUpTo, carrying: hit.models)
                    digest.merge(fresh)
                    cache[key] = FileCache(modified: modified, size: size,
                                           parsedUpTo: end, digest: digest, models: models)
                    total.merge(digest)
                    changed = true
                    return
                }

                let (digest, end, models) = read(from: 0, carrying: [:])
                cache[key] = FileCache(modified: modified, size: size,
                                       parsedUpTo: end, digest: digest, models: models)
                total.merge(digest)
                changed = true
              }
            }
        }
        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
            changed = true
        }
        if changed { saveDiskThrottled() }

        return Self.assemble(total, pricing: pricing, range: range, subscription: subscription)
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

            let cost = pricing.cost(model: model, input: input, output: output,
                                    cacheWrite: cacheWrite, cacheRead: cacheRead)
            // Integer arithmetic, not Calendar and DateFormatter: calling either once per turn
            // cost most of a five-second sweep, and neither does anything here that an offset
            // and a division cannot.
            let local = at.timeIntervalSince1970 + zone
            d.add(day: Int(floor(local / 86400)), model: model,
                  Counts(turns: 1, input: input, output: output,
                         cacheWrite: cacheWrite, cacheRead: cacheRead, usd: cost))
            d.perHour[Int(floor(local / 3600)), default: 0] += cost

            if d.latest == nil || at > d.latest!.at {
                d.latest = (at, model, input + cacheWrite + cacheRead)
            }
        }
        return (d, end)
    }

    /// Reduces one Codex rollout into the same buckets.
    ///
    /// Two line kinds matter and they are written apart from each other: `turn_context` names the
    /// model and a `root_turn_id`, and every `token_usage_record` that follows carries that id and
    /// the tokens. `models` is the correlation, carried in and out so a tail parse can still
    /// attribute turns whose context line is behind the offset.
    ///
    /// The marker pre-filters on the two leading characters the type shares — `token_count` and
    /// `text_result` come through it too and are dropped here. It is worth being narrow: this tree
    /// is 5.5 GB on the machine this was written on, with single sessions near a gigabyte.
    ///
    /// **`latest` is deliberately not set.** It feeds the context reading, and the size of a
    /// context window is a Claude question — letting a Codex turn win the "newest turn" race
    /// would measure a gpt model against Claude's window and print a percentage of nothing.
    ///
    /// Older sessions carry no `token_usage_record` at all; they contribute nothing rather than
    /// guessing, which is why the totals begin partway through the history.
    static func codexDigest(_ url: URL, from offset: Int, pricing: Pricing,
                                    models: inout [String: String]) -> (Digest, Int) {
        var d = Digest()
        let zone = Double(TimeZone.current.secondsFromGMT())
        var known = models

        let end = LineScanner.scan(url, marker: "\"type\":\"t", from: offset) { line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = o["type"] as? String,
                  let payload = o["payload"] as? [String: Any] else { return }

            if kind == "turn_context" {
                if let model = payload["model"] as? String,
                   let id = payload["root_turn_id"] as? String {
                    known[id] = model
                }
                return
            }
            guard kind == "token_usage_record",
                  let id = payload["root_turn_id"] as? String,
                  let model = known[id],
                  let usage = (payload["turn_token_usage"] ?? payload["usage"]) as? [String: Any],
                  let ts = o["timestamp"] as? String,
                  let at = ISO8601DateFormatter.parse(ts)
            else { return }

            // `input_tokens` here is the whole prompt, cached part included — unlike Claude's,
            // where the cached read is reported beside the input rather than inside it. Counting
            // both would bill the cache twice.
            let cachedIn = usage["cached_input_tokens"] as? Int ?? 0
            let input = max((usage["input_tokens"] as? Int ?? 0) - cachedIn, 0)
            let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0

            // Zero for every model Codex runs: the price list is Anthropic's catalogue and has no
            // OpenAI rates in it. The trophy already says so rather than implying the work was
            // free — inventing a number for the headline figure would be worse than admitting
            // there isn't one.
            let cost = pricing.cost(model: model, input: input, output: output,
                                    cacheWrite: cacheWrite, cacheRead: cachedIn)
            let local = at.timeIntervalSince1970 + zone
            d.add(day: Int(floor(local / 86400)), model: model,
                  Counts(turns: 1, input: input, output: output,
                         cacheWrite: cacheWrite, cacheRead: cachedIn, usd: cost))
            d.perHour[Int(floor(local / 3600)), default: 0] += cost
        }
        models = known
        return (d, end)
    }

    static func assemble(_ d: Digest, pricing: Pricing, range: TrophyRange,
                                 subscription: Subscription?) -> Result {
        var t = Trophy()
        let zone = Double(TimeZone.current.secondsFromGMT())
        let today = Int(floor((Date().timeIntervalSince1970 + zone) / 86400))
        // The range is counted in calendar days back from today, not in active days: "last 7
        // days" has to mean the same span whether you worked all seven of them or two.
        let days: [Int]
        if let back = range.days {
            let cutoff = today - back
            days = d.perDayModel.keys.filter { $0 > cutoff }
        } else {
            days = Array(d.perDayModel.keys)
        }

        var perModel: [String: Counts] = [:]
        var perDay: [Int: Double] = [:]
        for day in days {
            for (model, v) in d.perDayModel[day] ?? [:] {
                perModel[model, default: Counts()] += v
                perDay[day, default: 0] += v.usd
            }
        }

        var byModel: [(String, Int, Double)] = []
        for (model, v) in perModel {
            t.turns += v.turns
            t.tokens.input += v.input; t.tokens.output += v.output
            t.tokens.cacheWrite += v.cacheWrite; t.tokens.cacheRead += v.cacheRead
            t.equivalentUSD += v.usd
            byModel.append((model, v.turns, v.usd))
        }
        t.byModel = byModel.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1, $0.2) }
        // Active days within the range, which is what the amortised subscription is charged
        // against — a range with two working days in it did not cost you seven days of plan.
        t.days = perDay.count
        t.range = range

        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        t.byDay = perDay.keys.sorted().map { day in
            (dayFmt.string(from: Date(timeIntervalSince1970: Double(day) * 86400 - zone)),
             perDay[day] ?? 0)
        }
        // Empty hours keep their slot: a gap is information, and closing it up would make a
        // quiet night look busy.
        let thisHour = Int(floor((Date().timeIntervalSince1970 + zone) / 3600))
        t.byHour = (0..<24).reversed().map { back in
            let h = thisHour - back
            return (Date(timeIntervalSince1970: Double(h) * 3600 - zone), d.perHour[h] ?? 0)
        }
        if let subscription {
            t.subscriptionUSD = subscription.monthlyUSD * Double(max(t.days, 1)) / 30.0
            t.subscriptionMonthly = subscription
        }

        var ctx: Double?
        if let l = d.latest, Date().timeIntervalSince(l.at) < 6 * 3600 {
            ctx = min(100, Double(l.contextTokens) / contextWindow(for: l.model) * 100)
        }
        return Result(trophy: t, context: ctx, lastTurnAt: d.latest?.at)
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
              root["version"] as? Int == 4,
              root["pricing"] as? String == pricingStamp,
              let files = root["files"] as? [String: [String: Any]] else { return }

        for (path, entry) in files {
            guard let modified = entry["m"] as? Double,
                  let size = entry["s"] as? Int else { continue }
            var d = Digest()
            for (dayKey, models) in (entry["daymodels"] as? [String: [String: [Double]]] ?? [:]) {
                guard let day = Int(dayKey) else { continue }
                for (model, v) in models where v.count == 6 {
                    d.perDayModel[day, default: [:]][model] = Counts(
                        turns: Int(v[0]), input: Int(v[1]), output: Int(v[2]),
                        cacheWrite: Int(v[3]), cacheRead: Int(v[4]), usd: v[5])
                }
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
                                    size: size, parsedUpTo: entry["p"] as? Int ?? 0, digest: d,
                                    models: entry["models"] as? [String: String] ?? [:])
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
            if !entry.models.isEmpty { e["models"] = entry.models }
            e["daymodels"] = Dictionary(uniqueKeysWithValues: entry.digest.perDayModel.map {
                (String($0.key), $0.value.mapValues {
                    [Double($0.turns), Double($0.input), Double($0.output),
                     Double($0.cacheWrite), Double($0.cacheRead), $0.usd]
                })
            })
            e["hours"] = Dictionary(uniqueKeysWithValues: entry.digest.perHour.map { (String($0.key), $0.value) })
            if let l = entry.digest.latest {
                e["latest"] = ["at": l.at.timeIntervalSince1970, "model": l.model, "ctx": l.contextTokens]
            }
            files[path] = e
        }
        let root: [String: Any] = ["version": 4, "pricing": pricingStamp, "files": files]
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
