import Foundation
import XCTest
@testable import PWEAIBar

/// Claude's prepaid balance: read with the same login, beside the quota, and never in its way.
final class BalanceTests: XCTestCase {
    override func setUp() { super.setUp(); Loc.language = .en }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let organization = "0F1E2D3C-4B5A-6978-8695-A4B3C2D1E0F9"
    private let quota = #"{"five_hour":{"utilization":7.4,"resets_at":1800003600},"seven_day":{"utilization":18.2,"resets_at":1800400000}}"#

    private func map(_ json: String) throws -> ClaudeBalance? {
        ClaudeBalance.map(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
    }

    // MARK: The reply

    /// The reply measured on 2026-10-18: nothing bought, nothing given.
    func testTheMeasuredReplyIsAZeroBalance() throws {
        let balance = try XCTUnwrap(try map("""
        {"amount":0,"currency":"AUD","balance":{"money":{"amount_minor":0,"currency":"AUD","exponent":2},"credits":null},
         "auto_reload_settings":null,"expiry_policy_months":null,"tranches":[],"promo_tranches":[],"next_expires_at":null}
        """))
        XCTAssertEqual(balance.amount, 0)
        XCTAssertEqual(balance.currency, "AUD")
        XCTAssertNil(balance.nextLapse(after: date))
    }

    /// `balance.money` carries its exponent and wins over the flat field; the flat field is cents.
    func testMoneyUsesItsExponentAndTheFlatFieldIsCents() throws {
        XCTAssertEqual(try map(#"{"amount":999,"currency":"USD","balance":{"money":{"amount_minor":1250,"currency":"USD","exponent":2}}}"#)?.amount,
                       Decimal(string: "12.5"))
        XCTAssertEqual(try map(#"{"amount":1250,"currency":"usd"}"#)?.amount, Decimal(string: "12.5"))
        XCTAssertEqual(try map(#"{"amount":1250,"currency":"usd"}"#)?.currency, "USD")
        XCTAssertNil(try map(#"{"currency":"USD"}"#), "no amount: not supported here")
        XCTAssertNil(try map(#"{"amount":12.5,"currency":"USD"}"#), "minor units are whole numbers")
        XCTAssertNil(try map(#"{"amount":-100,"currency":"USD"}"#))
    }

    /// The promotional credit that lapses first, ignoring spent and lapsed ones.
    func testTheNextLapseIsTheSoonestThatIsStillWorthSomething() throws {
        let balance = try XCTUnwrap(try map("""
        {"amount":3000,"currency":"AUD","promo_tranches":[
          {"remaining_amount_minor_units":1000,"currency":"AUD","expires_at":"2027-01-20T00:00:00Z"},
          {"remaining_amount_minor_units":500,"currency":"AUD","expires_at":"2027-01-10T00:00:00Z"},
          {"remaining_amount_minor_units":0,"currency":"AUD","expires_at":"2027-01-05T00:00:00Z"},
          {"remaining_amount_minor_units":700,"currency":"AUD","expires_at":"2027-01-01T00:00:00Z"}]}
        """))
        let now = ISO8601DateFormatter().date(from: "2027-01-02T00:00:00Z")!
        XCTAssertEqual(balance.nextLapse(after: now)?.amount, 5)
        XCTAssertEqual(balance.nextLapse(after: now)?.expiresAt, ISO8601DateFormatter().date(from: "2027-01-10T00:00:00Z"))
    }

    // MARK: The request

    /// Asked the way Claude Code asks: the organisation in the path and in its header.
    func testTheRequestNamesTheOrganisationTwice() throws {
        let r = try XCTUnwrap(ClaudeUsageClient.prepaid(token: "t", organization: organization))
        let id = organization.lowercased()
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/api/oauth/organizations/\(id)/prepaid/credits")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-organization-uuid"), id)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(ClaudeUsageClient.prepaid(token: "t", organization: "../usage"), "only a UUID goes into the path")
    }

    // MARK: The provider

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock(); private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func provider(source: Credentials.Source = .claudeFile, organization: String?, balanceStatus: Int = 200,
                          clock: @escaping () -> Date, sent: Sent) throws -> ClaudeProvider {
        let space = try TestSpace()
        let token = Credentials.Token(value: "tok", expiresAt: date.addingTimeInterval(3600), source: source)
        let access = ClaudeProvider.Access(own: { source == .ownToken ? token : nil },
                                           load: { _ in source == .ownToken ? [] : [token] },
                                           save: { _ in .failed(-1) },
                                           organization: { organization })
        let quota = self.quota
        return ClaudeProvider(defaults: space.defaults, access: access, now: clock, request: { r in
            let path = r.url!.path; sent.add(path)
            let prepaid = path.hasSuffix("/prepaid/credits")
            let body = prepaid ? #"{"amount":1250,"currency":"AUD"}"# : quota
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: prepaid ? balanceStatus : 200,
                                                     httpVersion: nil, headerFields: nil)!)
        })
    }

    func testTheBalanceIsReadWithTheQuotaAndAtMostEveryHalfHour() async throws {
        var now = date
        let sent = Sent()
        let p = try provider(organization: organization, clock: { now }, sent: sent)
        _ = await p.windows(force: true)
        let first = await p.details.balance
        XCTAssertEqual(first?.amount, Decimal(string: "12.5"))
        now = date.addingTimeInterval(600)
        _ = await p.windows(force: true)
        now = date.addingTimeInterval(1900)
        _ = await p.windows(force: true)
        XCTAssertEqual(sent.all.filter { $0.hasSuffix("/prepaid/credits") }.count, 2)
        XCTAssertEqual(sent.all.filter { $0 == "/api/oauth/usage" }.count, 3)
    }

    /// A balance that cannot be read is no reason to call the quota failed.
    func testAFailingBalanceLeavesTheQuotaAlone() async throws {
        let sent = Sent()
        let p = try provider(organization: organization, balanceStatus: 500, clock: { self.date }, sent: sent)
        let reading = await p.windows(force: true)
        XCTAssertFalse(reading.stale)
        XCTAssertEqual(reading.windows.first?.percent, 7.4)
        let blocker = await p.blocker
        XCTAssertEqual(blocker, .none)
        let balance = await p.details.balance
        XCTAssertNil(balance)
    }

    /// No organisation, or a manual token that may belong to another account: not asked at all.
    func testNoOrganisationOrAManualTokenIsNotAsked() async throws {
        for (source, org) in [(Credentials.Source.claudeFile, nil as String?), (.ownToken, organization)] {
            let sent = Sent()
            let p = try provider(source: source, organization: org, clock: { self.date }, sent: sent)
            _ = await p.windows(force: true)
            XCTAssertFalse(sent.all.contains { $0.hasSuffix("/prepaid/credits") }, "\(source)")
        }
    }
}
