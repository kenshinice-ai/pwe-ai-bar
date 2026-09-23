import Foundation
import XCTest
@testable import PWEAIBar

/// The live Codex reading: one `codex app-server` process per attempt, so how often it is
/// attempted, and how much work each attempt does, both matter.
final class CodexAppServerTests: XCTestCase {

    private func reply(_ percent: Double, reset: Date) -> [[String: Any]] {
        [["id": 2, "result": ["rateLimitsByLimitId": ["codex": [
            "primary": ["usedPercent": percent, "windowDurationMins": 300,
                        "resetsAt": reset.timeIntervalSince1970]]]]]]
    }

    /// After one success, a server that started failing used to be spawned again on every
    /// sweep past the cache's life — every twenty seconds, each attempt allowed twelve.
    func testFailuresBackOffEvenAfterASuccess() async throws {
        let space = try TestSpace(); let clock = TestClock()
        var attempts = 0
        var answers: [[[String: Any]]] = [reply(40, reset: clock.date.addingTimeInterval(3 * 3600))]
        let server = CodexAppServer(locate: { "/bin/echo" },
                                    exchange: { _, _ in
                                        attempts += 1
                                        return answers.isEmpty ? [] : answers.removeFirst()
                                    },
                                    now: { clock.date })
        let codex = CodexProvider(root: space.root, now: { clock.date }, server: server)

        _ = await codex.windows()
        XCTAssertEqual(attempts, 1)

        clock.date.addTimeInterval(301)                 // past the TTL: try, and fail
        let held = await codex.windows()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(held.first?.percent, 40, "the last good reading is still shown")

        clock.date.addTimeInterval(20)                  // the next sweep: not yet
        _ = await codex.windows()
        XCTAssertEqual(attempts, 2, "one failure waits a minute")

        clock.date.addTimeInterval(45)
        _ = await codex.windows()
        XCTAssertEqual(attempts, 3, "then tries again, and fails again")

        clock.date.addTimeInterval(90)
        _ = await codex.windows()
        XCTAssertEqual(attempts, 3, "two failures wait two minutes")

        clock.date.addTimeInterval(40)
        answers = [reply(55, reset: clock.date.addingTimeInterval(3600))]
        let back = await codex.windows()
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(back.first?.percent, 55)
        XCTAssertFalse(back.first?.isStale ?? true)
    }

    func testTheBackoffDoublesAndStops() {
        XCTAssertEqual(CodexProvider.backoff(1), 60)
        XCTAssertEqual(CodexProvider.backoff(2), 120)
        XCTAssertEqual(CodexProvider.backoff(4), 480)
        XCTAssertEqual(CodexProvider.backoff(10), 900)
    }

    /// The exchange itself, against a stand-in server: an unasked notification first, then the
    /// reply — printed without a trailing newline, which must still count as a reply.
    func testTheExchangeFindsTheReplyAmongNotifications() throws {
        let space = try TestSpace()
        let script = try space.file("codex", """
            #!/bin/bash
            read -r _; read -r _; read -r _
            printf '%s\\n' '{"method":"remoteControl/status/changed","params":{}}'
            printf '%s\\n' '{"id":1,"result":{}}'
            printf '%s' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}'
            exec sleep 30
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let began = Date()
        let replies = CodexAppServer.run(script.path, ["{}", "{}", "{}"])
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "answered, not timed out")
        XCTAssertTrue(replies.contains { ($0["id"] as? NSNumber)?.intValue == 2 })
        XCTAssertTrue(replies.contains { $0["method"] as? String == "remoteControl/status/changed" })
    }
}
