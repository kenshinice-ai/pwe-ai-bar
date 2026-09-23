# 在 Mac 上接手：2026-09-23 这一轮修复

分支 `claude/token-monitor-optimization-iitxj3`，基于 `main` 的 1.5.0，**未发版**。
改了什么、为什么改，见 `HANDOFF.md` 的「2026-09-23 这一轮」。这份只讲**到了 Mac 上要做什么**。

**CI 已绿**（2026-09-23，`macos-15`，提交 `ef64465`）：loccheck、钩子脚本一致、`swift build`、`swift test`
**212 个全过**。其中 `WatcherRuntimeTests` 在 CI 那台真 Mac 上起了**真的** FSEvents 流和 kqueue：
- FSEvents 不崩（`kFSEventStreamEventIdSinceNow` 的转换没问题），写一个文件能在几秒内被报上来；
- spool 目录里 rename 进一个文件，kqueue 立刻触发。
- **它还抓到一个真 bug，已修**：FSEvents 报 `/private/var/…`，而 `resolvingSymlinksInPath` 会去掉 `/private`，
  两边对不上，事件全被丢掉。普通 `/Users/…` 家目录不受影响，日志树从别处链进来就会中招。`TreeWatcher` 现在用
  `realpath(3)` 把报上来的路径翻译回调用方的写法。

**所以到了 Mac 上不用修编译，监听器本身也已被证明会触发。** 剩下的是只有你的机器能回答的：
去重的前提和你的真实日志是否相符，以及界面上看起来对不对。

```bash
git fetch origin && git checkout claude/token-monitor-optimization-iitxj3
swift test --scratch-path "$TMPDIR/pweaibar-spm"     # 212 个，应与 CI 一致
./scripts/build-app.sh
```

---

## 1. 在真机上看

以下这些，测试和 CI 都证明不了：

1. **奖杯页数字应该下降，不是归零。** 先在 `main` 上截一张奖杯页（全部时间范围），记下回合数和等效成本。
   换到这个分支后删掉 `~/Library/Caches/PWE AI Bar/transcript-cache.json`（反正版本号变了会自动重建），再看一次。
   - 回合数应**明显减少**：一条消息原来被按内容块数重复计算。
   - 按模型那一栏里，原来带日期的 id（如 `…-20251001`）应合并到表名下面，并且有价格。
   - **有哪一天变成 0，或者总数几乎没变**：说明去重的前提不对。拿一个 `~/.claude/projects/**/*.jsonl` 看 assistant 行
     有没有 `message.id` 和 `requestId`，同一 id 是不是真的多行。规则在 `Transcript.digest`，测试在 `TranscriptTests`。
2. **FSEvents 在你的日志树上生效了没有**（内核层面 CI 已证明，这里看的是和 `~/.claude/projects` 的实际路径接不接得上）。开着 app 用 Claude Code 干活，奖杯页和 24 小时图应在 20–40 秒内跟上。
   如果要等到 15 分钟那次全量列举才动，就是 `TreeWatcher` 没报事件，`drain()` 一直在返回 `.quiet`。
   在 `Transcript.refresh` 里临时打印 `change` 就能看出来。
3. **等待提醒是否即时。** 装好钩子，让 Claude Code 弹出一次权限请求，菜单栏应在约 1 秒内出现「● Claude waiting」。
   如果要等将近 10 秒，就是 `DirectoryWatch` 没起作用，走的是兜底定时器。注意：`~/.cache/pwe-ai-bar/events` 要等**第一个事件**
   才会被建出来，所以第一次的延迟可能是 10 秒，之后应该是即时的。
4. **设置 ▸ 会话事件 ▸ 移除。** 点一下，`~/.claude/settings.json` 里我们的三条应被删除，你自己的钩子要原样保留，
   同目录下多出一个 `settings.json.pwe-backup-…`。
5. **钩子脚本不走 Python 的那条路径**：`PWEBAR_NO_PYTHON=1` 下跑一次 `HookTests.testTheShellFallbackWritesRecordsTheReaderAccepts`，
   或者手动执行：
   `echo '{"session_id":"s","message":"hi"}' | PWEBAR_NO_PYTHON=1 PWEBAR_EVENT_DIR=/tmp/x bash hooks/pwe-ai-bar-hook.sh waiting`，
   然后看 `/tmp/x/events/*.json`。BSD `sed` 与 GNU `sed` 在 `-E` 上的差别只在 Linux 上验证过 GNU 那一边。
6. **倒计时每分钟走一次**：打开面板放着不动，看重置倒计时有没有变化。
7. **登录时启动**：在「系统设置 ▸ 通用 ▸ 登录项」里手动移除本 app，再打开本 app 的设置，开关应该变成关。
8. 跑一次 `--endurance` / `--panel`，用眼睛看一遍。历史采样环的上限从 50 改到了 300，但续航仪的画法没动。

