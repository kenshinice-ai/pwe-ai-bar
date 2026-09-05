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

    /// `--cred` — where the token would come from, and whether asking costs a dialog.
    /// Deliberately does not read the shared item, so running it can never raise a prompt.
    static func credentials() {
        let own = Credentials.hasOwnToken
        let shared = Credentials.sharedItemExists()
        let refused = UserDefaults.standard.bool(forKey: "keychainRefused")
        let optedIn = UserDefaults.standard.bool(forKey: "sharedKeychainOptIn")

        print("PWE AI Bar — 凭据\n" + String(repeating: "─", count: 52))
        print("自有长期令牌   \(own ? "有" : "无")")
        print("Claude 钥匙串  \(shared ? "存在" : "不存在（没登录过）")")
        print("已授权读取     \(optedIn ? "是" : "否——不会主动去读")")
        print("曾被拒绝       \(refused ? "是" : "否")")
        print("")

        if own {
            print("当前来源：自有长期令牌。永远不会弹框。")
        } else if !shared {
            print("当前来源：本地估算。先运行 claude auth login。")
        } else if !optedIn {
            print("当前来源：本地估算——有总量和战绩，没有百分比。")
            print("这是默认状态，且不会有任何弹框。想要真实额度，二选一：")
            print("  零弹框   claude setup-token | \"…/PWEAIBar\" --token -")
            print("  一次弹框 面板点「启用」，在框里选「始终允许」")
        } else if refused {
            print("当前来源：本地估算。授权被拒过，不会再自动询问。")
            print("设置 → 额度数据来源 → 授权钥匙串，可以重来。")
        } else {
            print("当前来源：Claude Code 的钥匙串。已授权，读取时不再弹框。")
        }
    }

    /// `--stress DIR` renders the panel against data designed to break it: every bucket the
    /// endpoint might one day populate, names longer than their column, a hundred-per-cent
    /// window, a state with no ratio, and a trophy in the millions.
    ///
    /// Real data is always tidy — two windows, short names, sane numbers — so layout that only
    /// ever meets real data has never actually been tested.
    static func stress(into dir: String) {
        var snap = Snapshot()
        snap.windows = [
            QuotaWindow(id: "session", provider: .claude, channel: .session,
                        title: "五小时窗口", percent: 3, severity: .normal,
                        resetsAt: Date().addingTimeInterval(59), isActive: true),
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
        snap.trophy = Trophy(
            days: 365, turns: 1_234_567, equivalentUSD: 987_654.32, subscriptionUSD: 243.33,
            byModel: [("claude-opus-5", 1_200_000, 900_000), ("claude-fable-5-1", 34_567, 87_654.32)],
            byDay: (0..<30).map { ("2026-08-\($0 + 1)", Double($0) * 137.4) },
            byHour: (0..<24).map { (Date().addingTimeInterval(Double($0 - 23) * 3600),
                                    Double(($0 * 7) % 13) * 12.5) },
            tokens: (999_999_999, 888_888_888, 777_777_777, 6_666_666_666))

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
            case .unauthorized, .forbidden, .network: why = blocker.message
            case .expired: why = "登录过期（打开一次 Claude Code）"
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
