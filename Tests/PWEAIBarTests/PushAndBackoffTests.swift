import Foundation
import XCTest
@testable import PWEAIBar

final class PushAndBackoffTests: XCTestCase {

    /// The settings field says "ntfy / Bark URL". ntfy takes a text body; Bark needs JSON, and
    /// a text body reached it as an empty push.
    func testBarkGetsJSONAndNtfyGetsText() throws {
        let bark = try XCTUnwrap(Notifier.pushRequest("https://api.day.app/KEY", title: "T",
                                                      body: "B", urgent: true))
        XCTAssertEqual(bark.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bark.httpBody)) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "T")
        XCTAssertEqual(json["body"] as? String, "B")
        XCTAssertEqual(json["level"] as? String, "timeSensitive")

        let selfHosted = try XCTUnwrap(Notifier.pushRequest("https://push.example.com/bark/KEY",
                                                            title: "T", body: "B", urgent: false))
        XCTAssertNotNil(selfHosted.value(forHTTPHeaderField: "Content-Type"))

        let ntfy = try XCTUnwrap(Notifier.pushRequest("https://ntfy.sh/topic", title: "T",
                                                      body: "B", urgent: false))
        XCTAssertEqual(ntfy.value(forHTTPHeaderField: "X-Title"), "PWE AI Bar")
        XCTAssertEqual(ntfy.httpBody, Data("T — B".utf8))
        XCTAssertEqual(ntfy.httpMethod, "POST")
    }

    func testNothingIsSentToSomethingThatIsNotAWebAddress() {
        XCTAssertNil(Notifier.pushRequest("", title: "T", body: "B", urgent: false))
        XCTAssertNil(Notifier.pushRequest("file:///etc/passwd", title: "T", body: "B", urgent: false))
        XCTAssertNil(Notifier.pushRequest("not a url", title: "T", body: "B", urgent: false))
    }

    /// A 429 with no Retry-After used to wait five minutes every time, however many times in a
    /// row it had been refused. The server's own figure still wins whenever it gives one.
    func testRepeatedRefusalsWaitLongerUnlessTheServerSays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClaudeProvider.retryDate(nil, now: now), now.addingTimeInterval(300))
        XCTAssertEqual(ClaudeProvider.retryDate(nil, now: now, streak: 1), now.addingTimeInterval(600))
        XCTAssertEqual(ClaudeProvider.retryDate(nil, now: now, streak: 3), now.addingTimeInterval(2400))
        XCTAssertEqual(ClaudeProvider.retryDate(nil, now: now, streak: 9), now.addingTimeInterval(2400))
        XCTAssertEqual(ClaudeProvider.retryDate("120", now: now, streak: 5), now.addingTimeInterval(120))
    }
}
