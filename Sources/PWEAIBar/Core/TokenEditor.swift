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
        self.message = hasToken ? "令牌已保存，有效性以额度连接结果为准" : ""
    }

    @discardableResult
    func submit(_ value: String, save: (String) async -> ClaudeProvider.TokenUpdate) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; message = "正在保存并验证…"
        defer { isSaving = false }
        let result = await save(value)
        message = result.message
        if result.succeeded { hasToken = result.stored }
        return result.succeeded
    }
}
