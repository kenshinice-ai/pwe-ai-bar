# PWE AI Bar — 接手说明

最后更新 2026-09-23。`main` 上是 1.5.0；分支 `claude/token-monitor-optimization-iitxj3` 在它之上做了一轮修复
（**未发版**，见下面「2026-09-23 这一轮」）。约 10,800 行 Swift，212 个测试。经过两轮云端深度审阅
（55 + 48 个 agent），提出的十二条全部落地。

macOS 菜单栏应用，SwiftUI + AppKit，Swift Package，无第三方依赖。看八家 AI 编码工具的额度；
真正花力气的只有两件事——**读到 Claude 和 Codex 的真实数字**，以及**回答「按这个节奏，到不到得了重置」**。
其余六家是只读接入。

---

## 不显然的机制

读代码之前先读这几段，否则会把它们当成过度设计删掉。后三条是 1.0.13–1.1.1 补的，
每一条都是「只在构建机以外才看得见」的那类问题。

### 一、Claude Code 的登录：用 `security` 读，只读不写（1.5.0 整节重写）

**一条规则：读 Claude Code 的登录，用 Claude Code 自己用的那条命令，而且从不写它。**
`ClaudeCredentialStore` 跑的是

    /usr/bin/security find-generic-password -a <账户> -s "Claude Code-credentials" -w

Claude Code 用 `security` 工具创建这条记录，所以记录的分区列表里有 `apple-tool:`、访问列表里有
`/usr/bin/security` —— **这个工具读它不弹框，与是谁启动了工具无关**（分区检查看的是发起访问的那个进程的签名）。
进程内的 `SecItemCopyMatching` 是另一个读者：它以本 app 的身份去问，而本 app 只有在有人点过「始终允许」之后
才在列表上，下一次 `claude auth login` 重建记录又会把它清掉。1.0.10–1.4.0 走的正是这条路，所以当时需要
「改用钥匙串授权」按钮，而且每次重新登录之后都要再按一次。1.5.0 删掉了那个按钮和它背后的一切。

**那 1.0.9 fork 同一个工具，为什么每轮都弹框？** 已知的是：那时这个 app 自己也在写这条记录（续期后写回），
而 Lee 看到过 Claude Code 自己读登录时弹框。推断是别的程序写过之后，记录不再认这个工具。**这个推断没有逐一复现**，
而且 2026-09-15 有一个反例：1.4.0 在 14:27 写过之后，`security` 读取依然静默 —— 所以不是每次写都会触发。
但不写，就不可能是我们触发的。**写已经删掉了**：`ClaudeCredentialStore.IO` 没有任何会改动东西的成员
（结构测试用 `Mirror` 盯着），整个 app 只有这一个文件运行 `security`，而且只用 `find-generic-password` 一个动词。

其余的进程内钥匙串读取（Cursor / gh / Antigravity 的条目，以及 Claude 那条记录的**属性**）照旧两道 UI 闸都关 ——
一个条目有两道互不相干的闸：

| 闸 | 管什么 | 用什么关 |
|---|---|---|
| LocalAuthentication | 带 `SecAccessControl` 的条目（Touch ID、密码） | `kSecUseAuthenticationContext` + `LAContext.interactionNotAllowed` |
| 经典 ACL | `login.keychain` 上的普通条目 | **只有** `SecKeychainSetUserInteractionAllowed(false)` |

`Credentials.quietRead` / `quietAttributes` 同时关两道。别的工具的条目是它们在自己进程里建的，`security` 读它们
**会**弹框（1.0.9 在设置页上每次打开都弹）—— 所以走工具的只有 Claude Code 这一条。

**万一还是弹了**（钥匙串被锁，或者记录还带着旧版本写过的痕迹），三道保险，都在 `ClaudeProvider.candidates`：

