# Verification Summary

本文档只记录当前仓库状态下可复现的验证入口，并明确区分：

- 已由代码、测试或命令输出直接证明的事实
- 仍需在真实 macOS 桌面环境人工确认的行为

## Historical Command Evidence

以下命令与结果来自 2026-07-18 的既有单实例验收记录，不证明当前工作区中尚未提交的开机启动、安装身份和验收脚本改动：

```bash
swift build -c debug
swift test
./script/build_and_run.sh --verify
/usr/bin/open -n /Applications/CodexMonitorNative.app  # 与 dist 副本合计并发 6 次
/usr/bin/open -n dist/CodexMonitorNative.app
pgrep -x CodexMonitorNative
ps -p <owner-pid> -o pid=,ppid=,command=
```

历史记录说明：

- `swift test` 当时执行 361 个测试，0 失败；`swift build -c debug` 与当时版本的统一安装验收通过。
- 当时没有执行 `swift build -c release` 或 `./script/build_and_run.sh --telemetry`。

## Current Command Evidence (2026-07-18)

当前稳定工作区已执行：

```bash
swift test
swift build -c debug
./script/build_and_run.sh --verify
/usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/CodexMonitorNative.app
/usr/bin/codesign -dv /Applications/CodexMonitorNative.app
/usr/bin/codesign -dv /Applications/CodexMonitorNative.app/Contents/PlugIns/CodexMonitorWidgetExtension.appex
/usr/bin/pluginkit -mAvvv -i com.ryukeilee.CodexMonitorNativePrototype.widget
pgrep -x CodexMonitorNative
ps -p <owner-pid> -o pid=,user=,command=
```

结果：

- `swift test` 完整执行 449 个 XCTest，0 失败；包含真实 Popover 生命周期、安装身份、登录项、单实例 process-bound handoff、claimant 退出/身份变化、缓存边界及 Widget bridge 回归。
- `swift build -c debug` 通过。
- 修改后的统一验收以退出码 0 完成：安装版 owner 接收开发 challenger 后保持；dist 开发 owner 向安装版完成身份绑定移交并退出；不带开发绕过参数的 dist 旧副本用唯一 token 重定向到安装版 owner。最终 token owner 的 PID、instanceID、owner record 与运行路径一致。
- 最终只有一个 `CodexMonitorNative` 进程，运行路径为 `/Applications/CodexMonitorNative.app/Contents/MacOS/CodexMonitorNative`，版本为 `0.1.0 (1)`；未残留 `.CodexMonitorNative.install.*` 受控目录。
- 主应用与嵌套 Widget 的 `codesign --verify --deep --strict` 通过；两者均为本机 ad-hoc 签名，预期 App Group entitlements 已由 staging 和安装后门禁显式比较。
- `pluginkit` 注册路径为 `/Applications/CodexMonitorNative.app/Contents/PlugIns/CodexMonitorWidgetExtension.appex`，Widget 版本为 `0.1.0 (1)` 且 Parent Bundle 属于同一安装包。
- Computer Use 可视检查确认菜单栏显示可信周额度 `69%`，Popover 显示最新数据、更新时间、刷新/退出控件，重置额度详情可展开并恢复折叠。该检查不替代 Full-Screen、Sleep/Wake、登录项迁移或桌面 Widget 实际渲染人工门禁。

`--verify` 是统一安装验收入口：它先规范化并验证安装路径，在同目录 staging 中验证 app/Widget 版本、签名和预期 App Group entitlements，再保留旧安装 backup 后替换。运行路径、版本、`pluginkit` Widget 路径、跨副本单实例、首选安装接管与带唯一 token 的旧副本因果重定向全部通过后才提交；任一步失败会回滚旧安装。默认 ad-hoc 签名只证明本地产物完整性与 entitlement 内容，不证明证书、provisioning profile、WidgetKit 实际加载或运行路径；运行路径由 `ps`、唯一进程和 owner record 门禁独立证明。

### Current Installation-Hardening Evidence

当前安装安全改动已执行：

