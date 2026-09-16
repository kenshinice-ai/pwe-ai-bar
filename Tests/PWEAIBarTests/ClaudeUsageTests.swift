import Foundation
import Security
import XCTest
@testable import PWEAIBar

/// Claude Code's login as a file — all most of these tests need: a record that can be read, and
/// changed underneath the provider, with no keychain anywhere.
private final class ClaudeMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    func put(_ path: String, _ value: String) { lock.lock(); defer { lock.unlock() }; files[path] = value }
    func get(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return files[path] }
    var store: ClaudeCredentialStore {
        ClaudeCredentialStore(services: [], path: "/synthetic/auth.json", account: "fixture", io: .init(
            accounts: { _ in [] },
            readKeychain: { _, _, _ in XCTFail("No keychain in tests"); return nil },
            readFile: { self.get($0) },
            attributes: { _, _ in nil }))
    }
    var access: ClaudeProvider.Access {
        .init(own: { nil }, load: { try self.store.load(patient: $0) }, save: { _ in .failed(-1) })
    }
}

/// Claude Code's login as the security tool sees it: a record with a value and a stamp. A nil
/// answer is the tool refusing — a Deny, or a question nobody answered in time.
private final class KeychainRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    private var _stamp = Date(timeIntervalSince1970: 1_799_990_000)
    private var _answers: [String?] = []
    private var _reads: [TimeInterval] = []
    private var _hold: DispatchSemaphore?
    /// Signalled when a held read has started.
    let entered = DispatchSemaphore(value: 0)

    init(_ value: String?) { _value = value }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var value: String? { get { locked { _value } } set { locked { _value = newValue } } }
    var stamp: Date { get { locked { _stamp } } set { locked { _stamp = newValue } } }
    /// Answers for the next reads, in order, before `value` applies again.
    var answers: [String?] { get { locked { _answers } } set { locked { _answers = newValue } } }
    /// Holds the next read until signalled.
    var hold: DispatchSemaphore? { get { locked { _hold } } set { locked { _hold = newValue } } }
    /// The patience of every read the tool was run for, in order.
    var reads: [TimeInterval] { locked { _reads } }

    private func read(_ patience: TimeInterval) throws -> String {
        let held = locked { () -> DispatchSemaphore? in
            _reads.append(patience)
            defer { _hold = nil }
            return _hold
        }
        if let held { entered.signal(); held.wait() }
        let answer = locked { () -> String? in _answers.isEmpty ? _value : _answers.removeFirst() }
        guard let answer else { throw ClaudeCredentialStore.Failure.denied }
        return answer
    }

    var store: ClaudeCredentialStore {
        ClaudeCredentialStore(services: ["Claude Code-credentials"], path: "/synthetic/absent.json",
                              account: "fixture", io: .init(
            accounts: { _ in ["fixture"] },
            readKeychain: { _, _, patience in try self.read(patience) },
            readFile: { _ in nil },
            attributes: { _, _ in [kSecAttrModificationDate as String: self.stamp] }))
    }
    func access(own: Credentials.Token? = nil) -> ClaudeProvider.Access {
        .init(own: { own }, load: { try self.store.load(patient: $0) }, save: { _ in .failed(-1) },
              stamp: { self.store.stamp() })
    }
}

final class ClaudeUsageTests: XCTestCase {

