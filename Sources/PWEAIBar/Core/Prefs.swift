import AppKit
import SwiftUI
import ServiceManagement

enum MenuBarMode: String, CaseIterable, Identifiable {
    case icon, compact, full
    var id: String { rawValue }
    var label: String {
        [L("mode.icon", "Icon"), L("mode.compact", "Compact"), L("mode.full", "Full")][index]
    }
    private var index: Int { ["icon": 0, "compact": 1, "full": 2][rawValue]! }
}

enum PanelMode: String, CaseIterable, Identifiable {
    case lean, standard, full
    var id: String { rawValue }
    var label: String {
        [L("mode.lean", "Lean"), L("mode.standard", "Standard"), L("mode.full", "Full")][index]
    }
    private var index: Int { ["lean": 0, "standard": 1, "full": 2][rawValue]! }
}

enum AlertPlacement: String, CaseIterable, Identifiable {
    case menubar, notch, center
    var id: String { rawValue }
    var label: String {
        [L("place.menubar", "Menu bar"), L("place.notch", "Notch"),
         L("place.center", "Notification Centre")][index]
    }
    private var index: Int { ["menubar": 0, "notch": 1, "center": 2][rawValue]! }
}

/// How often to ask. `automatic` is the app's own cadence — 20 s while you are working, 5 min
/// when nothing has moved, 15 min once you have been away an hour — and it stays the default
/// because it is the one that is cheap when nothing is happening and quick when it is. The fixed
/// options exist because that reasoning is ours, not the reader's: on a metered connection or a
/// laptop on battery, "every fifteen minutes, always" is a legitimate thing to want.
enum RefreshInterval: String, CaseIterable, Identifiable {
    case automatic, oneMinute, fiveMinutes, fifteenMinutes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic:      return L("refresh.automatic", "Automatic")
        case .oneMinute:      return L("refresh.1m", "Every minute")
        case .fiveMinutes:    return L("refresh.5m", "Every 5 minutes")
        case .fifteenMinutes: return L("refresh.15m", "Every 15 minutes")
        }
    }
    /// Nil means "let the app decide", which is what `Store.interval` does on its own.
    var seconds: TimeInterval? {
        switch self {
        case .automatic:      return nil
        case .oneMinute:      return 60
        case .fiveMinutes:    return 300
        case .fifteenMinutes: return 900
        }
    }
}

