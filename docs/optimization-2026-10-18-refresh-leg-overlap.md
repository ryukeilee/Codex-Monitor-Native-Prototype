# reset-credit 明细腿与 RPC 腿重叠执行（2026-10-18）

本轮把 `QuotaRefreshService.refresh` 里串行执行的 reset-credit 明细腿改为与 app-server RPC 腿并发，
并以「明细腿请求身份 == RPC 腿证明的快照身份」这一精确身份门替代原先靠顺序提供的身份保证。
实测（同机、同会话、同一二进制内交错 A/B，真实端点）：刷新耗时中位数 **2939.8 ms → 1912.5 ms
（中位节省 1027.3 ms，−35%）**，六轮 A/B 发布出的 reset-credit 事实逐项相同。

## 目标与结论

- 目标：降低一次真实配额刷新的端到端等待成本，同时不削弱账户/会话边界校验、取消与超时处理、
  失败回退或 App/Widget 一致性。
- 现状（优化前）：`QuotaRefreshService.refresh` 先 `await realProvider.fetchQuota()`（spawn
  `codex app-server` + RPC），返回后才 `await resetCreditsDetailProvider.fetchDetails(for:)`
  （HTTPS GET `chatgpt.com/backend-api/wham/rate-limit-reset-credits`）。两腿串行，刷新返回的合并
  快照必须等明细腿结束。
- 结论：明细腿只需要一个账户/会话身份，不需要配额数值，因此可以与 RPC 腿并发。原先「顺序即身份
  保证」的作用改由身份门承担：预取载荷只有在**其请求身份与 RPC 腿证明的快照身份双方有效且完全
  相等**（`QuotaAccountBoundary.matches`）时才会上屏，否则按既有的身份不一致分支 fail-closed。
  实测 HTTP 腿的整段耗时（≈1.0–1.3 s）不再叠加在刷新总时长上。

## 证据

测量条件：本机 2026-10-18，debug 构建，真实 `codex-cli 0.163.0` + 已登录会话，真实端点，逐次
刷新进程全新启动。计时来自**临时**探针（未提交，测量后已删除），只打印计数、状态与耗时，不打印
令牌、账号标识或原始载荷。

### (a) 两腿单独计时（各 3 轮）

| 腿 | 第 1 轮 | 第 2 轮 | 第 3 轮 |
|---|---|---|---|
| RPC 腿 `RealQuotaProvider.fetchQuota()` | 1250.0 ms | 1331.7 ms | 1784.9 ms |
| 明细腿 `ResetCreditsDetailProvider.fetchDetails(for:)` | 1078.7 ms | 1160.5 ms | 1277.1 ms |

同轮 RPC 快照的 `resetAvailableCount = 3`（显式非 0），明细腿返回 `availableCount = 3`、3 条
`available` 明细、`statusSummary = [available:3]`：两条腿的计数一致，明细腿的额外信息是逐条
`expires_at`。

### (b) 优化前：出厂组合的端到端耗时（3 轮）

| 轮次 | `QuotaRefreshService()`（串行，优化前） |
|---|---|
| 1 | 3098.3 ms |
| 2 | 5049.6 ms |
| 3 | 3048.4 ms |

与 (a) 的量级自洽：总时长 ≈ RPC 腿 + 明细腿 + 进程启动/清理的固定开销。

### (c) 交错 A/B（6 轮，同一二进制）

A 臂＝优化前的串行顺序，用同一组真实 provider 在探针内复现（RPC 腿 → 以 RPC 快照身份调用明细
腿）；B 臂＝改后的出厂组合 `QuotaRefreshService()`（明细腿与 RPC 腿并发）。两臂交错执行，条件相同。

| 轮次 | A 串行 | B 重叠 | 节省 |
|---|---|---|---|
| 1 | 3233.6 ms | 1436.8 ms | 1796.8 ms |
| 2 | 2482.6 ms | 1912.5 ms | 570.1 ms |
| 3 | 2939.8 ms | 1401.2 ms | 1538.6 ms |
| 4 | 2772.1 ms | 2651.1 ms | 121.0 ms |
| 5 | 3584.7 ms | 1827.6 ms | 1757.1 ms |
| 6 | 2412.3 ms | 1936.7 ms | 475.6 ms |
| **中位数** | **2939.8 ms** | **1912.5 ms** | **1027.3 ms** |

