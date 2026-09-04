import Foundation
import Security

/// Where the Claude token comes from, and how to stop macOS asking about it.
///
/// The keychain grants access per *item* and per *code signature*. Claude Code's credential item
/// trusts the `claude` binary and nothing else, so any other program reading it gets the access
/// dialog. Clicking "Always Allow" adds that program's signature to the item's access list, and
/// from then on it is silent — provided the signature never changes, which is why local builds
/// are signed with a stable Apple Development identity rather than ad-hoc. An ad-hoc signature
/// is different on every compile, so every compile counts as a new app and asks again.
///
/// That still costs one dialog. To get to zero there is a second path: a long-lived token from
/// `claude setup-token`, kept in an item **this app creates**. A program is always trusted for
/// its own items, so that read never prompts and never expires out from under us. The app
/// prefers it whenever it is present.
enum Credentials {

    private static let ownService = "PWE AI Bar"
    private static let ownAccount = "claude-usage-token"
    private static let sharedService = "Claude Code-credentials"

    enum Source: String {
        case ownToken        // long-lived token we hold ourselves — never prompts
        case sharedKeychain  // Claude Code's item — one dialog, then silent
        case none
    }

    struct Token {
        let value: String
        let expiresAt: Date?
        let source: Source
    }

    // MARK: Our own item — no dialog, ever

    /// Reads the item this app created. An application is implicitly on the access list of its
    /// own keychain items, so this cannot raise a prompt.
    static func ownToken() -> Token? {
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
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return Token(value: value, expiresAt: nil, source: .ownToken)
    }

    @discardableResult
    static func storeOwnToken(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }     // empty means "forget it"
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "PWE AI Bar — Claude 用量令牌"
        // Available whenever this Mac is unlocked, and never copied to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var hasOwnToken: Bool { ownToken() != nil }

    // MARK: Claude Code's item — may show one dialog

    /// True when the item exists at all. Asks only for attributes, never the data, so it answers
    /// "have you ever logged in?" without tripping the access dialog.
    static func sharedItemExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    /// Blocking, and it can block for a long time — this is what puts the dialog on screen.
    /// Callers must run it off any executor they care about; see `ClaudeProvider`.
    static func readShared() -> Token? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let node = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let value = node["accessToken"] as? String, !value.isEmpty else { return nil }
        let exp = (node["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(value: value, expiresAt: exp, source: .sharedKeychain)
    }
}
