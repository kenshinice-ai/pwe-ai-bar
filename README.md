# PWE AI Bar

**你所有 AI 的额度，收进菜单栏那 22 点。但它的本职是在该你出手的那一刻找到你。**

PWE Studio 菜单栏家族的第四位，接在 Loan Bar、Lumen Bar、MAC MONITOR 之后。

![菜单栏](docs/menubar.png)

```
[翼] ✳ 68% / 88%  ⚛ 额度耗尽  ↻17:18
```

翼形仪表 · Claude 的五小时与周窗口 · Codex 状态 · 距重置倒计时。

---

## 它做什么

**看板部分**（这部分市面上已经有二十几个实现）

- Claude Code 的五小时与周窗口，真实百分比，来自 `/api/oauth/usage`
- Codex 额度，读它自己的会话日志，零凭据
- 当前会话上下文占用
- 战绩页：按 API 目录价折算的等效成本、回本倍数、模型与日期分布

**哨兵部分**（这部分没人做）

- **额度重置了** —— 到点主动告诉你可以继续干活
- **Claude 在等你回话** —— 权限确认卡住时，菜单栏让位、通知弹出
- **离座推手机** —— 超过五分钟没碰键盘，提醒转发到 ntfy / Bark
- 阈值预警用服务端自己的 `severity`，不是我们瞎定的数字

## 设计要点

**翼即仪表。** 五根羽毛就是五条通道，颜色沿羽毛走多远＝离出事多远。
房屋标准 §7.1「衍生仪表例外」已经写过这条：*标识可以作为仪表运动，不可作为识别运动*。
渲染器与 PWE MAC MONITOR 共用，零修改搬运。

**菜单栏一色，面板五色。** 22 点高的栏里每根羽毛约 1 点粗，五种色调糊成一片。

**菜单栏永远静止。** 只在读数变化时重画。动效全部关在战绩页，点开跑一次就停。

**密度可选。** 菜单栏三档（图标／紧凑／完整）＋事件抢占，面板三档（精简／标准／完整），
两边互不牵连。出厂给足信息，想安静自己往回调。

**主角会换人。** 面板里那个大数字不是固定窗口，是**当前最紧的那条**，
由接口的 `is_active` 与 strain 共同决定。

**没有百分比就不画进度条。** team 计划的额度耗尽是一个状态，不是一个比例，
画成满格进度条等于假装我们知道一个并不知道的数。它拿虚线。

**长期无解的红不钉死整只翼。** 一个永远 critical、没有重置时间的通道，
只保留自己那根羽毛的颜色，不参与菜单栏的整体判定——一直红的仪表就不是仪表了。

## 装

```bash
./scripts/build-app.sh          # 本机构建（ad-hoc 签名）
open "build/PWE AI Bar.app"
```

首次启动 macOS 会问一次钥匙串权限，选「始终允许」。
没登录过就先 `claude auth login`；不登录会降级成本地日志估算，有总量没有百分比。

会话事件要装 hook：设置 → 会话事件 → 安装。它以合并方式写进
`~/.claude/settings.json`，不覆盖你已有的配置。

## 自检

界面不是调数据源的地方——22 点的图标上，错的数字和对的长得一模一样。

```bash
.build/release/PWEAIBar --probe        # 各数据源实际返回了什么
.build/release/PWEAIBar --icon DIR     # 菜单栏图标，三档 × 明暗，外加 provider 标记
.build/release/PWEAIBar --panel DIR    # 面板，三档 × 明暗，跑真实数据
```

## 发布

**在发布机上做。** Developer ID 私钥在那台，这台只有 Apple Development，
本机产物是 ad-hoc 签名，Gatekeeper 在别的机器上一定拦。

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
├── Core/        Channel · Model · Store · RuleEngine · Notifier · Pricing · Prefs · Probe
├── Providers/   Claude（OAuth，降级本地）· Codex（本地）· Transcript · Hook
└── App/         StatusIcon · PanelView · TrophyView · SettingsView · ProviderMark · NotchWindow
```

自己写的其实只有 `Providers/` 和 `Core/`。品牌层、翼形仪表、菜单栏外壳、打包脚本
都来自家族里已有的产品。

设计方案全文：[docs/design.html](docs/design.html)

---

A Paradise Production · Create trust through clarity
