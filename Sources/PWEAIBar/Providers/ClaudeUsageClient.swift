import Foundation

/// One ephemeral session for quota traffic; credentials never enter a cookie store.
///
/// One endpoint, and it only reads. The token endpoint that used to sit beside it is gone on
/// purpose: renewing is Claude Code's to do, because only the renewer can store the replacement.
final class ClaudeUsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ClaudeUsageClient()
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
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
        // The endpoint should answer directly. Never forward a bearer token on a redirect.
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
}
