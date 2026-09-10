import AppKit

/// The menu-bar glyph: the wing as a gauge, plus as much or as little text as the user asked for.
///
/// One colour, never five. A 22 pt bar leaves each feather about a point thick, where five tints
/// collapse into a mottled smear that reports "something" without reporting what — MAC MONITOR
/// proved that with a real-size prototype and the conclusion carries over unchanged. Per-feather
/// detail lives in the panel.
///
/// Nothing here animates. An icon that moves all day is an anxiety source, not an information
/// source; this redraws when the reading changes and jumps, which reports an event more honestly
/// than a fade would — and costs nothing when nothing is happening.
@MainActor
enum StatusIcon {
    static let height: CGFloat = 22
    private static let wingHeight: CGFloat = 11.5      // 18.6 pt wide — the standard's 24 px min at 2x
    private static var wingWidth: CGFloat { wingHeight * BrandMark.aspect }

    private struct Segment {
        let text: String
        let colour: NSColor
        /// A provider segment draws that provider's silhouette instead of text. Recognised
        /// before it is read, which is what separates "which tool" from "how much left"
        /// without asking you to parse either.
        var mark: Provider?
    }

    static func render(_ snap: Snapshot, mode: MenuBarMode, dark: Bool) -> NSImage {
        let remaining = Prefs.shared.showRemaining
        let label: NSColor = dark ? .white : .black
        let font = Theme.nsNumber(11.5, 500)

        var segments: [Segment] = []

        // An event outranks every measurement. Someone is waiting on you; the numbers can wait.
        if let a = snap.attention {
            let tint = Theme.ns(dark ? Theme.amber : Theme.amberDeep)
            let who = snap.waiting > 1 ? String(format: L("menu.sessions", "%d sessions"), snap.waiting)
                : String(a.provider.name.split(separator: " ").first ?? "Claude")
            segments = [Segment(text: "●", colour: tint),
                        Segment(text: String(format: L("menu.waiting", "%@ waiting"), who), colour: tint)]
        } else {
            switch mode {
            case .icon:
                break
            case .compact:
                for p in providers(snap) {
                    segments.append(Segment(text: "", colour: tint(p.band, dark), mark: p.provider))
                    segments.append(Segment(text: Readout.text(p, remaining: remaining), colour: tint(p.band, dark)))
                }
            case .full:
                for p in providers(snap) {
                    segments.append(Segment(text: "", colour: tint(p.band, dark), mark: p.provider))
                    // One countdown for the whole bar could only ever belong to one provider and
                    // the reader had no way to tell which. Per provider it is answerable — but
                    // only if it sits against the number it is counting down, which for Claude
                    // means going between its two figures rather than after both of them.
                    func clock(_ w: QuotaWindow) -> [Segment] {
                        guard w.id == p.id, let c = countdown(w) else { return [] }
                        return [Segment(text: "↻\(c)", colour: label.withAlphaComponent(0.55))]
                    }
                    if p.provider == .claude,
                       let five = snap.window(.session), let week = snap.window(.week) {
                        segments.append(Segment(text: Readout.text(five, remaining: remaining), colour: tint(five.band, dark)))
                        segments += clock(five)
                        segments.append(Segment(text: "/", colour: label.withAlphaComponent(0.45)))
                        segments.append(Segment(text: Readout.text(week, remaining: remaining), colour: tint(week.band, dark)))
                        segments += clock(week)
                    } else {
                        segments.append(Segment(text: Readout.text(p, remaining: remaining), colour: tint(p.band, dark)))
                        segments += clock(p)
                    }
                }
            }
        }

        let gap: CGFloat = 5, lead: CGFloat = 3, trail: CGFloat = 2, markW: CGFloat = 13
        func width(_ s: Segment) -> CGFloat {
            s.mark != nil ? markW : (s.text as NSString)
                .size(withAttributes: [.font: font]).width
        }
        // A provider's `note` is free text from someone else's API. Unclipped, one long one
        // pushes every other reading off the far end of the bar — and on a full menu bar macOS
        // hides the whole item rather than shortening it, so an over-long label does not look
        // untidy, it looks like the app has crashed.
        segments = segments.map { seg in
            guard seg.mark == nil, seg.text.count > 6 else { return seg }
            return Segment(text: String(seg.text.prefix(5)) + "…", colour: seg.colour)
        }
        var widths = segments.map(width)
        // Whole segments come off the tail before anything gets squeezed: half a reading is
        // worse than one fewer reading. The wing and the first provider always survive.
        let ceiling: CGFloat = 260
        while segments.count > 2,
              widths.reduce(0, +) + CGFloat(segments.count - 1) * 5 > ceiling {
            segments.removeLast()
            widths.removeLast()
        }
        let run = widths.reduce(0, +) + CGFloat(max(segments.count - 1, 0)) * gap
        let total = lead + wingWidth + (segments.isEmpty ? 0 : gap + run) + trail

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { rect in
            let box = CGRect(x: lead, y: rect.midY - wingHeight / 2,
                             width: wingWidth, height: wingHeight)
            // One reading, not five. `barImage` takes the worst band of whatever it is handed,
            // so handing it every channel bypasses `Snapshot.overall` and lets a standing
            // condition — a spent credit pool with no percentage and no reset — hold the mark
            // red indefinitely. The bar gets the actionable band and the matching fill.
            let band = snap.overall
            let fill = snap.channels().filter { $0.band <= band }.map(\.fill).max() ?? 0
            let bar = [ChannelHealth(channel: .session, band: band, fill: fill)]
            WingGauge.barImage(bar, size: box.size, calmInk: label, dark: dark).draw(in: box)

            var x = lead + wingWidth + gap
            for (i, seg) in segments.enumerated() {
                if let mark = seg.mark {
                    ProviderMark.draw(mark,
                                      in: NSRect(x: x, y: rect.midY - markW / 2,
                                                 width: markW, height: markW),
                                      color: seg.colour)
                } else {
                    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: seg.colour]
                    let s = seg.text as NSString
                    s.draw(at: NSPoint(x: x, y: (height - s.size(withAttributes: a).height) / 2),
                           withAttributes: a)
                }
                x += widths[i] + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// One row per tracked provider: whichever of its windows is currently tightest.
    private static func providers(_ snap: Snapshot) -> [QuotaWindow] {
        var out: [QuotaWindow] = []
        // One gate, and one that actually gates. The old condition ended in an `||` clause that
        // matched every provider other than the two named ones, which let the remaining five into
        // the menu bar whether or not they were switched on: the switch worked everywhere but
        // here. Worded without the expression on purpose — a structural test looks for it, and a
        // comment quoting the bug reads to that test exactly like the bug.
        for p in Provider.allCases {
            guard Prefs.shared.showsInMenuBar(p) else { continue }
            let mine = snap.windows.filter { $0.provider == p }
            if let worst = mine.max(by: { $0.strain < $1.strain }) { out.append(worst) }
        }
        return out
    }

    private static func tint(_ h: Health, _ dark: Bool) -> NSColor {
        h == .calm ? (dark ? .white : .black) : Theme.healthNS(h, dark: dark)
    }

    /// Time until the window rolls over — the number that actually tells you whether to start
    /// something now or wait.
    private static func countdown(_ snap: Snapshot) -> String? {
        guard let w = snap.protagonist else { return nil }
        return countdown(w)
    }

    private static func countdown(_ w: QuotaWindow) -> String? {
        guard let at = w.resetsAt else { return nil }
        let s = Int(at.timeIntervalSinceNow)
        guard s > 0 else { return nil }
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        // Past a day, hours stop being a unit anyone reads. A weekly window rendered as
        // "215:59", which is not a time so much as a dare.
        if s < 86400 { return String(format: "%d:%02d", s / 3600, (s % 3600) / 60) }
        return String(format: L("compact.day", "%dd"), s / 86400)
    }
}

/// What the menu bar is currently showing.
///
/// Assigning `NSStatusItem.button.image` is not free: it commits a Core Animation transaction
/// and makes AppKit re-resolve the button's effective appearance. So any caller that fires more
/// often than the readout changes becomes a redraw storm — and one did, at about 3,050 a second,
/// because re-resolving the appearance fired the observer that called back into the redraw.
///
/// Compared on the bytes that were drawn rather than on a key naming the inputs: the glyph
/// carries a countdown, so a key would have to know about time, and a key that falls out of step
/// with the renderer freezes the menu bar — a worse bug than the one it fixes.
struct PaintedState {
    private var bytes: Data?
    private var sentence: String?
    private var painted = false

    /// True when this drawing differs from what is on screen, and records it as the new state.
    /// The first call is always true, including for an empty drawing: nothing is on screen yet.
    mutating func adopt(_ bytes: Data?, _ sentence: String) -> Bool {
        guard painted, bytes == self.bytes, sentence == self.sentence else {
            self.bytes = bytes; self.sentence = sentence; painted = true
            return true
        }
        return false
    }
}
