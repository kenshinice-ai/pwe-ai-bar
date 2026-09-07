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
    /// Ordered by a stored rank rather than a dictionary lookup: a new case added later would
    /// have made the old version trap on its first comparison.
    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
    static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
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
    /// comes out of a session log and represents that event's time. Usage elsewhere on the
    /// account may not be present locally, so an old observation must not imply live accuracy.
    var observedAt: Date = .init()

    /// Who decided this is a warning. The Claude endpoint grades itself and its word is used
    /// as-is; Codex reports a bare percentage that we grade against our own thresholds. Two
    /// providers' "warning" therefore do not mean the same thing, and the panel should not
    /// pretend otherwise.
    enum Grader: String { case server, local }
    var gradedBy: Grader = .local
    /// A stale or inferred reading is display-only and cannot confirm a recovery.
    var isStale = false
    var confirmedExhausted = false

    /// How long the window runs for. Known where the provider says so — Claude's two are fixed,
    /// Codex reports `window_minutes` — and nil everywhere else rather than guessed.
    var windowLength: TimeInterval?

    /// A stale or inferred reading is display-only and cannot confirm anything, and a window
    /// whose reset has already passed is describing a window that no longer exists.
    func canNotify(at now: Date) -> Bool {
        !isStale && observedAt <= now && now.timeIntervalSince(observedAt) <= 600
            && (resetsAt.map { $0 > now } ?? true)
    }

    /// What this window has actually read, most recent last. Empty until `History` has seen it
    /// more than once; nothing downstream may require it.
    var samples: [History.Sample] = []
    /// Opaque source/account generation; never a token or user identifier.
    var observationNamespace: String? = nil
    /// The key without an account on the end — also the key everything used before accounts
    /// were separated, which is why the alert rules still have to know it exists.
    var observationBase: String { "\(provider.rawValue):\(id)" }
    var observationKey: String {
        observationNamespace.map { observationBase + ":" + $0 } ?? observationBase
    }

    /// When the window opened, which its own length tells us without any history.
    func windowStart(at now: Date) -> Date? {
        guard let length = windowLength, let reset = resetsAt else { return nil }
        let start = reset.addingTimeInterval(-length)
        return start <= now ? start : nil
    }

    /// Everything about pace, projection and verdict now lives in `Forecast`, reached through
    /// `forecast(at:)`. It used to be three methods here plus four if-chains in the view, which
    /// is how the same window could be described as measured by one of them and unknown by
    /// another, and how "we cannot tell you" ended up rendering in the same grey as "you are
    /// fine". One question, one answer, one place.

    var display: String { percent.map { "\(Int($0.rounded()))%" } ?? (note ?? "—") }

    /// Strain for the wing. A window with no ratio but a critical state pins the feather.
    var strain: Double {
        if let p = percent {
            return min(1.2, Health.strain(p, warm: channel.warm, hot: channel.hot))
        }
        return severity == .critical ? 1.0 : 0
    }

    /// Whichever of the two is more alarming wins. The server's severity is authoritative about
    /// things we cannot see — an account-level restriction with no percentage attached — so it
    /// can raise the band on its own. It does not get to lower it: a window sitting at 96 % that
    /// the endpoint still calls `normal` is not a calm menu bar, and a sentinel that under-warns
    /// has failed at the only job it has. Saying "接近上限" here is separate from claiming the
    /// quota is spent; `confirmedExhausted` is what carries that claim.
    var band: Health {
        max(severity.health, Health.grade(percent ?? 0, warm: channel.warm, hot: channel.hot))
    }
}

enum Provider: String, CaseIterable, Codable {
    /// Ordered as they appear in the panel and in settings: the two with a first-party quota
    /// source first, then the rest alphabetically. Adding a case here is safe — `Channel` fixes
    /// five feathers and every provider past Claude and Codex rides in `other`, which carries
    /// whichever of them is currently tightest.
    case claude, codex, antigravity, copilot, cursor, devin, gemini, grok

    var name: String {
        switch self {
        case .claude:      return "Claude Code"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .copilot:     return "GitHub Copilot"
        case .cursor:      return "Cursor"
        case .devin:       return "Devin"
        case .gemini:      return "Gemini"
        case .grok:        return "Grok"
        }
    }

    /// Which feather this provider's windows ride on. Only the two with their own feather get
    /// one; the rest share `other`, which shows the tightest of them.
    var channel: Channel { self == .codex ? .codex : .other }

    /// Bundle ids tried in order when the user clicks through to the app. ChatGPT.app ships
    /// with `com.openai.codex` as its identifier, which is why that one is first.
    var bundleIDs: [String] {
        switch self {
        case .claude:      return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex:       return ["com.openai.codex", "com.openai.chat"]
        case .antigravity: return ["com.google.antigravity", "dev.antigravity.Antigravity"]
        case .copilot:     return ["com.microsoft.VSCode", "com.github.GitHubClient"]
        case .cursor:      return ["com.todesktop.230313mzl4w4u92"]
        case .devin:       return ["ai.cognition.devin", "com.exafunction.windsurf"]
        case .gemini:      return ["com.google.GeminiMacOS"]
        case .grok:        return ["com.x.grok", "ai.x.grok"]
        }
    }

    /// Where to go when the app is not installed. Clicking a row and having nothing happen is
    /// worse than opening the wrong thing.
    var fallbackURL: URL? {
        switch self {
        case .claude:      return URL(string: "https://claude.ai/code")
        case .codex:       return URL(string: "https://chatgpt.com/codex")
        case .antigravity: return URL(string: "https://antigravity.google")
        case .copilot:     return URL(string: "https://github.com/features/copilot")
        case .cursor:      return URL(string: "https://cursor.com/dashboard")
        case .devin:       return URL(string: "https://app.devin.ai")
        case .gemini:      return URL(string: "https://gemini.google.com")
        case .grok:        return URL(string: "https://grok.com")
        }
    }

