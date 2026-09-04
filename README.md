# PWE AI Bar

**你所有 AI 的额度，收进菜单栏那 22 点。但它的本职是在该你出手的那一刻找到你。**

PWE Studio 菜单栏家族的第四位，接在 Loan Bar、Lumen Bar、MAC MONITOR 之后。

![菜单栏](docs/menubar.png)

```
[翼] ✳ 68% / 88%   ⚛ 额度耗尽   ↻17:18
```

翼形仪表 · Claude 的五小时与周窗口 · Codex 状态 · 距重置倒计时。

---

## 它做什么

**看板**（这部分市面上已有二十几个实现，我们只是做得合乎自家规范）

- Claude Code 的五小时与周窗口，真实百分比，来自 `/api/oauth/usage`
- Codex 额度，读它自己的会话日志，零凭据
- 当前会话上下文占用
- 战绩页：按 API 目录价折算的等效成本、回本倍数、模型与日期分布

**哨兵**（这部分没人做）

- **额度重置了** —— 到点主动告诉你可以继续干活
- **Claude 在等你回话** —— 权限确认卡住时，菜单栏让位、通知弹出
- **离座推手机** —— 超过五分钟没碰键盘，提醒转发到 ntfy / Bark
- 阈值预警用服务端自己的 `severity`，不是我们瞎定的数字

## 装

```bash
./scripts/build-app.sh
open "build/PWE AI Bar.app"
```

**不会有任何授权弹框。** 首次运行只显示本地估算，面板里给一个「启用」按钮——
真实额度要不要接、什么时候接，由你按下去决定。

会话事件要装 hook：设置 → 会话事件 → 安装。三个钩子，以合并方式写进
`~/.claude/settings.json`，不覆盖你已有的配置：

| 钩子 | 作用 |
|---|---|
| `Notification` | Claude 停下来等你 → 菜单栏让位、通知弹出 |
| `UserPromptSubmit` | 你回复了 → 立刻清掉等待状态，而不是等这一轮结束 |
| `Stop` | 任务完成 → 离座时才提醒 |

`UserPromptSubmit` 不记录任何文本——它的载荷就是你刚敲进去的东西，
而这个事件只需要终结等待状态。

## 额度数据从哪来

钥匙串按「条目 + 代码签名」授权。Claude Code 的凭据条目只信任 `claude` 二进制，
别的程序读它就会弹框；点一次「始终允许」会把该程序的签名写进访问列表，之后静默。
**前提是签名不变**——所以本机构建用固定的 Apple Development 身份，
ad-hoc 每次编译都换身份，每次都算新 app，也就每次都要重问。

两条路，按你能忍受的弹框次数选：

| | 弹框 | 怎么做 |
|---|---|---|
| **长期令牌**（推荐） | 0 次 | `claude setup-token` 拿到令牌，粘进设置，或 `--token` 传入 |
| 共享钥匙串 | 1 次 | 面板点「启用」，在弹框里选「始终允许」 |
| 都不要 | 0 次 | 什么都不做。本地估算有总量和战绩，没有百分比 |

长期令牌存在**本 app 自己创建**的钥匙串条目里。自己的条目自己天然可读，
永不弹框，也不会过期。

```bash
claude setup-token | "build/PWE AI Bar.app/Contents/MacOS/PWEAIBar" --token -
```

被拒绝过会持久记住，不会每次启动重问。想重来：设置 → 额度数据来源 → 授权钥匙串。

## 设计要点

**翼即仪表。** 五根羽毛就是五条通道，颜色沿羽毛走多远＝离出事多远。
房屋标准 §7.1「衍生仪表例外」已经写过这条：*标识可以作为仪表运动，不可作为识别运动*。
渲染器与 PWE MAC MONITOR 共用，零修改搬运。

**菜单栏一色，面板五色。** 22 点高的栏里每根羽毛约 1 点粗，五种色调糊成一片。

**菜单栏永远静止。** 只在读数变化时重画。

**动效不碰几何和数值。** 数字从零涨上来很好看，但任何动画没跑完的时刻，页面就在说谎——
离屏渲染、刚打开的一瞬、隐藏状态下重建的视图，都会显示「$0.00」。
把动画挪到柱高只是换个地方犯同样的错。现在只留一个谁都不会误读的入场缩放。

**密度可选。** 菜单栏三档（图标／紧凑／完整）＋事件抢占，面板三档（精简／标准／完整），
两边互不牵连。出厂给足信息，想安静自己往回调。

**面板不用缩写。** 菜单栏才是空间紧张的地方，那里靠剪影认 provider；
面板是你专程点开来读的，所以是「Claude Code · 周窗口」，不是「CDX 15%」。

**主角会换人。** 大数字不是固定窗口，是**当前最紧的那条**，
由接口的 `is_active` 与 strain 共同决定。

**没有百分比就不画进度条。** team 计划的额度耗尽是一个状态，不是一个比例。它拿虚线。

