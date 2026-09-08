import Foundation

/// Which tier a reading has entered. Copied wholesale from PWE MAC MONITOR so the two apps
/// grade a reading identically — a feather that is three-quarters lit means the same thing
/// in both.
enum Health: Int, Comparable {
    case calm = 0, warm = 1, hot = 2
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    static func grade(_ v: Double, warm: Double, hot: Double) -> Health {
        v >= hot ? .hot : v >= warm ? .warm : .calm
    }
    var word: String { ["calm", "warm", "hot"][rawValue] }

    /// Warm begins at this fraction of the way to trouble, for every channel alike.
    static let warmMark = 0.72

    /// Re-express a reading as the distance travelled toward its own hot threshold: 0 at rest,
    /// exactly `warmMark` at the warm threshold, exactly 1 at the hot one. One shared scale is
    /// what lets a feather's length and its colour come from a single number, so the two can
    /// never disagree — and three-quarters of a feather means the same thing whether the
    /// channel counts a percentage, a countdown, or an exhausted-credits flag.
    static func strain(_ v: Double, warm: Double, hot: Double) -> Double {
        guard hot > warm, warm > 0, v > 0 else { return 0 }
        if v < warm { return warmMark * v / warm }
        return warmMark + (1 - warmMark) * (v - warm) / (hot - warm)
    }
}

/// The five channels the wing reports, innermost feather first.
///
/// Fixed at five: the mark has five feathers and the identity standard fixes that count, so a
/// sixth provider has nowhere to go — it rides in `other`, which shows whichever connected
/// provider is currently tightest. Ordered by how likely each is to stop you right now, so the
/// outermost and longest feather carries the window that actually blocks work.
enum Channel: Int, CaseIterable {
    case context = 0, codex, other, week, session

    var label: String { ["CTX", "CDX", "ETC", "7D", "5H"][rawValue] }
    var name: String {
        [L("channel.context", "Context"), "Codex", L("channel.other", "Other"),
         L("channel.week", "Weekly window"), L("channel.session", "5-hour window")][rawValue]
    }

    /// Percent thresholds. Only used when a source gives us a bare number and no severity of
    /// its own — the Claude endpoint grades itself, and its word wins over these.
    var warm: Double { self == .context ? 70 : 75 }
    var hot: Double  { self == .context ? 90 : 95 }
}

/// One channel's reading, expressed twice: `band` is which tier it entered, `fill` how far
/// through it is. Both derive from the same strain, so a feather can never be short and red.
struct ChannelHealth {
    let channel: Channel
    let band: Health
    let fill: Double        // 0…1, clamped for drawing
}
