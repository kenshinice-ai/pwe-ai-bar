import Foundation
import os

/// Account-bound, in-memory quota state. UI, history and retries never manufacture usage.
actor ClaudeProvider {
    typealias Reading = (windows: [QuotaWindow], stale: Bool)
    struct Access {
        var own: () -> Credentials.Token?
        var claudeCode: () -> Credentials.Token?
        var sharedExists: () -> Bool
        var shared: () -> Credentials.Token?
        var save: (String) -> Credentials.SaveResult
        var load: (() throws -> [Credentials.Token])? = nil
        var persist: ((Credentials.Token, Credentials.Token) throws -> Bool)? = nil
        static let live = Access(own: Credentials.ownToken, claudeCode: { Credentials.claudeCodeCredential() },
                                 sharedExists: Credentials.sharedItemExists, shared: Credentials.readShared,
                                 save: { Credentials.storeOwnToken($0) },
                                 load: { try ClaudeCredentialStore().load() },
                                 persist: { try ClaudeCredentialStore().save($0, expected: $1) })
    }
    enum Blocker: Error, Equatable {
        case none, needsSetup, notLoggedIn, keychainRefused, unauthorized, forbidden, network
        /// The login is beyond renewal. Carries when the refresh token died, when the record
        /// said so — the date is the difference between "何时" and a shrug.
        case expired(Date?)
        case storage, invalidResponse, credentialsChanged
        case rateLimited(Date)
        var message: String {
            switch self {
            case .none: return "已验证，额度连接正常"
            case .needsSetup: return "未能读取登录凭据，可在设置中重新连接"
            case .notLoggedIn: return "未找到凭据，请登录 Claude Code"
            case .keychainRefused: return "钥匙串访问失败或超时，请在设置中重新连接"
            case .expired(let at):
                // Naming the date and the command is the whole improvement. "凭据已失效" is true
                // and leaves the reader with nothing to do; this sentence ends in something they
                // can paste. `claude auth login` is what rewrites the record the app reads.
                guard let at else { return "登录已过期且无法续期 · 在终端运行 claude auth login" }
                return "Claude Code 的登录已在 \(Blocker.stamp(at)) 过期 · 在终端运行 claude auth login"
            case .unauthorized: return "凭据已失效，请重新登录 Claude Code 或更换手动令牌"
            case .forbidden: return "凭据无权读取额度，请检查账户权限或重新登录"
            case .network: return "暂时无法获取新读数，稍后自动重试"
            case .storage: return "续期凭据未能安全保存，请在 Claude Code 重新登录"
            case .invalidResponse: return "额度响应格式异常，保留上次读数，稍后重试"
            case .credentialsChanged: return "登录来源发生变化或冲突，请确认当前 Claude Code 登录后重试"
            case .rateLimited: return "接口限流中，将按服务端时间重试"
            }
        }

        private static func stamp(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_Hans_CN")
            f.setLocalizedDateFormatFromTemplate("MMMdHHmm")
            return f.string(from: date)
        }

        var isExpired: Bool { if case .expired = self { return true }; return false }
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
    struct Details {
        var plan: String?
        var spend: ClaudeSpend?
        var lastSuccessAt: Date?
        var lastAttemptAt: Date?
        var source: Credentials.Source = .none
    }
    private let defaults: UserDefaults
    private let access: Access
    private let request: (URLRequest) async throws -> (Data, URLResponse)
    private let now: () -> Date
    private var cache: [QuotaWindow] = []
    private var generation: String?
    private var historyNamespace: String?
    private var revision = 0
    private var task: Task<Reading, Never>?
    private var rejected: [String: Blocker] = [:]
    private var retryNetworkAt: Date?
    private(set) var details = Details()
    private(set) var blocker: Blocker = .none
    var source: Credentials.Source { details.source }
    var loggedIn: Bool {
        switch blocker {
        case .notLoggedIn, .needsSetup, .expired, .unauthorized, .keychainRefused, .credentialsChanged, .storage: return false
        default: return true
        }
    }

    // cacheURL/fallback remain source-compatible with diagnostic/test callers. Legacy quota
    // caches are deliberately neither read nor written: they cannot identify their account.
    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, access: Access = .live,
         now: @escaping () -> Date = Date.init,
         request: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await ClaudeUsageClient.shared.send($0) },
         fallback: @escaping () -> (resetsAt: Date, kind: String)? = { nil }) {
        self.defaults = defaults; self.access = access; self.now = now; self.request = request
    }

    private var retryAfter: Date? {
        get {
            let n = defaults.double(forKey: "quotaRetryAfter")
            guard n.isFinite else { return nil }
            let date = Date(timeIntervalSince1970: n)
            return date > now() ? date : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "quotaRetryAfter") }
    }

    private func offActor<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool { done.withLock { value in
                if value { return false }; value = true; return true
            } }
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try work() }
                if claim() { cont.resume(with: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                if claim() { cont.resume(throwing: Blocker.keychainRefused) }
            }
        }
    }

    private func candidates() async throws -> [Credentials.Token] {
        let access = self.access
        if defaults.bool(forKey: "claudeManualTokenSelected") {
            return try await offActor { access.own().map { [$0] } ?? [] }
        }
        var tokens: [Credentials.Token]
        do {
            if let load = access.load { tokens = try await offActor(load) }
            else { tokens = try await offActor { access.claudeCode().map { [$0] } ?? [] } }
        } catch {
            if defaults.bool(forKey: "sharedKeychainOptIn"), let shared = try await offActor(access.shared) { return [shared] }
            throw error
        }
        let unrefreshable = !tokens.isEmpty && tokens.allSatisfy {
            $0.expiresAt.map { $0 <= now() } == true && $0.refreshToken == nil
        }
        if tokens.isEmpty || unrefreshable {
            if let own = try await offActor(access.own) { return [own] }
            if defaults.bool(forKey: "sharedKeychainOptIn"), !defaults.bool(forKey: "keychainRefused") {
                if let shared = try await offActor(access.shared) { return [shared] }
            }
        }
        return tokens
    }

    private func signature(_ tokens: [Credentials.Token]) -> String {
        ClaudeValue.fingerprint(Data(tokens.map(\.generation).joined(separator: ":").utf8))
    }

    private func adopt(_ signature: String, identity: String?) {
        guard generation != signature else { return }
        generation = signature
        // Keyed on *who* the credential belongs to, not on the bytes of the credential.
        //
        // `signature` fingerprints the whole document, so a routine access-token rotation —
        // which Claude Code performs roughly hourly under load, and which this app now performs
        // itself — changed it, and with it every window's `observationKey`. The sample ring and
        // every pending reset promise were orphaned once an hour by an event that is not a
        // change of account at all: the forecast fell back to the whole-window average, and the
        // "you can start again" alert was left waiting on a key nobody would write to again.
        //
        // `accountKey` is the fingerprint of account uuid + organisation uuid that `sameIdentity`
        // already trusts to decide whether two credentials are the same person. Nil when the
        // document carries no identity, which puts the keys back to their bare form — stable,
        // and no worse than before accounts were separated at all.
        historyNamespace = identity
        cache = []; details = Details(); retryNetworkAt = nil
        // Rejected generations are only needed until discovery changes; bounded to one set.
        rejected = [:]
    }

    func windows(force: Bool = false) async -> Reading {
        if let task { return await task.value }
        let version = revision
        let fresh = Task { await fetch(force: force, version: version) }
        task = fresh
        let result = await fresh.value
        if revision == version { task = nil }
        return result
    }

    private func fetch(force: Bool, version: Int, reloads: Int = 1) async -> Reading {
        do {
            let tokens = try await candidates()
            try check(version)
            let expected = signature(tokens)
            adopt(expected, identity: tokens.first?.accountKey)
            guard let first = tokens.first else { throw Blocker.notLoggedIn }
            if let until = retryAfter { throw Blocker.rateLimited(until) }
            if !force, let retryNetworkAt, retryNetworkAt > now() { return staleReading() }
            if !force, blocker == .none, let success = details.lastSuccessAt,
               now().timeIntervalSince(success) < ttl(),
               !cache.contains(where: { $0.resetsAt.map { $0 <= now() } ?? false }) {
                return (cache, cache.contains(where: \.isStale))
            }
            var lastFailure: Blocker = .unauthorized
            for candidate in tokens {
                // A second source must prove it belongs to the same identity. Unknown sources
                // can be selected by logging into the intended CLI or saving a manual token.
                if candidate.generation != first.generation, !sameIdentity(first, candidate) {
                    lastFailure = .credentialsChanged; continue
                }
                do {
                    guard candidate.hasUsageScope else { throw Blocker.forbidden }
                    if let error = rejected[candidate.generation] { throw error }
                    return try await probe(candidate, all: tokens, expected: expected, version: version)
                } catch let error as Blocker where error == .unauthorized || error == .forbidden
                                                     || error.isExpired {
                    rejected[candidate.generation] = error
                    lastFailure = error
                }
            }
            throw lastFailure
        } catch Blocker.credentialsChanged where reloads > 0 {
            return await fetch(force: force, version: version, reloads: reloads - 1)
        } catch {
            guard version == revision, !Task.isCancelled else { return staleReading() }
            let failure = classify(error)
            blocker = failure
            switch failure {
            case .unauthorized, .forbidden, .expired, .notLoggedIn, .storage, .credentialsChanged:
                cache = []; details.spend = nil; details.plan = nil; details.lastSuccessAt = nil
            case .network, .invalidResponse:
                retryNetworkAt = now().addingTimeInterval(60)
            default: break
            }
            return staleReading()
        }
    }

    private func probe(_ original: Credentials.Token, all: [Credentials.Token], expected: String,
                       version: Int) async throws -> Reading {
        var token = original
        var current = all
        var expected = expected
        var rotated = false
        if let expiry = token.expiresAt, expiry.timeIntervalSince(now()) <= 300,
           token.refreshToken != nil, access.persist != nil {
            token = try await rotate(token, expected: expected, version: version)
            rotated = true
            current = all.map { $0.generation == original.generation ? token : $0 }
            expected = signature(current)
            generation = expected
        }
        if let expiry = token.expiresAt, expiry <= now() { throw Blocker.expired(expiryToReport(token)) }
        details.source = token.source
        details.lastAttemptAt = now()
        var reply = try await request(ClaudeUsageClient.usage(token: token.value))
        try check(version)
        guard var http = reply.1 as? HTTPURLResponse else { throw Blocker.invalidResponse }
        if http.statusCode == 401 {
            // The CLI may already have replaced the source; adopt it before rotating anything.
            guard signature(try await candidates()) == expected else { throw Blocker.credentialsChanged }
            try check(version)
            if !rotated, token.refreshToken != nil, access.persist != nil {
                token = try await rotate(token, expected: expected, version: version)
                current = current.map { $0.generation == original.generation ? token : $0 }
                expected = signature(current); generation = expected
                reply = try await request(ClaudeUsageClient.usage(token: token.value))
                try check(version)
                guard let retried = reply.1 as? HTTPURLResponse else { throw Blocker.invalidResponse }
                http = retried
            }
        }
        // The preferred source may have changed even though this request succeeded.
        guard signature(try await candidates()) == expected else { throw Blocker.credentialsChanged }
        try check(version)
        do { try checkHTTP(http) }
        catch let failure as Blocker {
            if failure == .unauthorized || failure == .forbidden { rejected[token.generation] = failure }
            throw failure
        }
        guard reply.0.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any] else { throw Blocker.invalidResponse }
        let mapped = try ClaudeUsageMapper.map(root, at: now())
        cache = mapped.windows.map { value in
            var w = value
            w.observationNamespace = historyNamespace ?? token.generation
            return w
        }
        details.plan = token.plan; details.spend = mapped.spend; details.lastSuccessAt = now()
        details.source = token.source
        blocker = .none; retryNetworkAt = nil
        return (cache, cache.contains(where: \.isStale))
    }

    /// A record of our own token refreshes, kept because the alternative is guesswork.
    ///
    /// Claude Code writes the same keychain item this app does, and the rotation deliberately
    /// preserves every field it does not own — so after the fact the credential itself cannot
    /// say which of the two rewrote it. Twice now that question has mattered and twice the
    /// honest answer was "cannot tell". This is the app stating, in its own store, what it did
    /// and when. A timestamp, an outcome and a count: no token, no account, no server body.
    /// `success` is a parameter rather than a comparison against the outcome string, because
    /// the string is display copy: it is printed, in Chinese, next to every failure phrase.
    /// Deciding "did it work" by matching it against the literal `"saved"` entangled the counter
    /// with the wording, so the first time anyone rephrased the success line the tally would
    /// have silently stopped — and the line was the only English word in a Chinese readout.
    private func note(_ outcome: String, success: Bool = false) {
        defaults.set(now().timeIntervalSince1970, forKey: "claudeRefreshAt")
        defaults.set(outcome, forKey: "claudeRefreshOutcome")
        if success {
            defaults.set(defaults.integer(forKey: "claudeRefreshCount") + 1, forKey: "claudeRefreshCount")
        }
    }

    nonisolated static func refreshRecord(_ d: UserDefaults = .standard)
        -> (at: Date, outcome: String, count: Int)? {
        let stamp = d.double(forKey: "claudeRefreshAt")
        guard stamp > 0 else { return nil }
        return (Date(timeIntervalSince1970: stamp),
                d.string(forKey: "claudeRefreshOutcome") ?? "未知",
                d.integer(forKey: "claudeRefreshCount"))
    }

    /// Exchanges in flight, keyed by the credential each one started from.
    ///
    /// A refresh token is single-use in the worst case: present it twice and the second attempt
    /// is `invalid_grant`, and by then the first attempt's replacement may be the only working
    /// credential in existence. Two concurrent fetches can otherwise both reach the exchange
    /// with the same token — `invalidate()` clears the memoised fetch and cancels it, but a
    /// cancelled task is not a stopped one, so the next `windows()` starts a second fetch that
    /// happily spends the same refresh token again. The second caller joins the first exchange
    /// instead of racing it.
    private var rotations: [String: Task<Credentials.Token, Error>] = [:]

    /// The expiry date it is honest to put in front of the reader, or nil.
    ///
    /// `refreshTokenExpiresAt` describes the refresh token Claude Code wrote. `rotated` rewrites
    /// `accessToken`, `refreshToken` and `expiresAt` but deliberately not this field — invariant
    /// one forbids reshaping a record we co-own — so once this app has swapped a token, the date
    /// on disk may belong to a refresh token that no longer exists. Naming a date we cannot vouch
    /// for is worse than naming none: the reader would go looking for what happened that day.
    private func expiryToReport(_ token: Credentials.Token) -> Date? {
        defaults.integer(forKey: "claudeRefreshCount") == 0 ? token.refreshExpiresAt : nil
    }

    private func rotate(_ token: Credentials.Token, expected: String, version: Int) async throws -> Credentials.Token {
        guard let refresh = token.refreshToken, let persist = access.persist
        else { throw Blocker.expired(expiryToReport(token)) }

        // 1.0.1 also skipped the exchange outright when `refreshTokenExpiresAt` had passed. That
        // is gone, and three separate reasons say it should be:
        //
        //   * it was gated on `claudeRefreshCount == 0`, a global counter that only ever goes up
        //     and is never reset — so the skip was unreachable on any install that had rotated
        //     even once, which is every install more than an hour old;
        //   * it ran ahead of the signature check below, so a reader who had just fixed their
        //     login with `claude auth login` was told "已过期" for another poll instead of the
        //     mismatch being caught and re-read within the same cycle;
        //   * it called `note()` on a path where no exchange happened, once per poll, which
        //     overwrites the one record that says a write-back failed.
        //
        // Saving a round-trip was always the minor half of that idea. The half worth keeping is
        // telling the reader the date, and that needs no gate — see `expiryToReport`.
        guard signature(try await candidates()) == expected else { throw Blocker.credentialsChanged }
        try check(version)

        // This is the last cancellation check before the exchange, and the exchange itself runs
        // in an unstructured task on purpose: an unstructured `Task` does not inherit
        // cancellation, so once the POST has started, nothing can stop it from running through
        // to the write-back.
        //
        // That matters more than it looks. `invalidate()` — the reader tapping 「重新连接」 or
        // saving a manual token — cancels the in-flight fetch, and URLSession honours
        // cancellation: the refresh POST would be torn down mid-flight. If the server had
        // already rotated the refresh token by then, its replacement arrives in a response
        // nobody is listening for, Claude Code's stored copy is dead, and the reader is logged
        // out of their own CLI by a settings tap. Losing interest in the *reading* must not be
        // able to abandon the *credential*.
        //
        // `await work.value` is not a cancellation point, so this waits for the exchange to
        // finish either way; the caller can be told the reading was cancelled afterwards.
        if let inFlight = rotations[token.generation] { return try await inFlight.value }
        let work = Task { try await self.exchange(token, refresh: refresh, persist: persist) }
        rotations[token.generation] = work
        defer { rotations[token.generation] = nil }
        let fresh = try await work.value
        // Now that the replacement is safely on disk, losing interest is free again.
        try check(version)
        return fresh
    }

    /// The exchange and the write-back, as one unit that always completes.
    private func exchange(_ token: Credentials.Token, refresh: String,
                          persist: @escaping (Credentials.Token, Credentials.Token) throws -> Bool)
        async throws -> Credentials.Token {
        let (data, response) = try await request(ClaudeUsageClient.refresh(token: refresh))
        guard let http = response as? HTTPURLResponse else { throw Blocker.invalidResponse }
        if http.statusCode == 400 || http.statusCode == 401 {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if body?["error"] as? String == "invalid_grant" || http.statusCode == 401 {
                note("凭据已失效"); throw Blocker.expired(expiryToReport(token))
            }
            rejected[token.generation] = .invalidResponse
            note("换发被拒 \(http.statusCode)")
            throw Blocker.invalidResponse
        }
        try checkHTTP(http)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Blocker.invalidResponse }
        let rotated: Credentials.Token
        do { rotated = try ClaudeCredentialStore.rotated(token, response: object, now: now()) }
        catch {
            rejected[token.generation] = .invalidResponse
            note("回复看不懂"); throw Blocker.invalidResponse
        }
        // Nothing between the response and the write below re-reads the credential or checks
        // for cancellation. The re-read that used to sit here was redundant with the store's own
        // compare-and-swap — `save(_:expected:)` reads the record again and refuses to write
        // unless it still matches, which is the check that actually protects against the CLI
        // changing it underneath us. Cancellation is not a concurrent change; it is us losing
        // interest, and losing interest must not cost anyone their login.
        let saved: Bool
        do { saved = try await offActor { try persist(rotated, token) } }
        catch {
            rejected[token.generation] = .storage
            // The dangerous one, and the reason it is recorded rather than merely thrown: the
            // exchange has already happened, so if the server rotated the refresh token then
            // the copy Claude Code still holds may now be dead. Nothing here can undo that; the
            // least the app can do is leave a note saying it is what happened.
            note("换到了但写不回去"); throw Blocker.storage
        }
        guard saved else { note("写回时凭据已被改动"); throw Blocker.credentialsChanged }
        note("已续期", success: true)
        return rotated
    }

    private func check(_ version: Int) throws {
        guard revision == version, !Task.isCancelled else { throw CancellationError() }
    }

    private func checkHTTP(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            let until = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            retryAfter = until
            throw Blocker.rateLimited(until)
        }
        if response.statusCode == 401 { throw Blocker.unauthorized }
        if response.statusCode == 403 { throw Blocker.forbidden }
        if response.statusCode >= 500 { throw Blocker.network }
        guard (200..<300).contains(response.statusCode) else { throw Blocker.invalidResponse }
    }

    private func classify(_ error: Error) -> Blocker {
        if let error = error as? Blocker { return error }
        if let error = error as? ClaudeCredentialStore.Failure {
            switch error {
            case .denied:
                // Latched, and only here. A refusal is a decision the reader made, and asking
                // again every five minutes for the rest of the day is how an app teaches people
                // to click Deny on reflex. The timeout path throws the same blocker and must
                // *not* latch — a keychain that was slow once is not a keychain that said no.
                // 设置 → 重新连接 clears it (`enableSharedKeychain`).
                defaults.set(true, forKey: "keychainRefused")
                return .keychainRefused
            case .ambiguous, .changed: return .credentialsChanged
            case .malformed: return .invalidResponse
            case .storage: return .storage
            }
        }
        if error is ClaudeUsageMapper.Failure { return .invalidResponse }
        return .network
    }

    private func sameIdentity(_ a: Credentials.Token, _ b: Credentials.Token) -> Bool {
        if let first = a.accountKey, let second = b.accountKey { return first == second }
        if let refresh = a.refreshToken, refresh == b.refreshToken { return true }
        return a.value == b.value
    }

    func enableSharedKeychain() {
        defaults.set(true, forKey: "sharedKeychainOptIn")
        defaults.set(false, forKey: "keychainRefused")
        defaults.set(false, forKey: "claudeManualTokenSelected")
        invalidate()
    }

    func useOwnToken(_ raw: String) async -> TokenUpdate {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let save = access.save
        let result: Credentials.SaveResult
        do { result = try await offActor { save(value) } }
        catch { return .failed(-1) }
        switch result {
        case .failed(let code): return .failed(code)
        case .cleared:
            defaults.set(false, forKey: "claudeManualTokenSelected"); invalidate(); return .cleared
        case .saved:
            defaults.set(true, forKey: "claudeManualTokenSelected"); invalidate()
            _ = await windows(force: true)
            return .saved(blocker)
        }
    }

    private func invalidate() {
        revision += 1; task?.cancel(); task = nil
        generation = nil; cache = []; details = Details()
        rejected = [:]; retryNetworkAt = nil; blocker = .none
    }

    /// How long the last reading stays good for.
    ///
    /// This used to shorten as the situation got worse: sixty seconds the moment any window
    /// went hot, or a reset came within a quarter of an hour. That is the wrong instinct
    /// wearing the clothes of diligence, and it cost a day of readings.
    ///
    /// A window that is spent has one thing left to say and it has already said it — the reset
    /// time, which is a fact in hand, not a number to go and re-read. Polling it every minute
    /// learns nothing and spends the only budget that matters: this endpoint answers "how much
    /// is left", and asking 1,440 times a day is how the app collected an hour-long Retry-After
    /// and then showed a figure that was thirty-three hours old. Hardest polling, at exactly
    /// the moment its reader cared most, producing the least information it has ever produced.
    ///
    /// So the cadence follows whether the number *can* have moved, not how alarming it looks:
    /// a spent window waits for its own rollover and adds a beat; an imminent reset is worth
    /// catching promptly, and two minutes is prompt; everything else is five minutes, which the
    /// event loop shortens on its own the moment a turn actually lands.
    private func ttl() -> TimeInterval {
        let soon = cache.compactMap(\.resetsAt).map { $0.timeIntervalSince(now()) }
            .filter { $0 > 0 }.min() ?? .infinity
        if cache.contains(where: \.confirmedExhausted) { return max(60, min(soon + 20, 900)) }
        if soon < 300 { return 120 }
        return 300
    }

    private func staleReading() -> Reading {
        (cache.map { value in
            var w = value; w.isStale = true
            if let reset = w.resetsAt, reset <= now() {
                w.percent = nil; w.severity = .normal; w.note = "待确认"; w.confirmedExhausted = false
            }
            return w
        }, true)
    }

    func parse(_ root: [String: Any]) -> [QuotaWindow] {
        (try? ClaudeUsageMapper.map(root, at: now()).windows) ?? []
    }
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


}
