import Foundation
import Security
import XCTest
@testable import PWEAIBar

final class CredentialTests: XCTestCase {
    func testUpdateFailureNeverDeletesOrAdds() {
        var adds = 0; var deletes = 0
        let operations = Credentials.Operations(update: { _, _ in errSecAuthFailed },
            add: { _ in adds += 1; return errSecSuccess }, delete: { _ in deletes += 1; return errSecSuccess })
        XCTAssertEqual(Credentials.storeOwnToken("synthetic", operations: operations), .failed(errSecAuthFailed))
        XCTAssertEqual(adds, 0); XCTAssertEqual(deletes, 0)
    }

    func testInsertOnlyWhenMissingAndDeleteFailuresSurface() {
        var adds = 0
        let operations = Credentials.Operations(update: { _, _ in errSecItemNotFound },
            add: { _ in adds += 1; return errSecNotAvailable }, delete: { _ in errSecAuthFailed })
        XCTAssertEqual(Credentials.storeOwnToken("synthetic", operations: operations), .failed(errSecNotAvailable))
        XCTAssertEqual(adds, 1)
        XCTAssertEqual(Credentials.storeOwnToken("", operations: operations), .failed(errSecAuthFailed))
        var absent = operations; absent.delete = { _ in errSecItemNotFound }
        XCTAssertEqual(Credentials.storeOwnToken("", operations: absent), .cleared)
        var update = operations; update.update = { _, _ in errSecSuccess }
        XCTAssertEqual(Credentials.storeOwnToken("replacement", operations: update), .saved)
        XCTAssertEqual(adds, 1)
    }

    @MainActor func testEditorWaitsForResultAndPreservesStateOnFailure() async {
        let editor = TokenEditor(hasToken: true)
        let failed = await editor.submit("synthetic") { _ in
            XCTAssertTrue(editor.isSaving)
            XCTAssertFalse(editor.message.contains("已保存"))
            return .failed(errSecAuthFailed)
        }
        XCTAssertFalse(failed); XCTAssertTrue(editor.hasToken); XCTAssertFalse(editor.isSaving)
        XCTAssertTrue(editor.message.contains("失败"))
        _ = await editor.submit("") { _ in .cleared }
        XCTAssertFalse(editor.hasToken)
        _ = await editor.submit("synthetic") { _ in .saved(.unauthorized) }
        XCTAssertTrue(editor.hasToken)
        XCTAssertTrue(editor.message.contains("失效"))
    }

    func testUnauthorizedDoesNotRetrySameTokenAndReplacementRecovers() async throws {
        for status in [401, 403] {
            let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
            let http = HTTPStub([(status, "{}", [:]), (200, "{\"five_hour\":{\"utilization\":20}}", [:])])
            let p = provider(space, clock: clock, credential: credential, http: http)
            let reading = await p.windows()
            XCTAssertTrue(reading.stale)
            let blocker = await p.blocker
            XCTAssertEqual(blocker, status == 401 ? .unauthorized : .forbidden)
            clock.date.addTimeInterval(3600)
            _ = await p.windows()
            let count = await http.count; XCTAssertEqual(count, 1)
            let result = await p.useOwnToken("  replacement-synthetic  ")
            XCTAssertEqual(result, .saved(.none)); XCTAssertEqual(credential.value, "replacement-synthetic")
            let recovered = await p.windows()
            XCTAssertEqual(recovered.windows.first?.percent, 20); XCTAssertFalse(recovered.stale)
        }
    }

