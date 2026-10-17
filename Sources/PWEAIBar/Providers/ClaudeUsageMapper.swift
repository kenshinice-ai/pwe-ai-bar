import CoreFoundation
import CryptoKit
import Foundation

enum ClaudeValue {
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        if let s = value as? String, let n = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), n.isFinite {
            return n
        }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 {
            return Date(timeIntervalSince1970: n > 30_000_000_000 ? n / 1000 : n)
        }
        guard let text = text(value) else { return nil }
        if let parsed = ISO8601DateFormatter.parse(text) { return parsed }
        // Some usage responses omit a timezone; their contract uses UTC.
        if let parsed = ISO8601DateFormatter.parse(text + "Z") { return parsed }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return text.count == 10 ? f.date(from: text) : nil
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClaudeSpend: Equatable {
    let usedUSD: Decimal
    let limitUSD: Decimal?
}

/// Money bought ahead for Claude: the organisation's prepaid balance, and the promotional credits
/// inside it that lapse on a date. Read from `prepaid/credits`, which Claude Code asks with the
/// same login (2.1.299, `api_prepaid_balance_fetch`).
///
/// Measured 2026-10-18 on this Mac's account: `amount` 0, `currency` "AUD", `balance.money`
/// `{amount_minor: 0, exponent: 2}`, no promotional credits.
struct ClaudeBalance: Equatable {
    struct Promo: Equatable {
        let amount: Decimal
        let currency: String
        let expiresAt: Date
    }
    let amount: Decimal
    let currency: String
    let promos: [Promo]

    /// The promotional credit that lapses first and is still worth something at `now`.
    func nextLapse(after now: Date) -> Promo? {
        promos.filter { $0.expiresAt > now && $0.amount > 0 }.min { $0.expiresAt < $1.expiresAt }
    }

    /// `balance.money` says its own exponent; `amount` is the older flat field, in cents. Nil for a
    /// reply that is neither — Claude Code reads a missing `amount` as "not supported here".
    static func map(_ root: [String: Any]) -> ClaudeBalance? {
        let money = (root["balance"] as? [String: Any])?["money"] as? [String: Any]
        guard let currency = ClaudeValue.text(money?["currency"]) ?? ClaudeValue.text(root["currency"]),
              currency.count == 3 else { return nil }
        let amount: Decimal?
        if let minor = ClaudeValue.number(money?["amount_minor"]) {
            amount = units(minor, exponent: ClaudeValue.number(money?["exponent"]) ?? 2)
        } else {
            amount = ClaudeValue.number(root["amount"]).flatMap { units($0, exponent: 2) }
        }
        guard let amount, amount >= 0 else { return nil }
        let promos: [Promo] = ((root["promo_tranches"] as? [[String: Any]]) ?? []).compactMap { tranche in
            guard let minor = ClaudeValue.number(tranche["remaining_amount_minor_units"]),
                  let value = units(minor, exponent: 2), value > 0,
                  let expires = ClaudeValue.date(tranche["expires_at"]) else { return nil }
            return Promo(amount: value, currency: ClaudeValue.text(tranche["currency"]) ?? currency,
                         expiresAt: expires)
        }
        return ClaudeBalance(amount: amount, currency: currency.uppercased(), promos: promos)
    }

    /// Minor units are whole numbers; anything else is not a figure to put in front of anyone.
    private static func units(_ minor: Double, exponent: Double) -> Decimal? {
        guard minor == minor.rounded(), abs(minor) < 1e15, (0...4).contains(exponent),
              exponent == exponent.rounded() else { return nil }
        var value = Decimal(Int64(minor))
        for _ in 0..<Int(exponent) { value /= 10 }
        return value
    }
}

/// A dollar allowance that comes with the plan, beside the percentage windows. Measured 2026-10-18 on
/// this Mac's Max account as `iguana_necktie`: `limit_dollars` 250, `used_dollars` 56.6455, resetting
/// 2026-11-05; Lee identified it as the credit the Max plan includes. Found by shape rather than by
/// that name — a node outside the windows with a dollar cap — because the name is a code word.
struct ClaudeAllowance: Equatable {
    let usedUSD: Decimal
    let limitUSD: Decimal
    let resetsAt: Date?
}

enum ClaudeUsageMapper {
    enum Failure: Error { case invalidResponse, conflictingWindows }
    struct Result {
        var windows: [QuotaWindow]
        var spend: ClaudeSpend?
        var allowances: [ClaudeAllowance] = []
    }

    /// Every node that is not a quota window and carries a positive `limit_dollars`. The windows
    /// carry the same fields, empty, so they are excluded by key: a window that one day gains a
    /// dollar cap is still a window, not a second allowance.
    static func allowances(_ root: [String: Any]) -> [ClaudeAllowance] {
        root.keys.sorted().compactMap { key -> ClaudeAllowance? in
            guard key != "five_hour", !key.hasPrefix("seven_day"), let node = root[key] as? [String: Any],
                  let limit = ClaudeValue.number(node["limit_dollars"]), limit > 0,
                  let used = ClaudeValue.number(node["used_dollars"]), used >= 0,
                  let limitUSD = dollars(limit), let usedUSD = dollars(used) else { return nil }
            return ClaudeAllowance(usedUSD: usedUSD, limitUSD: limitUSD, resetsAt: ClaudeValue.date(node["resets_at"]))
        }
    }

