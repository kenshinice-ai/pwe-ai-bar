import AppKit
import Foundation

/// The five providers that are not Claude or Codex.
///
/// Each is the same three steps — find the credential the vendor's own tool already stored, make
/// one request, map the answer — so they live together rather than in five files that would be
/// eighty per cent identical. What differs per provider is only: where the credential is, what
/// the request looks like, and which field carries the percentage. That is what each block below
/// contains, and nothing else.
///
/// **What is verified and what is not.** Claude and Codex were checked against live accounts on
/// this machine. None of these five were: none of the tools is installed here, so every one is
/// written from its documented contract and has never been compared against a real dashboard.
/// They are implemented, not confirmed, and the settings panel says so rather than showing a
/// confident "已连接" nobody has ever seen come true.
enum ExtraProviders {

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Whether the tool is on this Mac at all.
    ///
    /// This gates every keychain lookup below, and that is not tidiness. A `security` read is
    /// silent only when the item's owner also wrote it through `security`; an item created via
    /// the Security framework puts an access dialog on screen instead. Asking for the keychain
    /// item of a tool nobody installed is therefore a way to make a password prompt appear for
    /// no possible benefit — the exact thing this app exists to avoid.
    static func appPresent(_ p: Provider) -> Bool {
        for id in p.bundleIDs
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        let fm = FileManager.default
        switch p {
        case .cursor:      return fm.fileExists(atPath: ExtraSource.expand(Cursor.database))
        case .antigravity: return fm.fileExists(atPath: "/Applications/Antigravity.app")
        case .copilot:     return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .contains { fm.isExecutableFile(atPath: $0) }
        default:           return false
        }
    }

    static func installed(_ p: Provider) -> Bool {
        switch p {
        case .cursor:      return Cursor.token() != nil
        case .copilot:     return Copilot.token() != nil
        case .devin:       return Devin.auth() != nil
        case .grok:        return Grok.token() != nil
        case .antigravity: return Antigravity.stored() != nil
        default:           return false
        }
    }

    static func read(_ p: Provider, now: @escaping () -> Date = Date.init,
                     transport: @escaping Transport = { try await URLSession.shared.data(for: $0) })
        async -> ExtraSource.Reading {
        switch p {
        case .cursor:      return await Cursor.read(now: now, transport: transport)
        case .copilot:     return await Copilot.read(now: now, transport: transport)
        case .devin:       return await Devin.read(now: now, transport: transport)
        case .grok:        return await Grok.read(now: now, transport: transport)
        case .antigravity: return await Antigravity.read(now: now, transport: transport)
        default:           return ExtraSource.Reading()
        }
    }

    /// Shared shape: a failed request is never a signed-out account, and a 401 is never a
    /// network problem. Getting that pair backwards is how an app tells someone to log in again
    /// because their wifi dropped.
    static func outcome(_ answer: (status: Int, body: Data)?,
                                map: ([String: Any]) -> ExtraSource.Reading?) -> ExtraSource.Reading {
        guard let answer else {
            return ExtraSource.Reading(connection: .unavailable("暂时读不到，稍后重试"))
        }
        if answer.status == 401 || answer.status == 403 {
            return ExtraSource.Reading(connection: .signedOut)
        }
        guard (200..<300).contains(answer.status),
              let root = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
        else {
            return ExtraSource.Reading(connection: .unavailable("接口返回 \(answer.status)"))
        }
        guard var reading = map(root) else {
            return ExtraSource.Reading(connection: .unsupported("这个账户没有可读的额度"))
        }
        reading.connection = .connected
        return reading
    }

    static func window(_ id: String, _ p: Provider, _ title: String,
                               used: Double?, resetsAt: Date?, now: Date,
                               length: TimeInterval? = nil) -> QuotaWindow? {
        guard let used = ExtraSource.percent(used) else { return nil }
        return QuotaWindow(id: "\(p.rawValue)_\(id)", provider: p, channel: p.channel, title: title,
                           percent: used, resetsAt: resetsAt, observedAt: now,
                           gradedBy: .local, confirmedExhausted: used >= 100, windowLength: length)
    }

    // MARK: Cursor

