import Foundation

/// API list prices, per million tokens. A data file, not constants baked into a view: prices
/// change, and when they do the fix should be editing `pricing.json` in the bundle (or dropping
/// one in Application Support) rather than shipping a new build.
///
/// Cache write and cache read are expressed as multiples of the input rate, which is how the
/// price list itself is structured — 1.25× for a five-minute write, 0.1× for a read.
struct Pricing: Codable {
    struct Rate: Codable {
        var input: Double
        var output: Double
        var cacheWriteMultiple: Double = 1.25
        var cacheReadMultiple: Double = 0.10
    }

    var models: [String: Rate]
    var subscriptionMonthlyUSD: Double

    static let fallback = Pricing(
        models: [
            "claude-opus-5":    .init(input: 5,  output: 25),
            "claude-opus-4-8":  .init(input: 5,  output: 25),
            "claude-fable-5":   .init(input: 10, output: 50),
            "claude-fable-5-1": .init(input: 10, output: 50),
            "claude-sonnet-5":  .init(input: 2,  output: 10),
            "claude-haiku-4-5": .init(input: 1,  output: 5),
        ],
        subscriptionMonthlyUSD: 20
    )

    /// Bundle copy first, then a user override in Application Support — so a price change can be
    /// dropped in without rebuilding.
    static func load() -> Pricing {
        let override = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PWE AI Bar/pricing.json")
        for url in [override, Bundle.module.url(forResource: "pricing", withExtension: "json")] {
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
