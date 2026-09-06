import Foundation

/// What one quota window is going to do, decided in one place.
///
/// This is what the app is for. Every other quota bar reports how much is gone; this answers
/// "at this pace, do I get to the reset" — and the whole difficulty is answering it without
/// inventing precision the readings do not carry.
///
/// Three things make that possible, and they are all consequences of one observation:
/// **the readings are integers.** Claude's `utilization` and Codex's `usedPercent` both arrive
/// as whole percents, and the recorded history on a real machine shows long flat stretches at
/// a single value. The error is not noise, it is quantisation — so a regression, an EWMA or a
/// Kalman filter would all be spending their effort averaging away an ε that does not exist.
///
///   1. **The rate is a bracket, not a number.** Two readings a quarter-hour apart differing by
///      one percent are consistent with anything from nothing at all to eight percent an hour.
///      Both ends are computed and both are honest; the width of the bracket *is* the
///      uncertainty, so no confidence parameter has to be invented for it.
///   2. **Every verdict is one-sided.** "You will not make it" is only said when even the
///      slowest rate the readings allow runs the tank dry first; "you will" only when even the
///      fastest gets there. Anything in between is said to be in between.
///   3. **Precision is floored, never fitted.** The headline duration is the *guaranteed* one,
///      snapped down to a grain matched to its own size, so "1 小时 17 分" cannot be printed
///      from three samples — not as a matter of discipline, but because the number that would
///      say it does not exist.
///
/// The copy table lives here too, colour included. It used to live in the view as four
/// if-chains, which is how "we cannot tell you" ended up rendering in the same grey as
/// "you are fine" — the panel's one-second channel is *is there red on the right*, and a state
/// with no colour assigned is a state that reads as good news.
struct Forecast: Equatable {
    /// Percent per hour, as an interval. Both ends are bounds, never a fit.
    struct Rate: Equatable {
        let low: Double
        let high: Double
    }

    /// Where the bracket came from. Not a quality score — two different questions.
    /// `samples` answers "how fast am I going now"; `windowAverage` answers "how fast has this
    /// window gone overall", which is a gentler and less useful number that must never be
    /// allowed to impersonate the first one.
    enum Evidence: Equatable {
        case samples(span: TimeInterval)
        case windowAverage(elapsed: TimeInterval)

        var isMeasured: Bool { if case .samples = self { return true }; return false }
        var span: TimeInterval {
            switch self {
            case .samples(let s): return s
            case .windowAverage(let e): return e
            }
        }
    }

    /// Why there is no forecast. Diagnostic only — it reaches the self-check and VoiceOver and
    /// never the panel, because five different reasons to wait are still one instruction.
    enum Thinness: String, Equatable {
        case noPercent, noWindowLength, noSamples, spanTooShort, readingTooOld, tooEarlyInWindow
    }

    enum NoTimeline: String, Equatable {
        case noReset, resetPassed
    }

    /// The seven outcomes a person can tell apart and act differently on.
    enum Verdict: Equatable {
        case spent
        case fallsShort(gap: TimeInterval)
        case tooClose
        case makesIt(spare: Double)
        case sampling
        case blind(since: TimeInterval)
        case noTimeline(NoTimeline)
    }

    /// Which of the three colour bands the verdict belongs to. Assigned here so that a new
    /// verdict cannot be added without deciding whether it is news.
    enum Tone: Equatable {
        case hot    // you are out, or you will be
        case warm   // we cannot tell you, or we cannot see
        case plain  // nothing to report
    }

    let verdict: Verdict
    let tone: Tone
    /// now → reset. Nil only when there is no timeline to draw.
    let trip: TimeInterval?
    let rate: Rate?
    let evidence: Evidence?
    /// Running time at the fastest rate the readings allow: a floor, and the only duration
    /// this app is willing to print.
    let enduranceLow: TimeInterval?
    /// Running time at the slowest rate they allow. Infinite when the readings admit standing
    /// still, which is exactly why `.fallsShort` then cannot be claimed.
    let enduranceHigh: TimeInterval?
    let thinness: Thinness?
    /// Whether a long silence is the app failing to read or simply nobody using the tool. Only
    /// the first one has a remedy, and only the first one is allowed to name it.
    var unreadable: Bool = false

    // MARK: The one entry point

