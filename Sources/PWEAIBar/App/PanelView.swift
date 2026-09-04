import SwiftUI

/// The panel. Three densities, one rule that survives all of them: exactly one number is big,
/// and it is whichever window is closest to stopping you — not a fixed one. When the weekly is
/// at 84 % and the session at 34 %, the weekly is the headline; when it rolls over, the
/// headline changes hands on its own.
///
/// Density is a preference because taste differs, but arrangement is not. Three column
/// baselines, groups separated by rules and nothing separated inside a group, tabular figures
/// so a changing digit never shifts what sits beside it, and colour reserved for state.
struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs = Prefs.shared
    var onTrophy: () -> Void
    var onSettings: () -> Void
    var onOpen: (Provider) -> Void

    private var snap: Snapshot { store.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if prefs.panelMode == .lean {
                stage
            } else {
                gaugeRow
                Divider().overlay(Theme.hairline)
                ForEach(windowsToShow) { w in
                    windowRow(w)
                    Divider().overlay(Theme.hairline)
                }
            }

            if prefs.panelMode == .lean {
                Divider().overlay(Theme.hairline)
                minorRow
            }

            if prefs.panelMode == .full {
                scoreRow
                Divider().overlay(Theme.hairline)
            }

            if let a = snap.attention {
                eventRow(a)
                Divider().overlay(Theme.hairline)
            }

            footer
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.surface)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.s2) {
            WingView(solid: true, tint: Theme.accent)
                .frame(width: 15, height: 15 / BrandMark.aspect)
            Text("PWE AI Bar").font(Theme.serif(15)).foregroundStyle(Theme.text)
            Spacer()
            if snap.stale {
                Circle().fill(Theme.hex(Theme.amber)).frame(width: 5, height: 5)
                    .help("显示的是上一次成功读到的数字")
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    // MARK: Lean — one protagonist

    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); gauge(104); Spacer() }
                .padding(.bottom, Theme.s3)

            if let p = snap.protagonist {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.display).font(Theme.figures(36))
                        .foregroundStyle(Theme.health(p.band, dark: isDark))
                    Spacer()
                    Text(resetText(p) ?? "").font(Theme.sans(11)).foregroundStyle(Theme.text2)
                }
                track(p).padding(.top, 12)
                Text(p.title).font(Theme.sans(11)).foregroundStyle(Theme.text2)
                    .padding(.top, Theme.s2)
            } else {
                Text(store.loggedIn ? "读不到额度" : "未登录 · 运行 claude auth login")
                    .font(Theme.sans(12)).foregroundStyle(Theme.text2)
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 15)
    }

    private var minorRow: some View {
        HStack {
            ForEach(minorChannels, id: \.label) { item in
                HStack(spacing: 5) {
                    Text(item.label).font(Theme.sans(10, 600)).foregroundStyle(Theme.text2)
                    Text(item.value).font(Theme.figures(11, 500)).foregroundStyle(item.colour)
                }
                if item.label != minorChannels.last?.label { Spacer() }
            }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    // MARK: Standard / full — gauge with legend

    private var gaugeRow: some View {
        HStack(spacing: Theme.s3 + 1) {
            gauge(104)
            VStack(spacing: 5) {
                ForEach(legend, id: \.label) { row in
                    HStack(spacing: 7) {
                        Text(row.label).font(Theme.sans(10.5, 600))
                            .foregroundStyle(Theme.text2).frame(width: 30, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline).frame(height: 3)
                                Capsule().fill(row.colour)
                                    .frame(width: g.size.width * row.fraction, height: 3)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 10)
                        Text(row.value).font(Theme.figures(10.5, 500))
                            .foregroundStyle(Theme.text).frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 12)
    }

    private func windowRow(_ w: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(w.title.uppercased()).brandLabel(10).foregroundStyle(Theme.text2)
                Spacer()
                Text(resetText(w) ?? "").font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
            }
            track(w)
            HStack(alignment: .bottom) {
                Text(w.display).font(Theme.figures(17))
                    .foregroundStyle(Theme.health(w.band, dark: isDark))
                Spacer()
                Text(w.severity == .normal ? "" : w.severity.rawValue)
                    .font(Theme.figures(11, 500)).foregroundStyle(Theme.text2)
            }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    private var scoreRow: some View {
        HStack(spacing: Theme.s3 + 1) {
            score("活跃", "\(snap.trophy.days) 天")
            score("等效", money(snap.trophy.equivalentUSD))
            score("回本", snap.trophy.multiple >= 1
                  ? "\(Int(snap.trophy.multiple.rounded()))×" : "—")
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTrophy)
    }

    private func score(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).brandLabel(9.5).foregroundStyle(Theme.text2)
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
                Circle().fill(Theme.hex(isDark ? Theme.amber : Theme.amberDeep))
                    .frame(width: 6, height: 6)
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
        .padding(.horizontal, Theme.s3).padding(.vertical, 11)
    }

    // MARK: Pieces

    private func gauge(_ w: CGFloat) -> some View {
        WingView(channels: snap.channels(), perFeather: true)
            .frame(width: w, height: w / BrandMark.aspect)
    }

    /// A window with no ratio gets no bar. A team credit pool that is simply gone is a state,
    /// not a fraction, and drawing it as a full progress bar beside Claude's 87 % claims a
    /// measurement we do not have. It gets a dashed rule instead — present, clearly not a scale.
    @ViewBuilder
    private func track(_ w: QuotaWindow) -> some View {
        if let pct = w.percent {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sunk)
                    Capsule().fill(Theme.health(w.band, dark: isDark))
                        .frame(width: g.size.width * min(1, pct / 100))
                }
            }
            .frame(height: 6)
        } else {
            Capsule()
                .strokeBorder(Theme.health(w.band, dark: isDark).opacity(0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(height: 6)
        }
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var windowsToShow: [QuotaWindow] {
        let order: [Channel] = [.session, .week, .codex, .other]
        var out = snap.windows.sorted { a, b in
            (order.firstIndex(of: a.channel) ?? 9) < (order.firstIndex(of: b.channel) ?? 9)
        }
        // Standard shows the two that matter; full shows everything we have.
        if prefs.panelMode == .standard { out = Array(out.prefix(2)) }
        return out
    }

    private struct Row { let label: String; let value: String; let fraction: Double; let colour: Color }

    private var legend: [Row] {
        snap.channels().map { ch in
            let w = snap.window(ch.channel)
            let value: String
            if ch.channel == .context {
                value = snap.contextPercent.map { "\(Int($0.rounded()))%" } ?? "—"
            } else {
                value = w?.display ?? "—"
            }
            return Row(label: ch.channel.label, value: value,
                       fraction: min(1, ch.fill),
                       colour: ch.band == .calm ? Theme.text : Theme.health(ch.band, dark: isDark))
        }
        .sorted { $0.fraction > $1.fraction }
    }

    private var minorChannels: [Row] {
        legend.filter { $0.label != (snap.protagonist?.channel.label ?? "") }.prefix(3).map { $0 }
    }

    private func resetText(_ w: QuotaWindow) -> String? {
        guard let at = w.resetsAt else { return nil }
        let s = Int(at.timeIntervalSinceNow)
        guard s > 0 else { return nil }
        if s < 3600 { return "\(s / 60) 分钟后重置" }
        if s < 86400 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "\(f.string(from: at)) 重置"
        }
        return "\(s / 86400) 天后重置"
    }

    private func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 1)) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }

    private func money(_ v: Double) -> String {
        v >= 1000 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }
}
