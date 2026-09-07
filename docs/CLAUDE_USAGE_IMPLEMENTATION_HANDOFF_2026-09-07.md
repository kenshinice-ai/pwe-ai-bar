# Claude 额度修复 handoff — 2026-09-07

状态：**实现、完整回归、Release 构建、本机真实只读查询已完成。** 未提交 Git、未部署、未替换 Applications 中的应用。真实 token 到期后的续期/钥匙串写回没有在用户账户上主动触发。

## 1. 目标与基线

按 `CLAUDE_USAGE_IMPLEMENTATION_RESEARCH_2026-09-07.md` 修复 Claude OAuth 在线额度。完成候选、续期、映射、缓存、错误状态和面板；不升级 Claude，不安装 status line bridge，不接管其他工具或预测算法的工作。

基线 HEAD：`4341bfc019792a8983ecee997bfb603220be9744`。

开始时已有 `EnduranceView.swift` 未提交修改，以及 `ZZAdversarialScratch.swift`、`ZZAdversarialScratch2.swift`、`ZZAdversarialScratch3.swift`、`ZZFuzzScratch.swift` 四个未追踪测试。这五个文件前后 SHA-256 相同，逐字节保留。研究文档也原为未追踪文件。

审阅包从当前工作树构建，因此包含用户原有 EnduranceView 改动；不代表本轮重做了预测模块。原有 scratch 测试计入测试总数。

## 2. 产物

- [Release 本机审阅包](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/build/claude-review/PWE AI Bar.app>)。
- [验证摘要](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/validation.txt>)。
- [真实只读结果](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/live-read-only.txt>)。
- [成功浅色](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/claude-live-light.png>)、[成功深色](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/claude-live-dark.png>)。
- [限流浅色](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/claude-stale-light.png>)、[限流深色](</Users/leeliu/Documents/ClaudeProject/PWE AI Bar/docs/claude-usage-verification/2026-09-07/claude-stale-dark.png>)。

四张截图都是合成数据。真实查询只输出状态、来源、窗口数量，不输出令牌、账号或服务器正文。审阅包采用 ad-hoc 签名，并非公证分发包。

## 3. 实际实现

### 凭据和续期

- 新 `ClaudeCredentialStore` 精确定位 service/account 或文件路径，保留完整 JSON、refresh token、scopes、expiry 和套餐。
- 明确缺 `user:profile` 时提示权限问题；元数据未知时由服务端验证。
- 认证失败后，只尝试能够确认同身份的后续候选，不自动串用不同账户。
- 高级手动令牌保存后明确选中该来源，清除或重新连接恢复官方来源；CLI `--token` 与设置页一致。
- 临近到期或 401 时最多续期一次，先重读来源，优先采用 CLI 已更新的令牌。
- 写回前再次比较，保留未知字段。文件采用 0600、fsync、原子替换并拒绝符号链接；钥匙串使用精确 `SecItemUpdate`，不将 token 放进进程参数，不修改 ACL。
- 写回失败或刷新后仍被拒绝，不继续对同一凭据轮换，等待登录来源更新或用户恢复。
- 常规直接 Keychain API 使用禁止交互的 LAContext；显式重新连接才使用授权读取路径。系统工具仍受 macOS ACL 控制，不能承诺每台机器永远零弹窗。

### 网络与映射

- 新 `ClaudeUsageClient`：ephemeral session、关闭 Cookie/URL cache、拒绝重定向、超时和可接受响应大小限制。
- 新 `ClaudeUsageMapper`：纯函数解析五小时、周、`seven_day_*` 和 weekly scoped 独立池，不再将其他模型窗口压成一条。
- 支持数字/数字字符串、ISO-8601、epoch 秒/毫秒；拒绝 Boolean、非有限/越界比例以及矛盾的双结构主窗口。
- Claude 面板保留一位小数；99.5%不当作耗尽，非常接近边界显示 `<0.1%` / `>99.9%`。
- 额外消费用 Decimal 转换分值，单列消费和本期上限，不当作订阅百分比或可退余额。

### 缓存、历史、提醒

