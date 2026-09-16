import Foundation
import Security

/// Claude Code's login, read where Claude Code keeps it — the keychain record first, then the
/// file — and never written.
///
/// **Through the `security` tool, the way Claude Code itself reads and writes it.** Claude Code
/// creates the record with that tool, so the record lets that tool read it without asking: its
/// partition list carries `apple-tool:` and its access list carries `/usr/bin/security`,
/// whichever program happens to launch the tool. An in-process read is a different reader. It
/// asks as this app, and this app is on that list only if somebody once pressed Always Allow —
/// which the next `claude auth login` clears, because it builds the record afresh.
///
/// 1.0.10 went the other way, and why is worth keeping. 1.0.9 ran the tool too, and every poll's
/// subprocess raised a dialog named for the tool, which the timeout killed before anybody could
/// answer it. This app also wrote the record then — it renewed the token itself and put the
/// replacement back — and that write is the likeliest reason the record stopped admitting the tool.
/// Likeliest, not proven: on 2026-09-15 a record 1.4.0 had just written still read quietly. The cure
/// at the time was to stop running the tool; what is gone now is the write. `IO` has no member that
/// changes anything, so nothing here can be called to do it.
///
/// **Nothing here renews anything either.** Renewing spends a refresh token Claude Code also
/// holds and returns the only copy of its replacement, so it is only safe for whoever can store
/// that replacement. On 2026-09-08 three renewals on one machine could not be stored, and the
/// login that machine's CLI shared had to be rebuilt by hand. When the access token runs out now,
/// the reading waits for Claude Code — which can store what it renews — to renew it.
///
/// No secret travels in process arguments: the service and the account do, and the value arrives
/// on standard output.
struct ClaudeCredentialStore {
    enum Origin: Equatable {
        case file(String)
        case keychain(service: String, account: String)

        var key: String {
            switch self {
            case .file(let path): return "file:" + path
            case .keychain(let service, let account): return "keychain:" + service + ":" + account
            }
        }
    }

    /// `denied` is "the record is there and could not be read": the tool refused, or asked and
    /// nobody answered in time, or the record vanished between finding it and reading it. From
    /// here those are one outcome with one response. `malformed` covers a record that decodes to
    /// nothing usable, and a credential file that is not a plain file.
    enum Failure: Error { case denied, malformed, ambiguous }

    struct IO {
        var accounts: (_ service: String) throws -> [String]
        var readKeychain: (_ service: String, _ account: String, _ patience: TimeInterval) throws -> String?
        var readFile: (_ path: String) throws -> String?
        /// The record's attributes and never its value — for when it was last written.
        var attributes: (_ service: String, _ account: String) -> [String: Any]?

        static let live = IO(accounts: ClaudeCredentialStore.accounts,
                             readKeychain: { try ClaudeCredentialStore.readKeychain($0, $1, patience: $2) },
                             readFile: ClaudeCredentialStore.readFile,
                             attributes: { Credentials.quietAttributes(service: $0, account: $1)?.first })
    }

    var services: [String] = Credentials.sharedServiceCandidates()
    var path: String = Credentials.credentialsFilePath()
    var account: String = NSUserName()
    var io: IO = .live

    /// How long one read may take. A timer's read is short, because a dialog raised on a timer is
    /// the one thing to avoid. A read a person asked for waits long enough for them to answer it —
    /// cutting that short dismisses the dialog before Always Allow can be pressed.
    static let timerPatience: TimeInterval = 5
    static let personPatience: TimeInterval = 60

    func load(patient: Bool = false) throws -> [Credentials.Token] {
        let patience = patient ? Self.personPatience : Self.timerPatience
        var tokens: [Credentials.Token] = []
        var failure: Error?
        for service in services {
            do {
                guard let selected = try selectedAccount(service) else { continue }
                if let token = try read(.keychain(service: service, account: selected), patience: patience) {
                    tokens.append(token)
                    break
                }
            } catch Failure.denied {
                // Thrown past the file below, never absorbed by it. A refusal a fallback quietly
                // stands in for is a refusal nobody records, and a failed read nobody records is
                // tried again on the next poll — which, for a read that raised a dialog, is the
                // dialog on every poll. 1.0.9 shipped exactly that.
                throw Failure.denied
            } catch { failure = error }
        }
        do { if let token = try read(.file(path), patience: patience) { tokens.append(token) } }
        catch { failure = error }
        if tokens.isEmpty, let failure { throw failure }
        return tokens
    }

