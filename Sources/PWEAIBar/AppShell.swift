import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var trophyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let store = Store()
    private var appearanceObserver: NSKeyValueObservation?
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        // The faces have to be in the process font list before the first view is laid out, or
        // the whole first frame renders in the system fallback.
        Theme.registerFonts()
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        buildStatusItem()
        buildPopover()
        buildMainMenu()

        Notifier.shared.start()
        Notifier.shared.onOpen = { [weak self] p in self?.activate(p) }

        store.onSnapshot = { [weak self] snap in self?.redraw(snap) }
        store.start()

        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.redraw(self?.store.snapshot ?? Snapshot()) }
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
        button.toolTip = tooltip(snap)
        if ProcessInfo.processInfo.environment["PWEBAR_DEBUG"] != nil {
            FileHandle.standardError.write(Data("""
            [redraw] image=\(Int(image.size.width))x\(Int(image.size.height))             dark=\(dark) visible=\(statusItem.isVisible) len=\(statusItem.length)             windows=\(snap.windows.count) buttonWindow=\(button.window != nil)

            """.utf8))
        }
    }

    private func tooltip(_ snap: Snapshot) -> String {
        let remaining = Prefs.shared.showRemaining
        var lines = snap.windows.map {
            "\($0.provider.name) \($0.title) \(Readout.text($0, remaining: remaining))"
        }
        if let c = snap.contextPercent { lines.append("上下文 \(Int(c))%") }
        if snap.stale { lines.append("（显示的是上次成功读到的数字）") }
        return lines.isEmpty ? "PWE AI Bar" : lines.joined(separator: "\n")
    }

    @objc private func clicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        rightClick ? showMenu() : togglePopover()
    }

    // MARK: Panel

    /// Built once and reused. Rebuilding the hosting controller on every open threw away
    /// SwiftUI's state each time and made opening the panel visibly slow.
    ///
    /// `.applicationDefined` rather than `.transient` on purpose. A transient popover closes
    /// itself on any click outside — including the click on our own status item — and then our
    /// action fires and reopens it. The two cancel out and the icon reads as dead. Owning the
    /// dismissal means one click is one toggle.
    private func buildPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: panel)
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
        if popover.isShown { closePopover(); return }

        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)

        // Dismiss on the next click anywhere else — including in another app, which a local
        // monitor alone would miss.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // A click inside the popover is not a dismissal; a click anywhere else is.
                if let self, event.window !== self.popover.contentViewController?.view.window,
                   event.window !== self.statusItem.button?.window {
                    Task { @MainActor in self.closePopover() }
                }
                return event
            }
    }

    private func closePopover() {
        popover.performClose(nil)
        statusItem.button?.highlight(false)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
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

    @objc private func refreshNow() { store.refresh() }

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
            saveToken: { [weak self] t in self?.store.saveToken(t) },
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

    private func installHooks() -> Bool {
        guard let src = Bundle.module.url(forResource: "pwe-ai-bar-hook", withExtension: "sh")
        else { return false }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/pwe-ai-bar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("pwe-ai-bar-hook.sh")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        return HookProvider.install(scriptPath: dst.path)
    }

    /// Bring the agent's own app forward. Falls back to its website when nothing is installed —
    /// clicking "go look" and having nothing happen is worse than opening the wrong thing.
    private func activate(_ p: Provider) {
        store.clearAttention()
        for id in p.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
        if p == .claude, let u = URL(string: "https://claude.ai/code") {
            NSWorkspace.shared.open(u)
        }
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
