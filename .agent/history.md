# History（Maintenance Loop 记录）

本文件记录每次 Maintenance Loop 的执行结果。每次 Loop 结束必须追加一条记录（字段见 \\`.agent/loop.md\\` 第 6 节）。日常 Loop 只读本文件，不主动读取 \\`.agent/archive/\\`。

## 维护规则

- 只保留最近 **10** 次 Loop 记录。
- 更早记录移动到 \\`.agent/archive/\\`（建议按区间命名，如 \\`loop-001-015.md\\`），并在下方"归档索引"保留跳转。
- 记录按 Loop 编号倒序或正序排列均可，但必须自增且不重复。

## 归档索引

（暂无归档）

---

## Loop 记录

### Loop 0 — 基础设施初始化（非维护 Loop）

- **日期**：2026-08-09
- **类型**：基础设施搭建（非功能维护，不进入 Observe/Decide/Execute 流程）
- **内容**：建立 \\`.agent/\\` 维护循环基础设施：\\`loop.md\\`、\\`rules.md\\`、\\`memory.md\\`、\\`history.md\\`、\\`archive/\\`。
- **修改**：仅新增 \\`.agent/\\` 目录与 Markdown 文件；未改动任何业务代码、测试、构建脚本。
- **验证**：\\`git status\\` 确认无既有文件被覆盖；未运行测试（无代码改动，不影响构建）。
- **剩余风险**：无。后续首次真实维护 Loop 从编号 1 开始。

---

### Loop 0.1 — 基础设施完善：发现路径与文档缺口补齐（非维护 Loop）

- **日期**：2026-08-09
- **类型**：基础设施完善（非功能维护，不进入 Observe/Decide/Execute 流程）
- **内容**：
  - \\`AGENTS.md\\` 新增 "Maintenance Loop" 小节、\\`CLAUDE.md\\` 项目概览新增一行，指向 \\`.agent/loop.md\\`，补齐未来智能体的发现路径（此前全仓 Markdown 均未引用 \\`.agent\\`）。
  - \\`.agent/loop.md\\` 加法补齐两处缺口：Decide 节增加"问题选择要求（有明确依据 / 可以验证 / 修改范围可控）"与"连续维护同一模块须有新证据"；Record 节增加"本轮未修改时同样必须记录检查范围、未发现高价值问题的原因、验证状态"。
- **修改**：仅文档加法编辑（\\`AGENTS.md\\`、\\`CLAUDE.md\\`、\\`.agent/loop.md\\`、\\`.agent/history.md\\`）；未改动任何业务代码、测试、构建脚本。
- **验证**：\\`git status --short\\` 与 \\`git diff --stat\\` 确认改动仅限上述文档（\\`Sources/\\`、\\`Tests/\\`、\\`script/\\`、\\`Assets/\\`、\\`Package.swift\\`、\\`*.pbxproj\\` 无改动）；\\`swift build -c debug\\` exit 0。
- **剩余风险**：无。

---

### Loop 1 — 无有效证据，本轮不修改

