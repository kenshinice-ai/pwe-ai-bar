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

            if let a = snap.attention {
                waitingStage(a)
            } else if let p = focused {
                // Two halves, in the order they are asked: where you are, then where you are
                // heading. The reset time used to sit beside the figure; the instrument's own
                // axis now says it, and saying it twice on one screen made the panel look like
                // it was arguing with itself.
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Text(Readout.text(p, remaining: prefs.showRemaining)).font(Theme.figures(36))
                        .foregroundStyle(Theme.health(p.band, dark: isDark))
                    Spacer()
                    if p.resetsAt == nil, let note = resetText(p) {
                        Text(note).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                    }
                }
                track(p).padding(.top, 11)
                HStack(spacing: 5) {
                    ProviderMarkView(provider: p.provider,
                                     tint: p.confirmedExhausted ? Theme.health(.hot, dark: isDark) : Theme.text2)
                        .frame(width: 10, height: 10)
                    // Spent is a state, not a reading: "剩余" under a zero is the wrong caption,
                    // and how long you are stopped for is the only thing left worth saying.
                    Text(p.confirmedExhausted
                         ? "\(p.provider.name) · \(p.title) · \(waitText(p))"
                         : "\(p.provider.name) · \(p.title) · \(prefs.showRemaining ? Readout.label.remaining : Readout.label.used)")
                        .font(Theme.sans(11))
                        .foregroundStyle(p.confirmedExhausted ? Theme.text : Theme.text2)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.top, Theme.s2)
                EnduranceView(window: p, now: Date()).padding(.top, 13)
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 13)
    }

    /// Someone is waiting on you: that outranks every measurement, so it takes the big slot
    /// instead of sitting in a row under the charts. A percentage tells you how much room is
    /// left; this tells you the room is not the problem right now.
    private func waitingStage(_ e: AgentEvent) -> some View {
        Button { onOpen(e.provider) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Text(snap.waiting > 1 ? "\(snap.waiting) 个会话在等你" : "在等你回话")
                        .font(Theme.figures(26)).foregroundStyle(Theme.accent)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: Theme.s1)
                    Text(ago(e.at)).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                }
                HStack(spacing: 5) {
                    ProviderMarkView(provider: e.provider, tint: Theme.text2)
                        .frame(width: 10, height: 10)
                    Text(e.text).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Theme.s1)
                    Text("去看看 ›").font(Theme.sans(11)).foregroundStyle(Theme.accent)
                }
                .padding(.top, Theme.s2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snap.waiting > 1 ? "\(snap.waiting) 个会话在等你回话" : "\(e.provider.name) 在等你回话")
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 3600 { return "\(max(1, s / 60)) 分钟" }
        let hours = s / 3600, minutes = (s % 3600) / 60
        if s < 86400 { return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分" }
        return "\(s / 86400) 天"
    }

    /// What to say when there is nothing to show. "读不到额度" is true and useless — each of
    /// these has a different fix, and the panel is the only place the fix can be stated.
    private var emptyState: some View {
        let (headline, fix): (String, String?) = {
            switch store.blocker {
            case .needsSetup:
                return ("读不到 Claude Code 的凭据", "下面是本地估算；可在设置里改用钥匙串授权")
            case .notLoggedIn:
                return ("还没登录", "在终端运行 claude auth login")
            case .keychainRefused:
                // Re-logging in rewrites the keychain item through `security`, which is the one
                // program allowed to read it back; editing an ACL by hand is four dialogs deep.
                return ("钥匙串拒绝了访问", "重新运行 claude auth login 即可重建授权")
            case .unauthorized, .forbidden, .network:
                return ("额度连接需要处理", store.blocker.message)
            case .expired:
                // The old wording said opening Claude Code would renew it. Measured on this
                // machine: the credential sat expired for seven and a half hours while Claude
                // Code ran the whole time — the CLI does not rewrite that item on every refresh,
                // so the advice sent people to do something that would not have worked.
                return ("Claude 凭据已过期", "本 app 不替你续期。终端跑 claude setup-token，把结果贴进设置")
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
            if store.blocker == .unauthorized || store.blocker == .forbidden || store.blocker == .expired {
                Button("管理凭据", action: onSettings).font(Theme.sans(11.5))
            }
            if store.blocker == .needsSetup || store.blocker == .keychainRefused {
                Button("改用钥匙串授权") { onEnableQuota() }
                    .font(Theme.sans(11.5))
                    .help("正常情况下用不到。会弹一次 macOS 授权框，选「始终允许」后不再询问")
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
                    // The provider's own word for the plan, printed as given. "team" is what the
                    // account is called; deciding it should read "团队版" is inventing product.
                    if let plan = snap.plans[p], !plan.isEmpty {
                        Text(plan.uppercased()).font(Theme.sans(9, 600))
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.hairline))
                            .lineLimit(1)
                    }
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
            // A provider that failed keeps its heading and says why. Dropping the section
            // instead is indistinguishable from never having turned it on, and the one thing
            // someone needs at that moment is which of those two it is.
            if rows(for: p).isEmpty, let why = snap.connections[p] {
                Text(why).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button(title) {
                    if title == "管理凭据" { onSettings() } else { onEnableQuota() }
                }
                    .font(Theme.sans(11))
                    .help(title == "管理凭据" ? "打开设置以更换或清除令牌" : "会弹一次 macOS 钥匙串授权，选「始终允许」后不再询问")
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
        switch store.blocker {
        case .unauthorized, .forbidden, .expired: return (store.blocker.message, "管理凭据")
        case .network: return (store.blocker.message, nil)
        default: break
        }
        guard snap.windows(of: .claude).isEmpty else { return nil }
        switch store.blocker {
        case .needsSetup:      return ("只有本地估算，读不到 Claude Code 凭据", "处理")
        case .keychainRefused: return ("钥匙串授权被拒过", "重新授权")
        case .notLoggedIn:     return ("先在终端运行 claude auth login", nil)
        case .expired, .unauthorized, .forbidden, .network: return (store.blocker.message, "管理凭据")
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

    /// The reading the hero is showing: whichever window is closest to stopping you.
    ///
    /// This used to also honour a feather picked on the wing gauge. That gauge is gone from the
    /// hero — 124pt that could not be asked anything, and the per-feather hover that was meant
    /// to fix it turned out fiddly to operate. The mark stays in the header as identity, where
    /// it is a signature rather than an instrument.
    private var focused: QuotaWindow? { snap.protagonist }

    private var contextWindow: QuotaWindow? {
        guard let c = snap.contextPercent else { return nil }
        return QuotaWindow(id: "context", provider: .claude, channel: .context, title: "上下文",
                           percent: c,
                           severity: Severity(word: Health.grade(
                               c, warm: Channel.context.warm,
                               hot: Channel.context.hot) == .calm ? "normal" : "warning"))
    }

    /// A window with no ratio gets no bar. A credit pool that is simply gone is a state, not a
    /// fraction, and drawing it full-width beside Claude's 89 % claims a measurement we do not
    /// have. It gets a dashed rule: present, clearly not a scale.
    private func track(_ w: QuotaWindow) -> AnyView {
        guard let fraction = Readout.fill(w, remaining: prefs.showRemaining) else {
            // No ratio to draw: a dashed outline says "there is a window here and we cannot
            // measure it", which a flat empty bar would read as zero.
            return AnyView(Capsule()
                .strokeBorder(Theme.health(w.band, dark: isDark).opacity(0.5),
                              style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(height: 6))
        }
        // The pace projection is deliberately not drawn in here, and that was a change of mind
        // worth recording. A mark at the projected position pins to the very end of the track in
        // the one case that matters — a rate that eats everything left — where it reads as the
        // end cap. Shading the doomed stretch instead turns the fill into a ghost, so a window
        // with 30 % genuinely left looks empty. The bar has one job: where you are now. Where
        // you are heading is a sentence, and `paceLine` says it more precisely than any tick.
        return AnyView(GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sunk)
                // A genuine zero draws nothing. A minimum width keeps small values visible, but
                // painting a sliver on an empty window reads as "a little bit" when the truth
                // is "none".
                if fraction > 0 {
                    Capsule().fill(Theme.health(w.band, dark: isDark))
                        .frame(width: max(3, g.size.width * fraction))
                }
            }
        }
        .frame(height: 6))
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
            !rows(for: $0).isEmpty || snap.connections[$0] != nil
                || ($0 == .claude && claudeCallToAction != nil)
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
        if p == .claude, let context = contextWindow { out.append(context) }
        if prefs.panelMode == .lean { out = Array(out.prefix(2)) }
        return out
    }

    /// How long you are stopped for, said as a duration rather than a clock time. "23:10 重置"
    /// makes you do the arithmetic; "还有 1 小时 26 分" is the answer you were going to work out.
    private func waitText(_ w: QuotaWindow) -> String {
        guard let at = w.resetsAt else { return "等待重置" }
        let s = Int(at.timeIntervalSinceNow)
        guard s > 0 else { return "应该已经重置" }
        if s < 60 { return "不到 1 分钟就恢复" }
        if s < 3600 { return "还有 \(s / 60) 分钟" }
        let hours = s / 3600, minutes = (s % 3600) / 60
        if s < 86400 { return minutes == 0 ? "还有 \(hours) 小时" : "还有 \(hours) 小时 \(minutes) 分" }
        return "还有 \(s / 86400) 天"
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