- 结构上，节省量 = min(RPC 腿, 明细腿)（总时长由 `串行 = RPC + HTTP` 变为
  `重叠 = max(RPC, HTTP)`）。本轮样本中 RPC 腿通常较长，因此节省量接近明细腿的整段耗时；轮次 4
  的 RPC 腿本身变慢，节省量随之变小——这正是该结构应有的表现，不是回归。
- **内容等价**：6 轮中两臂的 reset-credit 事实逐项相同（`count=3`、三条 `expires_at`
  1792699270 / 1793293617 / 1794002478、`summary=[available:3]`），B 臂额外核对
  `resetCreditDetailsState=detailed`、`resetCreditRawFields=0`、`resetCreditTimeEntries=0`
  （即共同投影对 app-server 原始字段的清空行为不变）。

### (d) 触发频率

自动刷新节奏由 `AdaptiveRefreshCadencePolicy` 决定：无可信实时快照/bootstrap 5 分钟，稳定实时
数据 15 分钟，显著额度变化 2 分钟，另有 reset 边界、网络恢复、系统时钟变化等触发
（`Sources/CodexMonitorNative/Core/RefreshScheduler.swift:29`–`75`）。即稳态下每天约百余次刷新，
每次省下约 1.0 s 的明细腿串行等待；该腿也是失败面之一（上一轮样本出现过 1771 ms 长尾），重叠后
不再直接叠加到刷新总时长上。

## 改动

生产源码仅 `Sources/CodexMonitorNative/Core/QuotaRefreshService.swift`：

1. 新增可注入的 `currentAccountBoundary: @Sendable () -> QuotaAccountBoundary?`（默认
   `CodexAuthIdentityReader.currentBoundary()`，复用既有读取器，无缓存、无新读取路径）。
2. `refresh(basedOn:)` 在 RPC 腿之前 `async let prefetchResetCreditsDetails()`，在 RPC 腿与既有
   校验之后 `await`，失败路径不显式等待该子任务（由结构化并发作用域取消并 drain）。
3. `prefetchResetCreditsDetails()` 永不抛错（普通明细失败只降级 reset-credit 呈现，不会让 refresh 失败；
   取消仍继续传播），把结果归一到
   `resolved(outcome, requestBoundary:) / identityUnavailable / cancelled`。取消
   （含 `URLSession` 的 `URLError.cancelled`）保持为取消，不变成上屏诊断。
4. 身份门：**预取腿的每一个结果**（拿到的明细、服务端报无可用 credits、抓取失败）都带有其请求
   边界，且只有在快照边界与请求边界双方有效且完全相等时才被采用；否则一律按既有
   `.accountBoundaryMismatch` 分支发布 `.unavailable` + 同一诊断字符串（快照边界缺失/无效时不打
   「身份变化」warning；两边界均有效但不等时打一条固定文案的 warning，不含身份材料）。
5. `identityUnavailable`（启动时 `auth.json` 无可用身份）走**原串行路径**，行为与改动前逐字一致。
6. 三种 outcome 仍共用同一张投影表（`projectingResetCredits` /
   `projectingUnavailableResetCredits` / `reusableResetCreditDetails` 行为未变）。

### 行为等价表（发布出的 `QuotaSnapshot`）

| 情形 | 改动前 | 改动后 |
|---|---|---|
| RPC 腿失败 | 不发明细请求 | 已发出的明细请求被取消/drain；刷新仍以 RPC 错误失败，不发布快照 |
| RPC 成功 + 拿到明细 | `.detailed`（字段相同） | 相同 |
| RPC 成功 + 服务端报无可用 credits 且无可复用明细 | `.appServerCountOnly` | 相同 |
| RPC 成功 + 无可用 credits 但存在可复用未过期明细 | `.unavailable` + 该原因 + 复用明细 | 相同 |
| RPC 成功 + 明细失败（网络/HTTP/身份） | `.unavailable` + 同一诊断 + 复用明细 | 相同 |
| RPC 成功 + 明细腿被取消 | `CancellationError` | 相同 |
| 明细腿启动时 `auth.json` 无可用身份 | 之后串行请求 | 原串行路径不变 |
| 刷新期间账号/会话变化（在并发腿窗口内） | 上屏该次请求的明细 | 丢弃并发腿的**任何**结果 → `.unavailable` + 同一身份不一致诊断（fail-closed，下一次刷新恢复） |

