import Foundation

/// Codex's own documented way to be asked: `codex app-server`, line-delimited JSON-RPC on a
/// private pipe. Three messages, no task created, no model touched.
///
///     {"id":1,"method":"initialize","params":{"clientInfo":{…}}}
///     {"method":"initialized","params":{}}
///     {"id":2,"method":"account/rateLimits/read"}
///
/// Why bother when the rollout logs already have numbers: the logs are a record of what Codex
/// saw the last time it ran. Ask the server and you get what is true now — measured here at 83 %
/// against the log's 82 % — plus two things the logs never carry: the plan type, and how many
/// free rate-limit resets the account is holding.
///
/// Everything here is bounded. One deadline covers the whole exchange, output is capped, and the
/// process is killed rather than waited on. Notifications arrive unasked (`remoteControl/status/
/// changed` turned up on the first run), so replies are matched by `id` and everything else is
/// discarded.
actor CodexAppServer {
    static let shared = CodexAppServer()

    struct Reading {
        var windows: [QuotaWindow] = []
        var planType: String?
        var resetCredits: Int = 0
    }

    private let locate: () -> String?
    private let exchange: (String, [String]) -> [[String: Any]]
    private let now: () -> Date

    init(locate: @escaping () -> String? = CodexAppServer.executable,
         exchange: @escaping (String, [String]) -> [[String: Any]] = CodexAppServer.run,
         now: @escaping () -> Date = Date.init) {
        self.locate = locate; self.exchange = exchange; self.now = now
    }

    /// Where Codex actually lives. It is often not on `PATH` — on this machine the only copy is
    /// the one inside the ChatGPT desktop app, and a menu bar app launched from Finder does not
    /// inherit a shell `PATH` anyway.
    static func executable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(dir) + "/codex")
        }
        candidates += ["/Applications/ChatGPT.app/Contents/Resources/codex",
                       "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                       fm.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/codex").path]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func read() async -> Reading? {
        guard let binary = locate() else { return nil }
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"pwe_ai_bar","title":"PWE AI Bar","version":"\#(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        let send = exchange
        let replies = await withCheckedContinuation { (cont: CheckedContinuation<[[String: Any]], Never>) in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: send(binary, requests)) }
        }
        guard let result = replies.first(where: { ($0["id"] as? NSNumber)?.intValue == 2 })?["result"]
                as? [String: Any] else { return nil }
        return map(result)
    }

    func map(_ result: [String: Any]) -> Reading {
        // `rateLimitsByLimitId` is the shape that keeps the add-on pool separate from the quota;
        // `rateLimits` is the flattened one older builds send.
        let pools = (result["rateLimitsByLimitId"] as? [String: [String: Any]])
            ?? (result["rateLimits"] as? [String: Any]).map { ["codex": $0] }
            ?? [:]
        var out = Reading()
        out.resetCredits = ((result["rateLimitResetCredits"] as? [String: Any])?["availableCount"]
            as? NSNumber)?.intValue ?? 0

        if let quota = pools["codex"] {
            out.planType = quota["planType"] as? String
            for key in ["primary", "secondary"] {
                guard let node = quota[key] as? [String: Any],
                      let pct = (node["usedPercent"] as? NSNumber)?.doubleValue,
                      pct.isFinite, pct >= 0, pct <= 100 else { continue }
                let minutes = (node["windowDurationMins"] as? NSNumber)?.intValue
                let reset = (node["resetsAt"] as? NSNumber).flatMap {
                    $0.doubleValue.isFinite ? Date(timeIntervalSince1970: $0.doubleValue) : nil
                }
                out.windows.append(QuotaWindow(
                    id: "codex_\(minutes.map(String.init) ?? key)", provider: .codex, channel: .codex,
                    title: CodexProvider.windowName(minutes: minutes, key: key), percent: pct,
                    resetsAt: reset, observedAt: now(), gradedBy: .local,
                    confirmedExhausted: pct >= 99.5))
            }
        }
        // The add-on pool is a separate fact, and only while it is actually spent. Reporting it
        // as Codex's headline state is how "额度耗尽" ends up next to a quota sitting at 95 %.
        for (id, pool) in pools where id != "codex" {
            guard let reached = pool["rateLimitReachedType"] as? String,
                  reached.contains("credits") else { continue }
            out.windows.append(QuotaWindow(id: "codex_credits", provider: .codex, channel: .codex,
                                           title: "附加额度", percent: nil, severity: .critical,
                                           note: "已用尽", observedAt: now(), confirmedExhausted: true))
        }
        return out
    }

    /// Runs one exchange and returns every complete JSON object the server printed. Bounded by a
    /// wall-clock deadline and an output cap; the process is killed, never waited on.
    static func run(_ binary: String, _ requests: [String]) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        guard (try? process.run()) != nil else { return [] }

        let sink = Sink()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty || sink.append(chunk) == false { break }
            }
            drained.leave()
        }
        DispatchQueue.global(qos: .utility).async { _ = errors.fileHandleForReading.readDataToEndOfFile() }

        // Ask, then give the server a moment to answer before deciding it never will.
        for line in requests {
            guard let data = (line + "\n").data(using: .utf8),
                  (try? input.fileHandleForWriting.write(contentsOf: data)) != nil else { break }
        }
        let deadline = Date().addingTimeInterval(12)
        var replies: [[String: Any]] = []
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            replies = parse(sink.bytes)
            if replies.contains(where: { ($0["id"] as? NSNumber)?.intValue == 2 }) { break }
        }
        sink.stop()
        try? input.fileHandleForWriting.close()
        process.terminate()
        _ = drained.wait(timeout: .now() + 2)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        return replies
    }

    /// Output accumulates on a reader thread and is inspected from the caller's, so it lives
    /// behind a lock rather than in a captured `var`.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var stopped = false
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return buffer }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        /// Returns false when the reader should give up: asked to stop, or past the output cap.
        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            return !stopped && buffer.count <= 1 << 20
        }
    }

    static func parse(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }
}
