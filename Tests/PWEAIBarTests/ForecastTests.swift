import Foundation
import XCTest
@testable import PWEAIBar

/// The engine that answers "do I get to the reset".
///
/// Every test here is written against a claim the spec makes, and most of them are written
/// against a claim an earlier version of this code got wrong: a single fitted rate presented as
/// fact, a boolean standing in for how good the evidence was, and four if-chains in the view
/// deciding copy — which is how "we cannot tell you" ended up in the same grey as "you are fine".
final class ForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(percent: Double?, resetIn: TimeInterval, length: TimeInterval? = 5 * 3600,
                        stale: Bool = false, spent: Bool = false, observedAgo: TimeInterval = 0,
                        samples: [(TimeInterval, Double)] = []) -> QuotaWindow {
        var w = QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "t",
                            percent: percent, resetsAt: now.addingTimeInterval(resetIn),
                            observedAt: now.addingTimeInterval(-observedAgo), isStale: stale,
                            confirmedExhausted: spent, windowLength: length)
        w.samples = samples.map { History.Sample(at: now.addingTimeInterval($0.0), percent: $0.1) }
        return w
    }

    // MARK: The bracket

    /// A flat stretch is not the absence of evidence. It bounds the rate from above, and the
    /// bound tightens the longer nothing happens — which is the only reason a window that has
    /// not moved in forty-five minutes can be told apart from one nobody has read.
    func testAFlatStretchGivesACeilingAndNoFloor() throws {
        let f = window(percent: 40, resetIn: 3 * 3600,
                       samples: [(-2700, 40), (-2000, 40), (-1000, 40), (0, 40)]).forecast(at: now)
        let rate = try XCTUnwrap(f.rate)
        XCTAssertEqual(rate.low, 0, "nothing observed cannot put a floor under the rate")
        XCTAssertEqual(rate.high, 1 / 0.75, accuracy: 0.001, "one step over forty-five minutes")
        XCTAssertEqual(f.enduranceHigh, .infinity, "a rate that may be zero runs for ever")
        guard case .makesIt(let spare) = f.verdict else {
            return XCTFail("a ceiling this low makes the trip: \(f.verdict)")
        }
        XCTAssertEqual(spare, 56, accuracy: 0.5)
        XCTAssertEqual(f.tone, .plain)
    }

    /// One step is one step. It says the rate is not zero and says nothing about how far from
    /// zero, so it must never be enough to tell somebody they are going to run out.
    func testASingleStepCannotClaimAShortfall() throws {
        let f = window(percent: 95, resetIn: 4 * 3600,
                       samples: [(-1800, 94), (0, 95)]).forecast(at: now)
        let rate = try XCTUnwrap(f.rate)
        XCTAssertEqual(rate.low, 0)
        XCTAssertEqual(rate.high, 4, accuracy: 0.001)
        XCTAssertEqual(f.verdict, .tooClose, "not knowing is its own answer, not a shortfall")
        XCTAssertEqual(f.tone, .warm, "and it has to look different from good news")
    }

    /// Replayed from the owner's real cache: 19 → 20 → 21 → 23 across fifteen minutes of a
    /// weekly window. The old engine read this as a single rate of 16 %/h and projected it six
    /// and a half days forward without comment.
    func testTheRealWeeklyBurstIsBracketedAndThenDecaysOnItsOwn() throws {
        let burst: [(TimeInterval, Double)] = [(-900, 19), (-835, 20), (-675, 21), (0, 23)]
        let f = window(percent: 23, resetIn: 6.5 * 86400, length: 7 * 86400,
                       samples: burst).forecast(at: now)
        let rate = try XCTUnwrap(f.rate)
        XCTAssertEqual(rate.low, 12, accuracy: 0.001)
        XCTAssertEqual(rate.high, 20, accuracy: 0.001)
        // And then the verdict refuses to be a prophecy. The bracket bounds the rate over the
        // fifteen minutes that were *watched*; it says nothing about the six days after them,
        // and shutting the lid makes the true rate zero. So the shortfall — the one verdict that
        // turns a rate into a red claim about the far future — is withheld until the evidence
        // covers a quarter of what it is judging. Fifteen minutes of a week earns 「临界，说不准」.
        XCTAssertEqual(f.verdict, .tooClose)
        XCTAssertEqual(f.tone, .warm)

        // The same weekly window does get a red verdict from evidence that has actually watched
        // enough of it — which on a seven-day window is the whole-window average, not a burst.
        let sustained = window(percent: 40, resetIn: 6.5 * 86400, length: 7 * 86400,
                               samples: [(-43200, 10), (-21600, 25), (0, 40)]).forecast(at: now)
        guard case .fallsShort = sustained.verdict else {
            return XCTFail("half a day at this pace does not survive the week: \(sustained.verdict)")
        }

        // Two quiet hours later, with the burst still inside the horizon: the oldest sample
        // stays put while the newest advances, so the same climb is divided by a longer stretch
        // and the rate falls back without anyone having to age anything out.
        var later = window(percent: 23, resetIn: 6.5 * 86400, length: 7 * 86400)
        later.samples = (burst + [(3600, 23), (7200, 23)]).map {
            History.Sample(at: now.addingTimeInterval($0.0), percent: $0.1)
        }
        later.observedAt = now.addingTimeInterval(7200)
        let cooled = try XCTUnwrap(later.forecast(at: now.addingTimeInterval(7200)).rate)
        XCTAssertLessThan(cooled.high, 3, "the burst is two hours old and reads like it")
    }

    /// The real cache has three pairs of identical timestamps in it, and a repeated timestamp is
    /// a zero-length span waiting to divide by nothing.
    func testRepeatedTimestampsAreCollapsedRatherThanDividedBy() throws {
        let f = window(percent: 23, resetIn: 6.5 * 86400, length: 7 * 86400,
                       samples: [(-900, 19), (-835, 20), (-835, 20), (-675, 21), (0, 23)])
            .forecast(at: now)
        let rate = try XCTUnwrap(f.rate)
        XCTAssertEqual(rate.low, 12, accuracy: 0.001)
        XCTAssertTrue(rate.high.isFinite)

        // And the degenerate case: every sample at the same instant is one sample.
        let collapsed = window(percent: 40, resetIn: 3 * 3600,
                               samples: [(0, 38), (0, 39), (0, 40)]).forecast(at: now)
        XCTAssertEqual(collapsed.evidence?.isMeasured, false, "one instant is not a stretch")
        XCTAssertTrue(collapsed.rate.map { $0.high.isFinite } ?? true)
    }

    // MARK: Verdicts

    /// The comparison is inclusive on purpose. Exactly enough is enough.
    func testEnduranceExactlyEqualToTheTripMakesIt() {
        // 50 % left, a bracket whose fast end is 12.5 %/h, and four hours to go: 50 / 12.5 = 4.
        let f = window(percent: 50, resetIn: 4 * 3600,
                       samples: [(-3600, 38.5), (0, 50)]).forecast(at: now)
        XCTAssertEqual(f.enduranceLow ?? 0, 4 * 3600, accuracy: 1)
        guard case .makesIt = f.verdict else { return XCTFail("exactly enough is enough") }
    }

    /// Not being able to read is the one state on the list whose remedy is not "wait", so it is
    /// the one state that gets its own sentence. This is the owner's own machine: Claude Code's
    /// keychain credential expired overnight and the panel said 待确认 for thirteen hours with
    /// nothing on it that named an action.
    func testALongUnreadableStretchIsItsOwnVerdictWithItsOwnColour() {
        let f = window(percent: nil, resetIn: 2 * 3600, stale: true, observedAgo: 7 * 3600)
            .forecast(at: now)
        XCTAssertEqual(f.verdict, .blind(since: 7 * 3600))
        XCTAssertEqual(f.tone, .warm)
        XCTAssertEqual(f.verdictText, "7 小时没有新读数")
        XCTAssertTrue(f.spoken.contains("先把连接修好"), "this one has a remedy and names it")

        // A silence with nothing broken behind it says the same true thing and offers no cure:
        // Codex reads its figure out of a session log, so hours can pass with nobody at fault.
        let quiet = window(percent: 26, resetIn: 2 * 3600, observedAgo: 7 * 3600).forecast(at: now)
        XCTAssertEqual(quiet.verdictText, "7 小时没有新读数")
        XCTAssertFalse(quiet.spoken.contains("先把连接修好"))

        // A window whose stale reset has drifted into the past still gets told to go and look.
        // Ordered the other way round it was swallowed by 「已过重置时间，等新读数确认」 — the one
        // screen on which waiting is exactly the wrong advice.
        let expired = window(percent: nil, resetIn: -3600, stale: true, observedAgo: 18 * 3600)
            .forecast(at: now)
        XCTAssertEqual(expired.verdict, .blind(since: 18 * 3600))
        XCTAssertFalse(expired.hasTimeline, "no rule to draw, but it still has something to say")

        // Under the threshold it is an ordinary gap in the readings, and says so once.
        let brief = window(percent: 40, resetIn: 2 * 3600, stale: true, observedAgo: 400)
            .forecast(at: now)
        XCTAssertEqual(brief.verdict, .sampling)
        XCTAssertEqual(brief.verdictText, "还在采样")
    }

    /// Seven outcomes, three colours, and the assignment is part of the spec rather than of the
    /// view. The panel's whole one-second channel is whether there is colour on the right; a
    /// verdict with no tone decided for it is a verdict that reads as good news.
    func testEveryVerdictCarriesExactlyOneTone() {
        let cases: [(Forecast, Forecast.Tone, String)] = [
            (window(percent: 100, resetIn: 3600, spent: true).forecast(at: now), .hot, "已用尽"),
            (window(percent: 70, resetIn: 2 * 3600).forecast(at: now), .hot, "缺口 40 分"),
            (window(percent: 95, resetIn: 4 * 3600,
                    samples: [(-1800, 94), (0, 95)]).forecast(at: now), .warm, "临界，说不准"),
            (window(percent: 20, resetIn: 2 * 3600).forecast(at: now), .plain, "到点至少剩 66%"),
            (window(percent: nil, resetIn: 2 * 3600).forecast(at: now), .plain, "还在采样"),
            (window(percent: nil, resetIn: 2 * 3600, stale: true,
                    observedAgo: 7 * 3600).forecast(at: now), .warm, "7 小时没有新读数"),
            (window(percent: 40, resetIn: -60).forecast(at: now), .plain, "已过重置时间，等新读数确认"),
        ]
        for (f, tone, text) in cases {
            XCTAssertEqual(f.tone, tone, text)
            XCTAssertEqual(f.verdictText, text)
        }
    }

    // MARK: What reaches the panel

    /// The rule that the design review called fatal in one of the candidate engines, and that
    /// this one keeps structurally: the big number is whichever of the two is going to happen,
    /// and the label above it is keyed on which number won — never on the verdict. Under
    /// `.makesIt` the endurance is by definition the larger of the two, so a verdict-keyed rule
    /// prints the hypothetical figure every single time it says you are fine.
    func testTheHeadlineIsAlwaysTheThingThatActuallyHappens() {
        for f in [
            window(percent: 20, resetIn: 2 * 3600).forecast(at: now),
            window(percent: 40, resetIn: 3 * 3600,
                   samples: [(-2700, 40), (0, 40)]).forecast(at: now),
            window(percent: nil, resetIn: 2 * 3600).forecast(at: now),
            window(percent: 100, resetIn: 3600, spent: true).forecast(at: now),
        ] {
            XCTAssertFalse(f.headlineIsEndurance, "\(f.verdict)")
            XCTAssertEqual(f.headline, f.trip, "\(f.verdict)")
            XCTAssertEqual(f.headingLeft, "到重置", "\(f.verdict)")
        }

        let short = window(percent: 70, resetIn: 2 * 3600).forecast(at: now)
        XCTAssertTrue(short.headlineIsEndurance)
        XCTAssertEqual(short.headingLeft, "至少能跑")
        XCTAssertLessThan(try XCTUnwrap(short.headline), try XCTUnwrap(short.trip))
    }

    /// The line beside the big number spends its two hundred points on what the big number
    /// cannot say. An earlier candidate spent them restating the figure already set in the
    /// largest type on the panel.
    func testTheVerdictLineNeverRestatesTheHeadline() {
        for f in [
            window(percent: 70, resetIn: 2 * 3600).forecast(at: now),
            window(percent: 20, resetIn: 2 * 3600).forecast(at: now),
            window(percent: 95, resetIn: 4 * 3600, samples: [(-1800, 94), (0, 95)]).forecast(at: now),
            window(percent: nil, resetIn: 2 * 3600).forecast(at: now),
        ] {
            guard let headline = f.headline else { continue }
            XCTAssertFalse(f.verdictText.contains(Forecast.span(headline)),
                           "\(f.verdictText) restates \(Forecast.span(headline))")
        }
    }

    /// Rounded down, always, so the printed duration stays a floor and the sentence can say
    /// 至少 without lying. This is what makes 「1 小时 17 分」 unprintable from three samples —
    /// not as a matter of discipline, but because the number that would say it does not exist.
    func testBothDurationsOnTheRowAreFlooredToTheSameLadder() {
        let f = window(percent: 70, resetIn: 2 * 3600).forecast(at: now)
        guard case .fallsShort(let gap) = f.verdict else { return XCTFail("\(f.verdict)") }
        XCTAssertEqual(gap, Forecast.floorToGrain(gap), "the gap is a floor too, not a fitted figure")
        XCTAssertEqual(f.headline, Forecast.floorToGrain(try! XCTUnwrap(f.enduranceLow)))
    }

    /// Found on live data the moment the stage started leading with the countdown: a Codex
    /// window with 5% left and nothing being spent read 「到点至少剩 0%」 in grey, under a full
    /// amber bar and beside a line saying 剩余 5%. The margin was 0.9 and `Int` took it to zero.
    func testASubOnePercentMarginNeverPrintsAsZero() {
        XCTAssertEqual(Forecast.spare(0.9), "0.9%")
        XCTAssertEqual(Forecast.spare(0.04), "<0.1%")
        XCTAssertEqual(Forecast.spare(0), "0%", "zero is reserved for zero")
        XCTAssertEqual(Forecast.spare(17.8), "17%", "above one it is still a floor")
    }

    func testTheGrainOnlyEverRoundsDown() {
        XCTAssertEqual(Forecast.floorToGrain(3540), 3300, "under an hour, five-minute grain")
        XCTAssertEqual(Forecast.floorToGrain(21540), 20700, "under six hours, quarter-hour grain")
        XCTAssertEqual(Forecast.floorToGrain(21600), 21600, "on the grain, unchanged")
        XCTAssertEqual(Forecast.floorToGrain(360_000), 345_600, "days round to six hours")
        XCTAssertEqual(Forecast.floorToGrain(200), 200, "below the finest grain, left alone")
        for seconds in stride(from: 60.0, through: 400_000, by: 997) {
            XCTAssertLessThanOrEqual(Forecast.floorToGrain(seconds), seconds,
                                     "a floor that rounds up is not a floor")
        }
    }
}
