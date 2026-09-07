import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var trophyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let store = Store()
    private var appearanceObserver: NSKeyValueObservation?
    private var outsideMonitor: Any?
    private var prefsWatch: AnyCancellable?
    private var localMonitor: Any?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        // The faces have to be in the process font list before the first view is laid out, or
        // the whole first frame renders in the system fallback.
        Theme.registerFonts()
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        buildStatusItem()
        buildMainMenu()

        Notifier.shared.start()
        // An app update ships a new hook script; the copy on disk is the one that actually runs.
        HookProvider.refreshScript(source: Self.bundledHook)
        Notifier.shared.onOpen = { [weak self] p in self?.activate(p) }

        store.onSnapshot = { [weak self] snap in self?.redraw(snap) }
        store.start()

        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
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
    private func redraw(_ snap: Snapshot) {
        guard let button = statusItem?.button else { return }
        // The button's own appearance, never the app's. macOS darkens the menu bar to suit the
        // wallpaper independently of Light/Dark mode, so an app-level check paints black glyphs
        // onto a dark bar and the icon simply vanishes.
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let image = StatusIcon.render(snap, mode: Prefs.shared.menuBarMode, dark: dark)
        button.image = image
        // A zero-size image would leave an invisible, unclickable item — say something instead.
        button.title = image.size.width > 1 ? "" : "AI"
        let sentence = snap.spoken(remaining: Prefs.shared.showRemaining)
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
                  onEnableQuota: { [weak self] in self?.store.enableRealQuota() })
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover?.isShown == true { closePopover(); return }

        store.refresh()
        let popover = makePopover()
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
        let refresh = menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let trophy = menu.addItem(withTitle: "战绩…", action: #selector(showTrophy), keyEquivalent: "")
        trophy.target = self
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PWE AI Bar",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { store.refresh(forceClaude: true) }

    // MARK: Windows

    @objc private func showTrophy() {
        closePopover()
        let view = TrophyView(trophy: store.snapshot.trophy)
        if let w = trophyWindow {
            w.contentView = NSHostingView(rootView: view)
            present(w); return
        }
        let w = panelWindow(title: "战绩", size: NSSize(width: 460, height: 620))
        w.contentView = NSHostingView(rootView: view)
        trophyWindow = w
        present(w)
    }

    @objc private func showSettings() {
        closePopover()
        let view = SettingsView(
            installHooks: { [weak self] in self?.installHooks() ?? false },
            saveToken: { [weak self] t in
                guard let self else { return .failed(-1) }
                return await self.store.saveToken(t)
            },
            enableRealQuota: { [weak self] in self?.store.enableRealQuota() })
        if let w = settingsWindow {
            w.contentView = NSHostingView(rootView: view)
            present(w); return
        }
        let w = panelWindow(title: "设置", size: NSSize(width: 380, height: 560))
        w.contentView = NSHostingView(rootView: view)
        settingsWindow = w
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
        Bundle.module.url(forResource: "pwe-ai-bar-hook", withExtension: "sh")
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
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
