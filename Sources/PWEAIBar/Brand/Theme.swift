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

    // MARK: Faces — Playfair Display for the brand voice, Inter for the interface.
    // Both ship in the bundle as variable fonts, so the app never depends on installed fonts.
    private static var registered = false

    static func registerFonts() {
        guard !registered else { return }
        for name in ["Inter", "PlayfairDisplay"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        registered = true
    }

    private static func variable(_ family: String, size: CGFloat, weight: CGFloat,
                                 fallback: NSFont) -> NSFont {
        let wght = 0x77676874 as CFNumber   // 'wght'
        guard let base = NSFont(name: family, size: size) else { return fallback }
        let desc = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [wght: weight]
        ])
        return NSFont(descriptor: desc, size: size) ?? fallback
    }

    /// §7.2: a Han label runs one point larger than its Latin counterpart.
    static func labelSize(_ size: CGFloat) -> CGFloat { Loc.isCJK ? size + 1 : size }
    /// §7.2: and at 0.4× the tracking. Spacing out 汉字 separates a word rather than opening a line.
    static func labelTracking(_ t: CGFloat) -> CGFloat { Loc.isCJK ? t * 0.4 : t }

    static func sans(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(variable("Inter", size: size, weight: weight,
                      fallback: .systemFont(ofSize: size)))
    }

    static func serif(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        Font(variable("Playfair Display", size: size, weight: weight,
                      fallback: .systemFont(ofSize: size)))
    }

    /// Figures that change while you watch. Tabular by construction, so nothing jitters.
    static func figures(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        sans(size, weight).monospacedDigit()
    }

    static func nsNumber(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont {
        let base = variable("Inter", size: size, weight: weight,
                            fallback: .monospacedDigitSystemFont(ofSize: size, weight: .medium))
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        ])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}

extension View {
    /// The brand's small caps label: Inter Semibold, +0.18em tracking, upper case.
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
