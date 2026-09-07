# PWE AI Bar — P0 / P1 实施与验收记录

日期：2026-09-05（Australia/Melbourne）  
审查基线：`92edde1`  
范围：`ASTRA_AUDIT_HANDOFF_2026-09-05.md` 中 01～07 全部 P0 / P1。  
状态：源码修复、隔离回归测试及 Debug / Release 构建完成；未提交 Git，未发布或公证，未安装真实 hook。

## 实施结果

| 项目 | 已实施行为 | 验证 |
|---|---|---|
| 01 · 配置保护 | 读取/解析失败即停止；拒绝原子替换符号链接；保留其他配置和 hooks；写入前备份原始字节；正确引用特殊字符路径；安装结果检查脚本可执行性和三个 hook | 无文件创建、损坏/不支持/不可读配置、符号链接、复制失败、重复安装、备份、shell 路径执行测试 |
| 02 · Codex 额度 | 在受限尾部中按 `codex` / `premium` 分别归约；使用记录时间跨文件比较；兼容无 limit_id 的旧主额度；忽略损坏/缺时间/无效百分比；过期显示待确认 | 混合额度池、无效尾行与半行、mtime 改变、跨文件排序、附加额度恢复、缺失时间戳、过期和读取边界测试 |
| 03 · 事件可靠性 | hook 改为每事件独立文件；不按数量淘汰未消费事件；应用持久化会话状态后删除已消费文件；损坏文件隔离保留；每秒独立轮询，脱离远程额度刷新 | 60 个真实脚本并发进程全部事件保留；跨 reader 重建恢复；持久化失败不删事件；256 条损坏记录不阻塞后续有效事件；空闲两小时且 HTTP 挂起时事件仍及时到达 |
| 04 · 提醒状态 | 接收去重、待重置记录和投递队列分别持久化；OS 接受后才确认投递；失败每分钟重试；点击打开应用不清空去重；新回复解除旧等待；恢复需新鲜观测，延迟投递重查当前状态 | 缺失/过期/失败快照、重启、投递重试、多个同时重置、同会话新事件、跨会话隔离、已回复清除待投递等待测试 |
| 05 · 分级来源 | 明确 severity 优先；缺失或未知分级才使用本地阈值；缓存保留 grader；接近上限与明确耗尽分开 | server normal/warning/critical、本地 96%、明确 100%、带/不带 severity 的解析及缓存恢复测试 |
| 06 · 凭据恢复 | 优先 `SecItemUpdate`，仅不存在时新增；错误不删除原值；删除失败可见；设置等待存储与验证结果；401/403 状态明确且相同无效令牌不重复请求；更换令牌可恢复；429 遵守秒数/HTTP 日期退避；旧请求不能覆盖新令牌结果 | 模拟钥匙串更新/新增/删除失败，TokenEditor 状态，401/403 更换恢复，429 跨重启/更换保留退避，网络退避，凭据更换与旧请求并发测试 |
| 07 · 回归测试 | 新增 SwiftPM 测试 target 与独立路径、设置、时钟、凭据、网络、通知接收替身 | 35 个 XCTest 全部通过 |

没有实施交接文档中的 P2 / P3 项目。`Prefs` 的初始化入口仅用于测试隔离；未改动开机启动策略、统计计价口径或发布脚本。

## 主要文件

- `Sources/PWEAIBar/Providers/HookProvider.swift`：安全安装、旧日志兼容、独立事件消费。
- `hooks/pwe-ai-bar-hook.sh` 与资源内同名副本：并发安全的独立事件写入。
- `Sources/PWEAIBar/Providers/CodexProvider.swift`：分组归约、时间与过期语义。
- `Sources/PWEAIBar/Core/RuleEngine.swift`、`Store.swift`、`Notifier.swift`：提醒状态、独立调度及投递确认。
- `Sources/PWEAIBar/Providers/ClaudeProvider.swift`、`Credentials.swift`：凭据、网络、缓存与分级。
- `Sources/PWEAIBar/Core/TokenEditor.swift`、`App/SettingsView.swift`、`App/PanelView.swift`：真实保存结果与凭据恢复入口。
- `Tests/PWEAIBarTests/`：7 个文件、35 个测试方法。
- `README.md`：升级步骤、数据语义、测试命令和事件保留规则。

## 实际验收

### 自动化测试

最终完整测试结果：**35 tests, 0 failures**，测试执行约 **2.79 秒**，不含编译。

| 测试组 | 数量 |
|---|---:|
| CredentialTests | 10 |
| HookTests | 9 |
| QuotaTests | 6 |
| RuleTests | 7 |
| StoreTests | 2 |
| RenderingTests | 1 |

