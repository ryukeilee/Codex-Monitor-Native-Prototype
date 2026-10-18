# RPC 刷新样本计时与未覆盖边界（2026-10-18）

本轮不修改任何生产源码。用真实 `codex app-server`（`/opt/homebrew/bin/codex`，已登录
ChatGPT 会话）测量了完整刷新链路的时间构成。结论：**在本次样本覆盖的负载下**，已单独计时的
应用侧项合计约占刷新耗时的 0.03%–0.09%，未发现值得承担维护成本的进一步优化；该结论不声称覆盖
所有负载（见「未覆盖的放大路径」）。本文件记录本次样本的计时与未覆盖边界、证据与被否决的候选，
供后续判断「是否值得再动 RPC 刷新路径」时复用。

## 目标与结论

- 目标：确定一次真实配额刷新（`QuotaRefreshService` 默认真实组合，含 reset-credit 腿）的时间
  花在哪里，以及应用侧（解码、解析、账号边界校验、事件队列、分帧）各占多少。
- 范围：本测量**只覆盖 RPC 腿与 reset-credit 腿**，不包含 `AppState` 接受结果后的持久化、趋势
  分析与 UI 发布工作（本轮范围外）。
- 结论：在已覆盖范围内，**已单独计时的**应用侧项只有 RPC 腿的 2 次账号边界读取 + 一次真实帧的
  `decodeInboundFrame + parseRateLimits`，合计 ≈ 0.55–0.87 ms；若计入 reset-credit 腿的另 2 次
  身份读取（4 次 × 216–367 µs + 116–140 µs），合计 ≈ **0.98–1.61 ms**，相对 1.8–3.4 s 的实际
  刷新耗时约 **0.03%–0.09%**（量级结论）。这是**已测项的下界估计，并不等于应用侧全部计算的总
  耗时**：事件队列调度、请求/通知编码与解码、reset-credit 的 JSON 解码与投影、快照 merge/bound
  等均未单独计时。
- 本次样本中，主要可观测等待区间是两点外部 I/O（本仓库已单独计时的应用侧项比它们低约 3 个数量级）：
  1. app-server 自身的 `account/rateLimits/read`：提交版 harness 可复现「最后一次 `write(_:)`
     到最后一帧完成」的客户端观测间隔，本次样本 ≈ 1.4–2.1 s（见 (f)）；
  2. reset-credit HTTP 调用：提交版 harness 不覆盖该腿，临时 harness 计时见 (e)。
- 其余固定成本：进程启动 → 首帧约 30–34 ms，shutdown 约 7–14 ms。
- 本轮维持现状，不修改生产源码；工作区已有的未提交改动（含 `RealQuotaProvider.swift` 中
  `CodexRPCClient` 的 `Self.lineFeed` 常量提升）按原样全部保留。

## 证据

测量条件：本机 2026-10-18，debug 构建，真实 `codex app-server` + 已登录会话，采用**临时**
计时 harness（未提交），逐次刷新之间进程全新启动。(a)–(e) 的数字来自该临时 harness，每个口径
均为单次样本；提交版 opt-in 测试的复核输出（同一测量条件下）见「验证」，其中 (b) 的贡献回调数
与 (f) 的观测间隔口径可由提交版 harness 直接复现。

### (a) 3 次连续真实刷新（`CodexRPCClient` + `ProcessRPCTransport`）

| 指标 | 第 1 轮 | 第 2 轮 | 第 3 轮 |
|---|---|---|---|
| `totalMs` | 1371.80 | 1389.32 | 1208.72 |
| `startToStopMs` | 1362.78 | 1376.30 | 1199.55 |
| `shutdownMs` | 9.02 | 13.01 | 9.17 |
| `stdoutChunks` | 3 | 4 | 3 |
| `stdoutBytes` | 2354 | 2354 | 2247 |
| 帧数 | 4 | 4 | 3 |

三个样本的 `stderrChunks` 均为 0，`writes` 均为 3，`CodexAuthIdentityReader.boundary` 均为每轮
2 次调用。

### (b) 真实帧结构

- `initialize` 帧 205 字节，start 后约 30 ms 到达。
- 一个 216 字节 notification 与 `initialize` 共享同一个 chunk，即同一回调内连续完成两帧。
- rate-limits 帧 1823 字节，到达时刻 1358.57 / 1373.89 / 1197.58 ms（对应 (a) 的第 1/2/3 轮）。
- 106 字节 notification 出现在**第 1 轮（1147.77 ms）与第 2 轮（1256.31 ms）**，**第 3 轮
  没有**（第 3 轮只有 3 帧）。这两个时刻来自临时 harness 记录（非提交版 harness 输出）；提交版
  harness 只打印每帧到达时刻 `timesMs`，不标注帧的角色。
