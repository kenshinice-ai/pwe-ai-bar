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
    @MainActor func testHookEventReachesDeliveryWhileQuotaRequestIsSuspended() async throws {
        let space = try TestSpace(); let credential = FakeCredential(); let suspended = SuspendedHTTP()
        let p = ClaudeProvider(defaults: space.defaults, cacheURL: space.root.appendingPathComponent("quota.json"),
                               access: credential.access, request: { await suspended.send($0) }, fallback: { nil })
        let reader = HookEventReader(directory: space.root)
        let rules = RuleEngine(defaults: space.defaults, away: { false }, remaining: { true })
        var delivered: [RuleEngine.Alert] = []
        let store = Store(claude: p, rules: rules, readEvents: { await reader.events() },
                          readLocal: { .init(trophy: Trophy(), context: nil, lastTurnAt: nil) }, readCodex: { [] },
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
