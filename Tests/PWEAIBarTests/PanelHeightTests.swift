import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

/// The panel has to fit the screen it pops out of — and, just as importantly, it has to *ask*
/// for the height it needs.
///
/// The first fix here wrapped the middle in a `ScrollView` unconditionally and capped the whole
/// panel. It passed a test that measured `NSHostingView.fittingSize` in isolation, and it was
/// wrong in the app: a `ScrollView` asks for no height at all, so the popover had nothing
/// pushing it open and simply kept whatever size it had — around 300 pt — with the entire panel
/// scrolling inside it. Two more releases went out before that was understood, because the test
/// never put the view in a window and never let a layout pass run.
///
/// So these tests do. `NSHostingController` in a real window, the run loop pumped, and the
/// question asked of `fittingSize` — which is what a popover consults when it opens.
final class PanelHeightTests: XCTestCase {

    /// The smallest Mac still sold is 1440 x 900 points.
    static let smallScreen: CGFloat = 860
    /// What Lee's display actually has, and the case that must not scroll.
    static let roomyScreen: CGFloat = 1334

    @MainActor private func panel(usableHeight: CGFloat)
        throws -> (fitting: CGFloat, opened: CGFloat, scrolls: Bool) {
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
        // Every provider the settings screen can switch on. The worst case, not a hypothetical.
        for (provider, channel) in [(Provider.claude, Channel.week), (.claude, .session),
                                    (.codex, .codex), (.cursor, .other), (.copilot, .other),
                                    (.devin, .other), (.grok, .other), (.antigravity, .other)] {
            snap.windows.append(QuotaWindow(id: "\(provider)-\(channel)", provider: provider,
                                            channel: channel, title: "周窗口", percent: 72,
                                            severity: .normal, resetsAt: at.addingTimeInterval(86400)))
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
        let view = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {},
                             onOpen: { _ in }, onEnableQuota: {}, usableHeight: usableHeight)
        let controller = NSHostingController(rootView: AnyView(view))
        // A popover opens at whatever size it has and only grows if the content insists. Start
        // the window deliberately short, the way the panel first opens before any reading has
        // arrived, so a layout that cannot insist shows up as a failure here.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderBack(nil)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let fitting = controller.view.fittingSize.height
        // What the short window actually became. This is the number that was wrong in the app
        // and right in the old test: `fittingSize` reports an unconstrained fit either way, so
        // it cannot tell a layout that insists on its height from one that quietly accepts
        // whatever it is given. Only the window can.
        let opened = window.contentView?.frame.height ?? 0
        let scrolls = controller.view.descendantScrollView() != nil
        window.orderOut(nil)
        store.stop()
        return (fitting, opened, scrolls)
    }

    /// On a display with room, the whole panel shows and nothing scrolls.
    ///
    /// This is the one that was broken in 1.0.1 and 1.0.2: the panel stayed at about 300 pt and
    /// cut a provider row in half, on a screen with 1334 pt of space.
    @MainActor func testOnARoomyScreenTheWholePanelShowsAndNothingScrolls() throws {
        let (fitting, opened, scrolls) = try panel(usableHeight: Self.roomyScreen)
        print("roomy screen: fits \(fitting) pt, window opened to \(opened) pt, scrolls = \(scrolls)")
        XCTAssertFalse(scrolls, "there is room for all of it — a scroller here is the bug")
        XCTAssertGreaterThan(opened, 600,
                             "a 300 pt window stayed at \(opened) pt: nothing is asking it to open "
                             + "to the height the content needs, which is exactly what the reader "
                             + "sees as a panel cut off mid-row")
        XCTAssertEqual(opened, fitting, accuracy: 1, "it opened to something other than its own fit")
        XCTAssertLessThanOrEqual(fitting, PanelView.ceiling(usableHeight: Self.roomyScreen))
    }

    /// And on a screen too small for it, it is capped and what the cap hides stays reachable.
    @MainActor func testOnASmallScreenThePanelIsCappedAndStaysScrollable() throws {
        let (fitting, _, scrolls) = try panel(usableHeight: Self.smallScreen)
        let cap = PanelView.ceiling(usableHeight: Self.smallScreen)
        print("small screen: panel fits at \(fitting) pt against a \(cap) pt cap, scrolls = \(scrolls)")
        XCTAssertLessThanOrEqual(fitting, cap,
                                 "\(fitting) pt against a \(cap) pt screen — the overflow goes off "
                                 + "the top, taking the header and the endurance block with it")
        XCTAssertTrue(scrolls, "capped with no scroller means everything past the cap is simply gone")
    }
}

private extension NSView {
    /// Depth-first search for a real `NSScrollView`. SwiftUI's `ScrollView` is backed by one, so
    /// its presence or absence is the honest answer to "does this panel scroll".
    func descendantScrollView() -> NSScrollView? {
        if let me = self as? NSScrollView { return me }
        for child in subviews { if let found = child.descendantScrollView() { return found } }
        return nil
    }
}
