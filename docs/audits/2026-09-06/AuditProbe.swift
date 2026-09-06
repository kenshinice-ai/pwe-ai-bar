import Foundation
import AppKit
import SwiftUI
@testable import PWEAIBar

@main struct AuditProbe {
    @MainActor static func main() async throws {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = origin
        var calls = 0
        let server = CodexAppServer(locate: { "/synthetic/codex" }, exchange: { _, _ in
            calls += 1
            if calls > 1 { return [] }
            return [["id": 2, "result": ["rateLimitsByLimitId": ["codex": ["primary": [
                "usedPercent": 40.0, "windowDurationMins": 300,
                "resetsAt": origin.addingTimeInterval(600).timeIntervalSince1970
            ]]]]]]
        }, now: { clock })
        let provider = CodexProvider(root: URL(fileURLWithPath: "/private/tmp/nonexistent-pwe-audit-logs"), now: { clock }, server: server)
        _ = await provider.windows()
        clock = origin.addingTimeInterval(301)
        let failed = await provider.windows()
        print("CODEX_FAILURE calls=\(calls) percent=\(failed.first?.percent ?? -1) stale=\(failed.first?.isStale ?? false) age=\(clock.timeIntervalSince(failed.first!.observedAt))")
        clock = origin.addingTimeInterval(901)
        let pastReset = await provider.windows()
        print("CODEX_PAST_RESET calls=\(calls) percent=\(pastReset.first?.percent ?? -1) stale=\(pastReset.first?.isStale ?? false) resetPassed=\(pastReset.first!.resetsAt! < clock)")
        let mapping = await server.map(["rateLimits": ["primary": ["usedPercent": 99.6, "windowDurationMins": 300]]])
        print("CODEX_99_6 exhausted=\(mapping.windows.first!.confirmedExhausted)")

        let old = QuotaWindow(id: "weekly", provider: .codex, channel: .codex, title: "test", percent: 40,
                              resetsAt: origin.addingTimeInterval(7200), observedAt: origin.addingTimeInterval(-3600), windowLength: 18000)
        print("OLD_OBSERVATION age=3600 stale=\(old.isStale) burn=\(old.burn(at: origin)?.perHour ?? -1) estimate=\(old.projectedPercentAtReset(at: origin) ?? -1)")
        var clock2 = origin
        let history = History(url: URL(fileURLWithPath: "/private/tmp/pwe-audit-20260906-evidence/history-\(UUID().uuidString).json"), now: { clock2 })
        func window(_ pct: Double, _ at: Date) -> QuotaWindow {
            QuotaWindow(id: "hour", provider: .claude, channel: .session, title: "test", percent: pct,
                        resetsAt: origin.addingTimeInterval(18000), observedAt: at, windowLength: 18000)
        }
        _ = await history.observe([window(10, origin)])
        clock2 = origin.addingTimeInterval(1200)
        _ = await history.observe([window(20, clock2)])
        let replay = await history.observe([window(10, origin.addingTimeInterval(300))])
        print("HISTORY_OUT_OF_ORDER sampleCount=\(replay.first!.samples.count) lastPercent=\(replay.first!.samples.last!.percent) lastAtOffset=\(replay.first!.samples.last!.at.timeIntervalSince(origin))")

        let extras = ExtraStore(now: { clock2 }, fetch: { _, now in
            if now() == origin { return .init(windows: [window(20, now())], connection: .connected) }
            return .init(connection: .unavailable("offline"))
        })
        clock2 = origin
        _ = await extras.read([.cursor])
        clock2 = origin.addingTimeInterval(600)
        let extraFail = await extras.read([.cursor])
        print("EXTRA_FAILURE windowCount=\(extraFail.windows.count)")

        _ = NSApplication.shared
        Theme.registerFonts()
        let suite = UserDefaults(suiteName: "PWEAudit.\(UUID().uuidString)")!
        let prefs = Prefs(defaults: suite)
        prefs.panelMode = .full
        let store = Store(readEvents: { [] }, readLocal: { .init(trophy: Trophy(), context: nil, lastTurnAt: nil) },
                          readCodex: { ([],nil) }, deliver: { _,_ in false }, tracks: { (false,false) },
                          tracksExtra: { _ in false }, readExtras: { _ in .init() }, observe: { $0 })
        var snap = Snapshot()
        for p in Provider.allCases where p.unavailableReason == nil {
            for (idx, length) in [18000.0,604800.0].enumerated() {
                snap.windows.append(QuotaWindow(id: "\(p.rawValue)_\(idx)", provider: p,
                    channel: p == .claude ? (idx == 0 ? .session : .week) : p.channel,
                    title: idx == 0 ? "五小时窗口" : "周窗口", percent: 35 + Double(idx*10),
                    resetsAt: Date().addingTimeInterval(length*0.5), windowLength: length))
            }
        }
        store.injectForTesting(snap)
        var costs: [Double] = []
        for idx in 0..<11 {
            let start = ProcessInfo.processInfo.systemUptime
            let host = NSHostingView(rootView: PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {}, onOpen: {_ in}, onEnableQuota: {}).environment(\.colorScheme,.light))
            host.appearance = NSAppearance(named: .aqua)
            let height = host.fittingSize.height
            host.frame = NSRect(x: 0,y: 0,width: Theme.panelWidth,height:height)
            host.layoutSubtreeIfNeeded()
            costs.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            if idx == 0, let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:"/private/tmp/pwe-audit-20260906-evidence/seven-providers-full.png"))
                print("PANEL_ALL height=\(height) width=\(Theme.panelWidth)")
            }
        }
        let warm = Array(costs.dropFirst()).sorted()
        print("SYNTHETIC_LAYOUT coldMs=\(costs[0]) warmMedianMs=\(warm[warm.count/2]) warmMaxMs=\(warm.last!)")
    }
}
