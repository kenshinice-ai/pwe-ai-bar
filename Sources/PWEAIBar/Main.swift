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
