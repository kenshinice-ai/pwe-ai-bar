import AppKit

/// Signing in, for someone who has never opened Terminal.
///
/// Every dead end in this app used to end in "run `claude auth login` in a terminal". That
/// sentence assumes the reader knows what a terminal is, where to find it, and that the command
/// exists — and on the Mac that prompted this, it did not: `zsh: command not found`. An
/// instruction the reader cannot carry out is worse than none, because it looks like their fault.
///
/// A `.command` file is the one thing Launch Services hands to Terminal *and* Terminal executes,
/// so this is a button rather than a lesson.
enum ClaudeLogin {
    static let command = "claude auth login"

    /// True when Terminal was handed the script. False means the fallback ran: the command is on
    /// the clipboard and Terminal is open, so the worst case is one ⌘V rather than a dead end.
    @discardableResult
    static func begin() -> Bool {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sign in to Claude Code.command")
        let body = """
        #!/bin/bash
        clear
        echo "PWE AI Bar — signing in to Claude Code."
        echo "A browser window will open. You can close this window when it is done."
        echo
        exec \(command)
        """
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
