import Foundation
import Security
import os

/// Claude Code's quota, read from the same OAuth endpoint the `/usage` command uses.
///
/// Two things shape this file. First, the token is read from the keychain on demand and sent
/// only to `api.anthropic.com` — it is never written to disk, logged, or held longer than the
/// request. Second, the endpoint is rate-limited hard, so a cache and a strict `Retry-After`
/// are not optimisations here, they are the difference between working and being locked out.
///
/// Parsing is driven by the response's `limits[]` array rather than its named fields. The
/// payload already carries a row of buckets that are null today — per-model weeklies, extra
/// usage, several unlaunched names. Reading the array means the interface grows a line the day
/// one of them starts reporting, with no code change; reading `five_hour` and `seven_day` by
/// name would mean shipping a build for each.
actor ClaudeProvider {

    private var cache: [QuotaWindow] = []
    private var fetchedAt: Date?
    private var retryAfter: Date?
    /// Why we have no Claude numbers, when we have none. The panel needs to tell the
    /// difference: "log in" and "grant keychain access" are different problems with different
    /// fixes, and "读不到额度" helps with neither.
    enum Blocker: Equatable {
        case none
        case notLoggedIn          // no credential in the keychain at all
        case keychainRefused      // the item is there, macOS will not let us read it
        case expired              // token past its expiry; opening Claude Code refreshes it
        case rateLimited(Date)    // 429; showing the last good numbers until then
    }

    private(set) var loggedIn = false
    private(set) var blocker: Blocker = .none

    private let ttl: TimeInterval = 60

    // MARK: Keychain

    private struct Credential { let token: String; let expiresAt: Date? }

    /// Set once the user dismisses the keychain prompt without allowing access. Without this we
    /// would re-ask every refresh, which turns one dialog into a dialog every sixty seconds.
    private var keychainDenied = false

    /// The keychain read blocks its thread for as long as macOS shows the access dialog, and
    /// a newly-signed binary always gets one. If nobody is at the machine, that is forever.
    ///
    /// Two earlier attempts at a timeout both hung, and the second failure is the instructive
    /// one. Racing the read against a sleep in a `withTaskGroup` looks right and cannot work:
    /// the group does not return until *every* child finishes, `cancelAll()` has no effect on a
    /// synchronous `SecItemCopyMatching` already in flight, and so the group sits waiting on the
    /// loser it was supposed to abandon. (The first attempt was worse — both children shared
    /// this actor's executor, so the blocking read owned it and the timer never even ran.)
    ///
    /// So: no task group. Two queues race to resume one continuation, a lock decides who got
    /// there first, and the loser is simply never waited on.
    private func credentialWithTimeout() async -> Credential?? {
        await withCheckedContinuation { (cont: CheckedContinuation<Credential??, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func claim() -> Bool {
                resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let c = Self.readKeychain()
                if claim() { cont.resume(returning: .some(c)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                // Outer nil: the dialog was never answered.
                if claim() { cont.resume(returning: Credential??.none) }
            }
        }
    }

    /// Does the item exist at all? Asking for the attributes rather than the data does not
    /// trip the access dialog, which is what separates "you never logged in" from "macOS is
    /// refusing this build".
    private static func credentialExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    private static func readKeychain() -> Credential? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let node = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = node["accessToken"] as? String, !token.isEmpty else { return nil }
        let exp = (node["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credential(token: token, expiresAt: exp)
    }

    // MARK: Fetch

    func windows() async -> (windows: [QuotaWindow], stale: Bool) {
        if let at = fetchedAt, Date().timeIntervalSince(at) < ttl { return (cache, false) }
        if let r = retryAfter, Date() < r { return (cache, true) }

        if keychainDenied { return (cache.isEmpty ? offline() : cache, true) }

        let attempt = await credentialWithTimeout()
        guard let inner = attempt else {
            // Nobody answered the dialog. Stop asking — one prompt an hour is a nuisance, one
            // every sixty seconds is a reason to delete the app.
            keychainDenied = true
            loggedIn = false
            blocker = .keychainRefused
            return (offline(), true)
        }
        guard let cred = inner else {
            loggedIn = false
            // The item exists for the `claude` CLI but we could not read it: macOS is refusing
            // this binary's signature, which is a different fix from logging in.
            blocker = Self.credentialExists() ? .keychainRefused : .notLoggedIn
            return (offline(), true)
        }
        if let e = cred.expiresAt, e < Date() {
            blocker = .expired
            // Expired: opening Claude Code refreshes it. Say so by going stale rather than
            // sending a token we already know will bounce.
            loggedIn = false
            return (cache.isEmpty ? offline() : cache, true)
        }
        loggedIn = true

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (cache, true) }

            if http.statusCode == 429 {
                let after = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                retryAfter = Date().addingTimeInterval(after)
                blocker = .rateLimited(retryAfter!)
                return (cache.isEmpty ? offline() : cache, true)
            }
            guard http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return (cache.isEmpty ? offline() : cache, true) }

            retryAfter = nil
            blocker = .none
            cache = parse(root)
            fetchedAt = Date()
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

    private func title(_ kind: String) -> String {
        switch kind {
        case "session":    return "五小时窗口"
        case "five_hour":  return "五小时窗口"
        case "weekly_all", "seven_day": return "周窗口"
        default:           return kind.replacingOccurrences(of: "_", with: " ")
        }
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
