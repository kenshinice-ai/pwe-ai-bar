import AppKit
import SwiftUI

/// `PWEAIBar --probe` — one snapshot, printed, then exit.
///
/// The interface is the wrong place to debug a data source: a wrong number looks the same as a
/// right one on a 22 pt bar. This prints what every provider actually returned, so a bad reading
/// can be traced to the source that produced it without launching anything.
@MainActor
enum Probe {

    /// `--icon DIR` writes the menu-bar glyph as it would actually be drawn, both appearances
    /// and all three densities. A 22 pt icon is too small to debug by squinting at the bar, and
    /// an icon that renders empty looks exactly like one macOS decided to hide.
    static func icons(into dir: String) {
        // Deliberately synthetic, and it must say so: these numbers exercise calm/warm/exhausted
        // in one frame, which live data will not do on demand. Mistaking this sheet for a live
        // reading is a good way to go hunting for a bug that is not there.
        print("  （合成数据，非实时读数：58 / 87 / 耗尽）")
        var snap = Snapshot()
        snap.windows = [
            QuotaWindow(id: "session", provider: .claude, channel: .session, title: "五小时窗口",
                        percent: 58, severity: .normal,
                        resetsAt: Date().addingTimeInterval(2600)),
            QuotaWindow(id: "weekly_all", provider: .claude, channel: .week, title: "周窗口",
                        percent: 87, severity: .warning,
                        resetsAt: Date().addingTimeInterval(60000), isActive: true),
            QuotaWindow(id: "codex", provider: .codex, channel: .codex, title: "Codex",
                        percent: nil, severity: .critical, note: "耗尽"),
        ]
        snap.contextPercent = 39

        // The provider marks on their own, big enough to judge. At 13 pt a silhouette either
        // reads instantly or it does not, and squinting at the bar cannot tell you which.
        for dark in [true, false] {
            let width = CGFloat(Provider.allCases.count) * 70 + 20
            let sheet = NSImage(size: NSSize(width: width, height: 80))
            sheet.lockFocus()
            NSColor(Theme.hex(dark ? Theme.navy : Theme.paper)).setFill()
            NSRect(x: 0, y: 0, width: width, height: 80).fill()
            for (i, p) in Provider.allCases.enumerated() {
                let big = NSRect(x: 20 + CGFloat(i) * 70, y: 30, width: 44, height: 44)
                ProviderMark.draw(p, in: big, color: NSColor(Theme.hex(dark ? Theme.amber : Theme.amberDeep)))
                let small = NSRect(x: 36 + CGFloat(i) * 70, y: 10, width: 13, height: 13)
                ProviderMark.draw(p, in: small, color: NSColor(Theme.hex(dark ? Theme.textDark : Theme.ink)))
            }
            sheet.unlockFocus()
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/marks-\(dark ? "dark" : "light").png"))
            }
        }

