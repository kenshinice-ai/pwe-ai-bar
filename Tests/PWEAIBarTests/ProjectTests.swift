import Foundation
import XCTest
@testable import PWEAIBar

/// "Where did the last seven days go": the trophy page split by the folder each session ran in.
final class ProjectTests: XCTestCase {
    override func setUp() { super.setUp(); Loc.language = .en }
    private var pricing: Pricing { Pricing.load() }
    private let root = "/Users/someone/.claude/projects"

    private func today() -> Int {
        Int(floor((Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())) / 86400))
    }
    private func counts(_ usd: Double, turns: Int = 1) -> Transcript.Counts {
        .init(turns: turns, input: 0, output: 0, cacheWrite: 0, cacheRead: 0, usd: usd)
    }

    // MARK: Which project a log belongs to

    /// The folder under `.claude/projects`, whatever is below it — a subagent's log sits two
    /// levels deeper and still belongs to the session's project.
    func testALogBelongsToTheFolderItIsIn() {
        XCTAssertEqual(Transcript.projectKey(root + "/-Users-someone-Work/abc.jsonl", claudeRoot: root),
                       "-Users-someone-Work")
        XCTAssertEqual(Transcript.projectKey(root + "/-Users-someone-Work/abc/subagents/x.jsonl", claudeRoot: root),
                       "-Users-someone-Work")
    }

    /// One project would otherwise fill the list with its own branches.
    func testAWorktreeIsFoldedIntoItsProject() {
        XCTAssertEqual(Transcript.projectKey(root + "/-Users-someone-studio--claude-worktrees-audit-073a82/a.jsonl",
                                             claudeRoot: root),
                       "-Users-someone-studio")
    }

    func testCodexLogsAreOneRow() {
        XCTAssertEqual(Transcript.projectKey("/Users/someone/.codex/sessions/2026/10/16/rollout.jsonl",
                                             claudeRoot: root), Transcript.codexProject)
        XCTAssertEqual(Transcript.projectName(Transcript.codexProject), "Codex")
    }

    // MARK: What it is called

    /// The folder's own name, found on disk: "My Work/PWE AI Bar" and "My/Work/PWE/AI/Bar" mangle
    /// to the same key, so string editing alone cannot tell which the key stands for.
    func testTheNameIsTheFolderOnDisk() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("proj-" + UUID().uuidString)
        let folder = base.appendingPathComponent("My Work/PWE AI Bar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let key = Transcript.mangle(folder.path)
        XCTAssertEqual(Transcript.projectName(key, root: base.path, home: "/nowhere"), "PWE AI Bar")
    }

    /// A folder that is gone is still named, from the key, without the home folder and iCloud.
    func testAFolderThatIsGoneIsNamedFromItsKey() {
        let key = "-Users-someone-Library-Mobile-Documents-com-apple-CloudDocs-Old-Client-Site"
        XCTAssertEqual(Transcript.projectName(key, root: "/nonexistent", home: "/Users/someone"),
                       "Old Client Site")
    }

    func testTheHomeFolderAndANonLatinNameReadAsWords() {
        XCTAssertEqual(Transcript.projectName("-Users-someone", root: "/nonexistent", home: "/Users/someone"),
                       "Home folder")
        XCTAssertEqual(Transcript.projectName("-Users-someone-Documents-----", root: "/nonexistent",
                                              home: "/Users/someone"),
                       "Folder with a non-Latin name")
    }

    // MARK: The figures

    /// The rows add up to the headline, follow the range, and come largest first.
    func testTheRowsAddUpToTheHeadlineAndFollowTheRange() {
        let day = today()
        var d = Transcript.Digest()
        d.add(day: day, model: "claude-opus-5", counts(30, turns: 3))
        d.add(day: day - 2, model: "claude-opus-5", counts(12, turns: 2))
        d.add(day: day - 60, model: "claude-opus-5", counts(500, turns: 99))
        let projects: [Int: [String: Transcript.Counts]] = [
            day: ["a": counts(10, turns: 1), "b": counts(20, turns: 2)],
            day - 2: ["a": counts(12, turns: 2)],
            day - 60: ["c": counts(500, turns: 99)],
        ]
        let week = Transcript.assemble(d, pricing: pricing, range: .week, subscription: nil,
                                       projects: projects).trophy
        XCTAssertEqual(week.byProject.map(\.name), ["a", "b"], "largest first; c is outside the week")
        XCTAssertEqual(week.byProject.map(\.usd).reduce(0, +), week.equivalentUSD, accuracy: 0.001)
        XCTAssertEqual(week.byProject.first?.turns, 3)

        let all = Transcript.assemble(d, pricing: pricing, range: .all, subscription: nil,
                                      projects: projects).trophy
        XCTAssertEqual(all.byProject.first?.name, "c")
        XCTAssertEqual(all.byProject.map(\.usd).reduce(0, +), all.equivalentUSD, accuracy: 0.001)
        XCTAssertNil(all.previousUSD, "all time has no span before it")
    }

    /// "The 7 d before" is the seven days ending where this week begins — not overlapping it.
    func testThePreviousSpanIsTheSameLengthImmediatelyBefore() {
        let day = today()
        var d = Transcript.Digest()
        d.add(day: day, model: "claude-opus-5", counts(40))
        d.add(day: day - 6, model: "claude-opus-5", counts(2))   // this week, its first day
        d.add(day: day - 7, model: "claude-opus-5", counts(25))  // the week before, its last day
        d.add(day: day - 13, model: "claude-opus-5", counts(5))  // the week before, its first day
        d.add(day: day - 14, model: "claude-opus-5", counts(900)) // two weeks back: neither
        let week = Transcript.assemble(d, pricing: pricing, range: .week, subscription: nil).trophy
        XCTAssertEqual(week.equivalentUSD, 42, accuracy: 0.001)
        XCTAssertEqual(week.previousUSD ?? -1, 30, accuracy: 0.001)
    }

    /// Published renders say "Project A", never a folder name: folder names are often clients'.
    func testRedactedNamesAreLetters() {
        XCTAssertEqual(TrophyView.redacted(0), "Project A")
        XCTAssertEqual(TrophyView.redacted(2), "Project C")
    }
}
