import Darwin
import Foundation
import Security
import LocalAuthentication

/// Resolves exact sources and preserves the full credential document when rotating tokens.
/// All production reads/writes run off the UI actor. No secret is passed in process arguments.
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
    enum Failure: Error { case denied, malformed, ambiguous, storage, changed }
    struct IO {
        var accounts: (String) throws -> [String]
        var readKeychain: (String, String) throws -> String?
        var writeKeychain: (String, String, Data) throws -> Void
        var readFile: (String) throws -> String?
        var writeFile: (String, Data) throws -> Void
        static let live = IO(accounts: ClaudeCredentialStore.accounts, readKeychain: ClaudeCredentialStore.readKeychain,
                             writeKeychain: ClaudeCredentialStore.writeKeychain, readFile: ClaudeCredentialStore.readFile, writeFile: ClaudeCredentialStore.writeFile)
    }
    var services: [String] = Credentials.sharedServiceCandidates()
    var path: String = Credentials.credentialsFilePath()
    var account: String = NSUserName()
    var io: IO = .live

    func load() throws -> [Credentials.Token] {
        var tokens: [Credentials.Token] = []
        var failure: Error?
        for service in services {
            do {
                let accounts = try io.accounts(service)
                let selected: String?
                if accounts.contains(account) { selected = account }
                else if accounts.count == 1 { selected = accounts.first }
                else if accounts.isEmpty { selected = nil }
                else { throw Failure.ambiguous }
                if let selected, let token = try read(.keychain(service: service, account: selected)) {
                    tokens.append(token)
                    break
                }
            } catch { failure = error }
        }
        do { if let token = try read(.file(path)) { tokens.append(token) } }
        catch { failure = error }
        if tokens.isEmpty, let failure { throw failure }
        return tokens
    }

    func read(_ origin: Origin) throws -> Credentials.Token? {
        let text: String?, source: Credentials.Source
        switch origin {
        case .file(let path): text = try io.readFile(path); source = .claudeFile
        case .keychain(let service, let account):
            text = try io.readKeychain(service, account); source = .claudeKeychain
        }
        guard let text else { return nil }
        guard let token = Self.decode(text, source: source, origin: origin) else { throw Failure.malformed }
        return token
    }

    func unchanged(_ token: Credentials.Token) throws -> Bool {
        guard let origin = token.origin else { return false }
        return try read(origin)?.generation == token.generation
    }

    func save(_ token: Credentials.Token, expected: Credentials.Token) throws -> Bool {
        guard let origin = expected.origin, token.origin == origin, let bytes = token.document else { throw Failure.storage }
        guard try unchanged(expected) else { return false }
        switch origin {
        case .file(let path): try io.writeFile(path, bytes)
        case .keychain(let service, let account): try io.writeKeychain(service, account, bytes)
        }
        return true
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
                                 plan: ClaudeValue.text(node["subscriptionType"]))
    }

    static func rotated(_ token: Credentials.Token, response: [String: Any], now: Date) throws -> Credentials.Token {
        guard let access = ClaudeValue.text(response["access_token"]), let data = token.document,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = ClaudeValue.number(response["expires_in"]), seconds > 0, seconds < 366 * 86400 else {
            throw Failure.malformed
        }
        let nested = root["claudeAiOauth"] is [String: Any]
        var node = root["claudeAiOauth"] as? [String: Any] ?? root
        node["accessToken"] = access
        if let refresh = ClaudeValue.text(response["refresh_token"]) { node["refreshToken"] = refresh }
        node["expiresAt"] = now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000
        if nested { root["claudeAiOauth"] = node } else { root = node }
        let bytes = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        guard let out = decode(String(decoding: bytes, as: UTF8.self), source: token.source, origin: token.origin) else {
            throw Failure.malformed
        }
        return out
    }

    private static func accounts(_ service: String) throws -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecReturnAttributes as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitAll,
                                   kSecUseAuthenticationContext as String: Credentials.noninteractiveContext()]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Failure.denied }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func readKeychain(_ service: String, _ account: String) throws -> String? {
        guard let value = Subprocess.line(["/usr/bin/security", "find-generic-password", "-a", account, "-s", service, "-w"]) else {
            throw Failure.denied
        }
        return value
    }

    private static func writeKeychain(_ service: String, _ account: String, _ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecUseAuthenticationContext as String: Credentials.noninteractiveContext()]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw Failure.storage }
    }

    private static func readFile(_ path: String) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let attrs = try fm.attributesOfItem(atPath: path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw Failure.storage }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func writeFile(_ path: String, _ data: Data) throws {
        // Never create a new credential source or follow a symlink during a rotation.
        let fm = FileManager.default
        guard (try fm.attributesOfItem(atPath: path))[.type] as? FileAttributeType == .typeRegular else { throw Failure.storage }
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(".pwe-oauth-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.storage }
        defer { close(fd); try? fm.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw Failure.storage }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.storage }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, path) == 0 else { throw Failure.storage }
    }
}
