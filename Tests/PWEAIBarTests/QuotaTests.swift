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
    /// The app server answers for right now, which the rollout logs cannot: they only record
    /// what Codex saw the last time it ran. It also carries two things the logs never do.
    func testAppServerMappingKeepsPoolsApartAndReadsPlanAndResetCredits() async {
        let json = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":83,"windowDurationMins":300,"resetsAt":1788613424}},
         "rateLimitsByLimitId":{
           "codex":{"limitId":"codex","planType":"team",
                    "primary":{"usedPercent":83,"windowDurationMins":300,"resetsAt":1788613424},
                    "secondary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":1789105851},
                    "rateLimitReachedType":null},
           "premium":{"limitId":"premium","primary":null,"secondary":null,
                      "rateLimitReachedType":"workspace_member_credits_depleted"}},
         "rateLimitResetCredits":{"availableCount":2}}
        """
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let reading = await CodexAppServer().map(object)

        XCTAssertEqual(reading.planType, "team")
        XCTAssertEqual(reading.resetCredits, 2)
        XCTAssertEqual(reading.windows.map(\.percent), [83, 44, nil])
        XCTAssertEqual(reading.windows.map(\.title), ["五小时窗口", "周窗口", "附加额度"])
        XCTAssertEqual(reading.windows.map(\.id), ["codex_300", "codex_10080", "codex_credits"])
        // The spent add-on pool is its own row, never the quota's headline.
        XCTAssertFalse(reading.windows[0].confirmedExhausted)
        XCTAssertTrue(reading.windows[2].confirmedExhausted)
        XCTAssertEqual(reading.windows[0].resetsAt, Date(timeIntervalSince1970: 1788613424))
    }

    func testAppServerIgnoresNonsenseAndSurvivesAnEmptyAnswer() async {
        let server = CodexAppServer()
        for body in ["{}", #"{"rateLimitsByLimitId":{}}"#,
                     #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":"lots"}}}}"#,
                     #"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":140,"windowDurationMins":300}}}}"#] {
            let object = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            let reading = await server.map(object)
            XCTAssertTrue(reading.windows.isEmpty, body)
        }
        // No usable reply at all means fall back to the logs, not report zero usage.
        let quiet = CodexAppServer(locate: { "/nonexistent/codex" }, exchange: { _, _ in [] })
        let none = await quiet.read()
        XCTAssertNil(none)
    }

    /// Unsolicited notifications interleave with replies; matching by id is what keeps them out.
    func testRepliesAreMatchedByIdNotByArrivalOrder() async {
        let noise: [[String: Any]] = [
            ["method": "remoteControl/status/changed", "params": ["status": "disabled"]],
            ["id": 1, "result": ["userAgent": "x"]],
            ["id": 2, "result": ["rateLimitsByLimitId": ["codex": ["planType": "pro",
                "primary": ["usedPercent": 5, "windowDurationMins": 300]]]]],
        ]
        let server = CodexAppServer(locate: { "/bin/echo" }, exchange: { _, _ in noise })
        let reading = await server.read()
        XCTAssertEqual(reading?.planType, "pro")
        XCTAssertEqual(reading?.windows.first?.percent, 5)
    }

    /// The pace figures need no stored history: the window's own length says when it opened,
    /// and the percentage says how much has gone since. What they must not do is answer at all
    /// when the answer would be noise.
    func testPaceProjectionAnswersOnlyWhenTheAnswerMeansSomething() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(percent: Double?, resetIn: TimeInterval, length: TimeInterval?,
                    stale: Bool = false) -> QuotaWindow {
            // `observedAt` matters now: the pace is anchored to when the reading was taken,
            // and a reading older than ten minutes gets no forecast at all.
            QuotaWindow(id: "five_hour", provider: .claude, channel: .session, title: "t",
                        percent: percent, resetsAt: now.addingTimeInterval(resetIn),
                        observedAt: now, isStale: stale,
                        confirmedExhausted: (percent ?? 0) >= 99.5, windowLength: length)
        }
        // Three hours into a five-hour window with 70% gone: 23.3%/h, and the line crosses 100%
        // about 43 minutes before the window would have rolled over.
        let racing = window(percent: 70, resetIn: 2 * 3600, length: 5 * 3600).forecast(at: now)
        let rate = try XCTUnwrap(racing.rate)
        XCTAssertEqual(racing.evidence?.isMeasured, false, "no samples yet: this is the average")
        XCTAssertEqual(rate.low, 23.0, accuracy: 0.01)
        XCTAssertEqual(rate.high, 71.0 / 3, accuracy: 0.01)
        // Even at the slowest rate the reading allows, the tank is dry about 42 minutes before
        // the window would have rolled over on its own — so the shortfall is a guarantee, not a
        // projection from one fitted number.
        guard case .fallsShort(let gap) = racing.verdict else {
            return XCTFail("70 % three hours in must be called short: \(racing.verdict)")
        }
        XCTAssertEqual(gap, 2_400, accuracy: 60, "floored to the same grain as the headline")
        XCTAssertEqual(racing.tone, .hot)
        XCTAssertEqual(try XCTUnwrap(racing.enduranceLow), 4_563, accuracy: 60)

        // Comfortably inside the window: there is a rate, and the answer is that it does not
        // matter — stated as the floor of what will be left rather than as a crossing.
        let easy = window(percent: 20, resetIn: 2 * 3600, length: 5 * 3600).forecast(at: now)
        XCTAssertNotNil(easy.rate)
        guard case .makesIt(let spare) = easy.verdict else {
            return XCTFail("20 % three hours in makes it: \(easy.verdict)")
        }
        XCTAssertEqual(spare, 66, accuracy: 0.5)
        XCTAssertEqual(easy.tone, .plain)
        XCTAssertFalse(easy.headlineIsEndurance, "the reset is what actually happens, so it leads")

        // A window barely touched used to be refused a forecast on a floor of five percent.
        // The bracket makes the floor unnecessary: two percent over four hours is [0.25, 0.75]
        // %/h, which is wide in ratio and decisive in effect.
        let untouched = window(percent: 2, resetIn: 3600, length: 5 * 3600).forecast(at: now)
        guard case .makesIt = untouched.verdict else {
            return XCTFail("2 % four hours in makes it: \(untouched.verdict)")
        }

        for (label, w, expected) in [
            ("no window length", window(percent: 70, resetIn: 3600, length: nil),
             Forecast.Thinness.noWindowLength),
            ("no reading", window(percent: nil, resetIn: 3600, length: 5 * 3600), .noPercent),
            ("barely started", window(percent: 70, resetIn: 5 * 3600 - 60, length: 5 * 3600),
             .tooEarlyInWindow),
            ("stale reading", window(percent: 70, resetIn: 3600, length: 5 * 3600, stale: true),
             .readingTooOld),
        ] {
            let f = w.forecast(at: now)
            XCTAssertNil(f.rate, label)
            XCTAssertEqual(f.verdict, .sampling, label)
            XCTAssertEqual(f.thinness, expected, label)
            XCTAssertEqual(f.verdictText, "还在采样", label)
        }

        // An hour with no new reading is not thin evidence, it is silence, and it is named.
        let silent = QuotaWindow(id: "five_hour", provider: .claude, channel: .session,
                                 title: "t", percent: 70, resetsAt: now.addingTimeInterval(3600),
                                 observedAt: now.addingTimeInterval(-3600), windowLength: 5 * 3600)
        XCTAssertEqual(silent.forecast(at: now).verdict, .blind(since: 3600))

        // The two that are not "wait": one is a fact, the other has no timeline to draw on.
        XCTAssertEqual(window(percent: 100, resetIn: 3600, length: 5 * 3600).forecast(at: now).verdict,
                       .spent)
        XCTAssertEqual(window(percent: 70, resetIn: -60, length: 5 * 3600).forecast(at: now).verdict,
                       .noTimeline(.resetPassed))
    }

    /// A weekly window is seven days long whichever way the reading arrives, including out of
    /// the disk cache — without that, the projection silently stops working after a restart.
    func testWindowLengthsSurviveParsingAndTheDiskCache() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let body = #"{"limits":[{"kind":"session","percent":40,"resets_at":"2027-01-15T08:00:00Z"},"#
            + #"{"kind":"weekly_all","percent":10,"resets_at":"2027-01-20T08:00:00Z"}]}"#
        let http = HTTPStub([(200, body, [:])])
        let p = provider(space, clock: clock, credential: credential, http: http)
        let first = await p.windows()
        XCTAssertEqual(first.windows.map(\.windowLength), [5 * 3600, 7 * 86400])

        let restart = provider(space, clock: clock, credential: credential, http: http)
        let cached = await restart.windows()
        XCTAssertEqual(cached.windows.map(\.windowLength), [5 * 3600, 7 * 86400],
                       "a length lost on reload is a projection that quietly stops working")
    }

    /// From the audit: a failed refresh used to overwrite the *success* time, so a miss extended
    /// the life of the value it had failed to replace — and the panel went on presenting it as
    /// current. Attempting and succeeding are now two different clocks.
    func testAFailedRefreshDoesNotMakeTheOldReadingLookNewer() async throws {
        let space = try TestSpace(); let clock = TestClock()
        var replies: [[[String: Any]]] = [
            [["id": 2, "result": ["rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 40, "windowDurationMins": 300,
                            "resetsAt": clock.date.addingTimeInterval(3600).timeIntervalSince1970]]]]]],
            [],   // the next attempt fails
        ]
        let server = CodexAppServer(locate: { "/bin/echo" },
                                    exchange: { _, _ in replies.isEmpty ? [] : replies.removeFirst() },
                                    now: { clock.date })
        let codex = CodexProvider(root: space.root, now: { clock.date }, server: server)

        let first = await codex.windows()
        XCTAssertEqual(first.first?.percent, 40)
        XCTAssertFalse(first.first?.isStale ?? true)

        // Past the cache's life, and the refresh fails. The figure may be shown; it may not be
        // shown as current.
        clock.date.addTimeInterval(301)
        let held = await codex.windows()
        XCTAssertEqual(held.first?.percent, 40, "last good is still worth showing")
        XCTAssertTrue(held.first?.isStale ?? false, "but not as a fresh reading")
        XCTAssertNil(held.first?.forecast(at: clock.date).rate, "and nothing is forecast from it")

        // Past its own reset it is not merely stale — it describes a window that has gone.
        clock.date.addTimeInterval(3600)
        let expired = await codex.windows()
        XCTAssertNil(expired.first?.percent)
        XCTAssertEqual(expired.first?.note, "待确认")
        XCTAssertFalse(expired.first?.confirmedExhausted ?? true)
    }

}