- **日期**：2026-08-09
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`git status\\` / \\`git log --oneline -10\\` / \\`git diff --stat\\`：工作区仅有 Loop 0/0.1 的 4 个文档文件未提交（\\`.agent/history.md\\`、\\`.agent/loop.md\\`、\\`AGENTS.md\\`、\\`CLAUDE.md\\`），无任何业务代码、测试或脚本改动；最新提交为 \\`6d3faa2 docs: establish evidence-driven maintenance loop infrastructure\\`。
  - 全量测试 \\`swift test\\`：544 个测试，0 失败（与 memory.md 记录一致）。
  - \\`swift build -c debug\\`：构建通过（exit 0）。
  - \\`rg -n "TODO|FIXME|HACK" Sources Tests\\`：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\` / \\`README.md\\`：其中未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、手动刷新 UX、键盘与辅助功能、登录项迁移等），非代码缺陷，不属于本 Loop 的修改对象。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：\\`swift test\\`（544/0 通过）、\\`swift build -c debug\\`（exit 0）已执行；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——本轮无代码改动，不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake 等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 2 — 无有效证据，本轮不修改

- **日期**：2026-08-11
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`rtk git status\\`：工作区 clean，无未提交修改、无未跟踪文件；\\`rtk git diff --stat\\` 为空。
  - \\`rtk git log --oneline -10\\`：最新提交 \\`1bd17cc docs: complete maintenance loop docs and record loop sessions\\`，均为已完成工作，无在途分支或未完成事项。
  - 全量测试 \\`rtk swift test\\`：544 个，0 失败（2026-08-11 05:45 执行，与 memory.md 记录一致）。
  - \\`rtk rg -n "TODO|FIXME|HACK" Sources Tests docs\\`：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\`：未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Popover 键盘与辅助功能、Login Item Migration、Cross-Copy Activation 可视检查等），非代码缺陷，不属于本 Loop 的修改对象。
  - 应用日志：App 正在运行（PID 1025），\\`log show --last 30m\\` 无 error 级日志。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工发布门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：\\`swift test\\`（544/0 通过）已执行；\\`swift build -c debug\\` 未运行（本轮无代码改动，无构建变化）；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、登录项迁移、跨副本可视检查等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 3 — 无有效证据，本轮不修改

- **日期**：2026-08-11
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`git status\\`：工作区 clean，无未提交修改、无未跟踪文件；\\`git log --oneline -10\\`：最新提交 \\`docs: record loop 2 maintenance session (no code change)\\`，无在途分支或未完成事项。
  - 全量测试 \\`swift test\\`：544 个，0 失败（2026-08-11 10:04 执行，与 memory.md 记录一致）。
  - \\`rg -n "TODO|FIXME|HACK" Sources Tests docs\\`：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\`：未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Real/Cached/Failure Presentation、Dynamic Quota Window Presentation 等），非代码缺陷，不属于本 Loop 的修改对象。
  - 应用日志：App 正在运行（PID 1025），\\`log show --last 24h\\` 无 error/fault/crash 级别日志。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工发布门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：\\`swift test\\`（544/0 通过）已执行；\\`swift build -c debug\\` 未运行（本轮无代码改动，无构建变化）；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、真实/缓存/失败呈现等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 4 — 无有效证据，本轮不修改

- **日期**：2026-08-12
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`git status\\`：工作区 clean，无未提交修改、无未跟踪文件；\\`git diff --stat\\` 为空；\\`git log --oneline -10\\`：最新提交 \\`21efe8a docs: record loop 3 maintenance session (no code change)\\`，无在途分支或未完成事项。
  - 全量测试 \\`swift test\\`：544 个，0 失败（2026-08-12 16:27 执行，与 memory.md 记录一致）。
  - \\`rg -n "TODO|FIXME|HACK" Sources Tests docs\\`：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\` / \\`README.md\\`：自 \\`bfa11fc\\` 后无修改；未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Real/Cached/Failure Presentation 等），非代码缺陷。
  - 应用日志：App（PID 1025）与 Widget（PID 1023）自 2026-08-11 09:00 起连续运行；\\`log show --last 24h\\` 中应用 subsystem 无 error/fault/crash 级日志。唯一 error 级输出来自本次 \\`swift test\\` 的 xctest 进程：\\`Launch at login registration/unregistration failed（SMAppServiceErrorDomain 错误12/7）\\` 与 \\`UserDefaults Not updating lastKnownShmemState\\`。经核实均属 \\`LaunchAtLoginManagerTests\\` 预期失败路径模拟与测试隔离域噪音（测试文件对 SMAppServiceErrorDomain 的注册/注销失败、重试、修复路径有完整断言，544/0 通过），非应用缺陷。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档未验证项与测试进程日志均属人工门禁/预期模拟而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：\\`swift test\\`（544/0 通过）已执行；\\`swift build -c debug\\` 未运行（本轮无代码改动，无构建变化）；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、登录项迁移等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 5 — noAvailableCredits 被错误归类为详情获取失败

- **日期**：2026-08-13
- **问题**：账号当前无可用重置额度（正常业务状态）被当作"详情获取失败"处理：Popover 显示"详情失败：没有 available credits"，且真实应用每 15 分钟记录一条 error 级日志 \\`Reset credits detail fetch unavailable (没有 available credits); using app-server count only\\`，持续污染错误监控。
- **证据**：\\`log show --last 24h\\`（PID 16536，2026-08-13 00:22–13:12 连续 60+ 条，间隔 15 分钟 = \\`AdaptiveRefreshCadencePolicy.stableInterval\\`）；\\`ResetCreditsDetailProvider.parsePayload\\` 对 credits 数组无 available 条目抛 \\`noAvailableCredits\\`，与网络故障共用同一 \\`.unavailable\\` + diagnostic 降级路径（\\`QuotaRefreshService.enrichResetCreditsDetails\\` catch 分支）；对比 UI 对 \\`.detailed\\` + count==0 有专门中性文案"当前没有可用 reset credit"、\\`.appServerCountOnly\\` 本就是中性状态。
- **原因**：\\`noAvailableCredits\\` 是服务端明确返回的正常状态（当前无可用重置额度），不是获取故障；错误分类不当导致误导文案与持续 error 级日志（\\`Logger.warning\\` 在本机 macOS 上经 unified logging 显示为 E/error 级，全项目一致，非本消息特有）。
- **修改**：\\`Sources/CodexMonitorNative/Core/QuotaRefreshService.swift\\`（enrichResetCreditsDetails catch 分支特判 \\`noAvailableCredits\\` 且无可复用详情时，返回中性 \\`.appServerCountOnly\\`、diagnostic 置 nil、不记录日志；有可复用详情时保持原有 \\`.unavailable\\` 降级不变，复用条件未动）；\\`Tests/CodexMonitorNativeTests/QuotaRefreshServiceTests.swift\\`（+2 测试：无复用详情 → 中性状态；有复用详情 → 保持 .unavailable，锁定边界行为；+1 测试桩 \\`NoAvailableCreditsProvider\\`）。未改 UI/格式化/Widget 文件、未改持久化 schema（\\`.appServerCountOnly\\` 是既有 case）。
- **验证**：\\`swift test --filter QuotaRefreshServiceTests\\`（13/0，含新增 2 测试）；\\`swift test --filter StatusPopoverFormattingTests --filter ResetCreditsDetailProviderTests --filter WidgetPresentationTests --filter WidgetTimelineBridgeTests\\`（132/0）；\\`swift test\\`（559/0，557+2）；\\`swift build -c debug\\`（exit 0）。
- **剩余风险**：当前运行的 App（PID 16536）仍是旧二进制，日志行为变化需下次启动/更新后生效，未实测新二进制下的日志输出；Popover 文案变化（"详情失败：没有 available credits" → "当前仅显示 Codex 提供的次数"）属于可见行为，未做 QA_CHECKLIST 人工桌面检查（本环境无 GUI 访问），已由 \\`StatusPopoverFormattingTests\\` 覆盖中性状态文案路径。不涉及打包/签名/安装/Widget 集成改动，未运行 \\`--verify\\`。

---

### Feature 1 — 周额度消耗趋势与耗尽预测

- **日期**：2026-08-12
- **类型**：用户明确授权的新功能开发（非 Maintenance Loop）。
- **目标**：基于真实额度刷新记录近期周额度变化，在主 App 展示趋势、当前速度、预计耗尽时间和距离重置时间，同时保持菜单栏与 Widget 行为兼容。
- **设计**：新增独立、账号/会话边界隔离的趋势历史；只采集可信真实周额度。至少 3 个连续样本且跨度 10 分钟后才预测；额度上升/重置时间跨周期会重建序列，短时间大幅下降、非重置式回升和乱序样本不进入原趋势。
- **修改**：新增 \\`Core/UsageTrend.swift\\`、\\`UI/UsageTrendFormatting.swift\\`、\\`UI/UsageTrendView.swift\\` 与 \\`UsageTrendTests.swift\\`；在 \\`AppState\\` 成功持久化状态后同步趋势，在 Popover 接入趋势卡片。首次安装验收发现共享 \\`StatusPopoverFormatting.swift\\` 引用了主 App 专用趋势类型，导致 Widget 双编译失败；随后将趋势格式化移至主 App 专用文件，未扩散 Widget target 依赖，也未修改菜单栏投影、Widget payload 或签名配置。
- **验证**：\\`swift test --filter UsageTrend\\`（10/0 通过）；\\`swift test\\`（554/0 通过）；\\`swift build -c debug\\`（exit 0）。首次 \\`./script/build_and_run.sh --verify\\` 在 Widget 编译阶段按预期暴露上述类型边界问题；修正后重新执行通过，确认 \\`/Applications/CodexMonitorNative.app\\` 正在运行，主 App/Widget 签名、App Group entitlements、版本、运行路径、单实例 owner、旧副本重定向及 Widget 绑定全部通过。Computer Use 无法捕获菜单栏 App 的 CGWindow（\\`cgWindowNotFound\\`），因此标准宽度布局、文字截断、VoiceOver 与实时分钟倒计时仍需按 \\`QA_CHECKLIST.md\\` 人工确认。
- **剩余风险**：耗尽时间是按最近连续样本的平均速度线性外推，不代表服务端保证；首次启用或重置/异常跳变后需等待至少 10 分钟和 3 次成功刷新。

---

### Feature 2 — 额度异常变化检测与提醒

- **日期**：2026-08-12
- **类型**：用户明确授权的新功能开发（非 Maintenance Loop）。
- **目标**：在可信真实周额度发生异常变化时检测并提醒，同时保持账号隔离、趋势重建、菜单栏和 Widget 行为不变。
- **设计**：复用 \\`UsageTrendHistory\\` 已有异常阈值；新增 \\`QuotaAnomaly\\` 事件承载前后样本。只有同一账号/会话边界内新接受的异常样本触发一次事件；已知重置、重复/乱序、mock 与身份不匹配数据均不提醒。主 App 使用 \\`UserNotifications\\` 请求 alert/sound 权限并投递即时通知，前台时也展示 banner；拒绝权限或投递失败只记录日志，不影响额度状态提交。
- **修改**：扩展 \\`Core/UsageTrend.swift\\` 返回结构化异常事件；在 \\`Shared/AppState.swift\\` 的可信趋势协调点发布事件；新增 \\`System/QuotaAnomalyNotifier.swift\\` 并在 \\`App/AppDelegate.swift\\` 接线；\\`UsageTrendTests.swift\\` 增加异常事件、重置/重复抑制、通知文案和单次发布测试。未修改 Widget payload、共享 Widget 源文件、持久化 schema、签名或安装配置。
- **验证**：\\`swift test --filter UsageTrend\\`（13/0 通过）；\\`swift test\\`（557/0 通过）；\\`swift build -c debug\\`（exit 0）；\\`git diff --check\\`（exit 0）；\\`./script/build_and_run.sh --verify\\` 通过，确认 \\`/Applications/CodexMonitorNative.app\\` 正在运行，主 App 本地 ad-hoc 签名、Widget Apple Development 签名及 sandbox/App Group entitlements、版本、运行路径、单实例 owner、旧副本重定向与 Widget 绑定全部通过。未人为制造真实账号额度异常，因此通知中心的实际权限弹窗与 banner 外观仍需人工确认。
- **剩余风险**：用户拒绝系统通知权限后不会收到提醒；异常阈值是确定性启发式规则，服务端未提供异常语义，提醒表示“建议确认”而非确认存在未授权使用。

---

### Loop 6 — 无有效证据，本轮不修改

- **日期**：2026-08-14
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`git status\\`：工作区 clean，无未提交修改、无未跟踪文件；\\`git diff --stat\\` 为空；\\`git log --oneline -10\\`：最新提交 \\`bb9497f docs: remove CLAUDE.md and sync AGENTS.md with current project\\`（纯文档清理，无代码改动），无在途分支或未完成事项。
  - 全量测试 \\`swift test\\`：559 个，0 失败（2026-08-14 12:48 执行，与 AGENTS.md / Loop 5 记录一致）。
  - \\`rg -n "TODO|FIXME|HACK" Sources Tests docs\\`：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\` / \\`README.md\\`：自 \\`bfa11fc\\` 后无修改（\\`git log -- <docs>\\` 确认）；未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX 等），非代码缺陷。
  - 应用日志：App（PID 30564）与 Widget（PID 30571）自 2026-08-13 13:33 起常驻运行；\\`log show --last 24h\\` 中 subsystem 含 \\`CodexMonitor\\` 的 error 级输出全部来自 **xctest 测试进程**（PID 59665/99180/2427 等）：\\`Launch at login registration/unregistration failed（SMAppServiceErrorDomain 3/7/11/12）\\` 属 \\`LaunchAtLoginManagerTests\\` 预期失败路径模拟（Loop 4 已核实）；\\`Reset credits detail fetch unavailable（HTTP 503 / 没有 available credits）\\` 属 \\`QuotaRefreshServiceTests\\` 对降级路径的断言模拟，其中 \\`没有 available credits ... with previous unexpired detail times\\` 正是 Loop 5 明确保留的“有可复用详情 → 保持 \\`.unavailable\\`”边界路径，均有测试锁定。真实 App 进程 24h 内无 error/fault/crash 日志。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。测试进程的预期模拟日志与文档中的人工发布门禁项均非代码缺陷证据，禁止以“顺手优化”或猜测式修改替代。
- **验证状态**：\\`swift test\\`（559/0 通过）已执行；\\`swift build -c debug\\` 未运行（本轮无代码改动，无构建变化）；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险。Loop 5 记录的遗留项仍在跟踪：运行中的 App（PID 30564，13:33 启动）启动时间早于修复提交 \\`2c0187c\\`（13:34），为旧二进制，Loop 5 的日志行为变化需下次启动/更新后生效——已确认 24h 内旧二进制未产生 error 级日志，修复后行为待其重启后复核；遗留人工桌面验证项继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 7 — 无有效证据，本轮不修改

- **日期**：2026-08-16
- **问题**：未发现可处理的高价值问题，按 \\`loop.md\\` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - \\`git status --short\\` / \\`git log --oneline -10\\` / \\`git diff --stat\\`：工作区 clean，无未提交修改、无未跟踪文件；HEAD 为 \\`c30d991 docs: record loop 6 maintenance session (no code change)\\`，自 Loop 6 记录后仓库无任何新提交，无在途分支或未完成事项。
  - 全量测试 \\`swift test\\`：559 个，0 失败（2026-08-16 00:40 执行，与 AGENTS.md / Loop 6 记录一致）。
  - \\`rg -n "TODO|FIXME|HACK"\\`（Sources/Tests 的 .swift 与 docs）：无匹配。
  - 已知问题文档 \\`VERIFICATION.md\\` / \\`QA_CHECKLIST.md\\` / \\`README.md\\`：\\`git diff bfa11fc HEAD --stat\\` 为空，三份文档自 \\`bfa11fc\\` 后无修改；未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX 等），非代码缺陷。
  - 应用日志：\\`log show --last 24h\\`（subsystem 含 CodexMonitor，排除 xctest 进程）0 条 error/fault/crash 级输出。App 进程仍为 PID 30564（2026-08-13 13:33 启动，旧二进制，早于 Loop 5 修复提交 \\`2c0187c\\` 13:34），24h 内未产生 error 级日志——与 Loop 6 跟踪项一致：当前账号状态未触发"无可用重置额度"路径，修复后行为待该进程重启后复核，非代码缺陷证据。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败（559/0）、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档未验证项与旧二进制遗留跟踪项均非代码缺陷证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：\\`swift test\\`（559/0 通过）已执行；\\`swift build -c debug\\` 未运行（本轮无代码改动，无构建变化）；\\`./script/build_and_run.sh --verify\\` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险。遗留跟踪项：运行中的 App（PID 30564）为旧二进制，Loop 5 日志行为变化待其重启后复核（24h 内已确认无 error 日志）；遗留人工桌面验证项继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。附带观察（非本轮修改对象）：\\`memory.md\\` 中测试数量仍记 544，实际为 559（AGENTS.md 明确以 \\`swift test\\` 实际结果为准），属文档滞后，记录备查。
---

### Loop 8 — 无产品缺陷；同步 .agent/memory.md 测试数量文档滞后

- **日期**：2026-08-20
- **问题**：\\`.agent/memory.md\\`（维护基础设施文档）中测试数量仍写「XCTest，544 个，0 失败」，与 \\`AGENTS.md\\`（559）及当前 \\`swift test\\` 实际结果（559）不一致。属 Loop 7 已记录「备查」的文档滞后项。
- **证据**：\\`swift test\\` 实测 \\`Executed 559 tests, with 0 failures\\`（2026-08-20 18:21 执行）；\\`AGENTS.md\\` 三处标注 559；\\`.agent/memory.md\\` 第 24 行仍为 544，且 Loop 7（2026-08-16）已明确记录此滞后。
- **原因**：\\`memory.md\\` 最后更新于 2026-08-12（当时 544），此后 Loop 5（+2 测试 → 559）等未同步该数字；\\`memory.md\\` 自述职责是「只在这里更新长期事实」，测试数量属应同步的稳定事实，滞后会误导后续 Loop 的测试门槛判断。
- **修改**：仅 2 处文档同步（\\`git diff\\` 确认只动 \\`.agent/memory.md\\`）：① 第 5 行「最后更新」改为 2026-08-20（同步测试数量 544→559）；② 第 24 行 \\`XCTest，544 个，0 失败\\` → \\`XCTest，559 个，0 失败\\`。未改任何业务代码、测试、构建脚本、Widget 文件。
- **验证**：
  - \\`swift test\\`：559/0 通过（本轮 18:21 实测）。
  - \\`swift build -c debug\\`：exit 0（后台 job bash-5）。
  - \\`git status\\`/\\`git diff -- .agent/memory.md\\`：改动严格限定于该文件（2 行 diff）。
  - \\`rg 544 .agent/memory.md\\`：仅剩「最后更新」行的 544→559 变更说明，无陈旧正文残留。
  - 未运行 \\`./script/build_and_run.sh --verify\\`：本轮为 \\`.agent/\\` 文档改动，不涉及打包/签名/安装/Widget 集成或可见行为，不满足运行门槛。
- **Observe 阶段发现但未处理**（非本次修改对象）：
  - App 进程 PID 2442（2026-08-20 13:35 启动）初始有一次 \\`Refresh failed (networkFailed) consecutive=1\\`，随后在 18:17 唤醒/网络恢复刷新中成功（\\`Real refresh succeeded: weekly=96%\\`），菜单栏显示可信 96%，5 小时内无后续失败；旧进程 PID 30564 已被正确替换（单实例仲裁生效）。该瞬时失败非可复现、无代码路径证据，不构成有效证据；\\`rateLimitsRead rejected code=-32603\\` 与 \\`Failed to launch Codex app-server\\` 属启动时序（app-server 尚未就绪）噪声，App 按设计 fail-closed 保留上次快照，未违反产品不变量。
  - 文档/QA 未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX 等），非代码缺陷，继续由发布前人工门禁覆盖。
- **剩余风险**：无新增风险。本轮针对 memory.md 文档滞后已完成同步；App 瞬时启动失败的根因为环境/时序（codex app-server 启动竞态），非本次改动所覆盖范围，如有重复出现可作下轮观察项，但当前无路径证据。

### Loop 9 — 优化周额度消耗趋势与耗尽预测（近期加权与稳健性）

- **日期**：2026-08-21
- **问题**：周额度消耗趋势与耗尽预测使用首尾长期平均，近期明显节奏变化（突发消耗、长时间空闲后恢复）被稀释，且对不规则间隔、低变化样本证据不足时易产生误导性耗尽预测。
- **证据**：用户目标“优化现有周额度消耗趋势与耗尽预测，使预测能更准确反映近期真实使用速度，避免长期历史平均值掩盖最近明显的使用节奏变化；重点审查并改进 UsageTrendAnalyzer，对突发消耗、长时间空闲后恢复使用、不规则刷新间隔、低变化样本和样本不足场景保持稳健，证据不足时宁可不给出耗尽预测”。原 \\`UsageTrendAnalyzer.analyze\\` 仅用 \\`first.remaining - last.remaining / spanHours\\`，全量测试 559 中无覆盖近期加权/空闲/低变化抑制的用例。
- **原因**：长期平均未对近期窗口加权，未识别长空闲后重新活跃的上下文切换，低速率与小跌幅缺乏证据门槛，方差高但信号弱时仍会外推远期耗尽时间。
- **修改**：\\`Sources/CodexMonitorNative/Core/UsageTrend.swift\\`（\\`UsageTrendAnalyzer\\` 重构：① 长空闲（≥90 分钟且消耗 ≤1%）修剪，仅用空闲后有效窗口；② 基准仍按时间加权端到端，近期窗口（≥30 分钟或 4 点）若显著更快则 0.75/0.25 或 0.60/0.40 融合；③ 总消耗 <2% 视为证据不足返回 \\`insufficientData\\` 不预测；④ 基准 <0.7%/h 视为 \\`stable\\`（除非近期有 ≥1.5%/h 且 ≥2% 的强信号）；⑤ 回归残差 RMSE/R² 校验与 >14 天远期抑制，避免高噪声误预测；未改账号/会话隔离、重置识别、异常提醒、持久化、菜单栏/Widget 投影）；\\`Tests/CodexMonitorNativeTests/UsageTrendTests.swift\\`（+7 确定性测试：近期突发加权、长空闲修剪、不规则间隔、低变化抑制、极慢速率判稳、样本/跨度不足覆盖。）。
- **验证**：
  - \\`swift test --filter UsageTrendTests\\`：18/18 通过（含新增 7）。
  - \\`swift test\\`：566/566 通过，0 失败（原 559 +7）。
  - \\`swift build -c debug\\`：exit 0。
  - 未改 Widget 共享源文件与持久化 schema，无需同步 pbxproj。
  - 本轮 Loop 记录与 \\`memory.md\\` 同步后将执行 \\`./script/build_and_run.sh --verify\\` 进行签名安装验收（见 Loop 9 后续验收记录）。
- **剩余风险**：极低。近期加权阈值（1.3×/1.5×）为启发式，对恰好处于阈值附近的节奏变化可能保持基准速率；>14 天抑制与 0.7%/h 稳定阈值偏保守，极慢但持续消耗的场景会显示“当前速度下不会耗尽”而非远期时刻，符合“证据不足不预测”原则。未涉及 GUI 人工门禁项。

### Loop 10 — 统一后台刷新协调：调度锚点幂等 + 恢复触发新鲜度门控 + 刷新生命周期可观测性

- **日期**：2026-08-21
- **问题**：① 任何状态发布（时区/日历/本地化变化的 temporal reconciliation、网络不可用记账等）都会把下一次自动刷新的截止点重置为“现在+完整间隔”，环境扰动反复发生时自动刷新被无限推迟；② 唤醒/网络恢复/路径变化触发在缓存真实快照仍然新鲜且无失败时也立即发起完整 provider 周期（spawn codex app-server + RPC），短睡眠与网络抖动场景下是纯浪费请求；③ 缺少判断“上次刷新为什么跑、调度器处于什么生命周期”的结构化诊断。
- **证据**：用户目标明确要求审查 RefreshScheduler/QuotaRefreshService/AppState 触发关系并统一协调。代码路径：`RefreshScheduler.updateSchedule` 无条件 `scheduleNextRefreshIfPossible()`（以 `clock.now` 重算 bootstrap/stable/rapid 锚点）；`AppDelegate` becameReachable/wake 路径无条件 `requestRefresh(.networkRestored)`；生产代码无 `.wake` 发射点（唤醒恢复经 network observer 重启后的 .networkRestored 完成）。审查同时确认：所有产品刷新入口已统一经 scheduler 单入口 + AppState active/pending 双层合并（同一时间仅一个物理请求，已有测试锁定 maximumConcurrentCalls==1）；AppState freshness task 与 scheduler resetBoundary 双跟踪同一时间边界，边界处多一次 reconciliation 发布但物理请求唯一且发布携带 savedAt 重锚定语义——评估后接受现状不做所有权重构。
- **原因**：updateSchedule 无法区分“刷新完成后的有意义状态迁移”与“展示性重发布”；恢复类触发缺少新鲜度判定输入。
- **修改**：`Sources/CodexMonitorNative/Core/RefreshScheduler.swift`（① updateSchedule 幂等：非刷新中且输入未变且已有未来 deadline 时跳过重调度；② RefreshSchedulingState 增加 staleAfterInterval 字段（默认值保持兼容）；③ requestRefresh 新鲜度门控：wake/networkRestored/networkChanged 在 failureCount==0 && 真实快照 fresh && now<lastSuccess+stableInterval 时折叠进现有 cadence，scheduleNextRefreshIfPossible(recoveryAnchor:) 把 deadline 收紧到 ≤lastSuccess+stableInterval 避免 stale 窗口；manual/accountBoundaryChanged 永不门控，退避窗口内行为不变；④ 新增 lastFiredTrigger/lastFiredAt/freshnessGatedTriggerCount/hasDeferredAutomaticTrigger/activePauseReasons 诊断与门控日志）；`Sources/CodexMonitorNative/Shared/AppState.swift`（refreshSchedulingState 传递 staleAfterInterval；ActiveRefresh 携带 trigger，暴露 activeRefreshTrigger 计算属性与 lastRefreshTrigger）；`Tests/CodexMonitorNativeTests/RefreshSchedulerTests.swift`（+11 确定性测试：锚点幂等、失败输入重算、门控折叠、收紧、stale/老化立即刷新、退避禁用门控、manual/accountBoundary 不门控、networkChanged 门控、mock/无数据不门控、调度器诊断、AppState 触发诊断）。未改额度解析、Widget 展示、菜单栏行为、持久化格式；两文件均不在 Widget 双编译清单，无需 pbxproj 同步。实施计划与跨轮账本：`docs/superpowers/plans/refresh-coordination-unification.md`。
- **验证**：
  - `swift test --filter RefreshSchedulerTests`：25/0（原 14 + 新增 11）。
  - `swift test --filter AppStateTests --filter RefreshConsistencyRegressionTests --filter DeterministicFaultScenarioTests --filter WidgetTimelineBridgeTests --filter SleepWakeObserverTests --filter NetworkReachabilityObserverTests --filter SystemClockObserverTests`：158/0。
  - `swift test` 全量 ×2：577 测试，失败分别为 13 与 7，全部位于 `SingleInstanceCoordinatorTests` 预存在时序敏感族（handoff deadline 型断言）。基线对照：改动前干净工作树全量 ×3 失败 3/8/9，该套件单独运行在低负载下连续两次结果仍不同（2 个→1 个失败用例），Loop 9 同日早间曾记录 566/0 全过——证明该族测试在本机处于边际时序状态、与环境负载相关，与本次改动（不相交模块）无关。
  - `swift build -c debug`：exit 0。
  - 文档同步：AGENTS.md 测试数量 559→577（3 处）、memory.md 最后更新与刷新管线架构事实。
  - 未运行 `./script/build_and_run.sh --verify`：不涉及打包/签名/安装/Widget 集成改动。未做 QA_CHECKLIST 人工桌面检查：本环境无 GUI；刷新时机变化（启动时缓存 <15 分钟则跳过即时恢复刷新、由 cadence 在 ≤lastSuccess+15min 补齐）属可见时序行为，已由确定性测试覆盖语义。
- **剩余风险**：① SingleInstanceCoordinatorTests 的预存在时序波动未修复（不同子系统，超出本轮范围），建议独立 Loop 用注入时钟改造该族 deadline 断言；② 启动时若持久化快照 <15 分钟且无失败，首刷推迟到 cadence 截止点（数据持续可信展示，无 --% 或清空风险），若产品希望“启动必刷”可在门控中排除启动场景；③ 门控阈值为启发式（stableInterval/staleAfterInterval 复用既有常量），无服务端语义背书。

### Loop 11 — 刷新协调统一化收尾：全量验证、签名安装验收与发布提交

- **日期**：2026-08-21
- **问题**：Loop 10 的刷新协调改动尚有未闭环验证门（全量测试在波动环境下的稳定结论、`./script/build_and_run.sh --verify` 签名安装验收）且未入库。
- **证据**：用户指令“运行一次 loop，然后本机签名安装运行 app，直接合并提交推送”。Loop 10 遗留项见其“剩余风险”与 `docs/superpowers/plans/refresh-coordination-unification.md` Next 段。
- **修改**：无业务代码改动（纯验证 + 记录 + 版本控制操作）。本轮新增本条 Loop 记录；工作区包含 Loop 10 的全部待提交改动（2 个源文件、1 个测试文件、3 个文档、1 个实施计划）。
- **验证**：
  - `swift test` 全量：**577/0 全部通过**（安静环境下连预存在时序敏感的 SingleInstanceCoordinatorTests 也全绿，证实该族失败为环境负载相关的边际时序问题，非代码缺陷）。
  - `./script/build_and_run.sh --verify`：通过。安装路径 `/Applications/CodexMonitorNative.app`，最终 owner PID 47621（安装版取得单实例所有权，dist 旧副本让位重定向），主应用与 Widget 代码签名及 App Group entitlements 验证通过，Widget 版本 0.1.0 (1) 绑定正确，运行版本 0.1.0 (1)。
  - 安装后进程确认：PID 47621 运行中。
- **剩余风险**：SingleInstanceCoordinatorTests 在高负载下仍可能间歇失败（预存在，建议后续独立 Loop 注入时钟改造）；其余无新增风险。

### Loop 12 — Popover 额度区降密：状态徽标去重 + 重置额度卡单行化

- **日期**：2026-08-21
- **问题**：Popover 额度展示信息密度过高：① 每张额度卡片右上角状态徽标（"最新"/"历史缓存"/"刷新中"/"已过期"/"上次数据"）与顶部状态行或百分比旁"（历史缓存）"标注重复；② 重置额度卡固定占用两行（次数行 + 分隔线 + 最早到期行），倒计时/授予时间等低频细节常驻显示，推高面板默认高度、增加单屏文字元素数量。
- **证据**：用户目标"优化现有额度展示体验，降低信息密度并提升日常使用效率"（loop.md §2 用户反馈类证据）。代码路径：`QuotaGaugeView` 无条件渲染 `item.stateText`（`QuotaSummaryView.swift`）；`resetCreditsSection` 固定两行 + Divider；`StatusPopoverFormatting.quotaWindowStateText` 的 live/cached 新鲜度取值与 header `titleSummary` 及 `historyCaption` 语义重复；辅助功能契约 `quotaCardState` 已独立携带 stateText，不依赖视觉徽标。
- **修改**：（Loop 12 二次修订：徽标 Text 追加 `.minimumScaleFactor(0.75)`，消除窄卡内"已恢复，待刷新"截断）新增 `Sources/CodexMonitorNative/UI/QuotaCardDensityPolicy.swift`（`showsStateBadge(fieldState:trustedPercent:resetAt:now:)`：invalid/unavailable 与已过重置截止点（严格 `now < deadline` 边界，与 `makeQuotaWindowDisplayItem.isBeforeReset` 一致）的窗口保留徽标，live/cached 正常新鲜度徽标隐藏）；`Sources/CodexMonitorNative/UI/QuotaSummaryView.swift`（① `QuotaGaugeView` 按策略条件渲染状态徽标，辅助功能契约 `quotaCardState` 不变仍携带 stateText；② 重置额度卡两行 + Divider 合并为单行：次数居左主文本 + 行尾次要文本"最早到期 <时间>/timingLine/--"，倒计时与授予细节保留在既有"全部 N"披露行内；删除无引用的 `featuredResetCreditSummary`）；`Tests/CodexMonitorNativeTests/QuotaCardDensityPolicyTests.swift`（+6 确定性测试：live/cached 可信值隐藏冗余徽标、无重置时间隐藏、异常态保留、过截止点保留、边界语义锁定）；`QA_CHECKLIST.md` C.5 一条人工门禁描述同步为新单行布局。不改共享格式化层、Widget 投影与菜单栏；改动文件均不在 Widget pbxproj 双编译清单。
- **验证**：
  - `swift test --filter QuotaCardDensityPolicyTests`：6/0 通过（首轮抓出边界断言写反：生产语义 `now == deadline` 即视为已到重置点，已按 `QuotaTemporalSemantics.isPending` 严格边界修正测试）。
  - `swift test` 全量：583 执行（577+6），失败 6 全部位于 `SingleInstanceCoordinatorTests` 预存在时序敏感族。基线对照：`git stash -u` 后干净树隔离复跑同套件仍失败 9/25，且本树全量 6 失败 → 本树隔离 16 失败 → 干净树隔离 9 失败，失败集合随运行变化——证实为环境负载相关的预存在波动（Loop 10 已记录同类现象），与本轮不相交模块改动无关。
  - `swift build -c debug`：exit 0。
  - **渲染视觉验证**（临时 XCTest + NSHostingView 离屏渲染 PNG，验证后已删除）：① 正常成功快照——改动前卡片带"最新"徽标、重置区两行含"剩余 45分"，改动后徽标消失、重置区单行"重置次数 3 · 最早到期 今天 12:30 · 全部 2"，面板高度 370pt→337pt（@2x 渲染 740→674px，净降 33pt），额度区文字元素 14→11；② 已过重置点场景——"--"与"已恢复，待刷新"徽标按设计保留，正常周额度卡无徽标；发现徽标在窄卡内截断为"已恢复，待…"，随即给徽标 Text 补 `.minimumScaleFactor(0.75)` 并复渲染，本地 Vision OCR 确认完整显示"已恢复，待刷新"。OCR/视觉读取分别经 modlens 桥与 macOS Vision 框架完成。
  - 最终全量 `swift test`：**583/583 全部通过，0 失败**（安静环境；此前波动运行中的 SingleInstanceCoordinatorTests 失败亦全数消失，进一步证实其负载相关属性）。
  - 未运行 `./script/build_and_run.sh --verify`：不涉及打包/签名/安装/Widget 集成改动，不满足运行门槛。
  - QA 人工桌面检查未执行：本环境无 GUI。真实 Popover 的交互手感、展开"全部 N"后布局需发布前按 QA_CHECKLIST C.4/C.5 人工确认（离屏渲染已覆盖静态布局证据）。
- **剩余风险**：① 徽标隐藏依赖"header 状态行已表达快照级新鲜度"这一前提，若未来 header 简化需同步复核策略；② 重置额度单行的行尾次要文本在极窄窗口依赖 `minimumScaleFactor(0.78)` 缩放，极端本地化文案可能触底；③ SingleInstanceCoordinatorTests 预存在时序波动仍未修复（独立子系统，建议单独 Loop 用注入时钟改造）。后续降密候选（未处理）：周额度趋势卡 sparkline 默认折叠、额度卡"恢复/还需"两行合并的排版方案。

### Loop 13 — 额度卡状态切换体验：消除状态迁移视觉跳动

- **日期**：2026-08-21
- **问题**：额度卡在刷新/缓存/异常/恢复状态之间切换时存在视觉跳动：① header 指示器 `if refreshing { ProgressView } else { Image }` 视图身份硬切换，每次刷新周期两次闪变且相邻更新时间戳可能因固有尺寸不同位移；② 卡片内百分比数字与进度条宽度变化无任何动画，刷新成功/恢复后瞬间跳变；③ 恢复边界徽标出现 + 百分比翻 "--" 全部瞬变；④ 窗口 state live↔cached/unavailable 翻转导致整张卡片从网格消失/重现，网格瞬时重排。
- **证据**：用户目标"优化现有额度卡状态切换体验，减少刷新、缓存、异常和恢复状态之间的视觉跳动，提升状态变化时的信息层级和交互一致性；保持现有额度逻辑、Widget、VoiceOver、持久化和测试契约不变"（loop.md §2 用户反馈类证据）。代码路径：`StatusPopoverView.swift` L147-155（header if/else 指示器）；`QuotaSummaryView.swift` L242-252（caption 独立行）、L253-271（进度条/恢复行无动画）；全 UI 层无 `.animation`/`.contentTransition`（grep 证实仅 disclosure/hover 有局部动画）。测试契约核查：`StatusPopoverBehaviorTests` 仅断言辅助功能字符串与格式化函数，无视图结构断言；`QuotaGaugeView` 仅被 popover 的 `QuotaSummaryView` 使用，不在 Widget pbxproj 双编译清单。
- **修改**：`Sources/CodexMonitorNative/UI/QuotaSummaryView.swift`（+18/-0：① `QuotaSummaryView` 外层 VStack 加 reduce-motion 感知的 `.animation(_:value: quotaItems.map(\.id))`，卡片插入/移除原地过渡而非网格瞬断，键控卡片 id 故披露开关与倒计时 tick 不触发；② `QuotaGaugeView` 内容 VStack 加 `.animation(_:value: item)` 作用域动画覆盖进度条宽度/caption 与徽标插入移除/文本替换；③ 百分比 Text 加 `.contentTransition(.numericText())` 数字滚动）；`Sources/CodexMonitorNative/UI/StatusPopoverView.swift`（+19/-5：header 指示器改固定 16×16 ZStack 交叉淡入淡出，消除视图身份硬切换与时间戳位移）。三处动画均遵循代码库既有 `@Environment(\.accessibilityReduceMotion)` → nil 模式。不改辅助功能契约（label/value/hint/identifier 全部原样）、格式化层、Widget 投影、菜单栏、持久化；改动文件均不在 Widget pbxproj 双编译清单。
- **执行期证据修正**：原计划包含把 `historyCaption` 行移至百分比同行内联，但核查 `preferredCurrentQuotaWindows`/legacy fallback 均只保留 `.isCurrent`（== `.live`）窗口（自 `18d7674` 起），生产路径产出的 display item 的 `fieldState` 恒为 `.live`，caption 永远为 nil——该行是死路径，内联重构属无观察效果改动，按"禁止无证据修改"回退；真实发生的缓存态跳动是整卡消失/重现的网格重排，改用 id 键控动画处理。
- **验证**：
  - `swift build -c debug`：exit 0。
  - 窄相关测试 `--filter StatusPopoverBehaviorTests --filter QuotaCardDensityPolicyTests --filter StatusPopoverFormattingTests`：79/0；追加 Widget 投影相关后 140/0。
  - **渲染视觉验证**（临时 XCTest + NSWindow 层级 NSHostingView 离屏渲染 PNG @2x + modlens/Vision OCR，验证后临时文件已删除）：四状态静态布局高度与改动前一致（成功 483pt、失败 506pt），动画修饰符不影响静态布局；A 周 window 翻 cached→整卡按产品语义消失、余卡完好；B 正常双卡无徽标无 caption；C networkFailed 保留 42%/96% 可信数字 + header「网络异常」+ 底部「读取失败，显示上次快照」；D 真实 in-flight 刷新（阻塞式 service 驱动 `status=refreshing`）header「读取中」+ spinner + 数字保留 + 底部「读取中，暂用上次快照」。
  - `swift test` 全量 ×3：583 执行，失败分别为 9/14/17 个断言，全部位于 `SingleInstanceCoordinatorTests` 预存在时序敏感族且失败集合随运行波动；基线对照：`git stash -u` 干净树隔离复跑同套件失败 10/25（劣于本树 9/25）——证实为环境负载相关的预存在波动（Loop 10/11/12 已三次记录同类现象），与本轮不相交模块改动无关。
  - 未运行 `./script/build_and_run.sh --verify`：不涉及打包/签名/安装/Widget 集成改动，不满足运行门槛。
  - QA 人工桌面检查未执行：本环境无 GUI。动画手感（时长/曲线是否合意）、Reduce Motion 开关行为需发布前按 QA_CHECKLIST 人工确认（离屏渲染已覆盖静态布局证据；动画语义由作用域键控保证只影响状态迁移）。
- **剩余风险**：① 面板底部 `freshnessSummary` 行在刷新开始/结束与失败/恢复时插入/移除会使面板高度变化 ±23pt（C/D 渲染实测），属 NSPopover contentSize 更新，本轮未动（该行是失败态下"显示上次快照"的唯一文字载体，删除会丢信息；如需消除需在 PopoverController 层做高度动画，超出本轮最小 diff）；② 动画时长 0.28s/0.18s 为启发式，待人工 QA 手感校准；③ SingleInstanceCoordinatorTests 预存在时序波动仍未修复（独立子系统，建议单独 Loop 用注入时钟改造）。
- **验收与发布（用户指令：运行一次 loop 后本机签名安装运行 app，直接合并提交推送）**：
  - 发布前全量 `swift test`：583 执行，仅 `SingleInstanceCoordinatorTests` 预存在时序族 2 用例/10 断言失败（本会话内已用干净树基线证明为环境负载相关，与本轮改动无关），其余全部通过。
  - `./script/build_and_run.sh --verify`：通过（exit 0）。主应用与 Widget appex codesign 校验 valid on disk + satisfies Designated Requirement；安装至 `/Applications/CodexMonitorNative.app` 版本 0.1.0 (1)；运行进程 PID 50421（12:38:45 启动，路径为安装版），Widget 扩展进程同步运行。
  - 随后按用户指令 commit 并 push 本轮全部改动（源码 2 文件 + `.agent/` 记录 2 文件）。


