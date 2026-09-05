import SwiftUI

/// Density is a preference, not a house opinion — some people want every reading in the bar and
/// some want one glyph. What is not a preference is arrangement: whichever density you pick,
/// the same alignment rules hold.
struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var installHooks: () -> Bool
    var saveToken: (String) async -> ClaudeProvider.TokenUpdate
    var enableRealQuota: () -> Void
    @State private var hookState: String
    @State private var states: [Provider: String] = [:]
    @State private var token: String = ""
    @StateObject private var tokenEditor: TokenEditor

    init(installHooks: @escaping () -> Bool,
         saveToken: @escaping (String) async -> ClaudeProvider.TokenUpdate,
         enableRealQuota: @escaping () -> Void, prefs: Prefs? = nil,
         tokenEditor: TokenEditor? = nil, hookInstalled: Bool? = nil) {
        self.installHooks = installHooks; self.saveToken = saveToken; self.enableRealQuota = enableRealQuota
        self.prefs = prefs ?? .shared
        _tokenEditor = StateObject(wrappedValue: tokenEditor ?? TokenEditor(hasToken: Credentials.hasOwnToken))
        let installed = hookInstalled ?? HookProvider.isInstalled
        let current = HookProvider.installedScriptIsCurrent(
            source: Bundle.module.url(forResource: "pwe-ai-bar-hook", withExtension: "sh"))
        _hookState = State(initialValue: !installed ? "未安装" : current ? "已安装" : "脚本待更新")
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
            row("菜单栏") {
                Picker("", selection: $prefs.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            row("面板") {
                Picker("", selection: $prefs.panelMode) {
                    ForEach(PanelMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            row("百分比口径") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $prefs.showRemaining) {
                        Text(Readout.label.remaining).tag(true)
                        Text(Readout.label.used).tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("Codex 自己显示的是剩余，Claude 的接口给的是已用。"
                         + "统一成一种，免得同一个数看着像两回事。")
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row("提醒落点") {
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
                        Text("这台机器没有刘海，所以没有那个选项。")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                    }
                }
            }
            row("额度数据来源") {
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
                        SecureField("粘贴 claude setup-token 生成的令牌", text: $token)
                            .textFieldStyle(.roundedBorder).font(Theme.sans(11.5))
                        Button(tokenEditor.isSaving ? "验证中…" : tokenEditor.hasToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "清除" : "保存") {
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
                             ? "令牌保存在本 app 的钥匙串中，仍可能失效或被撤销。可直接粘贴新令牌更换，或清空输入后点「清除」。"
                             : "一般不需要填。额度直接读 Claude Code 自己的凭据，不弹框。只有这台机器没登录 Claude Code 时，才用 claude setup-token 生成一个粘进来。")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.s1)
                        // The prompting path is a fallback for machines where reading Claude
                        // Code's credential the quiet way did not work. With a token in hand it
                        // would change nothing, so it is not offered.
                        if !tokenEditor.hasToken {
                            Button("改用钥匙串授权") { enableRealQuota() }
                                .font(Theme.sans(11))
                                .help("读不到 Claude Code 凭据时的退路，会弹一次系统授权框")
                        }
                    }
                    if !tokenEditor.message.isEmpty {
                        Text(tokenEditor.message).font(Theme.sans(10.5)).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            row("追踪") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Provider.allCases, id: \.rawValue) { p in providerRow(p) }
                    Text("关掉的不会被查询。「未安装」指本机找不到该工具存下的登录信息。")
                        .font(Theme.sans(10)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }
            row("会话事件") {
                HStack {
                    Text("Claude Code hooks · \(hookState)")
                        .font(Theme.sans(12)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button(hookState == "未安装" ? "安装" : "重新安装") {
                        hookState = installHooks() ? "已安装" : "失败"
                    }
                    .font(Theme.sans(12))
                }
            }
            row("离座时推送") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("ntfy / Bark 的 URL，留空则不推送", text: $prefs.pushURL)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(11.5))
                    Text("只在你离开键盘超过 5 分钟时才会用到。")
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                }
            }
            row("其它") {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Toggle("提示音", isOn: $prefs.sound)
                    Toggle("开机启动", isOn: $prefs.launchAtLogin)
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
        if states[.claude] == "已登录" {
            return "正在直接读 Claude Code 自己的凭据，不需要授权，也不会弹框。"
        }
        if tokenEditor.hasToken {
            return "读不到 Claude Code 的凭据，改用下面保存的令牌。"
        }
        if prefs.sharedKeychainOptIn {
            return "已选择钥匙串授权，连接结果请查看额度面板。"
        }
        return "还没找到 Claude Code 的登录信息，只有本地估算。"
    }

    /// One line per provider, whether or not it is here. A tool that is installed but signed
    /// out and a tool that was never installed look identical when both are simply absent from
    /// the panel — so both are listed, and each says which it is.
    private func providerRow(_ p: Provider) -> some View {
        let reason = p.unavailableReason
        let detected = states[p]
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
        .accessibilityLabel("\(p.name)，\(reason ?? detected ?? "检测中")")
    }

    /// Detection only: whether a credential exists, never whether it still works. Saying
    /// "已连接" before a single request has come back would be inventing a fact.
    ///
    /// Run once, off the main thread, and never from inside a view body: finding these costs
    /// `sqlite3` and `security` subprocesses, and SwiftUI re-evaluates a body far more often
    /// than anyone installs an IDE.
    nonisolated private static func detect() -> [Provider: String] {
        var out: [Provider: String] = [:]
        for p in Provider.allCases where p.unavailableReason == nil {
            switch p {
            case .claude: out[p] = Credentials.sharedItemExists() ? "已登录" : "未登录"
            case .codex:  out[p] = CodexAppServer.executable() != nil ? "已安装" : "未安装"
            default:      out[p] = ExtraProviders.installed(p) ? "检测到" : "未安装"
            }
        }
        return out
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
