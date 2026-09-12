# PWE AI Bar — 接手说明

最后更新 2026-09-07 深夜。分支 `forecast-engine` 与 `main` 同步，版本 `0.1.0`。
约 8,400 行 Swift，113 个测试，`swift test` 约 14 秒。经过两轮云端深度审阅（55 + 48 个 agent），
提出的十二条全部落地。

macOS 菜单栏应用，SwiftUI + AppKit，Swift Package，无第三方依赖。看八家 AI 编码工具的额度；
真正花力气的只有两件事——**读到 Claude 和 Codex 的真实数字**，以及**回答「按这个节奏，到不到得了重置」**。
其余六家是只读接入。

---

## 不显然的机制

读代码之前先读这几段，否则会把它们当成过度设计删掉。后三条是 1.0.13–1.1.1 补的，
每一条都是「只在构建机以外才看得见」的那类问题。

### 一、不用输密码，但需要授权一次（这一节 1.1.0 整节重写过）

**上一版这里写的是错的，而且那个错误论证造成了 1.0.8–1.0.12 的全部麻烦。** 原文说：Claude Code
写凭据时 shell 出去调 `/usr/bin/security`，所以那个二进制在记录的 ACL 上，「我们用同样的方式读就是
静默的、不需要始终允许」。真实情况是：**那个子进程会弹它自己的授权框**，标题写的是工具的名字
（`security` 想要访问……）而不是应用的名字，而且**每轮轮询都弹**。

真正的规则是**一个条目有两道互不相干的 UI 闸**：

| 闸 | 管什么 | 用什么关 |
|---|---|---|
| LocalAuthentication | 带 `SecAccessControl` 的条目（Touch ID、密码） | `kSecUseAuthenticationContext` + `LAContext.interactionNotAllowed` |
| 经典 ACL | `login.keychain` 上的普通条目 | **只有** `SecKeychainSetUserInteractionAllowed(false)` |

这个 app 曾经处处装了第一把锁，**一个都没装第二把**。现在的形状：

- **跑在定时器上的读取一律不具备弹窗能力** —— `Credentials.quietRead(service:account:)` 同时关两道闸，
  该弹窗的地方返回 `nil`。`ClaudeCredentialStore` 和 `ExtraSource`（Cursor / gh / Antigravity）都走它，
  **没有任何后台路径 fork `security` 工具**，有一条结构测试扫全部源码盯着这件事。
- **唯一允许弹窗的是 `Credentials.authoriseShared()`**，只由用户按下「改用钥匙串授权」触发，
  不设看门狗——它等的是人在读授权框，掐断它正是最初那个 bug。
- 弹框出现时必须选**「始终允许」**：只点「允许」仅对那一次读取有效，下一轮又被挡回去。
- **`claude auth login` 会重建这个钥匙串条目**，新条目的访问列表不含本应用，授权随之清空 ——
  登录之后需要再按一次那个按钮。这不是缺陷，是 macOS 的模型。

**那个按钮必须说出结果**（1.1.2）。它一度可以什么都不做：授权被拒 → `Task.detached` 里静默 return；
授权成功但登录本身还是过期的 → 刷新后 blocker 没变，界面照旧。**两种结局对读者长得一模一样**，
而其中一种根本不该按这个按钮 —— 过期的登录只有 `claude auth login` 能治。现在
`enableSharedKeychain()` 返回是否拿到凭据，`Store.enableRealQuota()` 把它翻成一句人话：
被拒就教「选始终允许」，拿到了但仍被挡就**把 blocker 的原话说出来**（里面带着那条命令）。
面板的 CTA 行也去掉了 `lineLimit` —— 它曾把唯一可执行的那句截成「…run cla…」。

`Providers/Credentials.swift`、`Providers/ClaudeCredentialStore.swift`、`Providers/ExtraSource.swift`。
诊断用 `--credprobe`：它在**真签名 bundle 内部**报告每种读法的 `OSStatus`（未签名的测试程序不在 ACL 上，
结论不能外推）。

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

