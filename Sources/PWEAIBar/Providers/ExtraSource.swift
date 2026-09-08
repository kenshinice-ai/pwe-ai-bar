import Foundation

/// Shared plumbing for the providers we read but do not own.
///
/// Claude and Codex each earned bespoke code: one has a private endpoint we ask directly, the
/// other has a documented app server. The other five follow one shape — find a credential the
/// vendor's own tool already stored, make a single request, map the answer — so they share one
/// set of parts rather than five near-copies of the same file.
///
/// Three rules hold across all of them, and they are the same rules Claude follows:
///
///   * **Read only.** No token is refreshed and no credential file is ever written. A vendor's
///     login is theirs to manage; the worst thing this app could do is half-rotate someone's
///     session and leave them signed out of the tool they were working in.
///   * **Nothing uninvited.** A provider whose credential is absent is simply not installed, and
///     no request goes out for it. Missing is a state to report, not an error to retry.
///   * **Bounded.** Every subprocess has a deadline, every request has a timeout, and a provider
///     that fails does not delay the ones that work.
enum ExtraSource {

    /// What we know about a provider before, and after, asking.
    enum Connection: Equatable {
        case notInstalled            // no credential anywhere we know to look
        case signedOut               // credential present but the server refused it
        case connected
        case unavailable(String)     // network, or a shape we no longer recognise
        case unsupported(String)     // the account cannot answer this question at all

        var word: String {
            switch self {
            case .notInstalled:        return L("detected.absent", "not installed")
            case .signedOut:           return L("detected.signedOut", "signed out")
            case .connected:           return L("detected.connected", "connected")
            case .unavailable(let w):  return w
            case .unsupported(let w):  return w
            }
        }
    }

    struct Reading {
        var windows: [QuotaWindow] = []
        var plan: String?
        var connection: Connection = .notInstalled
    }

    // MARK: Finding things on disk

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path))
    }

    static func text(_ path: String) -> String? {
        try? String(contentsOfFile: expand(path), encoding: .utf8)
    }

    static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: expand(path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Reads a keychain item the same way its owner wrote it — see `Credentials` for why going
    /// through `security` is what keeps the access dialog off the screen.
    static func keychain(service: String, account: String? = nil,
                         run: ProcessLine = Subprocess.line) -> String? {
        var argv = ["/usr/bin/security", "find-generic-password"]
        if let account { argv += ["-a", account] }
        argv += ["-s", service, "-w"]
        return run(argv)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// One value out of a VS Code-style `state.vscdb`. Uses the system `sqlite3` rather than
    /// linking SQLite: the file belongs to another running app, and a read-only shell query that
    /// cannot hold a lock is the least invasive way in.
    static func sqliteValue(_ database: String, key: String,
                            run: ProcessLine = Subprocess.line) -> String? {
        let path = expand(database)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let quoted = key.replacingOccurrences(of: "'", with: "''")
        return run(["/usr/bin/sqlite3", "-readonly", path,
                    "SELECT value FROM ItemTable WHERE key = '\(quoted)' LIMIT 1;"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// `key: value` out of a small YAML or TOML file. Deliberately not a parser: these are the
    /// vendors' own flat config files, and pulling in a YAML dependency to read one line of
    /// `~/.config/gh/hosts.yml` would be the tail wagging the dog.
    static func flatValue(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix(":") || rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The GitHub CLI stores its token through Go's keyring, which sometimes wraps the value in
    /// a JSON envelope and sometimes does not.
    static func unwrap(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return trimmed.nonEmpty }
        for key in ["Data", "data", "token", "oauth_token", "value"] {
            if let value = (object[key] as? String)?.nonEmpty { return value }
        }
        return nil
    }

    // MARK: Reading values back

    /// Whatever shape a vendor chose for a timestamp. Seconds and milliseconds are told apart by
    /// magnitude, which is safe for any date this century.
    static func date(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 {
            return Date(timeIntervalSince1970: number > 3e10 ? number / 1000 : number)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 3e10 ? seconds / 1000 : seconds)
        }
        if let parsed = ISO8601DateFormatter.parse(text) { return parsed }
        // A bare calendar date is UTC midnight; treating it as local would move a reset by a day.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: text)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = (value as? NSNumber)?.doubleValue, n.isFinite { return n }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// Title-cases a vendor's own identifier for display: `pro_plus` becomes `Pro Plus`. The
    /// words stay theirs — mapping "pro" onto a multiplier the way AI Usage does bakes in a
    /// product definition that changes without telling us.
    static func planLabel(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 40 else { return nil }
        return text.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A JWT's expiry, read without validating it. Used only to say "this login has run out"
    /// instead of firing a request that is certain to come back 401.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = number(object["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: Asking

    static func send(_ request: URLRequest,
                     via transport: (URLRequest) async throws -> (Data, URLResponse))
        async -> (status: Int, body: Data)? {
        guard let (data, response) = try? await transport(request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    static func request(_ url: String, method: String = "GET",
                        headers: [String: String], body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
