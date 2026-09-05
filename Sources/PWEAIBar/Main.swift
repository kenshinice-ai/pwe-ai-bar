import AppKit

/// Built with `-parse-as-library`, so the entry point is an explicit `@main` on the main actor
/// rather than a top-level `main.swift` — the delegate is main-actor isolated and cannot be
/// constructed from a nonisolated top level.
@main
enum PWEAIBarMain {
    @MainActor
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--icon"),
           i + 1 < CommandLine.arguments.count {
            Theme.registerFonts()
            Probe.icons(into: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--panel"),
           i + 1 < CommandLine.arguments.count {
            Theme.registerFonts()
            let dir = CommandLine.arguments[i + 1]
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in await Probe.panels(into: dir); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return
        }
        // Headless credential setup, so a token can be piped straight in:
        //     claude setup-token | "PWE AI Bar.app/Contents/MacOS/PWEAIBar" --token -
        // `--notify` answers the only question that matters when an alert fires and nothing
        // appears: did the OS take it? Everything else in this app can be inspected from the
        // outside; notification delivery cannot.
        if CommandLine.arguments.contains("--notify") {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await Notifier.shared.diagnose()
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--token") {
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
            var value = arg
            if arg == "-" {
                value = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = Credentials.storeOwnToken(value).succeeded
            print(value.isEmpty ? (ok ? "已清除令牌" : "清除失败")
                                : (ok ? "已保存令牌，额度有效性将在应用中验证" : "保存失败"))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--endurance"),
           i + 1 < CommandLine.arguments.count {
            Theme.registerFonts()
            Probe.endurance(into: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--stress"),
           i + 1 < CommandLine.arguments.count {
            Theme.registerFonts()
            Probe.stress(into: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--cred") {
            Probe.credentials()
            return
        }
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // The delegate must outlive this scope; `run()` never returns until quit.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