```bash
bash -n script/build_and_run.sh
INSTALL_APP_PATH=/CodexMonitorNative.app ./script/build_and_run.sh --verify
INSTALL_APP_PATH="$HOME/CodexMonitorNative.app" ./script/build_and_run.sh --verify
INSTALL_APP_PATH="$PWD/CodexMonitorNative.app" ./script/build_and_run.sh --verify
INSTALL_APP_PATH=relative/CodexMonitorNative.app ./script/build_and_run.sh --verify
INSTALL_APP_PATH=/tmp/<safety-root>/CodexMonitorNative.app ./script/build_and_run.sh --verify
INSTALL_APP_PATH=/tmp/<isolated-root>/CodexMonitorNative.app ./script/build_and_run.sh --verify
```

结果：

- Bash 语法检查通过。
- 系统 `/bin/bash` 3.2 动态 harness 直接抽取当前脚本函数，覆盖 TERM 前 PID 存在但随后消失、pgrep 后 ps 前 PID 消失导致 PID 数组为空，以及失败 EXIT trap 继续调用 rollback；三条路径均通过且未触发 `set -u` unbound variable。已无用途的 acceptance PID 数组已从脚本移除。
- 最终验收首次在 `commit_install` 后打印 owner 摘要时暴露 Bash 3.2 对“未加花括号变量紧邻中文标点”的解析错误；两个输出变量均改为 `${name}`，对应动态回归通过，完整 `/Applications` 验收随后以退出码 0 重跑通过。
- 根目录、用户主目录和仓库根下各自名为 `CodexMonitorNative.app` 的危险目标、相对路径，以及伪装成目标名称但缺少合法 Bundle ID 的普通目录，均在构建、进程终止和删除前退出；临时目录内两个哨兵均保持不变。
- 使用临时 `pgrep`/`swift` stub 执行 `INSTALL_APP_PATH=/ ./script/build_and_run.sh run` 时，流程越过安装路径预检并到达预期的 `swift` stub；证明安装路径只约束 `--verify`，不会让 run/debug/logs/telemetry 依赖无关的 `/Applications` 状态。临时 stub 目录已删除。
- 隔离安装实际完成 SwiftPM/Widget 构建、Widget 先签与宿主后签、staging 版本检查、主应用/Widget 签名及 App Group entitlement 检查，并把新包移到临时安装路径。
- 因机器已有 `/Applications/CodexMonitorNative.app` 首选安装，临时包启动后按产品规则重定向到该首选路径，隔离验收在“运行路径必须属于临时安装”门禁失败。这不是完整 `--verify` 成功证据。
- 该自然失败触发 EXIT rollback：无原安装时移除了失败的新包；预置同 Bundle ID 原安装与哨兵后再次执行时，原安装从同目录 backup 恢复，Bundle ID 与哨兵保持，受控 `.CodexMonitorNative.install.*` 目录无残留。原安装此前正在运行时的自动重启分支尚未单独验证。
- 另一次隔离故障测试在新包落位且原包进入 backup 后撤销安装父目录写权限，强制“删除失败新包”步骤失败。脚本保留了受控工作目录与唯一 `previous-CodexMonitorNative.app`，其中哨兵和原 Bundle ID 均完整，并打印两步人工恢复路径；恢复权限后按该路径成功恢复原包。测试临时目录已清理。
- 进程门禁隔离负测使用条件 `pgrep` stub，仅在新包已落位且旧包已进入 backup 后返回枚举错误。脚本禁止 rollback 和旧 App 重启，保留当前新 target、带原哨兵的唯一 backup 及工作目录，并打印三者精确路径。随后使用真实进程工具确认并终止测试进程，按保留路径恢复原包；临时 stub 与安装目录均已清理。
- 修改后的最终 `/Applications` 验收已由 Root 执行并以退出码 0 通过；最终签名、Widget 注册、唯一运行进程及安装路径均已独立只读复核。

## Automated Evidence

除明确标为“历史记录”的条目外，以下内容由当前代码、自动化测试及上述当前命令输出直接约束：

