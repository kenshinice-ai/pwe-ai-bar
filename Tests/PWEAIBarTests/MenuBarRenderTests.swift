import AppKit
import XCTest
@testable import PWEAIBar

/// The menu-bar glyph, drawn the way the app draws it.
///
/// This is the surface someone looks at all day and the only one they see without opening
/// anything — and it had no rendered check at all, while the panel, the settings page and the
/// trophy page each had one. That gap is uncomfortable in general and specifically: the glyph
/// draws its own figures, so a change of typeface moves every width in it, and truncation here
/// is not cosmetic — the bar drops readings to fit.
///
/// Writes PNGs to `$OUT` alongside the other renders, so the three modes and both appearances
/// can be looked at rather than reasoned about.
final class MenuBarRenderTests: XCTestCase {

    /// Settings stated here rather than inherited from whichever Mac runs the test: both
    /// providers tracked, both in the bar, percentages as remaining.
    @MainActor private func prefs(_ space: TestSpace) -> Prefs {
        let p = Prefs(defaults: space.defaults)
        p.setTracking(.claude, true); p.setTracking(.codex, true)
        p.showRemaining = true
        return p
    }

    @MainActor private func snapshot(waiting: Bool = false) -> Snapshot {
        var snap = Snapshot()
        let at = Date()
        snap.windows = [
            QuotaWindow(id: "w", provider: .claude, channel: .week, title: L("channel.week", "Weekly"),
                        percent: 72, severity: .normal, resetsAt: at.addingTimeInterval(86400),
                        isActive: true, windowLength: 7 * 86400),
            QuotaWindow(id: "s", provider: .claude, channel: .session, title: L("channel.session", "5-hour"),
                        percent: 41, severity: .normal, resetsAt: at.addingTimeInterval(5400),
                        isActive: true, windowLength: 5 * 3600),
            QuotaWindow(id: "c", provider: .codex, channel: .codex, title: L("channel.session", "5-hour"),
                        percent: 88, severity: .warning, resetsAt: at.addingTimeInterval(7200)),
        ]
        // `attention` and `waiting` are derived from the events, not set — which is the point:
        // the bar cannot claim someone is waiting unless an event says so.
        if waiting { snap.events = [event(at: at)] }
        return snap
    }

    @MainActor func testEveryModeRendersSomethingThatFitsAMenuBar() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT"] ?? NSTemporaryDirectory())
        _ = NSApplication.shared

        for lang in [Language.en, .zhHans] {
            Loc.language = lang
            for mode in MenuBarMode.allCases {
                for dark in [true, false] {
                    let image = StatusIcon.render(snapshot(), mode: mode, dark: dark, prefs: prefs(try TestSpace()))
                    XCTAssertGreaterThan(image.size.width, 0, "\(lang.rawValue) \(mode.rawValue)")
                    // macOS gives a status item the bar's height and takes whatever width is
                    // asked for. A glyph taller than the bar is clipped, and one wider than a
                    // third of a laptop screen crowds out everybody else's items.
                    XCTAssertLessThanOrEqual(image.size.height, 22, "taller than the menu bar")
                    XCTAssertLessThan(image.size.width, 420, "\(mode.rawValue) is too wide for a menu bar")
                    try write(image, to: out.appendingPathComponent("menubar-\(lang.rawValue)-\(mode.rawValue)-\(dark ? "dark" : "light").png"), dark: dark)
                }
            }
            // Someone waiting on you replaces the readings entirely; it is the one state that
            // must never be the thing that gets truncated away.
            let waiting = StatusIcon.render(snapshot(waiting: true), mode: .full, dark: true, prefs: prefs(try TestSpace()))
            XCTAssertGreaterThan(waiting.size.width, 0)
            try write(waiting, to: out.appendingPathComponent("menubar-\(lang.rawValue)-waiting-dark.png"), dark: true)
        }
    }

    /// The glyph asks for exactly the width it drew. A status item sized from a stale number
    /// leaves either a gap or a clipped reading.
    @MainActor func testIconModeIsJustTheWing() throws {
        _ = NSApplication.shared
        Loc.language = .en
        let icon = StatusIcon.render(snapshot(), mode: .icon, dark: true, prefs: prefs(try TestSpace()))
        let full = StatusIcon.render(snapshot(), mode: .full, dark: true, prefs: prefs(try TestSpace()))
        XCTAssertLessThan(icon.size.width, full.size.width,
                          "icon mode carries no readings, so it cannot be as wide as full")
    }

    /// The attention line says itself, in full.
    ///
    /// It used to say "Claud…". A clipping rule written for a provider `note` — a field that no
    /// longer exists — was the only thing that could still reach this segment, and it cut every
    /// text longer than six characters down to five. The one sentence this app exists to deliver
    /// was the one sentence it truncated, on the surface nobody has to open to see.
    @MainActor func testTheWaitingLineIsNotClipped() throws {
        _ = NSApplication.shared
        for lang in [Language.en, .zhHans] {
            Loc.language = lang
            let whole = StatusIcon.render(snapshot(waiting: true), mode: .full, dark: true, prefs: prefs(try TestSpace()))
            // Measured against the same sentence drawn at its natural width: if the glyph is
            // materially narrower, something took a bite out of it.
            let sentence = String(format: L("menu.waiting", "%@ waiting"), "Claude")
            let natural = (sentence as NSString)
                .size(withAttributes: [.font: Theme.nsNumber(11.5, 500)]).width
            XCTAssertGreaterThan(whole.size.width, natural,
                                 "\(lang.rawValue): the waiting line is narrower than the words it has to say")
        }
    }

    /// Two providers in the bar draw more than one does.
    ///
    /// Sounds tautological; it is the check that catches a reading being silently dropped, which
    /// is what the old `Prefs.shared` read did whenever the machine running the render had a
    /// provider switched off.
    @MainActor func testEachProviderInTheBarAddsToIt() throws {
        _ = NSApplication.shared
        Loc.language = .en
        func width(claude: Bool, codex: Bool) throws -> CGFloat {
            let space = try TestSpace()
            let p = Prefs(defaults: space.defaults)
            p.setTracking(.claude, claude); p.setTracking(.codex, codex)
            p.setMenuBar(.claude, claude); p.setMenuBar(.codex, codex)
            return StatusIcon.render(snapshot(), mode: .full, dark: true, prefs: p).size.width
        }
        let both = try width(claude: true, codex: true)
        let onlyClaude = try width(claude: true, codex: false)
        let onlyCodex = try width(claude: false, codex: true)
        let neither = try width(claude: false, codex: false)
        XCTAssertGreaterThan(onlyClaude, neither, "Claude draws nothing in the bar")
        XCTAssertGreaterThan(onlyCodex, neither, "Codex draws nothing in the bar")
        XCTAssertGreaterThan(both, onlyClaude, "adding Codex did not widen the bar")
        XCTAssertGreaterThan(both, onlyCodex, "adding Claude did not widen the bar")
    }

    /// Saves the glyph on the ground it will actually be drawn on.
    ///
    /// The glyph is white on transparent for a dark menu bar, so a PNG with alpha opens as an
    /// empty strip in most viewers and the readings look like they are missing. They are not —
    /// but a check you cannot look at is not much of a check, and this one existed because the
    /// most important thing in the bar had been quietly clipped for months.
    @MainActor private func write(_ image: NSImage, to url: URL, dark: Bool) throws {
        let size = NSSize(width: image.size.width + 16, height: 22)
        let sheet = NSImage(size: size, flipped: false) { rect in
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            rect.fill()
            image.draw(at: NSPoint(x: 8, y: (22 - image.size.height) / 2),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
