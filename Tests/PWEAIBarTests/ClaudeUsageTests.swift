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
        XCTAssertEqual(record.outcome, "已续期")
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
}
