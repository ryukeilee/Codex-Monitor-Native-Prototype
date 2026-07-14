# Verification Summary

本文档只记录当前仓库状态下可复现的验证入口，并明确区分：

- 已由代码、测试或命令输出直接证明的事实
- 仍需在真实 macOS 桌面环境人工确认的行为

## Commands Run

本轮发布前收口实际执行：

```bash
swift build -c debug
swift test
./script/build_and_run.sh --verify
```

说明：

- `./script/build_and_run.sh --verify` 是统一安装验收入口：它会关闭旧实例、构建并签名 app 与 Widget、覆盖安装到 `/Applications/CodexMonitorNative.app`，启动最终安装包，并核对运行进程路径/版本及 `pluginkit` 的 Widget 路径。
- 本轮没有重新执行 `swift build -c release` 或 `./script/build_and_run.sh --telemetry`，因此它们不计入当前自动验证证据。

## Automated Evidence

以下内容有当前代码、测试或本轮命令结果作为直接证据：

- App 可以通过 SwiftPM 成功构建，`./script/build_and_run.sh --verify` 可完成覆盖安装，确认实际运行进程来自最终安装路径，并确认 Widget 注册路径属于该安装包。
- 菜单栏 App 以 `LSUIElement = true` 方式打包，无常规主窗口。
- 菜单栏标题策略只显示可信周额度百分比或 `--%`，不会用 5 小时、月或未知窗口替代周额度。
- Popover 包含：
  - 更新时间 / 最近尝试时间
  - 数据来源与刷新状态
  - 真实链路健康诊断
  - 手动刷新按钮
- Popover、status-item tooltip 与 Widget 共用同一个动态额度窗口投影：按 5 小时、周、月排序，只展示语义明确且当前可信的窗口。
- 投影只生成当前实时且可信的 item，并把百分比、进度、字段状态和恢复时间绑定在一起；同语义已知窗口只保留 canonical 来源，只有语义动态窗口缺失时才使用实时 legacy 5 小时/周字段补位。
- Popover 使用两列动态网格；窗口超过两行时切换到有高度上限的滚动视口，窗口集合变化通过 `StatusPopoverView` 的布局信号触发 `PopoverController` 重新测量。
- Widget 小尺寸容量为 1、中尺寸容量为 3；only-monthly 会成为真实 primary，unknown-only 不生成额度项。
- 真实刷新失败时会保留上次成功的真实快照，不会立即清空菜单栏数字。
- 真实链路错误可以区分为至少以下几类：
  - 需要登录 / 认证失败
  - 响应不可解析
  - 通用 RPC 失败
  - 等待首次真实请求 / 显示上次成功数据
- 启动后刷新、定时刷新、失败退避和 wake 后触发刷新都有测试覆盖。

当前测试直接覆盖的关键路径包括：

- 真实刷新成功后更新并持久化快照
- 认证失败时保留缓存并标记为需要登录
- 解析失败时保留缓存并标记为响应不可解析
- 恢复本地真实快照后，在首次请求前明确标记“显示上次成功数据”
- 连续失败退避
- 并发刷新去重
- scheduler tick
- sleep / wake notification wiring
- 动态投影稳定排序、known-kind 去重、legacy fallback 边界、未知/缓存/无效字段过滤与 reset 一致性
- Popover only-weekly、only-unknown、5 小时 + 周 + 月、多窗口行数与滚动信号
- Widget only-monthly、only-unknown、primary 选择和 overflow 计数
- 旧 Widget persisted payload 解码与 envelope 向后兼容

## Manual Verification Still Required

以下行为目前没有把“真实桌面交互结果”自动化，因此发布前仍需人工确认：

### 1. Full-Screen Space

步骤：

1. 运行 `./script/build_and_run.sh`。
2. 打开任意常规 app，例如 TextEdit 或 Safari。
3. 让该 app 进入全屏 Space。
4. 在全屏 Space 中点击菜单栏图标打开 Popover。
5. 点击 Popover 外部区域，确认其会像普通菜单栏面板一样关闭。
6. 再次打开 Popover，切回全屏 app，确认 Popover 不会卡成持续悬浮层。

预期结果：

- Popover 能在全屏 Space 中正常打开。
- Popover 会在失焦或外部点击后关闭。
- 全屏 app 仍是主要界面，Popover 不会异常悬浮。

### 2. Real Sleep / Wake

步骤：

1. 运行 `./script/build_and_run.sh`。
2. 让 App 先完成一次真实刷新，或至少准备好一个可见的真实快照。
3. 让 Mac 进入睡眠，再手动唤醒。
4. 唤醒后等待数秒，打开 Popover；如需辅助观察，可另开终端运行 `./script/build_and_run.sh --telemetry`。

预期结果：

- 唤醒后会触发一次刷新尝试。
- 如果刷新失败，菜单栏和 Popover 仍继续显示最近一次成功的真实快照。
- Popover 顶部状态与真实链路诊断能反映这次 wake 后请求结果。

### 3. Manual Refresh UX

步骤：

1. 运行 `./script/build_and_run.sh`。
2. 打开 Popover，点击“刷新”。
3. 观察按钮在刷新期间是否进入进行中状态。
4. 分别在成功路径和失败路径下观察刷新完成后的状态。
5. 如需稳定复现失败，可结合当前仓库支持的强制路径启动：

```bash
CODEX_MONITOR_FORCE_REFRESH_FAILURE=1 ./script/build_and_run.sh
```

预期结果：

- 刷新期间按钮不可重复触发。
- 成功时顶部状态更新为最新真实结果。
- 失败时仍显示上次成功数据，并在真实链路诊断中说明失败类型。

### 4. Real / Cached / Failure Presentation

步骤：

1. 分别准备以下场景：
   - 正常真实请求成功
   - 已存在真实缓存后再触发失败
   - 无真实快照时启动
2. 每个场景都打开 Popover，观察顶部状态与主体信息。

预期结果：

- 有可信周窗口时，菜单栏只显示该周额度百分比。
- 失败但有缓存时，Popover 明确写出“显示上次成功数据”。
- 无真实快照时，菜单栏显示 `--%`，Popover 不冒充真实额度。

### 5. Dynamic Quota Window Presentation

步骤：

1. 分别准备 only-weekly、only-monthly、only-unknown、5 小时 + 周 + 月、重复 known-kind 的快照或真实响应。
2. 打开 Popover，检查窗口顺序、未知窗口隐藏、重复来源去重、缓存/无效窗口隐藏和 reset 文案。
3. 保持 Popover 打开并触发刷新，确认窗口数量变化后面板重新测量，不出现不可滚动的裁切。
4. 在小尺寸与中尺寸 Widget 中检查相同快照；重点观察 only-monthly、only-unknown 和超过容量时的 `+N`。

预期结果：

- 没有的 5 小时或周窗口不会出现固定占位；只有实时 legacy 同语义字段才允许补位。
- 月窗口保持真实语义；未知、缓存、无效或演示字段不生成额度卡片，重复的已知语义只显示 canonical 来源。
- Widget compact primary 可预测，中尺寸最多展示三个已知窗口。
- 无可信周窗口时，菜单栏始终为 `--%`，不会取用月或未知窗口。

## Release Gate

发布前至少应满足：

- `swift test` 通过
- `swift build -c debug` 通过
- `./script/build_and_run.sh --verify` 通过
- 上述人工验证项中，Full-Screen Space 与 Real Sleep / Wake 已有人实际检查并记录结果
