import AppKit
import SwiftUI

/// A provider silhouette in SwiftUI. Same paths the menu bar draws, so the mark you learn in
/// the bar is the one you see in the panel.
struct ProviderMarkView: NSViewRepresentable {
    let provider: Provider
    var tint: Color = Theme.text

    func makeNSView(context: Context) -> MarkNSView { MarkNSView() }
    func updateNSView(_ v: MarkNSView, context: Context) {
        v.provider = provider
        v.tint = NSColor(tint)
        v.needsDisplay = true
    }
}

final class MarkNSView: NSView {
    var provider: Provider = .claude
    var tint: NSColor = .labelColor
    override func draw(_ dirty: NSRect) {
        ProviderMark.draw(provider, in: bounds, color: tint)
    }
}
