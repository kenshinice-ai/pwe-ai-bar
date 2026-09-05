import AppKit
import SwiftUI

/// SwiftUI wrapper over the shared renderer. The panel asks for five colours; the menu bar and
/// any small mark ask for one. Both go through `WingGauge`, so a feather's length can never
/// disagree with the number printed beside it.
struct WingView: NSViewRepresentable {
    var channels: [ChannelHealth] = []
    var perFeather: Bool = true
    /// Which feather to pick out. The brand standard's own exception for derived instruments is
    /// what allows this: the mark may move as an instrument, it may not move as identity — and
    /// an instrument you can put a question to is exactly what that clause is for.
    var highlight: Channel?
    /// Nil while the pointer is off the mark. Only wired up in the panel; the menu bar and the
    /// notch banner pass nothing and behave as before.
    var onHover: ((Channel?) -> Void)?
    var onPick: ((Channel) -> Void)?
    /// Draw the identity form instead — no gauge. For headers and the notch banner, where the
    /// mark is a signature rather than an instrument.
    var solid: Bool = false
    var tint: Color = Theme.accent
    /// What a screen reader says instead of "image".
    var spoken: String?

    func makeNSView(context: Context) -> WingNSView { WingNSView() }

    func updateNSView(_ v: WingNSView, context: Context) {
        v.channels = channels
        v.perFeather = perFeather
        v.highlight = highlight
        v.onHover = onHover
        v.onPick = onPick
        v.solid = solid || channels.isEmpty
        v.tint = NSColor(tint)
        v.ink = NSColor(Theme.text)
        v.setAccessibilityRole(.image)
        v.setAccessibilityLabel(spoken ?? "PWE 翼形仪表")
        v.needsDisplay = true
    }
}

final class WingNSView: NSView {
    var channels: [ChannelHealth] = []
    var perFeather = true
    var solid = false
    var tint: NSColor = .labelColor
    var ink: NSColor = .labelColor
    var highlight: Channel? { didSet { if highlight != oldValue { needsDisplay = true } } }
    var onHover: ((Channel?) -> Void)?
    var onPick: ((Channel) -> Void)?

    override func draw(_ dirty: NSRect) {
        if solid {
            BrandMark.draw(in: bounds, color: tint)
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        WingGauge.draw(channels, in: bounds, calmInk: ink, dark: dark, perFeather: perFeather)
        guard let highlight, onPick != nil else { return }
        // Outline rather than recolour: the fill already carries the health, and repainting it
        // to show a selection would be the one thing this gauge must never do — say a different
        // thing about the reading than the number beside it.
        let paths = BrandMark.paths(in: bounds)
        guard highlight.rawValue < paths.count else { return }
        let outline = paths[highlight.rawValue].copy() as! NSBezierPath
        outline.lineWidth = 1.2
        ink.withAlphaComponent(0.85).setStroke()
        outline.stroke()
    }

    // MARK: Pointing at a feather

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onPick != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(feather(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Without this the mark looks like the decoration it used to be. The pointer changing
        // is the only cue that the feathers can be asked anything.
        guard onPick != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func mouseDown(with event: NSEvent) {
        guard let c = feather(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(c)
    }

    /// Nearest feather by distance to its own axis.
    ///
    /// Hit-testing the outlines themselves is the obvious approach and the wrong one: the
    /// feathers are slivers a couple of points wide at the root and they fan apart, so most of
    /// the mark's area belongs to no feather at all and the pointer falls through the gaps.
    /// Distance to the axis divides the whole shape between the five with no dead zones.
    func feather(at point: CGPoint) -> Channel? {
        var best: (channel: Channel, distance: CGFloat)?
        for k in 0..<BrandMark.count {
            guard let channel = Channel(rawValue: k) else { continue }
            let axis = BrandMark.axis(k, in: bounds)
            let d = Self.distance(from: point, to: axis.root, axis.tip)
            if best == nil || d < best!.distance { best = (channel, d) }
        }
        guard let best, best.distance < bounds.width * 0.2 else { return nil }
        return best.channel
    }

    private static func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
