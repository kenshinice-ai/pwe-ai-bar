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
/// These tests cover the panel's half of that contract: the height it reports. The other half
/// — where AppKit actually puts the window — is not something a hosting view can be asked
/// about, and pretending otherwise is how the last two attempts passed while broken. That half
/// has its own check: `PWEAIBar --popover` opens the real panel on a real status item and
/// prints the popover's frame against the screen's. Run it after touching any of this.
final class PanelHeightTests: XCTestCase {

    /// The smallest Mac still sold is 1440 x 900 points.
    static let smallScreen: CGFloat = 860
    /// What Lee's display actually has, and the case that must not scroll.
    static let roomyScreen: CGFloat = 1334

    @MainActor private func panel(usableHeight: CGFloat)
        throws -> (desired: CGFloat, fitting: CGFloat, opened: CGFloat, scrollable: Bool) {
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
        // Read the height through the channel the app actually uses. `view.desiredHeight` on a
        // local copy of the struct is always nil: the measurement lives in SwiftUI's storage,
        // not in the value handed to the hosting controller.
        final class Box: @unchecked Sendable { var heights: [CGFloat] = [] }
        let box = Box()
        let view = PanelView(store: store, prefs: prefs, onTrophy: {}, onSettings: {},
                             onOpen: { _ in }, onEnableQuota: {},
                             usableHeight: { usableHeight },
                             onHeight: { box.heights.append($0) })
        let controller = NSHostingController(rootView: AnyView(view))
        // A popover opens at whatever size it has and only grows if the content insists. Start
        // the window deliberately short, the way the panel first opens before any reading has
        // arrived, so a layout that cannot insist shows up as a failure here.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderBack(nil)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let desired = box.heights.last ?? 0
        print("  reported heights: \(box.heights.map { Int($0) })")

        // Then do what `AppDelegate.resizePanel` does: set the size the panel asked for. The
        // window is deliberately started short and does NOT grow on its own — a ScrollView
        // creates no height constraint, which is the whole reason the app sets `contentSize`
        // rather than trusting layout to push the popover open. Asserting that it grew by itself
        // would be asserting a mechanism this app deliberately does not rely on.
        if desired > 0 { window.setContentSize(NSSize(width: Theme.panelWidth, height: desired)) }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let fitting = controller.view.fittingSize.height
        // What the short window actually became. This is the number that was wrong in the app
        // and right in the old test: `fittingSize` reports an unconstrained fit either way, so
        // it cannot tell a layout that insists on its height from one that quietly accepts
        // whatever it is given. Only the window can.
        let opened = window.contentView?.frame.height ?? 0
        // The scroller is always present now; what matters is whether it has anything to
        // scroll, which is the difference between "capped and reachable" and "capped and gone".
        // `firstScrollView` is the app's own helper — a second copy here would let the probe and
        // this test drift apart on what "is it scrolling" means, and a `!` on a missing scroller
        // would take the whole test bundle down instead of failing one case.
        let scroller = controller.view.firstScrollView()
        let scrollable = (scroller?.documentView?.frame.height ?? 0)
            > (scroller?.contentView.bounds.height ?? .greatestFiniteMagnitude) + 1
        window.orderOut(nil)
        store.stop()
        return (desired, fitting, opened, scrollable)
    }

    /// On a display with room, the panel asks for its whole height and has nothing to scroll.
    ///
    /// Broken twice before this. 1.0.1/1.0.2 wrapped everything in a `ScrollView`, which asks
    /// for no height at all, so the popover stayed at about 300 pt with the panel scrolling
    /// inside it. 1.0.3 removed the wrapper, so the content took its natural height — and
    /// AppKit, resizing a popover that was already on screen, hung its top 338 pt above the
    /// menu bar (measured; `--popover` reproduces both).
    ///
    /// Neither was a layout bug. The panel has to *state* a height and something has to set it.
    @MainActor func testOnARoomyScreenThePanelAsksForItsWholeHeight() throws {
        let (desired, _, _, scrollable) = try panel(usableHeight: Self.roomyScreen)
        print("roomy: desired \(desired), scrollable \(scrollable)")
        XCTAssertGreaterThan(desired, 600,
                             "the panel asked for \(desired) pt — nothing is measuring it, and a "
                             + "panel that states no height is one AppKit sizes on a guess")
        XCTAssertLessThanOrEqual(desired, PanelView.ceiling(usableHeight: Self.roomyScreen))
        // Given the height it asked for, everything fits. This is the assertion that fails if
        // the ask is too small — the 1.0.1/1.0.2 shape, where the panel scrolled inside a box
        // far smaller than its content.
        XCTAssertFalse(scrollable, "there is room for all of it — scrolling here is the bug")
    }

