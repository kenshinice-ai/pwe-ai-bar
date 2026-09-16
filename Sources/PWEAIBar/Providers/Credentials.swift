import CryptoKit
import Foundation
import Security
import LocalAuthentication

/// The keychain from this app's side: its own manual token, quiet reads of other tools' items,
/// and what can be learned about Claude Code's login without reading it — whether the record
/// exists, when it was last written, and whether Claude Code is installed at all.
///
/// Claude Code's login itself is read by `ClaudeCredentialStore`, and only read.
enum Credentials {

    static func noninteractiveContext() -> LAContext {
        let context = LAContext(); context.interactionNotAllowed = true; return context
    }

    private static let ownService = "PWE AI Bar"
    private static let ownAccount = "claude-usage-token"
    static let sharedService = "Claude Code-credentials"

    enum Source: String {
        case ownToken        // long-lived token we hold ourselves
        case claudeKeychain  // Claude Code's record, read through the security tool, never written
        case claudeFile      // ~/.claude/.credentials.json, read and never written
        case none
    }

    struct Token {
        let value: String
        let expiresAt: Date?
        let source: Source
        var refreshToken: String? = nil
        var scopes: [String]? = nil
        var document: Data? = nil
        var origin: ClaudeCredentialStore.Origin? = nil
        var accountKey: String? = nil
        var plan: String? = nil
        /// The server's own rate-limit tier, e.g. `default_claude_max_5x`. The only field that
        /// separates Max 5× from Max 20×, which is a factor of two in what the plan costs.
        var rateLimitTier: String? = nil

        var hasUsageScope: Bool { scopes?.isEmpty != false || scopes!.contains("user:profile") }
        var generation: String {
            ClaudeValue.fingerprint(Data((origin?.key ?? source.rawValue).utf8) + (document ?? Data(value.utf8)))
        }
    }

    // MARK: Manually stored credential

    /// Serialises the process-wide interaction switch so two readers cannot leave it off for
    /// each other, or restore it out from under one another.
    private static let interactionLock = NSLock()

