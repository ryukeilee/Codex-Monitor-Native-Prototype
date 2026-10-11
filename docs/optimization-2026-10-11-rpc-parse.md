# RPC 响应解析路径优化验证（2026-10-11）

以本地代码为准，本轮只优化 `Sources/CodexMonitorNative/Core/CodexAppServerProtocol.swift` 的入站帧解码路径，未改动其他生产文件，也未改动持久化格式、账户边界、错误分类表、配额公式或 UI 行为。

## 目标与修改内容

同一行 stdout 字节此前会被解析两次，并把解析结果再转换回 Foundation 对象：

- 旧 `CodexAppServerCodec.decodeLine` 先用 `JSONSerialization.jsonObject(with:options:[.fragmentsAllowed])` 解析一次（结果只用于拒绝非法 JSON 与非对象顶层），随后用 `JSONDecoder().decode(CodexAppServerMessage.self, from:)` 解析同一份字节；`CodexAppServerJSONValue.init(from:)` 对每个节点依次尝试 `Bool`/`Int64`/`Double`/`String`/keyed 容器/ unkeyed 容器，失败的尝试会抛错并被 `try?` 吞掉。
- `RealQuotaProvider.handleRateLimitsResponse` 随后调用 `result.foundationObject()`，把整棵值树重新构造成 `[String: Any]` 交给 `RealQuotaProvider.parseRateLimits(response:)`。

本轮修改：

1. `decodeLine` 只解析一次：`JSONSerialization` 产出 Foundation 对象，新增的 `private enum CodexAppServerMessageDecoder` 直接从该对象构造 `CodexAppServerMessage`（角色判定、`requestID(from:)`、`remoteError(from:)`、`value(from:)`、`optionalValue(from:)`、`double(from:)`、`integer(from:)`、`numberType(of:)`）。重复的 `JSONSerialization` 探针与 `JSONDecoder` 通道被删除。
2. 数字读取新增 `double(from:)`：`JSONSerialization` 对部分十进制文本返回 `NSDecimalNumber`，其 `doubleValue` 并非最近舍入，而 `Double(decimal.stringValue)`（十进制文本 → double）是正确舍入。该分支只在 `JSONSerialization` 选择十进制存储时生效，普通 double 取值不变。
3. `CodexAppServerRequestID`、`CodexAppServerJSONValue`、`CodexAppServerRemoteError`、`CodexAppServerMessage` 由 `Codable` 改为 `Encodable`，并删除各自的 `init(from:)`：线上解码现在只有一条路径，编码路径（`encodeRequest`/`encodeNotification`/`encodeErrorResponse`）与输出字节格式未变。
4. 测试：`CodexAppServerProtocolTests` 新增 10 个契约测试（数字类型映射、十进制存储精度、超精度整数偏差、`null` 可选语义、非有限数拒绝、结构拒绝、极值下的配额判定与计数行为）；新增 `CodexAppServerProtocolCorpusTests`（111 条线上帧的黄金结果，由修改前的解码器生成，在两棵树上都通过）；`OptimizationBenchmarkTests` 新增 opt-in 基准 `testRPCLineDecodeBaseline`（只使用两棵树共有的 API）。

保留项：`CodexAppServerProtocolViolation` 的分类与优先级、四个协议类型的取值类型与 `Equatable`/`Sendable` 语义、`foundationObject()` 与 `handleLine` 的错误映射（`protocolFrameError()`）、`params`/`data`/`result` 的可选语义、配额解析与账户边界校验。

未完成项：值树构造与 `foundationObject()` 往返转换仍然存在（占优化后 `full` 的约 50% 与 7%，见下）。它们由 `CodexAppServerMessage.response(id:result:)` 的 `CodexAppServerJSONValue` 契约决定，要消除必须改变该类型的表示，属于消息类型契约变更，本轮不扩大范围。

## 可复现 A/B 基准

基准代码：`Tests/CodexMonitorNativeTests/OptimizationBenchmarkTests.swift` 的 `testRPCLineDecodeBaseline`。

```bash
CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests/testRPCLineDecodeBaseline
```

它在同一轮内分别测量 5 个阶段（每条 payload 200 次 × 5 轮，取中位数，debug 配置，单位 ms/次）。计时循环内不执行断言（断言在循环外校验累计值）：