- **本次样本（含提交版 harness 的四次复核）中，全部帧的贡献回调数均为 1：没有一帧被回调边界
  拆分。** 贡献回调数 = 该帧的字节来自多少个 stdout 回调：1 = 该帧完整落在单个回调内，
  ≥2 = 该帧被拆开、由多个回调重组（见「可复现路径」的 `frameCallbacks`）。

### (c) 1823 字节真实 rate-limits 帧的解析成本（200 次 × 3 轮，debug）

| 阶段 | 耗时 |
|---|---|
| 纯 `JSONSerialization.jsonObject`（预热后） | ≈ 15–17 µs |
| `decodeInboundFrame` | ≈ 61–66 µs |
| `parseRateLimits` | ≈ 49 µs |
| 生产路径 `decodeInboundFrame + parseRateLimits` | ≈ 116–140 µs |

### (d) 账号边界读取

`CodexAuthIdentityReader.boundary(codexHome:)` ≈ 216–367 µs/次；每轮刷新 2 次，reset-credit 腿
另有 2 次。

### (e) `QuotaRefreshService` 默认真实组合

| 组件 | 3 轮耗时（ms） | 均值（ms） |
|---|---|---|
| `RealQuotaProvider.fetchQuota()` | 1594.06 / 1326.76 / 1378.21 | 1433.01 |
| `ResetCreditsDetailProvider.fetchDetails(for:)` | 1770.69 / 392.87 / 442.30 | 868.62 |

其中 1770.69 ms 是 reset-credit 腿的网络长尾，不是稳定成本。

### (f) 结论

**已测应用侧项与占比（下界估计）**：已单独计时的项为 RPC 腿的 2 次账号边界读取 + 一次真实帧的
`decodeInboundFrame + parseRateLimits`，即 2 × 216–367 µs + 116–140 µs ≈ **0.55–0.87 ms**；
若计入 reset-credit 腿的另 2 次身份读取（见 (d)），即 4 × 216–367 µs + 116–140 µs
≈ **0.98–1.61 ms**。相对 1.8–3.4 s 的实际刷新耗时约 **0.03%–0.09%**（量级结论）。

这一数字**不包含**未单独计时的应用侧工作：事件队列调度、initialize/initialized/rateLimits 的
请求与通知编码、response 解码、reset-credit 的 JSON 解码与投影、快照 merge/bound 等。因此它是
已测项的下界，并不等于应用侧全部计算的总耗时。

**本次样本的可复现口径**：提交版 harness 打印 `writesMs`（每次 `write(_:)` 相对 `start()` 的
时刻）与 `timesMs`（每帧到达时刻），但不标注帧的角色。二者**末项之差**即「最后一次 `write(_:)`
调用时刻到**最后一帧**完成时刻的客户端观测间隔」：本次提交版样本四连测为 **≈ 1680.9 / 2127.5 /
1480.4 / 1373.9 ms**（数值来自本次样本，抖动明显，见「验证」）。本次四个样本中最后一帧均为
rate-limits 响应（`frames` 末项 1823 字节），因此该间隔接近 rate-limits 请求 → 响应的客户端
等待；若将来响应之后还有 notification，该差值不再等于目标响应往返。reset-credit HTTP 腿在提交版
harness 中不可观测；临时 harness 的
`ResetCreditsDetailProvider.fetchDetails(for:)` 为 392.87–442.30 ms，另有一次 1770.69 ms 长尾
（见 (e)）。另有进程启动 → 首帧约 30–34 ms、shutdown 约 7–14 ms。

**在本次真实样本覆盖的负载下**，已测应用侧项比刷新延迟低 3 个数量级，未发现值得承担维护成本的
优化；本结论不声称覆盖所有负载（见「未覆盖的放大路径」）。

## 被否决的候选（均保留现状）

1. **分帧单次移除重写**（`OptimizationBenchmarkTests` 中的 `singleRemoval` 模型，已
   “measured but not shipped”）。生产 `handleStdoutChunk` 在**每帧**完成后执行一次
   `removeSubrange(0...newlineRange.lowerBound)`（同一 chunk 含 2 帧时该 chunk 内执行 2 次），
   并非「每 chunk 至多一次」。当前样本下每次刷新的分帧缓冲算术总计 ≤4 次**成功匹配 LF** 的搜索
   （另有至多一次扫到缓冲区末尾的未匹配搜索）、≤4 次 `subdata`、≤4 次前缀移除（4 帧，见 (a)）；
   单次移除重写能消除的搬移工作量级为每次刷新个位数次内存移动，且本次样本中帧均未跨回调重组
   （见 (b)）。**保留现状**：收益量级远低于刷新延迟，不值得为此改动生产分帧路径。