    private static let ownFlag = "ownTokenStored"
    /// Set once when a token is stored, so the common case — nobody ran `claude setup-token` —
    /// never touches the keychain at all.
    ///
    /// This is not premature: `SecItemCopyMatching` is a synchronous round trip to `securityd`,
    /// and it has been measured on this machine at 4 s, 10 s and 84 s for the same item. Whatever
    /// makes it slow, an app that reads a token it does not have on every refresh is paying for
    /// nothing.
    static var mayHaveOwnToken: Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: ownFlag) == nil else { return d.bool(forKey: ownFlag) }
        let found = read(ownService, ownAccount) != nil      // one-time migration probe
        d.set(found, forKey: ownFlag)
        return found
    }

    /// A keychain read that cannot put anything on screen, for every path that runs on a timer.
    ///
    /// Both switches are needed and they cover different gates: the `LAContext` covers
    /// LocalAuthentication for `SecAccessControl` items, `SecKeychainSetUserInteractionAllowed`
    /// covers the classic ACL on a `login.keychain` item. Missing the second one is what made
    /// this app ask a person for permission every twenty seconds.
    static func quietRead(_ service: String, _ account: String) -> String? {
        quietRead(service: service, account: account)
    }

    /// The same read for the other tools' items, whose account names this app does not know.
    /// `nil` matches whatever account the owner wrote — what `security find-generic-password -s`
    /// did, minus the subprocess, and minus the dialog it raised on every poll.
    static func quietRead(service: String, account: String?) -> String? {
        interactionLock.lock()
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true); interactionLock.unlock() }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecUseAuthenticationContext as String: noninteractiveContext()]
        if let account { q[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Records' attributes and never their values, with both dialog gates closed: which accounts a
    /// service has, and when each was last written. Attributes need no permission to read; the gates
    /// are shut regardless, so "cannot ask" holds by construction rather than by whatever securityd
    /// happens to do today. Empty when there is no such record, nil when the query itself failed.
    static func quietAttributes(service: String, account: String? = nil) -> [[String: Any]]? {
        interactionLock.lock()
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true); interactionLock.unlock() }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecUseAuthenticationContext as String: noninteractiveContext()]
        if let account { q[kSecAttrAccount as String] = account }
        var items: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return nil }
        return items as? [[String: Any]]
    }

    private static func read(_ service: String, _ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: Credentials.noninteractiveContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Noninteractive read; failures are surfaced by the provider or explicit setup flow.
    static func ownToken() -> Token? {
        guard mayHaveOwnToken else { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: Credentials.noninteractiveContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return Token(value: value, expiresAt: nil, source: .ownToken)
    }

    private static func remember(_ stored: Bool, defaults: UserDefaults) {
        defaults.set(stored, forKey: ownFlag)
    }

    enum SaveResult: Equatable {
        case saved, cleared, failed(OSStatus)
        var succeeded: Bool {
            switch self { case .saved, .cleared: return true; case .failed: return false }
        }
    }

    struct Operations {
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var add: (CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus
        static let live = Operations(update: SecItemUpdate,
                                     add: { SecItemAdd($0, nil) }, delete: SecItemDelete)
    }

    @discardableResult
    static func storeOwnToken(_ value: String, operations: Operations = .live, defaults: UserDefaults = .standard) -> SaveResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        if value.isEmpty {
            let result = operations.delete(base as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { return .failed(result) }
            remember(false, defaults: defaults)
            return .cleared
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        let result = operations.update(base as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { remember(true, defaults: defaults); return .saved }
        guard result == errSecItemNotFound else { return .failed(result) }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "PWE AI Bar — Claude 用量令牌"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = operations.add(add as CFDictionary)
        guard added == errSecSuccess else { return .failed(added) }
        remember(true, defaults: defaults)
        return .saved
    }

    static var hasOwnToken: Bool { ownToken() != nil }

    /// Whether a token was ever stored, answered from the flag alone. Safe on the main thread
    /// and safe inside a view's initialiser, which `hasOwnToken` is not: that one goes to
    /// securityd, and securityd has taken 84 seconds on this machine for this item.
    static var hasStoredOwnToken: Bool {
        UserDefaults.standard.bool(forKey: ownFlag)
    }

    // MARK: Claude Code's own credential — facts about it, never its value

    /// Whether Claude Code exists on this Mac at all — as opposed to existing but signed out.
    ///
    /// Worth the distinction because the advice differs and one of them is unfollowable: a Mac
    /// without it was told to "run claude auth login", and got `zsh: command not found`. Checked
    /// by looking rather than by spawning `which`: this runs off the main thread during settings
    /// detection, and a subprocess there is what the keychain lesson was about.
    static func claudeCodePresent() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if fm.fileExists(atPath: home.appendingPathComponent(".claude").path) { return true }
        for cli in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                    home.appendingPathComponent(".local/bin/claude").path,
                    home.appendingPathComponent(".claude/local/claude").path]
        where fm.fileExists(atPath: cli) { return true }
        for app in ["/Applications/Claude.app",
                    home.appendingPathComponent("Applications/Claude.app").path]
        where fm.fileExists(atPath: app) { return true }
        return false
    }

    /// True when Claude Code has ever logged in on this machine. Asks the keychain only for
    /// attributes, never the data, so it answers the question without tripping any dialog.
    static func sharedItemExists() -> Bool {
        for service in sharedServiceCandidates() where quietAttributes(service: service)?.isEmpty == false {
            return true
        }
        return FileManager.default.fileExists(atPath: credentialsFilePath())
    }

    /// `security -w` prints the raw value, but falls back to hex when the bytes are not printable
    /// text — a credential that happens to contain one is otherwise silently unreadable.
    static func parse(_ text: String, source: Source) -> Token? {
        guard let token = ClaudeCredentialStore.decode(text, source: source), token.hasUsageScope else { return nil }
        return token
    }

    static func hexDecoded(_ text: String) -> Data? {
        var hex = Substring(text)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.dropFirst(2) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(byte); i = next
        }
        return Data(bytes)
    }

    /// `CLAUDE_CONFIG_DIR` moves the credential to a service suffixed with a digest of the path,
    /// so a per-project config keeps its own login. The unsuffixed name is still tried after it.
    static func sharedServiceCandidates() -> [String] {
        guard let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return [sharedService] }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return ["\(sharedService)-\(digest.map { String(format: "%02x", $0) }.joined().prefix(8))", sharedService]
    }

    static func credentialsFilePath() -> String {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dir, !dir.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json").path
        }
        return NSString(string: dir).expandingTildeInPath + "/.credentials.json"
    }

}

/// Runs a command and returns its standard output, or nil for any non-zero exit, timeout or
/// launch failure. Injectable so tests never run the real one.
typealias ProcessLine = ([String]) -> String?

enum Subprocess {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if data.count + chunk.count > 1_048_576 { overflow = true; return false }
            data.append(chunk)
            return true
        }
    }

    static let line: ProcessLine = { run($0, timeout: 5) }

    /// `timeout` is the caller's patience, and the two callers want very different things.
    /// Five seconds is right for a command that answers on its own. A command that can put a
    /// keychain dialog on screen is waiting for a *person*, and killing it at five seconds
    /// dismisses that dialog before anyone can reach "Always Allow" — so the grant never
    /// records, and the next read asks again. Give that one a human's patience instead.
    static func run(_ argv: [String], timeout: TimeInterval) -> String? {
        guard let first = argv.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        let out = Output(), err = Output(), drained = DispatchGroup()
        for (pipe, buffer) in [(stdout, out), (stderr, err)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drained.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if !buffer.append(chunk) {
                        process.terminate(); break
                    }
                }
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut || process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        guard drained.wait(timeout: .now() + 1) == .success,
              !process.isRunning, !timedOut, process.terminationStatus == 0 else { return nil }
        out.lock.lock(); defer { out.lock.unlock() }
        err.lock.lock(); defer { err.lock.unlock() }
        guard !out.overflow, !err.overflow else { return nil }
        return String(data: out.data, encoding: .utf8)
    }
}
