import SwiftUI

/// The trophy page — and the only place in the app where anything moves.
///
/// On a subscription the interesting figure is not what you spent; you spent the subscription.
/// It is what the same tokens would have cost at list price. That number climbs into view once,
/// when you open the page, and then stops. Achievement wants to be seen, not to follow you
/// around the menu bar all day.
struct TrophyView: View {
    let trophy: Trophy
    @ObservedObject var prefs = Prefs.shared
    /// Changing the range changes what has to be re-aggregated, which only the store can do.
    var onRangeChange: (TrophyRange) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Entrance flourish only — nothing sized or valued depends on it.
    ///
    /// Two versions of this got it wrong before settling here. The first counted the money up
    /// from zero: any moment the animation had not finished, the page read "$0.00 · 0×" as if
    /// you had never used the thing. Moving the animation to the bar heights only relocated the
    /// bug — a chart flattened to a hairline lies about the data exactly as loudly, just more
    /// quietly. And both failed the same way for the same reason: `onAppear` never fires for a
    /// view that is not in a window, and animations do not run without a display to drive them.
    ///
    /// So geometry and figures are always true, and the only thing that moves is a scale nobody
    /// can misread. Worst case, the page opens at 97 % size and stays there.
    @State private var appeared = false

    private var t: Trophy { trophy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: Theme.s4) {
                    byModel
                    byDay
                    tokens
                }
                .padding(Theme.s4)
            }
        }
        .frame(width: 460)
        .background(Theme.canvas)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared || reduceMotion ? 1 : 0.9)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
        }
    }

    /// The hero, and the only thing on this page that is trying to land a punch.
    ///
    /// It used to be three columns of the same weight: the equivalent cost at 44 pt, then the
    /// subscription and the multiple at 20 pt beside it. That reads as a table, and a table is
    /// exactly what this is not — **the story is the ratio**, and a ratio told as two separate
    /// figures makes the reader do the comparison themselves. So the two amounts are drawn once,
    /// as one bar at one scale, where the subscription is a sliver you have to look for. That
    /// picture is the argument; the numbers only label it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: L("trophy.rangeDays", "%@ · %d active days"), t.range.label, t.days).uppercased()).brandLabel()
                    .foregroundStyle(Theme.hex(Theme.textDark2))
                Spacer(minLength: Theme.s2)
                rangePicker
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L("trophy.equivalentCost", "Equivalent API cost").uppercased()).brandLabel()
                    .foregroundStyle(Theme.hex(Theme.textDark2))
                Text(money(t.equivalentUSD))
                    .font(Theme.figures(46)).foregroundStyle(Theme.hex(Theme.amber))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }

            comparison

            if let sub = t.subscriptionMonthly {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("score.multiple", "Return").uppercased()).brandLabel()
                            .foregroundStyle(Theme.hex(Theme.textDark2))
                        Text(t.multiple >= 1 ? "\(Int(t.multiple.rounded()))×" : L("trophy.underOne", "under 1×"))
                            .font(Theme.figures(30)).foregroundStyle(Theme.hex(Theme.amber))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: L("trophy.planPerMonth", "%@ · %@/mo"), sub.display,
                                    amount(sub.monthly, sub.currency)))
                            .font(Theme.sans(12, 500)).foregroundStyle(Theme.hex(Theme.textDark))
                        Text(String(format: L("trophy.sameSpan", "%@ over the same span"),
                                    amount(sub.monthly * Double(max(t.days, 1)) / 30, sub.currency)))
                            .font(Theme.figures(12)).foregroundStyle(Theme.hex(Theme.textDark2))
                    }
                }
            } else {
                // No invented price, and therefore no multiple. A ratio reads exactly as
                // confidently whether or not anyone checked the number under it.
                Text(L("trophy.needPrice", "Set your subscription price in settings to see the return"))
                    .font(Theme.sans(12)).foregroundStyle(Theme.hex(Theme.textDark2))
            }
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hex(Theme.navy))
    }

    /// Both amounts on one scale. The subscription bar is deliberately allowed to be a hairline.
    private var comparison: some View {
        let sub = t.subscriptionMonthly.map { _ in t.subscriptionUSD } ?? 0
        let top = max(t.equivalentUSD, sub, 0.01)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Theme.hex(Theme.amber))
                        .frame(width: g.size.width * t.equivalentUSD / top, height: 12)
                    Capsule().fill(Theme.hex(Theme.textDark).opacity(0.55))
                        // A floor of one point: at this ratio the honest width rounds to nothing,
                        // and a bar that is not drawn at all reads as missing data rather than as
                        // the smallness that is the entire point.
                        .frame(width: max(1, g.size.width * sub / top), height: 12)
                }
            }
            .frame(height: 29)
            if t.subscriptionMonthly != nil {
                Text(L("trophy.barLegend",
                       "Above: equivalent API cost.  Below: the subscription over the same span, same scale"))
                    .font(Theme.sans(10.5)).foregroundStyle(Theme.hex(Theme.textDark2))
            }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(TrophyRange.allCases, id: \.self) { r in
                let on = prefs.trophyRange == r
                Text(r.label)
                    .font(Theme.sans(10.5, on ? 600 : 400))
                    .foregroundStyle(Theme.hex(on ? Theme.navy : Theme.textDark2))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(on ? Theme.hex(Theme.amber) : .clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { prefs.trophyRange = r; onRangeChange(r) }
            }
        }
    }

    /// Amounts in the reader's own currency. `A$` rather than `$` because on this page a bare
    /// dollar sign already means USD — the equivalent cost is a USD list price.
    private func amount(_ v: Double, _ currency: String) -> String {
        let prefix = currency == "AUD" ? "A" : ""
        // No cents on a round figure. "A$150.00/月" reads like a computed result; the price is
        // just a price, and the two decimals are the only noise in the hero.
        if v >= 1, v.rounded() == v {
            return prefix + "$" + (Self.grouped.string(from: NSNumber(value: Int(v))) ?? String(Int(v)))
        }
        return prefix + money(v)
    }

    private var byModel: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(L("trophy.byModel", "By model").uppercased()).brandLabel().foregroundStyle(Theme.text2)
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(Array(t.byModel.enumerated()), id: \.offset) { i, m in
                        Rectangle().fill(modelColour(i))
                            .frame(width: g.size.width * share(m.usd))
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
                            .lineLimit(1).truncationMode(.middle)
                        Text(String(format: L("trophy.turns", "%d turns"), m.turns)).font(Theme.figures(11, 400))
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
            Text(L("trophy.byDay", "By day").uppercased()).brandLabel().foregroundStyle(Theme.text2)
            let peak = max(t.byDay.map(\.usd).max() ?? 1, 0.01)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(t.byDay.enumerated()), id: \.offset) { _, d in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.85))
                        .frame(height: max(2, 48 * d.usd / peak))
                }
            }
            .frame(height: 48)
            if let first = t.byDay.first?.day, let last = t.byDay.last?.day {
                HStack(spacing: 4) {
                    Text(String(format: L("trophy.dayRange", "%@ to %@ · %d active days"), first, last, t.byDay.count))
                        .font(Theme.sans(11)).foregroundStyle(Theme.text2)
                    Spacer(minLength: Theme.s1)
                    // Same reason the hourly chart needed one: without the tallest bar's value
                    // the row is a silhouette, and every silhouette looks the same.
                    if let top = t.byDay.max(by: { $0.usd < $1.usd }), top.usd > 0 {
                        Text(String(format: L("trophy.dayPeak", "peak %@ · %@"), money(top.usd), top.day))
                            .font(Theme.figures(11, 500)).foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }

    private var tokens: some View {
        let parts: [(String, Int)] = [
            (L("tokens.input", "Input"), t.tokens.input),
            (L("tokens.output", "Output"), t.tokens.output),
            (L("tokens.cacheWrite", "Cache write"), t.tokens.cacheWrite),
            (L("tokens.cacheRead", "Cache read"), t.tokens.cacheRead),
        ]
        let total = max(parts.reduce(0) { $0 + $1.1 }, 1)
        return VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Token".uppercased()).brandLabel().foregroundStyle(Theme.text2)
            // Four numbers in a column hide the actual shape of this page: cache reads run two
            // to three orders of magnitude past everything else, which four right-aligned
            // figures make you notice only if you count digits. One bar says it at a glance,
            // and it is the most surprising true thing here.
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        Rectangle().fill(tokenColour(i))
                            .frame(width: g.size.width * Double(part.1) / Double(total))
                    }
                }
            }
            .frame(height: 10).clipShape(Capsule())
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                grid(part.0, part.1, share: Double(part.1) / Double(total), swatch: tokenColour(i))
            }
            Divider().overlay(Theme.hairline)
            grid(L("tokens.roundTrips", "Round trips"), t.turns, raw: true)
        }
    }

    /// Cache reads get the second colour because they are the cheap bulk — a tenth of the input
    /// rate — and separating them is what makes the bar say something rather than just be long.
    private func tokenColour(_ i: Int) -> Color {
        i == 3 ? modelColour(0) : Theme.accent.opacity(0.4 + 0.2 * Double(i))
    }

    private func grid(_ k: String, _ v: Int, raw: Bool = false, share: Double? = nil,
                      swatch: Color? = nil) -> some View {
        HStack {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9)
            } else if share == nil, !raw {
                Color.clear.frame(width: 9, height: 9)
            }
            Text(k).font(Theme.sans(12)).foregroundStyle(Theme.text2)
            Spacer()
            if let share, share >= 0.001 {
                Text(share >= 0.1 ? "\(Int((share * 100).rounded()))%"
                                  : String(format: "%.1f%%", share * 100))
                    .font(Theme.figures(11, 400)).foregroundStyle(Theme.text2)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(raw ? (Self.grouped.string(from: NSNumber(value: v)) ?? "\(v)") : big(v))
                .font(Theme.figures(12, 500)).foregroundStyle(Theme.text)
                .frame(width: 72, alignment: .trailing)
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

    /// `%,.0f` is not a thing in Swift — that is Python's and Java's grouping flag, and here it
    /// printed the literal string `$,.0f` where the largest figure on the page should have been.
    /// Grouping comes from a formatter or not at all.
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

    /// Rounding can push a figure past the unit it was chosen for: 999,999,999 is under a
    /// billion, so it lands in millions — and `%.1f` then prints it as "1000.0 M".
    static func big(_ v: Int) -> String {
        let units: [(limit: Double, unit: String, places: Int)] =
            [(1e9, "B", 2), (1e6, "M", 1), (1e3, "K", 0)]
        let d = Double(v)
        for (i, u) in units.enumerated() where d >= u.limit {
            let power = pow(10, Double(u.places))
            if (d / u.limit * power).rounded() / power >= 1000, i > 0 {
                let up = units[i - 1]
                return String(format: "%.\(up.places)f %@", d / up.limit, up.unit)
            }
            return String(format: "%.\(u.places)f %@", d / u.limit, u.unit)
        }
        return "\(v)"
    }

    private func big(_ v: Int) -> String { Self.big(v) }
}
