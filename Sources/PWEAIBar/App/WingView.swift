import AppKit
import SwiftUI

/// SwiftUI wrapper over the shared renderer. The panel asks for five colours; the menu bar and
/// any small mark ask for one. Both go through `WingGauge`, so a feather's length can never
/// disagree with the number printed beside it.
struct WingView: NSViewRepresentable {
    var channels: [ChannelHealth] = []
    var perFeather: Bool = true
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
        v.solid = solid || channels.isEmpty
        v.tint = NSColor(tint)
        v.ink = NSColor(Theme.text)
        v.setAccessibilityRole(.image)
        v.setAccessibilityLabel(spoken ?? L("wing.a11y", "PWE wing gauge"))
        v.needsDisplay = true
    }
}

final class WingNSView: NSView {
    var channels: [ChannelHealth] = []
    var perFeather = true
    var solid = false
    var tint: NSColor = .labelColor
    var ink: NSColor = .labelColor

    override func draw(_ dirty: NSRect) {
        if solid {
            BrandMark.draw(in: bounds, color: tint)
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        WingGauge.draw(channels, in: bounds, calmInk: ink, dark: dark, perFeather: perFeather)
    }
}
