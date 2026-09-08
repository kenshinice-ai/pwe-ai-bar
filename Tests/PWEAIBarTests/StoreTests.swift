import Foundation
import XCTest
@testable import PWEAIBar

private actor SuspendedHTTP {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func send(_ request: URLRequest) async -> (Data, URLResponse) {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return (Data("{\"five_hour\":{\"utilization\":20}}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func finish() { continuation?.resume(); continuation = nil }
}

final class StoreTests: XCTestCase {
    @MainActor func testClaudePublishesBeforeSlowCodexAndStatistics() async throws {
        let space = try TestSpace(); let clock = TestClock(); let credential = FakeCredential()
        let p = provider(space, clock: clock, credential: credential,
                         http: HTTPStub([(200, #"{"five_hour":{"utilization":7.4}}"#, [:])]))
        var localCalled = false
        let store = Store(claude: p,
                          rules: RuleEngine(defaults: space.defaults, away: { false }, remaining: { true }),
                          readEvents: { [] },
                          readLocal: { _, _ in localCalled = true; return .init(trophy: Trophy(), context: nil, lastTurnAt: nil) },
                          readCodex: { try? await Task.sleep(nanoseconds: 600_000_000); return ([], nil) },
                          deliver: { _, _ in false }, tracks: { (true, true) }, tracksExtra: { _ in false },
                          observe: { $0 })
        store.refresh()
        for _ in 0..<20 {
            if !store.snapshot.windows(of: .claude).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.snapshot.windows(of: .claude).first?.percent, 7.4)
        XCTAssertFalse(localCalled, "Claude must publish before unrelated work finishes")
        store.stop()
        try await Task.sleep(nanoseconds: 650_000_000)
    }

    @MainActor func testHookEventReachesDeliveryWhileQuotaRequestIsSuspended() async throws {
        let space = try TestSpace(); let credential = FakeCredential(); let suspended = SuspendedHTTP()
        let p = ClaudeProvider(defaults: space.defaults, cacheURL: space.root.appendingPathComponent("quota.json"),
                               access: credential.access, request: { await suspended.send($0) }, fallback: { nil })
        let reader = HookEventReader(directory: space.root)
        let rules = RuleEngine(defaults: space.defaults, away: { false }, remaining: { true })
        var delivered: [RuleEngine.Alert] = []
        let store = Store(claude: p, rules: rules, readEvents: { await reader.events() },
                          readLocal: { _, _ in .init(trophy: Trophy(), context: nil, lastTurnAt: nil) }, readCodex: { ([], nil) },
                          deliver: { alert, _ in delivered.append(alert); return true }, tracks: { (true, false) },
                          lastActivity: Date().addingTimeInterval(-7200))
        store.start(observeSystem: false)
        defer { store.stop() }
        for _ in 0..<40 {
            if await suspended.entered { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let started = await suspended.entered; XCTAssertTrue(started)
        let began = Date()
        _ = try space.file("events/synthetic.json", "{\"event_id\":\"one\",\"kind\":\"waiting\",\"session\":\"s\",\"at\":\(began.timeIntervalSince1970)}")
        for _ in 0..<100 {
            if !delivered.isEmpty { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertEqual(delivered.map(\.kind), [.waiting])
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertEqual(store.snapshot.events.first?.kind, .waiting)
        await suspended.finish()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(store.snapshot.events.first?.kind, .waiting, "Completing quota refresh must not overwrite newer events")
        XCTAssertEqual(delivered.count, 1)
    }

    func testChangingCredentialDiscardsOldInFlightResponse() async throws {
        let space = try TestSpace(); let credential = FakeCredential(); let suspended = SuspendedHTTP()
        let replacement = HTTPStub([(200, "{\"five_hour\":{\"utilization\":7}}", [:])])
        let p = ClaudeProvider(defaults: space.defaults, cacheURL: space.root.appendingPathComponent("quota.json"),
                               access: credential.access, request: { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token" {
                return await suspended.send(request)
            }
            return try await replacement.send(request)
        }, fallback: { nil })
        let original = Task { await p.windows() }
        for _ in 0..<40 {
            if await suspended.entered { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let updated = await p.useOwnToken("replacement")
        XCTAssertEqual(updated, .saved(.none))
        await suspended.finish()
        _ = await original.value
        let rows = await p.windows()
        XCTAssertEqual(rows.windows.first?.percent, 7)
    }
}
