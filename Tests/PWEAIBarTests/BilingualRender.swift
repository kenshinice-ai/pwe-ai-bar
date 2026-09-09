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
                // The longest label the mapper can actually produce: a model-scoped weekly window.
                QuotaWindow(id: "ws", provider: .claude, channel: .week,
                            title: String(format: L("channel.weekScoped", "Weekly · %@"), "Fable"),
                            percent: 97, severity: .critical,
                            resetsAt: at.addingTimeInterval(86400)),
                QuotaWindow(id: "w", provider: .claude, channel: .week, title: L("channel.week", "Weekly"), percent: 72,
                            severity: .normal, resetsAt: at.addingTimeInterval(86400),
                            isActive: true, windowLength: 7 * 86400),
                QuotaWindow(id: "s", provider: .claude, channel: .session, title: L("channel.session", "5-hour"), percent: 41,
                            severity: .normal, resetsAt: at.addingTimeInterval(5400),
                            isActive: true, windowLength: 5 * 3600),
                QuotaWindow(id: "c", provider: .codex, channel: .codex, title: L("channel.session", "5-hour"), percent: 88,
                            severity: .warning, resetsAt: at.addingTimeInterval(7200)),
            ]
            snap.contextPercent = 23.5
            store.injectForTesting(snap)
            let panel = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {},
                                  onOpen: { _ in }, onEnableQuota: {}, usableHeight: { 1334 })
            for dark in [true, false] {
                try shoot(AnyView(panel), width: Theme.panelWidth, dark: dark,
                          to: out.appendingPathComponent("panel-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
            }
            // Two states: as the window opens (Display and Alerts open, the rest collapsed), and
            // everything open. The first is what a reader sees; the second is the height check.
            for (state, open) in [("default", nil), ("expanded", true)] as [(String, Bool?)] {
                if let open { for g in ["display", "alerts", "sources", "general"] { prefs.setOpen(g, open) } }
                let settings = SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                            enableRealQuota: {}, prefs: prefs,
                                            tokenEditor: TokenEditor(hasToken: false), hookInstalled: false,
                                            usableHeight: { 1334 })
                try shoot(AnyView(settings), width: 380,
                          to: out.appendingPathComponent("settings-\(lang.rawValue)-\(state).png"))
            }
            // The trophy page with the shape real data actually has: five-figure turn counts and
            // a model the price table does not carry.
            var t = Trophy()
            t.days = 39; t.turns = 68_967
            t.equivalentUSD = 20_673; t.subscriptionUSD = 130
            t.range = .all
            t.subscriptionMonthly = Subscription(plan: "max_5x", display: "Max 5×",
                                                 currency: "USD", monthly: 100, monthlyUSD: 100)
            let models: [(model: String, turns: Int, usd: Double)] = [
                ("claude-opus-5", 53_264, 13_461), ("claude-fable-5", 11_973, 5_521),
                ("claude-fable-5-1", 3_151, 1_662), ("claude-sonnet-5", 81, 29.63),
                ("gpt-5-6-sol", 498, 0),
            ]
            t.byModel = models
            let shape: [Double] = [120, 940, 310, 60, 620, 1480, 205]
            t.byDay = (0..<39).map { (i: Int) -> (String, Double) in
                (String(format: "2026-08-%02d", i % 28 + 1), shape[i % 7] + Double(i * 9))
            }
            t.tokens = (18_402_113, 2_940_881, 41_002_774, 1_884_339_002)
            for dark in [true, false] {
                try shoot(AnyView(TrophyView(trophy: t, prefs: prefs)), width: 460, dark: dark,
                          to: out.appendingPathComponent("trophy-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
            }
            store.stop()
        }
        Loc.language = .en
    }

    @MainActor private func shoot(_ v: AnyView, width: CGFloat, dark: Bool = true, to url: URL) throws {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let bmp = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bmp)
        try XCTUnwrap(bmp.representation(using: .png, properties: [:])).write(to: url)
    }
}