    func read(_ origin: Origin, patience: TimeInterval = ClaudeCredentialStore.timerPatience) throws -> Credentials.Token? {
        let text: String?, source: Credentials.Source
        switch origin {
        case .file(let path): text = try io.readFile(path); source = .claudeFile
        case .keychain(let service, let account):
            text = try io.readKeychain(service, account, patience); source = .claudeKeychain
        }
        guard let text else { return nil }
        guard let token = Self.decode(text, source: source, origin: origin) else { throw Failure.malformed }
        return token
    }

    /// When Claude Code last wrote its login, from the record's attributes alone — reading those
    /// needs no permission and cannot ask. A read that failed is not retried on a timer until this
    /// moves, which is how "Claude Code has written it since" is told apart from "nothing changed".
    func stamp() -> Date? {
        var latest: Date?
        for service in services {
            guard let selected = try? selectedAccount(service) else { continue }
            if let date = io.attributes(service, selected)?[kSecAttrModificationDate as String] as? Date {
                latest = date
                break
            }
        }
        // The later of the two, so a rewritten file moves the stamp as surely as a rewritten record.
        if let file = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            latest = max(latest ?? file, file)
        }
        return latest
    }

    private func selectedAccount(_ service: String) throws -> String? {
        let accounts = try io.accounts(service)
        if accounts.contains(account) { return account }
        if accounts.count == 1 { return accounts[0] }
        if accounts.isEmpty { return nil }
        throw Failure.ambiguous
    }

    static func decode(_ text: String, source: Credentials.Source, origin: Origin? = nil) -> Credentials.Token? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(trimmed.utf8)
        let parsed = (try? JSONSerialization.jsonObject(with: bytes))
            ?? Credentials.hexDecoded(trimmed).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let root = parsed as? [String: Any],
              let document = try? JSONSerialization.data(withJSONObject: root, options: .sortedKeys) else { return nil }
        let node = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = ClaudeValue.text(node["accessToken"]) else { return nil }
        let scopes = node["scopes"] as? [String]
        if let raw = node["scopes"], !(raw is NSNull), scopes == nil { return nil }
        let expiry = ClaudeValue.number(node["expiresAt"])
        if let raw = node["expiresAt"], !(raw is NSNull), expiry == nil { return nil }
        let accountObject = root["account"] as? [String: Any] ?? [:]
        let accountID = ClaudeValue.text(node["accountUuid"]) ?? ClaudeValue.text(accountObject["uuid"])
        let organization = root["organization"] as? [String: Any] ?? [:]
        let organizationID = ClaudeValue.text(node["organizationUuid"]) ?? ClaudeValue.text(organization["uuid"])
        let identity = accountID.map { $0 + ":" + (organizationID ?? "unknown-organization") }
        return Credentials.Token(value: token, expiresAt: expiry.map { Date(timeIntervalSince1970: $0 / 1000) },
                                 source: source, refreshToken: ClaudeValue.text(node["refreshToken"]),
                                 scopes: scopes, document: document, origin: origin,
                                 accountKey: identity.map { ClaudeValue.fingerprint(Data($0.utf8)) },
                                 plan: ClaudeValue.text(node["subscriptionType"]),
                                 rateLimitTier: ClaudeValue.text(node["rateLimitTier"]))
    }

    /// The one command line this app runs against the keychain — what Claude Code runs to read the
    /// same record, `-w` for the value alone.
    static func securityArguments(service: String, account: String) -> [String] {
        ["/usr/bin/security", "find-generic-password", "-a", account, "-s", service, "-w"]
    }

    /// Nil from the tool — a refusal, a dialog nobody answered within `patience`, a record gone
    /// between finding and reading — is reported as `denied`. What follows is the same for all three.
    static func readKeychain(_ service: String, _ account: String, patience: TimeInterval,
                             run: ([String], TimeInterval) -> String? = Subprocess.run) throws -> String? {
        guard let text = run(securityArguments(service: service, account: account), patience) else {
            throw Failure.denied
        }
        return text
    }

    /// Asked on every poll, now that an unchanged stamp spares the value read — so through the query
    /// with both dialog gates shut, rather than trusting an attribute query never to ask.
    private static func accounts(_ service: String) throws -> [String] {
        guard let rows = Credentials.quietAttributes(service: service) else { throw Failure.denied }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func readFile(_ path: String) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let attrs = try fm.attributesOfItem(atPath: path)
        // A symlink or an oversized file is not the file Claude Code writes, and following one is
        // how a credential gets read from somewhere it was never put.
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw Failure.malformed }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
