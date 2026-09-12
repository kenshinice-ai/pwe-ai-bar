import AppKit
import SwiftUI

/// The Paradise Production palette and faces, exactly as the brand sheet writes them.
///
/// The accent is stored as a **pair**, never a single value: amber `#F5B335` fails WCAG AA on a
/// light ground, so the sheet forbids it there and requires deep amber `#A16207` instead. Keeping
/// the two apart in the type is what stops a view from accidentally picking the illegal one.
enum Theme {

    // MARK: Palette — brand sheet section 5
    static let navy      = 0x0E1729
    static let navyMid   = 0x16233D
    static let navyLift  = 0x22355A
    static let paper     = 0xF7F5F2
    static let ink       = 0x0C0A09
    static let rule      = 0xE3DFD8
    static let muted     = 0x6B7280
    static let amber     = 0xF5B335   // dark grounds only
    static let amberDeep = 0xA16207   // light grounds only

    static let fieldDark   = 0x101B31
    static let hairlineDark = 0x2A3A57
    static let textDark    = 0xF3F1EE
    static let textDark2   = 0x9BA6BA

    static let goodLight = 0x1E7A46, goodDark = 0x3EBB7C
    static let badLight  = 0xC0392B, badDark  = 0xE8695A

    // MARK: Spacing — Fibonacci, the integer approximation of φ
    static let s1: CGFloat = 5, s2: CGFloat = 8, s3: CGFloat = 13, s4: CGFloat = 21, s5: CGFloat = 34
    static let panelWidth: CGFloat = 340
    static let radius: CGFloat = 10

    // MARK: Health colour
    //
    // Calm never gets a hue: a normal reading must not spend the reader's attention. It is drawn
    // in whatever ink the surrounding surface uses, which the caller passes in.
    static func health(_ h: Health, dark: Bool) -> Color {
        switch h {
        case .calm: return dark ? hex(textDark) : hex(ink)
        case .warm: return dark ? hex(amber) : hex(amberDeep)
        case .hot:  return dark ? hex(badDark) : hex(badLight)
        }
    }

    static func healthNS(_ h: Health, dark: Bool) -> NSColor { NSColor(health(h, dark: dark)) }

    static func hex(_ v: Int) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
    static func ns(_ v: Int) -> NSColor { NSColor(hex(v)) }

    /// A colour that resolves per appearance, so one token covers light and dark.
    /// The concrete colours are captured up front: AppKit may evaluate the provider off the
    /// main thread, where reading app state is not safe.
    static func dyn(light: Int, dark: Int) -> Color {
        let l = NSColor(hex(light)), d = NSColor(hex(dark))
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }

    // Semantic, appearance-aware tokens. Views ask for a role, never a hue.
    static var canvas:   Color { dyn(light: paper,  dark: navy) }
    static var surface:  Color { dyn(light: 0xFFFFFF, dark: navyMid) }
    static var sunk:     Color { dyn(light: 0xF1EDE7, dark: fieldDark) }
    static var text:     Color { dyn(light: ink,    dark: textDark) }
    static var text2:    Color { dyn(light: muted,  dark: textDark2) }
    static var hairline: Color { dyn(light: rule,   dark: hairlineDark) }
    /// Always the variant legal on the ground it lands on — the brand's AA rule, carried by type.
    static var accent:   Color { dyn(light: amberDeep, dark: amber) }

    // MARK: Faces — the platform's own, at the platform's own sizes.
    //
    // Until 1.2.0 this bundled Inter and Playfair Display and drew the whole interface in them.
    // Three things were wrong with that, and the third settles it:
    //
    //   · SF Pro changes shape with size — Text below 20 pt, Display above — and carries Apple's
    //     own tracking tables. One static face is wrong at both ends of that range.
    //   · A bundled face does not follow the reader's text-size setting.
    //   · **Inter has no CJK glyphs.** Every Chinese string in this bilingual app was already
    //     being drawn by the system's per-glyph fallback, so the "brand face" only ever reached
    //     half the readers — and in a mixed line like 「Claude Code · 周窗口」 the Latin came from
    //     Inter and the Han from PingFang, two families with no weight relationship — the weight
    //     axis the old code set applied to Inter, never to whatever substituted for it. Asking for
    //     the system font gets PingFang matched to SF Pro's weights, which is the behaviour the
    //     brand standard §7.2 described at length and could not implement.
    //
    // Planning doc 17 §4.2 and doc 22 C5. Playfair survives in one place, and it is not this app:
    // the Paradise Production seal on the film line.

    /// The 100–900 numbers the call sites use, mapped onto the platform's named weights.
    private static func nsWeight(_ weight: CGFloat) -> NSFont.Weight {
        switch weight {
        case ..<350:  return .light
        case ..<450:  return .regular
        case ..<550:  return .medium
        case ..<650:  return .semibold
        default:      return .bold
        }
    }

