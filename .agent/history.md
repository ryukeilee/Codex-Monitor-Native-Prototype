# History（Maintenance Loop 记录）

本文件记录每次 Maintenance Loop 的执行结果。每次 Loop 结束必须追加一条记录（字段见 `.agent/loop.md` 第 6 节）。日常 Loop 只读本文件，不主动读取 `.agent/archive/`。

## 维护规则

- 只保留最近 **10** 次 Loop 记录。
- 更早记录移动到 `.agent/archive/`（建议按区间命名，如 `loop-001-015.md`），并在下方"归档索引"保留跳转。
- 记录按 Loop 编号倒序或正序排列均可，但必须自增且不重复。

## 归档索引

（暂无归档）

---

## Loop 记录

### Loop 0 — 基础设施初始化（非维护 Loop）

- **日期**：2026-08-09
- **类型**：基础设施搭建（非功能维护，不进入 Observe/Decide/Execute 流程）
- **内容**：建立 `.agent/` 维护循环基础设施：`loop.md`、`rules.md`、`memory.md`、`history.md`、`archive/`。
- **修改**：仅新增 `.agent/` 目录与 Markdown 文件；未改动任何业务代码、测试、构建脚本。
- **验证**：`git status` 确认无既有文件被覆盖；未运行测试（无代码改动，不影响构建）。
- **剩余风险**：无。后续首次真实维护 Loop 从编号 1 开始。

---

### Loop 0.1 — 基础设施完善：发现路径与文档缺口补齐（非维护 Loop）

- **日期**：2026-08-09
- **类型**：基础设施完善（非功能维护，不进入 Observe/Decide/Execute 流程）
- **内容**：
  - `AGENTS.md` 新增 "Maintenance Loop" 小节、`CLAUDE.md` 项目概览新增一行，指向 `.agent/loop.md`，补齐未来智能体的发现路径（此前全仓 Markdown 均未引用 `.agent`）。
  - `.agent/loop.md` 加法补齐两处缺口：Decide 节增加"问题选择要求（有明确依据 / 可以验证 / 修改范围可控）"与"连续维护同一模块须有新证据"；Record 节增加"本轮未修改时同样必须记录检查范围、未发现高价值问题的原因、验证状态"。
- **修改**：仅文档加法编辑（`AGENTS.md`、`CLAUDE.md`、`.agent/loop.md`、`.agent/history.md`）；未改动任何业务代码、测试、构建脚本。
- **验证**：`git status --short` 与 `git diff --stat` 确认改动仅限上述文档（`Sources/`、`Tests/`、`script/`、`Assets/`、`Package.swift`、`*.pbxproj` 无改动）；`swift build -c debug` exit 0。
- **剩余风险**：无。

---

### Loop 1 — 无有效证据，本轮不修改

- **日期**：2026-08-09
- **问题**：未发现可处理的高价值问题，按 `loop.md` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - `git status` / `git log --oneline -10` / `git diff --stat`：工作区仅有 Loop 0/0.1 的 4 个文档文件未提交（`.agent/history.md`、`.agent/loop.md`、`AGENTS.md`、`CLAUDE.md`），无任何业务代码、测试或脚本改动；最新提交为 `6d3faa2 docs: establish evidence-driven maintenance loop infrastructure`。
  - 全量测试 `swift test`：544 个测试，0 失败（与 memory.md 记录一致）。
  - `swift build -c debug`：构建通过（exit 0）。
  - `rg -n "TODO|FIXME|HACK" Sources Tests`：无匹配。
  - 已知问题文档 `VERIFICATION.md` / `QA_CHECKLIST.md` / `README.md`：其中未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、手动刷新 UX、键盘与辅助功能、登录项迁移等），非代码缺陷，不属于本 Loop 的修改对象。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：`swift test`（544/0 通过）、`swift build -c debug`（exit 0）已执行；`./script/build_and_run.sh --verify` 与 QA 人工检查未运行——本轮无代码改动，不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake 等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 2 — 无有效证据，本轮不修改

