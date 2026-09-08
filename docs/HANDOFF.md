# PWE AI Bar — 接手说明

最后更新 2026-09-07 深夜。分支 `forecast-engine` 与 `main` 同步，版本 `0.1.0`。
约 8,400 行 Swift，113 个测试，`swift test` 约 14 秒。经过两轮云端深度审阅（55 + 48 个 agent），
提出的十二条全部落地。

macOS 菜单栏应用，SwiftUI + AppKit，Swift Package，无第三方依赖。看八家 AI 编码工具的额度；
真正花力气的只有两件事——**读到 Claude 和 Codex 的真实数字**，以及**回答「按这个节奏，到不到得了重置」**。
其余六家是只读接入。

---

## 三件不显然的机制

读代码之前先读这三段，否则会把它们当成过度设计删掉。

### 一、不用输密码

钥匙串的授权是按「条目 × 程序」给的。Claude Code 写自己的凭据时是 shell 出去调 `/usr/bin/security`，
所以那个二进制在这条记录的 ACL 上。**我们用同样的方式读，就是静默的**；换成 `SecItemCopyMatching`
从别的 app 直接读，就会弹授权框。代价是一次约 20ms 的子进程，换来的是不弹框、不需要「始终允许」、
重新签名后也不会再弹。

`Providers/Credentials.swift`、`Providers/ClaudeCredentialStore.swift`。

### 二、令牌自己续期（改这里之前请读完整节）

Claude Code 会把这条钥匙串记录**晾着**——本机实测过一次，过期后放了 32 小时没管，面板因此显示了
一整天前的数字。所以我们自己续：拿记录里的 refresh token，在到期前几分钟 POST
`platform.claude.com/v1/oauth/token`（client_id 用 Claude Code 的公开值），再用 compare-and-swap
写回**同一个位置**。

三条不能动的规矩：

1. **轮换时在原 JSON 上改字段**，不要用 Codable 结构体重新编码——那会把我们没建模的字段悄悄丢掉，
   而那条记录不只属于我们。
2. **写回前再比一次**（`ClaudeCredentialStore.save(_:expected:)`）。凭据在我们换令牌的这几百毫秒里
   被 CLI 改过，就放弃，不要覆盖。
3. **写回失败不要重试轮换**。交换已经发生了，如果服务端轮换了 refresh token，Claude Code 手里那份
   可能已经作废。

**下面四条是不变量，不是风格偏好。破坏其中任何一条，代价是把用户从他自己的 Claude Code 里登出。**

4. **换发返回之后，到写回之前，不许有任何取消检查、也不许重读凭据。** 一旦 POST 返回，服务端
   可能已经作废了 CLI 手里那份，而替代品的唯一一份就在内存里。写回不是「为调用方生产结果」的
   一部分，是无论还有没有人要结果都必须跑完的收尾。
5. **换发整段跑在非结构化 `Task` 里**（`exchange`），因为非结构化任务不继承取消。`invalidate()`
   会 `task?.cancel()`，而 URLSession 尊重取消——不这样做，一次设置里的「重新连接」就能在 POST
   途中把它拆掉，替代品装在没人在听的响应里。
6. **同一份凭据同时只能有一次换发在途**（`rotations` 按 generation 索引）。被取消的任务不等于
   已停下的任务，下一次 `windows()` 会从磁盘读到那份还没写回的旧凭据，拿同一个 refresh token
   再换一次；第二次的 `invalid_grant` 到达时，第一次换来的替代品可能已经是唯一能用的凭据。
7. **写回之后再 `check(version)`。** 那时候丢弃结果是免费的。

这四条各有一个会失败的回归测试，都在 `ClaudeUsageTests`：
`testARotationIsWrittenBackEvenIfTheAppStopsCaringMidFlight`、
`testCancellingTheReadingDoesNotCancelTheExchange`、
`testTwoFetchesNeverSpendTheSameRefreshTokenTwice`。改动这一段之后它们必须仍然通过，
而且**撤掉你的改动它们必须失败**——我验过每一个。

