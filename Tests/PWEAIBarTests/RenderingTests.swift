import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

final class RenderingTests: XCTestCase {
    @MainActor func testClaudeQuotaSuccessAndRateLimitCardsRender() async throws {
        let space = try TestSpace(); let prefs = Prefs(defaults: space.defaults)
        prefs.panelMode = .standard
        let at = Date()
        let auth = ClaudeProvider.Access(own: { nil }, claudeCode: {
            Credentials.Token(value: "synthetic", expiresAt: nil, source: .claudeKeychain, plan: "pro")
        }, sharedExists: { false }, shared: { nil }, save: { _ in .failed(-1) })
        let body = """
        {"five_hour":{"utilization":7.4,"resets_at":\(at.addingTimeInterval(3600).timeIntervalSince1970)},
         "seven_day":{"utilization":18.2,"resets_at":\(at.addingTimeInterval(5*86400).timeIntervalSince1970)},
         "seven_day_sonnet":{"utilization":22.5,"resets_at":\(at.addingTimeInterval(5*86400).timeIntervalSince1970)},
         "extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000}}
        """
        let http = HTTPStub([(200, body, [:]), (429, "{}", ["Retry-After": "120"])])
        let p = ClaudeProvider(defaults: space.defaults, access: auth, request: { try await http.send($0) })
        let store = Store(claude: p, rules: RuleEngine(defaults: space.defaults, away: { false }, remaining: { true }),
                          readEvents: { [] }, readLocal: { _, _ in .init(trophy: Trophy(), context: nil, lastTurnAt: nil) },
                          readCodex: { ([], nil) }, deliver: { _, _ in XCTFail("No real notifications"); return false },
                          tracks: { (true, false) }, tracksExtra: { _ in false }, observe: { $0 })
        let output = ProcessInfo.processInfo.environment["PWEBAR_TEST_ARTIFACTS"].map { URL(fileURLWithPath: $0) } ?? space.root
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared; Theme.registerFonts()
        for stale in [false, true] {
            store.refresh(forceClaude: true)
            for _ in 0..<80 {
                if store.snapshot.claudeDetails.lastSuccessAt != nil && store.snapshot.stale == stale && !store.claudeRefreshing { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(store.snapshot.stale, stale)
            XCTAssertEqual(store.snapshot.windows(of: .claude).count, 3)
            XCTAssertEqual(store.snapshot.claudeDetails.spend?.usedUSD, Decimal(string: "12.34"))
            for dark in [false, true] {
                let panel = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {}, onOpen: { _ in }, onEnableQuota: {})
                try render(AnyView(panel), width: Theme.panelWidth, dark: dark,
                           output: output.appendingPathComponent("claude-\(stale ? "stale" : "live")-\(dark ? "dark" : "light").png"))
            }
        }
        store.stop()
    }

    @MainActor func testSyntheticCredentialStatesAndPendingQuotaRender() async throws {
        let space = try TestSpace(); let prefs = Prefs(defaults: space.defaults)
        let clock = TestClock(); let credential = FakeCredential()
        let p = provider(space, clock: clock, credential: credential, http: HTTPStub([]))
        let rules = RuleEngine(defaults: space.defaults, away: { false }, remaining: { true })
        let store = Store(claude: p, rules: rules, readEvents: { [] },
                          readLocal: { _, _ in .init(trophy: Trophy(), context: nil, lastTurnAt: nil) }, readCodex: { ([], nil) },
                          deliver: { _, _ in XCTFail("Rendering must not deliver notifications"); return false },
                          tracks: { (false, false) })
        var snap = Snapshot()
        snap.windows = [QuotaWindow(id: "codex_300", provider: .codex, channel: .codex, title: "五小时窗口",
                                    percent: nil, note: "待确认", isStale: true)]
        store.injectForTesting(snap)
        let editor = TokenEditor(hasToken: true)
        _ = await editor.submit("synthetic") { _ in .saved(.unauthorized) }
        let settings = SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                    enableRealQuota: {}, prefs: prefs, tokenEditor: editor, hookInstalled: true)
        let output = ProcessInfo.processInfo.environment["PWEBAR_TEST_ARTIFACTS"].map { URL(fileURLWithPath: $0) } ?? space.root
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        Theme.registerFonts()
        for dark in [false, true] {
            try render(AnyView(settings), width: 380, dark: dark,
                       output: output.appendingPathComponent("settings-\(dark ? "dark" : "light").png"))
            for mode in PanelMode.allCases {
                prefs.panelMode = mode
                let panel = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {}, onOpen: { _ in }, onEnableQuota: {})
                try render(AnyView(panel), width: Theme.panelWidth, dark: dark,
                           output: output.appendingPathComponent("pending-\(mode.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor private func render(_ view: AnyView, width: CGFloat, dark: Bool, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let height = host.fittingSize.height
        XCTAssertGreaterThan(height, 50); XCTAssertLessThan(height, 1500)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: output)
    }

    func testLargeFiguresDoNotRoundPastTheirOwnUnit() {
        XCTAssertEqual(TrophyView.big(999_999_999), "1.00 B", "under a billion, but not once rounded")
        XCTAssertEqual(TrophyView.big(1_000_000_000), "1.00 B")
        XCTAssertEqual(TrophyView.big(6_666_666_666), "6.67 B")
        XCTAssertEqual(TrophyView.big(999_999), "1.0 M")
        XCTAssertEqual(TrophyView.big(1_500_000), "1.5 M")
        XCTAssertEqual(TrophyView.big(1_234), "1 K")
        XCTAssertEqual(TrophyView.big(999), "999")
        XCTAssertEqual(TrophyView.big(0), "0")
    }

    /// Pins the shipped price table to the published one. Not a network test — it checks the
    /// two things that are easy to get wrong by hand and expensive to get wrong in the figure
    /// on the trophy page.
    func testShippedPricesCarryTheirSourceAndTheCacheReadException() throws {
        let url = try XCTUnwrap(Bundle.resources.url(forResource: "pricing", withExtension: "json"))
        let table = try JSONDecoder().decode(Pricing.self, from: Data(contentsOf: url))
        XCTAssertEqual(table._source, "https://platform.claude.com/docs/en/about-claude/pricing")
        XCTAssertNotNil(table._checked, "a price table with no date cannot be known to be stale")

        // Fable 5.1 and Mythos 5.1 read cache at 0.025x; every other model is the usual 0.1x.
        // Priced at 0.1x, a Fable session's cache reads come out four times too expensive.
        for id in ["claude-fable-5-1", "claude-mythos-5-1"] {
            XCTAssertEqual(table.models[id]?.cacheReadMultiple, 0.025, id)
        }
        for id in ["claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5"] {
            XCTAssertEqual(table.models[id]?.cacheReadMultiple, 0.1, id)
        }
        XCTAssertEqual(table.models["claude-opus-5"]?.input, 5)
        XCTAssertEqual(table.models["claude-opus-5"]?.output, 25)
        XCTAssertEqual(table.models["claude-sonnet-5"]?.input, 2)
        XCTAssertEqual(table.models["claude-haiku-4-5"]?.output, 5)

        // The worked example from the pricing page, to the cent: 10k uncached input, 40k cache
        // reads and 15k output on Opus 5 comes to $0.445 of tokens.
        let cost = table.cost(model: "claude-opus-5", input: 10_000, output: 15_000,
                              cacheWrite: 0, cacheRead: 40_000)
        XCTAssertEqual(cost, 0.445, accuracy: 0.0001)

        // A model nobody has priced costs nothing rather than something invented.
        XCTAssertEqual(table.cost(model: "someone-elses-model", input: 1_000_000, output: 0,
                                  cacheWrite: 0, cacheRead: 0), 0)
    }

}

/// The menu bar redrew about 3,050 times a second while the app sat idle, costing half a core:
/// `redraw` assigned `button.image`, the assignment made AppKit re-resolve the button's effective
/// appearance, and the `effectiveAppearance` observer redrew. Two things hold it shut now.
final class MenuBarRepaintTests: XCTestCase {
    func testAnIdenticalDrawingIsNotPaintedAgain() {
        var state = PaintedState()
        let glyph = Data([1, 2, 3])
        XCTAssertTrue(state.adopt(glyph, "72% left"), "nothing is on screen yet")
        XCTAssertFalse(state.adopt(glyph, "72% left"), "same bytes, same sentence — nothing to say")
        XCTAssertFalse(state.adopt(glyph, "72% left"))
        XCTAssertTrue(state.adopt(glyph, "71% left"), "the tooltip changed even though the glyph did not")
        XCTAssertTrue(state.adopt(Data([9]), "71% left"), "and the glyph can change under a fixed sentence")
    }

    /// An empty first drawing still has to reach the button: a status item that has never been
    /// painted shows nothing at all, and skipping it would leave an invisible, unclickable item.
    func testTheFirstDrawingAlwaysReachesTheButton() {
        var state = PaintedState()
        XCTAssertTrue(state.adopt(nil, ""))
        XCTAssertFalse(state.adopt(nil, ""))
    }

    /// Structural, because the loop lives in AppKit's KVO and cannot be reproduced in a unit
    /// test: the observer must compare the old and new appearance instead of redrawing on every
    /// notification. Dropping `options:` here is what cost half a core.
    func testTheAppearanceObserverOnlyActsOnARealChange() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/AppShell.swift")
        let code = try String(contentsOf: shell, encoding: .utf8)
        let observer = try XCTUnwrap(code.range(of: "observe(\\.effectiveAppearance"))
        let window = code[observer.lowerBound..<(code.index(observer.lowerBound, offsetBy: 400, limitedBy: code.endIndex) ?? code.endIndex)]
        XCTAssertTrue(window.contains("options: [.old, .new]"), "the observer must ask for both values")
        XCTAssertTrue(window.contains("change.oldValue?.name != change.newValue?.name"),
                      "and must return early unless the appearance actually changed")
    }
}
