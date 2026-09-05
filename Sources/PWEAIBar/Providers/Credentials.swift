import CryptoKit
import Foundation
import Security

/// Where the Claude token comes from, and why none of it needs a password.
///
/// The keychain grants access per *item* and per *program*. Claude Code's credential item is
/// created by the CLI shelling out to `/usr/bin/security`, so the program on that item's access
/// list is `/usr/bin/security` itself — not `claude`, and certainly not us. Calling
/// `SecItemCopyMatching` from this app is therefore a stranger knocking, and macOS puts the
/// access dialog on screen. Asking the *same* way Claude Code wrote it — running
/// `security find-generic-password` — is the program already on the list, and it is silent.
///
/// That is the whole trick, and it is the one AI Usage uses. It costs a subprocess (~20 ms) and
/// buys: no dialog, no "Always Allow", no re-prompt when the build's signature changes, and no
/// `claude setup-token` step. Nothing here is privileged — it is the user's own credential, read
/// on the user's own machine, through the door the user's own CLI installed.
///
/// Two fallbacks stay behind it: the credentials file Claude Code writes when the keychain is
/// unavailable, and a long-lived token from `claude setup-token` kept in an item *this app*
/// creates, which is preferred when present because an app is always trusted for its own items.
enum Credentials {

    private static let ownService = "PWE AI Bar"
    private static let ownAccount = "claude-usage-token"
    static let sharedService = "Claude Code-credentials"

    enum Source: String {
        case ownToken        // long-lived token we hold ourselves
        case claudeKeychain  // Claude Code's item, read through /usr/bin/security
        case claudeFile      // ~/.claude/.credentials.json
        case sharedKeychain  // Claude Code's item via SecItemCopyMatching — may show a dialog
        case none
    }

    struct Token {
        let value: String
        let expiresAt: Date?
        let source: Source
    }

    // MARK: Our own item — no dialog, ever

    /// Set once when a token is stored, so the common case — nobody ran `claude setup-token` —
    /// never touches the keychain at all.
    ///
    /// This is not premature: `SecItemCopyMatching` is a synchronous round trip to `securityd`,
    /// and it has been measured on this machine at 4 s, 10 s and 84 s for the same item. Whatever
    /// makes it slow, an app that reads a token it does not have on every refresh is paying for
    /// nothing.
    private static let ownFlag = "ownTokenStored"
    static var mayHaveOwnToken: Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: ownFlag) == nil else { return d.bool(forKey: ownFlag) }
        let found = read(ownService, ownAccount) != nil      // one-time migration probe
        d.set(found, forKey: ownFlag)
        return found
    }

    private static func read(_ service: String, _ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads the item this app created. An application is implicitly on the access list of its
    /// own keychain items, so this cannot raise a prompt.
    static func ownToken() -> Token? {
        guard mayHaveOwnToken else { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return Token(value: value, expiresAt: nil, source: .ownToken)
    }

    private static func remember(_ stored: Bool) {
        UserDefaults.standard.set(stored, forKey: ownFlag)
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
    static func storeOwnToken(_ value: String, operations: Operations = .live) -> SaveResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        if value.isEmpty {
            let result = operations.delete(base as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { return .failed(result) }
            remember(false)
            return .cleared
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        let result = operations.update(base as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { remember(true); return .saved }
        guard result == errSecItemNotFound else { return .failed(result) }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "PWE AI Bar — Claude 用量令牌"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = operations.add(add as CFDictionary)
        guard added == errSecSuccess else { return .failed(added) }
        remember(true)
        return .saved
    }

    static var hasOwnToken: Bool { ownToken() != nil }

    // MARK: Claude Code's own credential — no dialog

    /// True when Claude Code has ever logged in on this machine. Asks the keychain only for
    /// attributes, never the data, so it answers the question without tripping any dialog.
    static func sharedItemExists() -> Bool {
        for service in sharedServiceCandidates() {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { return true }
        }
        return FileManager.default.fileExists(atPath: credentialsFilePath())
    }

    /// The zero-dialog read. Blocking — run it off any executor you care about.
    ///
    /// Keychain before file: on macOS the keychain item is the one Claude Code keeps current,
    /// and a `.credentials.json` left over from a container or an older install would hand back
    /// a token that expired weeks ago.
    static func claudeCodeCredential(run: ProcessLine = Subprocess.line) -> Token? {
        for service in sharedServiceCandidates() {
            // `-a <user>` first: that is how the CLI writes it. Without it, `security` returns
            // whichever item it finds first, which on a shared Mac may belong to someone else.
            for arguments in [["-a", currentAccount(), "-s", service, "-w"], ["-s", service, "-w"]] {
                guard let text = run(["/usr/bin/security", "find-generic-password"] + arguments),
                      let token = parse(text, source: .claudeKeychain) else { continue }
                return token
            }
        }
        guard let text = try? String(contentsOfFile: credentialsFilePath(), encoding: .utf8)
        else { return nil }
        return parse(text, source: .claudeFile)
    }

    /// Direct keychain read. Kept only for the opt-in path, because this is the call that puts
    /// the access dialog on screen when the app is not on the item's access list.
    static func readShared() -> Token? {
        for service in sharedServiceCandidates() {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let text = String(data: data, encoding: .utf8),
                  let token = parse(text, source: .sharedKeychain) else { continue }
            return token
        }
        return nil
    }

    /// `security -w` prints the raw value, but falls back to hex when the bytes are not printable
    /// text — a credential that happens to contain one is otherwise silently unreadable.
    static func parse(_ text: String, source: Source) -> Token? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = Data(trimmed.utf8)
        guard let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                ?? hexDecoded(trimmed).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return nil }

        let node = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let value = (node["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        // An empty or missing scope list means the CLI never recorded one; only a populated list
        // that leaves out profile access proves this token cannot read usage.
        if let scopes = node["scopes"] as? [String], !scopes.isEmpty,
           !scopes.contains("user:profile") { return nil }
        let millis = (node["expiresAt"] as? NSNumber)?.doubleValue
        let exp = (millis?.isFinite ?? false) ? Date(timeIntervalSince1970: millis! / 1000) : nil
        return Token(value: value, expiresAt: exp, source: source)
    }

    private static func hexDecoded(_ text: String) -> Data? {
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

    private static func currentAccount() -> String {
        let user = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return user?.isEmpty == false ? user! : NSUserName()
    }
}

/// Runs a command and returns its standard output, or nil for any non-zero exit, timeout or
/// launch failure. Injectable so tests never touch the real keychain.
typealias ProcessLine = ([String]) -> String?

enum Subprocess {
    static let line: ProcessLine = { argv in
        guard let first = argv.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // Read while it runs: a pipe that fills up deadlocks a process waiting to write.
        let group = DispatchGroup()
        var data = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = err.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        // The only way `security` blocks this long is an access dialog we did not expect.
        // Kill it rather than leave a sheet sitting on the user's screen.
        let deadline = DispatchTime.now() + 5
        let queue = DispatchQueue.global(qos: .utility)
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        queue.asyncAfter(deadline: deadline, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
    }
}

