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
        let burn = try XCTUnwrap(out.first?.burn(at: clock))
        XCTAssertTrue(burn.measured, "with samples in hand the rate is measured, not averaged")
        XCTAssertGreaterThan(burn.perHour, 30, "the burst is what is happening now")
        XCTAssertLessThan(burn.span, 3600)

        // Averaged over the window it would read about 9 %/h and project no trouble at all;
        // measured, it runs out well before the reset.
        XCTAssertNotNil(out.first?.projectedExhaustion(at: clock))
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
        let burn = try XCTUnwrap(out.first?.burn(at: clock))
        XCTAssertFalse(burn.measured, "two minutes is not a rate")
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
        XCTAssertNil(out.first?.burn(at: clock)?.measured == true ? true : nil,
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
        XCTAssertEqual(live.first?.burn(at: clock)?.measured, true)

        var stale = try XCTUnwrap(live.first)
        stale.isStale = true
        XCTAssertNil(stale.burn(at: clock), "no reading, no rate")
        XCTAssertNil(stale.projectedExhaustion(at: clock))
        XCTAssertNil(stale.projectedPercentAtReset(at: clock))
    }

}