- `json`：一次 `JSONSerialization` 解析；
- `decode`：`CodexAppServerCodec.decodeLine`（含 `json`）；
- `convert`：`result.foundationObject()`；
- `parse`：`RealQuotaProvider.parseRateLimits`（不含 codec，输入为已转换好的对象）；
- `full`：`decodeLine` → `foundationObject` → `parseRateLimits`。

基线获取方式：`git archive HEAD | tar -x -C <临时目录>`，把上述基准测试文件复制进去后在同一台机器运行；工作目录不受影响。

| 阶段 | realistic 基线 | realistic 优化后 | scaled 基线 | scaled 优化后 |
|---|---|---|---|---|
| payload 字节数 | 165 | 165 | 1507 | 1507 |
| json | 0.0032 | 0.0032（-0.3%） | 0.0134 | 0.0137（+2.5%） |
| decode | 0.0758 | 0.0142（**-81.3%**） | 0.6012 | 0.0897（**-85.1%**） |
| convert | 0.0015 | 0.0015（+4.1%） | 0.0102 | 0.0112（+9.9%） |
| parse | 0.0222 | 0.0240（+8.4%） | 0.0399 | 0.0439（+10.2%） |
| **full** | **0.1024** | **0.0405（-60.4%）** | **0.6648** | **0.1504（-77.4%）** |

`full` 端到端吞吐提升：realistic 2.53 倍，scaled 4.42 倍。收益来自 `decode` 阶段被删除的第二次 `JSONSerialization` 探针与 `JSONDecoder`（含每节点 `try?` 级联）。

需要如实说明的是：`convert` 与 `parse` 两列在优化后慢了 4%–10%。新值树里的数字是 `JSONSerialization` 产出的 Foundation 数字（含 `NSDecimalNumber`）而非 `JSONDecoder` 产出的统一 `NSNumber`，下游 `foundationObject()` 与 `parseRateLimits` 的类型判定因此略慢；这部分开销远小于 `decode` 阶段的下降，`full` 仍整体显著变快。第二轮独立审查也各自测到同一方向（其 `parse` +5.2%/+8.7%、`convert` +7.1%/+8.3%）。

`scaled` 用于放大 JSON 占比以便测量；`realistic` 更接近一次刷新实际收到的负载。计时数据来自单机 debug 构建，仅代表解析路径自身开销，不代表端到端刷新耗时（真实刷新由拉起 `codex app-server` 进程主导）、整机能耗或 UI 帧率。

优化后 `full` 的构成（scaled）：`json` 0.0137 + 值树构造 0.0760 + `convert` 0.0112 + `parse` 0.0439。

## 行为等价性证据

对照方式（多路交叉，均在同一台机器、同一份代码树上重复可得）：

1. **协议帧差分夹具（临时，不提交）**：116 条协议帧 + 19 条 `result` 负载，在两棵树（`git archive HEAD` 临时副本与工作目录）各运行一次并逐行 `diff`。每条帧打印规范化结果（`violation:<CaseName>` 或值树完整 dump，显式区分 `.integer`/`.number`/`.bool`/`.null`、`data` 是否存在、id 类型）；每条负载打印 `parseRateLimits` 后的周/五小时百分比与状态、`resetAvailableCount`、窗口 id/剩余百分比/状态/时长。
2. **提交的黄金对照**：`CodexAppServerProtocolCorpusTests` 的 111 条线上帧期望值由修改前的解码器生成，在修改前与修改后两棵树上都通过。
3. **现实取值直接对照**：把两棵树的协议文件与同一份驱动代码编译，对 63 个现实取值（`0.1`、`0.7`、`0.3`、`33.33`、`43.75`、`87.5`、`99.9`、`12.499999999999998`、`0.49999999999999994`、`0.30000000000000004`、`1.5e9`、`1750000000.75`、`300`、`10080`、`5`、`0.05`…`1.95` 等）解码整帧并逐字节比较值树，完全一致。
4. **最短往返表示扫描**：对 11 个数量级窗口（`[1e-6,1e-4)` 至 `[2^53,2^63)`、epoch 秒区间、负值区间）各取 20000 个随机 double 的最短往返表示（Swift `description` / Ryu / Python `repr` 同形），解码后要求等于 `Double(text)`：**220000 个样本 0 个不一致**。
5. **第二轮独立审查的自建夹具**：12483 条协议帧 + 1215 条配额负载（约 1700 万次数值探针），违规分类 **0 行变化**，现实输入导致的快照字段/`RealQuotaError`/`QuotaRefreshStatus`/pending-id 匹配/账户边界/接受性变化 **0 例**；五百万级现实百分比计算 0 个可见整数翻转。

