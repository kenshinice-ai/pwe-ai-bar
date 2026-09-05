import Foundation

/// A short, bounded record of how each quota window has actually filled.
///
/// Everything else in this app is a reading of right now. This is the one place that remembers,
/// and it exists for a single reason: "how fast am I going" cannot be answered from one number.
/// Dividing the percentage by the time since the window opened gives the average over the whole
/// window, which is the wrong answer to the question people are actually asking — an hour of
/// heavy Opus after three quiet hours reads as a gentle pace right up until it stops you.
///
/// Deliberately small and deliberately disposable. It lives in Caches, it is capped per window,
/// it drops everything older than the window it belongs to, and losing it costs one thing: the
/// pace falls back to the whole-window average until a few samples land. Nothing here is worth
/// recovering, so nothing here is treated as precious.
actor History {
    static let shared = History()

    struct Sample: Codable, Equatable {
        let at: Date
        let percent: Double
    }

    /// Fifty samples spans a five-hour window at one every six minutes, which is finer than the
    /// refresh cadence ever gets when idle. Past that the oldest go first.
    private static let cap = 50
    /// Two readings a minute apart are the same reading. Recording both wastes the ring on a
    /// stretch of time where nothing happened.
    private static let quiet: TimeInterval = 55

    private let url: URL
    private let now: () -> Date
    private var samples: [String: [Sample]] = [:]
    private var loaded = false
    private var dirty = false
    private var savedAt: Date?

    init(url: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.url = url ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("PWE AI Bar/history.json")
    }

    static func key(_ w: QuotaWindow) -> String { "\(w.provider.rawValue):\(w.id)" }

    /// Records what each window reads now, and returns the same windows with a measured pace
    /// attached where there is enough history to measure one.
    func observe(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        load()
        let date = now()
        defer { autosave() }
        return windows.map { window in
            guard let percent = window.percent, !window.isStale,
                  window.observedAt <= date else { return window }
            let key = Self.key(window)
            var ring = samples[key] ?? []

            // A window that rolled over starts again: its old samples describe a different
            // window that happens to share a name, and averaging across the boundary would
            // report a pace that never happened.
            if let start = window.windowStart(at: date) {
                ring.removeAll { $0.at < start }
            }
            if let last = ring.last {
                // Going backwards means the window rolled over. Everything before it belongs to
                // a window that no longer exists.
                if percent < last.percent - 0.5 { ring.removeAll() }
                // A leap this large in this little observed time is not consumption, it is the
                // reading changing provenance — a cached figure being replaced by a live one,
                // which is exactly what happened the first time this ran: 20 % to 91 % in four
                // seconds. Recorded as a slope that is a rate of 60,000 %/h and a projection of
                // "empty in two minutes". A discontinuity restarts the record; it is never a
                // measurement of anything.
                else if percent - last.percent >= 25,
                        window.observedAt.timeIntervalSince(last.at) < 60 {
                    ring.removeAll()
                }
            }

            if let last = ring.last {
                // Replaying a cached reading is not a new observation, however long ago the
                // last one was recorded. Only a genuinely newer observation earns a sample.
                if window.observedAt > last.at,
                   date.timeIntervalSince(last.at) >= Self.quiet || abs(percent - last.percent) >= 0.5 {
                    ring.append(Sample(at: window.observedAt, percent: percent))
                }
            } else {
                ring.append(Sample(at: window.observedAt, percent: percent))
            }
            if ring.count > Self.cap { ring.removeFirst(ring.count - Self.cap) }

            if ring != samples[key] { samples[key] = ring; dirty = true }
            var out = window
            out.samples = ring
            return out
        }
    }

    /// Called from `observe` so the ring survives a crash without a caller having to remember.
    /// Throttled: this is a cache of a cache and does not deserve a write every twenty seconds.
    private func autosave() { flush() }

    /// Throttled, and only ever from `observe`'s caller. This is a cache of a cache.
    func flush(force: Bool = false) {
        guard dirty else { return }
        if !force, let savedAt, now().timeIntervalSince(savedAt) < 300 { return }
        let payload = samples.mapValues { ring in
            ring.map { ["at": $0.at.timeIntervalSince1970, "percent": $0.percent] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "windows": payload])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        savedAt = now()
        dirty = false
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 1,
              let windows = root["windows"] as? [String: [[String: Any]]] else { return }
        let date = now()
        for (key, rows) in windows {
            let ring = rows.compactMap { row -> Sample? in
                guard let at = row["at"] as? Double, at.isFinite,
                      let percent = row["percent"] as? Double,
                      percent.isFinite, percent >= 0, percent <= 100 else { return nil }
                let stamp = Date(timeIntervalSince1970: at)
                // A sample from the future is a clock that moved, not a reading.
                guard stamp <= date, date.timeIntervalSince(stamp) < 8 * 86400 else { return nil }
                return Sample(at: stamp, percent: percent)
            }.sorted { $0.at < $1.at }
            if !ring.isEmpty { samples[key] = Array(ring.suffix(Self.cap)) }
        }
    }
}
