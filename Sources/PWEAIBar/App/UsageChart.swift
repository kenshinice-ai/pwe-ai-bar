import SwiftUI

/// Twenty-four hourly bars of equivalent spend.
///
/// Drawn from the transcripts rather than a sampled history file, so it is complete the first
/// time you open the panel instead of filling in over the next day. Empty hours keep their slot:
/// a gap is information, and closing it up would make a quiet night look busy.
struct UsageChart: View {
    let hours: [(hour: Date, usd: Double)]
    var height: CGFloat = 34

    private var peak: Double { max(hours.map(\.usd).max() ?? 0, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                    let share = h.usd / peak
                    // The last bucket is the hour you are standing in. Drawn solid like the
                    // twenty-three complete ones it reads as a quiet hour, when what it really
                    // is is an hour that has not happened yet — five minutes past the hour it
                    // shows a twelfth of what it will end up being.
                    let partial = i == hours.count - 1
                    RoundedRectangle(cornerRadius: 1.5)
                        // An hour with real spend takes the accent; a quiet one stays a hairline
                        // in the rule colour, present but not competing.
                        .fill(share > 0.02 ? Theme.accent.opacity((0.35 + 0.65 * share) * (partial ? 0.45 : 1))
                                           : Theme.hairline)
                        .frame(height: max(1.5, height * share))
                }
            }
            .frame(height: height, alignment: .bottom)

            HStack {
                Text(label(hours.first?.hour)).font(Theme.sans(9.5))
                Spacer()
                // Bars without a scale are a shape, not a measurement: the same silhouette
                // stands for a $2 afternoon and a $200 one. The peak is the cheapest thing that
                // turns it back into a reading.
                if peak > 0.01 {
                    Text("峰值 \(money(peak))/时").font(Theme.sans(9.5))
                }
                Spacer()
                Text("现在 · 未满").font(Theme.sans(9.5))
            }
            .foregroundStyle(Theme.text2)
        }
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return f
    }()

    private func money(_ v: Double) -> String {
        v >= 100 ? "$" + (Self.grouped.string(from: NSNumber(value: v)) ?? String(Int(v)))
                 : String(format: "$%.1f", v)
    }

    private func label(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