    /// Cursor keeps its login in the editor's own VS Code state database, and sometimes in the
    /// keychain as well. The database is authoritative when both are present: it is the copy
    /// the running editor updates.
    enum Cursor {
        static let database = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

        static func token(run: ProcessLine = Subprocess.line) -> String? {
            if let value = ExtraSource.sqliteValue(database, key: "cursorAuth/accessToken", run: run) {
                return value
            }
            guard appPresent(.cursor) else { return nil }
            return ExtraSource.keychain(service: "cursor-access-token", run: run)
        }

        static func map(_ root: [String: Any], now: Date) -> ExtraSource.Reading? {
            guard root["enabled"] as? Bool != false,
                  let usage = ExtraSource.object(root["planUsage"]) else { return nil }
            let reset = ExtraSource.date(root["billingCycleEnd"])
            let windows = [("total", "本期额度", usage["totalPercentUsed"]),
                           ("auto", "Auto", usage["autoPercentUsed"]),
                           ("api", "API", usage["apiPercentUsed"])].compactMap {
                window($0.0, .cursor, $0.1, used: ExtraSource.number($0.2), resetsAt: reset, now: now)
            }
            return windows.isEmpty ? nil : ExtraSource.Reading(windows: windows)
        }

        static func read(now: @escaping () -> Date, transport: @escaping Transport) async
            -> ExtraSource.Reading {
            guard let token = token() else { return ExtraSource.Reading() }
            if let expiry = ExtraSource.jwtExpiry(token), expiry <= now() {
                return ExtraSource.Reading(connection: .signedOut)
            }
            // Connect RPC: a POST with an empty JSON body, not a REST GET.
            let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json",
                           "Connect-Protocol-Version": "1"]
            guard let usage = ExtraSource.request(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                method: "POST", headers: headers, body: Data("{}".utf8)) else {
                return ExtraSource.Reading(connection: .unavailable("请求构造失败"))
            }
            var reading = outcome(await ExtraSource.send(usage, via: transport)) {
                map($0, now: now())
            }
            if case .connected = reading.connection,
               let plan = ExtraSource.request(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo",
                method: "POST", headers: headers, body: Data("{}".utf8)),
               let answer = await ExtraSource.send(plan, via: transport),
               (200..<300).contains(answer.status),
               let root = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any] {
                reading.plan = ExtraSource.planLabel(ExtraSource.object(root["planInfo"])?["planName"])
            }
            return reading
        }
    }

    // MARK: GitHub Copilot

    /// Three places, in the order the tools themselves prefer: the editor plugin's own config,
    /// then the GitHub CLI's file, then the CLI's keychain item.
    enum Copilot {
        static func token(run: ProcessLine = Subprocess.line) -> String? {
            for path in ["~/.config/github-copilot/apps.json", "~/.config/github-copilot/hosts.json"] {
                guard let root = ExtraSource.json(path) else { continue }
                // Keys are hosts, sometimes with a suffix: "github.com", "github.com:abc123".
                for (host, value) in root where host == "github.com" || host.hasPrefix("github.com:") {
                    if let token = (ExtraSource.object(value)?["oauth_token"] as? String)?.nonEmpty {
                        return token
                    }
                }
            }
            if let yaml = ExtraSource.text("~/.config/gh/hosts.yml"),
               let token = ExtraSource.flatValue(yaml, key: "oauth_token") { return token }
            guard appPresent(.copilot) else { return nil }
            return ExtraSource.keychain(service: "gh:github.com", run: run).flatMap(ExtraSource.unwrap)
        }

        static func read(now: @escaping () -> Date, transport: @escaping Transport) async
            -> ExtraSource.Reading {
            guard let token = token() else { return ExtraSource.Reading() }
            guard let request = ExtraSource.request(
                "https://api.github.com/copilot_internal/user",
                headers: ["Authorization": "token \(token)", "Accept": "application/json",
                          "Editor-Version": "vscode/1.96.2",
                          "Editor-Plugin-Version": "copilot-chat/0.26.7",
                          "User-Agent": "GitHubCopilotChat/0.26.7",
                          "X-Github-Api-Version": "2025-04-01"]) else {
                return ExtraSource.Reading(connection: .unavailable("请求构造失败"))
            }
            return outcome(await ExtraSource.send(request, via: transport)) { map($0, now: now()) }
        }

        static func map(_ root: [String: Any], now: Date) -> ExtraSource.Reading? {
                let reset = ExtraSource.date(root["quota_reset_date"])
                    ?? ExtraSource.date(root["limited_user_reset_date"])
                let snapshots = ExtraSource.object(root["quota_snapshots"])
                var windows = [("premium_interactions", "Premium"), ("chat", "Chat"),
                               ("completions", "Completions")].compactMap { key, title -> QuotaWindow? in
                    guard let bucket = ExtraSource.object(snapshots?[key]) else { return nil }
                    // An unlimited bucket has no ratio to show. -1 is how this API spells it.
                    let entitlement = ExtraSource.number(bucket["entitlement"])
                    let remaining = ExtraSource.number(bucket["remaining"])
                    if bucket["unlimited"] as? Bool == true
                        || entitlement == -1 || remaining == -1 || entitlement == 0 { return nil }
                    let used: Double
                    if let left = ExtraSource.number(bucket["percent_remaining"]) { used = 100 - left }
                    else if let entitlement, entitlement > 0, let remaining {
                        used = 100 - remaining / entitlement * 100
                    } else { return nil }
                    return window(key, .copilot, title, used: used, resetsAt: reset, now: now)
                }
                if windows.isEmpty {
                    // Older accounts report a count left against a monthly total instead.
                    let left = ExtraSource.object(root["limited_user_quotas"])
                    let total = ExtraSource.object(root["monthly_quotas"])
                    windows = [("chat", "Chat"), ("completions", "Completions")]
                        .compactMap { key, title in
                            guard let cap = ExtraSource.number(total?[key]), cap > 0,
                                  let rest = ExtraSource.number(left?[key]) else { return nil }
                            return window(key, .copilot, title, used: (cap - rest) / cap * 100,
                                          resetsAt: reset, now: now)
                        }
                }
                guard !windows.isEmpty else { return nil }
                return ExtraSource.Reading(windows: windows,
                                           plan: ExtraSource.planLabel(root["copilot_plan"]))
        }
    }

    // MARK: Devin

    enum Devin {
        struct Auth { let apiKey: String; let server: String }

        static func auth() -> Auth? {
            guard let toml = ExtraSource.text("~/.local/share/devin/credentials.toml"),
                  let key = ExtraSource.flatValue(toml, key: "windsurf_api_key")
                    ?? ExtraSource.flatValue(toml, key: "apiKey")
                    ?? ExtraSource.flatValue(toml, key: "api_key") else { return nil }
            let server = ExtraSource.flatValue(toml, key: "api_server_url")
            return Auth(apiKey: key, server: server?.hasPrefix("https://") == true
                        ? server! : "https://server.codeium.com")
        }

        static func read(now: @escaping () -> Date, transport: @escaping Transport) async
            -> ExtraSource.Reading {
            guard let auth = auth() else { return ExtraSource.Reading() }
            let metadata: [String: Any] = ["metadata": [
                "apiKey": auth.apiKey, "ideName": "devin", "ideVersion": "1.108.2",
                "extensionName": "devin", "extensionVersion": "1.108.2", "locale": "en"]]
            guard let body = try? JSONSerialization.data(withJSONObject: metadata),
                  let request = ExtraSource.request(
                    "\(auth.server)/exa.seat_management_pb.SeatManagementService/GetUserStatus",
                    method: "POST",
                    headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1"],
                    body: body) else {
                return ExtraSource.Reading(connection: .unavailable("请求构造失败"))
            }
            return outcome(await ExtraSource.send(request, via: transport)) { map($0, now: now()) }
        }

        static func map(_ root: [String: Any], now: Date) -> ExtraSource.Reading? {
            guard let status = ExtraSource.object(root["userStatus"]) else { return nil }
            let plan = ExtraSource.object(status["planStatus"]) ?? [:]
            let info = ExtraSource.object(plan["planInfo"]) ?? [:]
            var windows: [QuotaWindow] = []
            // Devin reports what is left; everything here stores what is spent.
            if info["hideDailyQuota"] as? Bool != true,
               let left = ExtraSource.number(plan["dailyQuotaRemainingPercent"]),
               let row = window("daily", .devin, "每日额度", used: 100 - left,
                                resetsAt: ExtraSource.date(plan["dailyQuotaResetAtUnix"]),
                                now: now, length: 86400) {
                windows.append(row)
            }
            if let left = ExtraSource.number(plan["weeklyQuotaRemainingPercent"]),
               let row = window("weekly", .devin, "每周额度", used: 100 - left,
                                resetsAt: ExtraSource.date(plan["weeklyQuotaResetAtUnix"]),
                                now: now, length: 7 * 86400) {
                windows.append(row)
            }
            guard !windows.isEmpty else { return nil }
            return ExtraSource.Reading(windows: windows, plan: ExtraSource.planLabel(info["planName"]))
        }
    }

    // MARK: Grok

    enum Grok {
        static func token() -> String? {
            guard let root = ExtraSource.json("~/.grok/auth.json") else { return nil }
            let tokens = ExtraSource.object(root["tokens"]) ?? root
            for key in ["access_token", "accessToken"] {
                if let value = (tokens[key] as? String)?.nonEmpty { return value }
            }
            return nil
        }

        static func map(_ root: [String: Any], now: Date) -> ExtraSource.Reading? {
            guard let config = ExtraSource.object(root["config"]),
                  let period = ExtraSource.object(config["currentPeriod"]),
                  // Only the weekly period is a quota window; anything else is a billing cycle
                  // we would be mislabelling as one.
                  (period["type"] as? String) == "USAGE_PERIOD_TYPE_WEEKLY",
                  let row = window("weekly", .grok, "每周额度",
                                   used: ExtraSource.number(config["creditUsagePercent"]),
                                   resetsAt: ExtraSource.date(period["end"]), now: now,
                                   length: 7 * 86400)
            else { return nil }
            return ExtraSource.Reading(windows: [row])
        }

        static func read(now: @escaping () -> Date, transport: @escaping Transport) async
            -> ExtraSource.Reading {
            guard let token = token() else { return ExtraSource.Reading() }
            let headers = ["Authorization": "Bearer \(token)", "X-XAI-Token-Auth": "xai-grok-cli",
                           "Accept": "application/json"]
            guard let request = ExtraSource.request(
                "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers) else {
                return ExtraSource.Reading(connection: .unavailable("请求构造失败"))
            }
            var reading = outcome(await ExtraSource.send(request, via: transport)) {
                map($0, now: now())
            }
            if case .connected = reading.connection,
               let settings = ExtraSource.request("https://cli-chat-proxy.grok.com/v1/settings",
                                                  headers: headers),
               let answer = await ExtraSource.send(settings, via: transport),
               (200..<300).contains(answer.status),
               let root = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any] {
                reading.plan = ExtraSource.planLabel(root["subscription_tier_display"])
            }
            return reading
        }
    }

    // MARK: Antigravity

    /// Google's agent IDE, whose quota lives behind Cloud Code. Its keychain item holds a Google
    /// OAuth document; we use the access token in it and stop there. Minting a fresh one from
    /// the refresh token means writing a credential cache, and this app does not write anyone's
    /// login — so an expired session is reported as one, and Antigravity itself renews it.
    enum Antigravity {
        static func stored(run: ProcessLine = Subprocess.line) -> [String: Any]? {
            guard appPresent(.antigravity),
                  let raw = ExtraSource.keychain(service: "gemini", account: "antigravity", run: run),
                  let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            else { return nil }
            return root
        }

        static func map(_ root: [String: Any], now: Date) -> ExtraSource.Reading? {
            guard let groups = (ExtraSource.object(root["response"]) ?? root)["groups"]
                    as? [[String: Any]] else { return nil }
            var windows: [QuotaWindow] = []
            for group in groups {
                for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                    guard let id = (bucket["bucketId"] as? String)?.nonEmpty,
                          let fraction = ExtraSource.number(bucket["remainingFraction"]),
                          let row = window(id, .antigravity, ExtraSource.planLabel(id) ?? id,
                                           used: (1 - fraction) * 100,
                                           resetsAt: ExtraSource.date(bucket["resetTime"]),
                                           now: now) else { continue }
                    windows.append(row)
                }
            }
            return windows.isEmpty ? nil : ExtraSource.Reading(windows: windows)
        }

        static func read(now: @escaping () -> Date, transport: @escaping Transport) async
            -> ExtraSource.Reading {
            guard let root = stored() else { return ExtraSource.Reading() }
            let node = ExtraSource.object(root["tokens"]) ?? root
            guard let token = ["access_token", "accessToken"]
                .compactMap({ (node[$0] as? String)?.nonEmpty }).first else {
                return ExtraSource.Reading(connection: .signedOut)
            }
            if let expiry = ExtraSource.date(node["expiry_date"] ?? node["expires_at"]), expiry <= now() {
                return ExtraSource.Reading(connection: .signedOut)
            }
            // Two hosts, in the order Antigravity tries them.
            for host in ["https://daily-cloudcode-pa.googleapis.com",
                         "https://cloudcode-pa.googleapis.com"] {
                guard let request = ExtraSource.request(
                    host + "/v1internal:retrieveUserQuotaSummary", method: "POST",
                    headers: ["Authorization": "Bearer \(token)", "Accept": "application/json",
                              "Content-Type": "application/json", "User-Agent": "antigravity"],
                    body: Data("{}".utf8)) else { continue }
                guard let answer = await ExtraSource.send(request, via: transport) else { continue }
                if answer.status == 401 || answer.status == 403 {
                    return ExtraSource.Reading(connection: .signedOut)
                }
                guard (200..<300).contains(answer.status) else { continue }
                return outcome(answer) { map($0, now: now()) }
            }
            return ExtraSource.Reading(connection: .unavailable("暂时读不到，稍后重试"))
        }
    }
}