- Claude 额度只保留内存，旧版未绑定账户的 `quota-cache.json` 不再读取，也未主动删除。
- 先检查来源世代再用 TTL。世代变化隔离额度、历史与提醒 key；namespace 是哈希，不含明文身份或凭据。
- PWE 自己成功续期时保留历史 namespace；外部来源变化保守隔离。
- 区分成功、尝试和冷却时间；失败不更新成功时间。临时错误保留同来源旧值并标 stale；过 reset 后待确认。
- 认证、存储或来源冲突不把旧余额显示为当前账户。429 支持 Retry-After 两种格式，手动刷新也遵守。

### UI 和集成

- Claude 结果独立发布，不等待 Codex、其他工具或 Transcript 统计。
- 卡片增加刷新/查询中状态、来源、成功时间、旧读数和限流原因，以及套餐/额外消费。
- 手动刷新跳过普通 TTL，保留去重和冷却。发布世代防止停止或更换凭据后旧任务覆盖新状态。
- 保留独立 hook 事件循环。设置、README、诊断不再默认引导 setup-token 或承诺绝不弹框。
- `--credentials` 使用完整查询/续期流程；新 `--credentials-read-only` 禁止续期写回；`--cred` 只显示配置说明。
- 凭据 mock 测试改用独立 UserDefaults suite，不再写真实标记。
- 打包脚本读取 SwiftPM 实际 bin path，并支持独立构建/缓存/输出目录及签名身份。

## 4. 文件索引

| 职责 | 文件 |
| --- | --- |
| 精确发现、完整文档、写回 | `Providers/ClaudeCredentialStore.swift`（新） |
| HTTP 契约 | `Providers/ClaudeUsageClient.swift`（新） |
| 纯映射、消费类型 | `Providers/ClaudeUsageMapper.swift`（新） |
| 状态机 | `Providers/ClaudeProvider.swift` |
| 兼容读取、手动令牌、有界进程 | `Providers/Credentials.swift` |
| 发布与世代 | `Core/Store.swift`、`Model.swift`、`History.swift`、`RuleEngine.swift` |
| UI、格式、诊断 | `App/PanelView.swift`、`SettingsView.swift`、`Core/Readout.swift`、`Probe.swift`、`AppShell.swift`、`Main.swift` |
| 回归 | 新 `ClaudeUsageTests.swift`；更新 CredentialTests、QuotaTests、StoreTests、RenderingTests |
| 文档和打包 | README、此 handoff、`scripts/build-app.sh` |

上表应用代码位于 `Sources/PWEAIBar/`，测试位于 `Tests/PWEAIBarTests/`。

## 5. 已验证事实

| 检查 | 结果 |
| --- | --- |
| 修改前基线 | 106 tests / 0 failures |
| 最终完整回归 | **120 tests / 0 failures**，测试执行约26秒 |
| 最终 Release | **Build complete**，约27秒 |
| 打包/签名 | 审阅包生成；`codesign --verify --deep --strict` exit 0 |
| CLI入口 | 审阅包 `--cred` 成功退出 |
| 本机真实只读查询 | **claudeKeychain，2个有效窗口，旧读数=否，成功获取=是** |
| 视觉 | 检查深浅色成功/限流四张图；小数、套餐、消费和状态可见，无新增内容裁切 |
| 检查 | `git diff --check`、`bash -n scripts/build-app.sh` 通过 |
| 保护已有工作 | EnduranceView 和四个 scratch 文件 SHA-256 不变 |

Release 普通沙盒构建曾被 `dsymutil: Operation not permitted` 阻止；获准在沙盒外完成同一构建后通过，没有忽略源码编译错误。

重要回归：过期前刷新、401续期、CLI中途更新、未知字段保留、写回失败不重复轮换、刷新后401不循环、同账户候选、账户变化令TTL失效、single-flight、手动429冷却、严格日期/数字/冲突解析、文件权限/符号链接拒绝、Claude先于慢Codex发布、hook不被挂起额度请求阻塞。

旧的磁盘缓存断言已按新契约改为：内存缓存保持字段，重启必须重新查询；手动令牌也不能终身信任一次读取。