    /// §7.2: a Han label runs one point larger than its Latin counterpart.
    static func labelSize(_ size: CGFloat) -> CGFloat { Loc.isCJK ? size + 1 : size }
    /// §7.2: and at 0.4× the tracking. Spacing out 汉字 separates a word rather than opening a line.
    static func labelTracking(_ t: CGFloat) -> CGFloat { Loc.isCJK ? t * 0.4 : t }

    /// All interface text.
    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: nsWeight(weight)))
    }

    /// The wordmark, and anything speaking as the product rather than as a readout.
    ///
    /// Named for its job, not its face. It was `serif` while it loaded Playfair Display; a helper
    /// named after the file it opens starts lying the moment the file changes.
    static func wordmark(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: nsWeight(weight)))
    }

    /// Figures that change while you watch. Tabular by construction, so nothing jitters.
    static func figures(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        Font(NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight(weight)))
    }

    /// The menu-bar glyph's figures. Drawn with AppKit, so it needs the `NSFont` itself.
    static func nsNumber(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: nsWeight(weight))
    }
}

/// Press feedback.
///
/// Ten pressable things in this app had none: you clicked, and nothing acknowledged the click
/// until the effect arrived — which for a refresh is a second later and for a pin is never,
/// because the change is a one-pixel underline somewhere else. The moment that gap appears, a
/// surface stops feeling direct, so the acknowledgement belongs on the press itself.
/// `configuration.isPressed` is true from pointer-down, which is exactly the moment wanted.
///
/// Two shapes, because a control and a row want different things. A small control scales, which
/// is the platform's own idiom for a button being pushed. A full-width row scales badly — the
/// whole band shrinks away from its own edges and the eye reads it as the panel moving — so it
/// washes instead, which is what a selected table row does.
///
/// Under reduced motion both wash: that setting asks for less movement, not less feedback.
struct PressStyle: ButtonStyle {
    enum Shape { case control, row }
    var shape: Shape = .control

    func makeBody(configuration: Configuration) -> some View {
        Body(shape: shape, pressed: configuration.isPressed, label: configuration.label)
    }

    /// Which of the two acknowledgements applies. A function rather than an expression inside the
    /// view, because the interesting case is the one a screenshot cannot show: with reduced
    /// motion on, `scales` is false for both shapes and the wash has to take over. If it did not,
    /// asking for less movement would silently buy you no feedback at all.
    static func scales(shape: Shape, reduceMotion: Bool) -> Bool {
        shape == .control && !reduceMotion
    }

    /// A real view, so that `@Environment` is actually observed — `makeBody` is not a `body`,
    /// and an environment value read directly there does not update when it changes.
    private struct Body<Label: View>: View {
        let shape: Shape
        let pressed: Bool
        let label: Label
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var scales: Bool { PressStyle.scales(shape: shape, reduceMotion: reduceMotion) }

        var body: some View {
            label
                .scaleEffect(pressed && scales ? 0.97 : 1)
                .background(
                    RoundedRectangle(cornerRadius: shape == .row ? 0 : 4, style: .continuous)
                        .fill(Theme.text.opacity(pressed && !scales ? 0.07 : 0))
                )
                // 120 ms: long enough to be seen, short enough that the release never waits for it.
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
    }
}

extension View {
    /// The brand's small caps label: Semibold, +0.18em tracking, upper case.
    ///
    /// The tracking is a **Latin** rule — §6 of the brand standard — and §7.2 carves out the
    /// exception: Han runs one point larger and at 0.4× the tracking, because letter-spacing
    /// applied to 汉字 pulls a word apart instead of opening a line up. The default size named
    /// here is therefore the Latin one; Han reaches 9.5 pt through the exception rather than by
    /// being the default, which is how it was written while the app was Chinese-only.
    func brandLabel(_ size: CGFloat = 8.5) -> some View {
        font(Theme.sans(Theme.labelSize(size), 600))
            .tracking(Theme.labelTracking(size * 0.18))
    }
}

extension Theme {
    /// The only legitimate cap on a surface's height is the screen it is on. Anything else is
    /// taste presented as a constraint, and taste costs the reader room they actually have —
    /// the panel once capped at 860 pt and threw away 474 pt on a 1334 pt display.
    ///
    /// `inset` is the chrome that surface carries: a popover has a beak and margins, a titled
    /// window has a title bar. The floor exists only so a pathological screen still leaves
    /// something readable.
    static func ceiling(usableHeight: CGFloat?, inset: CGFloat) -> CGFloat {
        max(420, (usableHeight ?? NSScreen.main?.visibleFrame.height ?? 860) - inset)
    }
}
