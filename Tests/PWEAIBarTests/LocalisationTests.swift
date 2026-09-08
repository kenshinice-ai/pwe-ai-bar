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