- **定时器的读取只等 5 秒**（`timerPatience`），失败就记下来（`claudeUnreadable*`，存 defaults，跨重启）。
  **在记录的修改时间变化之前、或者退避到期之前，定时器不再运行工具。** 退避 15 分钟起，同一条记录每再失败一次翻倍，
  封顶 4 小时；修改时间一变（Claude Code 写过了）立刻重试。慢的 securityd 和没人答的弹框从这里看一模一样，
  所以是退避而不是永久停：前者不该让额度停一天，后者不该按时间表回来。
- **人按「刷新」是唯一的例外**（面板的刷新按钮、菜单的「立即刷新」→ `asked: true`）：越过退避，读取等 60 秒
  （`personPatience`），够人点到「始终允许」。定时器那次读取还在途时人按了刷新，会等它结束、再自己读一次，
  不拿定时器那份失败交差（`windows(force:asked:)`）。
- **有手动令牌时它顶上**，但失败照样记录，不因为读数恢复了就去重跑工具。

**不必每轮起一个进程。** 记录的修改时间是属性，读属性不需要授权、也不会弹框。修改时间没变、上次读取不到 5 分钟，
就沿用上次读到的内容（`lastRead`）；5 分钟上限是为了盖住「同一秒内又被写了一次」—— 一秒粒度的时间戳看不见它。
收到 401 时绕过这份缓存重读一次。

诊断：`--credprobe` 打印记录的修改时间、读取成败与耗时，从不打印值。**走的是 `security` 工具，记录检查的是工具的签名，
所以从哪个构建跑结论都一样** —— 以前「必须在真签名 bundle 里跑」的限制随进程内读取一起没了。

`Providers/ClaudeCredentialStore.swift`、`Providers/ClaudeProvider.swift`、`Providers/Credentials.swift`。

### 二、令牌不再由我们续期（1.5.0；想加回来之前请读完整节）

1.0.1–1.4.0 这个 app 自己续期：到期前几分钟拿记录里的 refresh token 去换，再 compare-and-swap 写回同一条记录。
**1.5.0 把这一整套删了** —— `persist`、`storable`、`rotate`、`exchange`、`rotations`、`claudeRotationBlockedUntil`、
`ClaudeUsageClient.refresh`，连同守着它们的八条不变量和各自的测试。

删的理由是两个代价，都不能靠更小心来消除：

1. **续期只对存得下替代品的一方是安全的。** 换发让服务端作废旧 refresh token，替代品的唯一一份在响应里。
   2026-09-08，一台机器上三次写回失败（当时的 CAS 回读还在 fork `security`，弹框没人答），三个替代品全丢，
   那台机器上 CLI 共享的登录只能用 `claude auth login` 重建。1.1.0 加的「先证明存得下，再花掉令牌」缩小了窗口，
   但证明和写回之间永远有一道缝。
2. **写会改动别人的记录**，而 Claude Code 自己读登录时弹框，正出现在这个 app 写它的那段时间（机制一）。
   不写，这条记录就只有 Claude Code 用 `security` 写，两边用同一个分区读。

**代价，而且面板必须说出来：** Claude Code 很久没用、令牌过期时，额度停住。面板显示
「Claude Code 的登录已于 … 过期 —— 打开 Claude Code 即可恢复」，旁边一个「打开 Claude Code」按钮
（`ClaudeLogin.openClaudeCode()`，在终端里运行 `claude`）。Claude Code 续期并写回之后，下一次读取
（修改时间变了，所以立刻）就恢复，不需要再按任何东西。

现在的形状（`ClaudeProvider.probe`）：

- 令牌没过期就用，**离过期多近都不续**；过期了直接 `.expired(到期时间)`，不发请求。
- 有手动令牌时，过期的 CLI 登录让位给它。
- **401 不再是续期的信号，而是重读的信号**：绕过缓存重读一次，记录变了（Claude Code 刚续过）就换新令牌再问，没变就是 `.unauthorized`。