    static func make(_ w: QuotaWindow, at now: Date) -> Forecast {
        let trip = w.resetsAt.map { $0.timeIntervalSince(now) }.flatMap { $0 > 0 ? $0 : nil }
        let age = now.timeIntervalSince(w.observedAt)

        // Ordered before everything, including the timeline checks, and that order was found by
        // an adversarial pass rather than by reasoning: a window nobody has been able to read
        // for eighteen hours has usually drifted past its own reset too, so a timeline check
        // that runs first swallows it and prints 「已过重置时间，等新读数确认」 — the one screen
        // where waiting is exactly the wrong advice. Age is also the trigger rather than the
        // stale flag: not every provider sets it, and how long ago a reading was taken is a fact
        // that needs no flag to be true.
        if age > blindAfter {
            return bare(.blind(since: age), tone: .warm, trip: trip, stale: w.isStale)
        }
        guard let reset = w.resetsAt else { return bare(.noTimeline(.noReset), tone: .plain) }
        guard let trip, reset > now else { return bare(.noTimeline(.resetPassed), tone: .plain) }

        // The fact outranks every estimate. A spent window has no endurance to compute, and
        // asking for one would put it through the branch that means "we could not measure this"
        // — over the one window we are most certain about.
        if w.confirmedExhausted { return bare(.spent, tone: .hot, trip: trip) }

        guard let percent = w.percent else {
            return bare(.sampling, tone: .plain, trip: trip, thinness: .noPercent)
        }
        // A reading we could not take is not a reading, whichever branch would have produced the
        // number. This guard used to live only in the averaging fallback, so a window marked
        // stale still handed back a confident *measured* rate from its samples — and the
        // instrument above it drew that rate as a solid mark.
        guard !w.isStale, age <= staleAfter else {
            return bare(.sampling, tone: .plain, trip: trip, thinness: .readingTooOld)
        }

        let read = rate(w, at: now, trip: trip, percent: percent)
        guard let rate = read.rate, let evidence = read.evidence else {
            return bare(.sampling, tone: .plain, trip: trip, thinness: read.thinness)
        }

        let remaining = max(0, 100 - percent)
        let low = remaining / rate.high * 3600                       // rate.high > 0 by construction
        let high = rate.low > 0 ? remaining / rate.low * 3600 : .infinity
        // Both ends are computed over the same stretch the verdict is compared against, so
        // `.makesIt` implying a non-negative landing is an identity rather than something that
        // has to be clamped afterwards. Anchoring the landing at `observedAt` while comparing
        // the endurance against `now` is a quarter-hour of drift between two halves of one
        // sentence, and it prints 「到点至少剩 -2%」 in the reassuring grey.
        let landingHigh = percent + rate.high * (trip / 3600)

        // How much of the trip the evidence is actually entitled to speak about.
        //
        // The bracket bounds the rate over the stretch that was *observed*. It says nothing
        // whatever about the six days after it — shut the lid and the true rate is zero. So the
        // one verdict that turns a rate into a red claim about the far future has to show that
        // it watched a meaningful part of the journey it is judging. Fifteen minutes of a weekly
        // window is a real reading and a worthless prophecy; it earns 「临界，说不准」, not
        // 「缺口 5 天以上」.
        //
        // Only the shortfall is gated. The other side needs no guard: thin evidence widens the
        // bracket, a wide bracket has a fast end, and a fast end cannot reach `.makesIt`.
        let watched = min(read.horizon, trip) / 4

        let verdict: Verdict
        let tone: Tone
        if high < trip, evidence.span >= watched {
            verdict = .fallsShort(gap: Forecast.floorToGrain(trip - high)); tone = .hot
        } else if low >= trip {
            verdict = .makesIt(spare: max(0, 100 - landingHigh)); tone = .plain
        } else {
            verdict = .tooClose; tone = .warm
        }

        return Forecast(verdict: verdict, tone: tone, trip: trip, rate: rate, evidence: evidence,
                        enduranceLow: low, enduranceHigh: high, thinness: nil)
    }

    /// A reading older than this is not current enough to project from. Matches what the alert
    /// rules already treat as live.
    static let staleAfter: TimeInterval = 600
    /// Past this, a reading we could not refresh stops being "a bit behind" and becomes a thing
    /// to go and fix. Two missed cycles at the slowest poll cadence.
    static let blindAfter: TimeInterval = 1800
    /// The shortest stretch of samples worth calling a measurement.
    static let shortestSpan: TimeInterval = 600

    private static func bare(_ verdict: Verdict, tone: Tone, trip: TimeInterval? = nil,
                             thinness: Thinness? = nil, stale: Bool = false) -> Forecast {
        Forecast(verdict: verdict, tone: tone, trip: trip, rate: nil, evidence: nil,
                 enduranceLow: nil, enduranceHigh: nil, thinness: thinness, unreadable: stale)
    }

    // MARK: The estimator