- App 已通过 SwiftPM Debug 构建；修改后的 `--verify` 已验证唯一运行进程来自 `/Applications/CodexMonitorNative.app`、版本为 `0.1.0 (1)`，且 Widget 注册路径属于同一安装包并保持版本一致。
- 主应用在任何状态栏、刷新、持久化或 Widget bridge 初始化前，先在固定的每用户命名空间取得永久 `owner.lock` 的非阻塞 `flock`；锁文件使用 `O_CLOEXEC`，owner 崩溃或被杀后由内核释放，后继实例不依赖 PID 判活或删除锁文件。
- 后启动副本不会创建 `AppState`、状态栏、scheduler、系统 observer、真实 RPC 或 Widget bridge。它通过带 `instanceID`、期限和 ACK 的原子文件信箱，请求现有 owner 在 MainActor 上幂等显示 Popover；只有 handler 已接收且 owner 仍可服务时才写 ACK，然后 challenger 退出。
- 关停分两阶段：先停止接受激活请求，继续持锁并清理 scheduler、observer 与 AppState，最后释放租约；这避免退出中的旧 owner 与接管的新 owner 同时刷新或写状态。
- 安装路径移交使用绑定 owner、claimant、完整安装身份、内核进程身份、request ID 与有效期的 ticket/ACK；审批期限与提交完成期限分离。审批后旧 owner 停止接受新激活但继续持有现有业务状态，释放永久锁让 claimant 写入 provisional owner；旧 owner 只有在稳定复核 claimant 的 PID/EUID/内核启动时间、完整 owner record 与真实 contended `flock` 后才发布不可逆的 `.committing`，随后幂等撤下 UI 和业务资源并完成退出。不可逆提交前失败会由旧 owner 重获锁并恢复，发布 `.committing` 后则不能再取消或回滚；claimant 以 vnode event 快速唤醒，并用 100 ms 有界 `flock` 重检覆盖通知合并或漏送。
- 自动安装移交只允许当前 v2 process-bound handoff。缺少当前 handoff capability、缺少内核 `processIdentity`、旧 schema 或格式不一致的 owner 永不由 challenger 自动终止；challenger 保持 secondary 并退出，必须先让旧 owner 正常退出，再重新启动新版。这是避免无法证明 flock owner 时误杀进程的有意兼容取舍。
- 首选安装候选必须保持 Bundle ID、稳定签名锚点并且版本不倒退；重定向在启动前再次验证完整身份，启动后还要证明对应进程、路径、owner record 与真实 contended `flock` 一致。真实移动交接还要求已记录旧路径确实消失；certificate-backed 构建保持 signer 与非降级边界，ad-hoc 构建额外要求代码摘要完全相同。开发绕过只对开发产物生效，也不会自动修复登录项。
- 开机启动只有在 `SMAppService.status == .enabled` 且保存的注册安装身份与当前 App 一致时才对 UI 生效；`requiresApproval`、`notFound`、身份缺失/损坏或旧路径残留不会显示成已启用。用户的期望状态单独保存，明确关闭始终尝试清理残留注册；需要修复时执行有界的 `unregister → register`，并只忽略真实的 JobNotFound。失败修复会绑定期望状态、当前安装身份和系统状态持久化，重复启动不会循环重试；身份、状态、意图变化或用户明确操作才恢复尝试。
- 历史记录（2026-07-18，早于当前工作区改动）：安装版 owner PID `20804` 与 instanceID 保持不变，`dist` challenger 退出，`activationCount` 从 `0` 增至 `1`；随后同时发起安装版与 `dist` 共 6 个 challenger，最终仍只有 PID `20804`，路径仍为安装版，`activationCount` 精确增至 `7`。该记录不替代当前版本的重新验收。
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
- 真实刷新失败时，只有当前账号与登录会话仍能确认属于缓存快照才会保留菜单栏数字；登出、重登、账号切换或身份不可确认会安全降级为 `--%`。
- 真实链路错误可以区分为至少以下几类：
  - 未找到 codex / codex 文件不可执行
  - Codex app-server 启动失败
  - Codex 版本或必需额度能力不兼容
  - 需要登录 / 需要切换到 ChatGPT 账号
  - 请求超时
  - 响应不可解析
  - 通用 RPC 失败
  - 等待首次真实请求 / 显示上次成功数据
