import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

/// The panel has to fit on the screen it pops out of.
///
/// `SettingsView` learned this once already — eight providers pushed it past 960 pt and the
/// rows below the fold became unreachable, which is why it has a `ScrollView` and a cap. The
/// panel has the same shape (a section per active provider, plus the chart and the score row
/// in full mode) and never got the same treatment: it grew until its top — the header, the
/// provider picker and the endurance block, which is the entire point of the app — was pushed
/// off the screen by a popover AppKit had nowhere left to put.
final class PanelHeightTests: XCTestCase {

    /// The smallest Mac still sold is 1440 x 900 points; the menu bar and the popover's own
    /// beak and margins take roughly forty of them. A panel taller than what is left cannot be
    /// shown whole no matter where AppKit puts it.
    static let smallestUsableScreen: CGFloat = 860

    @MainActor func testTheFullPanelFitsOnTheSmallestScreenWithEveryProviderShowing() throws {
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
                          readLocal: { .init(trophy: Trophy(), context: nil, lastTurnAt: nil) },
                          readCodex: { ([], nil) },
                          deliver: { _, _ in XCTFail("Measuring must not notify"); return false },
                          tracks: { (false, false) })

        var snap = Snapshot()
        let at = Date()
        // Every provider the settings screen can switch on, each with the rows it actually
        // draws. This is the worst case the panel has to survive, not a hypothetical one.
        for (provider, channel) in [(Provider.claude, Channel.week), (.claude, .session),
                                    (.codex, .codex), (.cursor, .other), (.copilot, .other),
                                    (.devin, .other), (.grok, .other), (.antigravity, .other)] {
            snap.windows.append(QuotaWindow(id: "\(provider)-\(channel)", provider: provider,
                                            channel: channel, title: "周窗口", percent: 72,
                                            severity: .normal,
                                            resetsAt: at.addingTimeInterval(86400)))
        }
        snap.contextPercent = 23.5
        let byHour: [(hour: Date, usd: Double)] = (0..<24).map { (i: Int) -> (Date, Double) in
            (at.addingTimeInterval(Double(i - 23) * 3600), Double((i * 7) % 13) * 12.5)
        }
        snap.trophy = Trophy(days: 38, turns: 12_345, equivalentUSD: 20_255, subscriptionUSD: 25.32,
                             byHour: byHour)
        store.injectForTesting(snap)

        _ = NSApplication.shared
        Theme.registerFonts()
        let panel = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {},
                              onOpen: { _ in }, onEnableQuota: {})
        let host = NSHostingView(rootView: AnyView(panel))
        host.frame = NSRect(x: 0, y: 0, width: Theme.panelWidth, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        print("panel height with every provider, full mode: \(height) pt "
              + "(ceiling \(PanelView.ceiling) pt)")

        // Two separate claims. The cap has to be small enough for the smallest Mac whatever
        // screen this test happens to run on — otherwise the assertion below passes here and
        // the panel still overflows on a 1440 x 900 machine.
        XCTAssertLessThanOrEqual(PanelView.ceiling, Self.smallestUsableScreen,
                                 "the panel's own cap does not fit the smallest Mac")
        XCTAssertLessThanOrEqual(height, PanelView.ceiling,
                                 "the panel measures \(height) pt against its own \(PanelView.ceiling) pt "
                                 + "cap — the overflow goes off the top of the screen, taking the "
                                 + "header, the provider picker and the endurance block with it")

        // The cap is only honest if what it hides is still reachable. Remove the ScrollView and
        // this passes while the rows below the fold become unreachable, exactly as in Settings.
        XCTAssertTrue(host.descendantScrollView() != nil,
                      "the panel is capped but has no scroller, so everything past the cap is gone")
        store.stop()
    }
}

private extension NSView {
    /// Depth-first search for a real `NSScrollView` in the hosted hierarchy. SwiftUI's
    /// `ScrollView` is backed by one, so its absence means the panel cannot be scrolled.
    func descendantScrollView() -> NSScrollView? {
        if let me = self as? NSScrollView { return me }
        for child in subviews { if let found = child.descendantScrollView() { return found } }
        return nil
    }
}
