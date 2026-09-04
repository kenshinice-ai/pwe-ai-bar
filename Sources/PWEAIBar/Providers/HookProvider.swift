import Foundation

/// Session events, delivered by Claude Code's own hooks.
///
/// This is the half of the product that quota polling cannot do. A percentage tells you the
/// state of the world; a hook tells you that something just happened and is now waiting on you.
/// The bridge is a shell script that appends one JSON line per firing, which keeps the hook
/// itself incapable of breaking a coding session — it does no network, holds no lock, and
/// always exits 0.
enum HookProvider {

    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/pwe-ai-bar/events.jsonl")

    /// How long a "waiting" event stays interesting. Claude Code does not fire a matching
    /// "resolved" hook, so an unanswered prompt is inferred to be answered once the session
    /// produces anything newer.
    private static let waitingTTL: TimeInterval = 30 * 60

    static func events() -> [AgentEvent] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }

        var newestPerSession: [String: (Date, AgentEvent.Kind)] = [:]
        var out: [AgentEvent] = []

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kindWord = o["kind"] as? String,
                  let kind = AgentEvent.Kind(rawValue: kindWord),
                  let secs = (o["at"] as? NSNumber)?.doubleValue else { continue }
            let at = Date(timeIntervalSince1970: secs)
            let session = o["session"] as? String ?? ""
            if let prev = newestPerSession[session], prev.0 > at { continue }
            newestPerSession[session] = (at, kind)

            let cwd = (o["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let raw = (o["text"] as? String) ?? ""
            out.removeAll { $0.id == session }
            out.append(AgentEvent(
                id: session.isEmpty ? UUID().uuidString : session,
                provider: .claude,
                kind: kind,
                text: raw.isEmpty ? defaultText(kind, project: cwd) : raw,
                at: at))
        }

        let now = Date()
        return out
            .filter { $0.kind != .waiting || now.timeIntervalSince($0.at) < waitingTTL }
            .sorted { $0.at > $1.at }
    }

    private static func defaultText(_ kind: AgentEvent.Kind, project: String) -> String {
        let where_ = project.isEmpty ? "" : " · \(project)"
        switch kind {
        case .waiting:  return "Claude 在等你回话\(where_)"
        case .finished: return "任务完成\(where_)"
        case .failed:   return "会话出错\(where_)"
        case .answered: return "已回复\(where_)"
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path) &&
        ((try? String(contentsOf: settingsURL, encoding: .utf8))?
            .contains("pwe-ai-bar-hook") ?? false)
    }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Merges our two hooks into the user's settings without touching anything else there.
    /// Their file is theirs: we read it, add what is missing, and write it back — never
    /// overwrite it with a template.
    @discardableResult
    static func install(scriptPath: String) -> Bool {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { root = o }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Three hooks. `UserPromptSubmit` is the one that makes "waiting" accurate: without it
        // the state only clears when the turn ends, so the menu bar keeps saying Claude is
        // waiting for minutes after you have already answered.
        for (event, kind) in [("Notification", "waiting"),
                              ("UserPromptSubmit", "answered"),
                              ("Stop", "finished")] {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            let command = "\(scriptPath.replacingOccurrences(of: " ", with: "\\ ")) \(kind)"
            let already = matchers.contains { m in
                ((m["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("pwe-ai-bar-hook") == true
                }
            }
            guard !already else { continue }
            matchers.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = matchers
        }
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        return (try? out.write(to: settingsURL, options: .atomic)) != nil
    }
}
