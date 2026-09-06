import Foundation
import XCTest
@testable import PWEAIBar

/// The one place in this app that remembers anything. It exists so "how fast am I going" can be
/// answered from readings rather than from an average since the window opened — and the average
/// is the reassuring answer: an hour of heavy work after three quiet ones comes out gentle right
/// up until it stops you.
final class HistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    /// `resetIn` is measured from `origin`, not from `at` — a window's reset is a fixed moment,
    /// and letting it slide with the clock made the window appear to reopen on every reading,
    /// which quietly discarded every sample before it.
    private func window(_ percent: Double, at: Date, resetIn: TimeInterval = 5 * 3600,
                        length: TimeInterval? = 5 * 3600) -> QuotaWindow {
        QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "t",
                    percent: percent, resetsAt: origin.addingTimeInterval(resetIn),
                    observedAt: at, windowLength: length)
    }

    func testSamplesAccumulateWithoutRecordingTheSameReadingTwice() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })

        var out = await history.observe([window(10, at: clock)])
        XCTAssertEqual(out.first?.samples.count, 1)

        // Twenty seconds later, unchanged: the same reading, not a second one.
        clock.addTimeInterval(20)
        out = await history.observe([window(10, at: clock)])
        XCTAssertEqual(out.first?.samples.count, 1, "a repeat of the same figure is not a sample")

        // Twenty seconds later, moved: worth recording even inside the quiet period.
        clock.addTimeInterval(20)
        out = await history.observe([window(12, at: clock)])
        XCTAssertEqual(out.first?.samples.count, 2)

        // A minute on, unchanged: the quiet period has passed, so the flat stretch is recorded
        // too — otherwise a pause looks like no time went by at all.
        clock.addTimeInterval(60)
        out = await history.observe([window(12, at: clock)])
        XCTAssertEqual(out.first?.samples.count, 3)
    }

    func testARolledOverWindowDoesNotAverageAcrossItsOwnBoundary() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })

        for step in 0..<4 {
            clock.addTimeInterval(600)
            _ = await history.observe([window(Double(step * 20 + 20), at: clock)])
        }
        clock.addTimeInterval(600)
        let before = await history.observe([window(90, at: clock)])
        XCTAssertGreaterThan(before.first?.samples.count ?? 0, 3)

        // The window resets: the reading drops. Everything before it describes a different
        // window that happens to share a name.
        clock.addTimeInterval(600)
        let after = await history.observe([window(2, at: clock)])
        XCTAssertEqual(after.first?.samples.count, 1, "a reset starts the record again")
        XCTAssertEqual(after.first?.samples.first?.percent, 2)
    }

    func testSamplesOlderThanTheWindowTheyBelongToAreDropped() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })
        _ = await history.observe([window(10, at: clock)])

        // Six hours on, in a window that opened an hour ago: the earlier sample predates it,
        // so keeping it would report a pace spanning two different windows.
        clock.addTimeInterval(6 * 3600)
        let out = await history.observe([window(30, at: clock, resetIn: 10 * 3600)])
        XCTAssertEqual(out.first?.samples.count, 1)
    }

    func testTheRingIsBoundedAndSurvivesARestart() async throws {
        let space = try TestSpace()
        let url = space.root.appendingPathComponent("h.json")
        var clock = origin
        let history = History(url: url, now: { clock })

        for step in 1...80 {
            clock.addTimeInterval(60)
            _ = await history.observe([window(min(99, Double(step)), at: clock,
                                              resetIn: 80 * 3600, length: 100 * 3600)])
        }
        let capped = await history.observe([window(99, at: clock, resetIn: 80 * 3600, length: 100 * 3600)])
        XCTAssertLessThanOrEqual(capped.first?.samples.count ?? 999, 50, "the ring is bounded")
        await history.flush(force: true)

        let reloaded = History(url: url, now: { clock })
        let out = await reloaded.observe([window(99, at: clock, resetIn: 80 * 3600, length: 100 * 3600)])
        XCTAssertGreaterThan(out.first?.samples.count ?? 0, 1, "the record survives a restart")
    }

    func testCorruptAndImpossibleSamplesAreDiscardedOnLoad() async throws {
        let space = try TestSpace()
        let url = try space.file("h.json", """
        {"version":1,"windows":{"claude:five_hour":[
          {"at":1800000000,"percent":10},
          {"at":9999999999,"percent":20},
          {"at":1800000060,"percent":140},
          {"at":1800000120,"percent":"twenty"},
          {"at":1800000180,"percent":30}
        ]}}
        """)
        let clock = origin.addingTimeInterval(600)
        let history = History(url: url, now: { clock })
        let out = await history.observe([window(35, at: clock)])
        // Two of the five rows are usable; the future one, the out-of-range one and the string
        // are dropped rather than poisoning the slope.
        XCTAssertEqual(out.first?.samples.map(\.percent).filter { $0 <= 100 }.count,
                       out.first?.samples.count)
        XCTAssertFalse(out.first?.samples.contains { $0.percent > 100 } ?? true)
        XCTAssertFalse(out.first?.samples.contains { $0.at > clock } ?? true)

        let junk = try space.file("junk.json", "{ not json")
        let broken = History(url: junk, now: { clock })
        let recovered = await broken.observe([window(35, at: clock)])
        XCTAssertEqual(recovered.first?.samples.count, 1, "an unreadable file is an empty one")
    }

    /// The whole point of keeping any history at all.
    func testARecentBurstIsReportedAsTheRateRatherThanAveragedAway() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })

        // Three quiet hours: 12 % used, an average of 4 %/h.
        for step in 1...6 {
            clock.addTimeInterval(1800)
            _ = await history.observe([window(Double(step) * 2, at: clock, resetIn: 5 * 3600)])
        }
        // Then twenty minutes of heavy work: 12 % to 32 %, which is 60 %/h.
        for step in 1...4 {
            clock.addTimeInterval(300)
            _ = await history.observe([window(12 + Double(step) * 5, at: clock, resetIn: 5 * 3600)])
        }
        let out = await history.observe([window(32, at: clock, resetIn: 5 * 3600)])
        let f = try XCTUnwrap(out.first).forecast(at: clock)
        let evidence = try XCTUnwrap(f.evidence)
        XCTAssertTrue(evidence.isMeasured, "with samples in hand the rate is measured, not averaged")
        XCTAssertLessThan(evidence.span, 3600)
        // Even the slowest rate the readings allow is the burst, not the quiet hours before it.
        XCTAssertGreaterThan(try XCTUnwrap(f.rate).low, 30, "the burst is what is happening now")

        // Averaged over the window it would read about 9 %/h and project no trouble at all;
        // bracketed from the samples, it runs dry before the reset under every rate the
        // readings admit.
        guard case .fallsShort = f.verdict else {
            return XCTFail("a burst that outruns the window must be called short: \(f.verdict)")
        }
    }

    /// Without enough history the honest answer is the average, and it must say so.
    func testTooLittleHistoryFallsBackToTheAverageAndAdmitsIt() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })
        clock.addTimeInterval(3 * 3600)
        _ = await history.observe([window(60, at: clock, resetIn: 5 * 3600)])
        clock.addTimeInterval(120)
        let out = await history.observe([window(62, at: clock, resetIn: 5 * 3600)])
        let f = try XCTUnwrap(out.first).forecast(at: clock)
        XCTAssertEqual(f.evidence?.isMeasured, false, "two minutes is not a rate")
    }

    func testStaleAndUnreadableWindowsAreNotRecorded() async throws {
        let space = try TestSpace()
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { self.origin })
        var stale = window(40, at: origin); stale.isStale = true
        var blank = window(40, at: origin); blank.percent = nil
        let out = await history.observe([stale, blank])
        XCTAssertTrue(out.allSatisfy { $0.samples.isEmpty },
                      "a reading we could not take is not a reading")
    }
    /// Found within minutes of this shipping, on live data: the record showed 20 % at 00:15,
    /// 20 % at 00:17, then 91 % four seconds later. Nobody consumed 71 points of a five-hour
    /// window in four seconds — the app had restarted, served a cached figure, then replaced it
    /// with a live one. As a slope that is tens of thousands of percent an hour, and a straight
    /// face on "empty in two minutes".
    func testAReadingThatChangesProvenanceIsNotARate() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })

        _ = await history.observe([window(20, at: clock)])
        clock.addTimeInterval(125)
        _ = await history.observe([window(20, at: clock)])
        clock.addTimeInterval(4)
        let out = await history.observe([window(91, at: clock)])

        XCTAssertEqual(out.first?.samples.count, 1, "the leap starts the record again")
        XCTAssertEqual(out.first?.samples.first?.percent, 91)
        XCTAssertNotEqual(out.first?.forecast(at: clock).evidence?.isMeasured, true,
                          "one sample is not a rate")

        // A climb of the same size over a believable stretch is a real burst and is kept.
        var slow = origin
        let second = History(url: space.root.appendingPathComponent("h2.json"), now: { slow })
        _ = await second.observe([window(20, at: slow)])
        slow.addTimeInterval(900)
        let kept = await second.observe([window(91, at: slow)])
        XCTAssertEqual(kept.first?.samples.count, 2, "fifteen minutes of heavy work is a burst")
    }

    /// A cached figure replayed on every poll is one observation, not twenty.
    func testReplayingTheSameObservationDoesNotAccumulateSamples() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })
        let observed = origin.addingTimeInterval(30)

        var stale = window(40, at: observed)
        _ = await history.observe([stale])
        for _ in 0..<10 {
            clock.addTimeInterval(120)
            stale = window(40, at: observed)          // same observedAt every time
            _ = await history.observe([stale])
        }
        let out = await history.observe([window(40, at: observed)])
        XCTAssertEqual(out.first?.samples.count, 1, "one fetch is one sample")

        clock.addTimeInterval(120)
        let fresh = await history.observe([window(41, at: clock)])
        XCTAssertEqual(fresh.first?.samples.count, 2, "a genuinely newer reading is recorded")
    }

    /// Caught by one of the design agents reading the code rather than by a test: the staleness
    /// guard lived only in the averaging fallback, so a window we had not been able to read
    /// still returned a confident *measured* rate from its samples — and the instrument above it
    /// would have drawn that rate as a solid mark.
    func testAStaleWindowHasNoRateAtAllEvenWithSamplesInHand() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })
        for step in 1...5 {
            clock.addTimeInterval(600)
            _ = await history.observe([window(Double(step) * 8, at: clock)])
        }
        let live = await history.observe([window(40, at: clock)])
        XCTAssertEqual(live.first?.forecast(at: clock).evidence?.isMeasured, true)

        var stale = try XCTUnwrap(live.first)
        stale.isStale = true
        let f = stale.forecast(at: clock)
        XCTAssertNil(f.rate, "no reading, no rate")
        XCTAssertNil(f.enduranceLow)
        XCTAssertEqual(f.verdict, .sampling)
        XCTAssertEqual(f.thinness, .readingTooOld)
    }

    /// From the audit, and the ordering error was exactly as described: the ring was cleared on
    /// a percentage drop *before* anything checked whether the reading was newer. A late
    /// arrival — an older, lower figure landing after a newer, higher one — was therefore read
    /// as a window reset and destroyed the record it should have been dropped by.
    func testALateArrivingOlderReadingCannotDisturbANewerRecord() async throws {
        let space = try TestSpace()
        var clock = origin
        let history = History(url: space.root.appendingPathComponent("h.json"), now: { clock })

        clock.addTimeInterval(600)
        _ = await history.observe([window(10, at: clock)])
        clock.addTimeInterval(600)
        let built = await history.observe([window(20, at: clock)])
        XCTAssertEqual(built.first?.samples.count, 2)

        // Now a reading observed ten minutes *earlier* than the last one turns up.
        let late = window(10, at: origin.addingTimeInterval(300))
        let after = await history.observe([late])
        XCTAssertEqual(after.first?.samples.count, 2, "the older reading is dropped, not obeyed")
        XCTAssertEqual(after.first?.samples.last?.percent, 20)

        // And it must not have been recorded at the back either.
        XCTAssertEqual(after.first?.samples.map(\.percent), [10, 20])
    }

    /// Also from the audit. The whole-window average divided by the time since the window
    /// opened — measured from the clock. With no new reading arriving, the same percentage
    /// therefore became a gentler pace every second the panel stayed open, and the forecast
    /// improved on its own with nothing behind the change.
    func testTheAveragePaceDoesNotImproveWhileNothingIsObserved() async throws {
        let observedAt = origin.addingTimeInterval(3 * 3600)
        let window = QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "t",
                                 percent: 60, resetsAt: origin.addingTimeInterval(5 * 3600),
                                 observedAt: observedAt, windowLength: 5 * 3600)
        let first = try XCTUnwrap(window.forecast(at: observedAt).rate)
        XCTAssertEqual(window.forecast(at: observedAt).evidence?.isMeasured, false)
        // 60 % over three hours, bracketed by the one point of quantisation the reading carries.
        XCTAssertEqual(first.low, 59.0 / 3, accuracy: 0.01)
        XCTAssertEqual(first.high, 61.0 / 3, accuracy: 0.01)

        // Nine minutes later, still no new reading: the rate is the same reading, so it is the
        // same rate. The projection may move with the clock; the measurement may not.
        let later = try XCTUnwrap(window.forecast(at: observedAt.addingTimeInterval(540)).rate)
        XCTAssertEqual(later.low, first.low, accuracy: 0.0001)
        XCTAssertEqual(later.high, first.high, accuracy: 0.0001)

        // Past the freshness budget there is no rate at all rather than a quietly stale one.
        let old = window.forecast(at: observedAt.addingTimeInterval(900))
        XCTAssertNil(old.rate)
        XCTAssertEqual(old.thinness, .readingTooOld)
    }

}