---

## 2. 不对劲时怎么退

每一条都能单独撤，彼此之间没有硬依赖：

- 监听器出问题：`Transcript.refresh` 里把 `watcher` 设为 `nil`，就退回每轮全量列举（即 1.5.0 的行为）；
  `Store` 里不调 `watchSpool()` 并把 `eventInterval` 默认值改回 1，就退回每秒轮询。
- 去重出问题：`digest` 的 `counted:` 传 `{ _ in false }`，同时把 `messageKey` 改成对每行都返回不同的值，
  就退回按行计数。缓存版本号记得再加一。
- 这几个提交可以分开 revert：`3ba07ab` 计数 / 定价 / FSEvents，`4b448d4` 钩子 / spool / 倒计时 / 登录项，
  `bc2069b` 退避 / 历史 / Bark / 格式化器，`5b1852d` CI 与文档，`7be03ad` 两处测试字面量，`5f29e58` + `ef64465` 真内核上的监听器测试与路径翻译。

---

## 3. 刻意没做、留给你判断的

- `Transcript.lastRateLimit()` 与 `ClaudeProvider.init(fallback:)` 仍然没接上。本机日志里要是真有 `quotaLimits.resetsAt`，
  可以把它接成「额度端点读不到时的重置时间」；这一轮没有真实日志可以核对，所以没接。
- 自建 Bark 如果路径不以 `/bark` 开头，仍会按 ntfy 的格式发送。要不要在设置里加一个显式的「类型」选项，由你决定。
- CI 用的是 `macos-15`，Swift 比本机的 6.4 旧。以后如果在代码里用了更新的语言特性，CI 会先挂在
  `swift build` 上；那时把 runner 换成带更新 Xcode 的镜像，不要为了迁就 CI 去改代码。

---

## 4. 本机核对结果（2026-09-24）

这台 Mac：macOS 27.0、Swift 6.4。在 `$TMPDIR` 的临时 worktree 里跑的，没有动主工作区；核对完才快进合并到 `main`。

| 清单 | 核对 | 结果 |
|---|---|---|
| 1 | 去重的前提 | **成立**。497 个日志文件里，同一个 `(message.id, requestId)` 平均占 **2.26 行**（抽查的三个会话 2.07×–2.29×），重复行的 `usage` **逐字段相同**（例：`(2, 495)` 出现三次） |
| 1 | 数字下降而不是归零 | 回合 100,432 → **44,356（−55.8%）**；token 374 亿 → 169 亿（−54.8%）；等价成本 **$30,559.95 → $12,446.96（−59.3%）**。54 天里**没有一天变成 0**，单日保留比 17%–60% |
| 1 | 带日期的模型 id | 原来 `claude-opus-5-5` 的 **87 个回合按 $0 计**（`main` 的价格表里没有这一行），现在有价格。归一化之后**没有任何模型再落到 $0** |
| — | `swift test` | **212 个全过、0 失败**（18.6 秒），与 CI 一致。swift-testing 那行「0 tests」是另一个 runner，本项目没有它的用例 |
| — | `scripts/build-app.sh` | 通过，资源四项齐全（pricing.json / 钩子脚本 / 两套 .lproj） |
| 5 | 钩子不走 Python 的那条路径 | 两条路径产出等价记录：shell 写 `"at":1790205450`，Python 写 `"at":1790205451.013551`，其余字段一致 |
| 2 | `TreeWatcher` 接不接得上真实日志树 | **接得上**。把它单独接到 `~/.claude/projects` + `~/.codex/sessions` 跑 45 秒：首次 `drain()` 按设计 `.unknown`，之后每 3 秒都报到正在写的会话文件，共 **24 个路径事件**，路径拼写与调用方一致（没有 `/private` 错位） |

**改前改后那两个数是复算的，不是 app 自己打印的** —— 奖杯页没有 CLI 出口，所以按两版各自的语义和各自的
`pricing.json` 在真实日志上重算了一遍：`main` 按行计数 + 只认完全相同的模型名，分支按
`(message.id, requestId)` 取各字段最大值 + `Pricing.canonical`。口径限于 Claude 的日志树（Codex 那棵不受这次去重影响）。

**仍然只有你能做的（要界面）：** 清单第 3、4、6、7 条 —— 等待提醒是否约 1 秒（要真的弹一次权限请求）、
设置里点「移除」后 `~/.claude/settings.json` 的实际变化（**没有替你点**，那是改你自己的配置）、
倒计时每分钟走一次、以及在系统设置里移除登录项后开关是否跟着变。再就是拿真实数据看一眼奖杯页。