        for dark in [true, false] {
            for mode in MenuBarMode.allCases {
                let image = StatusIcon.render(snap, mode: mode, dark: dark)
                let name = "icon-\(mode.rawValue)-\(dark ? "dark" : "light").png"
                write(image, to: dir + "/" + name)
                print("  \(name)  \(Int(image.size.width))×\(Int(image.size.height))")
            }
        }
    }

    /// Renders any view at a fixed width, in a chosen appearance, to a PNG.
    private static func shoot(_ view: AnyView, width: CGFloat, dark: Bool, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        // Let any entrance animation settle, or the snapshot catches the first frame and every
        // bar comes out flat.
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("  \((path as NSString).lastPathComponent)  \(Int(width))×\(Int(host.frame.height))")
    }

    private static func write(_ image: NSImage, to path: String) {
        // Composite onto a menu-bar-ish ground: a transparent PNG of white glyphs is
        // indistinguishable from an empty one.
        let scale: CGFloat = 4
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = NSImage(size: size)
        out.lockFocus()
        (path.contains("dark") ? NSColor(Theme.hex(Theme.navy)) : NSColor(Theme.hex(Theme.paper)))
            .setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// `--panel DIR` renders all three densities in both appearances, from live data. The
    /// panel is only reachable by clicking a 22 pt target, which makes it awkward to inspect
    /// while iterating — and impossible to diff against the design sheet.
    static func panels(into dir: String) async {
        let store = Store()
        store.start()
        // Wait for data rather than a fixed sleep. The first run of a freshly built binary can
        // sit on a keychain dialog — an ad-hoc signature changes on every build, so macOS treats
        // each one as a new app — and a fixed sleep silently renders an empty panel.
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            if !store.snapshot.windows.isEmpty || store.snapshot.trophy.turns > 0 { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        if store.snapshot.windows.isEmpty && store.snapshot.trophy.turns == 0 {
            print("  ⚠ 没等到数据——钥匙串授权框可能还开着")
        }
        try? await Task.sleep(for: .seconds(2))    // let the last fields settle
        // Offscreen rendering and a live store both want the main actor, and the store wins
        // every second forever. Nothing below needs new data; freeze what we have and draw it.
        store.stop()

        // The other two surfaces get rendered too. Settings and the trophy page are each two
        // clicks deep, which is exactly why they rot: nobody looks at them while iterating.
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            shoot(AnyView(TrophyView(trophy: store.snapshot.trophy)),
                  width: 460, dark: dark, to: dir + "/trophy-\(suffix).png")
            shoot(AnyView(SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                       enableRealQuota: {})),
                  width: 380, dark: dark, to: dir + "/settings-\(suffix).png")
        }

        for dark in [true, false] {
            for mode in PanelMode.allCases {
                Prefs.shared.panelMode = mode
                let view = PanelView(store: store, onTrophy: {}, onSettings: {}, onOpen: { _ in }, onEnableQuota: {})
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: Theme.panelWidth,
                                    height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = "panel-\(mode.rawValue)-\(dark ? "dark" : "light").png"
                try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
                print("  \(name)  \(Int(host.frame.width))×\(Int(host.frame.height))")
            }
        }
    }

    /// Metadata only; this command does not retrieve tokens or validate network access.
    /// `--cred`: what the setup is, in words. Named apart from `credentials()` because two
    /// functions differing only by `async` is a coin toss at the call site.
    static func credentialsHelp() {
        print("PWE AI Bar — " + L("probe.credConfig", "credential configuration"))
        print(L("probe.manualToken", "Manual token on record") + ": "
              + (Credentials.hasStoredOwnToken ? L("probe.yes", "yes") : L("probe.no", "no")))
        print(L("probe.reuseNote",
                "The Claude Code login is reused by default. The panel is authoritative for which "
                + "source was used and when it last worked."))
        print(L("probe.refreshNote",
                "A usable refresh token is spent on renewal and written safely back to where it came "
                + "from; if that fails, sign in again."))
        print(L("probe.keychainNote",
                "Keychain access is macOS's decision; this command does not test whether it is granted."))
    }

    /// `--stress DIR` renders the panel against data designed to break it: every bucket the
    /// endpoint might one day populate, names longer than their column, a hundred-per-cent
    /// window, a state with no ratio, and a trophy in the millions.
    ///
    /// Real data is always tidy — two windows, short names, sane numbers — so layout that only
    /// ever meets real data has never actually been tested.
    /// `--endurance DIR` draws the forecast instrument on its own, across every state it can
    /// reach. Real data is tidy: it will show one or two of these and never the other seven, so
    /// the branches that only appear on a bad day would never be looked at.
    /// `--credentials` answers the one question this app should never make someone guess at:
    /// why it cannot read Claude quota right now. Each source is reported separately — present
    /// or not, expired or not, and what the endpoint actually says to it. No token is printed.
    ///
    /// Written because the answer turned out to be genuinely surprising: the credential Claude
    /// Code keeps in the keychain sat expired for twelve hours while Claude Code itself ran the
    /// whole time, and no surface in the app could tell you that was what had happened.
    static func credentials() async { await quotaStatus(readOnly: false) }

    /// Uses the same pipeline as the app; output contains no credentials, account IDs or bodies.
    static func quotaStatus(readOnly: Bool) async {
        var access = ClaudeProvider.Access.live
        if readOnly { access.persist = nil }
        let provider = ClaudeProvider(access: access)
        let reading = await provider.windows(force: true)
        let details = await provider.details
        let state = await provider.blocker
        print("PWE AI Bar — " + String(format: L("probe.quotaCheck", "Claude quota check (%@)"),
                                       readOnly ? L("probe.noRotate", "no renewal")
                                                : L("probe.withRotate", "renewal as normal")))
        print(L("probe.state", "State") + ": " + state.message)
        print(L("probe.source", "Source") + ": " + details.source.rawValue)
        print(String(format: L("probe.windows", "Windows: %d   stale: %@"), reading.windows.count,
                     reading.stale ? L("probe.yes", "yes") : L("probe.no", "no")))
        print(L("probe.everSucceeded", "Ever read successfully") + ": "
              + (details.lastSuccessAt != nil ? L("probe.yes", "yes") : L("probe.no", "no")))
        // The one question the credential itself cannot answer. Claude Code writes the same
        // keychain item, and the rotation preserves every field it does not own, so after the
        // fact there is no telling from the record which of the two rewrote it.
        if let r = ClaudeProvider.refreshRecord() {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
            print(String(format: L("probe.renewal", "Renewed by this app: %@ · %@ · %d successful in total"),
                         f.string(from: r.at), r.outcome, r.count))
        } else {
            print(L("probe.renewal.never",
                    "Renewed by this app: never — every keychain update so far was somebody else's"))
        }
    }

    static func endurance(into dir: String) {
        let hour: TimeInterval = 3600
        let now = Date()
        func window(_ label: String, percent: Double?, resetIn: TimeInterval,
                    length: TimeInterval?, stale: Bool = false, spent: Bool = false,
                    observedAgo: TimeInterval = 0,
                    samples: [(TimeInterval, Double)] = []) -> (String, QuotaWindow) {
            var w = QuotaWindow(id: "five_hour", provider: .claude, channel: .session,
                                title: "五小时窗口", percent: percent,
                                resetsAt: resetIn == 0 ? nil : now.addingTimeInterval(resetIn),
                                observedAt: now.addingTimeInterval(-observedAgo), isStale: stale,
                                confirmedExhausted: spent, windowLength: length)
            w.samples = samples.map {
                History.Sample(at: now.addingTimeInterval($0.0), percent: $0.1)
            }
            return (label, w)
        }
        // Shapes taken from the real cache rather than invented: a burst of integer steps, a
        // long flat stretch, and a single step with nothing either side of it.
        let burst: [(TimeInterval, Double)] = [(-1500, 60), (-1200, 63), (-900, 66),
                                               (-600, 69), (-300, 72), (0, 75)]
        let flat: [(TimeInterval, Double)] = [(-2700, 40), (-1800, 40), (-900, 40), (0, 40)]
        let oneStep: [(TimeInterval, Double)] = [(-1800, 94), (0, 95)]
        let weekly: [(TimeInterval, Double)] = [(-900, 19), (-835, 20), (-675, 21), (0, 23)]
        let cases = [
            window("short", percent: 70, resetIn: 2 * hour, length: 5 * hour),
            window("measured", percent: 75, resetIn: 2 * hour, length: 5 * hour, samples: burst),
            window("flat", percent: 40, resetIn: 3 * hour, length: 5 * hour, samples: flat),
            window("tooclose", percent: 95, resetIn: 4 * hour, length: 5 * hour, samples: oneStep),
            window("comfortable", percent: 18, resetIn: 2 * hour, length: 5 * hour),
            window("offscale", percent: 6, resetIn: 2 * hour, length: 5 * hour),
            window("touching", percent: 60, resetIn: 2 * hour, length: 5 * hour),
            window("spent", percent: 100, resetIn: 90 * 60, length: 5 * hour, spent: true),
            window("blind", percent: nil, resetIn: 2 * hour, length: 5 * hour,
                   stale: true, observedAgo: 7 * hour),
            window("stale", percent: 55, resetIn: 2 * hour, length: 5 * hour,
                   stale: true, observedAgo: 400),
            window("nolength", percent: 55, resetIn: 2 * hour, length: nil),
            window("noratio", percent: nil, resetIn: 2 * hour, length: 5 * hour),
            window("noreset", percent: 55, resetIn: 0, length: 5 * hour),
            window("weekly", percent: 23, resetIn: 6.5 * 86400, length: 7 * 86400, samples: weekly),
        ]
        func line(_ k: String, _ v: String) {
            print("  \(k.padding(toLength: 12, withPad: " ", startingAt: 0))\(v)")
        }
        print("续航仪的十四个状态（合成数据）")
        for (label, w) in cases {
            let f = w.forecast(at: now)
            line(label, "\(f.verdictText)   |   \(f.headingLeft) "
                + (f.headline.map { Forecast.span($0) } ?? "—")
                + "   |   " + (f.paceText ?? "没有速率"))
        }
        for dark in [true, false] {
            let tag = dark ? "dark" : "light"
            for (label, w) in cases {
                shoot(AnyView(EnduranceView(window: w, now: now)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Theme.surface)),
                      width: Theme.panelWidth, dark: dark,
                      to: dir + "/endurance-\(label)-\(tag).png")
            }
        }
    }

    /// Opens the real panel in a real popover on a real status item, and reports its geometry.
    ///
    /// This exists because the panel's height went wrong twice and both times the unit tests
    /// were happy: they measured a hosting view in isolation, which cannot see where AppKit
    /// actually puts the window or whether it fits on the screen. Everything that was wrong is
    /// visible in these four numbers.
    @MainActor static func popoverGeometry() {
        // NSApp is nil until something touches NSApplication.shared, and a status item needs a
        // launched app behind it — without this the probe traps before it prints anything.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Theme.registerFonts()
        let store = Store()
        store.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "▍"
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        var reported: CGFloat = 0
        // Set this to reproduce what shipped in 1.0.3: the panel measures itself but nobody
        // acts on it, and AppKit is left to resize a popover that is already on screen.
        let sizeIt = ProcessInfo.processInfo.environment["PWEBAR_PROBE_NO_RESIZE"] != "1"
        let panel = PanelView(store: store, onTrophy: {}, onSettings: {}, onOpen: { _ in },
                              onEnableQuota: {},
                              // The same screen the app uses, or this check measures one display
                              // while the panel sized itself against another.
                              usableHeight: { item.button?.window?.screen?.visibleFrame.height },
                              onHeight: { h in
            reported = h
            if sizeIt { popover.contentSize = NSSize(width: Theme.panelWidth, height: h) }
        })
        popover.contentViewController = NSHostingController(rootView: panel)

        guard let button = item.button else { print("no status item button"); exit(1) }
        // Let a reading land, so the panel is the size it is in real use rather than empty.
        for _ in 0..<120 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        for _ in 0..<120 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let frame = popover.contentViewController?.view.window?.frame ?? .zero
        let scroller = popover.contentViewController?.view.firstScrollView()

        print("屏幕            \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt   "
              + "可用高度 \(Int(visible.height))   可用区间 y \(Int(visible.minY))…\(Int(visible.maxY))")
        print("面板申请的高度  \(Int(reported)) pt   上限 \(Int(PanelView.ceiling()))")
        print("弹出框窗口      \(Int(frame.width))x\(Int(frame.height)) pt   "
              + "y \(Int(frame.minY))…\(Int(frame.maxY))")
        // The beak and the shadow legitimately overlap the menu bar by a few points; anything
        // past that is the header and the endurance block being pushed off the screen.
        let above = frame.maxY - visible.maxY
        let below = visible.minY - frame.minY
        print("顶部超出屏幕    " + (above > 8
            ? "是，\(Int(above)) pt 在屏幕上方（标题栏和续航仪够不着）"
            : "否\(above > 1 ? "（\(Int(above)) pt 是尖角，正常）" : "")"))
        print("底部超出屏幕    \(below > 1 ? "是，\(Int(below)) pt" : "否")")
        if let scroller {
            let doc = scroller.documentView?.frame.height ?? 0
            let clip = scroller.contentView.bounds.height
            print("滚动            \(doc > clip + 1 ? "有（内容 \(Int(doc)) / 可见 \(Int(clip))）" : "无，全部显示")")
        } else {
            print("滚动            没有 NSScrollView")
        }
        store.stop()
        // Non-zero when the verdict is bad, so this can gate a release the way the handover says
        // it should. It already exits 1 for a missing status item; exiting 0 after printing
        // "顶部超出屏幕 是" made the check un-gateable and easy to skim past.
        exit(above > 8 || below > 8 ? 1 : 0)
    }

    static func stress(into dir: String) {
        var snap = Snapshot()
        snap.windows = [
            // Three hours into a five-hour window with 70 % gone: the pace line overshoots and
            // the projection lands before the reset, which is the case worth drawing.
            QuotaWindow(id: "session", provider: .claude, channel: .session,
                        title: "五小时窗口", percent: 70, severity: .normal,
                        resetsAt: Date().addingTimeInterval(2 * 3600), isActive: true,
                        windowLength: 5 * 3600),
            QuotaWindow(id: "weekly_all", provider: .claude, channel: .week,
                        title: "周窗口", percent: 100, severity: .critical,
                        resetsAt: Date().addingTimeInterval(9 * 86400), confirmedExhausted: true),
            QuotaWindow(id: "seven_day_oauth_apps", provider: .claude, channel: .other,
                        title: "周 oauth apps 超长名字测试", percent: 66.6, severity: .warning,
                        resetsAt: Date().addingTimeInterval(3600)),
            QuotaWindow(id: "codex_5h", provider: .codex, channel: .codex,
                        title: "五小时窗口", percent: 0, severity: .normal),
            QuotaWindow(id: "codex_credits", provider: .codex, channel: .codex,
                        title: "附加额度", percent: nil, severity: .critical,
                        note: "已用尽且说明很长",
                        observedAt: Date().addingTimeInterval(-9 * 86400)),
        ]
        snap.contextPercent = 99.7
        snap.events = [AgentEvent(id: "s", provider: .claude, kind: .finished,
                                  text: String(repeating: "很长的等待说明文字，", count: 12),
                                  at: Date().addingTimeInterval(-45))]
        // Four heterogeneous tuple literals inferred inside one call expression: Swift 6.3's
        // type-checker gives up on it and fails the whole target. It happened to compile on the
        // toolchain this was written against, which is the only reason it shipped that way.
        // Naming each array with its element type takes the inference away entirely.
        let byModel: [(model: String, turns: Int, usd: Double)] = [
            ("claude-opus-5", 1_200_000, 900_000), ("claude-fable-5-1", 34_567, 87_654.32),
        ]
        let byDay: [(day: String, usd: Double)] =
            (0..<30).map { ("2026-08-\($0 + 1)", Double($0) * 137.4) }
        let byHour: [(hour: Date, usd: Double)] = (0..<24).map { (i: Int) -> (Date, Double) in
            let at = Date().addingTimeInterval(Double(i - 23) * 3600)
            return (at, Double((i * 7) % 13) * 12.5)
        }
        let tokens: (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) =
            (999_999_999, 888_888_888, 777_777_777, 6_666_666_666)
        snap.trophy = Trophy(days: 365, turns: 1_234_567, equivalentUSD: 987_654.32,
                             subscriptionUSD: 243.33, byModel: byModel, byDay: byDay,
                             byHour: byHour, tokens: tokens)

        let store = Store()
        store.injectForTesting(snap)
        for dark in [true, false] {
            let tag = dark ? "dark" : "light"
            Prefs.shared.panelMode = .full
            shoot(AnyView(PanelView(store: store, onTrophy: {}, onSettings: {},
                                    onOpen: { _ in }, onEnableQuota: {})),
                  width: Theme.panelWidth, dark: dark, to: dir + "/stress-panel-\(tag).png")
            shoot(AnyView(TrophyView(trophy: snap.trophy)),
                  width: 460, dark: dark, to: dir + "/stress-trophy-\(tag).png")
            // Settings is two clicks deep, which is exactly why it rots — and it is now the
            // one surface every provider has to fit on.
            shoot(AnyView(SettingsView(installHooks: { false }, saveToken: { _ in .failed(-1) },
                                       enableRealQuota: {})),
                  width: 380, dark: dark, to: dir + "/stress-settings-\(tag).png")

            // One snapshot has one protagonist, and the two hero states worth checking are
            // mutually exclusive: a spent window outranks everything, so the pace projection
            // can never be seen in the same frame. Drop the exhausted weekly and draw the
            // other one.
            var racing = snap
            racing.windows = snap.windows.filter { $0.id != "weekly_all" }
            let paced = Store()
            paced.injectForTesting(racing)
            shoot(AnyView(PanelView(store: paced, onTrophy: {}, onSettings: {},
                                    onOpen: { _ in }, onEnableQuota: {})),
                  width: Theme.panelWidth, dark: dark, to: dir + "/stress-pace-\(tag).png")
        }
        for mode in MenuBarMode.allCases {
            let image = StatusIcon.render(snap, mode: mode, dark: true)
            write(image, to: dir + "/stress-icon-\(mode.rawValue)-dark.png")
            print("  stress-icon-\(mode.rawValue)-dark.png  \(Int(image.size.width))×\(Int(image.size.height))")
        }
    }

    static func run() {
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        func mark(_ what: String) {
            FileHandle.standardError.write(
                Data(String(format: "  [%6.2fs] %6.1f MB  %@\n",
                            Date().timeIntervalSince(t0), residentMB(), what).utf8))
        }
        Task { @MainActor in
            mark("start")
            _ = Credentials.claudeCodeCredential()
            mark("credential")
            _ = Transcript.lastRateLimit()
            mark("lastRateLimit")
            let pricing = Pricing.load()
            mark("pricing loaded")
            let claude = ClaudeProvider()
            let (windows, stale) = await claude.windows()
            mark("claude windows: \(windows.count)")
            let loggedIn = await claude.loggedIn

            var snap = Snapshot()
            snap.windows = windows
            snap.windows += await CodexProvider.shared.windows()
            mark("codex done")
            let local = await Transcript.shared.refresh(pricing: pricing)
            mark("transcript done: \(local.trophy.turns) turns")
            snap.trophy = local.trophy
            snap.contextPercent = local.context
            snap.events = await HookEventReader.shared.events()
            snap.stale = stale

            print("PWE AI Bar — probe\n" + String(repeating: "─", count: 58))
            let why: String
            let blocker = await claude.blocker
            switch blocker {
            case .none: why = "—"
            case .needsSetup: why = "未授权（面板点「启用真实额度」，或用 --token 设长期令牌）"
            case .notLoggedIn: why = "未登录（运行 claude auth login）"
            case .keychainRefused: why = "钥匙串拒绝（重新运行 claude auth login 即可重建授权）"
            case .unauthorized, .forbidden, .network, .storage, .invalidResponse,
                 .credentialsChanged, .expired: why = blocker.message
            case .rateLimited(let d): why = "限流至 \(f(d))"
            }
            print("登录        \(loggedIn ? "是" : "否")     数据陈旧  \(stale ? "是" : "否")")
            print("凭据        \(await claude.source.rawValue)     UA  \(ClaudeProvider.userAgent)")
            print("阻塞        \(why)")
            print("hooks       \(HookProvider.isInstalled ? "已安装" : "未安装")     刘海      \(Prefs.hasNotch ? "有" : "无")")
            print("\n窗口")
            if snap.windows.isEmpty { print("  （无）") }
            for w in snap.windows.sorted(by: { $0.strain > $1.strain }) {
                let reset = w.resetsAt.map { f($0) } ?? "—"
                // Pad in Swift, never with %-Ns: that pads by C-string bytes and chops a
                // multi-byte character clean in half — "信用耗尽" came out as mojibake.
                print("  " + pad(w.provider.rawValue, 8) + pad(w.title, 14)
                      + pad(w.percent.map { "已用 \(Int($0))%" } ?? (w.note ?? "—"), 12)
                      + pad(w.severity.rawValue, 10)
                      + "active=\(w.isActive ? "y" : "n")  reset=\(reset)")
            }
            print("\n翼形仪表（内→外）")
            for ch in snap.channels() {
                let bar = String(repeating: "█", count: Int(ch.fill * 20))
                    .padding(toLength: 20, withPad: "░", startingAt: 0)
                print("  \(ch.channel.label.padding(toLength: 4, withPad: " ", startingAt: 0)) \(bar) \(ch.band.word)")
            }
            print("  overall = \(snap.overall.word)")
            if let p = snap.protagonist {
                print("  主角     = \(p.provider.name) \(p.title)（已用 \(p.percent.map { String(Int($0)) } ?? "—")%）")
            }
            print("\n上下文      \(snap.contextPercent.map { String(format: "%.0f%%", $0) } ?? "—")")

            let t = snap.trophy
            print("\n战绩")
            print("  活跃 \(t.days) 天 · 往返 \(t.turns) 次")
            print(String(format: "  等效 $%.2f · 订阅 $%.2f · 回本 %.0f×",
                         t.equivalentUSD, t.subscriptionUSD, t.multiple))
            for m in t.byModel {
                print("    " + pad(m.model, 20) + pad("\(m.turns) 次", 12)
                      + String(format: "$%.2f", m.usd))
            }
            print(String(format: "  token  in %@  out %@  cw %@  cr %@",
                         big(t.tokens.input), big(t.tokens.output),
                         big(t.tokens.cacheWrite), big(t.tokens.cacheRead)))

            print("\n朗读（VoiceOver / tooltip）")
            print("  " + snap.spoken(remaining: Prefs.shared.showRemaining))

            print("\n事件")
            if snap.events.isEmpty { print("  （无）") }
            for e in snap.events.prefix(5) {
                print("  \(e.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(e.text)  · \(f(e.at))")
            }
            sem.signal()
        }
        // The probe is a command-line run: pump the main loop until the async work lands.
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Width in rendered columns, not bytes: CJK is double-width in a terminal and every
    /// character of it is three bytes, so both `count` and byte length line the table up wrong.
    private static func pad(_ s: String, _ width: Int) -> String {
        let cells = s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
        return s + String(repeating: " ", count: max(1, width - cells))
    }

    /// Current resident size. Stage timings alone cannot tell you which stage is the one
    /// holding memory, and guessing at that wasted more than one round here.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static func f(_ d: Date) -> String {
        let fm = DateFormatter(); fm.dateFormat = "MM-dd HH:mm"
        return fm.string(from: d)
    }

    private static func big(_ v: Int) -> String {
        let d = Double(v)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        return String(format: "%.0fK", d / 1e3)
    }
}

extension NSView {
    /// The first `NSScrollView` in this hierarchy — what SwiftUI's `ScrollView` is made of, and
    /// therefore the honest answer to "is this panel scrolling".
    func firstScrollView() -> NSScrollView? {
        if let me = self as? NSScrollView { return me }
        for child in subviews { if let found = child.firstScrollView() { return found } }
        return nil
    }
}
