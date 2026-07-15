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

- `./script/build_and_run.sh --verify` 仍是统一安装验收入口：它会关闭旧实例、构建并签名 app 与 Widget、覆盖安装到 `/Applications/CodexMonitorNative.app`，启动最终安装包，并核对运行进程路径/版本及 `pluginkit` 的 Widget 路径。
- 本轮没有重新执行 `swift build -c release` 或 `./script/build_and_run.sh --telemetry`，因此它们不计入当前自动验证证据。

## Automated Evidence

以下内容有当前代码、测试或本轮命令结果作为直接证据：

- App 可以通过 SwiftPM 成功构建；统一安装验收已确认运行进程来自 `/Applications/CodexMonitorNative.app`，版本为 `0.1.0 (1)`，Widget 注册路径属于同一安装包且版本一致。
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
- Popover 的圆形开机启动控件由系统 `Toggle` 承载，重置额度、诊断和字段详情由系统 `DisclosureGroup` 承载；视觉样式不再依赖普通按钮模拟开关或披露语义。
- Popover 保持系统原生的 Tab 阅读顺序，不用底部操作抢占焦点或改变初始滚动位置；同时支持 `Command-R` 刷新、`Command-Q` 退出和 `Escape` 关闭，交互控件暴露稳定的辅助功能标识及动态开关、展开和刷新状态。
- 进程内键盘测试把真实 `StatusPopoverView` 挂到隐藏 `NSWindow`，发送 `Command-R` / `Command-Q` 键等价事件，直接证明动作路由有效，并证明刷新状态发布到 SwiftUI 后禁用按钮会拦截重复 `Command-R`。
- UI 门禁以可执行行为契约为准：Popover 的纯交互契约覆盖滚动视口、嵌套披露、辅助功能状态和 Escape 关闭条件；Widget 的纯呈现输入覆盖容量、primary/overflow、中心数值、进度与 footer 文案。不再以源码字符串或“PNG 文件已写出”作为通过条件；Popover 的真实辅助功能树和 Widget extension 的实际渲染仍列入人工门禁。
- 纯装饰能量核心不进入辅助功能导航；顶部合并元素读出状态与更新时间，额度卡片同时读出恢复时间和剩余时间。
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
- Popover only-weekly、only-unknown、5 小时 + 周 + 月、多窗口行数，以及滚动视口与嵌套披露的纯交互信号
- Popover `Command-R` / `Command-Q` 的真实 `NSWindow` 键盘路由，以及刷新中禁用态对重复快捷键的拦截
- Widget 纯呈现层的 only-monthly、only-unknown、primary 选择、overflow、中心数值、进度与 footer 文案
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
4. 使用固定的 3 个可信额度窗口，在小尺寸与中尺寸 Widget 中检查相同快照；核对中心额度数字、小尺寸的 `+2`、footer 去除“最早重置”前缀后贴底，以及背景填满整个容器。
5. 分别检查有 footer 与无 footer 两种状态，确认主仪表的纵向位置不变，底部没有漏底或额外空行。

预期结果：

- 没有的 5 小时或周窗口不会出现固定占位；只有实时 legacy 同语义字段才允许补位。
- 月窗口保持真实语义；未知、缓存、无效或演示字段不生成额度卡片，重复的已知语义只显示 canonical 来源。
- Widget compact primary 可预测，中尺寸最多展示三个已知窗口。
- Widget 的 overflow、中心数值和 footer 与纯呈现层输出一致；footer 使用底部 overlay，不会挤动主仪表。
- 无可信周窗口时，菜单栏始终为 `--%`，不会取用月或未知窗口。

### 6. Popover Keyboard and Accessibility

步骤：

1. 在“系统设置 → 键盘”开启“键盘导航”，让 macOS 按系统约定把 Tab 焦点交给按钮、开关和披露控件。
2. 打开 Popover，不点击内容，确认内容仍位于顶部且没有因底部控件获取焦点而滚动。
3. 使用 `Tab` / `Shift-Tab` 遍历所有当前可见控件，确认首次 Tab 按阅读顺序进入控件、焦点环可见，且顺序与面板从上到下的阅读顺序一致。
4. 聚焦开机启动与各披露控件，使用空格及系统披露键盘操作切换状态；再用 `Command-R` 刷新、`Escape` 关闭面板。
5. 开启 VoiceOver，并用 Accessibility Inspector 核对启动开关、刷新、退出、诊断和重置详情控件的 identifier、角色、名称、值、禁用状态与展开状态；确认纯装饰能量核心不进入导航。
6. 展开诊断或重置详情，确认出现 identifier 为 `quota-scroll-viewport` 的纵向滚动区域；折叠全部内容后确认该滚动区域消失，Popover 会重新测量且内容不被裁切。
7. 展开重置额度详情，确认额度卡片读出百分比、状态、恢复时间与“还需”时间。

预期结果：

- 开机启动以开关类控件呈现并读出“已开启 / 已关闭 / 正在更新”，不会被误报为无状态普通按钮。
- 所有披露控件的键盘操作和 VoiceOver 状态保持一致，展开或折叠后立即更新读出值。
- 条件滚动视口与披露状态一致，展开或折叠后面板尺寸及时更新且内容可访问。
- 刷新、退出、关闭均有稳定键盘路径；刷新期间不可重复触发，关闭后没有残留焦点。
- 辅助功能导航顺序只包含有意义的状态与控件，不停留在装饰图形上。

## Release Gate

发布前至少应满足：

- `swift test` 通过
- `swift build -c debug` 通过
- `./script/build_and_run.sh --verify` 通过
- 上述人工验证项中，Full-Screen Space 与 Real Sleep / Wake 已有人实际检查并记录结果