**下面五条是不变量，不是风格偏好。破坏其中任何一条，代价是把用户从他自己的 Claude Code 里登出。
第 8 条是 2026-09-08 用一次真实的登出换来的。**

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
8. **先证明存得下，再花掉令牌。**（1.1.0）交换会让服务端作废旧 refresh token，而替代品的唯一一份
   在响应里；所以 `rotate` 先做一次**只读**的 compare-and-swap 回读（`Access.storable`），通不过
   就根本不交换。写回坏掉只损失一次轮询 + 30 分钟退避（`claudeRotationBlockedUntil`，**跨重启**
   记住，因为进程内的 `rejected` 表随进程死掉，而这个 app 被反复强杀重开过）。
   刻意保持只读：空写回去能证明更多，但那等于每次换发都往活凭据上写一次。

这五条各有一个会失败的回归测试，都在 `ClaudeUsageTests`：
`testARotationIsWrittenBackEvenIfTheAppStopsCaringMidFlight`、
`testCancellingTheReadingDoesNotCancelTheExchange`、
`testTwoFetchesNeverSpendTheSameRefreshTokenTwice`、
`testARecordThatCannotBeWrittenBackIsNeverExchangedFor`、`testAFailedWriteBackSurvivesARelaunch`。
改动这一段之后它们必须仍然通过，
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

### 四、订阅价格是读出来的，不是猜出来的

**档位来自 `rateLimitTier`，不是 `subscriptionType`。** 后者只说 "max"，分不出 5× 和 20×，
而那是**两倍**的差别。1.0.0–1.0.5 里价格是写死的常量 `20`（Pro 价），所以一个 Max 5× 账户
看到的回本是 782×，真值 156×——**错了五倍，而且页面从不显示订阅价，所以没有任何地方看着不对**。

`Pricing.planKey(tier:type:)` 只在能确定时返回档位；**只有 "max" 没有 tier 时返回 nil**。
拿不到价格时 `Trophy.subscriptionMonthly` 为 nil，页面就**不显示回本倍数**，改为提示去设置里填。
一个建立在没人核实过的价格上的比值，读起来和正确的比值一样自信——这就是它比不显示更糟的原因。

**A$150 和 US$100 都是 Max 5× 的价，彼此不是汇率换算。** Anthropic 按地区定价，
所以 `Subscription` 存两个数：`monthly` 给读者看（他真付的币种），`monthlyUSD` 用来算倍数
（等效成本本身就是 USD 目录价）。**等效成本不做币种换算**——那需要一个本应用没有可靠来源的汇率。
设置里两个数都可以改；留空则取 `pricing.json` 的 `subscriptions` 表。

### 五、摘要按「天 × 模型」分桶

`Digest.perDayModel: [Int: [String: Counts]]`。以前是 `perModel` 全历史总和 + `perDay` 只有成本，
那样的话日期区间**只能影响头部三个数字**，「按模型」和「Token」还是全历史——一个自己跟自己
矛盾的页面。现在区间对整页生效。代价是磁盘缓存格式升到 v3（v2 会被丢弃重建），
体量是天数 × 模型数，几千行。

区间按**日历天**回溯，不是活跃天：「最近 7 天」必须是同一个跨度，不然数字会因为两个原因
同时移动，失去可比性。而摊销的订阅费按**区间内的活跃天**算——两个工作日的一周，
你并没有花掉七天的订阅。

### 六、双语：英文在调用点，中文在表里

`L("key", "English")`。`en.lproj` 由 `Tools/loccheck` 从源码生成，只有 `zh-Hans.lproj`
是手维护的，于是漂移只可能朝一个方向发生。

> **手改 `en.lproj` 是无效操作。** 下一次 `loccheck`（`build-app.sh` 和 `release.sh` 都会跑）
> 会按调用点重新生成它，你的修改无声消失。这条上面写着，我照样犯了两次，两次都对外说了「已修复」
> 而其实没有 —— 所以现在有 `NoTerminalHomeworkTests.testEnglishIsGeneratedFromTheCallSites` 盯着。
> **改英文去调用点，改中文去表。**这个 app 是中文先写的，所以改造是**反过来**的：
中文搬进表，英文写到调用点。**方向别改回去**——缺一个 key 时回退到英文，
英文读者看到的是英文；反过来的话，缺 key 会给英文读者显示中文，
而那正是测试时没人会注意到的失败。

