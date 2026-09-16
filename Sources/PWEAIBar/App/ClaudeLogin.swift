import AppKit

/// Signing in, and opening Claude Code, for someone who has never opened Terminal.
///
/// Every dead end in this app used to end in "run `claude auth login` in a terminal". That
/// sentence assumes the reader knows what a terminal is, where to find it, and that the command
/// exists — and on the Mac that prompted this, it did not: `zsh: command not found`. An
/// instruction the reader cannot carry out is worse than none, because it looks like their fault.
///
/// A `.command` file is the one thing Launch Services hands to Terminal *and* Terminal executes,
/// so these are buttons rather than lessons.
enum ClaudeLogin {
    static let command = "claude auth login"

    /// True when Terminal was handed the script. False means the fallback ran: the command is on
    /// the clipboard and Terminal is open, so the worst case is one ⌘V rather than a dead end.
    @discardableResult
    static func begin() -> Bool {
        run(named: "Sign in to Claude Code",
            lines: [L("login.signingIn", "PWE AI Bar — signing in to Claude Code."),
                    L("login.signingIn.browser",
                      "A browser window will open. You can close this window when it is done.")],
            command: command)
    }

    /// Runs Claude Code, for a login that has expired or could not be read.
    ///
    /// This app reads that login and never renews it — renewing hands back a replacement only the
    /// renewer can store — so what brings an expired login back is Claude Code itself, used once.
    /// A read stopped by a keychain question is the same story: Claude Code meets that question
    /// too, and answering it there with Always Allow answers it for this app, because both read
    /// through the same tool. Signing in again would also work, but it rebuilds a login that only
    /// needed renewing.
    @discardableResult
    static func openClaudeCode() -> Bool {
        run(named: "Open Claude Code",
            lines: [L("login.opening", "PWE AI Bar — opening Claude Code."),
                    L("login.opening.renews",
                      "Using it renews its login, and the quota in the menu bar comes back on its own."),
                    L("login.opening.allow", "If macOS asks about the keychain, choose Always Allow.")],
            command: "claude")
    }

    private static func run(named name: String, lines: [String], command: String) -> Bool {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".command")
        // Single-quoted, so nothing in a sentence is ever read by the shell as syntax.
        let echoes = lines.map { "echo '" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let body = (["#!/bin/bash", "clear"] + echoes + ["echo", "exec " + command]).joined(separator: "\n") + "\n"
        if (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil,
           (try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: script.path)) != nil,
           NSWorkspace.shared.open(script) {
            return true
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
        }
        return false
    }
}
