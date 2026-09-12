import XCTest
@testable import PWEAIBar

/// Reading Codex's own rollout logs for what was spent in them.
///
/// Nothing read these for usage until 1.4.0 — the Codex provider opens the same files and looks
/// only at `rate_limits`, which is the quota bar. So a model like `gpt-6-astra` was not merely
/// unpriced, it was absent: no row, no turns, no tokens, on a tree that is 5.5 GB on the machine
/// this was written on.
final class CodexUsageTests: XCTestCase {

    /// The table the app actually ships, which is Anthropic's catalogue and carries no OpenAI
    /// rates at all — the fact the last test here is about.
    private func pricing() throws -> Pricing { Pricing.load() }

    private func rollout(_ space: TestSpace, _ lines: [String]) throws -> URL {
        try space.file("rollout.jsonl", lines.joined(separator: "\n") + "\n")
    }

    private func context(_ rootID: String, model: String) -> String {
        #"{"timestamp":"2026-09-12T07:04:43.652Z","type":"turn_context","payload":"#
            + #"{"root_turn_id":"\#(rootID)","model":"\#(model)","cwd":"/tmp"}}"#
    }

    private func usage(_ rootID: String, at: String = "2026-09-12T07:04:49.772Z",
                       input: Int, cached: Int, output: Int, cacheWrite: Int = 0) -> String {
        #"{"timestamp":"\#(at)","type":"token_usage_record","payload":{"root_turn_id":"\#(rootID)","#
            + #""turn_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"#
            + #""cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output)}}}"#
    }

    /// The model is named once, in a line of its own, and every turn after it carries only an id.
    func testTurnsAreAttributedToTheModelNamedByTheirContext() throws {
        let space = try TestSpace()
        let url = try rollout(space, [
            context("root-a", model: "gpt-6-astra"),
            usage("root-a", input: 1000, cached: 400, output: 50),
            context("root-b", model: "gpt-5.6-luna"),
            usage("root-b", input: 2000, cached: 0, output: 70),
            usage("root-a", input: 500, cached: 100, output: 10),
        ])
        var models: [String: String] = [:]
        let (d, _) = Transcript.codexDigest(url, from: 0, pricing: try pricing(), models: &models)

        var perModel: [String: Transcript.Counts] = [:]
        for (_, byModel) in d.perDayModel {
            for (m, c) in byModel { perModel[m, default: Transcript.Counts()] += c }
        }
        XCTAssertEqual(perModel["gpt-6-astra"]?.turns, 2)
        XCTAssertEqual(perModel["gpt-5.6-luna"]?.turns, 1)
        XCTAssertEqual(models["root-a"], "gpt-6-astra", "the map is handed back for the next pass")
    }

    /// Codex reports the cached part **inside** `input_tokens`; Claude reports it beside them.
    /// Counting both would bill the same tokens twice, and cache reads dominate this workload —
    /// 33 billion of them against 218 million fresh input on the machine this was written on.
    func testTheCachedPartIsNotCountedTwice() throws {
        let space = try TestSpace()
        let url = try rollout(space, [
            context("r", model: "gpt-6-astra"),
            usage("r", input: 1000, cached: 900, output: 20),
        ])
        var models: [String: String] = [:]
        let (d, _) = Transcript.codexDigest(url, from: 0, pricing: try pricing(), models: &models)
        let c = try XCTUnwrap(d.perDayModel.values.first?["gpt-6-astra"])
        XCTAssertEqual(c.input, 100, "fresh input is what was not already cached")
        XCTAssertEqual(c.cacheRead, 900)
    }

    /// A session runs for hours and the file is appended to while it does, so the sweep parses
    /// the tail. The context line naming the model is long behind that offset.
    func testATailParseStillKnowsWhichModelTheTurnUsed() throws {
        let space = try TestSpace()
        let head = [context("r", model: "gpt-6-astra"),
                    usage("r", input: 100, cached: 0, output: 10)].joined(separator: "\n") + "\n"
        let url = try space.file("rollout.jsonl", head)
        var models: [String: String] = [:]
        let (_, end) = Transcript.codexDigest(url, from: 0, pricing: try pricing(), models: &models)

        // The session continues.
        let more = usage("r", input: 300, cached: 0, output: 30) + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()

        var carried = models
        let (tail, _) = Transcript.codexDigest(url, from: end, pricing: try pricing(), models: &carried)
        let c = try XCTUnwrap(tail.perDayModel.values.first?["gpt-6-astra"])
        XCTAssertEqual(c.turns, 1)
        XCTAssertEqual(c.input, 300, "the tail's turn is attributed, not dropped")

        var empty: [String: String] = [:]
        let (orphan, _) = Transcript.codexDigest(url, from: end, pricing: try pricing(), models: &empty)
        XCTAssertTrue(orphan.perDayModel.isEmpty,
                      "without the carried map there is nothing to attribute it to — which is why it is carried")
    }

    /// The context percentage is a Claude measurement: it divides the newest turn's tokens by a
    /// Claude context window. Letting a Codex turn win "newest" would measure a gpt model against
    /// Anthropic's window and print a percentage of nothing.
    func testCodexTurnsNeverBecomeTheContextReading() throws {
        let space = try TestSpace()
        let url = try rollout(space, [
            context("r", model: "gpt-6-astra"),
            usage("r", at: "2099-01-01T00:00:00.000Z", input: 900_000, cached: 0, output: 10),
        ])
        var models: [String: String] = [:]
        let (d, _) = Transcript.codexDigest(url, from: 0, pricing: try pricing(), models: &models)
        XCTAssertNil(d.latest, "a Codex turn must not become the newest turn the context reading uses")
    }

    /// Unpriced is not free, and the interface says so — but it must not be invented either.
    func testCodexModelsCarryNoInventedPrice() throws {
        let p = try pricing()
        for model in ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna", "codex-auto-review"] {
            XCTAssertEqual(p.cost(model: model, input: 1_000_000, output: 1_000_000,
                                  cacheWrite: 0, cacheRead: 0), 0,
                           "\(model) has no published rate in the table; a made-up one would poison the headline figure")
        }
    }
}
