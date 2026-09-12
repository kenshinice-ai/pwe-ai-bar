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

    /// The rates the app charges Codex turns at, against the figures published for them.
    ///
    /// Written out here rather than read from the same file the code reads, so that this fails
    /// if the table is edited to something else. It is the one number the whole trophy page is
    /// built around, and the source it came from is recorded beside each rate in the file.
    func testCodexModelsArePricedAtTheirPublishedRates() throws {
        let p = try pricing()
        for (model, input, output) in [("gpt-6-astra", 10.0, 50.0),
                                       ("gpt-5.6-sol", 4.0, 20.0),
                                       ("gpt-5.6-luna", 0.2, 1.2),
                                       ("gpt-5.3-codex", 1.75, 14.0)] {
            let r = try XCTUnwrap(p.models[model], model)
            XCTAssertEqual(r.input, input, accuracy: 0.0001, "\(model) input")
            XCTAssertEqual(r.output, output, accuracy: 0.0001, "\(model) output")
            // Cached input is a tenth of the input rate on every one of them, and a cache write
            // is 1.25× from GPT-5.6 on — the same shape as Anthropic's, which is why the
            // defaults carry it and the file does not restate it.
            XCTAssertEqual(r.cacheReadMultiple, 0.10, accuracy: 0.0001, "\(model) cached input")
            XCTAssertEqual(r.cacheWriteMultiple, 1.25, accuracy: 0.0001, "\(model) cache write")
            XCTAssertNotNil(r.source, "\(model) must say where its rate came from")
        }
    }

    /// `codex-auto-review` stays unpriced on purpose.
    ///
    /// It is not a model OpenAI publishes a rate for — openai/codex#20981 is the open question
    /// about exactly that — and the third-party catalogues that do quote one disagree with each
    /// other by a factor of thirty. Counting it as nothing is visible in the interface and
    /// admits what is not known; a guessed rate would quietly move the headline figure.
    func testTheUnpublishedCodexAliasIsNotGivenAPrice() throws {
        let p = try pricing()
        XCTAssertNil(p.models["codex-auto-review"],
                     "no published rate exists for this identifier, so the table must not carry one")
        XCTAssertEqual(p.cost(model: "codex-auto-review", input: 1_000_000, output: 1_000_000,
                              cacheWrite: 0, cacheRead: 0), 0)
    }

    /// Every rate in the shipped table can say where it came from — either its own source or the
    /// file's. A table that mixes two vendors under one source line states something false.
    func testEveryRateHasAProvenance() throws {
        let p = try pricing()
        let fileSource = try XCTUnwrap(p._source)
        XCTAssertFalse(fileSource.isEmpty)
        for (model, rate) in p.models where model.hasPrefix("gpt") {
            XCTAssertNotEqual(rate.source, fileSource,
                              "\(model) is not priced by the file's own source")
            XCTAssertTrue(rate.source?.contains("openai") == true, "\(model) source")
        }
    }

    /// The shipped table decodes at all.
    ///
    /// Not a formality. `load()` catches a decoding error and returns the six-model fallback, so
    /// a single missing key in `pricing.json` does not lose one price — it loses every Anthropic
    /// price too, silently, and the trophy's headline figure changes with nobody told. That is
    /// what a row added without `cacheWriteMultiple` did, before the decoder learned to default.
    func testTheShippedTableDecodesRatherThanFallingBack() throws {
        let url = try XCTUnwrap(Bundle.resources.url(forResource: "pricing", withExtension: "json"))
        let table = try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
        XCTAssertEqual(Pricing.load().models.count, table.models.count,
                       "load() fell back to the built-in table instead of reading the file")
        XCTAssertGreaterThan(table.models.count, Pricing.fallback.models.count)
    }

    /// A row that states only the two prices gets the usual multiples rather than failing.
    func testARowMayOmitTheUsualMultiples() throws {
        let json = Data(#"{"models":{"x":{"input":3,"output":9}},"subscriptionMonthlyUSD":20}"#.utf8)
        let table = try JSONDecoder().decode(Pricing.self, from: json)
        let r = try XCTUnwrap(table.models["x"])
        XCTAssertEqual(r.cacheWriteMultiple, 1.25)
        XCTAssertEqual(r.cacheReadMultiple, 0.10)
    }
}
