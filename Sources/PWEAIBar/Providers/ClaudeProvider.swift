import Foundation
import os

/// Account-bound, in-memory quota state. UI, history and retries never manufacture usage.
///
/// Claude Code's login is read here and nothing else: never renewed, never rewritten. How it is
/// read is `ClaudeCredentialStore`'s business; what an expired one means is `probe`'s.
actor ClaudeProvider {
    typealias Reading = (windows: [QuotaWindow], stale: Bool)
    struct Access {
        var own: () -> Credentials.Token?
        /// Claude Code's login, read and only read. `patient` means a person is waiting on the
        /// read and can answer a keychain question; a timer's read gives up on one in seconds.
        var load: (_ patient: Bool) throws -> [Credentials.Token]
        var save: (String) -> Credentials.SaveResult
        /// When Claude Code last wrote its login, from attributes alone. Nil means unknown, and
        /// unknown means read again rather than trust the last read.
        var stamp: () -> Date? = { nil }
        /// Whether Claude Code is on this Mac at all. Injectable so a test can state it.
        var claudeCodePresent: () -> Bool = Credentials.claudeCodePresent
        static let live = Access(own: Credentials.ownToken,
                                 load: { try ClaudeCredentialStore().load(patient: $0) },
                                 save: { Credentials.storeOwnToken($0) },
                                 stamp: { ClaudeCredentialStore().stamp() })
    }
    enum Blocker: Error, Equatable {
        case none, notLoggedIn, notInstalled, keychainRefused, unauthorized, forbidden, network
        /// Claude Code's login has run out. Carries when, if the record said.
        case expired(Date?)
        case invalidResponse, credentialsChanged
        case rateLimited(Date)
        var message: String {
            switch self {
            case .none: return L("blocker.ok", "Verified — the quota connection is working")
            case .notLoggedIn: return L("blocker.notLoggedIn", "No credential found — sign in to Claude Code")
            case .notInstalled: return L("blocker.notInstalled",
                                         "Claude Code is not installed on this Mac — install it from claude.ai/code")
            case .keychainRefused:
                // Not "the keychain has not authorised this app". Reading through the security
                // tool needs nothing granted to this app, so that sentence pointed at a button
                // that no longer exists. What can stop the read is a question macOS put to the
                // tool, and Claude Code meets the same question when it next reads its login.
                return L("blocker.unreadable",
                         "Claude Code's login could not be read — open Claude Code, and if macOS asks, "
                         + "choose Always Allow")
            case .expired(let at):
                // The remedy is whatever renews the login, and that is Claude Code, not this app.
                // The old sentence said to sign in again, which rebuilt a login that only needed
                // renewing.
                guard let at else {
                    return L("blocker.expired.open",
                             "The Claude Code login has expired — open Claude Code to restore it")
                }
                return String(format: L("blocker.expired.openDated",
                                        "The Claude Code login expired on %@ — open Claude Code to restore it"),
                              Blocker.stamp(at))
            case .unauthorized: return L("blocker.unauthorized", "The credential is no longer valid — sign in to Claude Code again or replace the manual token")
            case .forbidden: return L("blocker.forbidden", "This credential may not read quota — check the account's permissions or sign in again")
            case .network: return L("blocker.network", "No new reading just now — retrying automatically")
            case .invalidResponse: return L("blocker.invalidResponse", "The quota response was malformed — keeping the last reading and retrying")
            case .credentialsChanged: return L("blocker.credentialsChanged", "The login source changed or conflicts — confirm the current Claude Code login and retry")
            case .rateLimited: return L("blocker.rateLimited", "Rate limited — retrying on the server's schedule")
            }
        }

        /// In the reader's language. A fixed `zh_Hans_CN` locale put a Chinese month into the
        /// English sentence.
        static func stamp(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: Loc.isCJK ? "zh_Hans_CN" : "en")
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
            case .saved(let state): return L("token.saved", "Saved") + " · " + state.message
            case .cleared: return L("token.cleared", "Token cleared")
            case .failed(let code): return String(format: L("token.failed", "Keychain operation failed (%d) — try again"), code)
            }
        }
    }
    struct Details {
        var plan: String?
        /// The server's rate-limit tier. Separates Max 5× from Max 20×, which the plan name
        /// does not, and that difference is a factor of two in what the subscription costs.
        var tier: String?
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
    /// The read in flight, and whether a person asked for it.
    private var task: (work: Task<Reading, Never>, asked: Bool)?
    /// The last read of Claude Code's login, with the record's stamp when it was taken.
    private var lastRead: (tokens: [Credentials.Token], stamp: Date, at: Date)?
    private var rejected: [String: Blocker] = [:]
    private var retryNetworkAt: Date?
    private(set) var details = Details()
    private(set) var blocker: Blocker = .none
    var source: Credentials.Source { details.source }
    var loggedIn: Bool {
        switch blocker {
        case .notLoggedIn, .notInstalled, .expired, .unauthorized, .keychainRefused, .credentialsChanged: return false
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

    /// Blocking work, off the actor, with a budget. Running out of budget reads as a refusal: the
    /// work this guards is the keychain, and a read that never comes back is one nobody answered.
    private func offActor<T>(patience: TimeInterval = 15, _ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool { done.withLock { value in
                if value { return false }; value = true; return true
            } }
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try work() }
                if claim() { cont.resume(with: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + patience) {
                if claim() { cont.resume(throwing: Blocker.keychainRefused) }
            }
        }
    }

    /// How long a read of an unchanged record stands in for a fresh one.
    ///
    /// Reading the value launches the security tool; reading the record's stamp is an attribute
    /// query that cannot ask anything. So while the stamp says Claude Code has not written the
    /// record since, the last read is still the record, and a poll every twenty seconds need not
    /// launch a process to learn that. The bound covers a write inside the same second as the
    /// read before it, which a stamp with one-second grain cannot see.
    private static let rereadAfter: TimeInterval = 300

    private func candidates(asked: Bool, fresh: Bool = false) async throws -> [Credentials.Token] {
        let access = self.access
        if defaults.bool(forKey: "claudeManualTokenSelected") {
            return try await offActor { access.own().map { [$0] } ?? [] }
        }
        let stamp = try await offActor(access.stamp)
        if !asked, !fresh, let last = lastRead, last.stamp == stamp,
           now().timeIntervalSince(last.at) < Self.rereadAfter {
            return last.tokens
        }
        // A timer does not repeat a read that failed until the record changes or the wait is up.
        // A person asking is the exception, and the one read allowed to wait for an answer.
        if !asked, let until = unreadableUntil(stamp), until > now() {
            return try await standIn()
        }
        let tokens: [Credentials.Token]
        do {
            tokens = try await offActor(patience: asked ? 75 : 15) { try access.load(asked) }
        } catch let error where Self.refused(error) {
            noteUnreadable(stamp)
            lastRead = nil
            return try await standIn()
        }
        clearUnreadable()
        lastRead = stamp.map { (tokens, $0, now()) }
        // Nothing here renews an expired login, so a saved token stands in while there is one.
        // Without one, the expired login is still what gets reported: its message names the fix.
        let expired = !tokens.isEmpty && tokens.allSatisfy { $0.expiresAt.map { $0 <= now() } == true }
        if tokens.isEmpty || expired, let own = try await offActor(access.own) { return [own] }
        return tokens
    }

    /// A saved token when Claude Code's login cannot be read; otherwise, the plain fact.
    private func standIn() async throws -> [Credentials.Token] {
        if let own = try await offActor(access.own) { return [own] }
        throw Blocker.keychainRefused
    }

    // MARK: A read that failed

    /// When a timer may next try a read of Claude Code's login that failed.
    ///
    /// From here two causes look the same: the tool put a question on screen and was stopped
    /// before anyone answered, or securityd was slow. The first must not come back on a schedule —
    /// a dialog that returns every poll is the defect this app has shipped before — and the second
    /// should not stall the quota for a day. So the wait starts at a quarter of an hour and doubles
    /// each time an unchanged record fails again, up to four hours. A new stamp ends it at once:
    /// once Claude Code has written the record, whatever stopped the read may be gone. Kept in
    /// defaults, because this app gets relaunched and a relaunch is not news.
    private func unreadableUntil(_ stamp: Date?) -> Date? {
        let at = defaults.double(forKey: "claudeUnreadableAt")
        guard at > 0, defaults.object(forKey: "claudeUnreadableStamp") as? Double == stamp?.timeIntervalSince1970
        else { return nil }
        let failures = min(max(1, defaults.integer(forKey: "claudeUnreadableCount")), 8)
        let wait = min(15 * 60 * pow(2, Double(failures - 1)), 4 * 3600)
        return Date(timeIntervalSince1970: at).addingTimeInterval(wait)
    }

    private func noteUnreadable(_ stamp: Date?) {
        let again = defaults.double(forKey: "claudeUnreadableAt") > 0
            && defaults.object(forKey: "claudeUnreadableStamp") as? Double == stamp?.timeIntervalSince1970
        defaults.set(again ? defaults.integer(forKey: "claudeUnreadableCount") + 1 : 1, forKey: "claudeUnreadableCount")
        defaults.set(now().timeIntervalSince1970, forKey: "claudeUnreadableAt")
        defaults.set(stamp?.timeIntervalSince1970, forKey: "claudeUnreadableStamp")
    }

    private func clearUnreadable() {
        guard defaults.object(forKey: "claudeUnreadableAt") != nil else { return }
        for key in ["claudeUnreadableAt", "claudeUnreadableStamp", "claudeUnreadableCount"] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The tool refused or went unanswered, or the read as a whole ran out of budget.
    private static func refused(_ error: Error) -> Bool {
        if case ClaudeCredentialStore.Failure.denied = error { return true }
        return (error as? Blocker) == .keychainRefused
    }

    private func signature(_ tokens: [Credentials.Token]) -> String {
        ClaudeValue.fingerprint(Data(tokens.map(\.generation).joined(separator: ":").utf8))
    }

    private func adopt(_ signature: String, identity: String?) {
        guard generation != signature else { return }
        generation = signature
        // Keyed on *who* the credential belongs to, not on the bytes of the credential.
        //
        // `signature` fingerprints the whole document, so every renewal Claude Code performs
        // changes it, and with it every window's `observationKey`. Keyed on that, the sample ring
        // and every pending reset promise were orphaned by an event that is not a change of
        // account at all: the forecast fell back to the whole-window average, and the "you can
        // start again" alert was left waiting on a key nobody would write to again.
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

    /// `asked` is a person — the Refresh button, the menu's Refresh now — as opposed to a timer or
    /// a turn landing. Only that read retries one that failed, and only that read waits long
    /// enough for someone to answer macOS.
    func windows(force: Bool = false, asked: Bool = false) async -> Reading {
        // Join the read in flight, unless a person is asking and that read is a timer's: it gives
        // up on the keychain within seconds, and a failure it leaves behind is not retried for a
        // while. Someone who pressed Refresh gets a read of their own.
        while let running = task {
            if running.asked || !asked { return await running.work.value }
            _ = await running.work.value
            if task?.work == running.work { task = nil }
        }
        let version = revision
        let work = Task { await fetch(force: force || asked, asked: asked, version: version) }
        task = (work, asked)
        let result = await work.value
        if revision == version, task?.work == work { task = nil }
        return result
    }

    private func fetch(force: Bool, asked: Bool, version: Int, reloads: Int = 1) async -> Reading {
        do {
            let tokens = try await candidates(asked: asked)
            try check(version)
            let expected = signature(tokens)
            adopt(expected, identity: tokens.first?.accountKey)
            // "Not signed in" and "not here at all" need different advice, and one of them
            // cannot be followed: a Mac without Claude Code was told to run a command that
            // answers `command not found`.
            guard let first = tokens.first else {
                throw access.claudeCodePresent() ? Blocker.notLoggedIn : Blocker.notInstalled
            }
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
                    return try await probe(candidate, expected: expected, asked: asked, version: version)
                } catch let error as Blocker where error == .unauthorized || error == .forbidden
                                                     || error.isExpired {
                    rejected[candidate.generation] = error
                    lastFailure = error
                }
            }
            throw lastFailure
        } catch Blocker.credentialsChanged where reloads > 0 {
            return await fetch(force: force, asked: asked, version: version, reloads: reloads - 1)
        } catch {
            guard version == revision, !Task.isCancelled else { return staleReading() }
            let failure = classify(error)
            blocker = failure
            switch failure {
            case .unauthorized, .forbidden, .expired, .notLoggedIn, .notInstalled, .credentialsChanged:
                cache = []; details.spend = nil; details.plan = nil; details.tier = nil
                details.lastSuccessAt = nil
            case .network, .invalidResponse:
                retryNetworkAt = now().addingTimeInterval(60)
            default: break
            }
            return staleReading()
        }
    }

    private func probe(_ token: Credentials.Token, expected: String, asked: Bool,
                       version: Int) async throws -> Reading {
        // No renewal, however close the expiry. Renewing spends a refresh token Claude Code also
        // holds and returns the only copy of its replacement, so it is safe only for whoever can
        // store that replacement — and this app stores nothing. On 2026-09-08 three renewals here
        // could not be stored, and the login that machine's CLI shared had to be rebuilt by hand.
        // An expired login now waits for Claude Code to renew it, and the next read finds the
        // replacement where Claude Code put it.
        if let expiry = token.expiresAt, expiry <= now() { throw Blocker.expired(expiry) }
        details.source = token.source
        details.lastAttemptAt = now()
        let reply = try await request(ClaudeUsageClient.usage(token: token.value))
        try check(version)
        guard let http = reply.1 as? HTTPURLResponse else { throw Blocker.invalidResponse }
        // A 401 is often Claude Code having renewed while the request was out. Read the record
        // again before believing anything about the old token — past the saved read, since the
        // saved read is the old token.
        if http.statusCode == 401 {
            guard signature(try await candidates(asked: asked, fresh: true)) == expected else {
                throw Blocker.credentialsChanged
            }
            try check(version)
        }
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
        details.plan = token.plan; details.tier = token.rateLimitTier
        details.spend = mapped.spend; details.lastSuccessAt = now()
        details.source = token.source
        blocker = .none; retryNetworkAt = nil
        return (cache, cache.contains(where: \.isStale))
    }

    private func check(_ version: Int) throws {
        guard revision == version, !Task.isCancelled else { throw CancellationError() }
    }

    private func checkHTTP(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            // Refusals in a row, kept across launches like the deadline itself. Without it a
            // 429 with no Retry-After waited five minutes, asked, was refused, and waited five
            // minutes again — all day, at the one endpoint that punishes asking.
            let streak = defaults.integer(forKey: "quotaRateLimitStreak")
            let until = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now(),
                                       streak: streak)
            defaults.set(streak + 1, forKey: "quotaRateLimitStreak")
            retryAfter = until
            throw Blocker.rateLimited(until)
        }
        if (200..<300).contains(response.statusCode) { defaults.removeObject(forKey: "quotaRateLimitStreak") }
        if response.statusCode == 401 { throw Blocker.unauthorized }
        if response.statusCode == 403 { throw Blocker.forbidden }
        if response.statusCode >= 500 { throw Blocker.network }
        guard (200..<300).contains(response.statusCode) else { throw Blocker.invalidResponse }
    }

    private func classify(_ error: Error) -> Blocker {
        if let error = error as? Blocker { return error }
        if let error = error as? ClaudeCredentialStore.Failure {
            switch error {
            case .denied: return .keychainRefused
            case .ambiguous: return .credentialsChanged
            case .malformed: return .invalidResponse
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
        revision += 1; task?.work.cancel(); task = nil; lastRead = nil
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
                w.percent = nil; w.severity = .normal
                w.note = L("note.unconfirmed", "unconfirmed"); w.confirmedExhausted = false
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

    /// When to ask again after a 429. The server's own `Retry-After` wins whenever it gives one;
    /// without it the wait doubles with each refusal in a row — 5, 10, 20, then 40 minutes, and
    /// no further — rather than knocking every five minutes on a door that keeps saying no.
    nonisolated static func retryDate(_ header: String?, now: Date, streak: Int = 0) -> Date {
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
        return now.addingTimeInterval(300 * pow(2, Double(min(max(streak, 0), 3))))
    }
}