- **日期**：2026-08-11
- **问题**：未发现可处理的高价值问题，按 `loop.md` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - `rtk git status`：工作区 clean，无未提交修改、无未跟踪文件；`rtk git diff --stat` 为空。
  - `rtk git log --oneline -10`：最新提交 `1bd17cc docs: complete maintenance loop docs and record loop sessions`，均为已完成工作，无在途分支或未完成事项。
  - 全量测试 `rtk swift test`：544 个，0 失败（2026-08-11 05:45 执行，与 memory.md 记录一致）。
  - `rtk rg -n "TODO|FIXME|HACK" Sources Tests docs`：无匹配。
  - 已知问题文档 `VERIFICATION.md` / `QA_CHECKLIST.md`：未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Popover 键盘与辅助功能、Login Item Migration、Cross-Copy Activation 可视检查等），非代码缺陷，不属于本 Loop 的修改对象。
  - 应用日志：App 正在运行（PID 1025），`log show --last 30m` 无 error 级日志。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工发布门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：`swift test`（544/0 通过）已执行；`swift build -c debug` 未运行（本轮无代码改动，无构建变化）；`./script/build_and_run.sh --verify` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、登录项迁移、跨副本可视检查等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 3 — 无有效证据，本轮不修改

- **日期**：2026-08-11
- **问题**：未发现可处理的高价值问题，按 `loop.md` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - `git status`：工作区 clean，无未提交修改、无未跟踪文件；`git log --oneline -10`：最新提交 `docs: record loop 2 maintenance session (no code change)`，无在途分支或未完成事项。
  - 全量测试 `swift test`：544 个，0 失败（2026-08-11 10:04 执行，与 memory.md 记录一致）。
  - `rg -n "TODO|FIXME|HACK" Sources Tests docs`：无匹配。
  - 已知问题文档 `VERIFICATION.md` / `QA_CHECKLIST.md`：未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Real/Cached/Failure Presentation、Dynamic Quota Window Presentation 等），非代码缺陷，不属于本 Loop 的修改对象。
  - 应用日志：App 正在运行（PID 1025），`log show --last 24h` 无 error/fault/crash 级别日志。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档中的未验证项属人工发布门禁而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：`swift test`（544/0 通过）已执行；`swift build -c debug` 未运行（本轮无代码改动，无构建变化）；`./script/build_and_run.sh --verify` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、真实/缓存/失败呈现等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 4 — 无有效证据，本轮不修改

- **日期**：2026-08-12
- **问题**：未发现可处理的高价值问题，按 `loop.md` §2/§3 结束本轮，不修改代码。
- **检查范围**（Observe 阶段）：
  - `git status`：工作区 clean，无未提交修改、无未跟踪文件；`git diff --stat` 为空；`git log --oneline -10`：最新提交 `21efe8a docs: record loop 3 maintenance session (no code change)`，无在途分支或未完成事项。
  - 全量测试 `swift test`：544 个，0 失败（2026-08-12 16:27 执行，与 memory.md 记录一致）。
  - `rg -n "TODO|FIXME|HACK" Sources Tests docs`：无匹配。
  - 已知问题文档 `VERIFICATION.md` / `QA_CHECKLIST.md` / `README.md`：自 `bfa11fc` 后无修改；未勾选项均为人工桌面行为检查（Full-Screen Space、Real Sleep/Wake、Manual Refresh UX、Real/Cached/Failure Presentation 等），非代码缺陷。
  - 应用日志：App（PID 1025）与 Widget（PID 1023）自 2026-08-11 09:00 起连续运行；`log show --last 24h` 中应用 subsystem 无 error/fault/crash 级日志。唯一 error 级输出来自本次 `swift test` 的 xctest 进程：`Launch at login registration/unregistration failed（SMAppServiceErrorDomain 错误12/7）` 与 `UserDefaults Not updating lastKnownShmemState`。经核实均属 `LaunchAtLoginManagerTests` 预期失败路径模拟与测试隔离域噪音（测试文件对 SMAppServiceErrorDomain 的注册/注销失败、重试、修复路径有完整断言，544/0 通过），非应用缺陷。
  - 用户反馈：本次会话仅要求执行一次 Loop，无具体问题场景。