/// Holds what the five answered, so a twenty-second refresh does not become five HTTP requests
/// and a handful of subprocesses every twenty seconds.
///
/// They are asked in parallel and independently: one provider being slow, signed out, or broken
/// must not delay or discard the others. That is the whole reason this is a task group rather
/// than a loop.
actor ExtraStore {
    static let shared = ExtraStore()

    struct Result {
        var windows: [QuotaWindow] = []
        var plans: [Provider: String] = [:]
        var connections: [Provider: ExtraSource.Connection] = [:]
    }

    private var cache: [Provider: (reading: ExtraSource.Reading, at: Date)] = [:]
    private let now: () -> Date
    private let fetch: (Provider, @escaping () -> Date) async -> ExtraSource.Reading

    init(now: @escaping () -> Date = Date.init,
         fetch: @escaping (Provider, @escaping () -> Date) async -> ExtraSource.Reading
            = { p, clock in await ExtraProviders.read(p, now: clock) }) {
        self.now = now; self.fetch = fetch
    }

    func read(_ providers: [Provider]) async -> Result {
        let due = providers.filter { p in
            guard let entry = cache[p] else { return true }
            return now().timeIntervalSince(entry.at) >= ttl(entry.reading)
        }
        if !due.isEmpty {
            let clock = now
            let get = fetch
            let fresh = await withTaskGroup(of: (Provider, ExtraSource.Reading).self) { group in
                for p in due { group.addTask { (p, await get(p, clock)) } }
                var out: [(Provider, ExtraSource.Reading)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (p, reading) in fresh { cache[p] = (reading, now()) }
        }
        var result = Result()
        for p in providers {
            guard let entry = cache[p] else { continue }
            result.windows += entry.reading.windows
            result.connections[p] = entry.reading.connection
            if let plan = entry.reading.plan { result.plans[p] = plan }
        }
        return result
    }

    /// A provider that is not here is asked again rarely: `installed()` costs a subprocess for
    /// some of them, and the answer changes about as often as someone installs an IDE.
    private func ttl(_ reading: ExtraSource.Reading) -> TimeInterval {
        switch reading.connection {
        case .notInstalled:        return 1800
        case .signedOut:           return 600
        case .unsupported:         return 3600
        case .unavailable:         return 120
        case .connected:
            let band = reading.windows.map(\.band).max() ?? .calm
            let soon = reading.windows.compactMap(\.resetsAt)
                .map { $0.timeIntervalSince(now()) }.filter { $0 > 0 }.min() ?? .infinity
            return band == .hot || soon < 600 ? 120 : band == .warm ? 180 : 300
        }
    }
}