`StoreTests` 在初始空闲时间已超过两小时、Claude HTTP 请求保持挂起时写入新等待事件；默认 1 秒事件轮询仍完成提醒分发，整个测试约 1.21 秒，断言要求在 5 秒内。随后释放 HTTP 请求，验证迟到的额度刷新没有覆盖新事件，也没有重复投递。

并发测试实际启动 60 个 hook 脚本进程，验证 60 条有效记录全部保留，超过旧版 40 条环形日志容量也不删除未消费事件。`answered` 文本没有保留合成输入内容。

### 构建与检查

- Debug 构建与测试通过。
- Release 构建通过。首次在沙箱内运行时，编译/链接完成，但 `dsymutil` 被权限限制拦住；经工具批准在沙箱外重跑同一本地构建，最终返回 `Build complete! (6.61 sec.)`。
- 当前工具链为 `/Applications/Xcode-beta.app/Contents/Developer`；这不等同于稳定版 Xcode 或 macOS 13 实机验证。
- `git diff --check` 通过。
- 构建、打包及两份 hook 脚本的 `bash -n` 通过。
- 两份 hook 脚本逐字节一致。

本次命令使用临时构建目录，未替换仓库原有 `build/PWE AI Bar.app`。Release 可执行文件位于 `/private/tmp/pwe-ai-bar-audit-build/release/PWEAIBar`，资源包位于同目录；临时文件可能被系统清理。

### 合成界面检查

使用当前 SwiftUI 视图生成 8 张图：凭据失效设置页的明暗两种外观，以及 Codex 待确认状态的三档面板密度 × 明暗两种外观。

已目视检查暗色设置页和浅色标准面板，凭据错误与“待确认”文字可见，没有显示伪造的剩余 100%。其他图完成渲染断言；不把离屏渲染称为完整窗口或辅助技术交互验收。

临时截图：`/private/tmp/pwe-p01-ui/`。

## 复验命令

在项目根目录执行：

```bash
swift test
swift build -c release
bash -n scripts/build-app.sh scripts/package.sh hooks/pwe-ai-bar-hook.sh Sources/PWEAIBar/Resources/pwe-ai-bar-hook.sh
cmp hooks/pwe-ai-bar-hook.sh Sources/PWEAIBar/Resources/pwe-ai-bar-hook.sh
git diff --check
```

本次受限环境使用：

```bash
PWEBAR_TEST_ARTIFACTS=/private/tmp/pwe-p01-ui \
CLANG_MODULE_CACHE_PATH=/private/tmp/pwe-ai-bar-audit-modules \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/pwe-ai-bar-audit-modules \
swift test --disable-sandbox \
  --scratch-path /private/tmp/pwe-ai-bar-audit-build \
  --cache-path /private/tmp/pwe-ai-bar-audit-cache
```

Release 采用相同缓存路径，主命令替换为 `swift build -c release`。`--disable-sandbox` 是本次 SwiftPM 执行参数，没有修改产品安全配置。

## 升级与真实环境边界

1. 使用项目原有本机构建流程生成新应用后，再运行新版本。本次只验证源码及临时构建，不把旧的 `build/` 应用当作已更新。
2. **已有 hook 用户需在新版设置中再次点击“安装”更新脚本。** 旧日志兼容读取仍保留，但旧脚本的并发写入缺陷不会因只替换应用而消失。
3. 每次修改有效 Claude 配置前，会在原目录生成 `settings.json.pwe-backup-<UUID>`。符号链接配置需要用户自行选择实际配置文件处理，本次安装函数会安全拒绝替换链接。
4. 未消费事件不自动按数量删除；应用恢复后批量消费。等待事件 30 分钟、完成/错误事件 2 分钟的新鲜度规则决定是否提醒；已消费的会话状态保留最多一天。
5. 未操作真实钥匙串或 Claude 配置，未向真实系统通知或外部推送端点发送测试消息。真实权限、服务端响应和设备送达仍需实际使用确认。
6. 系统通知请求被接受不代表用户已读。刘海和外部推送继续保留原来的独立行为，本次没有宣称验证 ntfy/Bark 服务协议或真实送达。
7. 发布签名、公证、最低系统验证，以及交接文档 P2/P3 的设置语义、统计和窗口适配，仍在本轮范围之外。

## 协议依据

`Retry-After` 的非负秒数与 HTTP 日期格式依据 [RFC 9110 §10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3)。钥匙串更新使用系统 `SecItemUpdate` / `SecItemAdd` / `SecItemDelete` 接口，存储副作用由测试替身验证，未以测试名义访问用户令牌。