/// User-facing settings. Density is a preference, not a house opinion: some people want every
/// reading in the bar, some want one glyph, and the design's job is to be legible either way.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d: UserDefaults
    var sharedKeychainOptIn: Bool { d.bool(forKey: "sharedKeychainOptIn") }

    /// Which settings groups are open. Display and Alerts by default — the two an existing user
    /// opens this window to change — so the window opens at roughly half its full height and the
    /// rest is a click away instead of a scroll away. Remembered per group, because a person who
    /// opens Sources once is likely to want it open next time too.
    private static let openByDefault: Set<String> = ["display", "alerts"]
    func isOpen(_ group: String) -> Bool {
        (d.object(forKey: "settings.open." + group) as? Bool) ?? Self.openByDefault.contains(group)
    }
    func setOpen(_ group: String, _ open: Bool) {
        objectWillChange.send()
        d.set(open, forKey: "settings.open." + group)
    }

    @Published var menuBarMode: MenuBarMode { didSet { d.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var panelMode: PanelMode      { didSet { d.set(panelMode.rawValue, forKey: "panelMode") } }
    @Published var placement: AlertPlacement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    /// Which providers to query at all. One set rather than a switch per provider: eight named
    /// booleans is how a ninth provider ends up half-wired.
    @Published var tracked: Set<String> { didSet { d.set(Array(tracked), forKey: "tracked") } }
    var trackClaude: Bool { tracks(.claude) }
    var trackCodex: Bool { tracks(.codex) }
    func tracks(_ p: Provider) -> Bool { p.unavailableReason == nil && tracked.contains(p.rawValue) }
    func setTracking(_ p: Provider, _ on: Bool) {
        if on { tracked.insert(p.rawValue) } else { tracked.remove(p.rawValue) }
    }
    /// Whether percentages read as "how much is left" rather than "how much is spent".
    /// Defaults to remaining — see `Readout` for why.
    @Published var showRemaining: Bool { didSet { d.set(showRemaining, forKey: "showRemaining") } }

    @Published var refreshInterval: RefreshInterval {
        didSet { d.set(refreshInterval.rawValue, forKey: "refreshInterval") }
    }

    /// Which providers get a place in the menu bar, as opposed to merely being queried. Two
    /// different questions: with eight providers the bar runs out of room long before the reader
    /// runs out of interest, and until now the only control was a density switch that applied to
    /// all of them at once.
    ///
    /// **Empty means all.** An upgrade must not silently empty someone's menu bar, and the set is
    /// only materialised when they first take something out of it.
    @Published var menuBarProviders: Set<String> {
        didSet { d.set(Array(menuBarProviders), forKey: "menuBarProviders") }
    }
    func showsInMenuBar(_ p: Provider) -> Bool {
        tracks(p) && (menuBarProviders.isEmpty || menuBarProviders.contains(p.rawValue))
    }
    func setMenuBar(_ p: Provider, _ on: Bool) {
        var set = menuBarProviders.isEmpty
            ? Set(Provider.allCases.filter { $0.unavailableReason == nil }.map(\.rawValue))
            : menuBarProviders
        if on { set.insert(p.rawValue) } else { set.remove(p.rawValue) }
        menuBarProviders = set
    }

    /// Interface language.
    ///
    /// Setting it pushes straight into `Loc`, which is what every `L()` reads — an override that
    /// only reached the store would leave the strings following the system until relaunch.
    @Published var language: Language {
        didSet { d.set(language.rawValue, forKey: "language"); Loc.language = language }
    }

    /// How far back the trophy page counts.
    @Published var trophyRange: TrophyRange { didSet { d.set(trophyRange.rawValue, forKey: "trophyRange") } }
    /// Which currency the subscription is shown in. The equivalent API cost stays in USD
    /// whatever this says — it is a USD list price, and converting it would need an exchange
    /// rate this app has no honest source for.
    @Published var subscriptionCurrency: String { didSet { d.set(subscriptionCurrency, forKey: "subscriptionCurrency") } }
    /// What the reader actually pays each month, in `subscriptionCurrency`. Zero means "use the
    /// table for the detected plan" — regional pricing, annual billing and tax all move this,
    /// so the shipped number is a starting point rather than an answer.
    @Published var subscriptionMonthly: Double { didSet { d.set(subscriptionMonthly, forKey: "subscriptionMonthly") } }
    /// The same figure in USD, which is what the multiple is computed against. Separate because
    /// A$150 and US$100 are both the price of Max 5× and neither is the other times a rate.
    @Published var subscriptionMonthlyUSD: Double { didSet { d.set(subscriptionMonthlyUSD, forKey: "subscriptionMonthlyUSD") } }
    /// Which provider the stage is pinned to, or empty for "whichever is closest to stopping
    /// you". Pinning exists because the automatic choice answers the question the app thinks
    /// you have; sometimes you came to look at one particular tool and the worst window belongs
    /// to another one. Stored as a raw value so an unknown provider from a future build reads
    /// back as no pin rather than as a crash.
    @Published var focusProvider: String { didSet { d.set(focusProvider, forKey: "focusProvider") } }
    @Published var sound: Bool       { didSet { d.set(sound, forKey: "sound") } }
    @Published var pushURL: String   { didSet { d.set(pushURL, forKey: "pushURL") } }
    @Published var launchAtLogin: Bool {
        didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); applyLoginItem() }
    }

    /// Whether the app may ask the site if there is a newer version. Three states, not two:
    /// `nil` means nobody has been asked yet, which is what the panel's one-line question reads
    /// to decide whether to appear. Storing "off" and "not asked yet" as the same `false` would
    /// either ask forever or never ask at all.
    @Published var updateChecks: Bool? {
        didSet {
            if let updateChecks { d.set(updateChecks, forKey: "updateChecks") }
            else { d.removeObject(forKey: "updateChecks") }
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        // Default to the dense bar. Giving everything up front and letting people dial back is
        // the recoverable mistake; starting quiet means most people never learn there is more.
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .full
        panelMode   = PanelMode(rawValue: d.string(forKey: "panelMode") ?? "") ?? .standard
        focusProvider = d.string(forKey: "focusProvider") ?? ""
        let saved = AlertPlacement(rawValue: d.string(forKey: "placement") ?? "") ?? .menubar
        // A setting carried over from a Mac that had a notch would silently deliver nothing here.
        placement = (saved == .notch && !Prefs.hasNotch) ? .menubar : saved
        if let saved = d.array(forKey: "tracked") as? [String] {
            tracked = Set(saved)
        } else {
            // Carry the two original switches forward. The other five start off, and that is
            // deliberate: turning one on sends a credential this app found on disk to a vendor
            // the user never asked it to contact. Every other permission here waits to be given
            // rather than assumed, and an outbound request with someone's token is not the place
            // to make an exception. Settings shows which are detected, one click away.
            var initial: Set<String> = []
            if d.object(forKey: "trackClaude") as? Bool != false { initial.insert(Provider.claude.rawValue) }
            if d.object(forKey: "trackCodex") as? Bool != false { initial.insert(Provider.codex.rawValue) }
            tracked = initial
        }
        showRemaining = d.object(forKey: "showRemaining") as? Bool ?? true
        refreshInterval = RefreshInterval(rawValue: d.string(forKey: "refreshInterval") ?? "") ?? .automatic
        menuBarProviders = Set(d.array(forKey: "menuBarProviders") as? [String] ?? [])
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .system
        trophyRange = TrophyRange(rawValue: d.string(forKey: "trophyRange") ?? "") ?? .all
        subscriptionCurrency = d.string(forKey: "subscriptionCurrency") ?? "USD"
        subscriptionMonthly = d.double(forKey: "subscriptionMonthly")
        subscriptionMonthlyUSD = d.double(forKey: "subscriptionMonthlyUSD")
        sound       = d.object(forKey: "sound")       as? Bool ?? true
        pushURL     = d.string(forKey: "pushURL") ?? ""
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        updateChecks = d.object(forKey: "updateChecks") as? Bool
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
