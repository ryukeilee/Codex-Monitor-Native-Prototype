# Memory（长期项目知识）

本文件只保存稳定架构信息、已确认设计、已解决的重要问题与已验证区域。**不保存**单次修改细节、临时日志、猜测。详细信息以 `AGENTS.md`、`CLAUDE.md` 为权威来源，本文件是面向维护 Loop 的长期摘要。内容有变化时（如模块迁移、新不变量），只在这里更新，不记录过程。

最后更新：2026-08-12（新增账号隔离的周额度趋势架构）

---

## 稳定架构事实

### 构建与运行
- macOS 14+，Swift 6（严格并发），SwiftUI/AppKit 菜单栏常驻应用。
- 主应用：SwiftPM executable target `Sources/CodexMonitorNative`（`Package.swift`）。
- Widget extension：`CodexMonitorWidgetExtension.xcodeproj`（SwiftPM 之外），直接编译选定的少量主应用源码；**权威文件清单是 pbxproj 的 Sources build phase**。
- 打包/签名/安装/验收唯一入口：`./script/build_and_run.sh`（含 `--verify`、`--logs`、`--telemetry`）。
- 构建产物 `dist/`、`.build/`、`build/` 是生成输出，不提交。

### 模块划分
- `App/` — 生命周期、`@main`、AppDelegate、单实例所有权、安装身份重校验、popover/激活、状态栏、widget timeline bridge。
- `Core/` — 额度刷新、调度、快照持久化、codex RPC 发现、真实/mock provider。
- `UI/` — SwiftUI popover、装饰组件、reactor 可视化、格式化、交互策略、self-check。
- `Shared/` — `AppState`、`WidgetDisplayState`、数据源协议、额度决策/状态类型、健康诊断、`AppLogger`、widget 展示。
- `System/` — 单实例仲裁、安装身份/权威、开机启动、睡眠唤醒、网络可达性、系统时钟监控、codex 认证边界观察。
- 测试：`Tests/CodexMonitorNativeTests`（XCTest，544 个，0 失败）。

### 已确认设计（不要重新质疑）
- **单一展示投影**：`AppState → AppStateEvent → QuotaPresentationSnapshot(=WidgetDisplayState) → StatusPopoverFormatting.quotaWindowDisplayItems → Popover/tooltip 直接消费，Widget 经 `WidgetPresentation` 按尺寸容量 1/3 确定性选择并显示 `+N` 溢出`。菜单栏只显示可信周剩余百分比或 `--%`。
- **刷新管线**：`RefreshScheduler`（自适应节奏 + 失败退避 + 暂停原因，可注入时钟）→ `AppState`（刷新合并、账号边界校验、快照 staging 的唯一所有者）→ `QuotaRefreshService`（真实+mock，partial 合并，reset credits 富化）→ `RealQuotaProvider`（codex 发现 + app-server RPC，默认 stdio 传输，不假设 `--stdio`）→ `QuotaSnapshot`。默认 5 分钟，失败退避 10/15 分钟；手动/唤醒/网络恢复可绕过退避。
- **账号边界 fail-closed**：真实快照绑定 `QuotaAccountBoundary`，只持久化域分隔 SHA-256 指纹；身份匹配才允许展示，否则清空显示 `--%`；跨刷新身份变化也失败关闭。持久化写失败不得复活失效快照；Widget 端主机显式失效时必须丢弃旧真实恢复源。
- **持久化**：`PersistenceEnvelope`（formatVersion + revision + SHA-256 checksum + 新旧互读兼容）。`SnapshotStore` 用 UserDefaults（主键+backup+corrupt 三份，带校验回滚）；`WidgetDisplayStateStore` 用 App Group 文件（flock 事务锁 + backup 恢复 + 旧格式迁移），Widget 端以 `savedAt` 判断过期并带时钟偏斜容差。写保护：非真实数据不得覆盖真实数据；更旧真实快照不得覆盖更新的；新格式不得被旧版本覆盖。
- **时间语义**：`QuotaTemporalSemantics` 是墙钟语义唯一来源（新鲜度、恢复、过期、时钟回拨）；测试注入 `now` 闭包，不依赖 run loop。
- **周额度趋势**：主 App 通过独立的 `UsageTrendStore` 按账号/会话边界保存可信真实周额度样本，不进入共享 Widget payload。`UsageTrendAnalyzer` 只分析同一连续序列；额度重置与异常跳变都会开启新基线，至少 3 个样本且跨度 10 分钟后才计算速度与耗尽预测。
- **安装/单实例**：`AppInstallationAuthority` 校验安装身份；`SingleInstanceCoordinator` 仲裁单实例所有权（redirect 首选安装、拒绝无效安装、版本与签名锚点比较）。

## 已解决的重要问题（避免重复调查）

- Widget 必须沙箱化并签名（非 ad-hoc），否则 pkd 拒绝注册、不在 widget 画廊出现；排障步骤见 `AGENTS.md` "Widget Extension Signing & Registration"。
- 真实刷新失败保留上次成功快照并表面化失败类型；菜单栏不清空（`--%` 仅当无可信周窗口）。
- Widget 自动刷新以本地写入时间 `savedAt` 而非服务端 `refreshedAt` 判断新鲜度。

## 已验证区域（避免重复检查）

- 测试领域表（刷新/RPC、账号边界、持久化、调度/生命周期、单实例、开机启动、UI 展示、Widget 时间线、重置额度、确定性故障、刷新一致性、额度决策）见 `AGENTS.md`；新增改动按表内对应文件补测试。
- 交付前门槛：`swift test` + `swift build -c debug`；`--verify` 仅在打包/签名/安装/Widget 改动时运行（会替换已安装 bundle）。

## 待确认/变更敏感区（改动前必读）

- 被 Widget 复用的文件变更必须同时验证两个编译上下文并同步 pbxproj。
- 持久化模型变更必须验证旧数据迁移与老读者兼容。
- `AGENTS.md` 中的测试数量（544）与 `CLAUDE.md` 中的（525）可能不同步，以命令实际结果为准。
