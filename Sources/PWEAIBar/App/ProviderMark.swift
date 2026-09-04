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

    /// Claude — a radial burst of tapered blades.
    ///
    /// Three things make it read as this mark rather than a generic star. The blades are
    /// lenses, not spikes: widest around their middle and coming to a point at both ends, so
    /// the mark has weight without a heavy centre. They stop short of the origin, leaving a
    /// small open eye where a filled hub would otherwise turn the whole thing into a sun. And
    /// their lengths vary on a short irregular cycle, which is what separates a drawn burst
    /// from a compass rose.
    private static func burst(in rect: CGRect) -> NSBezierPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let path = NSBezierPath()

        let lengths: [CGFloat] = [1.0, 0.80, 0.93, 0.78, 1.0, 0.83, 0.96, 0.76, 0.99, 0.86]
        let n = lengths.count
        let rIn = r * 0.17                  // the open eye
        // Narrow enough that ten blades stay separate at 13 pt: any fatter and the burst
        // closes up into a daisy, which is a different mark and the wrong one.
        let width = r * 0.088

        for (i, len) in lengths.enumerated() {
            // Half a step of rotation so no blade sits dead vertical — a mark that lines up
            // with the pixel grid reads as a widget, not a logo.
            let a = (CGFloat(i) + 0.5) * 2 * .pi / CGFloat(n) - .pi / 2
            let dir = CGPoint(x: cos(a), y: sin(a))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let rOut = r * len
            let span = rOut - rIn

            func at(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
                CGPoint(x: c.x + dir.x * (rIn + span * t) + perp.x * width * side,
                        y: c.y + dir.y * (rIn + span * t) + perp.y * width * side)
            }
            let inner = at(0, 0), outer = at(1, 0)

            path.move(to: inner)
            // Fullest in the inner third, so the blades read as radiating outward and taper
            // to needle tips rather than bulging into petals.
            path.curve(to: outer, controlPoint1: at(0.22, 1), controlPoint2: at(0.60, 1))
            path.curve(to: inner, controlPoint1: at(0.60, -1), controlPoint2: at(0.22, -1))
            path.close()
        }
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
            let t = CGAffineTransform(translationX: c.x, y: c.y)
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
