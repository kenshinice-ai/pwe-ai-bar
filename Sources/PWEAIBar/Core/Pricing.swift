import Foundation

/// API list prices, per million tokens. A data file, not constants baked into a view: prices
/// change, and when they do the fix should be editing `pricing.json` in the bundle (or dropping
/// one in Application Support) rather than shipping a new build.
///
/// Cache write and cache read are expressed as multiples of the input rate, which is how the
/// price list itself is structured — 1.25× for a five-minute write, 0.1× for a read. Two places
/// where that shorthand is not the whole truth, both recorded in the file rather than here:
/// Fable 5.1 and Mythos 5.1 read cache at 0.025×, and a one-hour cache write is 2× rather than
/// 1.25×. Transcripts do not say which write duration was used, so every write is priced as the
/// five-minute one; that under-counts an hour-cached session and is stated rather than hidden.
struct Pricing: Codable {
    struct Rate: Codable {
        var input: Double
        var output: Double
        var cacheWriteMultiple: Double = 1.25
        var cacheReadMultiple: Double = 0.10
    }

    struct Plan: Codable {
        var display: String
        var USD: Double?
        var AUD: Double?
        func amount(_ currency: String) -> Double? { currency == "AUD" ? AUD : USD }
    }

    struct Subscriptions: Codable {
        var plans: [String: Plan] = [:]
        var _source: String?
        var _checked: String?
        var _note: String?
    }

    var models: [String: Rate]
    var subscriptionMonthlyUSD: Double
    var subscriptions: Subscriptions?
    /// Where the table came from and when it was last checked against the source. Carried in the
    /// file so a stale price list can be recognised as one.
    var _source: String?
    var _checked: String?
    var _note: String?

    /// Only reached when the bundled file is missing or unreadable. Kept to the models most
    /// likely to be in a transcript rather than mirroring the whole table twice.
    static let fallback = Pricing(
        models: [
            "claude-opus-5":     .init(input: 5,  output: 25),
            "claude-opus-4-8":   .init(input: 5,  output: 25),
            "claude-fable-5":    .init(input: 10, output: 50),
            "claude-fable-5-1":  .init(input: 10, output: 50, cacheReadMultiple: 0.025),
            "claude-sonnet-5":   .init(input: 2,  output: 10),
            "claude-haiku-4-5":  .init(input: 1,  output: 5),
        ],
        subscriptionMonthlyUSD: 20,
        subscriptions: Subscriptions(plans: [
            "pro": .init(display: "Pro", USD: 20),
            "max_5x": .init(display: "Max 5×", USD: 100, AUD: 150),
            "max_20x": .init(display: "Max 20×", USD: 200),
        ])
    )

    /// Which plan key the account's own words map to.
    ///
    /// `rateLimitTier` is the precise one — it distinguishes `max_5x` from `max_20x`, which
    /// `subscriptionType` ("max") does not, and getting that wrong is a factor of two in the
    /// figure the whole page is built around. `subscriptionType` is the fallback for records
    /// that predate the tier field.
    static func planKey(tier: String?, type: String?) -> String? {
        if let tier = tier?.lowercased() {
            if tier.contains("max_20x") || tier.contains("max20") { return "max_20x" }
            if tier.contains("max_5x") || tier.contains("max5") { return "max_5x" }
            if tier.contains("pro") { return "pro" }
        }
        switch type?.lowercased() {
        case "pro": return "pro"
        // Deliberately not guessed as a tier: "max" alone cannot say 5× from 20×, and choosing
        // one would silently halve or double the multiple.
        case "max": return nil
        default: return nil
        }
    }

    /// What to charge the reader for, or nil when nothing here can say.
    ///
    /// Nil is a real answer and the page renders it as one: no multiple at all, and a prompt to
    /// set the price. A ratio against a price nobody confirmed reads exactly as confidently as
    /// a correct one, which is what makes it worse than showing nothing.
    func subscription(planKey: String?, currency: String,
                      override: Double?, overrideUSD: Double?) -> Subscription? {
        let plan = planKey.flatMap { subscriptions?.plans[$0] }
        let display = plan?.display ?? planKey ?? L("pricing.subscription", "Subscription")
        let shown = override ?? plan?.amount(currency)
        let usd = overrideUSD ?? plan?.USD ?? (currency == "USD" ? shown : nil)
        guard let shown, let usd, shown > 0, usd > 0 else { return nil }
        return Subscription(plan: planKey ?? "", display: display,
                            currency: currency, monthly: shown, monthlyUSD: usd)
    }

    /// Bundle copy first, then a user override in Application Support — so a price change can be
    /// dropped in without rebuilding.
    static func load() -> Pricing {
        let override = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PWE AI Bar/pricing.json")
        for url in [override, Bundle.resources.url(forResource: "pricing", withExtension: "json")] {
            guard let url, let data = try? Data(contentsOf: url),
                  let p = try? JSONDecoder().decode(Pricing.self, from: data) else { continue }
            return p
        }
        return .fallback
    }

    /// What one turn would have cost at list price. Unknown models cost nothing rather than
    /// guessing — a wrong number in the trophy is worse than a missing one.
    func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        guard let r = models[model] else { return 0 }
        return (Double(input) * r.input
              + Double(output) * r.output
              + Double(cacheWrite) * r.input * r.cacheWriteMultiple
              + Double(cacheRead) * r.input * r.cacheReadMultiple) / 1_000_000
    }
}
