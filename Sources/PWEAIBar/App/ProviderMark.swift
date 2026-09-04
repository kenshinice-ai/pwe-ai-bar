import AppKit

/// Each provider's silhouette, drawn as a monochrome path.
///
/// A letter in a box ("C", "X") is legible but not recognisable — you have to read it, and two
/// letters look like each other at 14 pt. A silhouette is recognised before it is read, which is
/// the whole job here: telling Claude from Codex at a glance, in a bar you are not looking at.
///
/// Monochrome and vector, for three reasons that happen to agree. Full-colour logos turn to mud
/// at menu-bar size; the Paradise standard forbids gradients and effects on marks; and a single
/// tinted silhouette can carry the health colour, which a fixed-colour logo cannot. AI Usage
/// reaches the same conclusion from the other direction — it ships its provider art as
/// grayscale template SVGs and lets the system tint them.
///
/// These are simplified identifying marks drawn from scratch, not copies of the brand files.
/// They exist to say which tool a number belongs to, which is what identification marks are for.
enum ProviderMark {

    static func draw(_ p: Provider, in rect: CGRect, color: NSColor) {
        switch p {
        case .claude: color.setFill(); burst(in: rect).fill()
        case .gemini: color.setFill(); spark(in: rect).fill()
        case .codex:
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(knot(in: rect))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Claude — a radial burst of tapered rays, unequal in length. Spiky, asymmetric, and
    /// nothing else in a menu bar looks like it.
    private static func burst(in rect: CGRect) -> NSBezierPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let path = NSBezierPath()
        // Ray lengths repeat in a short irregular cycle so the burst reads as drawn rather
        // than generated — an even star is a different mark entirely.
        let lengths: [CGFloat] = [1.0, 0.62, 0.86, 0.70, 1.0, 0.66, 0.90, 0.62, 0.96, 0.72]
        let half = CGFloat.pi / CGFloat(lengths.count) * 0.30   // ray half-width at the root
        for (i, len) in lengths.enumerated() {
            let a = CGFloat(i) * 2 * .pi / CGFloat(lengths.count) - .pi / 2
            let tip = CGPoint(x: c.x + cos(a) * r * len, y: c.y + sin(a) * r * len)
            let l = CGPoint(x: c.x + cos(a - half) * r * 0.20, y: c.y + sin(a - half) * r * 0.20)
            let rr = CGPoint(x: c.x + cos(a + half) * r * 0.20, y: c.y + sin(a + half) * r * 0.20)
            path.move(to: l)
            path.curve(to: tip, controlPoint1: l, controlPoint2: tip)
            path.curve(to: rr, controlPoint1: tip, controlPoint2: rr)
            path.close()
        }
        // A small hub keeps the rays from reading as loose specks when the icon is scaled down.
        path.appendOval(in: CGRect(x: c.x - r * 0.17, y: c.y - r * 0.17,
                                   width: r * 0.34, height: r * 0.34))
        return path
    }

    /// Codex — the six-fold woven rosette. Closed, rounded and geometric: the opposite
    /// silhouette to the burst, which is what makes the pair readable side by side.
    ///
    /// Built by stroking six rotated ellipses and filling the result. The obvious construction —
    /// six filled ovals under the even-odd rule — renders as nothing at all: every lobe overlaps
    /// an even number of its neighbours and the whole mark cancels itself out.
    private static func knot(in rect: CGRect) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let ring = CGMutablePath()
        for i in 0..<6 {
            var t = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: CGFloat(i) * .pi / 3)
                .translatedBy(x: -c.x, y: -c.y)
            ring.addEllipse(in: CGRect(x: c.x - r * 0.92, y: c.y - r * 0.36,
                                       width: r * 1.84, height: r * 0.72),
                            transform: t)
        }
        // Stroke width scales with the mark: a fixed width closes the weave at 13 pt and turns
        // it into a disc.
        return ring.copy(strokingWithWidth: max(1, r * 0.24),
                         lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// Gemini — the four-point spark, concave between the points.
    private static func spark(in rect: CGRect) -> NSBezierPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2 - .pi / 2
            let next = a + .pi / 2
            let tip = CGPoint(x: c.x + cos(next) * r, y: c.y + sin(next) * r)
            path.curve(to: tip,
                       controlPoint1: CGPoint(x: c.x + cos(a) * r * 0.16, y: c.y + sin(a) * r * 0.16),
                       controlPoint2: CGPoint(x: c.x + cos(next) * r * 0.16, y: c.y + sin(next) * r * 0.16))
        }
        path.close()
        return path
    }
}
