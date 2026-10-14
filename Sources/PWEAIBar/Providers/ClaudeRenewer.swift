import Foundation

/// Asks Claude Code to renew its own login, without a conversation.
///
/// This app reads Claude Code's login and never renews or writes it: renewing spends a refresh
/// token and returns the only copy of its replacement, and only Claude Code can store that. Until
/// 1.6.2 the app therefore waited for Claude Code to be used — which waited forever on a Mac where
/// Claude Code is used through the desktop app. The desktop app hands its sessions a token of its
/// own and never touches the keychain record, so the record expired eight hours after the last
/// terminal session and stayed expired: on 2026-10-14 it had not moved in 44 hours of daily use,
/// and the only thing that ever moved it was the panel's Open Claude Code button.
///
/// The way out keeps the rule. Claude Code renews its login before any request it makes, and
/// `/usage` is a local command whose only request is to the usage endpoint. Measured 2026-10-14
/// against an expired login: zero turns, zero tokens, $0, five seconds, and the record rewritten
/// by Claude Code itself. So the app runs that and nothing else; whatever is written, Claude Code
/// wrote it.
///
/// `--no-session-persistence` keeps the run out of the session logs, `disableAllHooks` keeps the
/// user's hooks — this app's own among them — from reacting to it, and the fixed working directory
/// means the one folder Claude Code makes per working directory is made once.
///
/// It is the user's choice, and off until they make it: a background app starting another program
/// on a schedule is something to be asked for. CodexBar learned the cost of not asking — its
/// background `/status` refresh opened a browser every hour for people whose record held no login
/// (steipete/CodexBar#1844). That is why `ClaudeProvider.renewIfDue` also requires the record to
/// have held a renewable login.
struct ClaudeRenewer {
    var locate: () -> URL?
    var run: (_ argv: [String], _ directory: URL, _ environment: [String: String]) -> Bool

    /// Pinned by a test. Anything that reached the model here would spend the user's quota.
    static let arguments = ["-p", "/usage", "--no-session-persistence",
                            "--settings", #"{"disableAllHooks":true}"#, "--output-format", "json"]
    /// The measured run takes five seconds; this covers a slow start and a slow network.
    static let patience: TimeInterval = 45

    static let live = ClaudeRenewer(locate: { locateCLI() }, run: { argv, directory, environment in
        Subprocess.run(argv, timeout: patience, directory: directory, environment: environment) != nil
    })

    /// True when Claude Code ran and reported success. Whether the login moved is the record's
    /// business, and the caller asks the record.
    func renew() -> Bool {
        guard let cli = locate() else { return false }
        let fm = FileManager.default
        let directory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PWE AI Bar", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return run([cli.path] + Self.arguments, directory, Self.environment())
    }

    /// This app's environment without anything that would point Claude Code at a login other than
    /// the one in the keychain — a token handed down by a host, or an API key.
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { key, _ in !key.hasPrefix("CLAUDE_CODE_") && !key.hasPrefix("ANTHROPIC_") }
    }

    /// The Claude Code a terminal would run, else the copy the desktop app keeps for its Code tab.
    ///
    /// The terminal one first: it is the one the user installed and signed in with. An app opened
    /// from the Dock gets a minimal PATH, so the usual install locations are listed as well.
    static func locateCLI(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        var candidates = path.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
        }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        candidates += [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0) }
        return candidates.first(where: isExecutable) ?? bundled(home: home)
    }

    /// `claude-code/<version>/<build>/claude.app/Contents/MacOS/claude`, newest version first. The
    /// desktop app replaces it when it updates, so it is looked up each time rather than remembered.
    static func bundled(home: URL) -> URL? {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let dir = root.appendingPathComponent(version)
            for build in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let cli = dir.appendingPathComponent(build)
                    .appendingPathComponent("claude.app/Contents/MacOS/claude")
                if isExecutable(cli) { return cli }
            }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