**方向性说明（诚实边界）**：身份门的判据是「请求身份 == 快照身份」（双方必须有效且完全相等），而串行
判据是「快照身份 == 请求时刻的 `auth.json`」并叠加「响应后 `auth.json` 仍相同」。两者都要求「明细请求
所用身份 == 快照上屏身份」；差别只在检查发生的时刻，以及身份变化时的结果：并发腿在身份变化时丢弃
结果，串行腿则可能在新身份下重新发起请求并上屏该次结果。因此并发组合不会把「另一账号/会话身份下的
请求结果」投影进快照——包括 `noAvailableCredits` 与失败诊断这两类非明细结果，它们同样受身份门约束。

同时必须说明：两种顺序在**时间上**不承诺无条件等价——同一账号下，额度数值、网络与端点状态本身会随
时间变化，两臂各是一次独立观测；本轮的等价性主张限于上表的情形：身份稳定的窗口内两者发布相同的
`.detailed` / `.appServerCountOnly` / `.unavailable` 投影（含可复用明细与诊断字符串），以及身份变化
时并发腿只可能更保守。

## 被否决的候选

1. **app-server 报 `availableCount == 0` 时跳过明细腿**。实测本机/本账号 app-server 报
   `resetAvailableCount = 3`（显式非 0），该分支在此账号下根本不会触发；且并非可证等价：若 HTTP
   返回可用 credits 而 app-server 计数为 0，旧实现会发布 `.detailed`，跳过会改为
   `.appServerCountOnly`。收益不成立 + 等价性不足，**否决**。
2. **让 `CodexRPCClient.complete → ProcessRPCTransport.shutdownAndWait` 异步化**。上一轮样本测得
   正常路径 shutdown 仅 7–14 ms（约占刷新 0.3%–0.6%），异常路径按生产配置最长约 2 s（`terminate`
   与 `kill` 各一次 `waitForExit`，每次上限 `shutdownGraceSeconds`，生产默认 1 s）。后者的确在
   actor 上同步阻塞并占用协作线程池线程，但触发条件（子进程忽略 SIGTERM）在本机未观测到，收益远
   小于本轮改动，且异步关闭会引入「结果已交付但进程仍在回收」的新生命周期问题。**保留现状**。
3. **`waitForExit()` 的 `Thread.sleep(0.001)` 轮询**。正常路径 7–14 ms 内轮询 7–14 次，属于微秒/
   单次唤醒量级，与刷新延迟不在同一数量级。**保留现状**。
4. **两腿并行但不加身份门**（直接让明细腿自行读取身份）：会重新打开「另一账号/会话的明细上屏」
   风险，直接违反 fail-closed 不变量。**否决**。
5. **两阶段发布**（先发布 RPC 快照、明细到达后再发布一次）：会对同一次刷新产生两次
   `commitState`（两次 Widget 状态写入与 timeline reload，并在 popover 上出现一次中间态呈现），
   需要新增中间状态。趋势的影响取决于第二份快照的时间戳：沿用同一 `refreshedAt` 会被
   `UsageTrend.append` 拒绝（`Sources/CodexMonitorNative/Core/UsageTrend.swift:61`），新时间戳则会成为
   一条重复周配额样本。收益与复杂度不匹配。**否决**。
6. **把明细腿移到 popover 打开时再取**：会让用户真正等待的地方（打开面板）承担网络延迟，并把
   快照与明细解耦成两套时序。**否决**。

## 可复现路径

本轮计时探针为临时文件，测量后已删除（不留在仓库内）。复现方式：新增一个 opt-in 测试，环境变量
`CODEX_MONITOR_PROBE=1` 时执行，A 臂按「`RealQuotaProvider().fetchQuota()` →
`ResetCreditsDetailProvider().fetchDetails(for: rpcSnapshot.accountBoundary!)`」顺序计时，B 臂计时
`QuotaRefreshService().refresh(basedOn:)`，两臂交错各 6 轮并打印每轮耗时、`resetAvailableCount`、
明细 `expiresAt` 集合与 `statusSummary`；需要真实 `codex` 与已登录会话。探针不得打印令牌、账号标识
或原始载荷。

结构性断言（已提交、无需网络）由新增测试覆盖：

```bash
swift test --filter QuotaRefreshServiceTests
```