    /// To the cent: `used_dollars` arrives as 56.6455, and a figure on screen is money.
    private static func dollars(_ value: Double) -> Decimal? {
        guard value.isFinite, abs(value) < 1e12 else { return nil }
        return Decimal(string: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value),
                       locale: Locale(identifier: "en_US_POSIX"))
    }

    /// One parser for every money figure in this response. Always POSIX: the digits arrive
    /// from JSON, not from a person, so the reader's locale has no business in them.
    private static func cents(_ value: Double) -> Decimal? {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func map(_ root: [String: Any], at now: Date) throws -> Result {
        var rows: [String: QuotaWindow] = [:]
        for key in root.keys.sorted() where key == "five_hour" || key == "seven_day" || key.hasPrefix("seven_day_") {
            guard let node = root[key] as? [String: Any] else { continue }
            let channel: Channel = key == "five_hour" ? .session : key == "seven_day" ? .week : .other
            guard let row = try window(id: key, title: title(key), channel: channel, node: node,
                                       percentage: node["utilization"], now: now) else { continue }
            rows[key] = row
        }
        for node in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = ClaudeValue.text(node["kind"]) else { continue }
            let id: String, label: String, channel: Channel
            switch kind {
            case "session": id = "five_hour"; label = L("channel.session", "5-hour"); channel = .session
            case "weekly_all": id = "seven_day"; label = L("channel.week", "Weekly"); channel = .week
            default:
                guard kind == "weekly_scoped" || node["group"] as? String == "weekly" else { continue }
                let scope = node["scope"] as? [String: Any] ?? [:]
                let model = scope["model"] as? [String: Any] ?? [:]
                let name = ClaudeValue.text(model["display_name"]) ?? ClaudeValue.text(model["id"])
                let scopeData = try JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)
                id = kind + "_" + String(ClaudeValue.fingerprint(scopeData).prefix(16))
                label = name.map { String(format: L("channel.weekScoped", "Weekly · %@"), $0) } ?? title(kind)
                channel = .other
            }
            guard let row = try window(id: id, title: label, channel: channel, node: node,
                                       percentage: node["percent"], now: now) else { continue }
            if var existing = rows[id] {
                if let a = existing.percent, let b = row.percent, abs(a - b) > 0.001 {
                    throw Failure.conflictingWindows
                }
                if let a = existing.resetsAt, let b = row.resetsAt, abs(a.timeIntervalSince(b)) > 1 {
                    throw Failure.conflictingWindows
                }
                existing.percent = existing.percent ?? row.percent
                existing.resetsAt = existing.resetsAt ?? row.resetsAt
                existing.severity = row.severity; existing.gradedBy = row.gradedBy
                existing.isActive = row.isActive
                existing.confirmedExhausted = existing.confirmedExhausted || row.confirmedExhausted
                rows[id] = existing
            } else { rows[id] = row }
        }
        var spend: ClaudeSpend?
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            // Both figures come from the same field of the same response and must be read the
            // same way. `used_credits` was parsed against en_US_POSIX and `monthly_limit`
            // against no locale at all, which Foundation resolves to the current one — so on a
            // machine whose locale writes decimals with a comma, the amount spent parsed and
            // the cap silently did not, and the panel said 「未提供上限」 about a server that
            // had provided one.
            guard let used = ClaudeValue.number(extra["used_credits"]), used >= 0,
                  let decimal = Self.cents(used) else {
                throw Failure.invalidResponse
            }
            var limit: Decimal?
            if let value = extra["monthly_limit"], !(value is NSNull) {
                guard let amount = ClaudeValue.number(value), amount >= 0 else { throw Failure.invalidResponse }
                if amount > 0 { limit = Self.cents(amount).map { $0 / 100 } }
            }
            spend = ClaudeSpend(usedUSD: decimal / 100, limitUSD: limit)
        }
        guard !rows.isEmpty || spend != nil else { throw Failure.invalidResponse }
        return Result(windows: rows.values.sorted {
            let a = $0.id == "five_hour" ? 0 : $0.id == "seven_day" ? 1 : 2
            let b = $1.id == "five_hour" ? 0 : $1.id == "seven_day" ? 1 : 2
            return a == b ? $0.id < $1.id : a < b
        }, spend: spend, allowances: allowances(root))
    }

    private static func window(id: String, title: String, channel: Channel, node: [String: Any],
                               percentage: Any?, now: Date) throws -> QuotaWindow? {
        let pct = ClaudeValue.number(percentage)
        if let percentage, !(percentage is NSNull), pct == nil { throw Failure.invalidResponse }
        if let pct, !(0...100).contains(pct) { throw Failure.invalidResponse }
        let word = ClaudeValue.text(node["severity"])?.lowercased()
        let known = ["normal", "warning", "warn", "critical", "error", "rejected", "exhausted"].contains(word ?? "")
        guard pct != nil || known && Severity(word: word) == .critical else { return nil }
        let reset = ClaudeValue.date(node["resets_at"])
        if let raw = node["resets_at"], !(raw is NSNull), reset == nil { throw Failure.invalidResponse }
        let expired = reset.map { $0 <= now } ?? false
        return QuotaWindow(id: id, provider: .claude, channel: channel, title: title,
                           percent: expired ? nil : pct, severity: expired ? .normal : Severity(word: word),
                           resetsAt: reset, isActive: node["is_active"] as? Bool ?? false,
                           note: expired ? L("note.unconfirmed", "unconfirmed") : nil, observedAt: now, gradedBy: known ? .server : .local,
                           isStale: expired, confirmedExhausted: !expired && ((pct ?? 0) >= 100 || ["exhausted", "rejected"].contains(word ?? "")),
                           windowLength: channel == .session ? 18000 : 604800)
    }

    private static func title(_ id: String) -> String {
        if id == "five_hour" { return L("channel.session", "5-hour") }
        if id == "seven_day" { return L("channel.week", "Weekly") }
        return id.replacingOccurrences(of: "seven_day_",
                                      with: String(format: L("channel.weekScoped", "Weekly · %@"), ""))
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}