**它的失败是静默的。** `.lproj` 解析不到时每个 `L()` 都回退，app 在两种语言下渲染得
一模一样，构建绿、测试绿、面板看着完全正常。这个坑踩过两次：`.lproj` 放在 `Resources/`
里面时 SwiftPM 两个都不打包；挪到 target 根之后它又把 `zh-Hans.lproj` 写成 `zh-hans.lproj`，
`path(forResource:)` 按大小写没匹配上。`resolve()` 因此自己按大小写不敏感找目录，
`LocalisationTests` 直接断言中文表**取得到**——除了它没有任何东西会注意到这种回退。

三条规矩：

1. **语序不同的地方用 `String(format:)`，不要拼接。**「%@没有新读数」对
   "No reading for %@"——拼接能出对的英文和坏掉的中文。
2. **不许拿显示文案当判断条件。** 改造前有三处这么写的（`title == "管理凭据"`、
   `hookState == "未安装"`、`states[.claude] == "已登录"`），翻译之后每一处都会
   稳定地走错分支。全部换成了 case。
3. **存进 defaults 的记录存 key，不存句子。** `claudeRefreshOutcome` 原来存中文句子，
   而那是一条比写它的那次运行活得更久的法证记录——事后没法翻译。

`loccheck` 是构建闸门（`build-app.sh` 里，编译之前），不是提醒。汉字排印按品牌标准
§7.2 例外：`Theme.labelSize` / `labelTracking`，汉字 +1pt、0.4× 字距。

### 七、资源只在构建机上找得到（1.0.13 修）

**1.0.0 到 1.0.12 在构建它的那台 Mac 以外一律打不开** —— 能装、能启动，然后什么都不出现：
没有菜单栏图标、没有窗口，因为它死在创建状态栏项之前。

SwiftPM 给**可执行**目标生成的 `Bundle.module` 按两条路径找资源包：先找
`Bundle.main.bundleURL`（.app 的**根目录**），再退回**编译时写死的绝对路径**
`…/.build/arm64-apple-macosx/release/PWEAIBar_PWEAIBar.bundle`。而 `build-app.sh` 把资源包放在
`Contents/Resources`（.app 该放的地方），所以第一条在任何机器上都失败，第二条只在有源码检出的
那台机器上成立。首次触碰是当时的 `Theme.registerFonts()` → `fatalError`。**构建机永远发现不了。**
（1.2.0 换成系统字体后已经没有这个函数了;留着这段是因为坑在资源解析上,不在字体上。）

- `Bundle.resources`（`Core/Resources.swift`）是唯一的访问器：`Contents/Resources` → .app 根 →
  `.module` 兜底（保留只为 `swift run` / `swift test`）。一条结构测试禁止其他源码碰生成的访问器。
- `--selfcheck` 让**组装好的 app 从自身内部**证明每项资源都在自身内部（两种字体、价格表、hook 脚本、
  两个语言包），`build-app.sh` 拿它当出包闸门，不过就拒绝出包。
- **复现任何回归的方法**：把 `.build/arm64-apple-macosx/release/PWEAIBar_PWEAIBar.bundle` 改名，再启动。

### 八、窗口高度由视图申报，不是问出来的（1.1.0 修）

面板早就是这个契约（见「已知风险」里 1.0.1–1.0.4 那条记录），**设置窗口 1.0.10–1.0.14 却不是**：
它用 `NSHostingView.fittingSize` 定高，而那个数**在页面完成布局之前恒为 0**（两种 `sizingOptions`
都实测过）。于是设置窗口在别的机器上**只开出一根标题栏** —— 而 Claude 的全部可改项都在那扇窗里，
「claude 那里改不了」就是这件事。

现在设置页和面板同一套：内容量进 `SettingsHeight` 这个 `PreferenceKey`，取 `min(内容, 天花板)`，
经 `onHeight` 报给窗口；`NSWindow.setContentHeight`（`App/WindowSizing.swift`）负责应用。两个细节
各坑过一轮：

- **`reduce` 必须用 `max`**。ScrollView 的内部也会以默认值 0 参与同一个键，而且可能**后到** ——
  用「取最新值」会把量到的 678 覆写成 0，回调只响一次且带着 0。
- **`.fullSizeContentView` 的窗口把内容藏在标题栏底下**，窗口内容高度必须是页面高度**加上**
  `contentRect.height − contentLayoutRect.height`（这里 32 pt），否则页面会静静地滚掉那一截。