### 唯一残留偏差族：超出 double 精度的整数字面量

当一个 JSON 数字的书写位数超过 double 可承载的精度、且 `JSONSerialization` 把它存成普通 double（数量级 ≥ 2^53 时会出现）时，数字已经是舍入后的 double 像；旧 `JSONDecoder` 会读出书写数字的精确整数。这类文本不是任何 double 的最短往返表示（Rust/Ryu、Python、Swift 的 f64 序列化都不会产生它），因此需要刻意构造或异常序列化才会出现。实测逐行差异全部落在这一族：

| 输入 | 旧 | 新 | 端到端影响 |
|---|---|---|---|
| `{"id":1,"result":9007199254740993.0}` | `integer(9007199254740993)` | `integer(9007199254740992)` | — |
| `{"id":9007199254740993.0,…}` | `integer(9007199254740993)` | `integer(9007199254740992)` | — |
| `{"code":9007199254740993.0,…}` | `code:9007199254740993` | `code:9007199254740992` | — |
| `{"params":{"deep":[{"n":9007199254740993.0}]}}` | `integer(9007199254740993)` | `integer(9007199254740992)` | — |
| `windowDurationMins: 9007199254740993.0` | `9007199254740993` | `9007199254740992` | 窗口种类仍为 `.unknown` |
| `availableCount: 9007199254740993.0` | `9007199254740993` | `9007199254740992` | `resetAvailableCount` 差 1 |
| `availableCount: …993` + `available_count: …993.0` | `9007199254740993`（一致） | `nil`（判定为冲突） | `resetAvailableCount` 为 nil |

真实负载中 id 为 1 起的序号、错误码为 `-32600` 一类、`availableCount` 为个位数、`windowDurationMins` 为 300/10080，均不落入该族。

### 已修复的十进制存储偏差（第一轮审查发现，第二轮给出机理）

第一轮审查发现 `{"remainingPercent":1.49999999999999985}` 会由 `1%` 变成 `2%`；第二轮独立复核给出机理：`JSONSerialization` 对部分十进制文本返回 `NSDecimalNumber`，其 `doubleValue` 不是最近舍入（实测在 `[1e-4,1e-3)`、`[1e-3,1e-2)`、`[1e-2,1e-1)` 窗口分别有 69.9%/64.4%/31.8% 的最短表示被读偏 1–4 ulp）。本轮 `double(from:)` 改为按十进制文本 `Double(decimal.stringValue)` 读取后：

| 输入 | 第一版实现 | 现在 | 旧实现 |
|---|---|---|---|
| `{"remainingPercent":1.49999999999999985}` | 周额度 `2%` | 周额度 `1%` | 周额度 `1%` |
| `{"id":1,"result":1.49999999999999985}` | `number(1.5)` | `number(1.4999999999999998)` | `number(1.4999999999999998)` |
| `{"id":1,"result":0.0077740401686756605}` | `number(0.007774040168675664)` | `number(0.0077740401686756605)` | `number(0.0077740401686756605)` |
| `{"id":9223372036854775670.0,…}` | 接受为 `integer(9223372036854774784)` | `invalidID` | `invalidID` |

修复由 `testDecodesDecimalStoredNumbersAtTheirWrittenPrecision` 与 `testDecimalPercentagesKeepTheirWrittenDecision` 固定；第 4 项（ID 接受性翻转）已回到与旧实现一致。

### 已核实等价的路径

