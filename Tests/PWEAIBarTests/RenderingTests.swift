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
                          readLocal: { .init(trophy: Trophy(), context: nil, lastTurnAt: nil) }, readCodex: { [] },
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
}