**这个方案的前提已经看见了（2026-09-16）：Claude Code CLI 续期之后，会把新令牌写回这条记录。**
本机当天 14:36:15 令牌过期，面板进入「已过期」；跑一次真正的对话（`claude -p 'Say OK.'`）之后，记录的修改时间
从 `20260915203615Z` 跳到 `20260916044110Z`（本地 14:41:10），面板随即恢复。
**`claude auth status` 不算**：退出码 0，但没有续期、也没有写记录 —— 会写的是真的用一次。
在这之前所有能观察到的写入都是我们自己做的（1.4.0 的 `claudeRefreshAt` 和记录的修改时间逐秒一致）。

验证方法留着，因为 CLI 的行为将来可能变：

    "/Applications/PWE AI Bar.app/Contents/MacOS/PWEAIBar" --credentials

看「登录最近写入」和「登录到期」。现在除了 Claude Code 没有别人写这条记录，**如果哪天用过 CLI、令牌已过期、
修改时间却不动，这个方案就需要重新审视** —— 那说明额度会一直停着。

守着这两节的测试（`ClaudeUsageTests`、`ReadOnlyLoginTests`）：
`testANearlyExpiredLoginIsReadNotRenewed`、`testAnExpiredLoginStopsAndPointsAtClaudeCode`、
`testOnceClaudeCodeRenewsTheNextReadRecovers`、`testA401ReReadsTheLoginInsteadOfRenewingIt`、
`testTheLoginIsReadThroughTheSecurityToolAndOnlyRead`、`testAFileDoesNotHideARefusedRecord`、
`testATimerDoesNotRetryAReadThatFailed`、`testAPersonAskingRetriesAndWaitsForAnAnswer`、
`testAPersonAskingDuringATimerReadGetsAReadOfTheirOwn`、`testAnUnchangedRecordIsNotReadAgain`，
以及结构测试 `testOnlyTheCredentialStoreRunsTheSecurityTool`、`testNothingCanWriteOrRenewClaudeCodesLogin`。
退避、文件不吞拒绝、人按刷新自己读、人按刷新等 60 秒、401 重读、修改时间缓存 —— 这六道各自撤掉之后对应测试都失败过
（2026-09-15 验过），恢复后全绿。

**不要把续期加回来**，除非同时解决「替代品存不下」和「写会改动别人的记录」—— 前者在不写的前提下无解。

`Providers/ClaudeProvider.swift`、`Providers/ClaudeUsageClient.swift`（只剩一个只读端点）、`App/ClaudeLogin.swift`。

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
矛盾的页面。现在区间对整页生效。代价是磁盘缓存格式升到 v3（v2 会被丢弃重建；2026-09-23 为消息去重又升到 v5），
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
   而那是一条比写它的那次运行活得更久的法证记录——事后没法翻译。（这条记录 1.5.0 随续期一起删了；规矩留着。）

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

