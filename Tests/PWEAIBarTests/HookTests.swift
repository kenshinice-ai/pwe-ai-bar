import Foundation
import XCTest
@testable import PWEAIBar

final class HookTests: XCTestCase {
    func testInvalidConfigurationIsNeverReplaced() throws {
        for contents in ["{\"keep\":true,", "[]", "{\"hooks\":false}", "{\"hooks\":{\"Stop\":42}}",
                         "{\"hooks\":{\"Stop\":[{\"hooks\":false}]}}"] {
            let space = try TestSpace()
            let settings = try space.file("settings.json", contents)
            let source = try space.file("source.sh", "#!/bin/bash\nexit 0\n")
            let script = space.root.appendingPathComponent("hook.sh")
            XCTAssertFalse(HookProvider.install(scriptPath: script.path, settings: settings, source: source))
            XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        }
    }

    func testMissingConfigCreationAndCopyFailure() throws {
        let space = try TestSpace()
        let settings = space.root.appendingPathComponent("nested/settings.json")
        let script = space.root.appendingPathComponent("installed/hook.sh")
        XCTAssertFalse(HookProvider.install(scriptPath: script.path, settings: settings,
                                           source: space.root.appendingPathComponent("missing")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        let source = try space.file("source.sh", "#!/bin/bash\nexit 0\n")
        XCTAssertTrue(HookProvider.install(scriptPath: script.path, settings: settings, source: source))
        XCTAssertTrue(HookProvider.isInstalled(settings: settings, script: script))
    }

    func testPreservesOtherHooksBacksUpAndQuotesPaths() throws {
        let space = try TestSpace()
        let original = "{\"keep\":{\"flag\":true},\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo existing\"}]}]}}"
        let settings = try space.file("settings.json", original)
        let source = try space.file("source.sh", "#!/bin/bash\nprintf '%s' \"$1\"\n")
        let script = space.root.appendingPathComponent("space ' dollar$ `backtick`; /pwe-ai-bar-hook.sh")
        XCTAssertTrue(HookProvider.install(scriptPath: script.path, settings: settings, source: source))
        let data = try Data(contentsOf: settings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["keep"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        let backups = try FileManager.default.contentsOfDirectory(at: space.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("pwe-backup") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data(original.utf8))
        XCTAssertTrue(HookProvider.install(scriptPath: script.path, settings: settings, source: source))
        XCTAssertEqual(try Data(contentsOf: settings), data)
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", HookProvider.shellQuote(script.path) + " answered"]
        process.standardOutput = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "answered")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        XCTAssertFalse(HookProvider.isInstalled(settings: settings, script: script))
    }

    func testSymbolicLinkConfigurationIsPreserved() throws {
        let space = try TestSpace()
        let target = try space.file("original.json", "{\"keep\":true}")
        let settings = space.root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        let script = try space.file("hook.sh", "#!/bin/bash\nexit 0\n")
        XCTAssertFalse(HookProvider.install(scriptPath: script.path, settings: settings))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{\"keep\":true}")
    }

    func testCorruptBatchIsQuarantinedWithoutBlockingValidEvents() async throws {
        let space = try TestSpace()
        for i in 0..<256 { _ = try space.file("events/\(i).json", "invalid") }
        _ = try space.file("events/zz-valid.json", "{\"kind\":\"waiting\",\"session\":\"s\",\"at\":\(Date().timeIntervalSince1970)}")
        let reader = HookEventReader(directory: space.root)
        _ = await reader.events()
        let events = await reader.events()
        XCTAssertEqual(events.count, 1)
        let retained = try FileManager.default.contentsOfDirectory(at: space.root.appendingPathComponent("events"), includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.filter { $0.pathExtension == "invalid" }.count, 256)
    }

    func testUnreadableConfigDoesNotBecomeEmptyConfig() throws {
        let space = try TestSpace()
        let settings = space.root.appendingPathComponent("directory-not-a-file")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let script = try space.file("hook.sh", "#!/bin/bash\nexit 0\n")
        XCTAssertFalse(HookProvider.install(scriptPath: script.path, settings: settings))
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path, isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
    }

    func testConcurrentRealHookWritersAndDurableConsumption() async throws {
        let space = try TestSpace()
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = project.appendingPathComponent("hooks/pwe-ai-bar-hook.sh")
        XCTAssertEqual(try Data(contentsOf: script), try Data(contentsOf: project.appendingPathComponent("Sources/PWEAIBar/Resources/pwe-ai-bar-hook.sh")))
        var processes: [Process] = []
        for i in 0..<60 {
            let process = Process(); let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, i == 0 ? "answered" : "waiting"]
            process.environment = ProcessInfo.processInfo.environment.merging(["PWEBAR_EVENT_DIR": space.root.path]) { _, new in new }
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data("{\"session_id\":\"synthetic-\(i)\",\"message\":\"private synthetic input\"}".utf8))
            try input.fileHandleForWriting.close()
            processes.append(process)
        }
        for process in processes { process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0) }
        let spool = space.root.appendingPathComponent("events")
        let files = try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 60, "No eviction of unread events, even above the old 40-event ring")
        for file in files { XCTAssertNotNil(HookProvider.decode(try Data(contentsOf: file))) }
        let reader = HookEventReader(directory: space.root)
        let events = await reader.events()
        XCTAssertEqual(events.count, 60)
        XCTAssertFalse(try XCTUnwrap(events.first { $0.kind == .answered }).text.contains("private"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil).isEmpty)
        let restarted = HookEventReader(directory: space.root)
        let restored = await restarted.events()
        XCTAssertEqual(Set(restored.map(\.key)), Set(events.map(\.key)))
    }

    func testNewestEventResolvesWaitingAndLegacyKeysStayStable() async throws {
        let space = try TestSpace(); let clock = TestClock()
        _ = try space.file("events.jsonl", "{\"kind\":\"waiting\",\"session\":\"s\",\"at\":\(clock.date.timeIntervalSince1970)}\n{\"kind\":\"answered\",\"session\":\"s\",\"at\":\(clock.date.timeIntervalSince1970 + 1)}\n")
        clock.date.addTimeInterval(2)
        let reader = HookEventReader(directory: space.root, now: { clock.date })
        let events = await reader.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .answered)
        let again = await reader.events()
        XCTAssertEqual(events.map(\.key), again.map(\.key))
    }

    func testFailedStateSavePreservesUnreadSpool() async throws {
        let space = try TestSpace()
        _ = try space.file("events/e.json", "{\"kind\":\"waiting\",\"session\":\"s\",\"at\":\(Date().timeIntervalSince1970)}")
        try FileManager.default.createDirectory(at: space.root.appendingPathComponent("event-state.json"), withIntermediateDirectories: true)
        let reader = HookEventReader(directory: space.root)
        _ = await reader.events()
        XCTAssertTrue(FileManager.default.fileExists(atPath: space.root.appendingPathComponent("events/e.json").path))
    }
}
