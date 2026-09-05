import AppKit
import SwiftUI
import ServiceManagement

enum MenuBarMode: String, CaseIterable, Identifiable {
    case icon, compact, full
    var id: String { rawValue }
    var label: String { ["icon": "图标", "compact": "紧凑", "full": "完整"][rawValue]! }
}

enum PanelMode: String, CaseIterable, Identifiable {
    case lean, standard, full
    var id: String { rawValue }
    var label: String { ["lean": "精简", "standard": "标准", "full": "完整"][rawValue]! }
}

enum AlertPlacement: String, CaseIterable, Identifiable {
    case menubar, notch, center
    var id: String { rawValue }
    var label: String { ["menubar": "菜单栏", "notch": "刘海", "center": "通知中心"][rawValue]! }
}

/// User-facing settings. Density is a preference, not a house opinion: some people want every
/// reading in the bar, some want one glyph, and the design's job is to be legible either way.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d: UserDefaults
    var sharedKeychainOptIn: Bool { d.bool(forKey: "sharedKeychainOptIn") }

    @Published var menuBarMode: MenuBarMode { didSet { d.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var panelMode: PanelMode      { didSet { d.set(panelMode.rawValue, forKey: "panelMode") } }
    @Published var placement: AlertPlacement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    @Published var trackClaude: Bool { didSet { d.set(trackClaude, forKey: "trackClaude") } }
    @Published var trackCodex: Bool  { didSet { d.set(trackCodex, forKey: "trackCodex") } }
    /// Whether percentages read as "how much is left" rather than "how much is spent".
    /// Defaults to remaining — see `Readout` for why.
    @Published var showRemaining: Bool { didSet { d.set(showRemaining, forKey: "showRemaining") } }
    @Published var sound: Bool       { didSet { d.set(sound, forKey: "sound") } }
    @Published var pushURL: String   { didSet { d.set(pushURL, forKey: "pushURL") } }
    @Published var launchAtLogin: Bool {
        didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); applyLoginItem() }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        // Default to the dense bar. Giving everything up front and letting people dial back is
        // the recoverable mistake; starting quiet means most people never learn there is more.
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .full
        panelMode   = PanelMode(rawValue: d.string(forKey: "panelMode") ?? "") ?? .standard
        let saved = AlertPlacement(rawValue: d.string(forKey: "placement") ?? "") ?? .menubar
        // A setting carried over from a Mac that had a notch would silently deliver nothing here.
        placement = (saved == .notch && !Prefs.hasNotch) ? .menubar : saved
        trackClaude = d.object(forKey: "trackClaude") as? Bool ?? true
        trackCodex  = d.object(forKey: "trackCodex")  as? Bool ?? true
        showRemaining = d.object(forKey: "showRemaining") as? Bool ?? true
        sound       = d.object(forKey: "sound")       as? Bool ?? true
        pushURL     = d.string(forKey: "pushURL") ?? ""
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
    }

    /// True only when a screen actually has a notch. An option that cannot work must be visibly
    /// unavailable, not silently inert — this machine (M1 13") has no notch, and the settings
    /// panel greys the choice out rather than letting you pick a mode that never fires.
    static var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    private func applyLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { /* the switch reflects intent; a failure here is not worth interrupting for */ }
    }
}
