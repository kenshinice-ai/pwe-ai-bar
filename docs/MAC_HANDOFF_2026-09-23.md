# 在 Mac 上接手：2026-09-23 这一轮修复

分支 `claude/token-monitor-optimization-iitxj3`，基于 `main` 的 1.5.0，**未发版**。
改了什么、为什么改，见 `HANDOFF.md` 的「2026-09-23 这一轮」。这份只讲**到了 Mac 上要做什么**。

这一轮是在 Linux 云端容器里写的，**没有在 macOS 上编译过**。纯逻辑部分在 Linux 的 Swift 6.0 上
编译过，并跑过 72 个测试，全过。AppKit / FSEvents / kqueue / SMAppService 相关的改动只被读过、没被编译过。
推送时 CI（`.github/workflows/ci.yml`，macOS 15）还在跑，结果没看到。

---

## 1. 先让它编译、测试通过

```bash
git fetch origin && git checkout claude/token-monitor-optimization-iitxj3
swift build --scratch-path "$TMPDIR/pweaibar-spm"
swift test  --scratch-path "$TMPDIR/pweaibar-spm"     # 应为 208 个
swiftc -O Tools/loccheck/main.swift -o /tmp/loccheck && /tmp/loccheck .
```

先看一眼 GitHub Actions 上这个分支的 CI；它失败的话，日志里就是下面这张表里的某一处。

### 最可能编译不过的地方（按风险从高到低）

| 位置 | 为什么有风险 | 如果报错 |
|---|---|---|
| `Providers/TreeWatcher.swift:49-66` | FSEvents 的 C 回调与常量类型全凭记忆写的。`FSEventStreamCreate` 的返回值当成 `FSEventStreamRef?` 用了 `guard let`，`kFSEventStreamEventIdSinceNow` 用 `FSEventStreamEventId(...)` 包了一层，`rawPaths` 走 `Unmanaged<CFArray>.fromOpaque` | 返回值若不是可选，去掉 `guard let` 改成 `let`。常量若导入成 `Int` 且为 -1，改用 `FSEventStreamEventId(bitPattern:)` 或直接写 `0xFFFFFFFFFFFFFFFF`，**这一处会在运行时崩，不会在编译时报**，务必跑一次 app |
| `Providers/HookProvider.swift:304-311`（`DirectoryWatch`） | `open(_, O_EVTONLY)`、`makeFileSystemObjectSource`、`source.data.isDisjoint(with:)` | 按编译器提示改签名，逻辑不用动 |
| `Core/Prefs.swift:228-231`（`syncLoginItem`） | `SMAppService.Status` 的 `.requiresApproval` | 不认的话，只比较 `.enabled` |
| `Core/Notifier.swift:153` | 在 `@MainActor` 类里写了 `nonisolated static func` | 编译器不接受就去掉 `nonisolated`，测试改成 `@MainActor` |
| `Providers/Transcript.swift:220` | actor 方法里把读 `claims` 的非逃逸闭包传给静态函数；Swift 6.0 的 Swift 5 模式下没问题，更新的编译器若报隔离错误 | 先把 `claims` 拷成局部 `let known = claims`，再传 `{ known[$0] != nil }`。同一遍里新增的键 `digest` 自己会挡住，所以结果不变 |
| `App/SettingsView.swift:230` | `switchRow(...).onAppear { prefs.syncLoginItem() }` | 挪到整个 `content` 的 `.onAppear` 上 |

---

## 2. 编译通过之后，在真机上看

以下这些，测试和 CI 都证明不了：

1. **奖杯页数字应该下降，不是归零。** 先在 `main` 上截一张奖杯页（全部时间范围），记下回合数和等效成本。
   换到这个分支后删掉 `~/Library/Caches/PWE AI Bar/transcript-cache.json`（反正版本号变了会自动重建），再看一次。
   - 回合数应**明显减少**：一条消息原来被按内容块数重复计算。
   - 按模型那一栏里，原来带日期的 id（如 `…-20251001`）应合并到表名下面，并且有价格。
   - **有哪一天变成 0，或者总数几乎没变**：说明去重的前提不对。拿一个 `~/.claude/projects/**/*.jsonl` 看 assistant 行
     有没有 `message.id` 和 `requestId`，同一 id 是不是真的多行。规则在 `Transcript.digest`，测试在 `TranscriptTests`。
2. **FSEvents 生效了没有。** 开着 app 用 Claude Code 干活，奖杯页和 24 小时图应在 20–40 秒内跟上。
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

## 3. 不对劲时怎么退

每一条都能单独撤，彼此之间没有硬依赖：

- 监听器出问题：`Transcript.refresh` 里把 `watcher` 设为 `nil`，就退回每轮全量列举（即 1.5.0 的行为）；
  `Store` 里不调 `watchSpool()` 并把 `eventInterval` 默认值改回 1，就退回每秒轮询。
- 去重出问题：`digest` 的 `counted:` 传 `{ _ in false }`，同时把 `messageKey` 改成对每行都返回不同的值，
  就退回按行计数。缓存版本号记得再加一。
- 四个提交之间可以分开 revert：`3ba07ab` 计数 / 定价 / FSEvents，`4b448d4` 钩子 / spool / 倒计时 / 登录项，
  `bc2069b` 退避 / 历史 / Bark / 格式化器，`5b1852d` CI 与文档。

---

## 4. 刻意没做、留给你判断的

- `Transcript.lastRateLimit()` 与 `ClaudeProvider.init(fallback:)` 仍然没接上。本机日志里要是真有 `quotaLimits.resetsAt`，
  可以把它接成「额度端点读不到时的重置时间」；这一轮没有真实日志可以核对，所以没接。
- 自建 Bark 如果路径不以 `/bark` 开头，仍会按 ntfy 的格式发送。要不要在设置里加一个显式的「类型」选项，由你决定。
- CI 用的是 `macos-15`。本机是 Swift 6.4，CI 的 Xcode 16 可能是 Swift 6.0 或 6.1。代码如果用到了更新的语言特性，
  CI 会先挂在 `swift build` 上；那种情况下把 runner 换成有更新 Xcode 的镜像，别去改代码。