## 6. 复现命令

### 测试

```bash
cd "/Users/leeliu/Documents/ClaudeProject/PWE AI Bar"
CLANG_MODULE_CACHE_PATH=/private/tmp/pwe-claude-20260907/clang \
SWIFT_MODULECACHE_PATH=/private/tmp/pwe-claude-20260907/swift \
PWEBAR_TEST_ARTIFACTS=/private/tmp/pwe-claude-20260907/ui \
swift test --disable-sandbox \
  --scratch-path /private/tmp/pwe-claude-20260907/build \
  --cache-path /private/tmp/pwe-claude-20260907/cache
```

### 独立审阅包

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/pwe-claude-20260907/clang \
SWIFT_MODULECACHE_PATH=/private/tmp/pwe-claude-20260907/swift \
PWEBAR_BUILD_ROOT=/private/tmp/pwe-claude-20260907/build \
PWEBAR_CACHE_PATH=/private/tmp/pwe-claude-20260907/cache \
PWEBAR_DISABLE_SANDBOX=1 \
PWEBAR_SIGN_IDENTITY=- \
PWEBAR_APP_OUTPUT='build/claude-review/PWE AI Bar.app' \
./scripts/build-app.sh release

codesign --verify --deep --strict 'build/claude-review/PWE AI Bar.app'
```

受管理环境阻止 dsymutil 时，应在获准构建环境运行同一命令，不能以二进制恰好存在视作构建通过。

### 诊断与使用

```bash
APP='build/claude-review/PWE AI Bar.app'
"$APP/Contents/MacOS/PWEAIBar" --cred
"$APP/Contents/MacOS/PWEAIBar" --credentials-read-only

# 完整流程可能更新原登录凭据：
"$APP/Contents/MacOS/PWEAIBar" --credentials

# 建议先退出旧 PWE，避免两个监控器同时查询：
open "$APP"
```

本轮实际执行前两条诊断，没有执行第三条完整续期诊断，也没有启动正常 GUI 入口或替换用户正在运行的应用。

## 7. 实际边界

1. **真实续期写回尚未主动触发。** 已通过注入式回归和临时文件测试；本机有效令牌的只读查询已通过。真实到期、钥匙串拒绝更新与恢复应在专用测试账号或正常到期场景验收。
2. **与官方 CLI 没有共同的跨进程锁。** 写前比较降低冲突，不能保证跨进程远端轮换永不竞争。写回/轮换冲突时重新登录，不修改 ACL 或放宽权限。
3. **未知身份候选保守处理。** 不证明同账户就不自动回退；用户可以重新登录所选 CLI 或明确保存手动令牌。
4. **内部 usage 接口仍可能变化。** 今日真实查询证明此账号可以读2个窗口，没有逐数字与官方页面并排验收，也没有在真实账户验证 extra_usage 单位。
5. **UI/性能验证范围。** 已做真实SwiftUI渲染与状态回归；未测物理点击到首帧p95、持续功耗、系统授权交互及真实通知送达。
6. **其他模块未扩展。** Codex/其他五家/成本统计/预测算法没有重做；本轮只为Claude提供身份隔离和新鲜的原始观察。
7. **status line不在交付中。** 不需修改Claude全局配置或升级CLI；后续需版本、账户和实际payload验收。
8. **分发未执行。** 本机ad-hoc包不是公证发行包，发布需既有Developer ID、公证流程和明确发布指令。

## 8. 接手顺序

1. 先检查当前Git工作树，区分本修复与保留的已有工作，不reset或覆盖。
2. 重跑测试与构建，使用实际构建产物，不依赖旧二进制。
3. 打开审阅包验普通刷新、限流提示、手动令牌保存/清除、重新连接；核对键盘与系统授权。
4. 用专用账号或正常到期场景验证真实续期写回，只记状态与脱敏字段，不导出token。
5. 同账户、同窗口、相近时间对照官方 `/usage`。有差异先查来源/时刻/响应结构，不人为调整比例。
6. 再按独立任务安排状态栏桥接、多工具和预测优化，不把这些尚未开始的扩展算成当前主路径的已验证功能。
