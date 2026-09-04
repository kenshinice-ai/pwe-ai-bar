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
                ForEach(Array(hours.enumerated()), id: \.offset) { _, h in
                    let share = h.usd / peak
                    RoundedRectangle(cornerRadius: 1.5)
                        // An hour with real spend takes the accent; a quiet one stays a hairline
                        // in the rule colour, present but not competing.
                        .fill(share > 0.02 ? Theme.accent.opacity(0.35 + 0.65 * share)
                                           : Theme.hairline)
                        .frame(height: max(1.5, height * share))
                }
            }
            .frame(height: height, alignment: .bottom)

            HStack {
                Text(label(hours.first?.hour)).font(Theme.sans(9.5))
                Spacer()
                Text("每格一小时").font(Theme.sans(9.5))
                Spacer()
                Text("现在").font(Theme.sans(9.5))
            }
            .foregroundStyle(Theme.text2)
        }
    }

    private func label(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