    /// Pinned: blocker messages render through `Loc`.
    override func setUp() { super.setUp(); Loc.language = .en }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func auth(_ value: String = "first", expiry: Double = 1_800_003_600, scope: String = "user:profile",
                      account: String = "A") -> String {
        """
        {"account":{"uuid":"\(account)"},"futureRoot":{"keep":true},"claudeAiOauth":{
          "accessToken":"\(value)","refreshToken":"refresh-\(value)","expiresAt":\(expiry * 1000),
          "scopes":["\(scope)"],"subscriptionType":"pro","futureField":[1,2,3]}}
        """
    }
    private var quota: String { #"{"five_hour":{"utilization":7.4,"resets_at":1800003600},"seven_day":{"utilization":18.2,"resets_at":1800400000}}"# }

    /// Waits for a semaphore without blocking the test's executor.
    private func arrival(_ signal: DispatchSemaphore) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { signal.wait(); cont.resume() }
        }
    }

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

    // MARK: Read, never renewed

    /// Thirty seconds from expiry is still a login, and it is used as one. 1.4.0 renewed it at this
    /// point — spending a refresh token Claude Code also holds, and writing the replacement back —
    /// which is the step that could log someone out of their own CLI. Now the only request is to
    /// the usage endpoint, and the record is left exactly as Claude Code wrote it.
    func testANearlyExpiredLoginIsReadNotRenewed() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        let original = auth(expiry: date.timeIntervalSince1970 + 30)
        memory.put("/synthetic/auth.json", original)
        let http = HTTPStub([(200, quota, [:])])
        var requests: [URLRequest] = []
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: {
            requests.append($0); return try await http.send($0)
        })
        let result = await provider.windows()
        XCTAssertFalse(result.stale); XCTAssertEqual(result.windows.first?.percent, 7.4)
        XCTAssertEqual(requests.map(\.url), [ClaudeUsageClient.usageURL])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer first")
        XCTAssertEqual(memory.get("/synthetic/auth.json"), original)
        let details = await provider.details
        XCTAssertEqual(details.plan, "pro")
    }

    /// An expired login is not renewed here, so the reading stops — and says what starts it again.
    /// "Sign in again" was the old advice, and it rebuilt a login that only needed renewing.
    func testAnExpiredLoginStopsAndPointsAtClaudeCode() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        let expiry = date.timeIntervalSince1970 - 2 * 3600
        memory.put("/synthetic/auth.json", auth(expiry: expiry))
        let http = HTTPStub([])
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date },
                                      request: { try await http.send($0) })
        let reading = await provider.windows()
        XCTAssertTrue(reading.windows.isEmpty)
        let blocker = await provider.blocker
        XCTAssertEqual(blocker, .expired(Date(timeIntervalSince1970: expiry)))
        XCTAssertTrue(blocker.message.contains("open Claude Code"), blocker.message)
        XCTAssertFalse(blocker.message.lowercased().contains("sign in"), blocker.message)
        // Against both shapes the case can take, so rewording one cannot make this a tautology.
        XCTAssertNotEqual(blocker.message, ClaudeProvider.Blocker.expired(nil).message,
                          "the date is named when the record gives one")
        XCTAssertTrue(ClaudeProvider.Blocker.expired(nil).message.contains("open Claude Code"))
        let count = await http.count
        XCTAssertEqual(count, 0, "an expired login is not worth a request, and nothing here renews it")
        let loggedIn = await provider.loggedIn
        XCTAssertFalse(loggedIn)
    }

    /// The other half of the trade. Claude Code renews and writes the replacement where it keeps
    /// it; the next ordinary read finds it, and the quota comes back without anyone pressing anything.
    func testOnceClaudeCodeRenewsTheNextReadRecovers() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth(expiry: date.timeIntervalSince1970 - 60))
        let http = HTTPStub([(200, quota, [:])])
        var clock = date
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { clock },
                                      request: { try await http.send($0) })
        _ = await provider.windows()
        var blocker = await provider.blocker
        XCTAssertTrue(blocker.isExpired)

        memory.put("/synthetic/auth.json", auth("renewed", expiry: date.timeIntervalSince1970 + 8 * 3600))
        clock.addTimeInterval(20)
        let reading = await provider.windows()
        XCTAssertFalse(reading.stale); XCTAssertEqual(reading.windows.first?.percent, 7.4)
        blocker = await provider.blocker
        XCTAssertEqual(blocker, .none)
        let count = await http.count; XCTAssertEqual(count, 1)
    }

    /// A 401 used to be the cue to renew. Now it is the cue to look again: Claude Code may have
    /// renewed while the request was out, and then the new token is already in the record.
    func testA401ReReadsTheLoginInsteadOfRenewingIt() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth())
        var urls: [URL?] = []
        let refused = HTTPStub([(401, "{}", [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: memory.access, now: { self.date }, request: {
            urls.append($0.url); return try await refused.send($0)
        })
        _ = await p.windows()
        let blocker = await p.blocker
        XCTAssertEqual(blocker, .unauthorized, "an unchanged record's refusal is the answer")
        XCTAssertEqual(urls, [ClaudeUsageClient.usageURL], "and no exchange is attempted, however refused the token")

        let secondSpace = try TestSpace(); let second = ClaudeMemory()
        second.put("/synthetic/auth.json", auth())
        var sent: [String] = []
        let renewed = ClaudeProvider(defaults: secondSpace.defaults, access: second.access, now: { self.date }, request: { r in
            sent.append(r.value(forHTTPHeaderField: "Authorization") ?? "")
            if sent.count == 1 { second.put("/synthetic/auth.json", self.auth("renewed-by-claude-code")) }
            return (Data(self.quota.utf8), HTTPURLResponse(url: r.url!, statusCode: sent.count == 1 ? 401 : 200,
                                                           httpVersion: nil, headerFields: nil)!)
        })
        let adopted = await renewed.windows()
        XCTAssertFalse(adopted.stale)
        XCTAssertEqual(sent, ["Bearer first", "Bearer renewed-by-claude-code"])
    }

    /// The same read Claude Code performs, so the record's `apple-tool:` partition — which only a
    /// write from some other program would change — admits this app too. And nothing that could
    /// change the record exists to be called.
    func testTheLoginIsReadThroughTheSecurityToolAndOnlyRead() throws {
        XCTAssertEqual(ClaudeCredentialStore.securityArguments(service: "Claude Code-credentials", account: "someone"),
                       ["/usr/bin/security", "find-generic-password", "-a", "someone", "-s", "Claude Code-credentials", "-w"])
        var runs: [([String], TimeInterval)] = []
        let value = try ClaudeCredentialStore.readKeychain("svc", "acct", patience: 5) { argv, patience in
            runs.append((argv, patience)); return "{}"
        }
        XCTAssertEqual(value, "{}")
        XCTAssertEqual(runs.first?.0, ClaudeCredentialStore.securityArguments(service: "svc", account: "acct"))
        XCTAssertEqual(runs.first?.1, 5)
        XCTAssertThrowsError(try ClaudeCredentialStore.readKeychain("svc", "acct", patience: 5) { _, _ in nil }) {
            guard case ClaudeCredentialStore.Failure.denied = $0 else { return XCTFail("\($0)") }
        }
        let members = Mirror(reflecting: ClaudeCredentialStore.IO.live).children.compactMap(\.label)
        XCTAssertEqual(members, ["accounts", "readKeychain", "readFile", "attributes"],
                       "the store's whole reach into the world, and none of it writes")
    }

    /// A refusal is not absorbed by a credential file next to the record. A file quietly standing
    /// in is how a failed read went unrecorded in 1.0.9, and was repeated every poll.
    func testAFileDoesNotHideARefusedRecord() throws {
        let store = ClaudeCredentialStore(services: ["svc"], path: "/synthetic/auth.json", account: "fixture", io: .init(
            accounts: { _ in ["fixture"] },
            readKeychain: { _, _, _ in throw ClaudeCredentialStore.Failure.denied },
            readFile: { _ in self.auth() },
            attributes: { _, _ in nil }))
        XCTAssertThrowsError(try store.load()) {
            guard case ClaudeCredentialStore.Failure.denied = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: A read that fails

    /// A read stopped by a question nobody answered must not come back on a schedule — that is a
    /// dialog every poll, a defect this app has shipped before. The record changing ends the wait,
    /// since Claude Code writing it may have removed whatever stopped the read; otherwise the wait
    /// runs out, and doubles each time an unchanged record fails again.
    func testATimerDoesNotRetryAReadThatFailed() async throws {
        let space = try TestSpace()
        let record = KeychainRecord(nil)
        var clock = date
        let http = HTTPStub([(200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: record.access(), now: { clock },
                               request: { try await http.send($0) })

        _ = await p.windows()
        var blocker = await p.blocker
        XCTAssertEqual(blocker, .keychainRefused)
        XCTAssertTrue(blocker.message.contains("open Claude Code"), blocker.message)
        XCTAssertEqual(record.reads, [ClaudeCredentialStore.timerPatience], "a timer's read is a short one")

        for _ in 0..<5 { clock.addTimeInterval(20); _ = await p.windows(force: true) }
        XCTAssertEqual(record.reads.count, 1, "polls inside the wait do not run the tool, forced or not")
        blocker = await p.blocker
        XCTAssertEqual(blocker, .keychainRefused)

        clock.addTimeInterval(15 * 60)
        _ = await p.windows()
        XCTAssertEqual(record.reads.count, 2, "past the first wait, a timer tries once more")

        clock.addTimeInterval(20 * 60)
        _ = await p.windows()
        XCTAssertEqual(record.reads.count, 2, "a second failure of the same record waits twice as long")

        record.value = auth()
        record.stamp = record.stamp.addingTimeInterval(3600)
        _ = await p.windows()
        XCTAssertEqual(record.reads.count, 3, "Claude Code wrote the record, so the wait is over")
        blocker = await p.blocker
        XCTAssertEqual(blocker, .none)
    }

    /// Pressing Refresh is the exception to the wait, and the one read given long enough for a
    /// person to reach Always Allow. Cut short, the question closes before it can be answered.
    func testAPersonAskingRetriesAndWaitsForAnAnswer() async throws {
        let space = try TestSpace()
        let record = KeychainRecord(nil)
        let http = HTTPStub([(200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: record.access(), now: { self.date },
                               request: { try await http.send($0) })
        _ = await p.windows()
        var blocker = await p.blocker
        XCTAssertEqual(blocker, .keychainRefused)

        record.value = auth()
        let reading = await p.windows(asked: true)
        XCTAssertFalse(reading.stale)
        XCTAssertEqual(record.reads, [ClaudeCredentialStore.timerPatience, ClaudeCredentialStore.personPatience])
        blocker = await p.blocker
        XCTAssertEqual(blocker, .none)
    }

    /// A person asking while a timer's read is still out does not inherit that read's answer. It
    /// waits for it — two reads at once would be two questions on screen — then reads patiently.
    func testAPersonAskingDuringATimerReadGetsAReadOfTheirOwn() async throws {
        let space = try TestSpace()
        let record = KeychainRecord(auth())
        record.answers = [nil]
        let held = DispatchSemaphore(value: 0)
        record.hold = held
        let http = HTTPStub([(200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: record.access(), now: { self.date },
                               request: { try await http.send($0) })

        let timer = Task { await p.windows() }
        await arrival(record.entered)
        let person = Task { await p.windows(asked: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        held.signal()
        _ = await timer.value
        let reading = await person.value

        XCTAssertFalse(reading.stale, "the person's own read got through")
        XCTAssertEqual(record.reads, [ClaudeCredentialStore.timerPatience, ClaudeCredentialStore.personPatience])
        let count = await http.count; XCTAssertEqual(count, 1)
    }

    /// A saved token is used while Claude Code's login cannot be read — and the failure is still
    /// recorded, so recovering through the saved token is not a reason to run the tool again.
    func testASavedTokenStandsInWhenClaudeCodesLoginCannotBeRead() async throws {
        let space = try TestSpace()
        let record = KeychainRecord(nil)
        let own = Credentials.Token(value: "saved-token", expiresAt: nil, source: .ownToken)
        var clock = date
        let http = HTTPStub([(200, quota, [:]), (200, quota, [:])])
        var sent: [String] = []
        let p = ClaudeProvider(defaults: space.defaults, access: record.access(own: own), now: { clock }, request: {
            sent.append($0.value(forHTTPHeaderField: "Authorization") ?? ""); return try await http.send($0)
        })
        let reading = await p.windows()
        XCTAssertFalse(reading.stale)
        let source = await p.source
        XCTAssertEqual(source, .ownToken)
        XCTAssertEqual(sent, ["Bearer saved-token"])

        clock.addTimeInterval(6 * 60)
        _ = await p.windows()
        XCTAssertEqual(sent.count, 2, "the saved token keeps the reading going")
        XCTAssertEqual(record.reads.count, 1, "while the failed read waits its turn")
    }

    /// Polls come every twenty seconds while someone works, and each read of the value launches a
    /// process. The record's stamp says whether Claude Code has written it since — an attribute
    /// query, which cannot ask anything — so an unchanged record is not read again for a while.
    func testAnUnchangedRecordIsNotReadAgain() async throws {
        let space = try TestSpace()
        let record = KeychainRecord(auth())
        var clock = date
        let http = HTTPStub([(200, quota, [:]), (200, quota, [:]), (200, quota, [:]), (200, quota, [:])])
        let p = ClaudeProvider(defaults: space.defaults, access: record.access(), now: { clock },
                               request: { try await http.send($0) })
        _ = await p.windows()
        for _ in 0..<5 { clock.addTimeInterval(20); _ = await p.windows() }
        XCTAssertEqual(record.reads.count, 1, "an unchanged stamp stands for an unchanged record")

        record.value = auth("renewed")
        record.stamp = record.stamp.addingTimeInterval(60)
        clock.addTimeInterval(20)
        _ = await p.windows()
        XCTAssertEqual(record.reads.count, 2, "a new stamp is read at once")

        clock.addTimeInterval(5 * 60 + 1)
        _ = await p.windows()
        XCTAssertEqual(record.reads.count, 3, "and no read stands in for a fresh one past five minutes")
    }

    // MARK: Cadence and identity

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

    func testCandidateFallbackRequiresSameIdentity() async throws {
        for sameAccount in [true, false] {
            let space = try TestSpace()
            let first = try XCTUnwrap(ClaudeCredentialStore.decode(auth(), source: .claudeKeychain))
            let second = try XCTUnwrap(ClaudeCredentialStore.decode(auth("second", account: sameAccount ? "A" : "B"), source: .claudeFile))
            let tokens = [first, second]
            let access = ClaudeProvider.Access(own: { nil }, load: { _ in tokens }, save: { _ in .failed(-1) })
            let http = HTTPStub([(401, "{}", [:]), (200, quota, [:])])
            let p = ClaudeProvider(defaults: space.defaults, access: access, now: { self.date }, request: { try await http.send($0) })
            let result = await p.windows()
            XCTAssertEqual(result.windows.isEmpty, !sameAccount)
            let count = await http.count; XCTAssertEqual(count, sameAccount ? 2 : 1)
        }
    }

    func testConcurrentReadsUseOneRequest() async throws {
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
    }

    /// A symlink is not the file Claude Code writes, and following one is how a credential gets
    /// read from somewhere it was never put.
    func testASymlinkedCredentialFileIsRefused() throws {
        let space = try TestSpace()
        let path = try space.file("auth.json", auth())
        XCTAssertEqual(try ClaudeCredentialStore(services: [], path: path.path).load().first?.value, "first")
        let link = space.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try ClaudeCredentialStore(services: [], path: link.path).load())
    }

    /// From the cloud review. The namespace that separates one account's readings from another's
    /// was a fingerprint of the whole credential *document*, so every renewal by Claude Code minted
    /// a new namespace and a new `observationKey`, and orphaned the sample ring and every pending
    /// reset promise: the forecast fell back to the whole-window average and the alert state
    /// started again from nothing.
    func testARenewalByClaudeCodeIsNotANewAccount() async throws {
        let space = try TestSpace(); let memory = ClaudeMemory()
        memory.put("/synthetic/auth.json", auth("first"))
        let http = HTTPStub([(200, quota, [:]), (200, quota, [:]), (200, quota, [:])])
        var clock = date
        let provider = ClaudeProvider(defaults: space.defaults, access: memory.access,
                                      now: { clock }, request: { try await http.send($0) })
        let before = await provider.windows().windows.first?.observationNamespace
        XCTAssertNotNil(before, "an identified account still gets its own namespace")

        // Same person, different bytes: Claude Code renewed its token underneath us.
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

/// 1.5.0's promise, pinned where a unit test can reach it: nothing in this app writes Claude Code's
/// login, renews it, or reads it any way but the way Claude Code does.
///
/// Worth pinning in source, because both failures it prevents are invisible from here. A write by
/// any program other than the security tool changes the record's partition list, and from then on
/// Claude Code's own reads of its login raise a dialog — what 1.4.0's renewals did to the machines
/// they ran on. And a renewal whose replacement cannot be stored logs the reader out of their CLI,
/// which happened on 2026-09-08.
final class ReadOnlyLoginTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    private func swiftSources() throws -> [URL] {
        try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                     includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The security tool reads Claude Code's record without a question because the tool made that
    /// record. Other tools' records — Cursor's, gh's — were made in-process by their owners, and the
    /// tool raises a dialog named for itself on each read of those; forking it for them did exactly
    /// that every time settings opened. So the tool runs from one file, for one kind of record,
    /// with one verb.
    func testOnlyTheCredentialStoreRunsTheSecurityTool() throws {
        let tool = "/usr/bin/" + "security"
        let files = try swiftSources()
        XCTAssertGreaterThan(files.count, 10)
        for file in files where file.lastPathComponent != "ClaudeCredentialStore.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(code.contains(tool), "\(file.lastPathComponent) runs the security tool")
        }
        let store = try source("Sources/PWEAIBar/Providers/ClaudeCredentialStore.swift")
        let verbs = try NSRegularExpression(pattern: #"[a-z]+-generic-password"#)
            .matches(in: store, range: NSRange(store.startIndex..., in: store))
            .compactMap { Range($0.range, in: store).map { String(store[$0]) } }
        XCTAssertEqual(Set(verbs), ["find" + "-generic-password"], "the tool is only ever asked to find")
    }

    func testNothingCanWriteOrRenewClaudeCodesLogin() throws {
        // Assembled from pieces, so this file does not match a search for them itself.
        let writes = ["SecItem" + "Update", "SecItem" + "Add", "SecItem" + "Delete",
                      "add" + "-generic-password", "delete" + "-generic-password", ".write" + "(", "createFile" + "("]
        for path in ["Sources/PWEAIBar/Providers/ClaudeCredentialStore.swift",
                     "Sources/PWEAIBar/Providers/ClaudeProvider.swift"] {
            let code = try source(path)
            for call in writes { XCTAssertFalse(code.contains(call), "\(path) can write: \(call)") }
        }
        let client = try source("Sources/PWEAIBar/Providers/ClaudeUsageClient.swift")
        for renewal in ["oauth/" + "token", "refresh" + "_token", "grant" + "_type"] {
            XCTAssertFalse(client.contains(renewal), "the client can renew a login: \(renewal)")
        }
        XCTAssertEqual(client.components(separatedBy: "URL(string:").count - 1, 1, "one endpoint, and it reads")
    }

    /// In-process keychain reads — other tools' records, and attributes of Claude Code's — shut
    /// both dialog gates. An `LAContext` alone does not close the classic ACL's.
    func testInProcessKeychainReadsShutTheClassicDialogGate() throws {
        let credentials = try source("Sources/PWEAIBar/Providers/Credentials.swift")
        XCTAssertTrue(credentials.contains("SecKeychainSetUserInteractionAllowed(false)"),
                      "the classic-ACL dialog has exactly one switch; an LAContext does not close it")
    }

    /// `Subprocess.run` carries the keychain read's patience and other providers' commands, and its
    /// budget is per call.
    func testTheTimeoutIsThePerCallBudget() {
        XCTAssertNil(Subprocess.run(["/bin/sleep", "2"], timeout: 0.3), "a short budget still bites")
        XCTAssertEqual(Subprocess.run(["/bin/echo", "ok"], timeout: 5), "ok\n")
    }
}

final class CallToActionTests: XCTestCase {
    /// The row that carries the only actionable sentence must not truncate it. It did, at two
    /// lines: "…cannot be renewed · run cla…".
    func testTheCallToActionRowDoesNotTruncateTheInstruction() throws {
        let panel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/App/PanelView.swift")
        let code = try String(contentsOf: panel, encoding: .utf8)
        let row = try XCTUnwrap(code.range(of: "private func ctaRow"))
        let window = code[row.lowerBound..<(code.index(row.lowerBound, offsetBy: 600, limitedBy: code.endIndex) ?? code.endIndex)]
        XCTAssertFalse(window.contains("lineLimit("),
                       "the call-to-action row is where the only actionable sentence lives")
    }
}

/// A Mac with no Claude Code on it was told to "run claude auth login", and answered
/// `zsh: command not found: claude`. Advice you cannot follow is worse than none.
final class ClaudeCodePresenceTests: XCTestCase {
    private func provider(_ space: TestSpace, present: Bool) -> ClaudeProvider {
        ClaudeProvider(defaults: space.defaults,
                       access: .init(own: { nil }, load: { _ in [] }, save: { _ in .failed(-1) },
                                     claudeCodePresent: { present }),
                       now: { Date(timeIntervalSince1970: 1_760_000_000) },
                       request: { _ in throw ClaudeProvider.Blocker.network })
    }

    func testAMacWithoutClaudeCodeIsToldSoRatherThanToldToSignIn() async throws {
        let space = try TestSpace()
        let p = provider(space, present: false)
        _ = await p.windows(force: true)
        let blocker = await p.blocker
        XCTAssertEqual(blocker, .notInstalled)
        XCTAssertFalse(blocker.message.contains("claude auth login"),
                       "that command does not exist on this Mac: \(blocker.message)")
        XCTAssertTrue(blocker.message.contains("claude.ai/code"), blocker.message)
    }

    func testAMacWithClaudeCodeButNoLoginIsStillToldToSignIn() async throws {
        let space = try TestSpace()
        let p = provider(space, present: true)
        _ = await p.windows(force: true)
        let blocker = await p.blocker
        XCTAssertEqual(blocker, .notLoggedIn)
    }

    /// The real detector, on the machine running the tests. Asserted only for not-crashing and
    /// for agreeing with itself — what it returns depends on the machine, which is the point.
    func testTheDetectorLooksRatherThanSpawning() throws {
        let present = Credentials.claudeCodePresent()
        XCTAssertEqual(present, Credentials.claudeCodePresent(), "must be a pure look at the disk")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PWEAIBar/Providers/Credentials.swift"), encoding: .utf8)
        let fn = try XCTUnwrap(source.range(of: "static func claudeCodePresent"))
        let body = source[fn.lowerBound..<(source.index(fn.lowerBound, offsetBy: 800, limitedBy: source.endIndex) ?? source.endIndex)]
        XCTAssertFalse(body.contains("Subprocess"), "runs off-main during detection; no subprocess there")
    }
}