    /// Why a provider can be listed but never report anything. Gemini's desktop app keeps only
    /// settings databases — no quota field anywhere — and the CLI's `gemini_cli.token.usage` is
    /// a token count behind opt-in telemetry, which is not the same measurement.
    var unavailableReason: String? {
        self == .gemini ? "本地没有额度来源" : nil
    }
}

/// Something that happened in a session, as opposed to something that is merely true.
struct AgentEvent: Identifiable, Codable {
    enum Kind: String, Codable {
        case waiting, finished, failed
        /// You replied. Carries no message of its own — it exists so a "waiting" state stops
        /// being true the moment you answer, instead of lingering until the turn ends.
        case answered
    }
    let id: String
    let provider: Provider
    let kind: Kind
    let text: String
    let at: Date

    /// The optional UUID is supplied by the spool writer. Legacy events retain a stable key.
    var eventID: String? = nil
    var key: String { eventID ?? "\(provider.rawValue):\(id):\(kind.rawValue):\(at.timeIntervalSince1970)" }

    var isAttention: Bool { kind == .waiting }
}

/// Everything the interface draws, assembled once per refresh.
struct Snapshot {
    var windows: [QuotaWindow] = []
    var claudeDetails = ClaudeProvider.Details()
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
                // Strain first, `is_active` only to break a tie.
                //
                // The other way round — which this was — let a window the endpoint had flagged
                // active outrank one that was actually full: a session at 3 % beat a weekly at
                // 100 %, and the panel led with the number that was not about to stop you.
                // `is_active` says "this is the window being charged right now", not "this is
                // the one closest to its limit".
                if abs(a.strain - b.strain) > 0.001 { return a.strain < b.strain }
                return b.isActive
            }
    }

    /// The window the stage shows, honouring a reader's pin.
    ///
    /// `protagonist` answers the question the app assumes you have — what is closest to
    /// stopping you. That is the right default and the wrong answer about half the time you
    /// deliberately open the panel, because you came to look at one particular tool. A pin says
    /// which one.
    ///
    /// A pin that matches nothing on screen is ignored rather than obeyed. Pinning a provider
    /// and then untracking it, or pinning one whose reading has not arrived yet, must not leave
    /// the stage blank — it falls back to the automatic choice and the pin quietly waits.
    func hero(pinnedTo provider: Provider?) -> QuotaWindow? {
        guard let provider else { return protagonist }
        let mine = windows.filter {
            $0.provider == provider && ($0.percent != nil || $0.severity == .critical)
        }
        guard !mine.isEmpty else { return protagonist }
        return mine.max { a, b in
            if abs(a.strain - b.strain) > 0.001 { return a.strain < b.strain }
            return b.isActive
        }
    }

    /// What each provider calls the plan this account is on. Shown as-is: it is their word for
    /// their own product, and translating "team" into anything else would be inventing meaning.
    var plans: [Provider: String] = [:]

    /// Why a tracked provider has nothing to show. Carried so a provider that failed keeps its
    /// place in the panel and says what happened, instead of vanishing — which looks identical
    /// to never having been switched on.
    var connections: [Provider: String] = [:]

    var attention: AgentEvent? { events.first { $0.isAttention } }
    var waiting: Int { events.filter(\.isAttention).count }

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
    /// One colour for the menu bar.
    ///
    /// Only channels that have something actionable on them get a vote. `window(_:)` prefers an
    /// actionable window but falls back to whatever exists, which is right for the panel — a
    /// feather should still show that Codex's credit pool is spent — and wrong here: a channel
    /// whose *only* reading is a standing condition would hold the whole mark red for weeks,
    /// which is the thing this rule exists to prevent. A gauge that is always red is not a gauge.
    var overall: Health {
        let live: Set<Channel> = Set(
            windows.filter(isActionable).map(\.channel)
        ).union(contextPercent != nil ? [.context] : [])
        let voting = channels().filter { live.contains($0.channel) }
        return voting.map(\.band).max() ?? .calm
    }

    /// One sentence, for VoiceOver and the tooltip.
    ///
    /// The wing is a picture of a number, and a picture is all a screen reader gets from it.
    /// The house standard spells the gauge out for the same reason — a mark that carries the
    /// reading has to be able to say it.
    func spoken(remaining: Bool) -> String {
        var parts: [String] = []
        for w in windows.sorted(by: { $0.strain > $1.strain }) {
            let value = w.percent.map {
                remaining ? "剩余 \(Int((100 - $0).rounded()))%" : "已用 \(Int($0.rounded()))%"
            } ?? (w.note ?? "无数据")
            parts.append("\(w.provider.name) \(w.title) \(value)")
        }
        if let c = contextPercent {
            parts.append("上下文 \(remaining ? "剩余 \(Int((100 - c).rounded()))" : "已用 \(Int(c.rounded()))")%")
        }
        if let a = attention { parts.insert(a.text, at: 0) }
        // Only when there is actually an old number on screen. Saying it while a provider has
        // no data at all points at nothing — the panel's own line explains that case.
        if stale, !windows.isEmpty { parts.append("显示的是上一次成功读到的数字") }
        return parts.isEmpty ? "PWE AI Bar，暂无数据" : parts.joined(separator: "，")
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
    /// The last 24 hours, one bucket an hour, oldest first. Comes from the transcripts
    /// rather than a sampled history file, so it is complete on first launch instead of
    /// filling in over the following day.
    var byHour: [(hour: Date, usd: Double)] = []
    var tokens: (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) = (0, 0, 0, 0)

    var multiple: Double { subscriptionUSD > 0 ? equivalentUSD / subscriptionUSD : 0 }
}