2. **`CodexRPCEventQueue.pendingOperations.removeFirst()` 的 O(n)**。每次刷新仅 4–6 次
   enqueue，数组长度不超过个位数，在本轮观测的规模下不足以产生可观测成本。队列每次从空转为非空
   会创建 1 个 drain `Task`；本次未单独计数每次刷新的实际创建数，事件与 drain 重叠时创建会合并。
   **保留现状。**
3. **`parseRateLimits` 中 legacy 双映射探测重复调用 `parseWindowDuration`**（primary/secondary
   各多一次）。仅占 49 µs 解析中的个位数微秒，且触及 legacy 分类语义；收益低于维护成本。
   **保留现状。**
4. **账号边界重复读取 auth.json**（每轮 4 次读数，每次 ≈ 216–367 µs）。fail-closed 身份校验是
   产品不变量（缓存会使跨账号污染重新成为可能），不能为了省下约 0.6 ms 而缓存。**保留现状。**
5. **其它解析/队列微优化**。在本次样本覆盖的负载下，已测应用侧项比刷新延迟低 3 个数量级，没有
   可证实的收益。**保留现状。**
6. **架构级候选**，不在本轮范围。常驻 app-server 复用进程：常驻进程对服务端往返以外的固定成本
   （启动 → 首帧约 30–34 ms、shutdown 约 7–14 ms）是否有净收益，本轮未做对照实验，不作判断；
   因超出范围保留现状。把 reset-credit HTTP 与 RPC 并行不可行，reset-credit 腿依赖 RPC 返回的
   account boundary，顺序是账户边界契约的一部分。**保留现状。**
7. **工作区未提交的 `Self.lineFeed` 常量提升**（`CodexRPCClient`）按「保留全部未提交成果」原样
   保留，不回退。实测其生产工作量约每次刷新 4 次成功匹配 LF 的搜索（另有至多一次扫到缓冲区末尾
   的未匹配搜索），属文档化但不显著。

## 未覆盖的放大路径（证据不足，本轮未验证）

以下边界来自代码审查，均为**未验证的观察**：本轮未构造对应负载，也未做对照实验。它们只用于
限定上文结论的适用范围，不作为本轮结论的反例。

- **notification 风暴**：`CodexRPCEventQueue.pendingOperations` 按到达顺序无界增长，连续
  `removeFirst()` 的累计搬移为 O(n²)，且超时事件排在积压之后。本次真实样本只观测到 4–6 次
  enqueue（见 (a)），未构造风暴样本。
- **异常退出时的同步等待**：`CodexRPCClient.complete` 在 actor 上同步调用 `shutdownAndWait()`，
  `ProcessRPCTransport.waitForExit()` 以 `Thread.sleep(0.001)` 轮询。正常路径 shutdown 为
  7–14 ms，但异常退出路径按生产配置（`terminate` 与 `kill` 各一次，每次 `waitForExit` 最多等待
  `shutdownGraceSeconds`）最长等待接近 2 s，期间占用协作线程池线程。本轮未做异步关闭对照。
- **notification 的 `params`**：仍会构造 typed value tree 后再由 client 忽略；大参数或风暴下可
  放大。本次真实样本的 notification 为 106/216 字节，未构造更大样本。

## 可复现路径

帧结构、贡献回调数与相位耗时（需要真实 `codex` 与登录会话，默认跳过；只打印 `LIVE` 行，
不做任何墙钟时间断言）：

```bash
CODEX_MONITOR_LIVE_CODEX=1 swift test --filter LiveCodexAppServerProtocolTests/testRealAppServerRefreshProducesABoundUsableSnapshot
```

输出中的 `frames`（每帧字节数）、`frameCallbacks`（每帧贡献回调数）、`timesMs`（每帧到达时刻）
与 `writesMs`（每次 `write(_:)` 时刻）即为 (b) 与 (f) 的复现口径。

合成 payload 的解析成本对照：

```bash
CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests/testRPCLineDecodeBaseline
```

## 验证

- 本轮唯一代码改动是 `Tests/CodexMonitorNativeTests/LiveCodexAppServerProtocolTests.swift`：
  为该 opt-in 测试扩展了只增不减的结构/相位观测。在既有 `RecordingRPCTransport` 上新增
  `stdoutChunkCount`、`stdoutByteCount`、每帧贡献回调数（`frameCallbacks`）、每帧字节数、
  每帧到达时刻（`frameElapsed`）、每次 `write(_:)` 时刻（`writeElapsed`）与
  `start → 首帧 → shutdown` 相位，并由 `bootBreakdown` 汇总。未新增测试方法，未添加时间断言。
- 贡献回调数的语义（`residueCallbacks + 1`）：1 = 该帧完整落在单个回调内；≥2 = 该帧被跨回调
  重组。逐帧推理：`"A\n"`+`"B\n"` → `[1,1]`；`"A\nB\n"` → `[1,1]`；`"A\nB"`+`"C\n"` →
  `[1,2]`（后一帧为 `"BC"`，跨 2 个回调）；`"A"`+`"\n"` → `[2]`。
