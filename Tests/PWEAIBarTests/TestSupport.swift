import Foundation
import XCTest
@testable import PWEAIBar

final class TestSpace {
    let root: URL
    let defaults: UserDefaults
    private let suite = "PWEAIBarTests.\(UUID().uuidString)"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PWEAIBarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }
    deinit {
        // Clearing the domain empties it but leaves cfprefsd holding a file it will write back
        // on exit. Without this, every `swift test` run litters ~/Library/Preferences for good.
        defaults.removePersistentDomain(forName: suite)
        defaults.removeSuite(named: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist"))
        try? FileManager.default.removeItem(at: root)
    }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
}

final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

func event(_ session: String = "session", kind: AgentEvent.Kind = .waiting, at: Date,
           id: String = UUID().uuidString) -> AgentEvent {
    AgentEvent(id: session, provider: .claude, kind: kind, text: "Synthetic event", at: at, eventID: id)
}

func codexLine(at: Date?, id: String? = "codex", pct: Double = 80,
               reset: Date, extra: [String: Any] = [:]) throws -> String {
    var rl: [String: Any] = ["primary": ["used_percent": pct, "window_minutes": 300,
                                                     "resets_at": reset.timeIntervalSince1970]]
    if let id { rl["limit_id"] = id }
    rl.merge(extra) { _, new in new }
    var row: [String: Any] = ["type": "event_msg", "payload": ["rate_limits": rl]]
    if let at { row["timestamp"] = ISO8601DateFormatter().string(from: at) }
    return String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)! + "\n"
}

actor HTTPStub {
    var replies: [(Int, String, [String: String])]
    private(set) var count = 0
    init(_ replies: [(Int, String, [String: String])]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        count += 1
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, body, headers) = replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: headers)!)
    }
}

final class FakeCredential {
    var value: String? = "synthetic-test-token"
    /// What Claude Code's own credential would hand back. Nil means "the CLI never logged in".
    var claudeCode: String?
    /// When Claude Code's stored credential expires. Nil means "no expiry recorded", which the
    /// provider must read as usable rather than as unknown-and-therefore-bad.
    var claudeCodeExpiry: Date?
    var claudeCodeReads = 0
    var result: Credentials.SaveResult = .saved
    var access: ClaudeProvider.Access {
        .init(own: { self.value.map { .init(value: $0, expiresAt: nil, source: .ownToken) } },
              claudeCode: {
                  self.claudeCodeReads += 1
                  return self.claudeCode.map {
                      .init(value: $0, expiresAt: self.claudeCodeExpiry, source: .claudeKeychain)
                  }
              },
              sharedExists: { false }, shared: { XCTFail("Unexpected shared keychain read"); return nil },
              save: { text in
                  if case .failed = self.result { return self.result }
                  self.value = text.isEmpty ? nil : text
                  return text.isEmpty ? .cleared : .saved
              })
    }
}

func provider(_ space: TestSpace, clock: TestClock, credential: FakeCredential,
              http: HTTPStub) -> ClaudeProvider {
    ClaudeProvider(defaults: space.defaults, cacheURL: space.root.appendingPathComponent("quota.json"),
                   access: credential.access, now: { clock.date }, request: { try await http.send($0) }, fallback: { nil })
}
