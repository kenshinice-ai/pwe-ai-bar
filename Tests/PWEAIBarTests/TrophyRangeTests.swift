import XCTest
@testable import PWEAIBar

/// The subscription price and the date range, which are the two things on the trophy page that
/// can be confidently wrong.
final class TrophyRangeTests: XCTestCase {

    private var pricing: Pricing { Pricing.load() }

    /// The tier is what separates Max 5× from Max 20×, and that is a factor of two.
    ///
    /// Shipped wrong: the price was the constant 20 — the Pro price — for every account. On a
    /// Max 5× account the page reported 782× where the truth was 156×, five times over, and
    /// never showed the subscription price at all so nothing looked odd.
    func testThePlanComesFromTheTierRatherThanTheWordMax() {
        XCTAssertEqual(Pricing.planKey(tier: "default_claude_max_5x", type: "max"), "max_5x")
        XCTAssertEqual(Pricing.planKey(tier: "default_claude_max_20x", type: "max"), "max_20x")
        XCTAssertEqual(Pricing.planKey(tier: "default_claude_ai", type: "pro"), "pro")

        // "max" on its own cannot say which tier, and choosing one would silently halve or
        // double the headline figure. Nil is the honest answer and the page renders it as one.
        XCTAssertNil(Pricing.planKey(tier: nil, type: "max"))
        XCTAssertNil(Pricing.planKey(tier: nil, type: nil))
    }

    func testAnUnknownPlanYieldsNoSubscriptionAndThereforeNoMultiple() {
        XCTAssertNil(pricing.subscription(planKey: nil, currency: "USD", override: nil, overrideUSD: nil),
                     "with no plan there is no price, and a multiple against an invented one "
                     + "reads exactly as confidently as a correct one")
        var t = Trophy()
        t.equivalentUSD = 20_328
        XCTAssertEqual(t.multiple, 0, "no subscription means no ratio at all")
    }

    /// A$150 and US$100 are both the price of Max 5×; neither is the other times a rate.
    func testTheShownAmountAndTheBasisAreSeparateAmounts() throws {
        let aud = try XCTUnwrap(pricing.subscription(planKey: "max_5x", currency: "AUD",
                                                     override: nil, overrideUSD: nil))
        XCTAssertEqual(aud.monthly, 150, "what the reader pays")
        XCTAssertEqual(aud.monthlyUSD, 100, "what the multiple is computed against")
        XCTAssertEqual(aud.display, "Max 5×")

        let usd = try XCTUnwrap(pricing.subscription(planKey: "max_5x", currency: "USD",
                                                     override: nil, overrideUSD: nil))
        XCTAssertEqual(usd.monthly, 100)
        XCTAssertEqual(usd.monthlyUSD, 100)
    }

    func testASettingsOverrideWinsOverTheShippedTable() throws {
        let s = try XCTUnwrap(pricing.subscription(planKey: "max_5x", currency: "AUD",
                                                   override: 165, overrideUSD: 110))
        XCTAssertEqual(s.monthly, 165)
        XCTAssertEqual(s.monthlyUSD, 110)
    }

    /// The range has to reach every section, not just the headline.
    ///
    /// This is what the per-day-per-model digest is for. When model and token totals were a
    /// single all-time sum, a range could only ever have moved the top three figures while
    /// "by model" and "Token" silently stayed all-time — a page disagreeing with itself.
    func testTheRangeFiltersModelsAndTokensAndNotJustTheHeadline() throws {
        let zone = Double(TimeZone.current.secondsFromGMT())
        let today = Int(floor((Date().timeIntervalSince1970 + zone) / 86400))
        var d = Transcript.Digest()
        // Two days inside a week, one far outside it.
        d.add(day: today, model: "claude-opus-5",
              .init(turns: 3, input: 100, output: 10, cacheWrite: 0, cacheRead: 0, usd: 30))
        d.add(day: today - 2, model: "claude-sonnet-5",
              .init(turns: 2, input: 50, output: 5, cacheWrite: 0, cacheRead: 0, usd: 12))
        d.add(day: today - 60, model: "claude-haiku-4-5",
              .init(turns: 99, input: 9_000, output: 900, cacheWrite: 0, cacheRead: 0, usd: 500))

        let week = Transcript.assemble(d, pricing: pricing, range: .week, subscription: nil).trophy
        XCTAssertEqual(week.days, 2)
        XCTAssertEqual(week.equivalentUSD, 42, accuracy: 0.001)
        XCTAssertEqual(week.turns, 5, "turns must follow the range too")
        XCTAssertEqual(week.tokens.input, 150, "and so must the token totals")
        XCTAssertEqual(Set(week.byModel.map(\.model)), ["claude-opus-5", "claude-sonnet-5"],
                       "the model 60 days ago is outside the week and must not appear")
        XCTAssertEqual(week.range, .week)

        let all = Transcript.assemble(d, pricing: pricing, range: .all, subscription: nil).trophy
        XCTAssertEqual(all.days, 3)
        XCTAssertEqual(all.equivalentUSD, 542, accuracy: 0.001)
        XCTAssertEqual(all.turns, 104)
        XCTAssertEqual(all.byModel.count, 3)
    }

    /// The subscription is charged against active days within the range, not against the span.
    func testTheSubscriptionIsAmortisedOverActiveDaysInTheRange() throws {
        let zone = Double(TimeZone.current.secondsFromGMT())
        let today = Int(floor((Date().timeIntervalSince1970 + zone) / 86400))
        var d = Transcript.Digest()
        for back in [0, 1] {
            d.add(day: today - back, model: "claude-opus-5",
                  .init(turns: 1, input: 10, output: 1, cacheWrite: 0, cacheRead: 0, usd: 100))
        }
        let sub = try XCTUnwrap(pricing.subscription(planKey: "max_5x", currency: "AUD",
                                                     override: nil, overrideUSD: nil))
        let t = Transcript.assemble(d, pricing: pricing, range: .week, subscription: sub).trophy
        XCTAssertEqual(t.days, 2, "two active days, not seven calendar days")
        XCTAssertEqual(t.subscriptionUSD, 100 * 2 / 30.0, accuracy: 0.001)
        XCTAssertEqual(t.multiple, 200 / (100 * 2 / 30.0), accuracy: 0.001)
        XCTAssertEqual(t.subscriptionMonthly?.currency, "AUD", "shown in the reader's currency")
    }
}
