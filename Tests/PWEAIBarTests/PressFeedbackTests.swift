import AppKit
import SwiftUI
import XCTest
@testable import PWEAIBar

/// Every pressable thing acknowledges the press.
///
/// Ten buttons in the panel and the settings page used the plain style, which draws nothing at
/// all when pressed. For the ones whose effect is instant that is merely flat; for a refresh
/// (a second away) or a provider pin (whose only visible result is a one-pixel underline
/// somewhere else) it is indistinguishable from a button that did not work — which is the same
/// symptom the keychain button shipped with, and the same fix.
final class PressFeedbackTests: XCTestCase {

    private func sources() throws -> [(name: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoPressableIsLeftWithoutFeedback() throws {
        // Assembled rather than written out, so that this file's own explanation of the rule
        // cannot be what the scan finds. Two structural tests in this project have been tripped
        // by their own comments already.
        let plain = ".buttonStyle" + "(.plain)"
        for (name, code) in try sources() {
            XCTAssertFalse(code.contains(plain),
                           "\(name) has a button that draws nothing when pressed — use PressStyle")
        }
    }

    /// The link style is allowed and deliberate: a link already reports its press by colouring,
    /// and scaling text inside a sentence is worse than leaving it alone.
    func testTheStyleIsActuallyUsed() throws {
        let used = try sources().filter { $0.code.contains("PressStyle(") }
        XCTAssertGreaterThanOrEqual(used.count, 2, "the panel and the settings page both have pressables")
    }

    /// Reduced motion asks for less movement, not less feedback. With it on, neither shape
    /// scales — so the wash is the only thing left, and it has to be what happens.
    func testReducedMotionDropsTheScaleAndNotTheFeedback() {
        XCTAssertTrue(PressStyle.scales(shape: .control, reduceMotion: false))
        XCTAssertFalse(PressStyle.scales(shape: .control, reduceMotion: true),
                       "a control must stop scaling when movement is reduced")
        XCTAssertFalse(PressStyle.scales(shape: .row, reduceMotion: false),
                       "a full-width row never scales — it washes, like a selected table row")
        XCTAssertFalse(PressStyle.scales(shape: .row, reduceMotion: true))
    }

    /// Both shapes actually lay out. A style that silently produces nothing would pass every
    /// assertion above and leave a blank panel.
    @MainActor func testBothShapesLayOut() {
        for shape in [PressStyle.Shape.control, .row] {
            let host = NSHostingView(rootView: Button("x") {}.buttonStyle(PressStyle(shape: shape)))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, "\(shape) produced no view")
        }
    }
}