`Providers/ClaudeUsageClient.swift`、`ClaudeCredentialStore.swift`、`ClaudeProvider.rotate`。

### 三、速率是区间，不是数字

**每一条读数都是整数**（Claude 的 `utilization`、Codex 的 `usedPercent`），长时间的平台期是常态。
误差不是高斯噪声，是量化。所以不要往这里放回归、EWMA 或卡尔曼——它们都在平均一个不存在的 ε。

```
rate.low  = max(0, Δp − 1) / S        （S 为小时）
rate.high = (Δp + 1) / S
```

两端都是界。一个式子带来三个想要的性质：平台期只给上界（于是有续航**下界**，敢说「至少还能跑」）；
单级跳的下界必为零（于是**一步永远不能宣布你会用尽**）；爆发随 S 增长自行衰减。
**区间的宽度就是不确定性的出口**，不需要另设置信度参数。

判决单边、共七个、各有颜色档，求值顺序写在 `Forecast.make` 里且顺序本身是被对抗审查逼出来的，
改之前先读那几段注释。完整规格：[FORECAST_ENGINE_SPEC_2026-09-06.md](FORECAST_ENGINE_SPEC_2026-09-06.md)，
§9 记了三个对手 agent 提的 20 条里哪些照做了、哪些没做以及为什么。

`Core/Forecast.swift`、`Core/History.swift`、`App/EnduranceView.swift`。

---

## 轮询节奏

这里有过一个反向逻辑：任何窗口一变红就把 TTL 压到 60 秒。一天 1440 次请求，换来一小时的
`Retry-After`，然后面板显示了 33 小时前的数字——**在读者最在意的那一刻打得最狠，产出最少的信息**。

现在跟着「这个数字有没有可能动过」走：

| 情形 | 间隔 |
|---|---|
| 窗口已用尽 | 等它自己滚过去再加一拍 |
| 重置在 5 分钟内 | 2 分钟 |
| 其余 | 5 分钟（AI Usage 出厂默认也是 5 分钟） |

另一半是事件驱动：一个回合落地后 25 秒问一次，去抖 90 秒（`Store.scheduleSettle`）。
心跳负责不让数字发霉，事件负责让它在真的发生了什么的时候到达。**正因为有后者，前者才敢慢。**

---

## 怎么跑

```bash
swift test                      # 108 个
./scripts/build-app.sh          # 组装并 ad-hoc 签名到 build/PWE AI Bar.app
```

自检子命令（都不打印令牌、账号或服务器正文）：

| 命令 | 用途 |
|---|---|
| `--credentials-read-only` | 查询额度但**不轮换**令牌；顺带打印「本 app 续期过没有」 |
| `--credentials` | 完整查询 + 续期流程 |
| `--endurance <dir>` | 续航仪 14 个敌意状态 × 明暗两套，渲染成 PNG |
| `--panel <dir>` | 三种密度 × 明暗，真实数据 |
| `--probe` | 全链路 |

**注意**：`--panel`、`--stress`、`--probe` 会各起一个完整的 `Store`，也就是**一次真实的网络请求**，
并且会覆写共享的 `~/Library/Caches/PWE AI Bar/history.json`。两个写者会互相覆盖，别在 app 运行时
连着跑它们来分析历史。这是已知问题，还没修。

### 发版（在另一台机器上做）

Developer ID 私钥只在发版机上，本机 `build-app.sh` 出来的是 ad-hoc 签名，Gatekeeper 在别的机器
上一律拒绝。发版机上：

```bash
scripts/release.sh 1.0.1          # 全流程，见下
scripts/package.sh --notarize     # 只要一个签好名公证过的本地 dmg
```

`release.sh` 的顺序是：预检（身份、公证凭据、干净的树、`gh`、标签没被占）· `swift test` ·
写 VERSION · 构建 · Developer ID 签名 · 公证 · staple · Gatekeeper 判决（dmg 和里面的 app 各一次）·
提交打标签推送 · GitHub Release · **把已发布的那份下回来核对校验和与 Gatekeeper** · 更新
Homebrew cask 并推 tap。中途失败会把 VERSION 和 cask 还原。**版本号只写在 `VERSION` 里**，
`Info.plist` 由 `build-app.sh` 从它生成，所以不存在两处对不上。

