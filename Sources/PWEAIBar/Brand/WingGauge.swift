import AppKit

/// The wing mark drawn as a live gauge — the one thing brand standard §7.1 permits the mark to do
/// that the identity form may not. Every feather is a channel: how far the colour has travelled
/// out the feather is how close that channel is to trouble, and the colour itself is which tier it
/// has entered. Both come from the same `ChannelHealth`, so they cannot contradict each other.
///
/// Menu bar and panel share this renderer. They differ in one flag: `perFeather`. A 22 pt bar
/// cannot carry five colours — the feathers there are about 1 pt thick, and five tints collapse
/// into a mottled streak that says "something" without saying what. So the bar shows the overall
/// band and the panel, where a feather is thick enough to read, shows all five.
enum WingGauge {

    /// Alpha of the unlit part of a feather — the stretch a warm or hot channel has not reached
    /// yet. High enough that the feather still reads as part of the mark rather than a broken
    /// stub. Calm channels never show it: they are drawn solid.
    ///
    /// A faint rail against a lit feather is exactly the distinction Increase Contrast exists to
    /// rescue, so under that setting it climbs until the whole feather is plainly there and only
    /// the colour separates reached from unreached.
    static func railAlpha(_ dark: Bool) -> CGFloat {
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return dark ? 0.80 : 0.72 }
        return dark ? 0.42 : 0.30
    }

    /// Halo for a feather that has crossed its threshold. Hot only, and only on the feather that
    /// crossed — if everything glows, glowing stops being a signal. On paper a bright halo reads
    /// as a smudge, so the light theme keeps it tighter and darker.
    static func glow(_ dark: Bool) -> (alpha: CGFloat, blur: CGFloat) {
        dark ? (0.55, 3.5) : (0.30, 2.2)
    }

    private static let softEdge: CGFloat = 0.06

    static func draw(_ channels: [ChannelHealth], in rect: CGRect,
                     calmInk: NSColor, dark: Bool, perFeather: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !channels.isEmpty else { return }
        let feathers = BrandMark.paths(in: rect)
        let rail = calmInk.withAlphaComponent(railAlpha(dark))
        let space = CGColorSpaceCreateDeviceRGB()
        let g = glow(dark)

        // In the bar every feather carries the worst channel, so the glyph still answers the one
        // question a menu bar can answer: is anything wrong?
        let worstBand = channels.map(\.band).max() ?? .calm
        let worstFill = channels.map(\.fill).max() ?? 0

        for (k, path) in feathers.enumerated() {
            let ch = perFeather ? channels[min(k, channels.count - 1)] : nil
            let band = ch?.band ?? worstBand
            let fill = CGFloat(ch?.fill ?? worstFill)
            let tint = band == .calm ? calmInk : Theme.healthNS(band, dark: dark)

            if band == .hot {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: g.blur, color: tint.withAlphaComponent(g.alpha).cgColor)
                tint.setFill()
                path.fill()
                ctx.restoreGState()
            }

            // A calm channel gets no gauge at all, only the solid mark. This is the interface's
            // colour rule carried into shape: a normal reading spends none of the reader's
            // attention. It also means the mark is whole whenever nothing is wrong — five
            // feathers each breaking at a different fill position reads as damage, not data —
            // and that a quiet machine shows the identity exactly as the standard draws it.
            if band == .calm {
                calmInk.setFill()
                path.fill()
                continue
            }

            ctx.saveGState()
            path.addClip()
            let f = min(1, max(0, fill))
            let stops: [CGFloat] = [0, max(0, f - 0.001), min(1, f + softEdge), 1]
            let colours = [tint.cgColor, tint.cgColor, rail.cgColor, rail.cgColor] as CFArray
            let (root, tip) = BrandMark.axis(k, in: rect)
            if let grad = CGGradient(colorsSpace: space, colors: colours, locations: stops) {
                ctx.drawLinearGradient(grad, start: root, end: tip,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Menu-bar cache
    //
    // Worth its weight, but only just — and only because of the halo. Measured with
    // `pwemon --bench-icon`, rasterising the whole glyph: 0.70 ms uncached, 1.11 ms uncached in
    // hot where the blur runs, against 0.45 ms on a cache hit. At a one-second interval that is
    // 0.11 % of a core saved in the state the machine is least able to spare it.
    //
    // The key must name every input. It once omitted `calmInk`, which would have served a light
    // glyph from a dark entry the moment anything but `dark` decided the ink.
    private static let bar = NSCache<NSString, NSImage>()

    static func barImage(_ channels: [ChannelHealth], size: CGSize,
                         calmInk: NSColor, dark: Bool) -> NSImage {
        let band = channels.map(\.band).max() ?? .calm
        // 5 % steps: below a tenth of a point at menu-bar width, so invisible, and it turns a
        // continuously drifting reading into a handful of distinct images.
        let step = Int(((channels.map(\.fill).max() ?? 0) * 20).rounded())
        let ink = calmInk.usingColorSpace(.sRGB) ?? calmInk
        let key = """
        \(band.rawValue)|\(step)|\(dark)|\(Int(size.width))x\(Int(size.height))\
        |\(ink.redComponent)-\(ink.greenComponent)-\(ink.blueComponent)-\(ink.alphaComponent)
        """ as NSString
        if let hit = bar.object(forKey: key) { return hit }
        // `channel` is unused when `perFeather` is false — the whole mark takes one band. Named
        // here only because ChannelHealth requires it; PWE AI Bar's outermost feather stands in
        // for MAC MONITOR's `.cpu`.
        let quantised = [ChannelHealth(channel: .session, band: band, fill: Double(step) / 20)]
        let image = NSImage(size: size, flipped: false) { r in
            draw(quantised, in: r, calmInk: calmInk, dark: dark, perFeather: false)
            return true
        }
        bar.setObject(image, forKey: key)
        return image
    }
}
