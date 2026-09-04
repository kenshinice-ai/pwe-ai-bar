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
            let sheet = NSImage(size: NSSize(width: 220, height: 80))
            sheet.lockFocus()
            NSColor(Theme.hex(dark ? Theme.navy : Theme.paper)).setFill()
            NSRect(x: 0, y: 0, width: 220, height: 80).fill()
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

        for dark in [true, false] {
            for mode in PanelMode.allCases {
                Prefs.shared.panelMode = mode
                let view = PanelView(store: store, onTrophy: {}, onSettings: {}, onOpen: { _ in })
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

    static func run() {
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        func mark(_ what: String) {
            FileHandle.standardError.write(
                Data(String(format: "  [%6.2fs] %@\n", Date().timeIntervalSince(t0), what).utf8))
        }
        Task { @MainActor in
            mark("start")
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
            snap.events = HookProvider.events()
            snap.stale = stale

            print("PWE AI Bar — probe\n" + String(repeating: "─", count: 58))
            print("登录        \(loggedIn ? "是" : "否")     数据陈旧  \(stale ? "是" : "否")")
            print("hooks       \(HookProvider.isInstalled ? "已安装" : "未安装")     刘海      \(Prefs.hasNotch ? "有" : "无")")
            print("\n窗口")
            if snap.windows.isEmpty { print("  （无）") }
            for w in snap.windows.sorted(by: { $0.strain > $1.strain }) {
                let reset = w.resetsAt.map { f($0) } ?? "—"
                // Pad in Swift, never with %-Ns: that pads by C-string bytes and chops a
                // multi-byte character clean in half — "信用耗尽" came out as mojibake.
                print("  " + pad(w.provider.rawValue, 8) + pad(w.channel.label, 5)
                      + pad(w.display, 8) + pad(w.severity.rawValue, 10)
                      + "active=\(w.isActive ? "y" : "n")  reset=\(reset)")
            }
            print("\n翼形仪表（内→外）")
            for ch in snap.channels() {
                let bar = String(repeating: "█", count: Int(ch.fill * 20))
                    .padding(toLength: 20, withPad: "░", startingAt: 0)
                print("  \(ch.channel.label.padding(toLength: 4, withPad: " ", startingAt: 0)) \(bar) \(ch.band.word)")
            }
            print("  overall = \(snap.overall.word)")
            if let p = snap.protagonist { print("  主角     = \(p.title) \(p.display)") }
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