- **未发现高价值问题的原因**：按 §2 有效证据清单逐项对照——无可复现 Bug、无测试失败、无行为异常（相对 Product Invariants）、无用户反馈、无带代码路径证据的稳定性/性能风险、无测试缺口（AGENTS.md 测试领域表各领域均有覆盖文件）。文档未验证项与测试进程日志均属人工门禁/预期模拟而非代码证据，禁止以"顺手优化"或猜测式修改替代。
- **验证状态**：`swift test`（544/0 通过）已执行；`swift build -c debug` 未运行（本轮无代码改动，无构建变化）；`./script/build_and_run.sh --verify` 与 QA 人工检查未运行——不涉及打包/签名/安装/Widget 集成或可见行为变更，不满足运行门槛。
- **剩余风险**：无新增风险；遗留的人工桌面验证项（Full-Screen Space、Real Sleep/Wake、登录项迁移等）继续由发布前人工门禁覆盖，不构成本 Loop 的修改依据。

---

### Loop 5 — noAvailableCredits 被错误归类为详情获取失败

- **日期**：2026-08-13
- **问题**：账号当前无可用重置额度（正常业务状态）被当作"详情获取失败"处理：Popover 显示"详情失败：没有 available credits"，且真实应用每 15 分钟记录一条 error 级日志 `Reset credits detail fetch unavailable (没有 available credits); using app-server count only`，持续污染错误监控。
- **证据**：`log show --last 24h`（PID 16536，2026-08-13 00:22–13:12 连续 60+ 条，间隔 15 分钟 = `AdaptiveRefreshCadencePolicy.stableInterval`）；`ResetCreditsDetailProvider.parsePayload` 对 credits 数组无 available 条目抛 `noAvailableCredits`，与网络故障共用同一 `.unavailable` + diagnostic 降级路径（`QuotaRefreshService.enrichResetCreditsDetails` catch 分支）；对比 UI 对 `.detailed` + count==0 有专门中性文案"当前没有可用 reset credit"、`.appServerCountOnly` 本就是中性状态。
- **原因**：`noAvailableCredits` 是服务端明确返回的正常状态（当前无可用重置额度），不是获取故障；错误分类不当导致误导文案与持续 error 级日志（`Logger.warning` 在本机 macOS 上经 unified logging 显示为 E/error 级，全项目一致，非本消息特有）。
- **修改**：`Sources/CodexMonitorNative/Core/QuotaRefreshService.swift`（enrichResetCreditsDetails catch 分支特判 `noAvailableCredits` 且无可复用详情时，返回中性 `.appServerCountOnly`、diagnostic 置 nil、不记录日志；有可复用详情时保持原有 `.unavailable` 降级不变，复用条件未动）；`Tests/CodexMonitorNativeTests/QuotaRefreshServiceTests.swift`（+2 测试：无复用详情 → 中性状态；有复用详情 → 保持 .unavailable，锁定边界行为；+1 测试桩 `NoAvailableCreditsProvider`）。未改 UI/格式化/Widget 文件、未改持久化 schema（`.appServerCountOnly` 是既有 case）。
- **验证**：`swift test --filter QuotaRefreshServiceTests`（13/0，含新增 2 测试）；`swift test --filter StatusPopoverFormattingTests --filter ResetCreditsDetailProviderTests --filter WidgetPresentationTests --filter WidgetTimelineBridgeTests`（132/0）；`swift test`（559/0，557+2）；`swift build -c debug`（exit 0）。
- **剩余风险**：当前运行的 App（PID 16536）仍是旧二进制，日志行为变化需下次启动/更新后生效，未实测新二进制下的日志输出；Popover 文案变化（"详情失败：没有 available credits" → "当前仅显示 Codex 提供的次数"）属于可见行为，未做 QA_CHECKLIST 人工桌面检查（本环境无 GUI 访问），已由 `StatusPopoverFormattingTests` 覆盖中性状态文案路径。不涉及打包/签名/安装/Widget 集成改动，未运行 `--verify`。

---

### Feature 1 — 周额度消耗趋势与耗尽预测

