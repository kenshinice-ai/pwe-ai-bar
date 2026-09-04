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

    /// When this reading was taken. Claude's comes from a live endpoint, so it is now. Codex's
    /// comes out of a session log, so it is as old as the last time Codex ran — the number is
    /// still correct while its window is open (nothing can consume Codex quota without writing
    /// to that log), but the panel says how old it is rather than implying it is live.
    var observedAt: Date = .init()

    /// Who decided this is a warning. The Claude endpoint grades itself and its word is used
    /// as-is; Codex reports a bare percentage that we grade against our own thresholds. Two
    /// providers' "warning" therefore do not mean the same thing, and the panel should not
    /// pretend otherwise.
    enum Grader { case server, local }
    var gradedBy: Grader = .local

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

    /// The reading that represents that feather.
    ///
    /// A provider can own several windows on one feather — Codex reports a five-hour, a weekly
    /// and a credit pool on the same one — so this takes the tightest. But it takes the
    /// tightest *actionable* one: the gauge is for things you can still do something about, and
    /// a spent add-on pool would otherwise hold that feather at full red for weeks and drown
    /// out the weekly window filling up behind it. The standing fact is not hidden; it keeps
    /// its own row in the panel, which is where a fact belongs.
    func window(_ ch: Channel) -> QuotaWindow? {
        let mine = windows.filter { $0.channel == ch }
        let live = mine.filter(isActionable)
        return (live.isEmpty ? mine : live).max { $0.strain < $1.strain }
    }

    func windows(of p: Provider) -> [QuotaWindow] { windows.filter { $0.provider == p } }

    /// A window you can do something about: it has a ratio, or a reset to wait for. An add-on
    /// credit pool that is simply spent has neither — it is a standing fact about the account,
    /// not a window that is about to stop you, and it must not speak for the whole app.
    var isActionable: (QuotaWindow) -> Bool {
        { !($0.severity == .critical && $0.percent == nil && $0.resetsAt == nil) }
    }

    /// The reading that gets to be the big number. Not a fixed window: whichever one is
    /// actually closest to stopping you, with the endpoint's `is_active` breaking ties.
    ///
    /// Standing conditions are excluded for the same reason they are kept out of the menu-bar
    /// colour — a headline that reads "附加额度 已用尽" for three weeks running tells you
    /// nothing you did not already know, and hides the window that is genuinely filling up.
    var protagonist: QuotaWindow? {
        let usable = windows.filter { ($0.percent != nil || $0.severity == .critical) && isActionable($0) }
        return (usable.isEmpty ? windows.filter { $0.percent != nil } : usable)
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
    /// One colour for the menu bar. `channels()` already reports only actionable readings, so
    /// nothing here needs a special case: a permanently spent credit pool cannot reach this.
    var overall: Health { channels().map(\.band).max() ?? .calm }
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
    /// The last 24 hours, one bucket an hour, oldest first. Comes from the transcripts
    /// rather than a sampled history file, so it is complete on first launch instead of
    /// filling in over the following day.
    var byHour: [(hour: Date, usd: Double)] = []
    var tokens: (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) = (0, 0, 0, 0)

    var multiple: Double { subscriptionUSD > 0 ? equivalentUSD / subscriptionUSD : 0 }
}