- 启动后刷新、定时刷新、失败退避和 wake 后触发刷新都有测试覆盖。
- 长时间运行资源生命周期有独立的收敛门禁：
  - 连续 500 次刷新后，每轮物理刷新任务都会清空，且全程最多保留一个有效的新鲜度任务；`shutdown` 后两类任务都归零。
  - 100 个已完成 shutdown 但仍被强引用的真实 RPC transport 不会让进程文件描述符数高于预热基线；8 个并发 shutdown 调用只执行一次终止/强制终止清理，所有 pipe 端点在显式 shutdown 中关闭。
  - RPC 事件队列使用单一 FIFO drain；已完成操作的捕获对象会在后续操作仍阻塞时释放，不再由整条 Task 链保留。
  - scheduler 连续 1,000 轮 start / pause / resume / stop 后定时器归零；stop 后更新间隔或 resume 不会复活定时器。
  - sleep/wake observer 连续 200 轮 start / stop 后观察者归零，并在持续注册期间完成 200 组 sleep / wake 通知；每轮 wake 任务都归零且观察者数固定为 2。
  - Popover 事件监视器资源连续 1,000 轮安装/移除后归零；真实 `NSPopover` 连续 50 次打开/关闭后，每轮 3 个事件监视器和异步布局任务均归零，陈旧关闭/布局完成不能影响新一轮展示。
  - Widget 状态连续 100 次原子移动失败后不残留 `.tmp-*` 文件。
- 最终安装包启动 36 秒与 3 分 10 秒时的两次只读资源快照均显示 CPU `0.0%`、RSS `38,640 KB`、0 个子进程；`lsof` 描述符记录从 46 降至 45，没有增长。`leaks` 报告 0 leaks / 0 leaked bytes，physical footprint 为 14.3 MB。短时快照只证明对应时刻，长期增长由上述确定性压力门禁约束。

当前测试直接覆盖的关键路径包括：

- 真实刷新成功后更新并持久化快照
- 认证失败时清除上一登录会话缓存并标记为需要登录
- 启动恢复、运行中登出、同账号重登和跨账号切换都会校验快照归属；旧无归属 payload 不会进入 App 或 Widget 的真实展示
- 解析失败时保留缓存并标记为响应不可解析
- 恢复本地真实快照后，在首次请求前明确标记“显示上次成功数据”
- 连续失败退避
- 并发刷新去重
- scheduler tick
- sleep / wake notification wiring
- 刷新任务、新鲜度任务、RPC 进程/pipe、scheduler timer、sleep/wake observer/task、Popover monitor/layout task 与 Widget 临时文件的重复生命周期收敛
- 动态投影稳定排序、known-kind 去重、legacy fallback 边界、未知/缓存/无效字段过滤与 reset 一致性
- Popover only-weekly、only-unknown、5 小时 + 周 + 月、多窗口行数，以及滚动视口与嵌套披露的纯交互信号
- Popover `Command-R` / `Command-Q` 的真实 `NSWindow` 键盘路由，以及刷新中禁用态对重复快捷键的拦截
- 首个 owner、8 个后启动请求的 ACK、非 owner 不处理动作、持锁但未 ready 时 fail closed、释放后接管、永久锁 inode 不变、陈旧元数据恢复、symlink 锁拒绝、关停前停止 ACK、遗留临时信箱清理、v1 请求兼容解码与过期请求不执行
- 同签名且不降级的首选安装身份移交、拒绝移交后旧 owner 继续服务、legacy/缺 `processIdentity` owner 保持 secondary 且不授权接管、live ticket 阻止无关第三副本、commit 跨旧 request deadline、通知漏送时在 ticket 期限内重检真实锁
- 开机启动首次意图迁移、`requiresApproval` 非有效启用、身份不匹配修复、用户明确关闭残留注册、JobNotFound 容错、AlreadyRegistered 不循环重试，以及路径/代码身份更新后只修复一次
- 安装身份同路径覆盖、移动、重签、签名不匹配、版本倒退、记录损坏和开发产物绕过的 fail-closed 决策
- 重复 `show` 不会把已经显示的 Popover 关闭或重复安装事件 monitor；关闭过渡中的转发请求会在 `popoverDidClose` 后重新显示
- Widget 纯呈现层的 only-monthly、only-unknown、primary 选择、overflow、中心数值、进度与 footer 文案
- 旧 Widget persisted payload 解码与 envelope 向后兼容

## Manual Verification Still Required

以下行为目前没有把“真实桌面交互结果”自动化；本轮没有重新执行这些人工桌面步骤，发布前仍需人工确认：

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

- 开机启动以开关类控件呈现；辅助功能读出系统实际状态或“正在更新”。待系统批准、未找到、身份不匹配与签名/注册失败不会读成“已启用”。
- 所有披露控件的键盘操作和 VoiceOver 状态保持一致，展开或折叠后立即更新读出值。
- 条件滚动视口与披露状态一致，展开或折叠后面板尺寸及时更新且内容可访问。
- 刷新、退出、关闭均有稳定键盘路径；刷新期间不可重复触发，关闭后没有残留焦点。
- 辅助功能导航顺序只包含有意义的状态与控件，不停留在装饰图形上。

