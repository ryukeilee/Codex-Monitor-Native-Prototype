# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Codex Monitor Native 是一个常驻 macOS 菜单栏的 Codex 额度监视器（Swift 6，macOS 14+，SwiftUI/AppKit），另有一个 WidgetKit extension 工程。仓库重点不是堆功能，而是让以下行为稳定可验证：

- 菜单栏标题只显示可信周额度剩余百分比，无可信周窗口时显示 `--%`。
- Popover、tooltip、Widget 通过同一条展示投影呈现额度窗口、恢复时间与数据可信度。
- 真实数据刷新失败时保留上次成功快照，不把菜单栏清空。

详细规范见 `AGENTS.md`（模块清单、测试领域表、Review/Commit 约定）；用户可见行为文档见 `README.md`。两者的历史测试数量可能早于当前代码，以命令实际结果为准。

维护现有功能时，按 `.agent/loop.md` 的证据驱动 Maintenance Loop 执行（Observe → Evidence → Decide → Execute → Verify → Record）；项目级 Agent 边界见 `.agent/rules.md`，长期项目知识见 `.agent/memory.md`，最近 Loop 记录见 `.agent/history.md`。

## 常用命令

- `swift build -c debug` / `swift build -c release` — 构建主应用。
- `swift test` — 全量 XCTest（当前 525 个，0 失败）。
- `swift test --filter <TestClass>` / `swift test --filter <TestClass>/<testMethod>` — 迭代时跑最窄子集。
- `./script/build_and_run.sh` — 构建主应用 + widget，打包签名并启动。
- `./script/build_and_run.sh --verify` — 安装验收流程：会在 `INSTALL_APP_PATH` 处替换安装、启动并验证版本/签名/widget 注册；会停掉现有 App。
- `./script/build_and_run.sh --logs` / `--telemetry` — 流式查看进程日志 / 子系统遥测。
- 环境变量：`BUILD_CONFIGURATION=debug|release`、`INSTALL_APP_PATH=...`、`CODEX_BIN`/`CODEX_EXECUTABLE`、`CODEX_MONITOR_FORCE_MOCK=1`、`CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1`、`CODEX_MONITOR_FORCE_REFRESH_FAILURE=1`。

真实数据依赖本机 `codex`（支持 `codex app-server`），App 用其默认 stdio 传输，不假设存在 `--stdio` 参数。

## 架构

### 两个构建目标
- 主应用：SwiftPM executable target `Sources/CodexMonitorNative`。
- Widget extension：`CodexMonitorWidgetExtension.xcodeproj`，在 SwiftPM 之外。它直接编译主应用中挑选的少量源码文件；**权威文件清单是 Xcode 工程的 Sources build phase（`project.pbxproj`），不是 SwiftPM target 声明**。改动被 widget 复用的 `Shared/` 文件时，必须保证两种编译上下文都兼容，并在 pbxproj 中同步增删；改 persisted 模型还需保持 payload 兼容。

### 展示投影（单一来源）
一条链喂给三个展示面（菜单栏、Popover、Widget）：

`AppState` → `AppStateEvent` → `QuotaPresentationSnapshot`(= `WidgetDisplayState`) → `StatusPopoverFormatting.quotaWindowDisplayItems` → 消费方（Popover/tooltip 直接消费；Widget 再经 `WidgetPresentation` 按小/中尺寸容量 1/3 做确定性选择并显示 `+N` 溢出）。

改展示逻辑时，Popover、tooltip、Widget 三处测试都要覆盖（`StatusPopoverFormattingTests`、`StatusPopoverBehaviorTests`、`WidgetPresentationTests`），顺序、过滤、标签、进度、恢复时间、溢出语义必须对齐。

### 刷新管线
`RefreshScheduler`（自适应节奏 + 失败退避 + 暂停原因）→ `AppState`（刷新合并/coalescing、账号边界校验、快照 staging）→ `QuotaRefreshService`（真实 provider + mock，partial 合并，reset credits 富化）→ `RealQuotaProvider`（codex 可执行文件发现 + app-server RPC）→ `QuotaSnapshot`。

- 默认定时 5 分钟，连续失败退避到 10/15 分钟；手动、唤醒、网络恢复刷新可绕过退避。
- `AppState` 是 RPC 执行、持久化、账号边界校验、错误分类的唯一所有者；`RefreshScheduler` 只决定何时触发。

### 账号边界（fail-closed）
真实快照绑定 `QuotaAccountBoundary`：从 `CODEX_HOME/auth.json` 读当前账号与登录会话，只持久化域分隔的 SHA-256 指纹。缓存真实快照仅在边界仍与当前身份匹配时才允许展示；登出、重登、切号或身份不可确认时清空旧快照显示 `--%`，绝不把 A 账号额度当成 B 账号的。跨刷新期间身份变化也必须失败关闭。

### 持久化
两条存储都用 `PersistenceEnvelope`（formatVersion + revision + SHA-256 checksum + 新旧互读兼容）：

- `SnapshotStore`：App 自身状态，UserDefaults（`codex.monitor.native.prototype.snapshot`），主键 + backup + corrupt 三份，写入带校验与回滚。
- `WidgetDisplayStateStore`：Widget 共享状态，App Group 文件（`group.com.ryukeilee.CodexMonitorNativePrototype/WidgetDisplayState.json`），flock 事务锁 + backup 恢复 + 旧格式迁移。Widget 端只读该文件，用 `savedAt`（本地写入时间）而非服务端 `refreshedAt` 判断过期，并带时钟偏斜容差。

必须保持的写保护：非真实数据不得覆盖真实数据（除非显式失效）；更旧真实快照不得覆盖更新的（除非显式允许或账号边界切换）；新版本格式不得被旧版本覆盖。改 persisted 模型必须验证旧数据迁移与老读者兼容。

### 安装 / 单实例仲裁
启动时 `AppInstallationAuthority` 校验当前安装身份，`SingleInstanceCoordinator` 做单实例所有权仲裁（redirect 到首选安装、拒绝无效安装、版本与签名锚点比较）。`--verify` 安装流程是打包、签名、安装、验证的唯一验收入口。改动 `App/` 生命周期或 `System/` 集成时，参考 `AppDelegateLifecycleTests`、`SingleInstanceCoordinatorTests`、`AppInstallationAuthorityTests`。

## 开发注意

- **Swift 6 严格并发**：`@MainActor` 在 `AppDelegate`、`AppState`、`WidgetTimelineBridge` 等类型上显式标注；新增跨线程类型注意 `Sendable`。
- **时间语义**：`QuotaTemporalSemantics` 是墙钟语义唯一来源（新鲜度、恢复、过期、时钟回拨）。测试注入 `now` 闭包推进确定性时钟，不依赖 run loop；`RefreshScheduler` 也是可注入时钟的。
- **不变量**：不把 mock/演示数据当真实数据展示；失败刷新不清空上次成功快照；菜单栏不用 5 小时/月/未知窗口替代周额度。
- **构建产物**：`dist/`、`.build/`、`build/` 是生成输出，不提交。
- **凭据**：不提交 token、auth.json 内容或原始账号标识；只持久化最小指纹。

## 验证纪律

- 迭代先跑最窄测试：`swift test --filter StatusPopoverFormattingTests`。
- 交付前跑 `swift test` + `swift build -c debug`。
- 改动打包、签名、安装、widget 集成时跑 `./script/build_and_run.sh --verify`。
- 改菜单栏/Popover/Widget 可见行为时对照 `QA_CHECKLIST.md`，并如实报告未执行的手动检查项。
- 对回归不变量（上面的三条）的问题，视为正确性问题而非外观差异。
