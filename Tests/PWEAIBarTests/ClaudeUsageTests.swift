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

/// A one-shot latch usable from a `@Sendable` request stub.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open_ = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        lock.lock(); open_ = true; let pending = waiters; waiters = []; lock.unlock()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open_ { lock.unlock(); cont.resume(); return }
            waiters.append(cont); lock.unlock()
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class ClaudeUsageTests: XCTestCase {

    /// Pinned: the rotation record renders through `Loc` now.
    override func setUp() { super.setUp(); Loc.language = .en }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func auth(_ value: String = "first", expiry: Double = 1_800_003_600, scope: String = "user:profile", account: String = "A",
                      refreshExpiry: Double? = nil) -> String {
        let refreshLine = refreshExpiry.map { ",\"refreshTokenExpiresAt\":\($0 * 1000)" } ?? ""
        return """
        {"account":{"uuid":"\(account)"},"futureRoot":{"keep":true},"claudeAiOauth":{
          "accessToken":"\(value)","refreshToken":"refresh-\(value)","expiresAt":\(expiry * 1000)\(refreshLine),
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

    /// The worst failure this app is capable of, found by the second cloud review.
    ///
    /// Once the refresh call returns, the server may already have retired the refresh token
    /// Claude Code is still holding, and the only copy of its replacement is in this process's
    /// memory. Writing it back is therefore not part of producing a result — it is cleanup that
    /// must happen whether or not anyone still wants the result. It used to be guarded by two
    /// `check(version)` calls and a re-read of the candidates, so anything that bumped
    /// `revision` in that window — the user tapping 「重新连接」 in settings, or saving a manual
    /// token — abandoned the replacement and left them logged out of their own CLI.
    func testARotationIsWrittenBackEvenIfTheAppStopsCaringMidFlight() async throws {
        final class Box: @unchecked Sendable { var provider: ClaudeProvider? }
        let box = Box()
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth(expiry: date.timeIntervalSince1970 + 30))
        let http = HTTPStub([
            (200, #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#, [:]),
            (200, quota, [:]),
        ])
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { self.date }, request: { request in
            if request.url == ClaudeUsageClient.refreshURL {
                // The exchange is in flight and the reader picks this moment to reconnect.
                await box.provider?.enableSharedKeychain()
            }
            return try await http.send(request)
        })
        box.provider = provider

        _ = await provider.windows()

        let stored = try XCTUnwrap(memory.get("/synthetic/auth.json"))
        let root = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as! [String: Any]
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "rotated",
                       "the replacement has to reach disk even when nobody wants the reading")
        XCTAssertEqual(oauth["refreshToken"] as? String, "rotated-refresh",
                       "and the rotated refresh token above all — it is the one that cannot be re-fetched")
        XCTAssertEqual(memory.writes, 1)

        // And it is recorded as our own doing, in the language the rest of the readout uses.
        let record = try XCTUnwrap(ClaudeProvider.refreshRecord(space.defaults))
        XCTAssertEqual(record.outcome, ClaudeProvider.Outcome.renewed.message)
        XCTAssertEqual(record.count, 1, "the tally no longer depends on matching an English literal")
    }

    /// Cancelling the *reading* must not cancel the *exchange*.
    ///
    /// `invalidate()` cancels the in-flight fetch, and URLSession honours cancellation — so a
    /// refresh POST would be torn down mid-flight. If the server had already rotated by then,
    /// the replacement arrives in a response nobody is listening for and Claude Code's stored
    /// copy is dead: a settings tap logs the reader out of their own CLI. The exchange therefore
    /// runs in an unstructured task, which does not inherit cancellation.
    func testCancellingTheReadingDoesNotCancelTheExchange() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth(expiry: date.timeIntervalSince1970 + 30))
        let http = HTTPStub([
            (200, #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#, [:]),
            (200, quota, [:]),
        ])
        let reached = Gate(), release = Gate()
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { self.date }, request: { request in
            if request.url == ClaudeUsageClient.refreshURL {
                reached.open()
                await release.wait()
                // URLSession tears a request down when its task is cancelled; the stub models
                // that, because without it this test passes against the very code it exists to
                // catch. Inside the unstructured exchange task this is never cancelled.
                try Task.checkCancellation()
            }
            return try await http.send(request)
        })

        let reading = Task { await provider.windows() }
        await reached.wait()
        // The real cancellation path, and the only one that reaches the exchange: `invalidate()`
        // cancels the memoised fetch task. Cancelling the *caller* never could — `windows()`
        // hands the work to an unstructured task of its own — which is why this test models the
        // settings tap rather than a caller losing patience.
        await provider.enableSharedKeychain()
        release.open()            // the server answers anyway
        _ = await reading.value

        let stored = try XCTUnwrap(memory.get("/synthetic/auth.json"))
        let oauth = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(stored.utf8))
                                   as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["refreshToken"] as? String, "rotated-refresh",
                       "a cancelled reading must not cost the reader their login")
        XCTAssertEqual(memory.writes, 1)
    }

    /// A refresh token is single-use in the worst case, and the second attempt's `invalid_grant`
    /// arrives after the first attempt's replacement has become the only working credential.
    /// Two fetches must never both spend it: the second joins the first exchange.
    func testTwoFetchesNeverSpendTheSameRefreshTokenTwice() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth(expiry: date.timeIntervalSince1970 + 30))
        let http = HTTPStub([
            (200, #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#, [:]),
            (200, quota, [:]), (200, quota, [:]),
        ])
        let reached = Gate(), release = Gate()
        let refreshes = Counter()
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { self.date }, request: { request in
            if request.url == ClaudeUsageClient.refreshURL {
                refreshes.bump()
                reached.open()
                await release.wait()
            }
            return try await http.send(request)
        })

        let first = Task { await provider.windows() }
        await reached.wait()
        // The reader reconnects: the memoised fetch is dropped and cancelled, and a second one
        // starts against a credential the first exchange has not written back yet.
        await provider.enableSharedKeychain()
        let second = Task { await provider.windows() }
        try await Task.sleep(nanoseconds: 50_000_000)
        release.open()
        _ = await first.value; _ = await second.value

        XCTAssertEqual(refreshes.value, 1, "the same refresh token must not be presented twice")
        XCTAssertEqual(memory.writes, 1)
    }

    /// When the login is past saving, the reader is told the date and the command.
    ///
    /// Found on a real machine: the CLI credential had sat untouched for days, both tokens past
    /// their dates, and all the app could say was "凭据已失效" — true, and leaving the reader
    /// with nothing to do. The record carried `refreshTokenExpiresAt` the whole time.
    ///
    /// 1.0.1 also skipped the exchange when that date had passed. That is gone: it was gated on
    /// a counter that only ever goes up, so it was unreachable on any install older than its
    /// first rotation. The exchange happening is therefore asserted here too — it is the
    /// behaviour, not a regression.
    func testAnUnsaveableLoginNamesTheDateAndTheCommand() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        let died = date.timeIntervalSince1970 - 4 * 86400
        memory.put("/synthetic/auth.json",
                   auth(expiry: date.timeIntervalSince1970 - 5 * 86400, refreshExpiry: died))
        let http = HTTPStub([(400, #"{"error":"invalid_grant"}"#, [:])])
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { self.date }, request: { try await http.send($0) })

        _ = await provider.windows()

        XCTAssertEqual(memory.writes, 0, "a refused exchange must not write over the credential")
        let blocker = await provider.blocker
        XCTAssertTrue(blocker.isExpired)
        XCTAssertTrue(blocker.message.contains("claude auth login"),
                      "the message has to end in something the reader can paste: \(blocker.message)")
        // Compared against the two shapes the case can produce rather than against a substring,
        // so rewording either one cannot quietly turn this assertion into a tautology.
        XCTAssertEqual(blocker.message, ClaudeProvider.Blocker.expired(Date(timeIntervalSince1970: died)).message,
                       "the dated form is the whole point when the date is ours to vouch for")
        XCTAssertNotEqual(blocker.message, ClaudeProvider.Blocker.expired(nil).message)
    }

    /// But a date this app may have outdated itself is not stated as fact.
    ///
    /// `ClaudeCredentialStore.rotated` rewrites the access token, the refresh token and the
    /// access expiry, and deliberately leaves `refreshTokenExpiresAt` alone — invariant one
    /// forbids reshaping a record Claude Code also owns. So after this app has swapped a token
    /// once, the date on disk may describe a refresh token that no longer exists. Naming it
    /// would send the reader looking for what happened on a day that means nothing.
    func testADateThisAppMayHaveOutdatedIsNotStatedAsFact() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        space.defaults.set(1, forKey: "claudeRefreshCount")   // we have rotated before
        memory.put("/synthetic/auth.json",
                   auth(expiry: date.timeIntervalSince1970 - 5 * 86400,
                        refreshExpiry: date.timeIntervalSince1970 - 4 * 86400))
        let http = HTTPStub([(400, #"{"error":"invalid_grant"}"#, [:])])
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { self.date }, request: { try await http.send($0) })

        _ = await provider.windows()

        let blocker = await provider.blocker
        XCTAssertTrue(blocker.isExpired)
        XCTAssertEqual(blocker.message, ClaudeProvider.Blocker.expired(nil).message,
                       "no date may be named once we cannot vouch for it: \(blocker.message)")
        XCTAssertTrue(blocker.message.contains("claude auth login"), "the remedy is still stated")
    }
}

/// 1.0.8 raised a keychain dialog every twenty seconds until the app was force-quit. 1.0.9 tried
/// to gate each call site that could prompt, missed two of the three, and moved a fourth out from
/// behind the gate on the false premise that an in-process read cannot prompt. 1.0.10 removes the
/// capability instead of guarding it: reads that run on a timer cannot put anything on screen.
/// These pin the parts of that which are testable without a window server.
final class KeychainPromptTests: XCTestCase {
    private func token(_ json: String, expired: Bool = false) throws -> Credentials.Token {
        try XCTUnwrap(ClaudeCredentialStore.decode(json, source: .sharedKeychain,
                                                   origin: .keychain(service: "Claude Code-credentials",
                                                                     account: "tester")))
    }
    private var expiredJSON: String {
        #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1000,"scopes":["user:profile"]}}"#
    }
    private let refreshReply = #"{"access_token":"new","expires_in":3600}"#
    private var at: Date { Date(timeIntervalSince1970: 1_760_000_000) }

    /// The failure that started all of this: the fallback rescues the reading, so nothing
    /// propagates and the app concludes it is fine. Recovering is not the same as fine.
    func testAFallbackThatRescuesTheReadingStillRecordsTheRefusal() async throws {
        let space = try TestSpace()
        space.defaults.set(true, forKey: "sharedKeychainOptIn")
        let shared = Counter()
        let good = try token(#"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":1800000000000,"scopes":["user:profile"]}}"#)
        let access = ClaudeProvider.Access(
            own: { nil }, claudeCode: { nil }, sharedExists: { true },
            shared: { shared.bump(); return good }, save: { _ in .failed(-1) },
            load: { throw ClaudeCredentialStore.Failure.denied })
        let p = ClaudeProvider(defaults: space.defaults, access: access, now: { self.at },
                               request: { _ in throw ClaudeProvider.Blocker.network })
        _ = await p.windows(force: true)
        XCTAssertTrue(space.defaults.bool(forKey: "keychainRefused"),
                      "the refusal must be recorded even though the fallback made it invisible")
        XCTAssertEqual(shared.value, 1, "and the door that cannot prompt stays open")
    }

    /// A refresh token is single-use in the worst case, so an exchange whose replacement cannot
    /// be stored can kill the copy Claude Code still holds. Within one run the in-memory
    /// `rejected` table already stops a repeat — but it dies with the process, and this app has
    /// been force-quit and relaunched all day. The record has to outlive the process.
    func testAFailedWriteBackSurvivesARelaunch() async throws {
        let space = try TestSpace()
        let expired = try token(expiredJSON)
        let http = HTTPStub([(200, refreshReply, [:]), (200, refreshReply, [:])])
        func provider() -> ClaudeProvider {
            ClaudeProvider(defaults: space.defaults,
                           access: .init(own: { nil }, claudeCode: { nil }, sharedExists: { false },
                                         shared: { nil }, save: { _ in .failed(-1) },
                                         load: { [expired] },
                                         persist: { _, _ in throw ClaudeCredentialStore.Failure.storage }),
                           now: { self.at }, request: { try await http.send($0) })
        }
        _ = await provider().windows(force: true)
        XCTAssertEqual(space.defaults.string(forKey: "claudeRefreshOutcome"), "savedFailed")
        let first = await http.count
        XCTAssertEqual(first, 1, "one exchange, and it could not be written back")

        // A fresh actor is a relaunch: `rejected` is empty again, and only the persisted record
        // stands between a dead write-back and another spent refresh token.
        _ = await provider().windows(force: true)
        let second = await http.count
        XCTAssertEqual(second, 1, "a relaunch must not spend another refresh token")
    }

    func testReconnectingLetsRotationTryAgainAfterARelaunch() async throws {
        let space = try TestSpace()
        let expired = try token(expiredJSON)
        let http = HTTPStub([(200, refreshReply, [:]), (200, refreshReply, [:])])
        func provider() -> ClaudeProvider {
            ClaudeProvider(defaults: space.defaults,
                           access: .init(own: { nil }, claudeCode: { nil }, sharedExists: { false },
                                         shared: { nil }, save: { _ in .failed(-1) },
                                         load: { [expired] },
                                         persist: { _, _ in throw ClaudeCredentialStore.Failure.storage }),
                           now: { self.at }, request: { try await http.send($0) })
        }
        let first = provider()
        _ = await first.windows(force: true)
        await first.enableSharedKeychain()
        _ = await provider().windows(force: true)
        let count = await http.count
        XCTAssertEqual(count, 2, "设置 → 重新连接 is the way back in, and it outlives the process too")
    }

    /// The one that cost a real login. The exchange makes the server rotate the refresh token,
    /// and the reply carries the only copy of the replacement — so if the record cannot be
    /// written back, the exchange must not happen at all. Checked before, not after.
    func testARecordThatCannotBeWrittenBackIsNeverExchangedFor() async throws {
        let space = try TestSpace()
        let expired = try token(expiredJSON)
        let http = HTTPStub([(200, refreshReply, [:])])
        let p = ClaudeProvider(
            defaults: space.defaults,
            access: .init(own: { nil }, claudeCode: { nil }, sharedExists: { false },
                          shared: { nil }, save: { _ in .failed(-1) }, load: { [expired] },
                          persist: { _, _ in XCTFail("must not reach the write-back"); return false },
                          storable: { _ in false }),
            now: { self.at }, request: { try await http.send($0) })
        _ = await p.windows(force: true)
        let count = await http.count
        XCTAssertEqual(count, 0, "a refresh token that cannot be replaced must not be spent")
        XCTAssertNotEqual(space.defaults.string(forKey: "claudeRefreshOutcome"), "invalidated",
                          "and nothing may be recorded on a path where no exchange happened")
    }

    /// 1.0.10 took the dialog away from every read, which stopped the nagging and also removed
    /// the only way back in: `claude auth login` recreates the item, its new access list does not
    /// carry this app, and every quiet read then answers errSecAuthFailed with nothing the reader
    /// can do. Exactly one door asks, and only a person opens it.
    func testOnlyTheButtonEverAsksForAuthorisation() async throws {
        let space = try TestSpace()
        space.defaults.set(true, forKey: "sharedKeychainOptIn")
        let asked = Counter()
        let opened = XCTestExpectation(description: "authorisation requested")
        let p = ClaudeProvider(
            defaults: space.defaults,
            access: .init(own: { nil }, claudeCode: { nil }, sharedExists: { true },
                          shared: { nil }, save: { _ in .failed(-1) }, load: { [] },
                          authorise: { asked.bump(); opened.fulfill(); return true }),
            now: { self.at }, request: { _ in throw ClaudeProvider.Blocker.network })

        for _ in 0..<3 { _ = await p.windows(force: true) }
        XCTAssertEqual(asked.value, 0, "no poll may ever put a permission prompt on screen")

        await p.enableSharedKeychain()
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(asked.value, 1, "pressing the button is what asks, and it asks once")
    }

    /// `Subprocess.run` is no longer on any keychain path, but it still runs other providers'
    /// commands and its budget is per call.
    func testTheTimeoutIsThePerCallBudget() {
        XCTAssertNil(Subprocess.run(["/bin/sleep", "2"], timeout: 0.3), "a short budget still bites")
        XCTAssertEqual(Subprocess.run(["/bin/echo", "ok"], timeout: 5), "ok\n")
    }

    /// The regression that produced 1.0.10: no code that runs on a timer may reach the keychain
    /// through a path that is allowed to draw. Asserted structurally, because a dialog cannot be
    /// asserted from a unit test.
    func testNoBackgroundKeychainReadForksTheSecurityTool() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Every source file, not one: the Claude read was cured in 1.0.10 and the same fork
        // was still sitting in ExtraSource, raising its dialog each time settings opened on a
        // machine with Cursor, gh or Antigravity signed in. The one exemption is the legacy
        // `claudeCodeCredential(run:)` in Credentials.swift, which nothing on a timer reaches.
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Credentials.swift" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(code.contains("/usr/bin/security"),
                           "\(file.lastPathComponent) forks the security tool — that is a dialog on every poll")
        }
        let credentials = try String(contentsOf: root.appendingPathComponent("Sources/PWEAIBar/Providers/Credentials.swift"),
                                     encoding: .utf8)
        XCTAssertTrue(credentials.contains("SecKeychainSetUserInteractionAllowed"),
                      "the classic-ACL dialog has exactly one switch; an LAContext does not close it")
    }
}