    /// And on a screen too small for it, the ask is the cap and the rest stays reachable.
    @MainActor func testOnASmallScreenThePanelAsksForTheCapAndStaysScrollable() throws {
        let (desired, _, _, scrollable) = try panel(usableHeight: Self.smallScreen)
        let cap = PanelView.ceiling(usableHeight: Self.smallScreen)
        print("small: desired \(desired) against cap \(cap), scrollable \(scrollable)")
        XCTAssertEqual(desired, cap, accuracy: 1,
                       "on a screen this size the panel must ask for the cap, not \(desired) pt — "
                       + "anything taller has its header pushed off the top of the screen")
        XCTAssertTrue(scrollable, "capped with nothing to scroll means the rest is simply gone")
    }
}

/// The settings window used to be a fixed 380 × 560 with a 620 pt cap inside it, so on a large
/// display it showed about half of itself and no amount of rearranging would have fixed that.
/// It now follows the same rule as the panel, from the same owner, with its own chrome inset.
final class SurfaceCeilingTests: XCTestCase {
    func testEverySurfaceIsCappedByItsScreenAndNothingElse() {
        XCTAssertEqual(Theme.ceiling(usableHeight: 1334, inset: 32), 1302, "the panel keeps its beak")
        XCTAssertEqual(Theme.ceiling(usableHeight: 1334, inset: 88), 1246, "the window keeps its title bar")
        XCTAssertEqual(PanelView.ceiling(usableHeight: 1334), 1302)
        XCTAssertEqual(SettingsView.ceiling(usableHeight: 1334), 1246)
    }

    func testABiggerScreenAlwaysBuysMoreRoom() {
        for inset in [CGFloat(32), 88] {
            XCTAssertGreaterThan(Theme.ceiling(usableHeight: 1600, inset: inset),
                                 Theme.ceiling(usableHeight: 1000, inset: inset),
                                 "a second cap chosen on taste would flatten this out")
        }
    }

    func testAPathologicalScreenStillLeavesSomethingReadable() {
        XCTAssertEqual(Theme.ceiling(usableHeight: 200, inset: 88), 420)
    }
}


/// The settings groups collapse, and which ones start open is a decision, not an accident.
final class SettingsGroupTests: XCTestCase {
    @MainActor func testDisplayAndAlertsOpenByDefaultAndTheChoiceIsRemembered() throws {
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        XCTAssertTrue(prefs.isOpen("display"), "what an existing user came to change")
        XCTAssertTrue(prefs.isOpen("alerts"))
        XCTAssertFalse(prefs.isOpen("sources"), "set once, then left alone")
        XCTAssertFalse(prefs.isOpen("general"))
        prefs.setOpen("sources", true); prefs.setOpen("display", false)
        let again = Prefs(defaults: space.defaults)
        XCTAssertTrue(again.isOpen("sources"), "remembered per group, across launches")
        XCTAssertFalse(again.isOpen("display"))
    }

    /// The point of collapsing: as the window opens it must fit a laptop screen with no scroller,
    /// and fully expanded it must still be capped by the screen rather than by taste.
    @MainActor func testTheDefaultStateFitsWithoutScrollingAndExpandedIsCappedByTheScreen() throws {
        _ = NSApplication.shared
        Loc.language = .en
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        func height(usable: CGFloat) -> CGFloat {
            let v = SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                 enableRealQuota: { "" }, prefs: prefs,
                                 tokenEditor: TokenEditor(hasToken: false), hookInstalled: false,
                                 usableHeight: { usable })
            return NSHostingView(rootView: v).fittingSize.height
        }
        let laptop: CGFloat = 900            // a 13" MacBook's usable height, roughly
        let opening = height(usable: laptop)
        XCTAssertLessThan(opening, SettingsView.ceiling(usableHeight: laptop),
                          "as it opens, the page must fit a laptop screen with no scroller: \(opening) pt")
        for g in ["display", "alerts", "sources", "general"] { prefs.setOpen(g, true) }
        let everything = height(usable: 4000)
        XCTAssertGreaterThan(everything, opening * 1.5, "expanding must actually reveal something")
        XCTAssertEqual(height(usable: laptop), SettingsView.ceiling(usableHeight: laptop), accuracy: 0.5,
                       "fully open on a small screen, the cap is the screen — and nothing else")
    }
}