其中 `testResetCreditDetailLegRunsWhileRealProviderLegIsStillInFlight` 断言 RPC 腿仍被 gate 阻塞时
明细腿已被调用（串行实现下会失败而不是挂起）；
`testPrefetchedAndSerialDetailOutcomesPublishIdenticalSnapshots` 断言三种 outcome ×（新鲜/可复用
明细）下串行与预取路径发布出的快照全字段相等；
`testRefreshDiscardsPrefetchedDetailsFetchedUnderADifferentAccountBoundary` 与
`testRefreshGatesPrefetchedNonPayloadOutcomesUnderADifferentAccountBoundary` 断言请求身份与快照身份
不一致时丢弃结果（含非 payload 结果）且不泄漏；
`testRefreshUsesSerialDetailLegWhenNoRequestIdentityIsAvailable` 断言无
可用身份时走原串行路径；`testFailedRealProviderDoesNotWaitForThePrefetchedDetailLeg` 断言 RPC 失败
时会取消（而非等待）并发腿。

## 验证

- `swift build -c debug` 通过。
- `swift test --filter QuotaRefreshServiceTests`：**20 tests, 0 failures**。
- `swift test`（完整）：**Executed 686 tests, 14 skipped, 0 failures (0 unexpected)**；14 个 skip 全部是既有
  opt-in（live app-server 与 performance baseline），临时探针在测量后已删除。
- `swift build -c release` 通过（release 下测试不可编译，仓库既有约束）。
- Widget target 构建（改动文件不在 widget target 的 Sources 列表中，仍作门禁检查）：
  `xcodebuild -project CodexMonitorWidgetExtension.xcodeproj -scheme CodexMonitorWidgetExtension
  -configuration Debug -derivedDataPath /tmp/widget-dd CODE_SIGNING_ALLOWED=NO build` →
  `** BUILD SUCCEEDED **`。
- `git diff --check` 干净。
- 独立复核（不同模型/会话，只读）：首轮结论「未发现阻塞性正确性或安全问题」，仅指出非 payload 预取结果
  未经身份门这一契约偏差；修复后针对修复及影响范围复核（见下方「复核后的修复」）。
- 未执行 `./script/build_and_run.sh --verify`（会停止现有 App 并替换已安装 bundle，属外部状态变更，
  需额外授权）；本轮不涉及签名、entitlements、安装路径或 Widget 打包。
- 未执行人工 UI 检查：本轮不改变菜单栏标题、tooltip、popover 或 Widget 的呈现规则（明细腿的结果
  投影路径与改动前相同）。

### 复核后的修复

首轮独立复核指出：身份门只覆盖了拿到明细（`.payload`）这一种预取结果，而 `noAvailableCredits`
与抓取失败两类结果未携带其请求身份，因此在「身份变化恰好发生在并发腿完成之后」的交错下，
可能把在 A 身份下产生的「无可用 credits / 失败分类」发布到 B 身份的快照上（不泄漏 A 的明细、
计数或标识）。已按此修复：`PrefetchedResetCreditsDetails` 合并为
`identityUnavailable / cancelled / resolved(outcome, requestBoundary:)`，**所有由请求产生的 outcome
统一过门**；同时合并了两处重复的错误分类、复用既有的诊断脱敏函数，并在门内保留两个独立 guard
（快照边界缺失/无效时不打「身份变化」warning）。测试新增
`testRefreshGatesPrefetchedNonPayloadOutcomesUnderADifferentAccountBoundary`（同时覆盖
`noAvailableCredits` 与普通失败两种非 payload 结果），并强化了「RPC 失败不等并发腿」与有界等待。

## 剩余风险

- 计时为单机、单会话、样本量小（各腿 3 轮、A/B 6 轮）的实测；端点延迟抖动明显（本节 A 臂
  2412–3585 ms），中位数只代表量级，不能外推为任意网络下的精确比例。未测 release 计时。
- 新增一次 `auth.json` 读取（≈216–367 µs，且与 RPC 腿并发）与「RPC 腿失败时已发出又被取消的
  一次 HTTPS 请求」。后者在 `codex` 不可用等持续失败状态下会按刷新失败节奏重复出现（失败会退避），
  请求在取消前通常只走到连接阶段；这是本轮唯一新增的对外副作用，已在此记录。
- 取消语义变化：明细腿现在会在刷新被取消时取消一个已在飞行中的请求（此前该请求根本不会发出）。
  生产明细腿用 `URLSession` 的协作式取消，取消后由结构化并发作用域 drain；若将来出现完全不响应
  取消的明细实现，失败刷新会被拖到该实现自身的超时（当前实现为 5 s 请求超时）。
- 身份门在同一刷新内身份变化时比串行判据更严格（见「方向性说明」），会在该次刷新把明细降级为
  `.unavailable` + 身份不一致诊断，下一次刷新恢复。
- 未测 CPU 占用、能耗与内存：本轮改动的收益是壁钟等待时间，不涉及持续计算。
