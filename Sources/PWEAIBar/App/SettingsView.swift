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
    var enableRealQuota: () -> Void
    @State private var hookState: HookState
    @State private var states: [Provider: Detected] = [:]
    @State private var token: String = ""
    @StateObject private var tokenEditor: TokenEditor

    init(installHooks: @escaping () -> Bool,
         saveToken: @escaping (String) async -> ClaudeProvider.TokenUpdate,
         enableRealQuota: @escaping () -> Void, prefs: Prefs? = nil,
         tokenEditor: TokenEditor? = nil, hookInstalled: Bool? = nil) {
        self.installHooks = installHooks; self.saveToken = saveToken; self.enableRealQuota = enableRealQuota
        self.prefs = prefs ?? .shared
        // The flag, not the keychain. Reading the item itself here is a synchronous trip to
        // securityd inside a view initialiser — measured on this machine at up to 84 s, which
        // is a settings window that appears to hang on open.
        _tokenEditor = StateObject(wrappedValue: tokenEditor
            ?? TokenEditor(hasToken: Credentials.hasStoredOwnToken))
        let installed = hookInstalled ?? HookProvider.isInstalled
        let current = HookProvider.installedScriptIsCurrent(
            source: Bundle.module.url(forResource: "pwe-ai-bar-hook", withExtension: "sh"))
        _hookState = State(initialValue: !installed ? .absent : current ? .installed : .stale)
    }

    var body: some View {
        // Eight providers pushed this past 960 pt. Without a scroller the rows below the fold
        // are not merely awkward to reach, they are unreachable — and one of them is the only
        // switch that turns a provider on.
        ScrollView {
            content
        }
        .frame(width: 380)
        .frame(maxHeight: 620)
        .background(Theme.surface)
        .tint(Theme.accent)
        .task {
            let found = await Task.detached(priority: .userInitiated) { Self.detect() }.value
            states = found
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(L("settings.language", "Language")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $prefs.language) {
                        ForEach(Language.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(L("settings.language.note",
                           "Following the system is not always right: plenty of Chinese speakers "
                           + "run macOS in English on purpose, and would never see the Chinese build."))
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $prefs.showRemaining) {
                        Text(Readout.label.remaining).tag(true)
                        Text(Readout.label.used).tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(L("settings.readout.note",
                           "Codex shows what is left; Claude's endpoint gives what is used. "
                           + "One convention, so the same window does not read as two things."))
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row(L("settings.alertPlacement", "Where alerts land")) {
                VStack(alignment: .leading, spacing: 5) {
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
                        Text(L("settings.noNotch", "This Mac has no camera housing, so that option is unavailable."))
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                    }
                }
            }
            row(L("settings.source", "Quota source")) {
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

                    HStack(spacing: Theme.s2) {
                        // Telling someone how to get a token they already have is noise; the
                        // useful thing to say at that point is where it lives and how to remove it.
                        Text(tokenEditor.hasToken
                             ? L("settings.token.stored",
                                 "The token is kept in this app's keychain and can still expire or be "
                                 + "revoked. Paste a new one to replace it, or clear the field and press Clear.")
                             : L("settings.token.none",
                                 "Usually unnecessary. The Claude Code login is reused automatically and "
                                 + "renewed in place when it can be. A manual token must pass the quota "
                                 + "endpoint; being long-lived does not mean it can read usage."))
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.s1)
                        // The prompting path is a fallback for machines where reading Claude
                        // Code's credential the quiet way did not work. With a token in hand it
                        // would change nothing, so it is not offered.
                        if !tokenEditor.hasToken {
                            Button(L("cta.useKeychain", "Use keychain access")) { enableRealQuota() }
                                .font(Theme.sans(11))
                                .help(L("settings.keychain.help",
                                        "The fallback when the Claude Code credential cannot be read; "
                                        + "macOS will ask for authorisation once"))
                        }
                    }
                    if !tokenEditor.message.isEmpty {
                        Text(tokenEditor.message).font(Theme.sans(10.5)).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            row(L("settings.tracking", "Tracking")) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Provider.allCases, id: \.rawValue) { p in providerRow(p) }
                    Text(L("settings.tracking.note",
                           "Anything switched off is never queried. \"Not installed\" means no login "
                           + "for that tool was found on this Mac."))
                        .font(Theme.sans(10)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
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
            row(L("settings.pushAway", "Push when you are away")) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L("settings.push.field", "ntfy / Bark URL — leave empty for no push"), text: $prefs.pushURL)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(11.5))
                    Text(L("settings.push.note", "Only used once you have been away from the keyboard for five minutes."))
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                }
            }
            row(L("settings.subscription", "Subscription price")) {
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

                    Text(L("settings.subscription.note",
                           "Leave empty to use the table price for the detected plan. The multiple is "
                           + "always computed in USD — the equivalent cost is itself a USD list price, "
                           + "and converting it would need an exchange rate this app has no reliable "
                           + "source for."))
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row(L("settings.other", "Other")) {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Toggle(L("settings.sound", "Sound"), isOn: $prefs.sound)
                    Toggle(L("settings.launchAtLogin", "Launch at login"), isOn: $prefs.launchAtLogin)
                }
                .toggleStyle(.switch).font(Theme.sans(12))
            }
        }
        .frame(width: 380)
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
                 "No usable Claude Code login was found — run claude auth login first.")
    }

    /// One line per provider, whether or not it is here. A tool that is installed but signed
    /// out and a tool that was never installed look identical when both are simply absent from
    /// the panel — so both are listed, and each says which it is.
    private func providerRow(_ p: Provider) -> some View {
        let reason = p.unavailableReason
        let detected = states[p]?.label
        return HStack(spacing: 7) {
            ProviderMarkView(provider: p, tint: reason == nil ? Theme.text : Theme.text2)
                .frame(width: 13, height: 13)
            Text(p.name).font(Theme.sans(12)).foregroundStyle(reason == nil ? Theme.text : Theme.text2)
                .lineLimit(1)
            Spacer(minLength: Theme.s1)
            // Empty until detection comes back off the main thread — a dash that turns into
            // "已登录" is honest; a guess that turns out wrong is not.
            Text(reason ?? detected ?? "…").font(Theme.sans(10)).foregroundStyle(Theme.text2)
                .lineLimit(1)
            Toggle("", isOn: Binding(get: { prefs.tracks(p) },
                                     set: { prefs.setTracking(p, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(reason != nil)
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
            case .claude: out[p] = Credentials.sharedItemExists() ? .signedIn : .signedOut
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

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(title.uppercased()).brandLabel().foregroundStyle(Theme.text2)
            content()
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
