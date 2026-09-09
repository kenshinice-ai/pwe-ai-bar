import XCTest
@testable import PWEAIBar

/// The localisation's one silent failure mode, and the typography exception that rides on it.
///
/// When the `.lproj` bundle cannot be resolved, every lookup falls back to the English written at
/// the call site — so the app renders *identically* in both languages and looks completely fine.
/// That is exactly what happened twice while this was being built: first the directories were
/// nested inside another processed resource directory and SwiftPM shipped neither, then SwiftPM
/// wrote `zh-Hans.lproj` into the bundle as `zh-hans.lproj` and the lookup missed it on case.
/// Both times the build was green, the tests passed, and the panel was English either way.
final class LocalisationTests: XCTestCase {

    override func tearDown() { Loc.language = .en; super.tearDown() }

    func testTheChineseTableIsActuallyReachable() {
        Loc.language = .zhHans
        XCTAssertEqual(Loc.effective, "zh-Hans")
        let translated = L("panel.refresh", "Refresh")
        XCTAssertNotEqual(translated, "Refresh",
                          "the zh-Hans bundle did not resolve — every string silently fell back to "
                          + "the English at its call site, which renders as a perfectly fine English app")
        XCTAssertEqual(translated, "刷新")
    }

    func testEnglishComesFromTheCallSiteAndNotFromATable() {
        Loc.language = .en
        XCTAssertEqual(L("panel.refresh", "Refresh"), "Refresh")
        // A key nobody has ever translated must still render, in English, rather than as the key.
        XCTAssertEqual(L("no.such.key.anywhere", "Fallback text"), "Fallback text")
    }

    /// §7.2 of the brand standard: the +0.18em small-caps tracking is a Latin rule, and Han runs
    /// one point larger at 0.4× of it. Spacing out 汉字 separates a word instead of opening a line.
    func testHanLabelsTakeTheTypographyException() {
        Loc.language = .en
        XCTAssertEqual(Theme.labelSize(8.5), 8.5)
        XCTAssertEqual(Theme.labelTracking(1.53), 1.53, accuracy: 0.001)

        Loc.language = .zhHans
        XCTAssertEqual(Theme.labelSize(8.5), 9.5, "Han runs a point larger")
        XCTAssertEqual(Theme.labelTracking(1.53), 1.53 * 0.4, accuracy: 0.001)
    }

    /// Every language the picker offers has to be one the bundle can actually produce.
    func testEveryOfferedLanguageResolves() {
        for lang in Language.allCases {
            Loc.language = lang
            XCTAssertTrue(Loc.supported.contains(Loc.effective),
                          "\(lang.rawValue) resolves to \(Loc.effective), which is not a shipped table")
        }
    }
}

/// Small display formatters that were each wrong in a way a screenshot showed and a test did not.
final class TrophyFormattingTests: XCTestCase {
    override func setUp() { super.setUp(); Loc.language = .en }

    /// `claude-fable-5-1` used to render as `fable 5 1` — two numbers, next to `opus 5` which is
    /// one. A point release is a version, not a third word.
    @MainActor func testAPointReleaseStaysOneNumber() {
        let v = TrophyView(trophy: Trophy())
        XCTAssertEqual(v.shortModelName("claude-fable-5-1"), "fable 5.1")
        XCTAssertEqual(v.shortModelName("claude-opus-5"), "opus 5")
        XCTAssertEqual(v.shortModelName("claude-haiku-4-5"), "haiku 4.5")
        XCTAssertEqual(v.shortModelName("gpt-5-6-sol"), "gpt 5.6 sol")
    }
}


/// 1.0.0 through 1.0.12 crashed on every Mac but the build machine, because SwiftPM's generated
/// `Bundle.module` looks for the resource bundle at the .app root and then at an absolute build
/// path. `Bundle.resources` is the one accessor now, and these keep it that way.
final class ResourceBundleTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Structural, because the failure only reproduces on a machine without the checkout: no
    /// source file may reach for the generated accessor except the one that wraps it.
    func testOnlyTheWrapperUsesTheGeneratedAccessor() throws {
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files where file.lastPathComponent != "Resources.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("Bundle.module"),
                           "\(file.lastPathComponent) reaches past Bundle.resources — that path only exists on the build machine")
        }
    }

    /// Every resource the app touches at launch, through the accessor the app uses. In a test
    /// host this resolves via the build path, which is the point: it proves the files exist, and
    /// `build-app.sh --selfcheck` proves they travel.
    func testEveryLaunchResourceResolvesThroughTheOneAccessor() throws {
        let b = Bundle.resources
        for face in ["Inter", "PlayfairDisplay"] {
            XCTAssertNotNil(b.url(forResource: face, withExtension: "ttf"), face)
        }
        XCTAssertNotNil(b.url(forResource: "pricing", withExtension: "json"))
        XCTAssertNotNil(b.url(forResource: "pwe-ai-bar-hook", withExtension: "sh"))
        let names = try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(b.resourceURL).path)
        for lang in ["en.lproj", "zh-hans.lproj"] {
            XCTAssertTrue(names.contains { $0.lowercased() == lang }, lang)
        }
    }
}

/// Nothing shown to a reader may hand them a command to type. The people who need a quota meter
/// are not the people who have a terminal open, and this app spent its first releases ending every
/// dead end in "run claude auth login in a terminal" — on one Mac that answered
/// `zsh: command not found`. Every one of those is a button now.
final class NoTerminalHomeworkTests: XCTestCase {
    private var tables: [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ["en", "zh-Hans"].compactMap { lang in
            let url = root.appendingPathComponent("Sources/PWEAIBar/\(lang).lproj/Localizable.strings")
            return (try? String(contentsOf: url, encoding: .utf8)).map { (lang, $0) }
        }
    }

    func testNoUserFacingStringTellsAnyoneToTypeACommand() throws {
        XCTAssertEqual(tables.count, 2, "both tables have to be readable for this to mean anything")
        for (lang, text) in tables {
            for line in text.split(separator: "\n") where line.hasPrefix("\"") {
                XCTAssertFalse(line.contains("claude auth login"),
                               "\(lang): \(line) — that is homework, not an instruction; give a button")
            }
        }
    }

    /// English is generated from the `L("key", "English")` defaults by `Tools/loccheck`, so editing
    /// `en.lproj` by hand is a write that the next build silently reverts. It cost two rounds of
    /// "fixed" that was not fixed, so it is asserted rather than remembered.
    func testEnglishIsGeneratedFromTheCallSites() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tool = try String(contentsOf: root.appendingPathComponent("Tools/loccheck/main.swift"),
                              encoding: .utf8)
        XCTAssertTrue(tool.contains("en.lproj") && tool.contains("write(toFile:"),
                      "if loccheck stops generating en.lproj, this test's premise is gone and the "
                      + "handoff needs correcting with it")
    }
}