    func testStorageFailureDoesNotInvalidateExistingObservation() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let http = HTTPStub([(200, "{\"five_hour\":{\"utilization\":20}}", [:])])
        let p = provider(space, clock: clock, credential: credential, http: http)
        _ = await p.windows()
        credential.result = .failed(errSecAuthFailed)
        let result = await p.useOwnToken("replacement")
        XCTAssertEqual(result, .failed(errSecAuthFailed)); XCTAssertEqual(credential.value, "synthetic-test-token")
        let rows = await p.windows()
        XCTAssertEqual(rows.windows.first?.percent, 20)
        let count = await http.count; XCTAssertEqual(count, 1)
    }

    /// Claude Code's credential is the one the CLI keeps refreshed and the one that costs no
    /// dialog. A token the user pasted in months ago is the fallback for machines without the
    /// CLI, not the preferred source — and neither path may reach the prompting keychain read.
    func testClaudeCodeCredentialWinsAndOwnTokenIsTheFallback() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        credential.claudeCode = "from-claude-code"
        let http = HTTPStub([(200, "{\"five_hour\":{\"utilization\":11}}", [:]),
                             (200, "{\"five_hour\":{\"utilization\":12}}", [:])])
        let p = provider(space, clock: clock, credential: credential, http: http)
        let live = await p.windows(); XCTAssertFalse(live.stale)
        let source = await p.source; XCTAssertEqual(source, .claudeKeychain)
        XCTAssertGreaterThan(credential.claudeCodeReads, 0)

        credential.claudeCode = nil
        clock.date.addTimeInterval(3600)
        let fallback = provider(space, clock: clock, credential: credential, http: http)
        let second = await fallback.windows(); XCTAssertFalse(second.stale)
        let fallbackSource = await fallback.source; XCTAssertEqual(fallbackSource, .ownToken)
    }

    /// `security -w` hands back hex when the stored bytes are not printable text, and a token
    /// whose recorded scopes exclude profile access cannot read usage however valid it looks.
    func testCredentialParsingCoversHexScopesAndExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1800000000000,"scopes":["user:profile"]}}"#
        let plain = Credentials.parse(json, source: .claudeKeychain)
        XCTAssertEqual(plain?.value, "abc")
        XCTAssertEqual(plain?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))

        let hex = json.utf8.map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(Credentials.parse(hex, source: .claudeKeychain)?.value, "abc")

        XCTAssertNil(Credentials.parse(#"{"claudeAiOauth":{"accessToken":"abc","scopes":["user:inference"]}}"#,
                                       source: .claudeKeychain))
        // No recorded scopes means the CLI never wrote any, which is not evidence against it.
        XCTAssertNotNil(Credentials.parse(#"{"claudeAiOauth":{"accessToken":"abc","scopes":[]}}"#,
                                          source: .claudeKeychain))
        for junk in ["", "   ", "not json", "{}", #"{"claudeAiOauth":{"accessToken":"  "}}"#] {
            XCTAssertNil(Credentials.parse(junk, source: .claudeKeychain), junk)
        }
    }

    func testRetryAfterSecondsHTTPDatesAndInvalidValues() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClaudeProvider.retryDate("3600", now: now), now.addingTimeInterval(3600))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            f.dateFormat = format
            XCTAssertEqual(ClaudeProvider.retryDate(f.string(from: now.addingTimeInterval(120)), now: now), now.addingTimeInterval(120))
        }
        // No usable header is not permission to come back in a minute. This endpoint's windows
        // run for the best part of an hour, and a minute of retries is how a day gets lost.
        for value in [nil, "invalid", "-10", "nan"] as [String?] {
            XCTAssertEqual(ClaudeProvider.retryDate(value, now: now), now.addingTimeInterval(300))
        }
    }

    func testRateLimitPersistsAcrossRestartAndCredentialReplacement() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let http = HTTPStub([(429, "{}", ["Retry-After": "3600"]), (200, "{\"five_hour\":{\"utilization\":20}}", [:])])
        let p = provider(space, clock: clock, credential: credential, http: http)
        _ = await p.windows()
        let restart = provider(space, clock: clock, credential: credential, http: http)
        _ = await restart.useOwnToken("replacement")
        let count = await http.count; XCTAssertEqual(count, 1)
        clock.date.addTimeInterval(3601)
        let reading = await restart.windows()
        XCTAssertFalse(reading.stale)
        let resumed = await http.count; XCTAssertEqual(resumed, 2)
    }

    func testNetworkFailureBacksOffAndRecovers() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let http = HTTPStub([])
        let p = provider(space, clock: clock, credential: credential, http: http)
        _ = await p.windows(); _ = await p.windows()
        let count = await http.count; XCTAssertEqual(count, 1)
        let blocker = await p.blocker; XCTAssertEqual(blocker, .network)
    }

    func testParsingAndDiskCachePreserveGrader() async throws {
        for server in [true, false] {
            let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
            let body = server
                ? "{\"limits\":[{\"kind\":\"session\",\"percent\":96,\"severity\":\"normal\"}]}"
                : "{\"limits\":[{\"kind\":\"session\",\"percent\":96}]}"
            let http = HTTPStub([(200, body, [:])])
            let p = provider(space, clock: clock, credential: credential, http: http)
            let first = await p.windows()
            XCTAssertEqual(first.windows.first?.band, .hot)   // 96% either way; see QuotaTests
            let restart = provider(space, clock: clock, credential: credential, http: http)
            let cached = await restart.windows()
            XCTAssertEqual(cached.windows.first?.gradedBy, server ? .server : .local)
            XCTAssertEqual(cached.windows.first?.band, first.windows.first?.band)
            let count = await http.count; XCTAssertEqual(count, 1)
        }
    }

    func testExpiredCachedWindowDoesNotConfirmRecoveryOffline() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let reset = ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(10))
        let http = HTTPStub([(200, "{\"five_hour\":{\"utilization\":98,\"resets_at\":\"\(reset)\"}}", [:])])
        let p = provider(space, clock: clock, credential: credential, http: http)
        _ = await p.windows()
        clock.date.addTimeInterval(20)
        let reading = await p.windows()
        XCTAssertTrue(reading.stale); XCTAssertNil(reading.windows.first?.percent)
        XCTAssertEqual(reading.windows.first?.note, "待确认")
    }
}
