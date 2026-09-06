import Foundation
import os

/// OAuth usage, with explicit credential, observation, and retry states.
actor ClaudeProvider {
    typealias Reading = (windows: [QuotaWindow], stale: Bool)
    struct Access {
        var own: () -> Credentials.Token?
        var claudeCode: () -> Credentials.Token?
        var sharedExists: () -> Bool
        var shared: () -> Credentials.Token?
        var save: (String) -> Credentials.SaveResult
        static let live = Access(own: Credentials.ownToken,
                                 claudeCode: { Credentials.claudeCodeCredential() },
                                 sharedExists: Credentials.sharedItemExists,
                                 shared: Credentials.readShared, save: { Credentials.storeOwnToken($0) })
    }
    enum Blocker: Equatable {
        case none, needsSetup, notLoggedIn, keychainRefused, expired, unauthorized, forbidden, network
        case rateLimited(Date)
        var message: String {
            switch self {
            case .none: return "已验证，额度连接正常"
            case .needsSetup: return "请启用真实额度"
            case .notLoggedIn: return "未找到凭据，请登录 Claude Code"
            case .keychainRefused: return "钥匙串访问失败，请重新授权"
            case .expired: return "Claude Code 的凭据已过期，而本 app 不替你续期。用 claude setup-token 生成长期令牌贴进设置即可"
            case .unauthorized: return "凭据已失效，请在设置中更换令牌或重新登录 Claude Code"
            case .forbidden: return "凭据无权读取额度，请检查账户权限或更换令牌"
            case .network: return "暂时无法验证，请检查网络，稍后自动重试"
            case .rateLimited: return "接口限流中，将按服务端时间重试"
            }
        }
    }
    enum TokenUpdate: Equatable {
        case saved(Blocker), cleared, failed(Int32)
        var stored: Bool { if case .saved = self { return true }; return false }
        var succeeded: Bool { if case .failed = self { return false }; return true }
        var message: String {
            switch self {
            case .saved(let state): return "已保存 · " + state.message
            case .cleared: return "已清除令牌"
            case .failed(let code): return "钥匙串操作失败（\(code)），请重试"
            }
        }
    }

    private let defaults: UserDefaults
    private let cacheURL: URL
    private let access: Access
    private let request: (URLRequest) async throws -> (Data, URLResponse)
    private let now: () -> Date
    private let fallback: () -> (resetsAt: Date, kind: String)?
    private var cache: [QuotaWindow] = []
    private var fetchedAt: Date?
    private var loaded = false
    private var revision = 0
    private var requestTask: Task<Reading, Never>?
    private var rejectedValue: String?
    private var retryNetworkAt: Date?
    private(set) var lastSource: Credentials.Source = .none

    /// Whether the *credential* is good — not whether the last request worked. Being throttled,
    /// or offline, is not a reason to tell someone to log in again, and sending them to
    /// `claude auth login` for a problem that heals itself is the worst kind of wrong advice.
    var loggedIn: Bool {
        switch blocker {
        case .notLoggedIn, .needsSetup, .expired, .unauthorized, .keychainRefused: return false
        case .none, .forbidden, .network, .rateLimited: return true
        }
    }
    private(set) var blocker: Blocker = .none

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, access: Access = .live,
         now: @escaping () -> Date = Date.init,
         request: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         fallback: @escaping () -> (resetsAt: Date, kind: String)? = { Transcript.lastRateLimit() }) {
        self.defaults = defaults; self.access = access; self.now = now; self.request = request; self.fallback = fallback
        self.cacheURL = cacheURL ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("PWE AI Bar/quota-cache.json")
    }

    private var refusedBefore: Bool {
        get { defaults.bool(forKey: "keychainRefused") }
        set { defaults.set(newValue, forKey: "keychainRefused") }
    }
    private var sharedAllowed: Bool {
        get { defaults.bool(forKey: "sharedKeychainOptIn") }
        set { defaults.set(newValue, forKey: "sharedKeychainOptIn") }
    }
    private var retryAfter: Date? {
        get {
            let d = Date(timeIntervalSince1970: defaults.double(forKey: "quotaRetryAfter"))
            return d > now() ? d : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "quotaRetryAfter") }
    }

    private func token() async -> Credentials.Token? {
        // Both of these block: one on securityd, one on a subprocess. Neither may run on this
        // actor — a refresh that waits on the keychain is a menu bar that stops answering.
        // Claude Code's own credential comes first: it is the one the CLI keeps current, and
        // reading it costs a ~20 ms subprocess against 4–84 s for the fallback. But *first* is
        // not *only*. It was measured on this machine expired by seven and a half hours while
        // Claude Code ran happily the whole time — the CLI does not rewrite that item on every
        // refresh — and taking the first credential found meant giving up with "登录过期" while
        // a perfectly good long-lived token sat in our own item, never tried.
        let read = access.claudeCode
        let date = now()
        let cli = await offActor { read() }
        if let cli, cli.expiresAt.map({ $0 > date }) ?? true {
            lastSource = cli.source
            return cli
        }
        // Only now is the slow one worth paying for.
        if let stored = await ownWithTimeout() {
            lastSource = stored.source
            return stored
        }
        if let cli {
            lastSource = cli.source
            return cli
        }
        // Everything below is the old direct-keychain path, which can put a dialog on screen.
        // It is reached only when Claude Code's credential could not be read the quiet way.
        guard sharedAllowed else {
            blocker = access.sharedExists() ? .needsSetup : .notLoggedIn; return nil
        }
        guard !refusedBefore else { blocker = .keychainRefused; return nil }
        return await sharedWithTimeout()
    }

    /// `SecItemCopyMatching` against our own item has been measured on this machine at 4 ms,
    /// 4 s, 10 s and 84 s for the same read — securityd's cold path, and worse again for a
    /// binary whose signature changed since the item was written. A refresh that waits on it
    /// unboundedly is a panel that stops updating, so it gets the same racing-continuation
    /// treatment the shared keychain read already has: answer in three seconds or count as
    /// absent for this cycle and try again on the next one.
    private func ownWithTimeout() async -> Credentials.Token? {
        let read = access.own
        return await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool {
                resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let token = read()
                if claim() { cont.resume(returning: token) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if claim() { cont.resume(returning: nil) }
            }
        }
    }

    private func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    /// The endpoint is Claude Code's own, undocumented and unversioned. Presenting anything else
    /// as the client is how a perfectly good token still earns a 429: this app asked with the
    /// URLSession default agent for a whole day and was throttled for all of it.
    static let userAgent: String = {
        let fm = FileManager.default
        var roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/node_modules").path]
        // Wherever `claude` actually lives: follow the launcher and walk up out of bin/.
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let link = String(dir) + "/claude"
            guard fm.isExecutableFile(atPath: link) else { continue }
            let real = (try? fm.destinationOfSymbolicLink(atPath: link)).map {
                $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: link).deletingLastPathComponent()
                    .appendingPathComponent($0).standardized.path
            } ?? link
            roots.insert(URL(fileURLWithPath: real).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path, at: 0)
        }
        for root in roots {
            let path = root + "/@anthropic-ai/claude-code/package.json"
            guard let data = fm.contents(atPath: path),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = o["version"] as? String,
                  !version.isEmpty, version.count < 32 else { continue }
            return "claude-code/" + version
        }
        return "claude-code/2.1.69"
    }()

    private func sharedWithTimeout() async -> Credentials.Token? {
        let version = revision
        let result: Credentials.Token?? = await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool {
                resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            let access = self.access
            DispatchQueue.global(qos: .userInitiated).async {
                let t = access.shared()
                if claim() { cont.resume(returning: .some(t)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                if claim() { cont.resume(returning: .none) }   // outer nil: never answered
            }
        }

        guard version == revision else { return nil }
        guard let inner = result else {
            // The dialog went unanswered. Remember that, so it is asked once and not once a
            // minute; Settings has a button to try again deliberately.
            refusedBefore = true
            blocker = .keychainRefused
            return nil
        }
        guard let t = inner else {
            // The item is there for the CLI but we could not read it: macOS is refusing this
            // signature, which is a different problem from never having logged in.
            if access.sharedExists() {
                refusedBefore = true
                blocker = .keychainRefused
            } else {
                blocker = .notLoggedIn
            }
            return nil
        }
        return t
    }

    private func invalidateCredential() {
        revision += 1
        requestTask?.cancel(); requestTask = nil
        fetchedAt = nil; cache = []; loaded = true
        rejectedValue = nil; retryNetworkAt = nil; blocker = .none; lastSource = .none
        try? FileManager.default.removeItem(at: cacheURL)
    }

    func enableSharedKeychain() {
        sharedAllowed = true; refusedBefore = false
        invalidateCredential()
    }

    func useOwnToken(_ raw: String) async -> TokenUpdate {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch access.save(value) {
        case .failed(let code): return .failed(code)
        case .cleared:
            invalidateCredential()
            return .cleared
        case .saved:
            invalidateCredential()
            _ = await windows()
            return .saved(blocker)
        }
    }

    var source: Credentials.Source { lastSource }

    func windows() async -> Reading {
        if let task = requestTask { return await task.value }
        let version = revision
        let task = Task { await fetch(version: version) }
        requestTask = task
        let result = await task.value
        if revision == version { requestTask = nil }
        return result
    }

    private func fetch(version: Int) async -> Reading {
        loadCache()
        let date = now()
        if let until = retryAfter { blocker = .rateLimited(until); return staleReading() }
        if let until = retryNetworkAt, until > date { return staleReading() }
        if let at = fetchedAt, !cache.isEmpty, date.timeIntervalSince(at) < ttl(),
           !cache.contains(where: { $0.resetsAt.map { $0 <= date } ?? false }) {
            return (cache, false)
        }
        let credential = await token()
        guard version == revision, !Task.isCancelled else { return staleReading() }
        guard let cred = credential else { return staleReading() }
        if let expiry = cred.expiresAt, expiry <= date {
            blocker = .expired; return staleReading()
        }
        if rejectedValue == cred.value { return staleReading() }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(cred.value)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        do {
            let (data, response) = try await request(req)
            guard version == revision, !Task.isCancelled else { return staleReading() }
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 || http.statusCode == 403 {
                rejectedValue = cred.value
                blocker = http.statusCode == 401 ? .unauthorized : .forbidden
                return staleReading()
            }
            if http.statusCode == 429 {
                let until = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: now())
                retryAfter = until; blocker = .rateLimited(until)
                return staleReading()
            }
            guard http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            let parsed = parse(root)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            cache = parsed; fetchedAt = now(); blocker = .none
            rejectedValue = nil; retryAfter = nil; retryNetworkAt = nil
            saveCache()
            return (cache, false)
        } catch {
            guard version == revision, !Task.isCancelled else { return staleReading() }
            blocker = .network; retryNetworkAt = now().addingTimeInterval(60)
            return staleReading()
        }
    }

    /// RFC 9110 permits delay-seconds or an HTTP date. Invalid values back off conservatively.
    nonisolated static func retryDate(_ header: String?, now: Date) -> Date {
        if let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let secs = Double(value), secs.isFinite {
                return now.addingTimeInterval(max(1, secs))
            }
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = format
                if let date = f.date(from: value) { return max(date, now.addingTimeInterval(1)) }
            }
        }
        return now.addingTimeInterval(300)
    }

    private func ttl() -> TimeInterval {
        let soon = cache.compactMap(\.resetsAt).map { $0.timeIntervalSince(now()) }.filter { $0 > 0 }.min() ?? .infinity
        let band = cache.map(\.band).max() ?? .calm
        return band == .hot || soon < 900 ? 60 : band == .warm ? 150 : 300
    }

    private func staleReading() -> Reading {
        var rows = cache
        if rows.isEmpty, let rl = fallback(), rl.resetsAt > now() {
            let channel: Channel = rl.kind.contains("week") ? .week : .session
            rows = [QuotaWindow(id: channel == .week ? "seven_day" : "five_hour", provider: .claude,
                                channel: channel, title: title(rl.kind), percent: nil, severity: .critical,
                                resetsAt: rl.resetsAt, note: "已限流", isStale: true)]
        }
        rows = rows.map { row in
            var w = row; w.isStale = true
            if let reset = w.resetsAt, reset <= now() {
                w.percent = nil; w.severity = .normal; w.note = "待确认"; w.confirmedExhausted = false
            }
            return w
        }
        return (rows, true)
    }

    func parse(_ root: [String: Any]) -> [QuotaWindow] {
        var out: [QuotaWindow] = []
        for l in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = l["kind"] as? String else { continue }
            let channel: Channel
            switch (kind, l["group"] as? String ?? "") {
            case ("session", _): channel = .session
            case ("weekly_all", _): channel = .week
            case (_, "weekly"): channel = .other
            default: continue
            }
            let pct = (l["percent"] as? NSNumber)?.doubleValue
            guard pct == nil || (pct!.isFinite && pct! >= 0 && pct! <= 100) else { continue }
            let word = l["severity"] as? String
            let recognized = ["normal", "warning", "warn", "critical", "error", "rejected", "exhausted"].contains(word?.lowercased() ?? "")
            let id = channel == .session ? "five_hour" : channel == .week ? "seven_day" : kind
            out.append(QuotaWindow(id: id, provider: .claude, channel: channel, title: title(kind),
                                   percent: pct, severity: Severity(word: word),
                                   resetsAt: (l["resets_at"] as? String).flatMap(ISO8601DateFormatter.parse),
                                   isActive: l["is_active"] as? Bool ?? false, observedAt: now(),
                                   gradedBy: recognized ? .server : .local,
                                   confirmedExhausted: (pct ?? 0) >= 100
                                       || ["exhausted", "rejected"].contains(word?.lowercased() ?? ""),
                                   windowLength: channel == .session ? 5 * 3600
                                       : channel == .week ? 7 * 86400 : nil))
        }
        for (key, channel) in [("five_hour", Channel.session), ("seven_day", Channel.week)]
        where !out.contains(where: { $0.channel == channel }) {
            guard let node = root[key] as? [String: Any], let pct = (node["utilization"] as? NSNumber)?.doubleValue,
                  pct.isFinite, pct >= 0, pct <= 100 else { continue }
            out.append(QuotaWindow(id: key, provider: .claude, channel: channel, title: title(key), percent: pct,
                                   resetsAt: (node["resets_at"] as? String).flatMap(ISO8601DateFormatter.parse),
                                   observedAt: now(), gradedBy: .local, confirmedExhausted: pct >= 100,
                                   windowLength: channel == .session ? 5 * 3600 : 7 * 86400))
        }
        let others = out.filter { $0.channel == .other }
        if others.count > 1, let worst = others.max(by: { $0.strain < $1.strain }) {
            out.removeAll { $0.channel == .other }; out.append(worst)
        }
        return out
    }

    private func title(_ kind: String) -> String {
        switch kind {
        case "session", "five_hour":     return "五小时窗口"
        case "weekly_all", "seven_day":  return "周窗口"
        case "seven_day_opus":           return "周 · Opus"
        case "seven_day_sonnet":         return "周 · Sonnet"
        default: break
        }
        var t = kind
            .replacingOccurrences(of: "seven_day", with: "周")
            .replacingOccurrences(of: "five_hour", with: "五小时")
            .replacingOccurrences(of: "_", with: " ")
        // The column that shows this is fixed width. Better a clipped name than a row that
        // shoves the number off the edge of the panel.
        if t.count > 10 { t = String(t.prefix(9)) + "…" }
        return t
    }

    private func loadCache() {
        guard !loaded else { return }; loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 3, let at = root["at"] as? Double,
              let rows = root["windows"] as? [[String: Any]] else { return }
        fetchedAt = Date(timeIntervalSince1970: at)
        guard fetchedAt! <= now() else { fetchedAt = nil; return }
        cache = rows.compactMap { r in
            guard let id = r["id"] as? String, let ch = r["channel"] as? Int,
                  let channel = Channel(rawValue: ch), let grader = (r["grader"] as? String).flatMap(QuotaWindow.Grader.init)
            else { return nil }
            let pct = r["percent"] as? Double
            guard pct == nil || (pct!.isFinite && pct! >= 0 && pct! <= 100) else { return nil }
            return QuotaWindow(id: id, provider: .claude, channel: channel, title: r["title"] as? String ?? "",
                               percent: pct, severity: Severity(word: r["severity"] as? String),
                               resetsAt: (r["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                               isActive: r["isActive"] as? Bool ?? false, observedAt: Date(timeIntervalSince1970: at),
                               gradedBy: grader, confirmedExhausted: r["exhausted"] as? Bool ?? false,
                               windowLength: channel == .session ? 5 * 3600
                                   : channel == .week ? 7 * 86400 : nil)
        }
    }

    private func saveCache() {
        let rows: [[String: Any]] = cache.map { w in
            var r: [String: Any] = ["id": w.id, "channel": w.channel.rawValue, "title": w.title,
                                    "severity": w.severity.rawValue, "grader": w.gradedBy.rawValue,
                                    "isActive": w.isActive, "exhausted": w.confirmedExhausted]
            if let p = w.percent { r["percent"] = p }
            if let at = w.resetsAt { r["resetsAt"] = at.timeIntervalSince1970 }
            return r
        }
        guard let at = fetchedAt, let data = try? JSONSerialization.data(withJSONObject:
            ["version": 3, "at": at.timeIntervalSince1970, "windows": rows]) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
