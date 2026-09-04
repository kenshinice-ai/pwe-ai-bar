import Foundation

/// How urgent a window is. The Claude usage endpoint reports this itself, which is why we do
/// not invent thresholds for it: the server knows what its own limits mean, and its word is
/// more accurate than any percentage we could compare against. Local thresholds exist only for
/// sources that give a bare number, and as the offline fallback.
enum Severity: String, Comparable {
    case normal, warning, critical

    init(word: String?) {
        switch (word ?? "").lowercased() {
        case "warning", "warn": self = .warning
        case "critical", "error", "rejected", "exhausted": self = .critical
        default: self = .normal
        }
    }
    var health: Health { self == .critical ? .hot : self == .warning ? .warm : .calm }
    static func < (a: Severity, b: Severity) -> Bool {
        let o: [Severity: Int] = [.normal: 0, .warning: 1, .critical: 2]
        return o[a]! < o[b]!
    }
}

/// One quota window, whatever the provider calls it.
///
/// `percent` is nil for a window that has no meaningful ratio — a team plan whose credits are
/// simply gone reports a state, not a fraction, and forcing it into a progress bar beside
/// Claude's would be a lie about what we know.
struct QuotaWindow: Identifiable {
    let id: String              // "session", "weekly_all", "codex_primary" …
    let provider: Provider
    let channel: Channel
    let title: String
    var percent: Double?
    var severity: Severity = .normal
    var resetsAt: Date?
    var isActive: Bool = false  // the endpoint's own word for "this is the one biting"
    var note: String?           // shown instead of a percentage when percent is nil

    var display: String { percent.map { "\(Int($0.rounded()))%" } ?? (note ?? "—") }

    /// Strain for the wing. A window with no ratio but a critical state pins the feather.
    var strain: Double {
        if let p = percent {
            return min(1.2, Health.strain(p, warm: channel.warm, hot: channel.hot))
        }
        return severity == .critical ? 1.0 : 0
    }

    var band: Health {
        // The server's own severity outranks our arithmetic wherever it gave us one.
        max(severity.health, Health.grade(percent ?? 0, warm: channel.warm, hot: channel.hot))
    }
}

enum Provider: String, CaseIterable {
    case claude, codex, gemini

    var chip: String { ["claude": "C", "codex": "X", "gemini": "G"][rawValue] ?? "?" }
    var name: String { ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"][rawValue] ?? rawValue }
    /// Bundle ids tried in order when the user clicks through to the app.
    var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex:  return ["com.openai.codex", "com.openai.chat"]
        case .gemini: return ["com.google.GeminiMacOS"]
        }
    }
}

/// Something that happened in a session, as opposed to something that is merely true.
struct AgentEvent: Identifiable {
    enum Kind: String { case waiting, finished, failed }
    let id: String
    let provider: Provider
    let kind: Kind
    let text: String
    let at: Date

    var isAttention: Bool { kind == .waiting }
}

/// Everything the interface draws, assembled once per refresh.
struct Snapshot {
    var windows: [QuotaWindow] = []
    var contextPercent: Double?
    var events: [AgentEvent] = []
    var trophy: Trophy = Trophy()
    var stale: Bool = false          // last fetch failed or was rate-limited; showing old numbers
    var updatedAt: Date = .init()

    func window(_ ch: Channel) -> QuotaWindow? { windows.first { $0.channel == ch } }

    /// The reading that gets to be the big number. Not a fixed window: whichever one is
    /// actually closest to stopping you, with the endpoint's `is_active` breaking ties.
    var protagonist: QuotaWindow? {
        windows.filter { $0.percent != nil || $0.severity == .critical }
               .max { a, b in
                   if a.isActive != b.isActive { return b.isActive }
                   return a.strain < b.strain
               }
    }

    var attention: AgentEvent? { events.first { $0.isAttention } }

    /// Five channels for the wing, innermost first, in `Channel` order.
    func channels(dark: Bool = true) -> [ChannelHealth] {
        Channel.allCases.map { ch in
            if ch == .context {
                let p = contextPercent ?? 0
                return ChannelHealth(channel: ch,
                                     band: Health.grade(p, warm: ch.warm, hot: ch.hot),
                                     fill: min(1, Health.strain(p, warm: ch.warm, hot: ch.hot)))
            }
            guard let w = window(ch) else {
                return ChannelHealth(channel: ch, band: .calm, fill: 0)
            }
            return ChannelHealth(channel: ch, band: w.band, fill: min(1, w.strain))
        }
    }

    /// The single colour the menu bar shows.
    ///
    /// A standing condition is not an event. An exhausted team credit pool reports critical
    /// forever and has no reset to wait for, so letting it set the bar's colour would pin the
    /// mark red permanently — and a gauge that is always red has stopped being a gauge. Those
    /// windows keep their own feather in the panel, where five colours can say "this one is a
    /// background fact"; they just do not get to speak for the whole mark.
    var overall: Health {
        let actionable = Channel.allCases.filter { ch in
            guard let w = window(ch) else { return true }
            return !(w.severity == .critical && w.percent == nil && w.resetsAt == nil)
        }
        return channels().filter { actionable.contains($0.channel) }
            .map(\.band).max() ?? .calm
    }
}

/// The trophy figures. On a subscription the interesting number is not what you spent — you
/// spent the subscription — but what the same tokens would have cost at API rates.
struct Trophy {
    var days: Int = 0
    var turns: Int = 0
    var equivalentUSD: Double = 0
    var subscriptionUSD: Double = 0
    var byModel: [(model: String, turns: Int, usd: Double)] = []
    var byDay: [(day: String, usd: Double)] = []
    var tokens: (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) = (0, 0, 0, 0)

    var multiple: Double { subscriptionUSD > 0 ? equivalentUSD / subscriptionUSD : 0 }
}
