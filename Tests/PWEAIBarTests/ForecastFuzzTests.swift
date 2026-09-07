import Foundation
import XCTest
@testable import PWEAIBar

/// Three hundred thousand hostile windows, asking one question of each: is every number the
/// engine hands the panel actually a number?
///
/// The forecast derives durations by dividing by a rate, percentages by subtracting from a
/// projection, and grains by flooring — three operations with three different ways to produce
/// an infinity, a NaN or a negative duration out of inputs that all looked reasonable. None of
/// those survive contact with a view: a NaN in a frame width takes the whole panel with it.
/// So rather than guess which combination does it, this generates them: percentages that are
/// nil or integral, resets in the past and the far future, windows with no length, readings
/// observed in the future, stale flags, exhaustion, and sample rings that are empty, flat,
/// climbing or pinned at a hundred.
///
/// It asserts invariants rather than values — every duration finite and non-negative, every
/// rate interval ordered and non-negative, every margin inside nought to a hundred, every gap
/// positive — because the point is not what the engine says about any one of these, it is that
/// there is no input for which it says something impossible.
final class ForecastFuzzTests: XCTestCase {
    func testNoHostileWindowProducesAnImpossibleNumber() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var rng = SystemRandomNumberGenerator()
        var bad: [String] = []
        var seenVerdicts = Set<String>()
        // Enough to reach every verdict several thousand times over; past this it is paying
        // twenty seconds of suite time to re-find what it already found.
        for _ in 0..<120_000 {
            let percent: Double? = Bool.random(using: &rng) ? Double.random(in: 0...100, using: &rng).rounded() : nil
            let resetIn = [Double.random(in: -7200...(7 * 86400), using: &rng), 0, 60, 600].randomElement(using: &rng)!
            let length: TimeInterval? = [5 * 3600, 7 * 86400, 300, 60, nil].randomElement(using: &rng)!
            let observedAgo = Double.random(in: -600...2400, using: &rng)
            let n = Int.random(in: 0...6, using: &rng)
            var samples: [(TimeInterval, Double)] = []
            var p = Double.random(in: 0...100, using: &rng).rounded()
            var t = -Double.random(in: 0...(4 * 3600), using: &rng)
            for _ in 0..<n {
                samples.append((t, p))
                t += Double.random(in: 0...1800, using: &rng)
                // Including steps that go backwards. The ring is supposed to be monotone and
                // History clears it when it is not — but a rolled-over window, or a provider
                // whose figure is derived from a remaining fraction, can hand one over anyway,
                // and that case produced a negative rate and a negative endurance until it was
                // guarded. A fuzzer that only ever climbs would never have found it.
                p = min(100, max(0, p + Double([0, 0, 1, 2, 5, -1, -40].randomElement(using: &rng)!)))
            }
            var w = QuotaWindow(id: "x", provider: .claude, channel: .session, title: "t",
                                percent: percent, resetsAt: resetIn == 0 ? nil : now.addingTimeInterval(resetIn),
                                observedAt: now.addingTimeInterval(-observedAgo),
                                isStale: Bool.random(using: &rng),
                                confirmedExhausted: Double.random(in: 0...1, using: &rng) < 0.05,
                                windowLength: length)
            w.samples = samples.map { History.Sample(at: now.addingTimeInterval($0.0), percent: $0.1) }
            let f = w.forecast(at: now)
            // exercise every formatter
            _ = f.spoken; _ = f.verdictText; _ = f.paceText; _ = f.headingLeft
            if let h = f.headline { _ = Forecast.parts(h); _ = Forecast.clock(now.addingTimeInterval(h)) }
            if let tr = f.trip { _ = Forecast.resetLabel(w.resetsAt, trip: tr) }
            seenVerdicts.insert("\(f.verdict)".prefix(while: { $0 != "(" }).description)
            func note(_ s: String) { if bad.count < 12 { bad.append("\(s) :: pct=\(String(describing: percent)) resetIn=\(resetIn) len=\(String(describing: length)) ago=\(observedAgo) samples=\(samples) -> \(f.verdict) low=\(String(describing: f.enduranceLow)) high=\(String(describing: f.enduranceHigh)) rate=\(String(describing: f.rate))") } }
            if let low = f.enduranceLow, !(low.isFinite && low >= 0) { note("enduranceLow not a finite non-negative") }
            if let hi = f.enduranceHigh, hi.isNaN { note("enduranceHigh NaN") }
            if let r = f.rate, !(r.low.isFinite && r.high.isFinite && r.low >= 0 && r.high >= r.low) { note("bad rate") }
            if let h = f.headline, !(h.isFinite && h >= 0) { note("headline") }
            if case .makesIt(let s) = f.verdict, !(s.isFinite && s >= 0 && s <= 100) { note("spare") }
            if case .fallsShort(let g) = f.verdict, !(g.isFinite && g > 0) { note("gap \(g)") }
            if case .blind(let s) = f.verdict, !(s.isFinite && s > 0) { note("blind since \(s)") }
        }
        print("verdicts seen: \(seenVerdicts.sorted())")
        for b in bad { print("BAD  \(b)") }
        XCTAssertTrue(bad.isEmpty, "\(bad.count) bad")
    }
}
