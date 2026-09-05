import Foundation
import XCTest
@testable import PWEAIBar

final class QuotaTests: XCTestCase {
    func testInterleavedPoolsUseRecordTimeAndIgnoreInvalidTail() async throws {
        let space = try TestSpace(); let clock = TestClock()
        let at = clock.date.addingTimeInterval(-300)
        let reset = clock.date.addingTimeInterval(3600)
        let main = try codexLine(at: at, reset: reset)
        let premium = try codexLine(at: at.addingTimeInterval(1), id: "premium", reset: reset,
                                    extra: ["primary": NSNull(), "rate_limit_reached_type": "workspace_member_credits_depleted"])
        let file = try space.file("session.jsonl", main + premium + "{\"rate_limits\":broken}\n" + "{\"rate_limits\":")
        try FileManager.default.setAttributes([.modificationDate: clock.date], ofItemAtPath: file.path)
        let provider = CodexProvider(root: space.root, now: { clock.date })
        let rows = await provider.windows()
        XCTAssertEqual(rows.count, 2)
        let quota = try XCTUnwrap(rows.first { $0.id == "codex_300" })
        XCTAssertEqual(quota.percent, 80)
        XCTAssertEqual(quota.observedAt, at)
        XCTAssertNotNil(rows.first { $0.id == "codex_credits" })
    }

    func testCrossFileSelectionUsesObservationNotMtimeAndRecoveredPoolClears() async throws {
        let space = try TestSpace(); let clock = TestClock(); let reset = clock.date.addingTimeInterval(3600)
        _ = try space.file("a.jsonl", codexLine(at: clock.date.addingTimeInterval(-1), pct: 20, reset: reset))
        _ = try space.file("b.jsonl", codexLine(at: clock.date.addingTimeInterval(-50), pct: 90, reset: reset))
        let depleted = try codexLine(at: clock.date.addingTimeInterval(-30), id: "premium", reset: reset,
                                     extra: ["primary": NSNull(), "rate_limit_reached_type": "credits_depleted"])
        let recovered = try codexLine(at: clock.date, id: "premium", reset: reset, extra: ["primary": NSNull()])
        _ = try space.file("c.jsonl", depleted + recovered)
        let rows = await CodexProvider(root: space.root, now: { clock.date }).windows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.percent, 20)
    }

    func testExpiredQuotaIsUnknownAndCannotNotify() async throws {
        let space = try TestSpace(); let clock = TestClock()
        _ = try space.file("s.jsonl", codexLine(at: clock.date.addingTimeInterval(-10), reset: clock.date.addingTimeInterval(-1)))
        let rows = await CodexProvider(root: space.root, now: { clock.date }).windows()
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.percent); XCTAssertEqual(Readout.text(row, remaining: true), "待确认")
        XCTAssertTrue(row.isStale); XCTAssertFalse(row.canNotify(at: clock.date))
    }

    func testMissingTimeIsNotInferredFromFileAndLegacyIDIsSupported() async throws {
        let space = try TestSpace(); let clock = TestClock(); let reset = clock.date.addingTimeInterval(1000)
        let file = try space.file("s.jsonl", codexLine(at: nil, reset: reset))
        let provider = CodexProvider(root: space.root, now: { clock.date })
        var rows = await provider.windows()
        XCTAssertEqual(rows.first?.id, "codex_unknown")
        try codexLine(at: clock.date, id: nil, reset: reset).write(to: file, atomically: true, encoding: .utf8)
        rows = await provider.windows()
        XCTAssertEqual(rows.first?.percent, 80)
    }

    func testBoundedTailReportsUnavailableAndBadPercentageDoesNotMaskGoodRecord() async throws {
        let space = try TestSpace(); let clock = TestClock(); let reset = clock.date.addingTimeInterval(3600)
        let good = try codexLine(at: clock.date.addingTimeInterval(-1), reset: reset)
        _ = try space.file("s.jsonl", good + String(repeating: "unrelated\n", count: 100))
        let bounded = await CodexProvider(root: space.root, now: { clock.date }, tailBytes: 200).windows()
        XCTAssertEqual(bounded.first?.id, "codex_unknown")
        _ = try space.file("s.jsonl", good + codexLine(at: clock.date, pct: -1, reset: reset))
        let full = await CodexProvider(root: space.root, now: { clock.date }).windows()
        XCTAssertEqual(full.first?.percent, 80)
    }

    /// The contract is "more alarming wins", not "server wins". A server severity raises the
    /// band on its own — it knows about restrictions that carry no percentage — but it cannot
    /// talk a 96 % window back down to calm, because a sentinel that under-warns is useless.
    func testEitherSourceCanRaiseTheBandAndNeitherCanLowerIt() {
        for severity in [Severity.normal, .warning, .critical] {
            let w = QuotaWindow(id: "s", provider: .claude, channel: .session, title: "test",
                                percent: 96, severity: severity, gradedBy: .server)
            XCTAssertEqual(w.band, .hot, "96% is hot whatever the server calls it")
            XCTAssertFalse(w.confirmedExhausted, "near the limit is not the same as spent")
        }
        for (severity, band) in [(Severity.normal, Health.calm), (.warning, .warm), (.critical, .hot)] {
            let quiet = QuotaWindow(id: "s", provider: .claude, channel: .session, title: "test",
                                    percent: 1, severity: severity, gradedBy: .server)
            XCTAssertEqual(quiet.band, band, "with nothing to report locally, the server decides")
        }
        let local = QuotaWindow(id: "s", provider: .codex, channel: .codex, title: "test", percent: 96)
        XCTAssertEqual(local.band, .hot)
        XCTAssertFalse(local.confirmedExhausted)
    }
}
