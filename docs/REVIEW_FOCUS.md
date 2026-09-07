# 这一轮深度审阅要看什么

> 这份文件是审阅脚手架，不是产品文档。审阅结束后连同 `review/*` 分支一起删掉。

这条分支的存在只有一个目的：**把仅有的一次深度审阅花在整个项目里唯一能损坏应用之外的东西的代码上。**

## 为什么是这一块

这个仓库里其他部分最坏的失败是「面板上显示了一个错的数字」。这一块最坏的失败是
**把用户的 Claude Code 登录弄坏**——它读取、刷新并**写回**用户真实的 OAuth 凭据，
落点是钥匙串条目 `Claude Code-credentials` 或 `~/.claude/.credentials.json`，而这两个位置
都不是我们的，是 Claude Code CLI 的。

而且它是这个项目里**唯一没有被独立审阅过**的部分：

| 部分 | 已受到的审查 |
|---|---|
| 预报引擎 | 3 个独立设计 agent + 2 轮对抗攻击 + 12 万次 fuzz + 两轮我自己的修 |
| 面板 UI | 我自己的多轮 + 逐状态渲染核对 |
| **这一块** | **只有行为验收：测试通过、真实只读查询成功、面板读到数** |

行为验收回答的是「它现在能用吗」，不是「它在什么情况下会把事情搞坏」。逐行没人看过。
它也不是我写的——由另一个 agent（Codex/Astra）实现，我做的是验收。

## 这条 diff 是什么

这条分支相对 `main`（`ca4f021`）是一条直线，包含：

1. **`Claude 额度自己续期`** — 新增 `ClaudeCredentialStore`（发现、解码、比对、写回）、
   `ClaudeUsageClient`（HTTP 契约）、`ClaudeUsageMapper`（纯映射），重写 `ClaudeProvider` 状态机。
2. **`额度越紧打得越狠，这个逻辑是反的`** — TTL 与轮询节奏，加上续期遥测。

外加一个把合成截图从 diff 里拿掉的提交。

前面还有 `预报引擎重做成一个纯函数` 和 `删掉一个没人用的颜色` 两个提交也在这条 diff 里——
那是本地 `main` 的位置决定的，不是审阅目标。预报引擎已经被 3 个设计 agent、2 轮对抗攻击
和 12 万次 fuzz 过过一遍了，**请把力气放在凭据那两个提交上**。

## 威胁模型 / 请重点看这些

**1. 写回把别人的记录写坏。**
`ClaudeCredentialStore.rotated` 刻意在原 JSON 上改字段而不是用 Codable 重新编码，
因为那条记录不只属于我们，未知字段必须逐字保留。请确认：嵌套 / 非嵌套两种形状、
hex 编码回退、`scopes` 为 null 或类型不对、`expiresAt` 为字符串或越界——有没有哪条路径
会产出一个 Claude Code 读不回去的文档。

**2. refresh token 轮换的窗口。**
`ClaudeProvider.rotate` 的顺序是：换 → `rotated()` → 再比一次 → `persist`。
如果服务端轮换了 refresh token 而 `persist` 失败，CLI 手里那份可能已经作废。
我们的处理是记录并停止对同一凭据重试。**这个窗口关不上**——请判断它是否被缩到了最小，
以及有没有比「记一笔」更好的补救。

**3. compare-and-swap 是真的吗。**
`save(_:expected:)` 靠 `unchanged(expected)` 再读一次比对。这是 TOCTOU：读和写之间
CLI 仍然可能插进来。请评估这个窗口的实际风险，以及 `SecItemUpdate` 的精确 query
是否可能匹配到不止一条记录。

**4. 身份串用。**
多个候选来源（钥匙串 / 文件 / 手动令牌）时，`sameIdentity` 用 account uuid + org uuid
的指纹决定能不能回退到下一个候选。请确认不存在「A 账号的额度显示成 B 账号」的路径，
包括 uuid 缺失、只有其中一个、以及换账号之后旧缓存的世代隔离（`observationNamespace`）。

**5. 文件写回的安全性。**
0600、fsync、原子替换、拒绝符号链接——请确认这些是真的按顺序成立的，特别是原子替换
之后权限位是否还在，以及父目录被替换成符号链接的情形。

**6. HTTP 层。**
ephemeral session、关 cookie、拒绝重定向（避免 bearer 被转发）、限响应大小。
`platform.claude.com/v1/oauth/token` 的响应解析对恶意/畸形 body 是否稳。

**7. 节奏与限流。**
TTL 新规则见 `ClaudeProvider.ttl()`；`force` 会绕过 TTL 与网络退避，但**必须**仍然尊重
`retryAfter`。请确认没有任何路径能在被限流期间发出请求，以及 `Retry-After` 的两种格式
（秒数 / HTTP 日期）解析正确、失败时保守退避。

**8. 遥测不能泄密。**
`claudeRefreshAt` / `claudeRefreshOutcome` / `claudeRefreshCount` 三个键，以及
`--credentials` / `--credentials-read-only` 的输出。请确认没有令牌、账号 ID 或服务器正文
会被打印或落盘。

## 已知且不打算改的

- 那个轮换窗口（见 2）。
- `history.json` 有两个写者（app 与自检子命令各起一个 Store），会互相覆盖。
  这一条**不在本 diff 里**，`docs/HANDOFF.md` 有记录。

## 怎么跑

```
swift test                          # 103 个
swift run PWEAIBar --credentials-read-only    # 查询但不轮换令牌
```

背景与设计理由：`docs/HANDOFF.md` 的「三件不显然的机制」第一、二条，以及
`docs/CLAUDE_USAGE_IMPLEMENTATION_RESEARCH_2026-09-07.md`。