测它要把 run loop **分成小片泵**（`30 × run(until: +0.02)`）；一次长的 `run(until:)` 会在 SwiftUI
把偏好传播完之前就返回，测试什么都看不到。

### 九、菜单栏重绘会自我触发（1.1.1 修）

空转时烧掉 49–66% 的一个核，而且在往上爬。这是自己追自己的尾巴：`redraw` 赋值
`statusItem.button.image` → AppKit **重新解析按钮的 effective appearance** →
`observe(\.effectiveAppearance)` 的观察者触发 → 再 redraw。**每秒约 3,050 次**，只被 run loop 限速。

两道闸，缺一不可：

- 观察者取 `options: [.old, .new]`，外观名没变就返回。**这是环本身。**
- `PaintedState`（`App/StatusIcon.swift`）比对**画出来的字节**（TIFF）加提示语，一样就不碰图层，
  这样将来任何调用方都打不开这个环。**刻意比对绘制结果而不是「输入键」**：图标里有倒计时，
  键就得懂时间，而键一旦和渲染器脱节，菜单栏会**冻住** —— 比原 bug 更糟。

**定位它靠的不是 profiler。** `sample` 是墙钟采样，显示主线程「在 Core Animation 里」，
但大半其实**阻塞在 `mach_msg` 等渲染服务器**；`ps -M` 每线程只报 0.4%。一击定案的是应用自己的
计数器：`PWEBAR_DEBUG=1`，12 秒 36,601 次。**判断「是不是跑得太频繁」，廉价计数器胜过 profiler。**

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

**但这套推理是我们的，不是读者的**（1.1.6）。计量网络、电池供电的笔记本上，「就是每十五分钟一次」
是完全正当的要求，所以设置里能选固定间隔，`Store.interval` 先看 `Prefs.refreshInterval`，
`.automatic` 才回落到上面那张表。默认仍是自动。

### 追踪 ≠ 出现在菜单栏（1.1.6）

两个问题被当成一个开关问了很久：**查不查**，和**要不要在菜单栏占位**。八家一起挤，栏位先用完的
永远不是读者的兴趣，而此前唯一的控制是一个对所有家一起生效的密度开关。现在
`Prefs.showsInMenuBar(_:)` 管后者，设置页是一张两列的表。

`menuBarProviders` **空集表示全部** —— 升级绝不能悄悄清空谁的菜单栏；集合只在读者第一次拿掉
某一家时才被具象化（`setMenuBar`）。

顺带修掉一个真 bug:`StatusIcon.providers` 的门控以一个「匹配除这两家之外全部」的 `||` 分句结尾，
于是**其余五家绕过了追踪开关**——开关在别处都生效，唯独在菜单栏不生效。现在只有一道门,
并且有结构测试盯着不许再开旁路。

---

## 怎么跑

```bash
swift test                      # 147 个
./scripts/build-app.sh          # 组装、签名，并跑 --selfcheck 闸门
```

自检子命令（都不打印令牌、账号或服务器正文）：

| 命令 | 用途 |
|---|---|
| `--credentials-read-only` | 查询额度但**不轮换**令牌；顺带打印「本 app 续期过没有」 |
| `--credentials` | 完整查询 + 续期流程 |
| `--endurance <dir>` | 续航仪 14 个敌意状态 × 明暗两套，渲染成 PNG |
| `--panel <dir>` | 三种密度 × 明暗，真实数据 |
| `--probe` | 全链路 |
| `--version` | 打印版本号，和设置页页脚读同一处 |
| `--selfcheck` | 从 .app 内部证明每项资源都在 .app 内部；`build-app.sh` 拿它当出包闸门（机制七） |
| `--credprobe` | 在真签名 bundle 里报告各种钥匙串读法的 `OSStatus`（机制一） |
| `PWEBAR_DEBUG=1` | 每次菜单栏重绘打一行。判断「是不是画得太频繁」，这个计数器比 profiler 快得多（机制九） |

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