- **协议分类与优先级**：`result`+`error`、`method`+`result`/`error`、`{"id":1,"extra":true}`、缺 id 的 response/error、`method` 非字符串或 `null`、`error` 非对象/缺 code/缺 message/code 为字符串/浮点/布尔/`null`/超界整数、message 非字符串，均给出相同的 `CodexAppServerProtocolViolation`；`params` 解码先于 `id`（`{"id":null,"method":"x","params":-1e400}` 两侧同为 `invalidMessage`）。第二轮独立夹具 12483 帧中分类变化 0 行。
- **`null` 可选语义**：`result: null` 保留 `.null`；`params: null`、`error.data: null` 归一为可选 `nil`（等价于旧 `decodeIfPresent`）。第一版实现遗漏了这一点，由差分夹具发现并修正。
- **非有限数**：`-1e400` 在 `result`/`params`/`error.data`/嵌套对象中均被拒为 `invalidMessage`；`1e400` 为 `invalidJSON`；`id: -1e400` 为 `invalidID`。
- **`Int64.min` 边界**：写在下界附近的整数（`-9223372036854775809`、`-9223372036854776320`）其 double 恰好等于 `Int64.min`，旧解码给 `.number`；新 `integer(from:)` 在浮点分支排除 `Int64.min` 后与旧行为一致（若不排除，新实现会把越界书写值伪造成 `Int64.min`）。裸整数 `-9223372036854775808` 仍经整数存储得到 `.integer(.min)`。
- **可被 double 精确承载的数字**：`1`/`1.0`/`1e2`/`-0.0`/`1.5`/`1e-320`/`9223372036854775807`/`1152921504606846976.0`/`18446744073709551615`/`18446744073709551616`/`1e19`/布尔/`null`/嵌套结构，与旧实现一致。
- **端到端配额判定**：19 条负载中，除上表（残留族）所列 3 条外，周/五小时百分比与状态、窗口集合、窗口种类、`resetAt`、可用次数全部一致；第二轮 1215 条配额负载、五百万级现实百分比计算中 0 例可见翻转。
- **编码路径**：既有 `testEncodesRequestWithoutJSONRPCHeaderOrNewline`、`testEncodesNotificationWithoutID`、`testEncodesErrorResponse` 未改动且通过；测试传输层仍用 `decodeLine` 解析自己写出的帧并做 `Equatable` 比较。

### 为什么没有“既快又逐位相同”的实现

在同一台机器、同一份 1507 字节负载上实测（-O 构建，ms/次）：

| 候选 | 耗时 | 数值语义 |
|---|---|---|
| `JSONSerialization` + 直接构造（本轮采用） | 0.0166 | 十进制文本按精确文本还原；超精度整数字面量按 double 像承载 |
| `JSONDecoder`（旧路径，单次解析） | 0.2129 | 与旧实现逐位相同 |
| 精简版 `JSONDecoder` 值树（去掉多余容器尝试） | 0.2285 | 与旧实现逐位相同 |

公共 Foundation API 里只有 `JSONDecoder` 保留书写数字的精确语义，而它比 `JSONSerialization` 慢约 13 倍，且精简值树实现没有收益（瓶颈在 `JSONDecoder` 内部）。十进制存储路径已通过 `double(from:)` 恢复到与旧实现一致；剩余的唯一差别是普通 double 存储中已经丢失的书写位数，无法从 double 恢复。

## 边界回归与验证

- `swift test`：638 项，0 失败，8 项 opt-in 基准跳过。
- 相关子集：`CodexAppServerProtocolTests`（20 项）、`CodexAppServerProtocolCorpusTests`（111 条帧，在两棵树均通过）、`RealQuotaProviderTests`、`RefreshConsistencyRegressionTests`、`DeterministicFaultScenarioTests`、`ReliabilityProbeTests` 全部通过。
- `swift build -c debug`、`swift build -c release` 通过；`git diff --check` 通过。
- `CodexAppServerProtocol.swift` 不在 Widget Xcode target 的 Sources build phase 中（`project.pbxproj` 无引用），本轮未改动任何 Widget 共享编译单元，也未改动持久化模型或载荷格式。
- 本轮未执行会替换已安装 bundle 的 `./script/build_and_run.sh --verify`，也未做人工 UI 检查：改动不涉及签名、entitlements、安装路径、菜单栏标题、Popover 或 Widget 呈现。

## 独立审查

**第 1 轮（codex / gpt-6.1-sol，只读静态审查 + 两棵树实验）**：3 项 BLOCKER、2 项 NIT。

- BLOCKER 1「小数 1 ulp 会改变可信周额度」：成立（`{"remainingPercent":1.49999999999999985}` 旧 `1%` / 当时实现 `2%`）。已定位机理并修复（`double(from:)`），现与旧实现一致。
- BLOCKER 2「整数转换改变拒绝行为与可用次数」：部分成立。`{"id":9223372036854775670.0,…}` 的接受性翻转已随同一修复回到 `invalidID`；`9007199254740993.0` 一类的超精度整数字面量无法从 double 恢复，作为唯一残留族记录并加测试。
- BLOCKER 3「值树往返转换仍在」：事实成立，已在「目标与修改内容」与「剩余风险」中标注为未完成项，并说明消除需要改变 `CodexAppServerJSONValue` 的表示（本轮范围外）。
- NIT 1（DEBUG 解析计数器不能证明解析次数）：已删除计数器与其测试，改为结构化的 `testRejectsFramesBeforeBuildingAnyMessage` 加基准阶段数据。
- NIT 2（基准 `parse` 列注释与实现不符）：已修正注释，明确 `parse` 只测已转换对象上的配额解析。

