import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

final class RenderingTests: XCTestCase {
    @MainActor func testSyntheticCredentialStatesAndPendingQuotaRender() async throws {
        let space = try TestSpace(); let prefs = Prefs(defaults: space.defaults)
        let clock = TestClock(); let credential = FakeCredential()
        let p = provider(space, clock: clock, credential: credential, http: HTTPStub([]))
        let rules = RuleEngine(defaults: space.defaults, away: { false }, remaining: { true })
        let store = Store(claude: p, rules: rules, readEvents: { [] },
                          readLocal: { .init(trophy: Trophy(), context: nil, lastTurnAt: nil) }, readCodex: { ([], nil) },
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
    /// The gauge is now the panel's navigation, so the hit-testing is load-bearing.
    ///
    /// The obvious implementation — hit-test the feather outlines — leaves most of the mark
    /// belonging to nobody: the shapes are slivers that fan apart, and the pointer falls through
    /// the gaps between them. Nearest-axis has no dead zones, and this checks that each feather
    /// actually claims its own.
    @MainActor func testEveryFeatherClaimsItsOwnAxisAndTheMarkHasNoDeadZones() {
        let view = WingNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 240 / BrandMark.aspect))
        view.onPick = { _ in }
        for k in 0..<BrandMark.count {
            let axis = BrandMark.axis(k, in: view.bounds)
            for t in [0.25, 0.5, 0.75] {
                let point = CGPoint(x: axis.root.x + (axis.tip.x - axis.root.x) * t,
                                    y: axis.root.y + (axis.tip.y - axis.root.y) * t)
                XCTAssertEqual(view.feather(at: point), Channel(rawValue: k),
                               "feather \(k) at \(t) of its own axis")
            }
        }
        // Well outside the mark answers nothing rather than the nearest thing to it.
        XCTAssertNil(view.feather(at: CGPoint(x: -400, y: -400)))
        // Without a handler wired up the mark is inert, exactly as it is in the menu bar.
        let inert = WingNSView(frame: view.bounds)
        inert.updateTrackingAreas()
        XCTAssertTrue(inert.trackingAreas.isEmpty)
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
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pricing", withExtension: "json"))
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