- **日期**：2026-08-12
- **类型**：用户明确授权的新功能开发（非 Maintenance Loop）。
- **目标**：基于真实额度刷新记录近期周额度变化，在主 App 展示趋势、当前速度、预计耗尽时间和距离重置时间，同时保持菜单栏与 Widget 行为兼容。
- **设计**：新增独立、账号/会话边界隔离的趋势历史；只采集可信真实周额度。至少 3 个连续样本且跨度 10 分钟后才预测；额度上升/重置时间跨周期会重建序列，短时间大幅下降、非重置式回升和乱序样本不进入原趋势。
- **修改**：新增 `Core/UsageTrend.swift`、`UI/UsageTrendFormatting.swift`、`UI/UsageTrendView.swift` 与 `UsageTrendTests.swift`；在 `AppState` 成功持久化状态后同步趋势，在 Popover 接入趋势卡片。首次安装验收发现共享 `StatusPopoverFormatting.swift` 引用了主 App 专用趋势类型，导致 Widget 双编译失败；随后将趋势格式化移至主 App 专用文件，未扩散 Widget target 依赖，也未修改菜单栏投影、Widget payload 或签名配置。
- **验证**：`swift test --filter UsageTrend`（10/0 通过）；`swift test`（554/0 通过）；`swift build -c debug`（exit 0）。首次 `./script/build_and_run.sh --verify` 在 Widget 编译阶段按预期暴露上述类型边界问题；修正后重新执行通过，确认 `/Applications/CodexMonitorNative.app` 正在运行，主 App/Widget 签名、App Group entitlements、版本、运行路径、单实例 owner、旧副本重定向及 Widget 绑定全部通过。Computer Use 无法捕获菜单栏 App 的 CGWindow（`cgWindowNotFound`），因此标准宽度布局、文字截断、VoiceOver 与实时分钟倒计时仍需按 `QA_CHECKLIST.md` 人工确认。
- **剩余风险**：耗尽时间是按最近连续样本的平均速度线性外推，不代表服务端保证；首次启用或重置/异常跳变后需等待至少 10 分钟和 3 次成功刷新。

---

### Feature 2 — 额度异常变化检测与提醒

- **日期**：2026-08-12
- **类型**：用户明确授权的新功能开发（非 Maintenance Loop）。
- **目标**：在可信真实周额度发生异常变化时检测并提醒，同时保持账号隔离、趋势重建、菜单栏和 Widget 行为不变。
- **设计**：复用 `UsageTrendHistory` 已有异常阈值；新增 `QuotaAnomaly` 事件承载前后样本。只有同一账号/会话边界内新接受的异常样本触发一次事件；已知重置、重复/乱序、mock 与身份不匹配数据均不提醒。主 App 使用 `UserNotifications` 请求 alert/sound 权限并投递即时通知，前台时也展示 banner；拒绝权限或投递失败只记录日志，不影响额度状态提交。
- **修改**：扩展 `Core/UsageTrend.swift` 返回结构化异常事件；在 `Shared/AppState.swift` 的可信趋势协调点发布事件；新增 `System/QuotaAnomalyNotifier.swift` 并在 `App/AppDelegate.swift` 接线；`UsageTrendTests.swift` 增加异常事件、重置/重复抑制、通知文案和单次发布测试。未修改 Widget payload、共享 Widget 源文件、持久化 schema、签名或安装配置。
- **验证**：`swift test --filter UsageTrend`（13/0 通过）；`swift test`（557/0 通过）；`swift build -c debug`（exit 0）；`git diff --check`（exit 0）；`./script/build_and_run.sh --verify` 通过，确认 `/Applications/CodexMonitorNative.app` 正在运行，主 App 本地 ad-hoc 签名、Widget Apple Development 签名及 sandbox/App Group entitlements、版本、运行路径、单实例 owner、旧副本重定向与 Widget 绑定全部通过。未人为制造真实账号额度异常，因此通知中心的实际权限弹窗与 banner 外观仍需人工确认。
- **剩余风险**：用户拒绝系统通知权限后不会收到提醒；异常阈值是确定性启发式规则，服务端未提供异常语义，提醒表示“建议确认”而非确认存在未授权使用。

---
