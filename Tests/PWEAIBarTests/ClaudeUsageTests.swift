import Foundation
import XCTest
@testable import PWEAIBar

private final class ClaudeMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    var failWrite = false
    var writes = 0
    func put(_ path: String, _ value: String) { lock.lock(); defer { lock.unlock() }; files[path] = value }
    func get(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return files[path] }
    var store: ClaudeCredentialStore {
        ClaudeCredentialStore(services: [], path: "/synthetic/auth.json", account: "fixture", io: .init(
            accounts: { _ in [] }, readKeychain: { _, _ in XCTFail("No keychain in tests"); return nil },
            writeKeychain: { _, _, _ in XCTFail("No keychain in tests") }, readFile: { self.get($0) },
            writeFile: { path, data in
                if self.failWrite { throw ClaudeCredentialStore.Failure.storage }
                self.writes += 1; self.put(path, String(decoding: data, as: UTF8.self))
            }))
    }
    var access: ClaudeProvider.Access {
        .init(own: { nil }, claudeCode: { nil }, sharedExists: { false }, shared: { nil }, save: { _ in .failed(-1) },
              load: { try self.store.load() }, persist: { try self.store.save($0, expected: $1) })
    }
}

final class ClaudeUsageTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func auth(_ value: String = "first", expiry: Double = 1_800_003_600, scope: String = "user:profile", account: String = "A") -> String {
        """
        {"account":{"uuid":"\(account)"},"futureRoot":{"keep":true},"claudeAiOauth":{
          "accessToken":"\(value)","refreshToken":"refresh-\(value)","expiresAt":\(expiry * 1000),
          "scopes":["\(scope)"],"subscriptionType":"pro","futureField":[1,2,3]}}
        """
    }
    private var quota: String { #"{"five_hour":{"utilization":7.4,"resets_at":1800003600},"seven_day":{"utilization":18.2,"resets_at":1800400000}}"# }

    func testMapperPreservesDecimalsModelPoolsAndExtraSpend() throws {
        let json = #"{"five_hour":{"utilization":7.4,"resets_at":1800003600000},"seven_day":{"utilization":"18.2","resets_at":1800400000},"seven_day_sonnet":{"utilization":0},"limits":[{"kind":"weekly_scoped","percent":8,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":9,"scope":{"model":{"display_name":"Another"}}}],"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000}}"#
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let mapped = try ClaudeUsageMapper.map(root, at: date)
        XCTAssertEqual(mapped.windows.count, 5)
        XCTAssertEqual(mapped.windows[0].percent, 7.4)
        XCTAssertEqual(mapped.windows[0].resetsAt, date.addingTimeInterval(3600))
        XCTAssertEqual(Readout.panelText(mapped.windows[0], remaining: true), "92.6%")
        XCTAssertEqual(mapped.spend?.usedUSD, Decimal(string: "12.34"))
        XCTAssertEqual(mapped.spend?.limitUSD, 50)
        XCTAssertEqual(Set(mapped.windows.map(\.id)).count, 5)
    }

    func testMapperRejectsBooleanInvalidNumbersAndConflicts() throws {
        for value: Any in [true, "NaN", "Infinity", -1, 101] {
            XCTAssertThrowsError(try ClaudeUsageMapper.map(["five_hour": ["utilization": value]], at: date))
        }
        XCTAssertThrowsError(try ClaudeUsageMapper.map([:], at: date))
        XCTAssertThrowsError(try ClaudeUsageMapper.map(["five_hour": ["utilization": NSNull()]], at: date))
        XCTAssertThrowsError(try ClaudeUsageMapper.map([
            "five_hour": ["utilization": 12], "limits": [["kind": "session", "percent": 13]]
        ], at: date))
        for value in [0.0, 99.49, 99.5, 99.99, 100.0] {
            let row = try XCTUnwrap(ClaudeUsageMapper.map(["five_hour": ["utilization": value]], at: date).windows.first)
            XCTAssertEqual(row.confirmedExhausted, value == 100)
        }
        let expired = try ClaudeUsageMapper.map(["five_hour": ["utilization": 100, "resets_at": date.timeIntervalSince1970 - 1]], at: date)
        XCTAssertNil(expired.windows[0].percent); XCTAssertFalse(expired.windows[0].confirmedExhausted)
    }

    func testDateAndScopeParsing() throws {
        let text = "2027-01-15T08:00:00"
        XCTAssertEqual(ClaudeValue.date(text), ClaudeValue.date(text + "Z"))
        XCTAssertEqual(ClaudeValue.date(1800000000000), date)
        XCTAssertNil(ClaudeValue.date(true))
        let token = try XCTUnwrap(ClaudeCredentialStore.decode(auth(scope: "user:inference"), source: .claudeFile))
        XCTAssertFalse(token.hasUsageScope)
        XCTAssertNotNil(token.document)
    }

    func testRefreshPersistsUnknownFieldsAndUsesNewToken() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth(expiry: date.timeIntervalSince1970 + 30))
        let http = HTTPStub([(200, #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#, [:]), (200, quota, [:])])
        var requests: [URLRequest] = []
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: {
            requests.append($0); return try await http.send($0)
        })
        let result = await provider.windows()
        XCTAssertFalse(result.stale); XCTAssertEqual(result.windows.first?.percent, 7.4)
        XCTAssertEqual(requests.map(\.url), [ClaudeUsageClient.refreshURL, ClaudeUsageClient.usageURL])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
        let saved = try JSONSerialization.jsonObject(with: Data(memory.get("/synthetic/auth.json")!.utf8)) as! [String: Any]
        XCTAssertNotNil(saved["futureRoot"])
        XCTAssertEqual((saved["claudeAiOauth"] as? [String: Any])?["futureField"] as? [Int], [1, 2, 3])
        XCTAssertEqual(memory.writes, 1)
        let details = await provider.details
        XCTAssertEqual(details.plan, "pro")
        _ = await provider.windows()
        let count = await http.count; XCTAssertEqual(count, 2)
    }

    /// The cadence used to tighten as the news got worse — sixty seconds the moment any window
    /// went hot. A spent window has nothing left to say until it rolls over, so that spent the
    /// only budget that matters, 1,440 times a day, to learn nothing; the endpoint answered with
    /// an hour-long Retry-After and the panel then showed a figure thirty-three hours old.
    func testASpentWindowIsNotPolledUntilItRollsOver() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth())
        let reset = date.timeIntervalSince1970 + 600
        let body = """
        {"five_hour":{"utilization":100,"resets_at":\(reset)},\
        "seven_day":{"utilization":18.2,"resets_at":\(date.timeIntervalSince1970 + 400_000)}}
        """
        let http = HTTPStub([(200, body, [:]), (200, body, [:]), (200, body, [:])])
        var clock = date
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { clock }, request: { try await http.send($0) })

        let first = await provider.windows()
        XCTAssertTrue(first.windows.contains { $0.confirmedExhausted })
        var count = await http.count; XCTAssertEqual(count, 1)

        // Two minutes on. The old rule would have gone back for a number that cannot have moved.
        clock.addTimeInterval(120)
        _ = await provider.windows()
        count = await http.count
        XCTAssertEqual(count, 1, "nothing can have changed while the window is spent")

        // Past its own rollover there is finally something to learn.
        clock.addTimeInterval(500)
        _ = await provider.windows()
        count = await http.count
        XCTAssertEqual(count, 2, "the reset is the one moment worth asking about")
    }

    /// And the ordinary case is five minutes, which is what AI Usage ships as its default too —
    /// the old sixty-second floor was the outlier, not the baseline.
    func testAHealthyWindowRestsFiveMinutesAndAnImminentResetTwo() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth())
        let far = #"{"five_hour":{"utilization":20,"resets_at":1800014400},"seven_day":{"utilization":18.2,"resets_at":1800400000}}"#
        let http = HTTPStub([(200, far, [:]), (200, far, [:]), (200, far, [:])])
        var clock = date
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { clock }, request: { try await http.send($0) })
        _ = await provider.windows()
        clock.addTimeInterval(280)
        _ = await provider.windows()
        var count = await http.count
        XCTAssertEqual(count, 1, "under five minutes, the cached reading still stands")
        clock.addTimeInterval(40)
        _ = await provider.windows()
        count = await http.count
        XCTAssertEqual(count, 2, "past it, ask again")
    }

    func test401RefreshAndConcurrentCLIChangeAreBounded() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth())
        let http = HTTPStub([(401, "{}", [:]), (200, #"{"access_token":"new","refresh_token":"new-r","expires_in":3600}"#, [:]), (200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: { try await http.send($0) })
        let reading = await p.windows()
        XCTAssertFalse(reading.stale); XCTAssertEqual(memory.writes, 1)
        let count = await http.count; XCTAssertEqual(count, 3)

        let secondSpace = try TestSpace(); let second = ClaudeMemory(); second.put("/synthetic/auth.json", auth())
        var requests = 0
        let changed = ClaudeProvider(defaults: secondSpace.defaults, access: second.access, now: { self.date }, request: { r in
            requests += 1
            if requests == 1 { second.put("/synthetic/auth.json", self.auth("cli-new")) }
            return (Data(self.quota.utf8), HTTPURLResponse(url: r.url!, statusCode: requests == 1 ? 401 : 200, httpVersion: nil, headerFields: nil)!)
        })
        let adopted = await changed.windows()
        XCTAssertFalse(adopted.stale); XCTAssertEqual(second.writes, 0); XCTAssertEqual(requests, 2)
    }

    func testRotationStorageFailureDoesNotPublishNewTokenOrQuota() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory(); memory.failWrite = true
        let original = auth(expiry: date.timeIntervalSince1970 - 1)
        memory.put("/synthetic/auth.json", original)
        let http = HTTPStub([(200, #"{"access_token":"new","expires_in":3600}"#, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: { try await http.send($0) })
        let reading = await p.windows()
        XCTAssertTrue(reading.windows.isEmpty)
        let blocker = await p.blocker; XCTAssertEqual(blocker, .storage)
        XCTAssertEqual(memory.get("/synthetic/auth.json"), original)
        _ = await p.windows(force: true)
        let requests = await http.count; XCTAssertEqual(requests, 1, "a failed save must not rotate the old refresh token again")
    }

    func testAccountChangeInvalidatesTTLAndHistoryNamespace() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory(); memory.put("/synthetic/auth.json", auth())
        let http = HTTPStub([(200, quota, [:]), (200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: { try await http.send($0) })
        let before = await p.windows()
        memory.put("/synthetic/auth.json", auth("other", account: "B"))
        let after = await p.windows()
        XCTAssertNotEqual(before.windows.first?.observationKey, after.windows.first?.observationKey)
        let count = await http.count; XCTAssertEqual(count, 2)
    }

    func testManualRefreshHonorsCooldownAndFailureKeepsSuccessTime() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory(); memory.put("/synthetic/auth.json", auth())
        var clock = date
        let http = HTTPStub([(200, quota, [:]), (429, "{}", ["Retry-After": "120"]), (200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { clock }, request: { try await http.send($0) })
        _ = await p.windows(); clock.addTimeInterval(5)
        let failed = await p.windows(force: true)
        XCTAssertTrue(failed.stale)
        let details = await p.details; XCTAssertEqual(details.lastSuccessAt, date)
        _ = await p.windows(force: true)
        let count = await http.count; XCTAssertEqual(count, 2)
        clock.addTimeInterval(121)
        let recovered = await p.windows(force: true); XCTAssertFalse(recovered.stale)
    }

    func testCredentialStoreRefusesOverwriteAfterSourceChanged() throws {
        let memory = ClaudeMemory(); memory.put("/synthetic/auth.json", auth())
        let original = try XCTUnwrap(memory.store.load().first)
        let rotated = try ClaudeCredentialStore.rotated(original, response: ["access_token": "new", "expires_in": 3600], now: date)
        memory.put("/synthetic/auth.json", auth("different"))
        XCTAssertFalse(try memory.store.save(rotated, expected: original))
        XCTAssertEqual(memory.writes, 0)
    }

    func testCandidateFallbackRequiresSameIdentity() async throws {
        for sameAccount in [true, false] {
            let space = try TestSpace()
            var first = try XCTUnwrap(ClaudeCredentialStore.decode(auth(), source: .claudeKeychain))
            var second = try XCTUnwrap(ClaudeCredentialStore.decode(auth("second", account: sameAccount ? "A" : "B"), source: .claudeFile))
            first.refreshToken = nil; second.refreshToken = nil
            let tokens = [first, second]
            let access = ClaudeProvider.Access(own: { nil }, claudeCode: { nil }, sharedExists: { false }, shared: { nil },
                                               save: { _ in .failed(-1) }, load: { tokens })
            let http = HTTPStub([(401, "{}", [:]), (200, quota, [:])])
            let p = ClaudeProvider(defaults: space.defaults, access: access, now: { self.date }, request: { try await http.send($0) })
            let result = await p.windows()
            XCTAssertEqual(result.windows.isEmpty, !sameAccount)
            let count = await http.count; XCTAssertEqual(count, sameAccount ? 2 : 1)
        }
    }

    func testConcurrentReadsUseOneRequestAnd401AfterRotationStaysRejected() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory(); memory.put("/synthetic/auth.json", auth())
        let http = HTTPStub([(200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await http.send($0)
        })
        async let a = p.windows(force: true)
        async let b = p.windows(force: true)
        let values = await [a, b]
        XCTAssertTrue(values.allSatisfy { !$0.stale })
        let count = await http.count; XCTAssertEqual(count, 1)

        let secondSpace = try TestSpace()
        let rejectedHTTP = HTTPStub([(401, "{}", [:]), (200, #"{"access_token":"rejected-new","expires_in":3600}"#, [:]), (401, "{}", [:])])
        let rejected = ClaudeProvider(defaults: secondSpace.defaults, access: memory.access, now: { self.date }, request: { try await rejectedHTTP.send($0) })
        _ = await rejected.windows(force: true)
        _ = await rejected.windows(force: true)
        let requests = await rejectedHTTP.count; XCTAssertEqual(requests, 3)
    }

    func testPrivateAtomicFileRotationAndSymlinkRefusal() throws {
        let space = try TestSpace()
        let path = try space.file("auth.json", auth())
        let store = ClaudeCredentialStore(services: [], path: path.path)
        let original = try XCTUnwrap(store.load().first)
        let rotated = try ClaudeCredentialStore.rotated(original, response: ["access_token": "new", "expires_in": 3600], now: date)
        XCTAssertTrue(try store.save(rotated, expected: original))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.value, "new")
        let link = space.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        let linked = ClaudeCredentialStore(services: [], path: link.path)
        XCTAssertThrowsError(try linked.load())
    }

    /// Also from the cloud review, and the worse of the two. The namespace that separates one
    /// account's readings from another's was a fingerprint of the whole credential *document*,
    /// so a routine access-token rotation — Claude Code does one about hourly, and this app now
    /// does them too — minted a new namespace, a new `observationKey`, and orphaned the sample
    /// ring and every pending reset promise. Once an hour, the forecast fell back to the
    /// whole-window average and the alert state started again from nothing.
    func testAnExternalTokenRotationIsNotANewAccount() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth("first"))
        let http = HTTPStub([(200, quota, [:]), (200, quota, [:])])
        var clock = date
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { clock }, request: { try await http.send($0) })
        let before = await provider.windows().windows.first?.observationNamespace
        XCTAssertNotNil(before, "an identified account still gets its own namespace")

        // Same person, different bytes: the CLI rotated its own token underneath us.
        memory.put("/synthetic/auth.json", auth("second"))
        clock.addTimeInterval(600)
        let after = await provider.windows(force: true).windows.first?.observationNamespace
        XCTAssertEqual(after, before, "a new access token is not a new account")

        // A genuinely different account still separates.
        memory.put("/synthetic/auth.json", auth("third", account: "B"))
        clock.addTimeInterval(600)
        let elsewhere = await provider.windows(force: true).windows.first?.observationNamespace
        XCTAssertNotEqual(elsewhere, before)
    }
}