Team ID `2SQV3H5MH9`，产物在 `dist/`。签名和打包都在 `$TMPDIR` 里做，只有做好的 dmg 回到
`dist/`——iCloud 的文件提供者会不停给仓库里的文件盖 `com.apple.FinderInfo`，而 codesign 拒绝
带着它的 bundle，先清再签是个会间歇性输掉的竞态。

站点不在这个仓库里，`release.sh` 不碰它：`cd '../PWE Loan Bar' && ./site/deploy.sh`。

---

## 已验证 / 未验证

**已验证**：真实只读查询成功；面板读到 Claude 周窗口、五小时、上下文三行实况；113 个测试通过；
钥匙串条目在多轮读写后 accessToken / refreshToken / scopes 完整；续航仪 14 个状态明暗两套渲染无溢出；
两轮云端审阅的十二条全部修复，其中六条配了先失败后通过的回归测试。

**未验证，且要说清楚**：

1. **续期路径在真实账户上触发过一次，2026-09-07 23:29，失败，而且失败是对的。** 那条钥匙串
   记录从 09-01 起就没被写过，`expiresAt` 停在 09-02、`refreshTokenExpiresAt` 停在 09-03——
   我们拿一个已经死了四天的 refresh token 去换，服务端回 `invalid_grant`。**没有写入发生，
   记录的修改时间仍然是 09-01，没有任何人因此掉线。** 四条不变量守住了。
   顺带暴露的真问题见下一节第一条。**累计成功续期仍然是 0 次**，所以「换到了但写不回去」
   那条风险路径依旧没有被真实触发过。
2. **refresh token 会不会轮换，不知道。** 零风险的验证方式：记下当前 refresh token 的 SHA-256 前
   16 位，等 Claude Code 下次续期后再取一次比对。变了就说明会轮换，那条写回失败的风险窗口就是真的。
3. **另外五家（Cursor、Copilot、Devin、Grok、Antigravity）从未在真实账户上验证过**——
   本机一个都没装。全部只读、全部 `appPresent()` 门控、全部有超时。

---

## 已知风险与待办

- **~~拿死掉的 refresh token 去换~~（1.0.1 修）**。那条记录里一直有 `refreshTokenExpiresAt`，
  我们没读。现在读了：这个日期已经过去、并且**本 app 从未成功续期过**（`claudeRefreshCount == 0`）
  的时候，直接不换发，并且把日期和 `claude auth login` 一起说出来。第二个条件不能去掉——
  一旦我们自己换过一次，这个字段描述的可能是一个已经不存在的 refresh token，
  凭一个过期的日期拒绝续一个还活着的凭据，比白发一次请求糟得多。
  两个方向各有一个回归测试（`ClaudeUsageTests`）。
- **~~面板高度~~（1.0.1、1.0.2、1.0.3 都没修对，1.0.4 才对）**。原问题是真的：内容最多 913 pt，
  1440×900 放不下，溢出被推到屏幕上方，标题栏和续航仪够不着。三次修错值得写下来，
  因为每一次的测试都是绿的。

  1. **1.0.1**：无条件包 `ScrollView`。`ScrollView` 纵向完全可伸缩、**不产生约束**，
     于是面板不再向 popover 要高度，popover 停在约 300 pt，整个面板在里面滚。
  2. **1.0.2**：把上限从 860 提到跟随屏幕。毫无作用——**上限从来没被碰到过**。
  3. **1.0.3**：装得下就不包 ScrollView。内容拿到自然高度了，但 popover 是
     **显示之后**才被 AppKit 改大的，它于是向上重新锚定：**顶部跑到屏幕上方 338 pt**。

  **这从来不是布局问题，是通信问题。** 面板必须**说出**一个高度，
  而拥有窗口的那一半必须**设置**它。现在：`PanelView.desiredHeight`
  = `min(chrome + middle, ceiling)`，通过 `onHeight` 报出去；
  `AppDelegate.resizePanel` 把它写进 `popover.contentSize`，**并且在 `show` 之前就写好**。
  `ScrollView` 一直在（形状不随读数变化），装得下就没有东西可滚。

  **`PanelHeightTests` 只能覆盖前一半**——一个 hosting view 回答不了「AppKit 把窗口放在哪」，
  假装它能回答，正是前两次带着绿灯发版的原因。后一半用
  **`PWEAIBar --popover`**：在真实状态栏项上开真实弹出框，打印窗口 frame 与屏幕 frame 的关系。
  `PWEBAR_PROBE_NO_RESIZE=1` 可以复现 1.0.3 的行为。**改这一段之后跑一次。**