另一半是事件驱动：一个回合落地后 25 秒问一次，去抖 90 秒（`Store.scheduleSettle`）。钩子事件本身
2026-09-23 起由 `DirectoryWatch` 盯 spool 目录即时读取，10 秒一次的定时器只是兜底和时钟。
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
swift test --scratch-path "$TMPDIR/pweaibar-spm"   # 212 个
./scripts/build-app.sh          # 组装、签名，并跑 --selfcheck 闸门
```

**编译产物不能留在 iCloud 里**（2026-09-16，Swift 6.4）。构建现在会给资源包签名，而 codesign 拒绝任何带着
iCloud 文件提供者反复盖上的 `com.apple.FinderInfo` 的 bundle —— 仓库里的 `.build` 会让 `swift build`
第一步就失败（`CodeSign … PWEAIBar_PWEAIBar.bundle failed`）。`release.sh` 和 `package.sh` 已经把
scratch path 默认指到 `$TMPDIR/pweaibar-spm`；手跑 `swift test` 时自己加 `--scratch-path`。
仓库里的 `.build` 还混着另一台机器的产物（`/Users/leeliu/...`），那是 iCloud 同步来的，删掉即可。

自检子命令（都不打印令牌、账号或服务器正文）：

| 命令 | 用途 |
|---|---|
| `--credentials` | 走 app 的同一条路径只读查询额度（以「人按刷新」的身份，钥匙串问了会等人答），并打印登录最近写入与到期时间 —— 机制二的验证方法。`--credentials-read-only` 是它的别名 |
| `--endurance <dir>` | 续航仪 14 个敌意状态 × 明暗两套，渲染成 PNG |
| `--panel <dir>` | 三种密度 × 明暗，真实数据 |
| `--probe` | 全链路 |
| `--version` | 打印版本号，和设置页页脚读同一处 |
| `--selfcheck` | 从 .app 内部证明每项资源都在 .app 内部；`build-app.sh` 拿它当出包闸门（机制七） |
| `--credprobe` | 用 `security` 读一次 Claude Code 的登录，打印修改时间、成败与耗时，从不打印值（机制一） |
| `PWEBAR_DEBUG=1` | 每次菜单栏重绘打一行。判断「是不是画得太频繁」，这个计数器比 profiler 快得多（机制九） |

**注意**：`--panel`、`--stress`、`--probe` 会各起一个完整的 `Store`，也就是**一次真实的网络请求**，
并且会写共享的 `~/Library/Caches/PWE AI Bar/history.json`。2026-09-23 起写之前先合并，不再互相覆盖，
但它们的读数仍会进同一份历史。

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

## 2026-09-23 这一轮：参照 Javis603/token-monitor 做的修复（未发版）

对照了 token-monitor（Electron + tokscale，31 个客户端、27 家额度来源）之后，挑出的是**本项目自己的错和慢**，
不是去追它的功能数量。按严重程度：

**会让奖杯页数字出错的三条**

1. **Claude 日志按行计数，不按消息计数。** Claude Code 把一条回复按内容块（thinking / text / 每个 tool_use）
   写成多行，每行重复同一个 `message.id` 和同一份 `usage`；恢复的会话还会把旧消息带进新文件。以前每行都算一个回合，
   回合数、token 和等效成本都会被放大。现在 `Transcript.digest` 以 `message.id + requestId` 去重（ccusage 用的同一对键）：
   同一遍解析里的多行取各字段最大值（流式中途写下的行 `output_tokens` 不完整），跨文件、跨增量解析用 `claims`
   （消息键 → 计入它的文件）挡住重复。没有 `message.id` 的行照旧逐行计。磁盘缓存升到 **v5**，旧缓存丢弃重建。
   - 键是 52 位 FNV-1a（`Transcript.messageKey`），要进 JSON 缓存，`hashValue` 每次启动换种子不能用。
   - **代价**：被复制进新文件的旧消息只记在先被读到的那个文件上。原文件被 Claude Code 清理掉之后，这些回合会从总数里消失——
     和原来「原文件删了它的回合就没了」是同一种丢失，只是换了个文件承担。
2. **价格表只认完全相同的模型名。** 快照 id 带日期（`claude-haiku-4-5-20251001`）、Vertex 用 `@`、上下文变体带 `[1m]`、
   3.x 代把家族名放在版本号后面（`claude-3-5-haiku-…`），以前全部按 0 计。`Pricing.canonical` 只剥掉**不可能改变模型**的装饰；
   **故意不做前缀匹配**——`claude-opus-5` 是 `claude-opus-5-5` 的前缀，价格却不同，前缀匹配会把新模型悄悄算成旧价。
   桶也按规范名归并，奖杯页不会同一个模型出两行。表里补了 **`claude-opus-5-5`：$4 / $20，缓存读 $0.20（0.05×）**。
3. **「移除钩子」按钮不存在。** cask 的注释一直说「设置 ▸ 会话事件可以移除」，代码里只有安装。现在有
   `HookProvider.uninstall`：和安装同样的护栏（软链接拒绝、先备份原字节、写之前原文件变了就放弃），
   只删 `install` 加进去的三条，清空了的 matcher 和事件一并删掉，用户自己的钩子原样保留。设置页多了「移除」按钮。

**慢的地方**

4. **每轮都列一遍两棵日志树。** 活跃时每 20 秒 `enumerator` + 每个文件一次 `stat`。现在 `TreeWatcher` 用 FSEvents
   收集变化的路径，下一轮只 `stat` 这些文件；什么都没变就直接复用上一轮合并好的桶。**它从不需要是对的才安全**：
   流没起来、内核丢了事件、根目录被移动、不在 macOS 上，一律返回 `.unknown`，退回原来的全量列举；另外每 15 分钟
   无条件全量一次，兜住启动后才出现的目录。日志根目录解析了软链接——FSEvents 报的是真实路径，
   `~/.claude` 如果是 dotfiles 仓库链进来的，不解析就会同一个文件两个键、算两遍。
5. **ISO8601 解析每行新建两个格式化器。** 冷扫的热点。改成两个静态实例（`ISO8601DateFormatter` 文档说明线程安全）。
   界面里的 `HH:mm` 也统一到 `Forecast.clock`，用 `autoupdatingCurrent` 的时区——一个活到进程结束的格式化器
   否则会一直用创建时的时区。
6. **钩子事件每秒列一次目录。** 现在 `DirectoryWatch`（kqueue）盯着 spool 目录，事件一落地就读；
   定时器降为 10 秒一次的兜底（目录要等第一个事件才出现，以及基于时钟的提醒要有节拍）。注入了读取器的测试
   没有 spool 可盯，仍是轮询。读的途中又来的变化会在读完后补读一次，不会丢到下一拍。
7. **Codex app-server 失败后每轮都重启。** 退避以前只在「从没成功过」时生效；成功一次之后，服务一旦开始失败，
   每轮 20 秒就重新拉起一个进程、每次最多等 12 秒。现在每次失败都计数，等待 1 → 2 → 4 → … 最多 15 分钟，失败期间继续显示
   上一次的读数（照旧标成陈旧）。交换过程里也不再每 50 ms 把整个输出缓冲区重新解析一遍，只解析新到的完整行；
   末尾没有换行的最后一个回复也算回复。
8. **429 没有 `Retry-After` 时永远等 5 分钟。** 现在连续被拒按 5 / 10 / 20 / 40 分钟加倍（`quotaRateLimitStreak`，
   跨启动保留，成功一次清零）；服务器给了 `Retry-After` 就照它的。

**小问题**

9. **倒计时不走。** 面板和菜单栏的倒计时只在快照到达时重算，闲着的时候十五分钟才一次。`Store.clock` 每分钟发布一次，
   面板因此重绘，菜单栏也跟着 `onSnapshot` 走一遍（`PaintedState` 照旧挡掉没变的重绘）。
10. **钩子依赖 `/usr/bin/python3`。** 没装 Command Line Tools 的 Mac 上那是个弹安装框的桩，钩子静默什么都不记。
    脚本现在先用 `xcode-select -p`（不弹框）确认有真的 Python，没有就走纯 shell：把 `session_id` / `cwd` / `message`
    作为 JSON 字符串原样（连转义）搬进记录，不解码；超过 4096 字符的字段留空而不是截断（截断可能切断一个转义）。
    非 JSON 对象的输入不算事件，和 Python 路径一致。`PWEBAR_NO_PYTHON=1` 可以强制走这条路径。
11. **Bark 推送收不到内容。** 设置里写着「ntfy / Bark URL」，但发的是纯文本 POST，Bark 要 JSON。现在 `api.day.app`
    或路径以 `/bark` 开头的地址发 JSON（`title` / `body` / `group`，紧急的加 `level: timeSensitive`），其余照旧。
    只接受 http(s)。**自建 Bark 如果路径不带 `/bark`，仍会按 ntfy 发**——识别是启发式的。
12. **按天分桶用的是今天的时区偏移。** 夏令时切换或出差之后历史会错一天。现在每个回合用它自己那天的偏移，
    日标签按 UTC 格式化（天号本身就是本地日期），时区标识进了缓存戳，换时区会整体重建。
13. **上下文百分比会被子代理的回合抢走。** `isSidechain` 的回合仍计入总数，但不再当「最新回合」。
14. **周窗口的采样环太小。** 50 个样本、每分钟一个，只覆盖 50 分钟，而周窗口的测速跨度最长 42 小时，所以几乎总是退回
    整窗平均。现在最小间隔按窗口长度的千分之一放宽（周窗口约 10 分钟），上限 300 个（五小时窗口约 4.6 小时、周窗口约 50 小时）。
15. **history.json 双写者**（原「已知风险」里那条）。`History.flush` 写之前先读回磁盘上的版本合并：按时间取并集，
    同一时刻以自己的为准，最后一次读数下跌（=重置）之前的都丢掉，不把两个窗口拼在一起。
16. **登录时启动的开关只反映意图。** 注册失败（不在 /Applications 里跑、或在系统设置里被移除）时开关仍显示「开」。
    现在注册之后、以及设置页出现时，都按 `SMAppService.mainApp.status` 回写开关；等待用户批准算「开」。

**刻意没做的**：`Transcript.lastRateLimit()` 和 `ClaudeProvider.init(fallback:)` 仍然没接上。它读的 `quotaLimits` 字段
在这一轮里没有真实日志可以核对，接上等于让一个没验证过的数字出现在额度行里。要接的话先在本机日志里确认字段形状。

**新增 CI**：`.github/workflows/ci.yml`，macOS 15 上跑 loccheck（并要求 `en.lproj` 没有漂移）、钩子脚本与打包副本一致、
`swift build`、`swift test`。以前只有发版机跑过测试。

**怎么验证的**：这一轮是在 Linux 云端容器里写的，没有 Mac。
- 纯逻辑的部分（Transcript、Pricing、History、HookProvider、Codex 两个文件、Forecast、LineScanner、TreeWatcher 的状态机）
  在 Linux 的 Swift 6.0 上编译，并跑了 `TranscriptTests`、`HookTests`、`HistoryTests`、`ForecastTests`、
  `CodexUsageTests`、`CodexAppServerTests`、`TrophyRangeTests`，72 个全过。钩子脚本两条路径都用真实输入跑过。
- **CI（macOS 15）上 212 个测试全过**，包括只在 macOS 上编译的那些改动，以及 `WatcherRuntimeTests`：在 CI 那台真 Mac 上
  起真的 FSEvents 流和 kqueue，证明两者会触发、FSEvents 常量不会在运行时崩。它还抓到一个真 bug——FSEvents 报 `/private/var/…`、
  `resolvingSymlinksInPath` 却去掉 `/private`，事件对不上全被丢掉——已由 `TreeWatcher` 用 `realpath(3)` 翻译路径修掉。
  剩下只有本机能回答的核对（去重和真实日志、界面），清单见 `MAC_HANDOFF_2026-09-23.md`。
- 去重依赖的日志形状（一条消息多行、每行带 `message.id` 和 `requestId`）来自 ccusage 等工具的公开做法，这一轮**没有拿本机真实
  日志核对**。发版前在本机比一下改前改后的回合数：应该明显下降，且不应该出现某一天变成 0。

---

## 已验证 / 未验证

**已验证**：真实只读查询成功；面板读到 Claude 周窗口、五小时、上下文三行实况；185 个测试通过；
**在构建机以外的 Mac 上装好、打开、进入设置**（1.0.13 起，见机制七）；续航仪 14 个状态明暗两套渲染无溢出；
两轮云端审阅的十二条全部修复，其中六条配了先失败后通过的回归测试。

**1.5.0，2026-09-15，本机**：`security find-generic-password … -w` 退出码 0、25 ms、无弹框；Developer ID 签名的构建
`--credprobe` 13 ms 读到 1 份凭据，`--credentials` 状态「已验证」、3 个窗口、不陈旧。机制一、二的六道保险逐一撤掉，
对应测试各自失败，恢复后全绿。**09-16**：1.4.0 在 06:36 又续期写了一次记录（弹框随之出现，这正是 1.5.0 要去掉的），
换上 1.5.0 之后 14:36 令牌过期、面板进入「已过期」，跑一次 `claude -p` 后 14:41 恢复 —— 整条代价与恢复路径都走过一遍。

**未验证，且要说清楚**：

0. **~~Claude Code CLI 续期后是否写回这条记录~~ —— 2026-09-16 看见了，见机制二。** 令牌过期后跑一次
   `claude -p`，记录的修改时间跟着变、面板自己恢复；`claude auth status` 不会。
1. **被旧版本写过的记录，`security` 读会不会弹框，因机器而异。** 本机被 1.4.0 写过之后读取仍静默；另一台机器没看过。
   弹了的话机制一的退避兜底，面板会让人打开 Claude Code 并选「始终允许」。
2. **~~写回失败那条路径没被真实触发过~~ —— 2026-09-08 触发了三次，代价是一次真实的登出。** 1.5.0 起这条路径不存在了。
3. **另外五家（Cursor、Copilot、Devin、Grok、Antigravity）从未在真实账户上验证过**——
   本机一个都没装。全部只读、全部 `appPresent()` 门控、全部有超时。

---

## 已知风险与待办

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

- **~~写回失败的窗口~~ —— 1.5.0 随续期一起删除。** 旧安装的 defaults 里还留着 `claudeRefreshAt` / `Outcome` /
  `Count`、`claudeRotationBlockedUntil`、`sharedKeychainOptIn`、`keychainRefused`，都不再读取，留着无害。
- **`offActor` 的超时会把一次慢成功报成失败**（定时器 15 秒、人按刷新 75 秒）。超时算一次读取失败，进入机制一的退避，
  所以一次慢的 securityd 可能让额度停 15 分钟；按「刷新」立刻重试。
- **~~history.json 双写者~~ —— 2026-09-23 修**：写之前读回合并，见「这一轮」第 15 条。
- **FSEvents / kqueue 两个监听器**（2026-09-23）在 CI 的真内核上验证过会触发；还没在一台装着真实日志树的 Mac 上长时间跑过。
  都是「失败就退回老路径」的设计；如果它们**报少了**，奖杯页最多晚 15 分钟、等待提醒最多晚 10 秒。
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
               Codex{Provider,AppServer} Extra{Source,Providers} Hook(含 DirectoryWatch)
               Transcript LineScanner TreeWatcher(FSEvents,2026-09-23)
  App/         PanelView EnduranceView SettingsView StatusIcon(含 PaintedState,机制九)
               UsageChart TrophyView ProviderMark{,View} NotchWindow
               WindowSizing(NSWindow.setContentHeight,机制八)
  Brand/       Theme WingGauge BrandMark        Resources/  字体、图标、pricing.json
.github/workflows/ci.yml        macOS 上的 loccheck + build + test（2026-09-23）
docs/
  HANDOFF.md                    这份
  BRIEF_2026-09-23.md           这一轮的一页简报（给本地接手看）
  MAC_HANDOFF_2026-09-23.md     这一轮的真机核对清单
  FORECAST_ENGINE_SPEC_2026-09-06.md            预报引擎规格（§9 是对抗审查结论）
  AI_USAGE_MENUBAR_RESEARCH_AND_IMPLEMENTATION_2026-09-05.md   为什么不用输密码
  CLAUDE_USAGE_IMPLEMENTATION_RESEARCH_2026-09-07.md   续期方案的调研（1.5.0 起不再续期，留档）
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
