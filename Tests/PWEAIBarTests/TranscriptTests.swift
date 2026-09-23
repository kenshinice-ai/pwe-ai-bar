import Foundation
import XCTest
@testable import PWEAIBar

/// Claude Code's own logs, reduced to the trophy's buckets.
///
/// Nothing tested this reducer until 1.6.0, and the first thing a test found was that it counted
/// lines, not messages: an assistant reply is written as one line per content block, each
/// repeating the same `usage`, so a three-block reply was billed three times.
final class TranscriptTests: XCTestCase {

    private let pricing = Pricing(
        models: ["claude-haiku-4-5": .init(input: 1, output: 5),
                 "claude-opus-5-5": .init(input: 4, output: 20, cacheReadMultiple: 0.05),
                 "claude-opus-5": .init(input: 5, output: 25),
                 "claude-haiku-3-5": .init(input: 0.8, output: 4)],
        subscriptionMonthlyUSD: 20)

    private func line(id: String?, request: String? = "req_1", model: String = "claude-opus-5-5",
                      at: String = "2026-09-20T10:00:00.000Z", input: Int = 100, output: Int = 50,
                      cacheWrite: Int = 0, cacheRead: Int = 0, sidechain: Bool = false) -> String {
        var message: [String: Any] = [
            "model": model,
            "usage": ["input_tokens": input, "output_tokens": output,
                      "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead],
        ]
        if let id { message["id"] = id }
        var row: [String: Any] = ["type": "assistant", "timestamp": at, "message": message,
                                  "isSidechain": sidechain]
        if let request { row["requestId"] = request }
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func turns(_ d: Transcript.Digest) -> Int {
        d.perDayModel.values.flatMap(\.values).map(\.turns).reduce(0, +)
    }

    private func counts(_ d: Transcript.Digest) -> Transcript.Counts {
        var c = Transcript.Counts()
        for models in d.perDayModel.values { for v in models.values { c += v } }
        return c
    }

    func testOneMessageWrittenAsSeveralBlocksIsOneTurn() throws {
        let space = try TestSpace()
        let url = try space.file("s.jsonl", [
            line(id: "msg_1", output: 3),      // thinking, written while the reply was streaming
            line(id: "msg_1", output: 50),     // text
            line(id: "msg_1", output: 50),     // tool call
            line(id: "msg_2", request: "req_2", input: 10, output: 5),
        ].joined(separator: "\n") + "\n")

        let (d, _, keys) = Transcript.digest(url, from: 0, pricing: pricing)
        XCTAssertEqual(turns(d), 2, "three lines of one message are one turn")
        XCTAssertEqual(keys.count, 2)
        let c = counts(d)
        XCTAssertEqual(c.input, 110)
        XCTAssertEqual(c.output, 55, "the complete figure, not the streaming one, and not three of it")
    }

    func testTheSameMessageIdUnderAnotherRequestIsAnotherTurn() throws {
        let space = try TestSpace()
        let url = try space.file("s.jsonl", [
            line(id: "msg_1", request: "req_1"),
            line(id: "msg_1", request: "req_2"),
        ].joined(separator: "\n") + "\n")
        XCTAssertEqual(turns(Transcript.digest(url, from: 0, pricing: pricing).0), 2)
    }

    func testLinesWithoutAnIdAreStillCounted() throws {
        let space = try TestSpace()
        let url = try space.file("s.jsonl", [line(id: nil), line(id: nil)].joined(separator: "\n") + "\n")
        let (d, _, keys) = Transcript.digest(url, from: 0, pricing: pricing)
        XCTAssertEqual(turns(d), 2)
        XCTAssertTrue(keys.isEmpty)
    }

    /// A resumed session copies earlier messages into its own file. Whatever another file has
    /// already been credited with is not counted again.
    func testMessagesAlreadyCountedElsewhereAreSkipped() throws {
        let space = try TestSpace()
        let url = try space.file("resumed.jsonl", [
            line(id: "msg_old"), line(id: "msg_new", request: "req_9"),
        ].joined(separator: "\n") + "\n")
        let old = Transcript.messageKey(id: "msg_old", request: "req_1")
        let (d, _, keys) = Transcript.digest(url, from: 0, pricing: pricing, counted: { $0 == old })
        XCTAssertEqual(turns(d), 1)
        XCTAssertEqual(keys, [Transcript.messageKey(id: "msg_new", request: "req_9")])
    }

    /// A tail parse can start between two blocks of one message.
    func testATailParseDoesNotRecountAMessageSplitAcrossTheOffset() throws {
        let space = try TestSpace()
        let first = line(id: "msg_1") + "\n"
        let url = try space.file("s.jsonl", first)
        let (_, end, keys) = Transcript.digest(url, from: 0, pricing: pricing)
        XCTAssertEqual(end, first.utf8.count)

        try Data((first + line(id: "msg_1") + "\n" + line(id: "msg_2", request: "req_2") + "\n").utf8)
            .write(to: url)
        let seen = Set(keys)
        let (tail, _, more) = Transcript.digest(url, from: end, pricing: pricing,
                                                counted: { seen.contains($0) })
        XCTAssertEqual(turns(tail), 1, "only msg_2 is new")
        XCTAssertEqual(more.count, 1)
    }

    func testDatedSnapshotIdsArePricedAndGroupedUnderTheTableName() throws {
        let space = try TestSpace()
        let url = try space.file("s.jsonl", [
            line(id: "a", model: "claude-haiku-4-5-20251001", input: 1_000_000, output: 0),
        ].joined(separator: "\n") + "\n")
        let d = Transcript.digest(url, from: 0, pricing: pricing).0
        let models = d.perDayModel.values.flatMap(\.keys)
        XCTAssertEqual(models, ["claude-haiku-4-5"])
        XCTAssertEqual(counts(d).usd, 1.0, accuracy: 1e-9)
    }

    func testCanonicalNamesStripOnlyWhatCannotChangeTheModel() {
        XCTAssertEqual(pricing.canonical("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(pricing.canonical("claude-haiku-4-5@20251001"), "claude-haiku-4-5")
        XCTAssertEqual(pricing.canonical("claude-opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(pricing.canonical("claude-3-5-haiku-20241022"), "claude-haiku-3-5")
        // Not a prefix match: an unknown later model must stay unknown, not borrow a price.
        XCTAssertEqual(pricing.canonical("claude-opus-5-7"), "claude-opus-5-7")
        XCTAssertEqual(pricing.cost(model: "claude-opus-5-7", input: 1_000_000, output: 0,
                                    cacheWrite: 0, cacheRead: 0), 0)
        XCTAssertEqual(pricing.cost(model: "claude-opus-5-5", input: 0, output: 0,
                                    cacheWrite: 0, cacheRead: 1_000_000), 0.20, accuracy: 1e-9)
    }

    func testTheShippedTableDecodesAndPricesOpus55() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/Resources/pricing.json")
        let table = try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.cost(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000,
                                  cacheWrite: 0, cacheRead: 0), 24, accuracy: 1e-9)
    }

    /// The context reading is about the conversation in front of you; a subagent's turn is not.
    func testASidechainTurnIsNotTheNewestTurnForContext() throws {
        let space = try TestSpace()
        let url = try space.file("s.jsonl", [
            line(id: "main", at: "2026-09-20T10:00:00.000Z", input: 1000),
            line(id: "sub", request: "req_2", at: "2026-09-20T10:05:00.000Z", input: 9, sidechain: true),
        ].joined(separator: "\n") + "\n")
        let d = Transcript.digest(url, from: 0, pricing: pricing).0
        XCTAssertEqual(d.latest?.contextTokens, 1000)
        XCTAssertEqual(turns(d), 2, "the subagent's turn still counts toward the totals")
    }

    /// Buckets use the offset in force on the turn's own date. With today's offset, a turn at
    /// 23:30 on a summer night moved to the next day once the clocks went back.
    func testDaysAreBucketedByTheOffsetOnThatDate() throws {
        guard let zone = TimeZone(identifier: "Australia/Melbourne") else { throw XCTSkip("no tzdata") }
        let saved = NSTimeZone.default
        NSTimeZone.default = zone
        defer { NSTimeZone.default = saved }
        let space = try TestSpace()
        // 2026-01-15 23:30 AEDT (UTC+11) and 2026-07-15 23:30 AEST (UTC+10).
        let url = try space.file("s.jsonl", [
            line(id: "summer", at: "2026-01-15T12:30:00.000Z"),
            line(id: "winter", request: "req_2", at: "2026-07-15T13:30:00.000Z"),
        ].joined(separator: "\n") + "\n")
        let d = Transcript.digest(url, from: 0, pricing: pricing).0
        let result = Transcript.assemble(d, pricing: pricing, range: .all, subscription: nil)
        XCTAssertEqual(result.trophy.byDay.map(\.0), ["2026-01-15", "2026-07-15"])
    }

    func testMessageKeysAreStableAndFitADouble() {
        let k = Transcript.messageKey(id: "msg_01ABC", request: "req_01XYZ")
        XCTAssertEqual(k, Transcript.messageKey(id: "msg_01ABC", request: "req_01XYZ"))
        XCTAssertNotEqual(k, Transcript.messageKey(id: "msg_01ABC", request: nil))
        XCTAssertNotEqual(Transcript.messageKey(id: "ab", request: "c"),
                          Transcript.messageKey(id: "a", request: "bc"), "the separator matters")
        XCTAssertEqual(Int(Double(k)), k, "survives the JSON cache")
    }

    func testTheWatcherReportsPathsOnceAndFallsBackAfterALoss() {
        let w = TreeWatcher.started()
        XCTAssertEqual(w.drain(), .quiet)
        w.record(["/a.jsonl", "/b.jsonl"], lost: false)
        w.record(["/a.jsonl"], lost: false)
        XCTAssertEqual(w.drain(), .files(["/a.jsonl", "/b.jsonl"]))
        XCTAssertEqual(w.drain(), .quiet, "handed over once")
        w.record(["/c.jsonl"], lost: true)
        XCTAssertEqual(w.drain(), .unknown, "after a loss, list everything")
        XCTAssertEqual(w.drain(), .quiet)
        XCTAssertEqual(TreeWatcher(paths: []).drain(), .unknown, "no stream, no claims")
    }
}