**第 2 轮（opencode / deepseek-v4.1-flash，跨 provider 独立复核）**：结论 **无 BLOCKER**；确认违规分类 0 行变化、现实输入 0 例决策变化，并独立复现了基线与优化后的 A/B 数值（方向与幅度一致）。

- NIT 1（重要）：第一轮偏差族的机理、触发范围与支撑证据描述错误——真实机理是 `NSDecimalNumber.doubleValue` 非最近舍入，触发的是**规范最短往返表示**（`[1e-4,1e-1)` 区间错读率 32%–70%），最大偏差 4 ulp，而不是“仅刻意构造的 17 位文本、1 ulp”。已按其建议在 `value(from:)` 的十进制路径改用 `Double(decimal.stringValue)`，并以 220000 条最短表示扫描（0 不一致）与新增测试固定；文档与注释（含 `CodexAppServerProtocolCorpusTests` 头注释）同步改为正确描述。
- NIT 2：基准表 `scaled parse` 符号错误，且 `json/convert/parse` 并非“两端基本不变”——`convert` 与 `parse` 实际变慢 4%–10%。已修正符号与表述，并在基准一节如实列出该回归及其原因。
- NIT 3：测试总数与文档不符。已按最终提交状态更新为 638 项 / 8 跳过 / 0 失败。
- NIT 4：两处注释隐含“唯一偏差族是超过 double 精度的数字”，已更新为十进制存储路径 + 超精度整数两族（其中前者已修复）。
- NIT 5：基准 `full` 循环内含 `XCTAssert`，会抬高绝对值。已把断言移出所有计时循环（改为循环外校验累计值）并重新测量，`full` 结论不变。

## 收敛结论

第二轮独立审查未发现阻塞问题；其提出的 5 项 NIT 全部已修复或已如实记录。第一轮的两项语义问题中，十进制精度问题已通过 `double(from:)` 修复并回到与旧实现一致，接受性翻转随之消失；剩余的唯一偏差族是“书写位数超过 double 承载的整数字面量”，它无法从 double 恢复，已用测试固定并在文档中列表化。收益由两棵树上同一份基准文件实测，并由第二轮独立复现。

## 剩余风险与未验证项

- **唯一残留偏差族（未解决）**：JSON 整数字面量超过 double 精度且被 `JSONSerialization` 存为普通 double 时（≥2^53），值树与 `durationMinutes`/`resetAvailableCount` 会相差 1，或两个别名拼写由一致变为冲突；这类文本不是任何 double 的最短往返表示，正常 f64 序列化不会产生。要消除它需要放弃 `JSONSerialization`（即放弃本轮收益），或改变值表示以保留原始文本。详见上文表格。
- **未消除的往返转换**：值树构造（占优化后 `full` 约 50%）与 `foundationObject()`（约 7%）仍在；消除它们需要改变 `CodexAppServerJSONValue` 的表示，未在本轮范围。
- **`convert`/`parse` 阶段小幅变慢（4%–10%）**：新值树的数字来自 `JSONSerialization`（含 `NSDecimalNumber`），下游类型判定略慢；`full` 整体仍下降 60%–77%，但该回归确实存在且由两轮审查各自测到。
- **计时数据来自本机 debug 构建**；仓库现有测试依赖 DEBUG 默认参数，release 配置下测试不可编译，因此没有 release 计时结论。
- **未对真实 `codex app-server` 进程做端到端联调**：解析路径由既有 RPC 测试的合成帧、111 条黄金对照与两轮审查的差分夹具覆盖，未采样真实进程的负载字段分布。
- 删除 `Decodable` 后这些类型不再能被 `JSONDecoder` 解码（当前无调用方）；若将来需要该能力需重新实现 `init(from:)`。
- 本轮未执行 `./script/build_and_run.sh --verify`（会替换已安装 bundle，属外部状态变更），也未进行人工 UI 检查。
