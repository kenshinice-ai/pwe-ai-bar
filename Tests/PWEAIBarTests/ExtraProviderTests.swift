import Foundation
import XCTest
@testable import PWEAIBar

/// None of these five tools is installed on the machine this was written on, so every one of
/// them is mapped from its documented contract and has never been compared against a live
/// dashboard. These tests pin the shape of that contract: what counts as signed out, which field
/// carries the percentage, and — for the three that report what is *left* — that it gets turned
/// around before it reaches a bar that draws what is *spent*.
final class ExtraProviderTests: XCTestCase {

    /// Pinned: these assert on copy that is localised now, and `.system` would follow whatever
    /// language the machine running the tests uses.
    override func setUp() { super.setUp(); Loc.language = .en }
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func reply(_ status: Int, _ body: String) -> ExtraProviders.Transport {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: Percent direction

    private func object(_ body: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
    }

    func testDevinAndAntigravityReportWhatIsLeftAndItIsTurnedAround() {
        let devin = """
        {"userStatus":{"planStatus":{
          "dailyQuotaRemainingPercent":30,"dailyQuotaResetAtUnix":1800003600,
          "weeklyQuotaRemainingPercent":90,"weeklyQuotaResetAtUnix":1800600000,
          "planInfo":{"planName":"team_pro","hideDailyQuota":false}}}}
        """
        let d = ExtraProviders.Devin.map(object(devin), now: clock)
        XCTAssertEqual(d?.windows.map(\.percent), [70, 10], "30% left is 70% used")
        XCTAssertEqual(d?.plan, "Team Pro")
        XCTAssertEqual(d?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        // A plan that hides the daily figure must not have one invented for it.
        let hidden = devin.replacingOccurrences(of: "\"hideDailyQuota\":false", with: "\"hideDailyQuota\":true")
        XCTAssertEqual(ExtraProviders.Devin.map(object(hidden), now: clock)?.windows.count, 1)

        let antigravity = """
        {"response":{"groups":[{"buckets":[
          {"bucketId":"gemini_pro","remainingFraction":0.25,"resetTime":"2027-01-15T08:00:00Z"},
          {"bucketId":"claude_sonnet","remainingFraction":1.0}]}]}}
        """
        let a = ExtraProviders.Antigravity.map(object(antigravity), now: clock)
        XCTAssertEqual(a?.windows.map(\.percent), [75, 0], "0.25 left is 75% used")
        XCTAssertEqual(a?.windows.map(\.title), ["Gemini Pro", "Claude Sonnet"])
        XCTAssertFalse(a?.windows[1].confirmedExhausted ?? true, "a full bucket is not a spent one")
    }

    func testCursorAndGrokReportWhatIsSpentAndItIsLeftAlone() {
        let cursor = """
        {"enabled":true,"billingCycleEnd":"2027-02-01T00:00:00Z",
         "planUsage":{"totalPercentUsed":64,"autoPercentUsed":12,"apiPercentUsed":0}}
        """
        let c = ExtraProviders.Cursor.map(object(cursor), now: clock)
        XCTAssertEqual(c?.windows.map(\.percent), [64, 12, 0])
        XCTAssertEqual(c?.windows.map(\.title), ["This period", "Auto", "API"])
        // A disabled dashboard has no reading to report, which is not the same as zero usage.
        let off = cursor.replacingOccurrences(of: "\"enabled\":true", with: "\"enabled\":false")
        XCTAssertNil(ExtraProviders.Cursor.map(object(off), now: clock))

        let grok = """
        {"config":{"creditUsagePercent":41,
                   "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":1800600000}}}
        """
        let g = ExtraProviders.Grok.map(object(grok), now: clock)
        XCTAssertEqual(g?.windows.first?.percent, 41)
        XCTAssertEqual(g?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_600_000))
        // Any other period type is a billing cycle, and calling it a quota window is a lie.
        let monthly = grok.replacingOccurrences(of: "USAGE_PERIOD_TYPE_WEEKLY",
                                                with: "USAGE_PERIOD_TYPE_MONTHLY")
        XCTAssertNil(ExtraProviders.Grok.map(object(monthly), now: clock))
    }

    // MARK: Copilot, which is the only one with two response shapes

    func testCopilotSkipsUnlimitedBucketsAndFallsBackToTheOlderShape() {
        // Exercised through the mapper rather than `read`, which needs a token on disk.
        let modern = """
        {"copilot_plan":"individual","quota_reset_date":"2027-03-01",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"remaining":75},
           "chat":{"unlimited":true,"entitlement":-1,"remaining":-1},
           "completions":{"percent_remaining":40}}}
        """
        let reading = ExtraProviders.Copilot.map(object(modern), now: clock)
        XCTAssertEqual(reading?.windows.map(\.title), ["Premium", "Completions"],
                       "an unlimited bucket has no ratio to draw")
        XCTAssertEqual(reading?.windows.map(\.percent), [75, 60])
        XCTAssertEqual(reading?.plan, "Individual")
        // A bare calendar date is UTC midnight; read as local it would move the reset a day.
        XCTAssertEqual(reading?.windows.first?.resetsAt,
                       ISO8601DateFormatter.parse("2027-03-01T00:00:00Z"))

        let legacy = """
        {"limited_user_reset_date":"2027-03-01",
         "monthly_quotas":{"chat":100,"completions":500},
         "limited_user_quotas":{"chat":25,"completions":500}}
        """
        let old = ExtraProviders.Copilot.map(object(legacy), now: clock)
        XCTAssertEqual(old?.windows.map(\.percent), [75, 0])
    }

    // MARK: Telling failures apart

    func testRefusedIsNotOfflineAndOfflineIsNotSignedOut() async {
        let cases: [(Int, String, ExtraSource.Connection)] = [
            (401, "{}", .signedOut),
            (403, "{}", .signedOut),
            (500, "{}", .unavailable("the endpoint returned 500")),
            (200, "not json", .unavailable("the endpoint returned 200")),
            (200, "{}", .unsupported("this account exposes no readable quota")),
        ]
        for (status, body, expected) in cases {
            let request = ExtraSource.request("https://example.invalid/x", headers: [:])!
            let answer = await ExtraSource.send(request, via: reply(status, body))
            let reading = ExtraProviders.outcome(answer) { root in
                ExtraSource.object(root["planUsage"]).map { _ in ExtraSource.Reading() }
            }
            XCTAssertEqual(reading.connection, expected, "\(status) \(body)")
        }
        // A transport that throws is a network problem, never a credential problem.
        let dead: ExtraProviders.Transport = { _ in throw URLError(.notConnectedToInternet) }
        let request = ExtraSource.request("https://example.invalid/x", headers: [:])!
        let none = await ExtraSource.send(request, via: dead)
        XCTAssertNil(none)
        XCTAssertEqual(ExtraProviders.outcome(none) { _ in ExtraSource.Reading() }.connection,
                       .unavailable("No reading just now — retrying later"))
    }

    // MARK: Value parsing

    func testTimestampsSecondsMillisecondsAndPlainDatesAllLand() {
        XCTAssertEqual(ExtraSource.date(1_800_000_000), clock)
        XCTAssertEqual(ExtraSource.date(1_800_000_000_000), clock, "milliseconds by magnitude")
        XCTAssertEqual(ExtraSource.date("1800000000"), clock)
        XCTAssertEqual(ExtraSource.date("2027-01-15T08:00:00Z"),
                       ISO8601DateFormatter.parse("2027-01-15T08:00:00Z"))
        for junk in [nil, "", "   ", "not a date", 0, -1, Double.nan] as [Any?] {
            XCTAssertNil(ExtraSource.date(junk), String(describing: junk))
        }
    }

    func testFlatConfigValuesAndKeyringEnvelopes() {
        let yaml = "github.com:\n    user: someone\n    oauth_token: gho_synthetic\n"
        XCTAssertEqual(ExtraSource.flatValue(yaml, key: "oauth_token"), "gho_synthetic")
        let toml = "windsurf_api_key = \"synthetic-key\"\napi_server_url = \"https://example.test\"\n"
        XCTAssertEqual(ExtraSource.flatValue(toml, key: "windsurf_api_key"), "synthetic-key")
        XCTAssertNil(ExtraSource.flatValue(toml, key: "missing"))
        XCTAssertEqual(ExtraSource.unwrap(#"{"Data":"wrapped"}"#), "wrapped")
        XCTAssertEqual(ExtraSource.unwrap("bare"), "bare")
        XCTAssertNil(ExtraSource.unwrap("{}"))
    }

    func testPlanLabelsKeepTheVendorsOwnWords() {
        XCTAssertEqual(ExtraSource.planLabel("pro_plus"), "Pro Plus")
        XCTAssertEqual(ExtraSource.planLabel("team"), "Team")
        XCTAssertNil(ExtraSource.planLabel(""))
        XCTAssertNil(ExtraSource.planLabel(String(repeating: "x", count: 64)))
        XCTAssertNil(ExtraSource.planLabel(42))
    }

    // MARK: The store around them

    func testProvidersAreAskedInParallelAndOneStallDoesNotHoldUpTheRest() async {
        let slow = Provider.cursor
        let store = ExtraStore(now: { self.clock }) { p, _ in
            if p == slow { try? await Task.sleep(for: .milliseconds(400)) }
            return ExtraSource.Reading(
                windows: [QuotaWindow(id: "\(p.rawValue)_w", provider: p, channel: .other,
                                      title: "w", percent: 10)],
                plan: p.rawValue, connection: .connected)
        }
        let started = Date()
        let result = await store.read([.cursor, .copilot, .devin, .grok])
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertEqual(result.plans.count, 4)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2, "four in parallel, not in turn")
    }

    func testAnsweredProvidersAreNotAskedAgainUntilTheirOwnTimeIsUp() async {
        var calls = 0
        var connection = ExtraSource.Connection.notInstalled
        var clock = self.clock
        let store = ExtraStore(now: { clock }) { p, _ in
            calls += 1
            return ExtraSource.Reading(connection: connection)
        }
        _ = await store.read([.grok])
        _ = await store.read([.grok])
        XCTAssertEqual(calls, 1, "a tool nobody installed is not looked for every refresh")

        clock.addTimeInterval(1801)
        connection = .connected
        _ = await store.read([.grok])
        XCTAssertEqual(calls, 2)
        clock.addTimeInterval(200)
        _ = await store.read([.grok])
        XCTAssertEqual(calls, 2, "a calm connected reading holds for five minutes")
        clock.addTimeInterval(200)
        _ = await store.read([.grok])
        XCTAssertEqual(calls, 3)
    }

    /// The one that matters on a machine like this one: nothing is installed, so nothing is
    /// asked, and no credential goes anywhere.
    func testNothingInstalledMeansNoRequestAndNoWindows() async {
        var asked = 0
        let transport: ExtraProviders.Transport = { _ in
            asked += 1
            throw URLError(.badURL)
        }
        for p in [Provider.cursor, .devin, .grok, .antigravity] where !ExtraProviders.installed(p) {
            let reading = await ExtraProviders.read(p, now: { self.clock }, transport: transport)
            XCTAssertEqual(reading.connection, .notInstalled, p.rawValue)
            XCTAssertTrue(reading.windows.isEmpty)
        }
        XCTAssertEqual(asked, 0, "a provider with no credential is never contacted")
    }

    @MainActor func testGeminiIsListedAsUnreadableRatherThanQuietlyMissing() throws {
        XCTAssertNotNil(Provider.gemini.unavailableReason)
        XCTAssertNil(Provider.claude.unavailableReason)
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        prefs.setTracking(.gemini, true)
        XCTAssertFalse(prefs.tracks(.gemini), "a provider with no source is never queried")
        // The five that are not this app's subject stay off until someone turns them on: doing
        // otherwise sends a credential found on disk to a vendor nobody asked us to contact.
        XCTAssertTrue(prefs.tracks(.claude))
        XCTAssertTrue(prefs.tracks(.codex))
        for p in [Provider.cursor, .copilot, .devin, .grok, .antigravity] {
            XCTAssertFalse(prefs.tracks(p), p.rawValue)
        }
    }
}
