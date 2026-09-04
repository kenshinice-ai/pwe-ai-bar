import SwiftUI

/// Density is a preference, not a house opinion — some people want every reading in the bar and
/// some want one glyph. What is not a preference is arrangement: whichever density you pick,
/// the same alignment rules hold.
struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var installHooks: () -> Bool
    var saveToken: (String) -> Void
    var enableRealQuota: () -> Void
    @State private var hookState: String = HookProvider.isInstalled ? "已安装" : "未安装"
    @State private var token: String = ""
    @State private var tokenState: String = Credentials.hasOwnToken ? "已保存" : ""

    var body: some View {
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
                        Button(Credentials.hasOwnToken && token.isEmpty ? "清除" : "保存") {
                            saveToken(token)
                            tokenState = token.isEmpty ? "" : "已保存"
                            token = ""
                        }
                        .font(Theme.sans(12))
                    }

                    HStack(spacing: Theme.s2) {
                        Text("想彻底不再弹框：终端运行 claude setup-token，把结果粘进来。")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("授权钥匙串") { enableRealQuota() }
                            .font(Theme.sans(11))
                    }
                    if !tokenState.isEmpty {
                        Text(tokenState).font(Theme.sans(10.5)).foregroundStyle(Theme.accent)
                    }
                }
            }
            row("追踪") {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Toggle("Claude Code", isOn: $prefs.trackClaude)
                    Toggle("Codex", isOn: $prefs.trackCodex)
                }
                .toggleStyle(.switch).font(Theme.sans(12))
            }
            row("会话事件") {
                HStack {
                    Text("Claude Code hooks · \(hookState)")
                        .font(Theme.sans(12)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("安装") { hookState = installHooks() ? "已安装" : "失败" }
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
        .background(Theme.surface)
        // System blue on a navy-and-amber panel reads as someone else's app. One tint at the
        // root covers every switch, picker and button below it.
        .tint(Theme.accent)
    }

    private var sourceLine: String {
        if Credentials.hasOwnToken {
            return "正在用长期令牌，不会有任何授权弹框。"
        }
        if UserDefaults.standard.bool(forKey: "sharedKeychainOptIn") {
            return "正在读 Claude Code 的钥匙串凭据，已授权。"
        }
        return "还没接真实额度，只有本地估算——而且不会有任何弹框。"
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