### 7. Cross-Copy Activation Visual Check

步骤：

1. 保持 `/Applications/CodexMonitorNative.app` 正在运行并关闭 Popover。
2. 执行 `/usr/bin/open -n dist/CodexMonitorNative.app --args --codex-monitor-allow-development-instance`，明确走直接开发 challenger，而不是旧副本重定向。
3. 确认现有安装版的 Popover 被显示，菜单栏没有新增第二个图标。
4. 在 Popover 已显示时重复执行该命令，确认面板保持显示而不是被 toggle 关闭。

预期结果：

- 后启动副本退出，现有 owner 被唤起且 Popover 可见。
- 始终只有一个菜单栏图标；重复唤起是幂等的。

历史人工记录（2026-07-18；早于当前工作区改动）：统一验收先由 `dist` challenger 显示安装版 owner 的 Popover，随后并发启动安装版与 `dist` 共 6 个 challenger；最终 Accessibility 只报告一个 CodexMonitorNative Popover，桌面截图只显示一个 `100%` 菜单栏状态项，Popover 在重复唤起后仍保持显示。

当前工作区记录（2026-07-18）：修改后的 `--verify` 已确认安装版 owner 接收 dist challenger、首选 owner 移交及旧副本 token 重定向，最终只保留一个安装版进程。随后 Computer Use 只报告一个 CodexMonitorNative Popover，菜单栏显示 `69%`，详情披露可展开并恢复折叠。尚未重新执行“Popover 已显示时重复唤起”及 6 个 challenger 同时启动的人工时序。

### 8. Launch Item Migration Check

步骤：

1. 从安装版明确开启开机启动，确认 Popover 显示“已启用”，退出并重新启动 App，确认没有重复注册提示。
2. 在相同路径覆盖安装一个重新签名的构建并启动，确认状态重新收敛为“已启用”。
3. 退出 App，将 `.app` 真正移动到另一安装目录（确保旧路径不存在），从新路径启动并再次确认“已启用”。
4. 注销并重新登录 macOS，使用 `ps` 确认唯一进程来自新路径；随后用唯一 token 启动不带开发绕过的旧测试副本，并检查同一 token 的重定向日志：

```bash
redirect_check_token="$(/usr/bin/uuidgen)"
/usr/bin/open -n dist/CodexMonitorNative.app --args --codex-monitor-redirect-verification-token "$redirect_check_token"
/usr/bin/log show --last 1m --info --style compact \
  --predicate "process == \"CodexMonitorNative\" AND eventMessage CONTAINS[c] \"Verified redirect to the recorded preferred app installation token=$redirect_check_token\""
```
5. 在“系统设置 > 通用 > 登录项”关闭许可，确认 Popover 显示“需在系统设置中批准”且不会显示有效启用或循环重注册；从 Popover 关闭待批准意图后再次启动，确认保持关闭。

预期结果：

- 覆盖安装、同路径重签和真实移动后，登录项只绑定当前首选安装；重复启动不重复注册。
- 待批准、失败或身份无法验证时不显示虚假启用；系统级拒绝不会被后台覆盖。
- 登录时及旧副本挑战后都只有当前首选路径的唯一 owner。

本轮结果：449 个自动化测试、隔离路径故障注入及修改后的最终 `/Applications` 验收已提供状态机、签名、entitlements、覆盖安装、首选 owner 移交、旧副本 token 重定向和唯一运行路径证据。真实注销/重新登录、实际移动旧路径不存在的 App，以及 System Settings 许可切换仍未人工确认。只读导出 macOS 后台任务数据库的 `sfltool dumpbtm` 在非交互授权环境中未取得有效授权，提升权限后也无进展，已终止，因此不把系统数据库中的实际登录项路径记录为已核对。

## Release Gate

发布前至少应满足：

- `swift test` 通过
- `swift build -c debug` 通过
- `./script/build_and_run.sh --verify` 通过
- Cross-Copy Activation Visual Check 已有人实际检查并记录结果
- 上述人工验证项中，Full-Screen Space 与 Real Sleep / Wake 已有人实际检查并记录结果