- **写回失败的窗口**（机制二第 3 条）。窗口已经被收到最窄——换发与写回之间不再有任何可取消点，
  也不会有第二次换发——但如果磁盘/钥匙串写入本身失败，交换已经发生这件事无法撤销。只能记录：
  失败会写进 `claudeRefreshOutcome`，`--credentials-read-only` 会打印出来。
- **`offActor` 的 15 秒超时会把一次慢成功报成失败**。超时后继续跑的那次写入仍可能成功，而我们
  已经记了「换到了但写不回去」并把这份凭据标成 `.storage` 拒绝。下一次凭据变化会自愈（`adopt`
  清空 `rejected`），所以留着没修，但报出来的话不准。
- **history.json 双写者**（见上）。修法是 History 写之前先读回来合并，或者自检子命令改用独立缓存目录。
- **周窗口上的区间带只有约 11pt 宽**。七天的横轴上本来就该窄，信息由尺寸线和结论句承担，不打算改。
- `.fallsShort` 的大数字取自 `enduranceLow`、缺口取自 `enduranceHigh`，两者相加不等于 trip。
  两个数回答两个问题且都是下界，图上针与红线画在不同位置分得开，不打算改。

---

## 仓库地图

```
Sources/PWEAIBar/
  Core/        Forecast(预报引擎) History(采样环) Store(节奏) RuleEngine(提醒)
               Model Prefs Pricing Readout Probe(自检) Channel Notifier TokenEditor
  Providers/   Claude{Provider,CredentialStore,UsageClient,UsageMapper} Credentials
               Codex{Provider,AppServer} Extra{Source,Providers} Hook Transcript LineScanner
  App/         PanelView EnduranceView SettingsView StatusIcon UsageChart TrophyView
               ProviderMark{,View} NotchWindow
  Brand/       Theme WingGauge BrandMark        Resources/  字体、图标、pricing.json
docs/
  HANDOFF.md                    这份
  FORECAST_ENGINE_SPEC_2026-09-06.md            预报引擎规格（§9 是对抗审查结论）
  AI_USAGE_MENUBAR_RESEARCH_AND_IMPLEMENTATION_2026-09-05.md   为什么不用输密码
  CLAUDE_USAGE_IMPLEMENTATION_RESEARCH_2026-09-07.md   续期方案的调研
  design.html                   设计方案全文
  history/                      已经完成的几轮交接与审计报告，留档不再维护
```

---

## 约定

- **文档和提交信息用中文，代码注释用英文。** 注释解释「为什么」和「上一版为什么错」，不解释「做了什么」。
- 面板里不用缩写；菜单栏里才靠剪影省地方。**菜单栏静态，不做动画。**
- 品牌色：navy `#0E1729`、amber `#F5B335`（**只用于深底**）、deep amber `#A16207`（**只用于浅底**）、
  paper `#F7F5F2`、ink `#0C0A09`。字体 Playfair Display + Inter。排版按 φ = 1.618034。
- 提交信息第一行是一句人话，不是 `feat:`。正文写清楚**为什么这么改**，以及改之前是怎么错的。
- 一次改动配一个能失败的测试。渲染类的改动跑一遍 `--endurance` / `--panel` 用眼睛看过再提交。
