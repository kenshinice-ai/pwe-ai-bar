import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    /// Remembered across launches. The panel cannot be measured until it has been laid out, and
    /// it is not laid out until it is first shown — so on the first click of every launch there
    /// was nothing to size the popover with, and it opened at its natural height with its top
    /// off the screen. Last run's height is a far better opening guess than none.
    private var panelHeight: CGFloat = UserDefaults.standard.double(forKey: "panelHeight")
    private var trophyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let store = Store()
    private let updates = UpdateCheck()
    private var appearanceObserver: NSKeyValueObservation?
    private var outsideMonitor: Any?
    private var prefsWatch: AnyCancellable?
    private var localMonitor: Any?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Before the first view is built, or the first frame renders in the wrong language.
        Loc.language = Prefs.shared.language
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        buildStatusItem()
        buildMainMenu()

        Notifier.shared.start()
        // An app update ships a new hook script; the copy on disk is the one that actually runs.
        HookProvider.refreshScript(source: Self.bundledHook)
        Notifier.shared.onOpen = { [weak self] p in self?.activate(p) }

        store.onSnapshot = { [weak self] snap in self?.redraw(snap) }
        store.start()

        // After the interface is up, never before it: an update check is a convenience, and a
        // convenience must not be on the path between launching and seeing a number.
        Task { [weak self] in
            await self?.updates.checkIfDue(enabled: Prefs.shared.updateChecks)
        }

        // `.old`/`.new`, and only when the name actually changed. Without that this is a loop:
        // `redraw` assigns `button.image`, assigning it makes AppKit re-resolve the button's
        // effective appearance, re-resolving fires this observer, and the observer redraws.
        // Measured at about 3,050 redraws a second — half a core on an app that is doing
        // nothing, and the reason the CPU climbed rather than settled.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance,
                                                       options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue?.name != change.newValue?.name else { return }
            Task { @MainActor in self?.redraw(self?.store.snapshot ?? Snapshot()) }
        }

        // Density and the used/remaining convention both change what the glyph says. Without
        // this the settings window updates instantly and the menu bar keeps showing the old
        // reading for up to twenty seconds, which reads as the switch not having worked.
        prefsWatch = Prefs.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.redraw(self.store.snapshot)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        redraw(store.snapshot)
    }

    /// Redrawn only when a snapshot lands — every 20 s while you work, every 5 min when nothing
    /// is moving. No timer of its own, no animation: a menu bar that moves all day is an anxiety
    /// source, not an information source.
    /// The guard in `redraw` is not an optimisation — see `PaintedState`.
    private var painted = PaintedState()

    private func redraw(_ snap: Snapshot) {
        guard let button = statusItem?.button else { return }
        // The button's own appearance, never the app's. macOS darkens the menu bar to suit the
        // wallpaper independently of Light/Dark mode, so an app-level check paints black glyphs
        // onto a dark bar and the icon simply vanishes.
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let image = StatusIcon.render(snap, mode: Prefs.shared.menuBarMode, dark: dark, prefs: .shared)
        let sentence = snap.spoken(remaining: Prefs.shared.showRemaining)
        // Compared on what was actually drawn, not on a key naming the inputs. The glyph carries
        // a countdown, so a key would have to know about time — and a key that falls out of step
        // with the renderer freezes the menu bar, which is a worse bug than the one it fixes.
        guard painted.adopt(image.tiffRepresentation, sentence) else { return }
        button.image = image
        // A zero-size image would leave an invisible, unclickable item — say something instead.
        button.title = image.size.width > 1 ? "" : "AI"
        button.toolTip = sentence
        button.setAccessibilityLabel("PWE AI Bar")
        button.setAccessibilityValue(sentence)
        if ProcessInfo.processInfo.environment["PWEBAR_DEBUG"] != nil {
            FileHandle.standardError.write(Data("""
            [redraw] image=\(Int(image.size.width))x\(Int(image.size.height))             dark=\(dark) visible=\(statusItem.isVisible) len=\(statusItem.length)             windows=\(snap.windows.count) buttonWindow=\(button.window != nil)

            """.utf8))
        }
    }

    @objc private func clicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        rightClick ? showMenu() : togglePopover()
    }

    // MARK: Panel

    /// Built on first open, then reused.
    ///
    /// Two things here. Building the SwiftUI graph at launch costs real memory for a panel most
    /// launches never show — deferring it is most of the difference between a menu-bar app that
    /// sits at ninety megabytes and one that sits well below. And it is built *once*: rebuilding
    /// the hosting controller on every open threw away SwiftUI's state each time and made the
    /// panel visibly slow to appear.
    ///
    /// `.applicationDefined` rather than `.transient` on purpose. A transient popover closes
    /// itself on any click outside — including the click on our own status item — and then our
    /// action fires and reopens it. The two cancel out and the icon reads as dead. Owning the
    /// dismissal means one click is one toggle.
    private func makePopover() -> NSPopover {
        if let popover { return popover }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = false
        p.contentViewController = NSHostingController(rootView: panel)
        popover = p
        return p
    }

    private var panel: some View {
        PanelView(store: store,
                  onTrophy: { [weak self] in self?.showTrophy() },
                  onSettings: { [weak self] in self?.showSettings() },
                  onOpen: { [weak self] p in self?.activate(p) },
                  onEnableQuota: { [weak self] in Task { _ = await self?.store.enableRealQuota() } },
                  updates: updates,
                  // The screen the status item is actually on. `NSScreen.main` is the screen
                  // holding the key window, which for a menu-bar app is whatever other app is
                  // frontmost — with a laptop plus an external display that is routinely the
                  // wrong one, and the panel would size against the wrong height.
                  usableHeight: { [weak self] in
                      self?.statusItem?.button?.window?.screen?.visibleFrame.height
                  },
                  onHeight: { [weak self] h in self?.resizePanel(to: h) })
    }

    /// The panel says how tall it wants to be; this is what makes the popover that size.
    ///
    /// Left to constraint propagation alone this went wrong twice, in opposite directions — a
    /// popover stuck at 300 pt with the panel scrolling inside it, then a popover so tall its
    /// header sat above the menu bar. Setting `contentSize` outright is not a workaround for
    /// either; it is the size being stated once, by the half of the code that can measure it,
    /// to the half that owns the window.
    private func resizePanel(to height: CGFloat) {
        guard height > 0, abs(height - panelHeight) > 0.5 else { return }
        panelHeight = height
        UserDefaults.standard.set(height, forKey: "panelHeight")
        // Deliberately not applied while the panel is open. Resizing a popover that is already
        // on screen makes AppKit re-anchor it, and on a status item that is how its top ends up
        // above the menu bar. A reading that arrives mid-view scrolls instead — the content
        // stays reachable — and the new height takes effect the next time it is opened.
        guard popover?.isShown != true else { return }
        popover?.contentSize = NSSize(width: Theme.panelWidth, height: height)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover?.isShown == true { closePopover(); return }

        store.refresh()
        let popover = makePopover()
        // Size it before it is shown. A popover that grows after it is on screen is re-anchored
        // by AppKit, and on a status item that is how its top ends up off the top of the screen.
        if panelHeight > 0 {
            popover.contentSize = NSSize(width: Theme.panelWidth, height: panelHeight)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)

        // Dismiss on the next click anywhere else — including in another app, which a local
        // monitor alone would miss.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        // Escape closes it. `.applicationDefined` means we own dismissal entirely, and a panel
        // you can open with the mouse but not close with the keyboard is a panel that traps you.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            Task { @MainActor in self?.closePopover() }
            return nil
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // A click inside the popover is not a dismissal; a click anywhere else is.
                if let self, event.window !== self.popover?.contentViewController?.view.window,
                   event.window !== self.statusItem.button?.window {
                    Task { @MainActor in self.closePopover() }
                }
                return event
            }
    }

    private func closePopover() {
        popover?.performClose(nil)
        statusItem.button?.highlight(false)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        let refresh = menu.addItem(withTitle: L("menu.refreshNow", "Refresh now"), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let trophy = menu.addItem(withTitle: L("menu.trophy", "Trophy…"), action: #selector(showTrophy), keyEquivalent: "")
        trophy.target = self
        let settings = menu.addItem(withTitle: L("menu.settings", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("menu.quitNamed", "Quit PWE AI Bar"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { store.refresh(forceClaude: true) }

    // MARK: Windows

    @objc private func showTrophy() {
        closePopover()
        // Observing the store rather than snapshotting the trophy: changing the range has to
        // re-aggregate, and a window holding a value copied at open time would keep showing the
        // old span while the picker said otherwise.
        let view = TrophyWindow(store: store, onRangeChange: { [weak self] _ in self?.store.refresh() })
        if let w = trophyWindow {
            w.contentView = NSHostingView(rootView: view)
            present(w); return
        }
        let w = panelWindow(title: L("window.trophy", "Trophy"), size: NSSize(width: 460, height: 620))
        w.contentView = NSHostingView(rootView: view)
        trophyWindow = w
        present(w)
    }

    /// Whether the settings window has taken its first measured height. The first report sizes
    /// the window before anyone has looked at it and must not animate; the ones after are a
    /// group opening or closing under the pointer, and those should.
    private var settingsSizedOnce = false

    @objc private func showSettings() {
        closePopover()
        let fresh = settingsWindow == nil
        let w = settingsWindow ?? panelWindow(title: L("window.settings", "Settings"),
                                              size: NSSize(width: 380, height: 560))
        settingsWindow = w
        settingsSizedOnce = false
        // The window's height comes from the view, once SwiftUI has measured it — the same
        // contract as the panel. Not from `NSHostingView.fittingSize`, which is 0 for a hosted
        // ScrollView until layout and which sized this window to a bare title bar on the first
        // Mac that ever ran the app past launch. 560 is only what shows for the frame before
        // the first report lands.
        let view = SettingsView(
            installHooks: { [weak self] in self?.installHooks() ?? false },
            saveToken: { [weak self] t in
                guard let self else { return .failed(-1) }
                return await self.store.saveToken(t)
            },
            enableRealQuota: { [weak self] in
                guard let self else { return "" }
                return await self.store.enableRealQuota()
            },
            updates: updates,
            onHeight: { [weak self, weak w] height in
                guard let self, let w else { return }
                w.setContentHeight(height, animate: self.settingsSizedOnce)
                if !self.settingsSizedOnce, fresh { w.center() }
                self.settingsSizedOnce = true
            })
        w.contentView = NSHostingView(rootView: view)
        present(w)
    }

    private func panelWindow(title: String, size: NSSize) -> NSWindow {
        let w = KeyableWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    private static var bundledHook: URL? {
        Bundle.resources.url(forResource: "pwe-ai-bar-hook", withExtension: "sh")
    }

    private func installHooks() -> Bool {
        guard let src = Self.bundledHook else { return false }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/pwe-ai-bar")
        let dst = dir.appendingPathComponent("pwe-ai-bar-hook.sh")
        return HookProvider.install(scriptPath: dst.path, source: src)
    }

    /// Bring the agent's own app forward. Falls back to its website when nothing is installed —
    /// clicking "go look" and having nothing happen is worse than opening the wrong thing.
    private func activate(_ p: Provider) {
        for id in p.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        if let u = p.fallbackURL { NSWorkspace.shared.open(u) }
    }

    /// An accessory app shows no menu bar, but a main menu is still what wires up ⌘C / ⌘V / ⌘W
    /// inside text fields and windows.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.settings", "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
    }
}

/// A titled window that can still take focus while the app runs as an accessory. The default
/// refuses key status for a non-activating app, which would leave the push-URL field uneditable.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The trophy page as a window: live, so the range picker has something to change.
private struct TrophyWindow: View {
    @ObservedObject var store: Store
    var onRangeChange: (TrophyRange) -> Void
    var body: some View {
        TrophyView(trophy: store.snapshot.trophy, onRangeChange: onRangeChange)
    }
}
