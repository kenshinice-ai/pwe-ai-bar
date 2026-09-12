import XCTest
@testable import PWEAIBar

/// The update check is the only thing this app tells another server about itself, so the tests
/// that matter most are the ones about what it does *not* send and when it does *not* run.
final class UpdateCheckTests: XCTestCase {

    // MARK: What leaves the machine

    /// The payload is the whole privacy promise, and the settings note prints it as three things.
    /// This fails the moment a fourth is added, which is the point: a field can only be added
    /// deliberately, with the note and this test changed to match.
    func testPayloadIsThreeFieldsAndNamesNoMachine() {
        let payload = UpdateCheck.payload(version: "1.1.6")
        XCTAssertEqual(Set(payload.keys), ["product", "version", "os"])
        XCTAssertEqual(payload["product"], "aibar")
        XCTAssertEqual(payload["version"], "1.1.6")
        // Loan Bar sends a fingerprint because it counts seats against a licence. This app has
        // no licence, so it has nothing to count and asks for nothing it cannot use.
        for forbidden in ["machine", "order", "tier", "state", "token", "account"] {
            XCTAssertNil(payload[forbidden], "payload must not carry \(forbidden)")
        }
    }

    // MARK: Version comparison

    func testNewerIsNumericNotLexical() {
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.0"), "1.10 is after 1.9")
        XCTAssertTrue(UpdateCheck.isNewer("1.2.0", than: "1.1.6"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.6", than: "1.1.6"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.5", than: "1.1.6"))
        XCTAssertTrue(UpdateCheck.isNewer("1.2", than: "1.1.9"), "a short version still compares")
        XCTAssertFalse(UpdateCheck.isNewer("nonsense", than: "1.0.0"))
    }

    // MARK: Consent

    @MainActor func testSilentUntilAsked() async throws {
        let space = try TestSpace()
        var calls = 0
        let updates = UpdateCheck(defaults: space.defaults, now: { Date() },
                                  fetch: { _ in calls += 1; throw CancellationError() })
        await updates.checkIfDue(enabled: nil)      // never asked
        await updates.checkIfDue(enabled: false)    // asked, said no
        XCTAssertEqual(calls, 0, "no consent, no request")
        XCTAssertNil(updates.available)
    }

    @MainActor func testAtMostOncePerDay() async throws {
        let space = try TestSpace()
        let clock = TestClock()
        var calls = 0
        let updates = UpdateCheck(defaults: space.defaults, now: { clock.date },
                                  fetch: { _ in
                                      calls += 1
                                      return (Self.body("1.9.9"), Self.ok)
                                  })
        await updates.checkIfDue(enabled: true)
        XCTAssertEqual(calls, 1)
        clock.date += 60 * 60
        await updates.checkIfDue(enabled: true)
        XCTAssertEqual(calls, 1, "an hour later is not a new day")
        clock.date += 24 * 60 * 60
        await updates.checkIfDue(enabled: true)
        XCTAssertEqual(calls, 2)
    }

    /// A failure must be retried on the next launch, not parked for twenty-four hours — the
    /// offline case is the common one and it should cost the reader nothing.
    @MainActor func testAFailedCheckIsNotRecordedAsDone() async throws {
        let space = try TestSpace()
        let clock = TestClock()
        var calls = 0
        let updates = UpdateCheck(defaults: space.defaults, now: { clock.date },
                                  fetch: { _ in calls += 1; throw URLError(.notConnectedToInternet) })
        await updates.checkIfDue(enabled: true)
        await updates.checkIfDue(enabled: true)
        XCTAssertEqual(calls, 2, "offline today must not cost tomorrow's check")
    }

    // MARK: What it does with the answer

    @MainActor func testOnlyANewerVersionSurfaces() async throws {
        let space = try TestSpace()
        let updates = UpdateCheck(defaults: space.defaults, now: { Date() },
                                  fetch: { _ in (Self.body("1.1.0"), Self.ok) })
        await updates.check(version: "1.1.6")
        XCTAssertNil(updates.available, "an older server version is not an update")
    }

    @MainActor func testDismissSilencesThatVersionOnly() async throws {
        let space = try TestSpace()
        let clock = TestClock()
        var answer = "1.2.0"
        let updates = UpdateCheck(defaults: space.defaults, now: { clock.date },
                                  fetch: { _ in (Self.body(answer), Self.ok) })
        await updates.check(version: "1.1.6")
        XCTAssertEqual(updates.available?.version, "1.2.0")
        updates.dismiss()
        XCTAssertNil(updates.available)

        await updates.check(version: "1.1.6")
        XCTAssertNil(updates.available, "the dismissed version stays quiet")

        answer = "1.3.0"
        await updates.check(version: "1.1.6")
        XCTAssertEqual(updates.available?.version, "1.3.0", "but a later one speaks up")
    }

    /// A field this build has never heard of must not stop an old copy from learning there is a
    /// new one — the old copy is exactly the one that needs to.
    @MainActor func testAnUnknownFieldDoesNotBreakTheAnswer() async throws {
        let space = try TestSpace()
        let json = #"{"version":"2.0.0","published":"2026-10-01","channel":"beta","minimumOS":"14.0"}"#
        let updates = UpdateCheck(defaults: space.defaults, now: { Date() },
                                  fetch: { _ in (Data(json.utf8), Self.ok) })
        await updates.check(version: "1.1.6")
        XCTAssertEqual(updates.available?.version, "2.0.0")
    }

    @MainActor func testNotesFollowTheInterfaceLanguage() {
        let release = UpdateCheck.Release(version: "1.2.0", published: nil,
                                          notes_en: "English note", notes_cn: "中文说明",
                                          download: nil)
        Loc.language = .zhHans
        XCTAssertEqual(release.notes, "中文说明")
        Loc.language = .en
        XCTAssertEqual(release.notes, "English note")
        Loc.language = .system
    }

    // MARK: Helpers

    private static let ok = HTTPURLResponse(url: URL(string: "https://pwestudio.site/app/check")!,
                                            statusCode: 200, httpVersion: nil, headerFields: nil)!

    private static func body(_ version: String) -> Data {
        Data(#"{"version":"\#(version)","published":"2026-09-12"}"#.utf8)
    }
}
