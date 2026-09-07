import Foundation

/// One ephemeral session for quota/refresh traffic; credentials never enter a cookie store.
final class ClaudeUsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ClaudeUsageClient()
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    override init() { super.init(); _ = session }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let reply = try await session.data(for: request)
        guard reply.0.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        return reply
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // These two endpoints should answer directly. Never forward bearer tokens on redirects.
        completionHandler(nil)
    }

    static func usage(token: String) -> URLRequest {
        var r = URLRequest(url: usageURL)
        r.timeoutInterval = 12
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue(ClaudeProvider.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    static func refresh(token: String) throws -> URLRequest {
        var r = URLRequest(url: refreshURL)
        r.httpMethod = "POST"
        r.timeoutInterval = 12
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": token,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        ])
        return r
    }
}