`release.sh` 的顺序是：预检（身份、公证凭据、干净的树、**没有 iCloud 冲突副本**、`gh`、标签没被占）·
`swift test` · 写 VERSION · 构建 · Developer ID 签名 · **`--selfcheck` 出包闸门（机制七）** ·
公证 · staple · Gatekeeper 判决（dmg 和里面的 app 各一次）·
提交打标签推送 · GitHub Release · **把已发布的那份下回来核对校验和与 Gatekeeper** · 更新
Homebrew cask 并推 tap。中途失败会把 VERSION 和 cask 还原。**版本号只写在 `VERSION` 里**，
`Info.plist` 由 `build-app.sh` 从它生成，所以不存在两处对不上。

Team ID `2SQV3H5MH9`，产物在 `dist/`。签名和打包都在 `$TMPDIR` 里做，只有做好的 dmg 回到
`dist/`——iCloud 的文件提供者会不停给仓库里的文件盖 `com.apple.FinderInfo`，而 codesign 拒绝
带着它的 bundle，先清再签是个会间歇性输掉的竞态。

站点不在这个仓库里，`release.sh` 不碰它：`cd '../PWE Loan Bar' && ./site/deploy.sh`。

---

## 已验证 / 未验证

**已验证**：真实只读查询成功；面板读到 Claude 周窗口、五小时、上下文三行实况；147 个测试通过；
**在构建机以外的 Mac 上装好、打开、进入设置**（1.0.13 起，见机制七）；
钥匙串条目在多轮读写后 accessToken / refreshToken / scopes 完整；续航仪 14 个状态明暗两套渲染无溢出；
两轮云端审阅的十二条全部修复，其中六条配了先失败后通过的回归测试。

**未验证，且要说清楚**：

0. **~~写回失败那条路径没被真实触发过~~ —— 2026-09-08 触发了三次，而且代价是真的。**
   三次交换都成功（服务器当场作废旧 refresh token 并发新的），三次写回都失败（当时的 CAS 回读还在
   fork `security`，弹框在超时内没人答得上），三个替代品全丢。第三次之后钥匙串里那个 refresh token
   已被服务器拒绝（`invalid_grant`），**那台机器上 Claude Code CLI 共享的登录只能用
   `claude auth login` 重建**。这正是机制二一直在防的事，防错了顺序而已 —— 修法见机制二。

1. **~~续期路径从没成功过~~ —— 2026-09-08 07:37:49 成功了一次，`累计成功 1 次`。**
   这条从「安全网，没人验过」变成了「真的跑过，真的写回去了，真的没把人登出」。
   剩下没验证的是**失败**分支：写回失败那条路径（`.storage`）依旧没被真实触发过。

   在此之前的那次是 2026-09-07 23:29，失败，而且失败是对的： 那条钥匙串
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

- **~~写回失败的窗口~~ —— 2026-09-08 发生了，代价是一次真实的登出（1.1.0、1.1.1 收口）**。
  当时的 CAS 回读还在 fork `security`，弹框在超时内没人答得上，三次交换的替代品全丢，
  第三次之后钥匙串里的 refresh token 被服务端拒绝。现在两头都堵上了：读取不再具备弹窗能力
  （机制一），交换之前先证明写得回（机制二第 8 条）。**残余风险**：证明和写回之间仍有一道缝，
  磁盘在那一瞬坏掉依然无法撤销 —— 只能记录，失败写进 `claudeRefreshOutcome`，
  `--credentials-read-only` 会打印。
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
               Resources(唯一的资源访问器,机制七)
  Providers/   Claude{Provider,CredentialStore,UsageClient,UsageMapper} Credentials
               Codex{Provider,AppServer} Extra{Source,Providers} Hook Transcript LineScanner
  App/         PanelView EnduranceView SettingsView StatusIcon(含 PaintedState,机制九)
               UsageChart TrophyView ProviderMark{,View} NotchWindow
               WindowSizing(NSWindow.setContentHeight,机制八)
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
  paper `#F7F5F2`、ink `#0C0A09`。**字体是系统字体**(1.2.0 起;Inter 没有汉字,双语界面里它
  从来只覆盖了一半读者 —— 见 `Brand/Theme.swift` 顶部)。间距按 φ = 1.618034,字号不按。
- 提交信息第一行是一句人话，不是 `feat:`。正文写清楚**为什么这么改**，以及改之前是怎么错的。
- 一次改动配一个能失败的测试。渲染类的改动跑一遍 `--endurance` / `--panel` 用眼睛看过再提交。
