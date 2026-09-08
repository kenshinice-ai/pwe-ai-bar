import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

final class BilingualRenderTests: XCTestCase {
    @MainActor func testRenderBothLanguages() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT"] ?? NSTemporaryDirectory())
        _ = NSApplication.shared
        Theme.registerFonts()
        for lang in [Language.en, .zhHans] {
            Loc.language = lang
            let space = try TestSpace()
            let prefs = Prefs(defaults: space.defaults)
            prefs.panelMode = .full
            let store = Store(claude: ClaudeProvider(defaults: space.defaults,
                                                     access: .init(own: { nil }, claudeCode: { nil },
                                                                   sharedExists: { false }, shared: { nil },
                                                                   save: { _ in .failed(-1) }),
                                                     request: { _ in throw ClaudeProvider.Blocker.network }),
                              rules: RuleEngine(defaults: space.defaults, away: { false }, remaining: { true }),
                              readEvents: { [] },
                              readLocal: { _, _ in .init(trophy: Trophy(), context: nil, lastTurnAt: nil) },
                              readCodex: { ([], nil) },
                              deliver: { _, _ in false }, tracks: { (true, true) })
            var snap = Snapshot()
            let at = Date()
            snap.windows = [
                QuotaWindow(id: "w", provider: .claude, channel: .week, title: "Weekly", percent: 72,
                            severity: .normal, resetsAt: at.addingTimeInterval(86400),
                            isActive: true, windowLength: 7 * 86400),
                QuotaWindow(id: "s", provider: .claude, channel: .session, title: "5-hour", percent: 41,
                            severity: .normal, resetsAt: at.addingTimeInterval(5400),
                            isActive: true, windowLength: 5 * 3600),
                QuotaWindow(id: "c", provider: .codex, channel: .codex, title: "5-hour", percent: 88,
                            severity: .warning, resetsAt: at.addingTimeInterval(7200)),
            ]
            snap.contextPercent = 23.5
            store.injectForTesting(snap)
            let panel = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {},
                                  onOpen: { _ in }, onEnableQuota: {}, usableHeight: { 1334 })
            try shoot(AnyView(panel), width: Theme.panelWidth,
                      to: out.appendingPathComponent("panel-\(lang.rawValue).png"))
            let settings = SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                        enableRealQuota: {}, prefs: prefs,
                                        tokenEditor: TokenEditor(hasToken: false), hookInstalled: false)
            try shoot(AnyView(settings), width: 380,
                      to: out.appendingPathComponent("settings-\(lang.rawValue).png"))
            store.stop()
        }
        Loc.language = .en
    }

    @MainActor private func shoot(_ v: AnyView, width: CGFloat, to url: URL) throws {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let bmp = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bmp)
        try XCTUnwrap(bmp.representation(using: .png, properties: [:])).write(to: url)
    }
}
