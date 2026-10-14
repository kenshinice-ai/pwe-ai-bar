import Foundation
import XCTest
@testable import PWEAIBar

/// Finding Claude Code, and running exactly one command that cannot reach the model.
final class ClaudeRenewerTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("renewer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func desktopCopy(_ home: URL, _ version: String) throws -> URL {
        let url = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code/\(version)/abc/claude.app/Contents/MacOS/claude")
        try executable(url)
        return url
    }

    func testTheTerminalInstallWinsOverTheDesktopCopy() throws {
        let home = try home()
        _ = try desktopCopy(home, "2.1.295")
        let terminal = home.appendingPathComponent(".local/bin/claude")
        try executable(terminal)
        XCTAssertEqual(ClaudeRenewer.locateCLI(home: home, path: "")?.path, terminal.path)
    }

    /// Versions compare as numbers: 2.1.1000 is newer than 2.1.295, which a string sort gets wrong.
    func testOtherwiseTheNewestDesktopCopy() throws {
        let home = try home()
        _ = try desktopCopy(home, "2.1.99")
        _ = try desktopCopy(home, "2.1.295")
        let newest = try desktopCopy(home, "2.1.1000")
        XCTAssertEqual(ClaudeRenewer.locateCLI(home: home, path: "")?.path, newest.path)
    }

    func testNoClaudeCodeMeansNothingRuns() {
        var ran = false
        let renewer = ClaudeRenewer(locate: { nil }, run: { _, _, _ in ran = true; return true })
        XCTAssertFalse(renewer.renew())
        XCTAssertFalse(ran)
    }

    /// The one command, from the one place, without a host's token: Claude Code must use the login
    /// in the keychain, which is the one this app reads.
    func testItRunsUsageAndOnlyUsageWithTheKeychainLogin() {
        var seen: (argv: [String], directory: URL, environment: [String: String])?
        let cli = URL(fileURLWithPath: "/somewhere/claude")
        let renewer = ClaudeRenewer(locate: { cli }, run: { seen = ($0, $1, $2); return true })
        XCTAssertTrue(renewer.renew())
        XCTAssertEqual(seen?.argv, [cli.path, "-p", "/usage", "--no-session-persistence",
                                    "--settings", #"{"disableAllHooks":true}"#, "--output-format", "json"])
        XCTAssertEqual(seen?.directory.lastPathComponent, "PWE AI Bar")
        let environment = ClaudeRenewer.environment(["HOME": "/h", "CLAUDE_CODE_OAUTH_TOKEN": "x",
                                                     "ANTHROPIC_API_KEY": "y", "CLAUDE_CONFIG_DIR": "/c"])
        XCTAssertEqual(environment, ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"])
    }

    /// The renewer starts Claude Code and touches nothing itself: no keychain call, no file write,
    /// no request of its own.
    func testTheRenewerWritesNothingAndAsksNothing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/PWEAIBar/Providers/ClaudeRenewer.swift"),
                              encoding: .utf8)
        for call in ["SecItem", "-generic-password", "/usr/bin/" + "security", "URLSession", "URLRequest",
                     ".write" + "(", "oauth/" + "token", "refresh" + "_token"] {
            XCTAssertFalse(code.contains(call), "the renewer contains \(call)")
        }
    }
}
