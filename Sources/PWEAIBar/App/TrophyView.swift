import SwiftUI

/// The trophy page — and the only place in the app where anything moves.
///
/// On a subscription the interesting figure is not what you spent; you spent the subscription.
/// It is what the same tokens would have cost at list price. That number climbs into view once,
/// when you open the page, and then stops. Achievement wants to be seen, not to follow you
/// around the menu bar all day.
struct TrophyView: View {
    let trophy: Trophy
    @State private var progress: Double = 0

    private var t: Trophy { trophy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: Theme.s4) {
                    byModel
                    byDay
                    tokens
                    Text("口径：按 API 目录价折算，缓存写取输入价 1.25×、缓存读 0.1×。"
                         + "价目表是 pricing.json，改价改文件即可。")
                        .font(Theme.sans(11)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.s4)
            }
        }
        .frame(width: 460)
        .background(Theme.canvas)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { progress = 1 }
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("\(t.days) 天等效 API 成本".uppercased()).brandLabel()
                    .foregroundStyle(Theme.hex(Theme.textDark2))
                Text(money(t.equivalentUSD * progress))
                    .font(Theme.figures(44)).foregroundStyle(Theme.hex(Theme.amber))
            }
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("订阅同期摊销".uppercased()).brandLabel()
                    .foregroundStyle(Theme.hex(Theme.textDark2))
                Text(money(t.subscriptionUSD)).font(Theme.figures(20))
                    .foregroundStyle(Theme.hex(Theme.textDark))
            }
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("回本".uppercased()).brandLabel().foregroundStyle(Theme.hex(Theme.textDark2))
                Text(t.multiple >= 1 ? "\(Int((t.multiple * progress).rounded()))×" : "—")
                    .font(Theme.figures(20)).foregroundStyle(Theme.hex(Theme.amber))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hex(Theme.navy))
    }

    private var byModel: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("按模型".uppercased()).brandLabel().foregroundStyle(Theme.text2)
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(Array(t.byModel.enumerated()), id: \.offset) { i, m in
                        Rectangle().fill(modelColour(i))
                            .frame(width: g.size.width * share(m.usd) * progress)
                    }
                }
            }
            .frame(height: 10).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(t.byModel.enumerated()), id: \.offset) { i, m in
                    HStack(spacing: Theme.s1 + 1) {
                        RoundedRectangle(cornerRadius: 2).fill(modelColour(i))
                            .frame(width: 9, height: 9)
                        Text(short(m.model)).font(Theme.sans(12)).foregroundStyle(Theme.text)
                        Text("\(m.turns) 次").font(Theme.figures(11, 400))
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        Text(money(m.usd)).font(Theme.figures(12, 500)).foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }

    private var byDay: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("按天".uppercased()).brandLabel().foregroundStyle(Theme.text2)
            let peak = max(t.byDay.map(\.usd).max() ?? 1, 0.01)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(t.byDay.enumerated()), id: \.offset) { _, d in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.85))
                        .frame(height: max(2, 48 * d.usd / peak * progress))
                }
            }
            .frame(height: 48)
            if let first = t.byDay.first?.day, let last = t.byDay.last?.day {
                Text("\(first) 至 \(last) · \(t.byDay.count) 个活跃日")
                    .font(Theme.sans(11)).foregroundStyle(Theme.text2)
            }
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Token".uppercased()).brandLabel().foregroundStyle(Theme.text2)
            grid("输入", t.tokens.input)
            grid("输出", t.tokens.output)
            grid("缓存写", t.tokens.cacheWrite)
            grid("缓存读", t.tokens.cacheRead)
            Divider().overlay(Theme.hairline)
            grid("往返", t.turns, raw: true)
        }
    }

    private func grid(_ k: String, _ v: Int, raw: Bool = false) -> some View {
        HStack {
            Text(k).font(Theme.sans(12)).foregroundStyle(Theme.text2)
            Spacer()
            Text(raw ? "\(v)" : big(v)).font(Theme.figures(12, 500)).foregroundStyle(Theme.text)
        }
    }

    private func share(_ usd: Double) -> Double {
        let total = t.byModel.reduce(0) { $0 + $1.usd }
        return total > 0 ? usd / total : 0
    }

    /// Navy for the workhorse, amber for everything after it — the brand's own two-colour split,
    /// which is also the only pair guaranteed to read on this ground.
    private func modelColour(_ i: Int) -> Color {
        i == 0 ? Theme.dyn(light: Theme.navy, dark: 0x8FA9D6) : Theme.accent
    }

    private func short(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
         .replacingOccurrences(of: "-", with: " ")
    }

    private func money(_ v: Double) -> String {
        v >= 1000 ? String(format: "$%,.0f", v).replacingOccurrences(of: ",", with: ",")
                  : String(format: "$%.2f", v)
    }

    private func big(_ v: Int) -> String {
        let d = Double(v)
        if d >= 1e9 { return String(format: "%.2f B", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1f M", d / 1e6) }
        if d >= 1e3 { return String(format: "%.0f K", d / 1e3) }
        return "\(v)"
    }
}