**长期无解的红不进仪表。** 一个永远 critical、没有重置时间的通道不参与菜单栏配色，
也不当面板头条——一直红的仪表就不是仪表了。它在面板里仍然独占一行。

**Claude 和 Codex 的读数不是一回事。** Claude 来自实时接口且自带 `severity`；
Codex 来自会话日志，有多旧取决于它上次运行，而且只有裸百分比、分级是我们判的。
所以面板会标「9 小时前读到」。

**百分比只有一种口径。** Codex 自己的界面写「Usage remaining 84%」，
Claude 的接口给的是 `utilization`——同一个窗口的两头，两个数看着像两回事。
统一，可切换，默认剩余：那才是你真正在问的问题，也是一条会排空的进度条不用标签就能读懂的原因。
翼形仪表不跟着翻面——羽毛长度是离出事有多远，翻了就会跟旁边的数字打架。

## 三家为什么不一样

| | 要授权吗 | 为什么 |
|---|---|---|
| **Codex** | 不要 | 它把 `rate_limits` 明文写进自己的会话日志。我们只是读一个已经在磁盘上的文件 |
| **Claude Code** | 要 | transcript 里 `rateLimits` 字段留着但**从不填**（57 处全是 null），全盘搜 `utilization` / `resets_at` 零命中。唯一来源是 API，API 要 token |
| **Gemini** | 读不到 | 桌面版 `com.google.GeminiMacOS` 只有 settings 数据库，没有任何额度字段。CLI 有 `gemini_cli.token.usage`，那是 **token 计数不是额度**，而且遥测要手动开 |

不是我们对三家用了三种办法，是三家各自决定了往本地写什么。

## 自检

界面不是调数据源的地方——22 点的图标上，错的数字和对的长得一模一样。
两块最容易烂掉的界面都在两次点击之外，所以也一并渲染出来。

```bash
BIN="build/PWE AI Bar.app/Contents/MacOS/PWEAIBar"

"$BIN" --probe        # 各数据源返回了什么、每段耗时、每段内存、朗读文案
"$BIN" --cred         # 令牌从哪来，问一次要不要弹框
"$BIN" --icon DIR     # 菜单栏图标：三档 × 明暗，外加 provider 剪影
"$BIN" --panel DIR    # 面板三档、设置页、战绩页，各两种外观，跑真实数据
"$BIN" --stress DIR   # 用刻意刁难的数据渲染：超长名字、100%、没有比例的状态、七位数
"$BIN" --token -      # 从标准输入存长期令牌
```

真实数据永远是整齐的——两个窗口、短名字、正常数值——所以只见过真实数据的布局
其实从没被测过。`--stress` 第一次跑就抓到三个 bug。

## 性能

菜单栏应用整天在跑，任何开销都要乘以几万次。

| | |
|---|---|
| 真实占用 | **37 MB**（峰值 46 MB） |
| 刷新（冷启动） | 4.0 秒 |
| 刷新（之后） | **0.15 秒** |
| 图标重绘 | 0.43 ms（量化到 5% 步长） |
| 轮询节奏 | 20 秒 → 15 分钟没动静降 5 分钟 → 一小时降 15 分钟 |

会话日志有 159 MB。做到这个数用了五件事：字节级分块扫描而不是 `String.contains`
（Unicode 逐字素比较，几乎全部开销花在拒绝不要的行上）；按文件记住解析到的字节偏移，
只读新增部分（JSONL 只追加，而当前会话那个文件一直在长）；读文件时就地归约成
按模型／按天／按小时的桶，不在内存里留单条记录；只扫尾部找 429 记录
（那一处独占 88 MB）；解析结果落盘，重启不用从头再来。

量的时候注意看 `phys_footprint` 而不是 `ps` 的 RSS——后者把所有 app 共享的框架页也算进来，
在这里差了三倍，我照着它白优化了两轮。

## 发布

**在发布机上做。** Developer ID 私钥在那台，这台只有 Apple Development，
本机产物 Gatekeeper 在别的机器上一定拦。

```bash
./scripts/package.sh --notarize
```

需要先建一次公证凭据：

```bash
xcrun notarytool store-credentials PWE_NOTARY --team-id 2SQV3H5MH9 \
  --apple-id <apple-id> --password <app-specific-password>
```

## 结构

```
Sources/PWEAIBar/
├── Brand/       BrandMark · WingGauge  ← MAC MONITOR，零修改
│                Theme                   ← 品牌色板与字体
├── Core/        Channel · Model · Store · RuleEngine · Notifier
│                Pricing · Prefs · Probe
├── Providers/   Credentials · Claude（OAuth）· Codex（本地）
│                Transcript · Hook
└── App/         StatusIcon · PanelView · TrophyView · SettingsView
                 ProviderMark · UsageChart · WingView · NotchWindow
```

自己写的其实只有 `Providers/` 和 `Core/`。品牌层、翼形仪表、菜单栏外壳、
打包脚本都来自家族里已有的产品。

设计方案全文：[docs/design.html](docs/design.html)

---

A Paradise Production · Create trust through clarity
