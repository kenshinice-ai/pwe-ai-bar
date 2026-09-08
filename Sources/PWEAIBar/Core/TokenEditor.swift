import Foundation
import Combine

/// UI state follows the completed storage and verification result, never a button click.
@MainActor
final class TokenEditor: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var hasToken: Bool
    @Published private(set) var message: String

    init(hasToken: Bool) {
        self.hasToken = hasToken
        self.message = hasToken
            ? L("token.stored", "A token is saved; the quota connection decides whether it works") : ""
    }

    @discardableResult
    func submit(_ value: String, save: (String) async -> ClaudeProvider.TokenUpdate) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; message = L("token.saving", "Saving and verifying…")
        defer { isSaving = false }
        let result = await save(value)
        message = result.message
        if result.succeeded { hasToken = result.stored }
        return result.succeeded
    }
}
