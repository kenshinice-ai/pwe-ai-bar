import Foundation
import XCTest
@testable import PWEAIBar

final class RuleTests: XCTestCase {
    @MainActor func testPendingResetSurvivesMissingStaleAndRestartThenAcknowledgesOnce() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let reset = clock.date.addingTimeInterval(10)
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        var snap = Snapshot()
        snap.windows = [QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "session",
                                     percent: 90, resetsAt: reset, observedAt: clock.date)]
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
        clock.date.addTimeInterval(20)
        snap.windows = [QuotaWindow(id: "codex", provider: .codex, channel: .codex, title: "Codex", percent: 10, observedAt: clock.date)]
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
        let restarted = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        snap.windows = [QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "session",
                                     percent: 5, resetsAt: clock.date.addingTimeInterval(3600), observedAt: clock.date)]
        snap.stale = true
        XCTAssertTrue(restarted.evaluate(snap).isEmpty)
        snap.stale = false; snap.windows[0].isStale = true
        XCTAssertTrue(restarted.evaluate(snap).isEmpty)
        snap.windows[0].isStale = false; snap.windows[0].observedAt = reset.addingTimeInterval(-1)
        XCTAssertTrue(restarted.evaluate(snap).isEmpty)
        snap.windows[0].observedAt = clock.date
        let alerts = restarted.evaluate(snap)
        XCTAssertEqual(alerts.map(\.kind), [.reset])
        XCTAssertEqual(restarted.evaluate(snap).map(\.id), alerts.map(\.id), "Unaccepted delivery remains queued")
        restarted.acknowledge(alerts[0])
        XCTAssertTrue(restarted.evaluate(snap).isEmpty)
        let again = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        XCTAssertTrue(again.evaluate(snap).isEmpty)
    }

    /// Codex writes a reading only when Codex runs, so a promise that waits for confirmation is
    /// a promise that is never kept — and "you can start again" is the alert people are actually
    /// sitting there waiting for. Say it on the clock, and say that it is the clock talking.
    @MainActor func testResetIsAnnouncedOnTheClockWhenNoFreshReadingArrives() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let reset = clock.date.addingTimeInterval(60)
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        var snap = Snapshot()
        func codex(_ pct: Double?, observed: Date, stale: Bool = false) -> QuotaWindow {
            QuotaWindow(id: "codex_300", provider: .codex, channel: .codex, title: "五小时窗口",
                        percent: pct, resetsAt: reset, note: pct == nil ? "待确认" : nil,
                        observedAt: observed, isStale: stale)
        }
        snap.windows = [codex(95, observed: clock.date)]
        XCTAssertTrue(rules.evaluate(snap).map(\.kind).filter { $0 == .reset }.isEmpty)

        // The window has expired and Codex has not run since: the reading is stale by design.
        clock.date = reset.addingTimeInterval(60)
        snap.windows = [codex(nil, observed: reset.addingTimeInterval(-300), stale: true)]
        XCTAssertTrue(rules.evaluate(snap).contains { $0.kind == .resetExpected } == false,
                      "one minute past the reset is too eager")

        clock.date = reset.addingTimeInterval(180)
        let alerts = rules.evaluate(snap)
        XCTAssertEqual(alerts.map(\.kind), [.resetExpected])
        XCTAssertTrue(alerts[0].body.contains("确认"), "the wording must not claim a measurement")
        XCTAssertEqual(rules.evaluate(snap).map(\.id), alerts.map(\.id), "queued until the OS takes it")
        rules.acknowledge(alerts[0])
        XCTAssertTrue(rules.evaluate(snap).isEmpty)

        // A real reading turning up afterwards must not repeat the same news.
        clock.date.addTimeInterval(60)
        snap.windows = [codex(0, observed: clock.date)]
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
    }

    @MainActor func testDeferredResetWaitsForFreshConfirmationBeforeRetry() async throws {
        let space = try TestSpace(); let clock = TestClock()
        space.defaults.set(["five_hour": clock.date.timeIntervalSince1970 - 10], forKey: "pendingResets")
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        var snap = Snapshot()
        snap.windows = [QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "quota", percent: 0, observedAt: clock.date)]
        let pending = rules.evaluate(snap)
        XCTAssertEqual(pending.count, 1)
        snap.stale = true
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
        snap.stale = false
        XCTAssertEqual(rules.evaluate(snap).map(\.id), pending.map(\.id))
    }

    @MainActor func testMultipleResetsDoNotSuppressEachOther() async throws {
        let space = try TestSpace(); let clock = TestClock()
        space.defaults.set(["five_hour": clock.date.timeIntervalSince1970 - 10,
                            "seven_day": clock.date.timeIntervalSince1970 - 10], forKey: "pendingResets")
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        var snap = Snapshot()
        snap.windows = ["five_hour", "seven_day"].map {
            QuotaWindow(id: $0, provider: .claude, channel: .session, title: $0, percent: 0, observedAt: clock.date)
        }
        let alerts = rules.evaluate(snap)
        XCTAssertEqual(alerts.count, 2)
        alerts.forEach(rules.acknowledge)
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
    }

    @MainActor func testEventDeliveryPersistsAndNewPromptStillNotifies() async throws {
        let space = try TestSpace(); let clock = TestClock()
        var snap = Snapshot(); snap.events = [event(at: clock.date, id: "one")]
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        let first = rules.evaluate(snap)
        XCTAssertEqual(first.count, 1)
        let restart = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        XCTAssertEqual(restart.evaluate(snap).map(\.id), first.map(\.id))
        restart.acknowledge(first[0])
        // Opening the provider does not reset event reception or invent an answered event.
        XCTAssertTrue(restart.evaluate(snap).isEmpty)
        XCTAssertNotNil(snap.attention)
        clock.date.addTimeInterval(1)
        snap.events = [event(kind: .answered, at: clock.date)]
        XCTAssertTrue(restart.evaluate(snap).isEmpty)
        XCTAssertNil(snap.attention)
        snap.events = [event(at: clock.date, id: "two")]
        XCTAssertEqual(restart.evaluate(snap).count, 1)
    }

    @MainActor func testResolvedWaitingIsRemovedFromOutboxButOtherSessionRemains() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        let other = event("other", at: clock.date)
        var snap = Snapshot(); snap.events = [event(at: clock.date), other]
        XCTAssertEqual(rules.evaluate(snap).count, 2)
        clock.date.addTimeInterval(1)
        snap.events = [event(kind: .answered, at: clock.date), other]
        let remaining = rules.evaluate(snap)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].subject, "claude:other")
    }

    @MainActor func testWaitingSurvivesTwoMinuteGapButFinishedDoesNotReplayBacklog() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { true }, remaining: { true })
        var snap = Snapshot()
        snap.events = [event(at: clock.date.addingTimeInterval(-300)),
                       event("old-finished", kind: .finished, at: clock.date.addingTimeInterval(-300))]
        XCTAssertEqual(rules.evaluate(snap).map(\.kind), [.waiting])
    }

    @MainActor func testNinetySixPercentIsNearLimitNotExhausted() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let rules = RuleEngine(defaults: space.defaults, now: { clock.date }, away: { false }, remaining: { true })
        var snap = Snapshot()
        snap.windows = [QuotaWindow(id: "codex", provider: .codex, channel: .codex, title: "quota", percent: 10, observedAt: clock.date)]
        XCTAssertTrue(rules.evaluate(snap).isEmpty)
        snap.windows[0].percent = 96
        let near = rules.evaluate(snap)
        XCTAssertEqual(near.map(\.kind), [.threshold])
        XCTAssertFalse(near[0].title.contains("用尽")); rules.acknowledge(near[0])
        snap.windows[0].percent = 100; snap.windows[0].confirmedExhausted = true
        let full = rules.evaluate(snap)
        XCTAssertEqual(full.map(\.kind), [.exhausted])
    }
}
