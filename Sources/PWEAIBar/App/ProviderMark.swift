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
        case .cursor: stroke(cube(in: rect), in: rect, color: color, weight: 0.16)
        case .copilot: color.setFill(); goggles(in: rect).fill()
        case .devin: stroke(comb(in: rect), in: rect, color: color, weight: 0.15)
        case .grok: color.setFill(); slash(in: rect).fill()
        case .antigravity: stroke(chevrons(in: rect), in: rect, color: color, weight: 0.2)
        case .codex:
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(knot(in: rect))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Outline marks are stroked rather than filled: at 13 pt a filled cube is a blob and a
    /// filled hexagon is a dot. Stroke weight scales with the mark for the same reason the
    /// rosette's does — a fixed width closes every gap at menu-bar size.
    private static func stroke(_ path: CGPath, in rect: CGRect, color: NSColor, weight: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = min(rect.width, rect.height) / 2
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path.copy(strokingWithWidth: max(1, r * weight),
                              lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Cursor — the isometric cube, drawn as its silhouette plus the two inner edges that make
    /// it read as a solid rather than a hexagon. Those two edges are the whole mark: without
    /// them it is Devin's outline, and the pair have to be told apart in the same list.
    private static func cube(in rect: CGRect) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * 0.86
        let w = r * 0.87                    // half-width of the hex silhouette
        let h = r * 0.5                     // half-height of a face's top edge
        let top = CGPoint(x: c.x, y: c.y + r)
        let bottom = CGPoint(x: c.x, y: c.y - r)
        let upperL = CGPoint(x: c.x - w, y: c.y + h), upperR = CGPoint(x: c.x + w, y: c.y + h)
        let lowerL = CGPoint(x: c.x - w, y: c.y - h), lowerR = CGPoint(x: c.x + w, y: c.y - h)
        let path = CGMutablePath()
        path.addLines(between: [top, upperR, lowerR, bottom, lowerL, upperL, top])
        path.move(to: upperL); path.addLine(to: c)
        path.addLine(to: upperR)
        path.move(to: c); path.addLine(to: bottom)
        return path
    }

    /// GitHub Copilot — the visor. Horizontal where every other mark here is radial, which is
    /// what makes it findable in a row of them.
    private static func goggles(in rect: CGRect) -> NSBezierPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let path = NSBezierPath(roundedRect:
            CGRect(x: c.x - r * 0.98, y: c.y - r * 0.62, width: r * 1.96, height: r * 1.24),
            xRadius: r * 0.62, yRadius: r * 0.62)
        // Two eyes punched out, even-odd. Slits rather than dots: a pair of dots at 13 pt reads
        // as a colon lying down.
        for side in [-1.0, 1.0] as [CGFloat] {
            path.append(NSBezierPath(roundedRect:
                CGRect(x: c.x + side * r * 0.46 - r * 0.17, y: c.y - r * 0.3,
                       width: r * 0.34, height: r * 0.6),
                xRadius: r * 0.17, yRadius: r * 0.17))
        }
        path.windingRule = .evenOdd
        return path
    }

    /// Devin — a hexagon with a hollow centre. The plain outline of the cube without its inner
    /// edges, which is exactly why the cube keeps them.
    private static func comb(in rect: CGRect) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * 0.84
        let path = CGMutablePath()
        for scale in [1.0, 0.42] as [CGFloat] {
            var points: [CGPoint] = []
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 + .pi / 6
                points.append(CGPoint(x: c.x + cos(a) * r * scale, y: c.y + sin(a) * r * scale))
            }
            points.append(points[0])
            path.addLines(between: points)
        }
        return path
    }

    /// Grok — the double slash. Two parallelograms leaning the same way; the only diagonal
    /// silhouette in the set.
    private static func slash(in rect: CGRect) -> NSBezierPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let lean = r * 0.42                 // horizontal travel from bottom to top
        let path = NSBezierPath()
        for (offset, width) in [(-r * 0.42, r * 0.3), (r * 0.42, r * 0.3)] {
            let x = c.x + offset
            path.move(to: CGPoint(x: x - lean, y: c.y - r * 0.92))
            path.line(to: CGPoint(x: x - lean + width, y: c.y - r * 0.92))
            path.line(to: CGPoint(x: x + lean + width, y: c.y + r * 0.92))
            path.line(to: CGPoint(x: x + lean, y: c.y + r * 0.92))
            path.close()
        }
        return path
    }

    /// Antigravity — two stacked chevrons pointing up. The name is the mark.
    private static func chevrons(in rect: CGRect) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        for y in [r * 0.42, -r * 0.34] as [CGFloat] {
            path.addLines(between: [CGPoint(x: c.x - r * 0.8, y: c.y + y - r * 0.42),
                                    CGPoint(x: c.x, y: c.y + y + r * 0.3),
                                    CGPoint(x: c.x + r * 0.8, y: c.y + y - r * 0.42)])
        }
        return path
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
