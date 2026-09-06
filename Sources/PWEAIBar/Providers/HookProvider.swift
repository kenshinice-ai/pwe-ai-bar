import Foundation

/// Configuration installation is deliberately separate from event consumption.
enum HookProvider {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/pwe-ai-bar")
    static let log = directory.appendingPathComponent("events.jsonl")
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    static let required = [("Notification", "waiting"), ("UserPromptSubmit", "answered"), ("Stop", "finished")]

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func command(_ path: String, _ kind: String) -> String {
        "\(shellQuote(path)) \(kind)"
    }

    private static func isOurCommand(_ value: String?, path: String, kind: String) -> Bool {
        // Exact legacy command compatibility; never claim ownership by substring alone.
        value == command(path, kind)
            || value == "\(path.replacingOccurrences(of: " ", with: "\\ ")) \(kind)"
    }

    private static func configuration(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if let raw = root["hooks"] {
            guard let hooks = raw as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
            for (event, _) in required where hooks[event] != nil {
                guard let matchers = hooks[event] as? [[String: Any]],
                      matchers.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
            }
        }
        return root
    }

    static var script: URL { directory.appendingPathComponent("pwe-ai-bar-hook.sh") }

    static var isInstalled: Bool { isInstalled(settings: settingsURL, script: script) }

    /// The installed script is a copy, so an app update leaves the old one running. Nothing in
    /// the settings file changes when we fix a bug inside it, so "已安装" would keep saying yes
    /// to a script written weeks ago — which is exactly how a concurrency fix ships to nobody.
    static func installedScriptIsCurrent(source: URL?, script: URL? = nil) -> Bool {
        guard let source, let want = try? Data(contentsOf: source) else { return true }
        return (try? Data(contentsOf: script ?? Self.script)) == want
    }

