import Foundation
import os

/// Claude Code's quota, read from the same OAuth endpoint the `/usage` command uses.
///
/// Two things shape this file. First, the token: it comes from `Credentials`, is sent only to
/// `api.anthropic.com`, and never reaches a log or a plain file — a long-lived token is stored,
/// but in a keychain item this app owns, never on disk. Second, the endpoint is rate-limited
/// hard, so the cache and a strict `Retry-After` are not optimisations here; they are the
/// difference between working and being locked out for the next hour.
///
/// Parsing is driven by the response's `limits[]` array rather than its named fields. The
/// payload already carries a row of buckets that are null today — per-model weeklies, extra
/// usage, several unlaunched names. Reading the array means the interface grows a line the day
/// one of them starts reporting, with no code change; reading `five_hour` and `seven_day` by
/// name would mean shipping a build for each.
actor ClaudeProvider {

    private var cache: [QuotaWindow] = []
    private var fetchedAt: Date?
    private var loadedFromDisk = false

    /// The last good response, kept between launches.
    ///
    /// Without it every fresh process starts with an empty cache and fires a request
    /// immediately — which is exactly how a few relaunches in a row earn a 429 from an endpoint
    /// that is rate-limited hard. It also means the panel shows real figures the instant it
    /// opens rather than after a round trip.
    private static var diskCache: URL {
        // `.first` rather than `[0]`: the array is never empty in practice, but a cache path
        // is not worth a trap if it ever is.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("PWE AI Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quota-cache.json")
    }

    private func loadCache() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.diskCache),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = root["at"] as? Double,
              let rows = root["windows"] as? [[String: Any]] else { return }
        fetchedAt = Date(timeIntervalSince1970: at)
        cache = rows.compactMap { r in
            guard let id = r["id"] as? String, let ch = r["channel"] as? Int,
                  let channel = Channel(rawValue: ch) else { return nil }
            return QuotaWindow(
                id: id, provider: .claude, channel: channel,
                title: r["title"] as? String ?? "",
                percent: r["percent"] as? Double,
                severity: Severity(word: r["severity"] as? String),
                resetsAt: (r["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                isActive: r["isActive"] as? Bool ?? false,
                observedAt: Date(timeIntervalSince1970: at),
                gradedBy: .server)
        }
        // A window whose reset has already passed is not news, it is yesterday's high.
        cache.removeAll { w in w.resetsAt.map { $0 < Date() } ?? false }
    }

    private func saveCache() {
        let rows: [[String: Any]] = cache.map { w in
            var r: [String: Any] = ["id": w.id, "channel": w.channel.rawValue,
                                    "title": w.title, "severity": w.severity.rawValue,
                                    "isActive": w.isActive]
            if let p = w.percent { r["percent"] = p }
            if let d = w.resetsAt { r["resetsAt"] = d.timeIntervalSince1970 }
            return r
        }
        let root: [String: Any] = ["at": Date().timeIntervalSince1970, "windows": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: Self.diskCache, options: .atomic)
    }
    /// Persisted, because a 429 from this endpoint can last the better part of an hour and a
    /// relaunch would otherwise walk straight back into it — which is how a fifty-three minute
    /// block got earned in the first place. Kept in defaults rather than the cache file so it
    /// survives someone clearing the cache to force a refresh.
    private var retryAfter: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "quotaRetryAfter")
            guard t > 0 else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return d > Date() ? d : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0,
                                      forKey: "quotaRetryAfter")
        }
    }
    /// Why we have no Claude numbers, when we have none. The panel needs to tell the
    /// difference: "log in" and "grant keychain access" are different problems with different
    /// fixes, and "读不到额度" helps with neither.
    enum Blocker: Equatable {
        case none
        case needsSetup           // never asked yet — we do not raise a dialog uninvited
        case notLoggedIn          // no credential in the keychain at all
        case keychainRefused      // the item is there, macOS will not let us read it
        case expired              // token past its expiry; opening Claude Code refreshes it
        case rateLimited(Date)    // 429; showing the last good numbers until then
    }

    private(set) var loggedIn = false
    private(set) var blocker: Blocker = .none

    private let ttl: TimeInterval = 60

    // MARK: Credential

    /// Persisted across launches. Without it, a dialog the user closed once comes back on every
    /// launch forever — which is the single most common reason people delete a menu-bar app.
    private var refusedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "keychainRefused") }
        set { UserDefaults.standard.set(newValue, forKey: "keychainRefused") }
    }

    /// Whether the user has ever said yes to reading Claude Code's credential.
    ///
    /// The app does not touch the shared item until they do. An access dialog that appears on
    /// its own, seconds after first launch, for reasons the user has not been told, is the most
    /// alarming thing a small menu-bar app can do — and it arrives before anything has had a
    /// chance to explain why it is needed. So the first run shows local figures and a button,
    /// and the dialog only ever appears as the direct result of pressing it.
    private var sharedAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "sharedKeychainOptIn") }
        set { UserDefaults.standard.set(newValue, forKey: "sharedKeychainOptIn") }
    }

    /// Order matters. Our own long-lived token can never raise a dialog, so it is tried first
    /// and, when present, the shared item is never touched at all.
    private func token() async -> Credentials.Token? {
        if let own = Credentials.ownToken() { return own }
        guard sharedAllowed else {
            blocker = Credentials.sharedItemExists() ? .needsSetup : .notLoggedIn
            return nil
        }
        guard !refusedBefore else {
            blocker = .keychainRefused        // asked, declined; say so instead of going quiet
            return nil
        }
        return await sharedWithTimeout()
    }

    /// The shared read blocks its thread for as long as macOS shows the access dialog, and if
    /// nobody is at the machine that is forever.
    ///
    /// Two earlier attempts at a timeout both hung, and the second is the instructive one.
    /// Racing the read against a sleep in a `withTaskGroup` looks right and cannot work: the
    /// group does not return until *every* child finishes, `cancelAll()` has no effect on a
    /// synchronous `SecItemCopyMatching` already in flight, so the group sits waiting on the
    /// loser it was meant to abandon. (The first attempt was worse still — both children shared
    /// this actor's executor, so the blocking read owned it and the timer never ran.)
    ///
    /// So: no task group. Two queues race to resume one continuation, a lock decides who won,
    /// and the loser is simply never waited on.
    private func sharedWithTimeout() async -> Credentials.Token? {
        let result: Credentials.Token?? = await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool {
                resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let t = Credentials.readShared()
                if claim() { cont.resume(returning: .some(t)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                if claim() { cont.resume(returning: .none) }   // outer nil: never answered
            }
        }

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
            if Credentials.sharedItemExists() {
                refusedBefore = true
                blocker = .keychainRefused
            } else {
                blocker = .notLoggedIn
            }
            return nil
        }
        return t
    }

    /// The user has asked for the real numbers, which is the only thing that puts the access
    /// dialog on screen. Called from the panel's button and from Settings.
    func enableSharedKeychain() {
        sharedAllowed = true
        refusedBefore = false
        blocker = .none
        fetchedAt = nil
    }

    func useOwnToken(_ value: String) {
        Credentials.storeOwnToken(value.trimmingCharacters(in: .whitespacesAndNewlines))
        blocker = .none
        fetchedAt = nil
    }

    var source: Credentials.Source {
        if Credentials.hasOwnToken { return .ownToken }
        return loggedIn ? .sharedKeychain : Credentials.Source.none
    }

    // MARK: Fetch

    func windows() async -> (windows: [QuotaWindow], stale: Bool) {
        loadCache()
        if let at = fetchedAt, Date().timeIntervalSince(at) < ttl, !cache.isEmpty {
            return (cache, false)
        }
        if let r = retryAfter {
            blocker = .rateLimited(r)
            return (cache, true)
        }

        guard let cred = await token() else {
            loggedIn = false
            return (cache.isEmpty ? offline() : cache, true)
        }
        if let e = cred.expiresAt, e < Date() {
            // Expired: opening Claude Code refreshes it. Say so rather than sending a token we
            // already know will bounce. A long-lived token has no expiry and never lands here.
            blocker = .expired
            loggedIn = false
            return (cache.isEmpty ? offline() : cache, true)
        }
        loggedIn = true

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(cred.value)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (cache, true) }

            if http.statusCode == 429 {
                let after = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                let until = Date().addingTimeInterval(after)
                retryAfter = until
                blocker = .rateLimited(until)
                return (cache.isEmpty ? offline() : cache, true)
            }
            guard http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return (cache.isEmpty ? offline() : cache, true) }

            retryAfter = nil
            blocker = .none
            cache = parse(root)
            fetchedAt = Date()
            saveCache()
            return (cache, false)
        } catch {
            return (cache.isEmpty ? offline() : cache, true)
        }
    }

    // MARK: Parse

    private func parse(_ root: [String: Any]) -> [QuotaWindow] {
        var out: [QuotaWindow] = []

        if let limits = root["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String else { continue }
                let group = l["group"] as? String ?? ""
                let channel: Channel
                switch (kind, group) {
                case ("session", _):     channel = .session
                case ("weekly_all", _):  channel = .week
                case (_, "weekly"):      channel = .other      // per-model weeklies, when they arrive
                default:                 continue
                }
                let pct = (l["percent"] as? NSNumber)?.doubleValue
                out.append(QuotaWindow(
                    id: kind,
                    provider: .claude,
                    channel: channel,
                    title: title(kind),
                    percent: pct,
                    severity: Severity(word: l["severity"] as? String),
                    resetsAt: (l["resets_at"] as? String).flatMap(ISO8601DateFormatter.parse),
                    isActive: (l["is_active"] as? Bool) ?? false,
                    gradedBy: (l["severity"] as? String) != nil ? .server : .local
                ))
            }
        }

        // Named fields as the backstop, only for channels the array did not cover.
        for (key, channel) in [("five_hour", Channel.session), ("seven_day", Channel.week)]
        where !out.contains(where: { $0.channel == channel }) {
            guard let n = root[key] as? [String: Any],
                  let pct = (n["utilization"] as? NSNumber)?.doubleValue else { continue }
            out.append(QuotaWindow(
                id: key, provider: .claude, channel: channel, title: title(key),
                percent: pct,
                severity: Health.grade(pct, warm: channel.warm, hot: channel.hot) == .hot
                    ? .critical : Health.grade(pct, warm: channel.warm, hot: channel.hot) == .warm
                    ? .warning : .normal,
                resetsAt: (n["resets_at"] as? String).flatMap(ISO8601DateFormatter.parse)
            ))
        }

        // Several per-model weeklies can share the `other` feather. Keep the tightest.
        let others = out.filter { $0.channel == .other }
        if others.count > 1, let worst = others.max(by: { $0.strain < $1.strain }) {
            out.removeAll { $0.channel == .other }
            out.append(worst)
        }
        return out
    }

    /// Known kinds get a proper name; anything new gets a readable one rather than a raw
    /// identifier. The endpoint already ships several buckets that report nothing yet
    /// (`seven_day_opus`, `seven_day_oauth_apps`, a few unlaunched names), and the day one of
    /// them starts reporting, this is what the panel will call it.
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

    /// No token, no network, or rate-limited: fall back to what the transcripts remember. A 429
    /// record carries a real reset time, which is the one genuinely useful thing we have offline.
    private func offline() -> [QuotaWindow] {
        guard let rl = Transcript.lastRateLimit(), rl.resetsAt > Date() else { return [] }
        let channel: Channel = rl.kind.contains("week") ? .week : .session
        return [QuotaWindow(id: rl.kind, provider: .claude, channel: channel,
                            title: title(rl.kind), percent: 100, severity: .critical,
                            resetsAt: rl.resetsAt, isActive: true, note: "已限流")]
    }
}