    /// The bracket, and where it came from.
    ///
    /// `low` and `high` bound the true rate rather than estimating it. A reading of `p` means the
    /// true value is somewhere within one step of `p` — which holds whether the provider rounds
    /// or truncates — so a change of `Δp` over `S` hours is a true change strictly inside
    /// `(Δp − 1, Δp + 1)`, and dividing by `S` carries that straight through.
    ///
    /// Three consequences fall out of the one formula, and all three are wanted:
    ///
    ///   * A flat stretch gives `[0, 1/S]`: no lower bound at all, and an upper bound that gets
    ///     tighter the longer nothing happens. That is the correct reading of "nothing moved" —
    ///     it is evidence of slowness, not absence of evidence.
    ///   * A single step gives a lower bound of zero, so one step can never license "you will
    ///     run out". It takes two to make that claim.
    ///   * A burst decays on its own. The oldest sample in the horizon stays put while the
    ///     newest advances, so `S` grows against a fixed `Δp` and the rate falls back without
    ///     anyone having to age anything out.
    private static func rate(_ w: QuotaWindow, at now: Date, trip: TimeInterval, percent: Double)
        -> (rate: Rate?, evidence: Evidence?, thinness: Thinness?, horizon: TimeInterval) {
        // How far back to measure, scaled to what is being decided. Too long and a burst is
        // averaged back into the quiet hours before it; too short and one heavy turn becomes the
        // whole sample, and a weekly window starts projecting from four minutes of evidence.
        //
        // The floor is applied last, and it is twice the shortest usable span rather than equal
        // to it. With the two the same size the branch was arithmetically unreachable in the
        // last forty minutes before every reset — a window of samples exactly ten minutes wide
        // can only contain a stretch of *less* than ten minutes — so the instrument fell back to
        // the whole-window average precisely when the question stops being hypothetical.
        let scaled = min(max(trip / 4, 2 * shortestSpan), (w.windowLength ?? 3600) / 4)
        let horizon = max(scaled, 2 * shortestSpan)
        // Anchored to the newest reading rather than to the clock. Anchored to `now`, the oldest
        // sample slides out of the window between one frame and the next, so the rate steps
        // while nothing at all has been observed.
        let newest = w.samples.filter { $0.at <= now }.map(\.at).max() ?? now
        let recent = dedupe(w.samples.filter { newest.timeIntervalSince($0.at) <= horizon && $0.at <= now })
        if let first = recent.first, let last = recent.last, recent.count >= 2 {
            let span = last.at.timeIntervalSince(first.at)
            if span >= shortestSpan {
                let climb = last.percent - first.percent
                let hours = span / 3600
                return (Rate(low: max(0, climb - 1) / hours, high: (climb + 1) / hours),
                        .samples(span: span), nil, horizon)
            }
        }

        // The fallback answers a different question and is labelled as one everywhere it shows.
        // Its own bracket comes from the same quantisation: the percentage is an integer too.
        guard let length = w.windowLength, let start = w.windowStart(at: now) else {
            return (nil, nil, w.windowLength == nil ? .noWindowLength : .noSamples, horizon)
        }
        let elapsed = w.observedAt.timeIntervalSince(start)
        // Ten minutes into a five-hour window, two turns extrapolate to anything at all.
        guard elapsed > max(300, length * 0.05) else {
            return (nil, nil, .tooEarlyInWindow, horizon)
        }
        let hours = elapsed / 3600
        return (Rate(low: max(0, percent - 1) / hours, high: (percent + 1) / hours),
                .windowAverage(elapsed: elapsed),
                nil, horizon)
    }

    /// Real history carries repeated timestamps — the cache on this machine has three pairs of
    /// them — and a repeated timestamp is a zero-length span waiting to divide by nothing.
    /// Later readings win: an observation is not corrected by an older copy of itself.
    static func dedupe(_ samples: [History.Sample]) -> [History.Sample] {
        var out: [History.Sample] = []
        for s in samples.sorted(by: { $0.at < $1.at }) {
            if let last = out.last, last.at == s.at { out[out.count - 1] = s } else { out.append(s) }
        }
        return out
    }

    // MARK: What the panel says

    /// The duration in the largest type: whichever of the two is actually going to happen.
    ///
    /// Endurance past the reset is hypothetical — the window rolls over and refills long before
    /// the tank would run dry — so a two-hour window headlining 13 小时 40 分 would be describing
    /// uninterrupted running time nobody is ever going to get. Keyed on which number won, never
    /// on the verdict: under `.makesIt` the endurance is *by definition* the larger of the two,
    /// so a verdict-keyed rule prints the hypothetical figure every time it says you are fine.
    var headline: TimeInterval? {
        guard let trip else { return nil }
        guard let low = enduranceLow, low < trip else { return trip }
        return Forecast.floorToGrain(low)
    }

    var headlineIsEndurance: Bool {
        guard let trip, let low = enduranceLow else { return false }
        return low < trip
    }

