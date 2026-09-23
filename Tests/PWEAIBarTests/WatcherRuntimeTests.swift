import Foundation
import XCTest
@testable import PWEAIBar

/// The two file watchers against the real kernel, not a stand-in. Everything else about them is
/// covered by tests that drive `record`/`drain` by hand; only this proves the streams start, the
/// FSEvents constants convert without trapping, and events actually arrive.
final class WatcherRuntimeTests: XCTestCase {

    #if os(macOS)
    /// Polls `drain` until a written file is reported, or gives up. FSEvents is asked for a
    /// one-second latency, so a few seconds is generous.
    func testFSEventsReportsAFileWrittenUnderTheRoot() throws {
        let space = try TestSpace()
        let root = space.root.resolvingSymlinksInPath()
        let watcher = TreeWatcher(paths: [root.path])
        XCTAssertEqual(watcher.drain(), .unknown, "the first answer is always a full listing")

        let file = root.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: file)

        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            switch watcher.drain() {
            case .files(let paths): seen.formUnion(paths)
            case .unknown: XCTFail("the stream reported a loss for one file")
            case .quiet: break
            }
            if seen.contains(file.path) { break }
        }
        XCTAssertTrue(seen.contains(file.path), "reported: \(seen)")
    }

    func testTheSpoolWatchFiresWhenAnEventIsRenamedIn() throws {
        let space = try TestSpace()
        let spool = space.root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let fired = expectation(description: "directory changed")
        fired.assertForOverFulfill = false
        let queue = DispatchQueue(label: "test.spool")
        let watch = try XCTUnwrap(DirectoryWatch(spool, queue: queue) { fired.fulfill() })

        // What the hook script does: write beside, then rename into place.
        let tmp = spool.appendingPathComponent("x.tmp")
        try Data("{}".utf8).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: spool.appendingPathComponent("x.json"))
        wait(for: [fired], timeout: 5)
        XCTAssertFalse(watch.gone)
    }
    #endif

    func testNoRootsMeansNoClaims() {
        XCTAssertEqual(TreeWatcher(paths: ["/nonexistent/\(UUID().uuidString)"]).drain(), .unknown)
    }
}