    /// Replace our own copy in place when it has fallen behind. Only ever touches a file this
    /// app wrote, in this app's cache directory, and only when the settings file already points
    /// at it — installing the hooks is still a decision the user makes once, by hand.
    @discardableResult
    static func refreshScript(source: URL?, settings: URL? = nil, script: URL? = nil) -> Bool {
        let target = script ?? Self.script
        guard let source, isInstalled(settings: settings ?? settingsURL, script: target),
              !installedScriptIsCurrent(source: source, script: target),
              let bytes = try? Data(contentsOf: source) else { return false }
        guard (try? bytes.write(to: target, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return true
    }

    static func isInstalled(settings: URL, script: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let data = try? Data(contentsOf: settings), let root = try? configuration(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return required.allSatisfy { event, kind in
            (hooks[event] as? [[String: Any]] ?? []).contains { matcher in
                // A restricted matcher does not cover all sessions.
                let match = matcher["matcher"] as? String ?? ""
                return (match.isEmpty || match == "*") &&
                    (matcher["hooks"] as? [[String: Any]] ?? []).contains {
                        $0["type"] as? String == "command"
                            && isOurCommand($0["command"] as? String, path: script.path, kind: kind)
                    }
            }
        }
    }

    /// Fail closed on unreadable/invalid existing configuration. Backup bytes before mutation.
    @discardableResult
    static func install(scriptPath: String, settings: URL = settingsURL, source: URL? = nil) -> Bool {
        let fm = FileManager.default
        do {
            // Atomic replacement would replace the link itself, losing the user's indirection.
            if (try? settings.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return false }
            let original: Data?
            do { original = try Data(contentsOf: settings) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { original = nil }
            var root = try original.map(configuration) ?? [:]
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (event, kind) in required {
                var matchers = hooks[event] as? [[String: Any]] ?? []
                let exists = matchers.contains { matcher in
                    let match = matcher["matcher"] as? String ?? ""
                    return (match.isEmpty || match == "*") &&
                        (matcher["hooks"] as? [[String: Any]] ?? []).contains {
                            $0["type"] as? String == "command"
                                && isOurCommand($0["command"] as? String, path: scriptPath, kind: kind)
                        }
                }
                if !exists { matchers.append(["hooks": [["type": "command", "command": command(scriptPath, kind)]]]) }
                hooks[event] = matchers
            }
            root["hooks"] = hooks
            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            let script = URL(fileURLWithPath: scriptPath)
            if let source {
                let bytes = try Data(contentsOf: source)
                try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: script, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            }
            guard fm.isExecutableFile(atPath: scriptPath) else { return false }
            // Repeated installs should not rewrite valid settings or create redundant backups.
            if isInstalled(settings: settings, script: script) { return true }
            try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let original {
                guard try Data(contentsOf: settings) == original else { return false }
                let backup = settings.appendingPathExtension("pwe-backup-\(UUID().uuidString)")
                try original.write(to: backup, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            } else if fm.fileExists(atPath: settings.path) { return false }
            try output.write(to: settings, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
            return isInstalled(settings: settings, script: script)
        } catch { return false }
    }

    static func decode(_ data: Data) -> AgentEvent? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (o["kind"] as? String).flatMap(AgentEvent.Kind.init),
              let secs = (o["at"] as? NSNumber)?.doubleValue, secs.isFinite else { return nil }
        let eventID = o["event_id"] as? String
        let session = o["session"] as? String ?? ""
        let project = (o["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let raw = kind == .answered ? "" : String((o["text"] as? String ?? "").prefix(200))
        let text: String
        switch kind {
        case .waiting: text = "Claude 在等你回话"
        case .finished: text = "任务完成"
        case .failed: text = "会话出错"
        case .answered: text = "已回复"
        }
        return AgentEvent(id: session.isEmpty ? (eventID ?? "legacy-\(secs)") : session,
                          provider: .claude, kind: kind,
                          text: raw.isEmpty ? text + (project.isEmpty ? "" : " · \(project)") : raw,
                          at: Date(timeIntervalSince1970: secs), eventID: eventID)
    }
}

/// Consume immutable per-event files. Only delete a file after its state is durably saved.
/// Unread files have no count-based eviction, including when the application is not running.
actor HookEventReader {
    static let shared = HookEventReader()
    private let directory: URL
    private let now: () -> Date
    private var latest: [String: AgentEvent] = [:]
    private var loaded = false
    private var legacyModified: Date?
    private var dirty = false

    init(directory: URL = HookProvider.directory, now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.now = now
    }

    func events() -> [AgentEvent] {
        let fm = FileManager.default
        let state = directory.appendingPathComponent("event-state.json")
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: state),
               let saved = try? JSONDecoder().decode([String: AgentEvent].self, from: data) { latest = saved }
        }
        let before = latest.mapValues(\.key)
        let spool = directory.appendingPathComponent("events")
        let files = ((try? fm.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var consumed: [URL] = []
        for file in files.prefix(256) {
            guard let data = try? Data(contentsOf: file) else { continue }
            // A timestamp in the future is either a corrupt record or a clock that moved; either
            // way, skipping it would re-read the same file every second until the date caught up.
            guard let event = HookProvider.decode(data), event.at <= now().addingTimeInterval(300) else {
                // Retain corrupt bytes for inspection without letting them block the next batch.
                try? fm.moveItem(at: file, to: file.appendingPathExtension("invalid"))
                continue
            }
            guard event.at <= now() else { continue }
            merge(event)
            consumed.append(file)
        }
        // Quarantined bytes are for a person to look at, not an archive to keep forever.
        for stray in ((try? fm.contentsOfDirectory(at: spool, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []).filter({ $0.pathExtension == "invalid" }) {
            let at = (try? stray.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if now().timeIntervalSince(at ?? now()) > 7 * 86400 { try? fm.removeItem(at: stray) }
        }
        // Read legacy ring files until the user updates their installed hook script.
        let legacy = directory.appendingPathComponent("events.jsonl")
        let modified = (try? legacy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified != legacyModified, let data = try? Data(contentsOf: legacy) {
            for line in data.split(separator: 10) {
                if let event = HookProvider.decode(Data(line)), event.at <= now() { merge(event) }
            }
            legacyModified = modified
        }
        latest = latest.filter { now().timeIntervalSince($0.value.at) < 86400 }
        dirty = dirty || !consumed.isEmpty || before != latest.mapValues(\.key)
        if dirty {
            do {
                let data = try JSONEncoder().encode(latest)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: state, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
                for file in consumed { try? fm.removeItem(at: file) }
                dirty = false
            } catch { /* Leave the spool intact for the next read. */ }
        }
        return latest.values.filter { $0.kind != .waiting || now().timeIntervalSince($0.at) < 1800 }
            .sorted { $0.at == $1.at ? $0.key > $1.key : $0.at > $1.at }
    }

    private func merge(_ event: AgentEvent) {
        if let previous = latest[event.id], previous.at > event.at
            || (previous.at == event.at && previous.key >= event.key) { return }
        latest[event.id] = event
    }
}
