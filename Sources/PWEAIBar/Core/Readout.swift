import Foundation

/// How a percentage is written down.
///
/// Codex's own interface says "Usage remaining · 84%". The Claude endpoint reports
/// `utilization`, which is the same window seen from the other end — 16 % used. Both are
/// correct and the two numbers look nothing alike, so a panel that mixes them makes its own
/// figures look wrong next to the tools they came from.
///
/// One convention, applied to every provider, and the user picks which. Remaining is the
/// default: it is the question you are actually asking ("can I keep going?"), it is what Codex
/// shows, and a bar that drains reads like a fuel gauge without needing a label.
///
/// The wing gauge never uses this. A feather's length is strain — distance travelled toward
/// trouble — and that has to point the same way regardless of how the number beside it is
/// written, or the mark and the figure would contradict each other.
enum Readout {

    static func text(_ w: QuotaWindow, remaining: Bool) -> String {
        // The one state where a number is the wrong answer. "100%" and "0%" are the same fact
        // written two ways, and both need reading twice; at a glance in a menu bar, neither
        // says *you are stopped*. Two characters do.
        if w.confirmedExhausted { return "已用尽" }
        guard let pct = w.percent else { return w.note ?? "—" }
        let shown = remaining ? max(0, 100 - pct) : pct
        return "\(Int(shown.rounded()))%"
    }

    /// How much of the bar to paint, 0…1. In remaining mode the bar empties as you spend,
    /// which is why it is not simply `1 - used` everywhere else in the code.
    static func fill(_ w: QuotaWindow, remaining: Bool) -> Double? {
        guard let pct = w.percent else { return nil }
        let shown = remaining ? max(0, 100 - pct) : pct
        return min(1, max(0, shown / 100))
    }

    static var label: (used: String, remaining: String) { ("已用", "剩余") }
}