- `swift build -c debug` 通过。
- 提交版 harness 在当前条件下复核四次，测试全部通过（每次 1 项、0 失败），输出：

  ```text
  LIVE serverVersion=codex-cli 0.163.0
  LIVE refresh frames=4 weeklyRemaining=97 fiveHourRemaining=96 windows=2
  LIVE refresh transport totalMs=1724.80 startToFirstFrameMs=30.74 startToStopMs=1715.70 shutdownMs=9.11 stdoutChunks=4 stdoutBytes=2354 frames=[205,216,106,1823] frameCallbacks=[1,1,1,1] timesMs=[30.7,30.8,1099.8,1712.4] writesMs=[0.4,31.5,31.5]
  ```

  ```text
  LIVE serverVersion=codex-cli 0.163.0
  LIVE refresh frames=4 weeklyRemaining=97 fiveHourRemaining=96 windows=2
  LIVE refresh transport totalMs=2175.53 startToFirstFrameMs=30.17 startToStopMs=2161.82 shutdownMs=13.71 stdoutChunks=4 stdoutBytes=2354 frames=[205,216,106,1823] frameCallbacks=[1,1,1,1] timesMs=[30.2,30.2,1080.9,2159.1] writesMs=[0.4,31.5,31.6]
  ```

  ```text
  LIVE serverVersion=codex-cli 0.163.0
  LIVE refresh frames=4 weeklyRemaining=97 fiveHourRemaining=96 windows=2
  LIVE refresh transport totalMs=1524.27 startToFirstFrameMs=30.36 startToStopMs=1515.09 shutdownMs=9.18 stdoutChunks=4 stdoutBytes=2354 frames=[205,216,106,1823] frameCallbacks=[1,1,1,1] timesMs=[30.4,30.4,1483.2,1511.5] writesMs=[0.4,31.1,31.1]
  ```

  ```text
  LIVE serverVersion=codex-cli 0.163.0
  LIVE refresh frames=3 weeklyRemaining=97 fiveHourRemaining=96 windows=2
  LIVE refresh transport totalMs=1418.90 startToFirstFrameMs=34.03 startToStopMs=1411.48 shutdownMs=7.42 stdoutChunks=3 stdoutBytes=2247 frames=[205,216,1823] frameCallbacks=[1,1,1] timesMs=[34.0,34.1,1409.4] writesMs=[0.5,35.5,35.5]
  ```

  四次复核与 (a)–(b) 的结构性事实一致：帧数在 3 与 4 之间波动（最后一轮没有 106 字节
  notification，与 (a) 第 3 轮一致）、**本次记录样本**中帧边界为
  `[205,216,106,1823]` 或去掉 notification 的 `[205,216,1823]`、全部帧的贡献回调数为 1
  （无跨回调拆分）、首帧约 30–34 ms、shutdown 7–14 ms；`writesMs` 显示后两次写几乎同时
  （约 31–36 ms，两次写相隔 <1 ms），而 rate-limits 帧在 1.4–2.2 s 后到达，即 (f) 中「最后一次
  `write(_:)` 到最后一帧完成」的客户端观测间隔口径（样本中最后一帧即 1823 字节 rate-limits
  响应）。**帧边界并非常量**：审查在同一环境另一次运行得到首帧 189 字节，说明帧长随
  app-server 版本/环境变化。
- `git diff --check` 通过。

## 剩余风险

- 证据来自单机、单次会话、少量样本、debug 构建，只能支持「已单独计时的应用侧项约占刷新耗时
  0.03%–0.09%」这一量级结论，不能外推为任意机器/网络下的精确比例，也不覆盖未单独计时的应用侧
  工作与「未覆盖的放大路径」中的负载。
- 真实 app-server 延迟抖动明显（reset-credit 腿出现 1770 ms 长尾、提交版样本中「最后一次
  `write(_:)` 到最后一帧完成」的客户端观测间隔在 1.37–2.13 s 之间）；表中的均值仅用于展示量级。
- 未测 release 计时（仓库既有约束：release 下测试不可编译）。
- 未构造超大 payload 的真实样本：现有 scaled 合成 payload 1294 字节**小于**真实 1823 字节帧，
  因此不能据此推断「大 payload 放大后仍无影响」；真实 1823 字节帧实测 116–140 µs，更大样本
  未测。
- 未执行 `./script/build_and_run.sh --verify`（会替换已安装 bundle，属外部状态变更）与人工 UI
  检查：本轮不涉及签名、entitlements、安装路径、菜单栏、Popover 或 Widget 呈现。
- 本轮只测单次刷新内的时间构成，未测 CPU 占用、能耗或内存。
