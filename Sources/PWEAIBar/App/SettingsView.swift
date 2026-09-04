import SwiftUI

/// Density is a preference, not a house opinion — some people want every reading in the bar and
/// some want one glyph. What is not a preference is arrangement: whichever density you pick,
/// the same alignment rules hold.
struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var installHooks: () -> Bool
    @State private var hookState: String = HookProvider.isInstalled ? "已安装" : "未安装"

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
            row("提醒落点") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $prefs.placement) {
                        ForEach(AlertPlacement.allCases) { p in
                            Text(p.label).tag(p)
                                .disabled(p == .notch && !Prefs.hasNotch)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                    if !Prefs.hasNotch {
                        Text("这台机器没有刘海，该选项不可用。")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.text2)
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
