import SwiftUI

/// Density is a preference, not a house opinion — some people want every reading in the bar and
/// some want one glyph. What is not a preference is arrangement: whichever density you pick,
/// the same alignment rules hold.
/// Whether the Claude Code hooks are in place. A case, not the words shown for it: this used to
/// be a `String` compared against 「未安装」 to decide what the button says and does, which
/// survives exactly until the string is translated.
enum HookState: Equatable {
    case absent, installed, stale, failed
    var label: String {
        switch self {
        case .absent:    return L("hooks.absent", "not installed")
        case .installed: return L("hooks.installed", "installed")
        case .stale:     return L("hooks.stale", "script needs updating")
        case .failed:    return L("hooks.failed", "failed")
        }
    }
}

/// What detection found for one provider — again a case rather than its own label, for the same
/// reason: `states[.claude] == "已登录"` decided which sentence the settings page shows.
enum Detected: Equatable {
    case signedIn, signedOut, present, absent, detected
    var label: String {
        switch self {
        case .signedIn:  return L("detected.signedIn", "signed in")
        case .signedOut: return L("detected.signedOut", "signed out")
        case .present:   return L("detected.present", "installed")
        case .absent:    return L("detected.absent", "not installed")
        case .detected:  return L("detected.found", "detected")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var installHooks: () -> Bool
    var saveToken: (String) async -> ClaudeProvider.TokenUpdate
    var enableRealQuota: () async -> String
    /// Injectable so a test can assert against a stated screen height rather than whichever
    /// machine happens to run it.
    var usableHeight: () -> CGFloat? = { NSScreen.main?.visibleFrame.height }
    /// The height this page wants, reported to whoever owns the window. Same contract as the
    /// panel's: SwiftUI measures, the owner applies. 1.0.10 through 1.0.14 sized the window from
    /// `NSHostingView.fittingSize` instead, which is 0 for a hosted ScrollView until it has been
    /// laid out — so on the first Mac that ever ran this app past launch, the settings window
    /// opened as a bare title bar.
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var contentHeight: CGFloat = 0
    @State private var hookState: HookState
    @State private var states: [Provider: Detected] = [:]
    @State private var token: String = ""
    @State private var keychainNote: String = ""
    @State private var keychainBusy = false
    @StateObject private var tokenEditor: TokenEditor
    @ObservedObject var updates: UpdateCheck
    @State private var checking = false

    init(installHooks: @escaping () -> Bool,
         saveToken: @escaping (String) async -> ClaudeProvider.TokenUpdate,
         enableRealQuota: @escaping () async -> String, prefs: Prefs? = nil,
         tokenEditor: TokenEditor? = nil, hookInstalled: Bool? = nil,
         updates: UpdateCheck? = nil,
         usableHeight: @escaping () -> CGFloat? = { NSScreen.main?.visibleFrame.height },
         onHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.installHooks = installHooks; self.saveToken = saveToken; self.enableRealQuota = enableRealQuota
        self.usableHeight = usableHeight; self.onHeight = onHeight
        self.prefs = prefs ?? .shared
        self.updates = updates ?? UpdateCheck()
        // The flag, not the keychain. Reading the item itself here is a synchronous trip to
        // securityd inside a view initialiser — measured on this machine at up to 84 s, which
        // is a settings window that appears to hang on open.
        _tokenEditor = StateObject(wrappedValue: tokenEditor
            ?? TokenEditor(hasToken: Credentials.hasStoredOwnToken))
        let installed = hookInstalled ?? HookProvider.isInstalled
        let current = HookProvider.installedScriptIsCurrent(
            source: Bundle.resources.url(forResource: "pwe-ai-bar-hook", withExtension: "sh"))
        _hookState = State(initialValue: !installed ? .absent : current ? .installed : .stale)
    }

    /// 88 pt of chrome: the title bar, plus a margin top and bottom so the window is not wedged
    /// against the menu bar and the dock. Same rule as the panel, different furniture.
    static func ceiling(usableHeight: CGFloat? = nil) -> CGFloat {
        Theme.ceiling(usableHeight: usableHeight, inset: 88)
    }

    /// Everything, or the ceiling, whichever is smaller — and nil until SwiftUI has measured,
    /// because the number the window would otherwise take is 0.
    private var desiredHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        return min(contentHeight, Self.ceiling(usableHeight: usableHeight()))
    }

    var body: some View {
        // Eight providers pushed this past 960 pt. Without a scroller the rows below the fold
        // are not merely awkward to reach, they are unreachable — and one of them is the only
        // switch that turns a provider on.
        ScrollView {
            content.measuring(SettingsHeight.self)
        }
        .frame(width: 380)
        .frame(maxHeight: Self.ceiling(usableHeight: usableHeight()))
        .background(Theme.surface)
        .tint(Theme.accent)
        .onPreferenceChange(SettingsHeight.self) { contentHeight = $0 }
        .onChange(of: desiredHeight) { if let h = $0 { onHeight(h) } }
        .onAppear { if let h = desiredHeight { onHeight(h) } }
        .task {
            let found = await Task.detached(priority: .userInitiated) { Self.detect() }.value
            states = found
        }
    }

    /// Eleven sections that all looked alike — small-caps title, content, hairline — read as a
    /// list of eleven unrelated things. Four groups instead, ordered by how often you come back
    /// to them rather than by first-run order: Display and Alerts are what someone already set
    /// up opens this window to change, so they are what it opens on. Sources sits below them
    /// because it is configured once and then left alone. Nothing lives in a bucket called
    /// "Other" any more — Sound belongs with the alerts it makes, Launch at login with the
    /// general preferences.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("display", L("settings.group.display", "Display")) {
                row(L("settings.menuBar", "Menu bar")) {
                    Picker("", selection: $prefs.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                row(L("settings.panel", "Panel")) {
                    Picker("", selection: $prefs.panelMode) {
                        ForEach(PanelMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                row(L("settings.readout", "Percentage basis")) {
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        Picker("", selection: $prefs.showRemaining) {
                            Text(Readout.label.remaining).tag(true)
                            Text(Readout.label.used).tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        note(L("settings.readout.note",
                               "Codex shows what is left; Claude's endpoint gives what is used. "
                               + "One convention, so the same window does not read as two things."))
                    }
                }
            }

            group("alerts", L("settings.group.alerts", "Alerts")) {
                row(L("settings.alertPlacement", "Where alerts land")) {
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        // The notch choice is removed, not greyed. A segmented control cannot show
                        // a disabled item convincingly — it looks identical to a live one until you
                        // press it — and an option that can never work on this hardware is not a
                        // choice, it is a dead end with a label on it.
                        Picker("", selection: $prefs.placement) {
                            ForEach(AlertPlacement.allCases.filter { $0 != .notch || Prefs.hasNotch }) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()

                        if !Prefs.hasNotch {
                            note(L("settings.noNotch", "This Mac has no camera housing, so that option is unavailable."))
                        }
                    }
                }
                row(L("settings.pushAway", "Push when you are away")) {
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        TextField(L("settings.push.field", "ntfy / Bark URL — leave empty for no push"), text: $prefs.pushURL)
                            .textFieldStyle(.roundedBorder).font(Theme.sans(11.5))
                        note(L("settings.push.note", "Only used once you have been away from the keyboard for five minutes."))
                    }
                }
                switchRow(L("settings.sound", "Sound"), $prefs.sound)
            }

            group("sources", L("settings.group.sources", "Sources")) {
                row(L("settings.refresh", "Refresh")) {
                    Picker("", selection: $prefs.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
                }
                row(L("settings.tools", "Tools")) {
                    VStack(alignment: .leading, spacing: Theme.s1 + 2) {
                        providerHeader
                        ForEach(Provider.allCases, id: \.rawValue) { p in providerRow(p) }
                        note(L("settings.tracking.note",
                               "Switched off is never queried. Menu bar decides which of the ones you "
                               + "do query get a place up there — with eight of them the bar runs out "
                               + "of room long before you run out of interest.")).padding(.top, 2)
                    }
                }
                row(L("settings.source", "Quota source")) { quotaSource }
                row(L("settings.sessionEvents", "Session events")) {
                    HStack {
                        Text("Claude Code hooks · \(hookState.label)")
                            .font(Theme.sans(12)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button(hookState == .absent ? L("settings.hooks.install", "Install")
                                                    : L("settings.hooks.reinstall", "Reinstall")) {
                            hookState = installHooks() ? .installed : .failed
                        }
                        .font(Theme.sans(12))
                    }
                }
            }

            group("general", L("settings.group.general", "General")) {
                row(L("settings.language", "Language")) {
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        Picker("", selection: $prefs.language) {
                            ForEach(Language.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        note(L("settings.language.note",
                               "Following the system is not always right: plenty of Chinese speakers "
                               + "run macOS in English on purpose, and would never see the Chinese build."))
                    }
                }
                switchRow(L("settings.launchAtLogin", "Launch at login"), $prefs.launchAtLogin)
                row(L("settings.updates", "Updates")) { updatesRow }
                row(L("settings.subscription", "Subscription price")) { subscription }
            }
            footer
        }
        .frame(width: 380)
    }

    /// Which build is actually running. Not decoration: several releases went out in two days
    /// chasing one bug, and "is the fix in the copy I am looking at" was a question the screen
    /// could not answer — you had to go and read Info.plist.
    private var footer: some View {
        HStack(spacing: 6) {
            Text(verbatim: "PWE AI Bar").font(Theme.sans(11)).foregroundStyle(Theme.text2)
            Text(verbatim: Self.version).font(Theme.figures(11)).foregroundStyle(Theme.text)
            // The one place the version is already read to answer "is the fix in this copy". If
            // there is a newer one, that is the same question and this is where it gets answered.
            if let release = updates.available {
                Button {
                    NSWorkspace.shared.open(UpdateCheck.downloadPage)
                } label: {
                    Text(verbatim: "→ " + release.version)
                        .font(Theme.figures(11)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressStyle())
                .help(L("settings.updates.download", "Download"))
            }
            Spacer()
            Button { NSWorkspace.shared.open(Self.repository) } label: {
                Text(verbatim: "GitHub").font(Theme.sans(11))
            }
            .buttonStyle(.link)
            // Quitting lived only in the right-click menu on the status icon. Right-clicking a
            // menu-bar glyph is a thing you know or you do not, and an app with no Dock icon
            // gives you nothing else to try — so the way out is on screen, where the way in was.
            Button(L("settings.quit", "Quit")) { NSApplication.shared.terminate(nil) }
                .font(Theme.sans(11))
        }
        .padding(.horizontal, Theme.s3).padding(.top, Theme.s3).padding(.bottom, Theme.s4)
    }

    /// The updates control.
    ///
    /// Off until it is turned on, and the note says exactly what leaves the machine rather than
    /// linking to a policy — three fields is short enough to print, and a promise you can read in
    /// place is worth more than one you have to go and look up.
    @ViewBuilder private var updatesRow: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: 7) {
                Text(L("settings.updates.tell", "Tell me when there is a new version"))
                    .font(Theme.sans(12)).foregroundStyle(Theme.text)
                Spacer(minLength: Theme.s1)
                Toggle("", isOn: Binding(get: { prefs.updateChecks == true },
                                         set: { on in
                                             prefs.updateChecks = on
                                             // Answer the question it was just asked. Turning
                                             // this on and seeing nothing happen reads as a
                                             // switch that did not work.
                                             if on { Task { await updates.check() } }
                                         }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if let release = updates.available {
                HStack(spacing: 7) {
                    Text(String(format: L("settings.updates.available", "Version %@"),
                                release.version))
                        .font(Theme.figures(11.5)).foregroundStyle(Theme.accent)
                    Spacer(minLength: Theme.s1)
                    // A button, not a command. Someone who has to be told to open Terminal and
                    // type `brew upgrade` is someone who stays on the old version.
                    Button(L("settings.updates.download", "Download")) {
                        NSWorkspace.shared.open(UpdateCheck.downloadPage)
                    }.font(Theme.sans(11))
                    Button(L("settings.updates.later", "Later")) { updates.dismiss() }
                        .buttonStyle(.link).font(Theme.sans(11))
                }
                if let notes = release.notes { note(notes) }
            } else if prefs.updateChecks == true {
                HStack(spacing: 7) {
                    Button(L("settings.updates.now", "Check now")) {
                        checking = true
                        Task { await updates.check(); checking = false }
                    }.font(Theme.sans(11)).disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
            }
            note(L("settings.updates.note",
                   "Asks pwestudio.site once a day whether a newer version exists. It sends three "
                   + "things and nothing else: that this is PWE AI Bar, which version it is, and "
                   + "which macOS it runs on. No account, no tokens, no usage figures, and nothing "
                   + "that identifies the machine."))
        }
    }

    private static let repository = URL(string: "https://github.com/kenshinice-ai/pwe-ai-bar")!

    /// Falls back to a dash rather than to "1.0.0" or an empty string: a wrong version on screen
    /// is worse than an admitted unknown, because this line is the thing being trusted to settle
    /// the question "is the fix in the copy I am looking at".
    ///
    /// It asks whether `Bundle.main` **is this app**, not merely whether it has a version. The
    /// old test was presence, on the stated premise that a test host returns nil — it does not.
    /// xctest has a version of its own, and the footer printed it: the render harness that
    /// produces the screenshots for the website was drawing "PWE AI Bar 16.0", which is the
    /// Xcode version and has nothing to do with this app. A published screenshot is exactly how
    /// a wrong number reaches somebody.
    static var version: String {
        guard Bundle.main.bundleIdentifier == bundleID,
              let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return "—" }
        return v
    }

    /// Kept next to the accessor that needs it rather than derived from `Bundle.main`, which is
    /// the thing being checked.
    static let bundleID = "com.paradiseproduction.pweaibar"

    /// Broken out of `content` for the same reason it is the messiest section on the page: a
    /// status line, a field, two buttons and two paragraphs, none of which are the same shape.
    private var quotaSource: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            // The whole point of this section is that the default never shows a dialog.
            // Say which of the three states you are in — a permission prompt the user
            // did not expect is the thing most likely to make them quit on day one, and
            // a line claiming we are reading something we deliberately are not is just
            // as bad in the other direction.
            Text(sourceLine)
                .font(Theme.sans(11)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.s1 + 1) {
                SecureField(L("settings.token.field", "Advanced: paste a token with quota read access"), text: $token)
                    .textFieldStyle(.roundedBorder).font(Theme.sans(11.5))
                Button(tokenEditor.isSaving ? L("settings.token.verifying", "Verifying…")
                       : tokenEditor.hasToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? L("settings.token.clear", "Clear") : L("settings.token.save", "Save")) {
                    Task { @MainActor in
                        if await tokenEditor.submit(token, save: saveToken) { token = "" }
                    }
                }
                .font(Theme.sans(12))
                .disabled(tokenEditor.isSaving)
            }
            .disabled(tokenEditor.isSaving)

            // Telling someone how to get a token they already have is noise; the
            // useful thing to say at that point is where it lives and how to remove it.
            note(tokenEditor.hasToken
                 ? L("settings.token.stored",
                     "The token is kept in this app's keychain and can still expire or be "
                     + "revoked. Paste a new one to replace it, or clear the field and press Clear.")
                 : L("settings.token.none",
                     "Usually unnecessary. The Claude Code login is reused automatically and "
                     + "renewed in place when it can be. A manual token must pass the quota "
                     + "endpoint; being long-lived does not mean it can read usage."))

            // The prompting path is a fallback for machines where reading Claude Code's
            // credential the quiet way did not work. With a token in hand it would change
            // nothing, so it is not offered. On its own line, not squeezed against the
            // paragraph above: a button beside wrapping text collides with it at every width
            // the text happens to reflow at.
            // The same button the panel offers, here too: this section is where someone goes
            // looking when the panel told them something is wrong with the login.
            HStack(spacing: Theme.s2) {
                Button(L("cta.signIn", "Sign in")) { ClaudeLogin.begin() }
                    .font(Theme.sans(11))
                    .help(L("cta.signIn.help", "Opens Terminal and signs in for you"))
                Button(L("cta.installClaude", "Get Claude Code")) {
                    if let u = Provider.claude.fallbackURL { NSWorkspace.shared.open(u) }
                }
                .font(Theme.sans(11))
                .help(L("cta.installClaude.help", "Opens the Claude Code download page"))
            }
            if !tokenEditor.hasToken {
                Button(keychainBusy ? L("keychain.asking", "Asking macOS…")
                                    : L("cta.useKeychain", "Use keychain access")) {
                    Task { @MainActor in
                        keychainBusy = true
                        keychainNote = await enableRealQuota()
                        keychainBusy = false
                    }
                }
                .disabled(keychainBusy)
                    .font(Theme.sans(11))
                    .help(L("settings.keychain.help",
                            "The fallback when the Claude Code credential cannot be read; "
                            + "macOS will ask for authorisation once"))
            }
            if !keychainNote.isEmpty {
                note(keychainNote).foregroundStyle(Theme.accent)
            }
            if !tokenEditor.message.isEmpty {
                Text(tokenEditor.message).font(Theme.sans(10.5)).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subscription: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Picker("", selection: $prefs.subscriptionCurrency) {
                Text(L("currency.usd", "USD")).tag("USD")
                Text(L("currency.aud", "AUD")).tag("AUD")
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: Theme.s2) {
                priceField(prefs.subscriptionCurrency == "AUD"
                             ? L("settings.perMonth.aud", "per month A$")
                             : L("settings.perMonth.usd", "per month US$"),
                           value: $prefs.subscriptionMonthly)
                // The multiple is computed in USD whatever is displayed, so when the
                // shown currency is not USD the USD figure is a second, separate number
                // rather than a conversion — A$150 and US$100 are both the price of
                // Max 5×, and neither is the other times an exchange rate.
                if prefs.subscriptionCurrency != "USD" {
                    priceField(L("settings.inUSD", "as US$"), value: $prefs.subscriptionMonthlyUSD)
                }
            }

            note(L("settings.subscription.note",
                   "Leave empty to use the table price for the detected plan. The multiple is "
                   + "always computed in USD — the equivalent cost is itself a USD list price, "
                   + "and converting it would need an exchange rate this app has no reliable "
                   + "source for."))
        }
    }

    /// This has to describe what the app actually does, in the order it actually does it. It
    /// used to lead with the saved token because that used to be the preferred source; it is
    /// now the fallback, and a settings page that says otherwise is telling a small lie about
    /// where someone's credential is being read from.
    private var sourceLine: String {
        if states[.claude] == .signedIn {
            return L("settings.source.found",
                     "A Claude Code login was found. Whether it connects, and what macOS allows, "
                     + "is shown in the quota panel.")
        }
        if tokenEditor.hasToken {
            return L("settings.source.manualToken",
                     "A manual token is saved. Its permissions and validity are decided by the "
                     + "quota endpoint.")
        }
        if prefs.sharedKeychainOptIn {
            return L("settings.source.keychain",
                     "Keychain access is selected; the result is shown in the quota panel.")
        }
        return L("settings.source.none",
                 "No usable Claude Code login was found. Use Sign in below.")
    }

    /// One line per provider, whether or not it is here. A tool that is installed but signed
    /// out and a tool that was never installed look identical when both are simply absent from
    /// the panel — so both are listed, and each says which it is.
    /// Two columns, because they answer two questions. Querying a provider and giving it a place
    /// in the menu bar used to be the same switch, which meant the only way to unclutter the bar
    /// was to stop reading a tool you actually use.
    private static let column: CGFloat = 40

    private var providerHeader: some View {
        HStack(spacing: 7) {
            // No word here: the row above it is already the column's name, and having both
            // read "Tracking" over "Provider / Track" was two labels arguing about one thing.
            Spacer(minLength: Theme.s1)
            Text(L("settings.col.track", "Track").uppercased())
                .brandLabel().foregroundStyle(Theme.text2)
                .frame(width: Self.column, alignment: .center)
            Text(L("settings.col.menuBar", "Bar").uppercased())
                .brandLabel().foregroundStyle(Theme.text2)
                .frame(width: Self.column, alignment: .center)
        }
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityHidden(true)
    }

    private func providerRow(_ p: Provider) -> some View {
        let reason = p.unavailableReason
        let detected = states[p]?.label
        let live = reason == nil && states[p] != nil && states[p] != .absent
        return HStack(spacing: 7) {
            ProviderMarkView(provider: p, tint: reason == nil ? Theme.text : Theme.text2)
                .frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name).font(Theme.sans(12))
                    .foregroundStyle(reason == nil ? Theme.text : Theme.text2).lineLimit(1)
                // Empty until detection comes back off the main thread — a dash that turns into
                // "已登录" is honest; a guess that turns out wrong is not.
                HStack(spacing: 3) {
                    Circle().fill(live ? Theme.accent : Theme.text2.opacity(0.45))
                        .frame(width: 4, height: 4)
                    Text(reason ?? detected ?? "…").font(Theme.sans(10))
                        .foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.s1)
            Toggle("", isOn: Binding(get: { prefs.tracks(p) },
                                     set: { prefs.setTracking(p, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(reason != nil)
                .frame(width: Self.column, alignment: .center)
            Toggle("", isOn: Binding(get: { prefs.showsInMenuBar(p) },
                                     set: { prefs.setMenuBar(p, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(reason != nil || !prefs.tracks(p))
                .frame(width: Self.column, alignment: .center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("settings.provider.a11y", "%@, %@"), p.name,
                                   reason ?? detected ?? L("settings.detecting", "detecting")))
    }

    /// Detection only: whether a credential exists, never whether it still works. Saying
    /// "已连接" before a single request has come back would be inventing a fact.
    ///
    /// Run once, off the main thread, and never from inside a view body: finding these costs
    /// `sqlite3` and `security` subprocesses, and SwiftUI re-evaluates a body far more often
    /// than anyone installs an IDE.
    nonisolated private static func detect() -> [Provider: Detected] {
        var out: [Provider: Detected] = [:]
        for p in Provider.allCases where p.unavailableReason == nil {
            switch p {
            case .claude:
                out[p] = Credentials.sharedItemExists() ? .signedIn
                       : Credentials.claudeCodePresent() ? .signedOut : .absent
            case .codex:  out[p] = CodexAppServer.executable() != nil ? .present : .absent
            default:      out[p] = ExtraProviders.installed(p) ? .detected : .absent
            }
        }
        return out
    }

    /// Zero means "unset", so an empty field reads back as the table default rather than as a
    /// price of nothing — which would otherwise render a multiple of infinity.
    private func priceField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.text2)
            TextField("", text: Binding(
                get: { value.wrappedValue > 0 ? String(format: "%g", value.wrappedValue) : "" },
                set: { value.wrappedValue = Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }))
                .textFieldStyle(.roundedBorder).font(Theme.figures(11.5))
                .frame(width: 72)
        }
    }

    /// The heading a group of rows hangs from. Same small-caps device as a row title, one step
    /// up in size and at full strength — the hierarchy is built out of the brand's own label
    /// rather than a second typeface invented for this window.
    ///
    /// Collapsible, and two of the four start collapsed. Four groups fully open still ran to about
    /// 1,450 pt — past any laptop screen — and a page you have to scroll to see the shape of is a
    /// page that feels disordered whatever its order. The chevron is the same SF Symbol family the
    /// panel already uses for its gear and its outbound arrow, so it reads as this product and not
    /// as a stock disclosure triangle.
    private func group<C: View>(_ id: String, _ title: String, @ViewBuilder content: () -> C) -> some View {
        let open = prefs.isOpen(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { prefs.setOpen(id, !open) }
            } label: {
                HStack(spacing: Theme.s2) {
                    Text(title.uppercased()).brandLabel(10).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Theme.s3)
                .padding(.top, Theme.s4).padding(.bottom, open ? Theme.s2 : Theme.s3)
            }
            .buttonStyle(PressStyle(shape: .row))
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? L("settings.group.open", "expanded")
                                     : L("settings.group.closed", "collapsed"))
            // A closed group still needs a rule under it; open, its last row draws one.
            .overlay(alignment: .bottom) {
                if !open { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
            if open { content() }
        }
    }

    /// One switch does not need a heading of its own; it needs to sit on the same grid as the
    /// provider switches above it, which is what this shares with `providerRow`.
    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        shell {
            HStack(spacing: 7) {
                Text(title).font(Theme.sans(12)).foregroundStyle(Theme.text)
                Spacer(minLength: Theme.s1)
                Toggle("", isOn: isOn)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    /// The explanatory line under a control. Seven of these had drifted to three sizes and four
    /// spacings; a paragraph that means the same thing should not look like four things.
    private func note(_ text: String) -> some View {
        Text(text).font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        shell {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(title.uppercased()).brandLabel().foregroundStyle(Theme.text2)
                content()
            }
        }
    }

    private func shell<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .padding(.horizontal, Theme.s3).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// The settings page's measured content height. Its own key rather than the panel's, so the two
/// windows can never report into each other.
///
/// `max`, not "take the latest": a ScrollView's own internals also contribute this key, at its
/// default of 0, and they can arrive after the measurement — which turned 678 into 0 and left the
/// window at whatever it happened to be.
enum SettingsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
