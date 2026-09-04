import SwiftUI

/// The panel. Three densities, two rules that hold across all of them.
///
/// **One number is big**, and it is whichever window is closest to stopping you — not a fixed
/// one. When the weekly sits at 89 % and the session at 76 %, the weekly is the headline; when
/// it rolls over, the headline changes hands on its own.
///
/// **Nothing is abbreviated.** The menu bar is where space is scarce and a silhouette has to do
/// the work of a word; the panel is where you came to read. A row that says `CDX 15%` makes you
/// decode it first, so it says "Codex · 周窗口" instead, under a heading with that provider's
/// mark beside its full name.
struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.colorScheme) private var colorScheme
    var onTrophy: () -> Void
    var onSettings: () -> Void
    var onOpen: (Provider) -> Void
    var onEnableQuota: () -> Void

    private var snap: Snapshot { store.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            stage
            rule

            // Lean means lean. Showing the same provider sections with two rows instead of
            // three made it 440 points against standard's 469 — a mode that promises less and
            // delivers the same thing is just a mode nobody picks. It gets one line instead.
            if prefs.panelMode == .lean {
                minorRow
                rule
                // The way to turn real quota on cannot live only in the modes that show
                // provider sections, or picking the compact one hides the single button the
                // app needs you to press.
                if let cta = claudeCallToAction {
                    ctaRow(cta)
                    rule
                }
            } else {
                ForEach(activeProviders, id: \.self) { p in
                    providerSection(p)
                    rule
                }
            }

            if prefs.panelMode == .full {
                chartSection
                rule
                scoreRow
                rule
            }

            if let a = snap.attention {
                eventRow(a)
                rule
            }
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.surface)
    }

    private var rule: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.s2) {
            WingView(solid: true, tint: Theme.accent)
                .frame(width: 15, height: 15 / BrandMark.aspect)
            Text("PWE AI Bar").font(Theme.serif(15)).foregroundStyle(Theme.text)
            Spacer()
            // The dot means "these numbers are older than they look". With no numbers at all
            // it means nothing, and the section's own line already says what is wrong.
            if snap.stale, !snap.windows.isEmpty {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    .help("显示的是上一次成功读到的数字")
                    .accessibilityLabel("数据可能已过时")
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    // MARK: The one big number

    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); gauge(124); Spacer() }
                .padding(.bottom, Theme.s2)

            if let p = snap.protagonist {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Text(Readout.text(p, remaining: prefs.showRemaining)).font(Theme.figures(36))
                        .foregroundStyle(Theme.health(p.band, dark: isDark))
                    Spacer()
                    Text(resetText(p) ?? "").font(Theme.sans(11)).foregroundStyle(Theme.text2)
                }
                track(p).padding(.top, 11)
                HStack(spacing: 5) {
                    ProviderMarkView(provider: p.provider, tint: Theme.text2)
                        .frame(width: 10, height: 10)
                    Text("\(p.provider.name) · \(p.title) · \(prefs.showRemaining ? Readout.label.remaining : Readout.label.used)")
                        .font(Theme.sans(11)).foregroundStyle(Theme.text2)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.top, Theme.s2)
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 13)
    }

    /// What to say when there is nothing to show. "读不到额度" is true and useless — each of
    /// these has a different fix, and the panel is the only place the fix can be stated.
    private var emptyState: some View {
        let (headline, fix): (String, String?) = {
            switch store.blocker {
            case .needsSetup:
                return ("还没接上真实额度", "下面显示的是本地估算")
            case .notLoggedIn:
                return ("还没登录", "在终端运行 claude auth login")
            case .keychainRefused:
                // Re-logging in rewrites the keychain item with a fresh access list, which is
                // one command; editing the existing item's ACL by hand is four dialogs deep.
                return ("钥匙串拒绝了访问", "重新运行 claude auth login 即可重建授权")
            case .expired:
                return ("登录已过期", "打开一次 Claude Code 就会自动续期")
            case .rateLimited(let until):
                let m = max(1, Int(until.timeIntervalSinceNow / 60))
                return ("接口限流中", "\(m) 分钟后自动重试")
            case .none:
                return ("暂时读不到额度", nil)
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(headline).font(Theme.sans(13, 600)).foregroundStyle(Theme.text)
            if let fix {
                Text(fix).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.blocker == .needsSetup || store.blocker == .keychainRefused {
                Button("启用真实额度") { onEnableQuota() }
                    .font(Theme.sans(11.5))
                    .help("会弹一次 macOS 钥匙串授权，选「始终允许」后不再询问")
            }
        }
    }

    // MARK: One section per provider

    private func providerSection(_ p: Provider) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2 + 1) {
            Button { onOpen(p) } label: {
                HStack(spacing: 7) {
                    ProviderMarkView(provider: p, tint: Theme.health(bandOf(p), dark: isDark))
                        .frame(width: 13, height: 13)
                    Text(p.name).font(Theme.sans(12, 600)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: Theme.s1)
                    // Claude's numbers come live from an endpoint; Codex's come out of a session
                    // log and are exactly as old as its last run. Saying so is the difference
                    // between a stale number and a lie.
                    if let age = readingAge(p) {
                        Text(age).font(Theme.sans(10)).foregroundStyle(Theme.text2)
                    }
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8)).foregroundStyle(Theme.text2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(rows(for: p)) { w in
                windowRow(w)
            }

            // The call to action has to live here, not only in the empty state. As soon as any
            // other provider reports a number the panel is no longer empty, and the one thing
            // the user needs to press disappears with it.
            if p == .claude, let cta = claudeCallToAction {
                ctaRow(cta).padding(.top, 2)
            }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    private func ctaRow(_ cta: (text: String, button: String?)) -> some View {
        HStack(spacing: Theme.s2) {
            Text(cta.text).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true).lineLimit(2)
            Spacer(minLength: Theme.s1)
            if let title = cta.button {
                Button(title) { onEnableQuota() }
                    .font(Theme.sans(11))
                    .help("会弹一次 macOS 钥匙串授权，选「始终允许」后不再询问")
            }
        }
    }

    /// Everything that is not the headline, on one line, each with its provider's silhouette
    /// so a glance still says whose number it is.
    private var minorRow: some View {
        let others = snap.windows
            .filter { $0.id != snap.protagonist?.id }
            .sorted { $0.strain > $1.strain }
            .prefix(3)
        return HStack(spacing: Theme.s3) {
            ForEach(Array(others.enumerated()), id: \.offset) { _, w in
                HStack(spacing: 4) {
                    ProviderMarkView(provider: w.provider, tint: Theme.text2)
                        .frame(width: 10, height: 10)
                    Text(Readout.text(w, remaining: prefs.showRemaining))
                        .font(Theme.figures(11.5, 500))
                        .foregroundStyle(Theme.health(w.band, dark: isDark))
                }
            }
            if let c = snap.contextPercent {
                HStack(spacing: 4) {
                    Text("上下文").font(Theme.sans(10)).foregroundStyle(Theme.text2)
                    Text("\(Int((prefs.showRemaining ? 100 - c : c).rounded()))%")
                        .font(Theme.figures(11.5, 500)).foregroundStyle(Theme.text)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    /// Nil once real quota is flowing.
    private var claudeCallToAction: (text: String, button: String?)? {
        guard snap.windows(of: .claude).isEmpty else { return nil }
        switch store.blocker {
        case .needsSetup:      return ("只有本地估算，还没接上真实额度", "启用")
        case .keychainRefused: return ("钥匙串授权被拒过", "重新授权")
        case .notLoggedIn:     return ("先在终端运行 claude auth login", nil)
        case .expired:         return ("登录已过期，打开一次 Claude Code 即可", nil)
        case .rateLimited(let until):
            return ("接口限流中，\(max(1, Int(until.timeIntervalSinceNow / 60))) 分钟后重试", nil)
        case .none:            return nil
        }
    }

    /// Label, bar, figure, reset — four columns that keep their x positions down the whole
    /// panel, so the eye runs straight down instead of re-finding them on every line.
    private func windowRow(_ w: QuotaWindow) -> some View {
        HStack(spacing: Theme.s2) {
            // Fixed columns keep the four baselines aligned down the whole panel; truncation
            // is what stops an unexpectedly long name from pushing the number off the edge.
            Text(w.title).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 66, alignment: .leading)
            track(w).frame(maxWidth: .infinity)
            Text(Readout.text(w, remaining: prefs.showRemaining)).font(Theme.figures(11.5, 600))
                .foregroundStyle(Theme.health(w.band, dark: isDark))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .trailing)
            Text(shortReset(w) ?? "").font(Theme.sans(10))
                .foregroundStyle(Theme.text2)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Text("最近 24 小时").font(Theme.sans(11, 600)).foregroundStyle(Theme.text2)
                Spacer()
                Text(money(snap.trophy.byHour.reduce(0) { $0 + $1.usd }) + " 等效")
                    .font(Theme.figures(11, 500)).foregroundStyle(Theme.text)
            }
            UsageChart(hours: snap.trophy.byHour)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    private var scoreRow: some View {
        Button(action: onTrophy) {
            HStack(spacing: Theme.s3) {
                score("活跃", "\(snap.trophy.days) 天")
                score("等效", money(snap.trophy.equivalentUSD))
                score("回本", snap.trophy.multiple >= 1
                      ? "\(Int(snap.trophy.multiple.rounded()))×" : "—")
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func score(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(Theme.sans(9.5, 600)).tracking(1.7).foregroundStyle(Theme.text2)
            Text(v).font(Theme.figures(16)).foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ e: AgentEvent) -> some View {
        Button {
            store.clearAttention()
            onOpen(e.provider)
        } label: {
            HStack(spacing: Theme.s2) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text(e.text).font(Theme.sans(12)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: Theme.s1)
                Text(ago(e.at)).font(Theme.sans(11)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button(action: onTrophy) {
                Text("\(snap.trophy.days) 天 · \(money(snap.trophy.equivalentUSD)) 等效 ›")
                    .font(Theme.sans(10)).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(ago(snap.updatedAt) + "更新").font(Theme.sans(10)).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 10)
    }

    // MARK: Pieces

    private func gauge(_ w: CGFloat) -> some View {
        WingView(channels: snap.channels(), perFeather: true,
                 spoken: snap.spoken(remaining: prefs.showRemaining))
            .frame(width: w, height: w / BrandMark.aspect)
    }

    /// A window with no ratio gets no bar. A credit pool that is simply gone is a state, not a
    /// fraction, and drawing it full-width beside Claude's 89 % claims a measurement we do not
    /// have. It gets a dashed rule: present, clearly not a scale.
    @ViewBuilder
    private func track(_ w: QuotaWindow) -> some View {
        if let fraction = Readout.fill(w, remaining: prefs.showRemaining) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sunk)
                    // A genuine zero draws nothing. A minimum width keeps small values visible,
                    // but painting a sliver on an empty window reads as "a little bit" when the
                    // truth is "none".
                    if fraction > 0 {
                        Capsule().fill(Theme.health(w.band, dark: isDark))
                            .frame(width: max(3, g.size.width * fraction))
                    }
                }
            }
            .frame(height: 6)
        } else {
            Capsule()
                .strokeBorder(Theme.health(w.band, dark: isDark).opacity(0.5),
                              style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(height: 6)
        }
    }

    /// The appearance of *this view*, not of the application.
    ///
    /// Reading `NSApp.effectiveAppearance` here painted near-white figures onto a white panel:
    /// the app object and the view can disagree, and only the view knows what ground its text
    /// is actually landing on. Same class of mistake as reading the app's appearance to decide
    /// the menu-bar glyph's colour — twice now, so it is worth naming.
    private var isDark: Bool { colorScheme == .dark }

    /// Claude always gets a section, even with nothing to report — that section is where the
    /// "turn this on" row lives, and hiding it would hide the only way forward.
    private var activeProviders: [Provider] {
        Provider.allCases.filter {
            !rows(for: $0).isEmpty || ($0 == .claude && claudeCallToAction != nil)
        }
    }

    private func bandOf(_ p: Provider) -> Health {
        rows(for: p).map(\.band).max() ?? .calm
    }

    /// Only shown once a reading is old enough to matter. A live endpoint never gets a label;
    /// a log-derived one gets one as soon as it stops being "just now".
    private func readingAge(_ p: Provider) -> String? {
        guard let oldest = snap.windows(of: p).map(\.observedAt).min() else { return nil }
        let s = Int(Date().timeIntervalSince(oldest))
        guard s > 300 else { return nil }
        if s < 3600 { return "\(s / 60) 分钟前读到" }
        if s < 86400 { return "\(s / 3600) 小时前读到" }
        return "\(s / 86400) 天前读到"
    }

    /// Claude's context is one of its readings, not a channel of its own — it belongs under the
    /// heading with the rest of what Claude reports.
    private func rows(for p: Provider) -> [QuotaWindow] {
        var out = snap.windows(of: p).sorted { ($0.percent ?? -1) > ($1.percent ?? -1) }
        if p == .claude, let c = snap.contextPercent {
            out.append(QuotaWindow(id: "context", provider: .claude, channel: .context,
                                   title: "上下文", percent: c,
                                   severity: Severity(word: Health.grade(
                                       c, warm: Channel.context.warm,
                                       hot: Channel.context.hot) == .calm ? "normal" : "warning")))
        }
        if prefs.panelMode == .lean { out = Array(out.prefix(2)) }
        return out
    }

    private func resetText(_ w: QuotaWindow) -> String? {
        guard let at = w.resetsAt else { return nil }
        let s = Int(at.timeIntervalSinceNow)
        guard s > 0 else { return nil }
        // Integer division turned the last minute before a reset into "0 分钟后重置", which
        // reads as broken rather than imminent.
        if s < 60 { return "不到 1 分钟" }
        if s < 3600 { return "\(s / 60) 分钟后重置" }
        if s < 86400 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "\(f.string(from: at)) 重置"
        }
        return "\(s / 86400) 天后重置"
    }

    private func shortReset(_ w: QuotaWindow) -> String? {
        guard let at = w.resetsAt else { return nil }
        let s = Int(at.timeIntervalSinceNow)
        guard s > 0 else { return nil }
        if s < 60 { return "<1 分" }
        if s < 3600 { return "\(s / 60) 分" }
        if s < 86400 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: at)
        }
        return "\(s / 86400) 天"
    }

    private func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 1)) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }

    /// Grouped, like the trophy page. Six figures with no separator — "$987654" — is a string
    /// of digits, not a number you can read at a glance.
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private func money(_ v: Double) -> String {
        if v >= 1000 {
            return "$" + (Self.grouped.string(from: NSNumber(value: v)) ?? String(Int(v)))
        }
        return String(format: "$%.2f", v)
    }
}