/// A settings window that opens as a bare title bar is a window that does not open. This puts the
/// real view in a real window, pumps the run loop the way the panel test does, and measures what a
/// person would see. `NSHostingView.fittingSize` before layout — the number 1.0.10 through 1.0.14
/// sized this window from — is 0 here, which is the whole bug.
final class SettingsWindowTests: XCTestCase {
    private final class Reports: @unchecked Sendable { var heights: [CGFloat] = [] }
    private func pump(_ n: Int) { for _ in 0..<n { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }

    @MainActor func testTheSettingsWindowOpensAtAUsableHeightAndShrinksWhenGroupsCollapse() throws {
        _ = NSApplication.shared
        Loc.language = .en
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        let reports = Reports()
        let view = SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                enableRealQuota: { "" }, prefs: prefs,
                                tokenEditor: TokenEditor(hasToken: false), hookInstalled: false,
                                usableHeight: { 900 },
                                onHeight: { [weak w] h in reports.heights.append(h); w?.setContentHeight(h, animate: false) })
        w.contentView = NSHostingView(rootView: view)
        w.orderBack(nil)
        pump(30)
        let overlap = w.titleBarOverlap
        let shown = w.contentRect(forFrameRect: w.frame).height
        print("  settings window: reported \(reports.heights.map { Int($0) }), title-bar overlap \(Int(overlap)), window \(Int(shown))")
        XCTAssertFalse(reports.heights.isEmpty, "the page never stated a height — nothing is measuring it")
        XCTAssertGreaterThan(shown - overlap, 400, "the room below the title bar is \(shown - overlap) pt")
        XCTAssertEqual(shown - overlap, reports.heights.last ?? -1, accuracy: 1, "exactly what the page asked for")
        XCTAssertLessThanOrEqual(reports.heights.last ?? .infinity, SettingsView.ceiling(usableHeight: 900), "never past the screen")

        prefs.setOpen("display", false); prefs.setOpen("alerts", false)
        pump(30)
        let collapsed = w.contentRect(forFrameRect: w.frame).height
        XCTAssertLessThan(collapsed, shown - 200, "collapsing both open groups must shrink the window: \(Int(shown)) → \(Int(collapsed))")
        XCTAssertGreaterThan(collapsed - overlap, 150, "but four headers and a footer are still a window")
        w.orderOut(nil)
    }
}

/// Querying a provider and giving it a place in the menu bar are two questions. They used to be
/// one switch — and in the menu bar even that switch was ignored for five of the eight.
final class MenuBarVisibilityTests: XCTestCase {
    @MainActor func testAnUpgradeDoesNotEmptyAnyonesMenuBar() throws {
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        XCTAssertTrue(prefs.menuBarProviders.isEmpty, "nothing stored yet")
        XCTAssertTrue(prefs.showsInMenuBar(.claude), "empty means all, not none")
        XCTAssertTrue(prefs.showsInMenuBar(.codex))
    }

    @MainActor func testTakingOneOutLeavesTheRestIn() throws {
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        prefs.setMenuBar(.codex, false)
        XCTAssertFalse(prefs.showsInMenuBar(.codex), "the one taken out")
        XCTAssertTrue(prefs.showsInMenuBar(.claude), "and only that one")
        XCTAssertFalse(prefs.menuBarProviders.isEmpty, "the set is materialised on first removal")
    }

    @MainActor func testAnUntrackedProviderIsNeverInTheMenuBar() throws {
        let space = try TestSpace()
        let prefs = Prefs(defaults: space.defaults)
        prefs.setTracking(.codex, false)
        XCTAssertFalse(prefs.showsInMenuBar(.codex),
                       "not queried cannot mean shown; the bar had its own opinion about this")
    }

    /// Structural: the menu-bar gate used to end in `|| (p != .claude && p != .codex)`, which let
    /// the other five in whether or not they were switched on.
    func testTheMenuBarGateHasNoEscapeHatch() throws {
        let icon = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/App/StatusIcon.swift"), encoding: .utf8)
        XCTAssertTrue(icon.contains("Prefs.shared.showsInMenuBar(p)"), "one gate")
        XCTAssertFalse(icon.contains("p != .claude && p != .codex"), "and no way round it")
    }

    func testTheRefreshChoicesMeanWhatTheySay() {
        XCTAssertNil(RefreshInterval.automatic.seconds, "automatic is the app deciding, not a number")
        XCTAssertEqual(RefreshInterval.oneMinute.seconds, 60)
        XCTAssertEqual(RefreshInterval.fiveMinutes.seconds, 300)
        XCTAssertEqual(RefreshInterval.fifteenMinutes.seconds, 900)
        let store = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/Core/Store.swift"), encoding: .utf8)
        XCTAssertTrue(store?.contains("if let fixed = Prefs.shared.refreshInterval.seconds { return fixed }") == true,
                      "a stated preference has to be consulted before the app's own judgement")
    }
}