    /// Left of the heading row. Says which number is in the big slot, so the label and the
    /// figure can never point at different moments.
    var headingLeft: String {
        if trip == nil { return "" }
        return headlineIsEndurance ? "至少能跑" : "到重置"
    }

    /// Right of the heading row: the rate, and the stretch it was measured over. A rate with no
    /// span behind it is a claim; with one it is a reading.
    var paceText: String? {
        guard let rate, let evidence else { return nil }
        let mid = (rate.low + rate.high) / 2
        let stretch = evidence.isMeasured ? "最近 \(Forecast.span(evidence.span))" : "开窗以来"
        return "\(stretch) 耗速 \(Forecast.percentPerHour(mid))%/时"
    }

    /// The one line that is allowed to be coloured, and the only place the verdict is stated.
    /// It never restates the headline: the big number carries the duration, and this carries
    /// what the duration cannot say.
    var verdictText: String {
        switch verdict {
        case .spent: return "已用尽"
        case .fallsShort(let gap): return "缺口 \(Forecast.span(gap))"
        case .tooClose: return "临界，说不准"
        case .makesIt(let spare): return "到点至少剩 \(Int(spare.rounded(.down)))%"
        case .sampling: return "还在采样"
        case .blind(let since): return "\(Forecast.span(since))没有新读数"
        case .noTimeline(.noReset): return "这个额度没有重置时间，算不出续航"
        case .noTimeline(.resetPassed): return "已过重置时间，等新读数确认"
        }
    }

    var hasTimeline: Bool { trip != nil }

    /// Spoken in full, where a whole sentence costs nothing.
    var spoken: String {
        guard let trip else { return verdictText }
        let head = headlineIsEndurance
            ? "按最快的估计还能跑 \(Forecast.span(headline ?? 0))"
            : "到重置还有 \(Forecast.span(trip))"
        var out = [head]
        if let pace = paceText { out.append(pace) }
        out.append(verdictText)
        if case .blind = verdict, unreadable { out.append("先把连接修好") }
        if let thinness { out.append("原因：\(thinness.rawValue)") }
        return out.joined(separator: "，")
    }

    // MARK: Formatting

    /// Grain matched to the size of the figure, and always rounded **down**, so the printed
    /// duration stays a floor and the sentence can honestly say 至少. This is what makes
    /// 1 小时 17 分 structurally unprintable from thin evidence rather than merely discouraged.
    static func floorToGrain(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let grain: TimeInterval
        switch seconds {
        case ..<3600: grain = 300
        case ..<21600: grain = 900
        case ..<86400: grain = 3600
        default: grain = 21600
        }
        // Below the finest grain there is nothing to round away, and rounding *up* to reach it
        // would turn the floor into a claim — the one thing this function exists to prevent.
        guard seconds >= grain else { return seconds }
        return (seconds / grain).rounded(.down) * grain
    }

    static func percentPerHour(_ perHour: Double) -> String {
        guard perHour.isFinite else { return "—" }
        return perHour < 1 ? String(format: "%.1f", perHour) : String(Int(perHour.rounded()))
    }

    /// One duration format for the whole app. Split into number and unit so the figures can take
    /// the tabular face and the units can stay in the interface face.
    static func parts(_ seconds: TimeInterval) -> [(text: String, isNumber: Bool)] {
        guard seconds.isFinite else { return [("很久", false)] }
        let s = max(0, Int(seconds))
        if s < 3600 { return [("\(max(1, s / 60))", true), ("分", false)] }
        if s < 86400 {
            let h = s / 3600, m = (s % 3600) / 60
            return m == 0 ? [("\(h)", true), ("小时", false)]
                          : [("\(h)", true), ("小时", false), ("\(m)", true), ("分", false)]
        }
        if s < 172_800 {
            let d = s / 86400, h = (s % 86400) / 3600
            return h == 0 ? [("\(d)", true), ("天", false)]
                          : [("\(d)", true), ("天", false), ("\(h)", true), ("小时", false)]
        }
        return [("\(s / 86400)", true), ("天以上", false)]
    }

    /// The same duration as a plain string, spaced the way the panel writes them everywhere
    /// else — "1 小时 17 分", never "1小时17分".
    static func span(_ seconds: TimeInterval) -> String {
        parts(seconds).map(\.text).joined(separator: " ")
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func resetLabel(_ reset: Date?, trip: TimeInterval) -> String {
        guard let reset else { return "" }
        if trip < 86400 { return "\(clock(reset)) 重置" }
        return "\(max(1, Int((trip / 86400).rounded()))) 天后重置"
    }
}

extension QuotaWindow {
    /// The single question this app exists to answer, asked once per draw.
    func forecast(at now: Date) -> Forecast { Forecast.make(self, at: now) }
}
