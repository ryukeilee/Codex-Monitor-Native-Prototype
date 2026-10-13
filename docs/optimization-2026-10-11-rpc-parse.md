# RPC 响应解析路径优化验证（2026-10-11）

以本地代码为准，本轮只优化 `Sources/CodexMonitorNative/Core/CodexAppServerProtocol.swift` 的入站帧解码路径，未改动其他生产文件，也未改动持久化格式、账户边界、错误分类表、配额公式或 UI 行为。

## 兼容性验收（本轮追加）

本轮不改变解码行为，只做验收、证据补全与文档更正。结论与改动如下：

- **真实 `codex app-server` 端到端联调已完成**（原文档列为未验证项）。新增 opt-in 测试 `Tests/CodexMonitorNativeTests/LiveCodexAppServerProtocolTests.swift`，在本机 `codex-cli 0.162.1` 上通过：真实帧全部可解码、线上数字与解码结果逐值一致、握手字段齐备、真实 `-32600` 拒绝帧形状符合预期、生产刷新路径返回绑定账户的可用快照。
- **残留偏差族的描述已更正。** 原文档称该族“不是任何 double 的最短往返表示，Rust/Ryu、Python、Swift 的 f64 序列化都不会产生它”，此说法**不成立**：正常最短往返文本（例如 `1.152921504606847e+18`）同样落入该族。原“220000 个最短表示样本 0 不一致”的扫描只比较了 double 取整结果，无法发现 `.integer` 的精确值差异，因此不能作为该结论的证据。更正后的族、量级边界与不可达性论证见「残留偏差族」一节。
- **不修改数值语义的决定有实测依据**：两个“读取书写数字”的原型都在两棵树上实测过，A 使总差异从 516 条升到 536 条，接受性翻转的差分行数从 2 行升到 9 行（涉及 3 个新文本，其中 `9223372036854775670.0` 在网格里占 3 行），B 降到 186 条但仍无法归零，且需要 `Decimal(Double)`（对 `Double.infinity` 会 SIGTRAP）。详见「修复评估」一节。
- **生产文件本轮只有注释变化**：`CodexAppServerProtocol.swift` 的偏差族说明改为准确表述；测试新增 2 项契约测试、5 条真实脱敏帧黄金对照与 2 项 opt-in 真实联调测试。

## 目标与修改内容

同一行 stdout 字节此前会被解析两次，并把解析结果再转换回 Foundation 对象：

- 旧 `CodexAppServerCodec.decodeLine` 先用 `JSONSerialization.jsonObject(with:options:[.fragmentsAllowed])` 解析一次（结果只用于拒绝非法 JSON 与非对象顶层），随后用 `JSONDecoder().decode(CodexAppServerMessage.self, from:)` 解析同一份字节；`CodexAppServerJSONValue.init(from:)` 对每个节点依次尝试 `Bool`/`Int64`/`Double`/`String`/keyed 容器/ unkeyed 容器，失败的尝试会抛错并被 `try?` 吞掉。
- `RealQuotaProvider.handleRateLimitsResponse` 随后调用 `result.foundationObject()`，把整棵值树重新构造成 `[String: Any]` 交给 `RealQuotaProvider.parseRateLimits(response:)`。

本轮修改：

1. `decodeLine` 只解析一次：`JSONSerialization` 产出 Foundation 对象，新增的 `private enum CodexAppServerMessageDecoder` 直接从该对象构造 `CodexAppServerMessage`（角色判定、`requestID(from:)`、`remoteError(from:)`、`value(from:)`、`optionalValue(from:)`、`double(from:)`、`integer(from:)`、`numberType(of:)`）。重复的 `JSONSerialization` 探针与 `JSONDecoder` 通道被删除。
2. 数字读取新增 `double(from:)`：`JSONSerialization` 对部分十进制文本返回 `NSDecimalNumber`，其 `doubleValue` 并非最近舍入，而 `Double(decimal.stringValue)`（十进制文本 → double）是正确舍入。该分支只在 `JSONSerialization` 选择十进制存储时生效，普通 double 取值不变。
3. `CodexAppServerRequestID`、`CodexAppServerJSONValue`、`CodexAppServerRemoteError`、`CodexAppServerMessage` 由 `Codable` 改为 `Encodable`，并删除各自的 `init(from:)`：线上解码现在只有一条路径，编码路径（`encodeRequest`/`encodeNotification`/`encodeErrorResponse`）与输出字节格式未变。
4. 测试：`CodexAppServerProtocolTests` 新增 10 个契约测试（数字类型映射、十进制存储精度、超精度整数偏差、`null` 可选语义、非有限数拒绝、结构拒绝、极值下的配额判定与计数行为）；新增 `CodexAppServerProtocolCorpusTests`（线上帧黄金结果，由修改前的解码器生成，在两棵树上都通过）；`OptimizationBenchmarkTests` 新增 opt-in 基准 `testRPCLineDecodeBaseline`（只使用两棵树共有的 API）。

保留项：`CodexAppServerProtocolViolation` 的分类与优先级、四个协议类型的取值类型与 `Equatable`/`Sendable` 语义、`foundationObject()` 与 `handleLine` 的错误映射（`protocolFrameError()`）、`params`/`data`/`result` 的可选语义、配额解析与账户边界校验。

未完成项：值树构造与 `foundationObject()` 往返转换仍然存在（占优化后 `full` 的约 50% 与 7%，见下）。它们由 `CodexAppServerMessage.response(id:result:)` 的 `CodexAppServerJSONValue` 契约决定，要消除必须改变该类型的表示，属于消息类型契约变更，本轮不扩大范围。**后续（2026-10-13）**：生产路径已改用 `CodexAppServerInboundFrame` 直接消费原始 Foundation 载荷，类型化消息契约保留；见 `optimization-2026-10-13-rpc-inbound-frame.md`。

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

基线获取方式：`git archive HEAD | tar -x -C <临时目录>`，把同一份基准文件复制进去后在同一台机器运行；工作目录不受影响。

第一轮（实现提交时）实测：

| 阶段 | realistic 基线 | realistic 优化后 | scaled 基线 | scaled 优化后 |
|---|---|---|---|---|
| payload 字节数 | 165 | 165 | 1507 | 1507 |
| json | 0.0032 | 0.0032（-0.3%） | 0.0134 | 0.0137（+2.5%） |
| decode | 0.0758 | 0.0142（**-81.3%**） | 0.6012 | 0.0897（**-85.1%**） |
| convert | 0.0015 | 0.0015（+4.1%） | 0.0102 | 0.0112（+9.9%） |
| parse | 0.0222 | 0.0240（+8.4%） | 0.0399 | 0.0439（+10.2%） |
| **full** | **0.1024** | **0.0405（-60.4%）** | **0.6648** | **0.1504（-77.4%）** |

本轮验收在同一台机器上用同一份基准在两棵树上重测，结论一致（生产代码未变，差异属运行噪声）：

| 阶段 | realistic 基线 | realistic 当前 | scaled 基线 | scaled 当前 |
|---|---|---|---|---|
| json | 0.0031 | 0.0032（+2.2%） | 0.0133 | 0.0134（+0.6%） |
| decode | 0.0749 | 0.0145（**-80.7%**） | 0.5886 | 0.0883（**-85.0%**） |
| convert | 0.0015 | 0.0014（-1.7%） | 0.0101 | 0.0100（-0.8%） |
| parse | 0.0223 | 0.0239（+7.1%） | 0.0396 | 0.0436（+10.0%） |
| **full** | **0.1014** | **0.0419（-58.7%）** | **0.6442** | **0.1464（-77.3%）** |

`full` 端到端吞吐提升：realistic 约 2.4 倍，scaled 约 4.4 倍。收益来自 `decode` 阶段被删除的第二次 `JSONSerialization` 探针与 `JSONDecoder`（含每节点 `try?` 级联）。

需要如实说明的是：`convert` 与 `parse` 在两次测量中呈 0%–10% 的小幅变慢（本轮 `convert` 两列分别为 -1.7% 与 -0.8%，属噪声）。新值树里的数字是 `JSONSerialization` 产出的 Foundation 数字（含 `NSDecimalNumber`）而非 `JSONDecoder` 产出的统一 `NSNumber`，下游 `foundationObject()` 与 `parseRateLimits` 的类型判定因此略慢；这部分开销远小于 `decode` 阶段的下降，`full` 仍整体显著变快。

`scaled` 用于放大 JSON 占比以便测量；`realistic` 更接近一次刷新实际收到的负载。计时数据来自单机 debug 构建，仅代表解析路径自身开销，不代表端到端刷新耗时（真实刷新由拉起 `codex app-server` 进程主导）、整机能耗或 UI 帧率。

优化后 `full` 的构成（scaled，第一轮）：`json` 0.0137 + 值树构造 0.0760 + `convert` 0.0112 + `parse` 0.0439。

## 行为等价性证据

对照方式（多路交叉，均在同一台机器、同一份代码树上重复可得）：

1. **协议帧差分夹具（临时，不提交）**：116 条协议帧 + 19 条 `result` 负载，在两棵树（`git archive HEAD` 临时副本与工作目录）各运行一次并逐行 `diff`。每条帧打印规范化结果（`violation:<CaseName>` 或值树完整 dump，显式区分 `.integer`/`.number`/`.bool`/`.null`、`data` 是否存在、id 类型）；每条负载打印 `parseRateLimits` 后的周/五小时百分比与状态、`resetAvailableCount`、窗口 id/剩余百分比/状态/时长。
2. **提交的黄金对照**：`CodexAppServerProtocolCorpusTests` 的期望值由修改前的解码器生成，在修改前与修改后两棵树上都通过。本轮新增 5 条来自真实 `codex-cli 0.162.1` 会话的脱敏帧（账户与安装标识已替换），仍是两棵树都通过。
3. **现实取值直接对照**：把两棵树的协议文件与同一份驱动代码编译，对 63 个现实取值（`0.1`、`0.7`、`0.3`、`33.33`、`43.75`、`87.5`、`99.9`、`12.499999999999998`、`0.49999999999999994`、`0.30000000000000004`、`1.5e9`、`1750000000.75`、`300`、`10080`、`5`、`0.05`…`1.95` 等）解码整帧并逐字节比较值树，完全一致。
4. **最短往返表示扫描（本轮更正）**：第一轮的扫描对 11 个数量级窗口各取 20000 个随机 double 的最短往返表示，要求“解码结果等于 `Double(text)`”，结论是 0 不一致。该判据只比较 double 取整后的值，**无法发现 `.integer` 的精确值差异**，因此不能证明兼容性。本轮改为按 binade 直接比较 `.integer` 精确值：`[2^50,2^54)` 共 80000 个样本 **0 不一致**；`[2^54,2^55)` 起开始出现差异（该窗 25.1%），到 `[2^62,2^63)` 为 99.1%。独立审查（第 3 轮）用 Python `repr`、真实 `serde_json 1.0.152`、真实 `ryu 1.0.23` 三种 writer 生成 720000 条文本（240000 个不同 f64），每种 writer 有 33571 条差异，全部落在 `[2^54,2^60)` 与 `[2^60,2^63)` 窗口；`[1e-6,1)`、`[1,1e9)`、epoch 秒、epoch 毫秒、`[1e12,2^53)`、`[2^53,2^54)` 均为 0。
5. **第二轮独立审查的自建夹具**：12483 条协议帧 + 1215 条配额负载（约 1700 万次数值探针），违规分类 **0 行变化**，现实输入导致的快照字段/`RealQuotaError`/`QuotaRefreshStatus`/pending-id 匹配/账户边界/接受性变化 **0 例**；五百万级现实百分比计算 0 个可见整数翻转。
6. **本轮 7510 帧差分**：111 条提交黄金帧 + 7392 条数值网格帧（含 `2^53`/`2^63`/`UInt64` 边界、11 种字面量形式、600 个随机 16–25 位整数、700 个随机最短往返 double）+ 7 条真实脱敏帧，在两棵树上各跑一次并逐帧比较规范化结果与 `parseRateLimits` 投影。差异 **516 条，全部在数值网格中**；提交黄金帧 **0 条**、真实帧 **0 条**。

## 残留偏差族（本轮核实并更正）

偏差机理：新解码把浮点存储读作 **double 像**（整数值且能表示成 `Int64` 时给 `.integer`），旧 `JSONDecoder` 则转换 **书写数字**。当书写文本的有效位数超过 double 可承载的精度时两者不同。原文档只描述了“超过 double 精度的整数字面量”一类，且错误地断言这类文本不会被正常 f64 writer 产生。实际存在的族如下：

| 族 | 输入示例 | 旧 | 新 | 正常 writer 可产生 |
|---|---|---|---|---|
| 1 | `1.152921504606847e+18`（最短往返文本） | `integer(1152921504606847000)` | `integer(1152921504606846976)` | **是**（serde_json / Ryu / Python `repr`） |
| 2 | `9007199254740991.5`（分数文本，double 取整为整数） | `integer(9007199254740991)` | `integer(9007199254740992)` | 否（最短往返 writer 不会输出该文本） |
| 3 | `9007199254740993.0`（人为超精度文本） | `integer(9007199254740993)` | `integer(9007199254740992)` | 否 |
| 4 | `-9223372036854775804.0`（负值落在 `Int64.min` 的 double 像内） | 接受为 `integer(-9223372036854775804)` | `invalidID` / `malformedError` | 否 |

族的边界与不可达性：

- 族 1 的边界是**量级**而不是有效位数：文本的十进制整数与 double 的精确整数不同才会触发，这需要量级 ≥2^53（更低时 double 能精确表示整数），而实测差异只在 **≥2^54** 出现——`[2^50,2^54)` 的 80000 个最短往返样本 0 差异；三种真实 writer 的 720000 条文本中差异只出现在 `[2^54,2^63)`。样本中最小的差异文本 `3.175517239614493e+16` 只有 16 位有效数字，因此“17 位文本”不是判据。
- 配额路径消费的每个数字都远低于该边界：百分比 0–100、窗口时长 300/10080、epoch 秒约 `1.8e9`（2^31）、重置次数为个位数。
- 真实负载中最大的数字是 `emittedAtMs` 约 `1.79e12`（2^41），它是通知信封里的顶层字段，模型按既有契约忽略（旧实现同样忽略），且写成裸整数（两版一致）。
- 真实帧实测：7 条帧共 33 个数字，**浮点语法字面量 0 个**，全部为整数语法。
- 族的**接受性**只在族 4 改变，且需要负值恰好落在 `Int64.min` 的 double 像内并写成浮点语法；真实 `id` 为 1 起的序号、错误码为 `-32600` 一类，不会触及。

族 1 与族 2 的 `.integer` 精确值差异（例如 `1152921504606847000` vs `1152921504606846976`）不会改变任何配额判定：这些量级的百分比会因超出 `0...100` 被丢弃，时长会因不等于 300/10080 归为 `.unknown`，epoch 秒会得到一个远未来时间，两者行为一致。上述族的输入均已由 `CodexAppServerProtocolTests` 固定（`testDecodesNumbersBeyondDoublePrecisionAtDoublePrecision`、`testFloatSyntaxBoundaryNumbersPinValuesAndTheInt64MinRejection`、`testShortestRoundTripTextsBelowTheDeviationBoundaryMatchTheLegacyConversion`）。

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

- **协议分类与优先级**：`result`+`error`、`method`+`result`/`error`、`{"id":1,"extra":true}`、缺 id 的 response/error、`method` 非字符串或 `null`、`error` 非对象/缺 code/缺 message/code 为字符串/浮点/布尔/`null`/超界整数、message 非字符串，均给出相同的 `CodexAppServerProtocolViolation`；`params` 解码先于 `id`（`{"id":null,"method":"x","params":-1e400}` 两侧同为 `invalidMessage`）。第二轮独立夹具 12483 帧与本轮 7510 帧差分中，除族 4 的 2 条外分类变化 0 行。
- **`null` 可选语义**：`result: null` 保留 `.null`；`params: null`、`error.data: null` 归一为可选 `nil`（等价于旧 `decodeIfPresent`）。第一版实现遗漏了这一点，由差分夹具发现并修正。
- **非有限数**：`-1e400` 在 `result`/`params`/`error.data`/嵌套对象中均被拒为 `invalidMessage`；`1e400` 为 `invalidJSON`；`id: -1e400` 为 `invalidID`。
- **`Int64.min` 边界**：写在下界附近的整数（`-9223372036854775809`、`-9223372036854776320`）其 double 恰好等于 `Int64.min`，旧解码给 `.number`；新 `integer(from:)` 在浮点分支排除 `Int64.min` 后与旧行为一致（若不排除，新实现会把越界书写值伪造成 `Int64.min`）。裸整数 `-9223372036854775808` 仍经整数存储得到 `.integer(.min)`。
- **可被 double 精确承载的数字**：`1`/`1.0`/`1e2`/`-0.0`/`1.5`/`1e-320`/`9223372036854775807`/`1152921504606846976.0`/`18446744073709551615`/`18446744073709551616`/`1e19`/布尔/`null`/嵌套结构，与旧实现一致。
- **端到端配额判定**：19 条负载中，除上表（残留族）所列 3 条外，周/五小时百分比与状态、窗口集合、窗口种类、`resetAt`、可用次数全部一致；第二轮 1215 条配额负载、五百万级现实百分比计算中 0 例可见翻转；本轮 7 条真实帧的 `parseRateLimits` 投影 0 变化。
- **编码路径**：既有 `testEncodesRequestWithoutJSONRPCHeaderOrNewline`、`testEncodesNotificationWithoutID`、`testEncodesErrorResponse` 未改动且通过；测试传输层仍用 `decodeLine` 解析自己写出的帧并做 `Equatable` 比较。

## 修复评估：为什么保持数值语义不变

本轮实现并实测了两个“读取书写数字”的原型，在同一份 7510 帧差分上比较（`total` = 与旧解码不同的帧数）：

| 变体 | total | 提交黄金帧 | 真实帧 | 接受性翻转（差分行数） | 结论 |
|---|---|---|---|---|---|
| 当前实现（double 像） | 516 | 0 | 0 | 2 | 采用 |
| 原型 A：`NSDecimalNumber.stringValue` 数字能表示成 `Int64` 时优先 | 536 | 2 | 0 | 9 | 变差，弃用 |
| 原型 B：double 像在 `Int64` 范围内时优先用数字（普通 double 走 `decimalValue`） | 186 | 0 | 0 | 2 | 无法归零，弃用 |

- 原型 A 变差的原因：旧解码对 `9223372036854775807.0`、`9223372036854775806.0`、`9223372036854775670.0` 一类**正数靠近 `Int64.max` 的文本给 `.number`**（double 像为 2^63，越界），而数字本身在范围内；按数字读取会把这些文本变成 `.integer` 并引入新的接受性翻转（`id` 与 `code` 两个位置各 3 个文本）。旧行为在这一带存在符号不对称的边界（`-9223372036854775807.0` 反而被接受为精确数字），不是“数字能放下就用数字”这一条规则能复现的。
- 原型 B 把差异降到 186 条但无法归零：族 2（分数文本被旧实现截断）、族 4 与部分族 3 仍在，因为 `decimalValue` 给出的是 double 的最短往返文本，而不是书写文本。
- 原型 B 还引入一处崩溃风险：`Decimal(Double)` 对 `Double.infinity` 会 **SIGTRAP**（本机实测 `Decimal(Double.infinity)` 直接终止进程；`1e300`、`greatestFiniteMagnitude` 则静默变成 `NaN`）。当前实现只在 `double.isFinite` 之后才可能做十进制转换，而 `decimalValue` 路线把转换放在任意浮点存储上，一旦将来调整判断顺序就可能被 `-1e400` 这类负载触发。
- 因此本轮不采用任何“数字优先”的补丁：它既无法恢复逐位一致，又把一条可解释的规则（浮点存储 = double 像）换成依赖 Foundation 内部怪癖与符号边界的规则，并把崩溃风险引入解码路径。取而代之的是把族、边界与不可达性写清楚，并用测试固定。

## 为什么没有“既快又逐位相同”的实现

在同一台机器、同一份 1507 字节负载上实测（-O 构建，ms/次）：

| 候选 | 耗时 | 数值语义 |
|---|---|---|
| `JSONSerialization` + 直接构造（本轮采用） | 0.0166 | 十进制文本按精确文本还原；浮点存储按 double 像承载 |
| `JSONDecoder`（旧路径，单次解析） | 0.2129 | 与旧实现逐位相同 |
| 精简版 `JSONDecoder` 值树（去掉多余容器尝试） | 0.2285 | 与旧实现逐位相同 |

公共 Foundation API 里只有 `JSONDecoder` 保留书写数字的精确语义，而它明显更慢，且精简值树实现没有收益（瓶颈在 `JSONDecoder` 内部）。需要说明的是：上表来自实现轮，本轮未复测，其夹具细节未留存；独立审计在自己的 -O 夹具上测得 1507 字节负载 `JSONDecoder` 0.2318 ms、`JSONSerialization`＋直接构造 0.0926 ms（差约 2.5 倍），与本表第 1 行（0.0166 ms）相差 5 倍以上。因此**该表的绝对值和“13 倍”不应作为验收依据**；可复现的收益以 debug 基准（`decode` −81%/−85%、`full` −60%/−77%）与两棵树的 A/B 实测为准，两者都由本轮与审查独立复现。十进制存储路径已通过 `double(from:)` 恢复到与旧实现一致；剩余差别来自浮点存储中已经丢失的书写位数，无法从 double 恢复（独立审查另行确认：默认及 7 种 `JSONSerialization.ReadingOptions` 配置都不保留数字原文）。

## 真实 `codex app-server` 联调（本轮新增）

测试：`Tests/CodexMonitorNativeTests/LiveCodexAppServerProtocolTests.swift`，默认跳过。

```bash
CODEX_MONITOR_LIVE_CODEX=1 swift test --filter LiveCodexAppServerProtocolTests
```

两项测试：

1. `testRealAppServerFramesDecodeAndPreserveEveryWireNumber`：用生产 `ProcessRPCTransport` 驱动真实 `codex app-server`，按生产编码器发送 `initialize`、`initialized`、`account/rateLimits/read` 与一个未知方法，然后断言：每一帧都能通过 `decodeLine`；**线上数字字面量与解码出的数字多重集逐值相等**（扫描器独立于 codec，按字符串状态跳过字符串字面量，并只比较模型读取的顶层字段——真实通知信封带有模型忽略的顶层 `emittedAtMs`）；`initialize` 结果含握手要求的 4 个字符串字段；未知方法返回 `.error(code:-32600, message:…, data:nil)`；真实配额负载经 `parseRateLimits` 得到当前可用的周窗口。
2. `testRealAppServerRefreshProducesABoundUsableSnapshot`：用生产 `CodexRPCClient`（真实 transport、真实 `auth.json` 边界读取器）完成一次完整刷新，断言返回账户边界有效、周窗口 `durationMinutes == 10080` 且状态为 `.live`、`weeklyQuotaPercent == 周窗口 remainingPercent`，并对同一次刷新捕获的所有帧重复数字多重集校验。

本机实测（`codex-cli 0.162.1`，macOS 27.0.1 arm64）：两项均通过，多次运行共捕获 3–5 帧（客户端拿到响应后立即关闭进程，启动通知流的尾部会被丢弃；测试只强制要求三个响应帧），真实负载解析出 2 个窗口（周/五小时均 `.live`），无违规、无数字差异。

限制：需要本机安装 `codex` 且已登录（否则按 `XCTSkip` 报告为跳过，不会伪装成通过）；只覆盖一个账号状态与一个服务端版本；不覆盖超时、进程死亡、认证失败等失败路径（这些仍由合成测试覆盖）。测试不打印或持久化账户、会话或 `auth.json` 内容，只输出帧数、窗口数与百分比。

## 边界回归与验证

- `swift test`：643 项，10 项跳过（8 项 opt-in 基准 + 2 项 opt-in 真实联调），0 失败。
- `CODEX_MONITOR_LIVE_CODEX=1 swift test --filter LiveCodexAppServerProtocolTests`：2 项通过（真实 `codex-cli 0.162.1`）。
- 相关子集：`CodexAppServerProtocolTests`（22 项）、`LiveCodexAppServerProtocolTests`（3 项，其中 1 项为不依赖进程的扫描器对照测试）、`CodexAppServerProtocolCorpusTests`（116 条帧，在两棵树均通过）、`RealQuotaProviderTests`、`RefreshConsistencyRegressionTests`、`DeterministicFaultScenarioTests`、`ReliabilityProbeTests` 全部通过。
- `swift build -c debug`、`swift build -c release` 通过；`git diff --check` 通过。
- `CodexAppServerProtocol.swift` 不在 Widget Xcode target 的 Sources build phase 中（`project.pbxproj` 无引用），本轮未改动任何 Widget 共享编译单元，也未改动持久化模型或载荷格式。
- 本轮未执行会替换已安装 bundle 的 `./script/build_and_run.sh --verify`，也未做人工 UI 检查：改动不涉及签名、entitlements、安装路径、菜单栏标题、Popover 或 Widget 呈现。

## 独立审查

**第 1 轮（codex / gpt-6.1-sol，只读静态审查 + 两棵树实验）**：3 项 BLOCKER、2 项 NIT。

- BLOCKER 1「小数 1 ulp 会改变可信周额度」：成立（`{"remainingPercent":1.49999999999999985}` 旧 `1%` / 当时实现 `2%`）。已定位机理并修复（`double(from:)`），现与旧实现一致。
- BLOCKER 2「整数转换改变拒绝行为与可用次数」：部分成立。`{"id":9223372036854775670.0,…}` 的接受性翻转已随同一修复回到 `invalidID`；超精度整数字面量无法从 double 恢复，当时作为唯一残留族记录并加测试。
- BLOCKER 3「值树往返转换仍在」：事实成立，已在「目标与修改内容」与「剩余风险」中标注为未完成项，并说明消除需要改变 `CodexAppServerJSONValue` 的表示（本轮范围外）。
- NIT 1（DEBUG 解析计数器不能证明解析次数）：已删除计数器与其测试，改为结构化的 `testRejectsFramesBeforeBuildingAnyMessage` 加基准阶段数据。
- NIT 2（基准 `parse` 列注释与实现不符）：已修正注释，明确 `parse` 只测已转换对象上的配额解析。

**第 2 轮（opencode / deepseek-v4.1-flash，跨 provider 独立复核）**：结论 **无 BLOCKER**；确认违规分类 0 行变化、现实输入 0 例决策变化，并独立复现了基线与优化后的 A/B 数值（方向与幅度一致）。

- NIT 1（重要）：第一轮偏差族的机理、触发范围与支撑证据描述错误——真实机理是 `NSDecimalNumber.doubleValue` 非最近舍入，触发的是**规范最短往返表示**（`[1e-4,1e-1)` 区间错读率 32%–70%），最大偏差 4 ulp，而不是“仅刻意构造的 17 位文本、1 ulp”。已按其建议在 `value(from:)` 的十进制路径改用 `Double(decimal.stringValue)`，并新增测试固定；文档与注释同步改为正确描述。
- NIT 2：基准表 `scaled parse` 符号错误，且 `json/convert/parse` 并非“两端基本不变”——`convert` 与 `parse` 实际变慢 0%–10%。已修正符号与表述，并在基准一节如实列出该回归及其原因。
- NIT 3：测试总数与文档不符。已按最终提交状态更新。
- NIT 4：两处注释隐含“唯一偏差族是超过 double 精度的数字”，已更新。
- NIT 5：基准 `full` 循环内含 `XCTAssert`，会抬高绝对值。已把断言移出所有计时循环（改为循环外校验累计值）并重新测量，`full` 结论不变。

**第 3 轮 a（codex / gpt-6.1-sol，跨 provider 数值语义独立审计）**：结论 **“正常 JSON writer 可达的整数语义回归成立”**，并推翻了原文档的两条支撑论据。

- 用真实 writer 生成 720000 条文本（Python `repr`、`serde_json 1.0.152`、`ryu 1.0.23` 各 240000 条，覆盖 12 个数量级窗口）：每种 writer 有 **33571 条**与旧解码的精确整数不同；全部落在 `[2^54,2^60)`（14089 条/窗）与 `[2^60,2^63)`（19482 条/窗）；epoch 秒、epoch 毫秒、`[1e12,2^53)`、`[2^53,2^54)` 窗口 0 差异。据此确认：最短往返表示只保证回读为同一个 f64，**不保证文本里的十进制整数等于该 f64 的精确整数**，而第一轮“220000 样本 0 不一致”的判据只比较 double，因此漏掉了这一族。
- 4,019 条边界文本网格：943 条差异，其中 **753 条是 `NSDecimalNumber` 存储**（数字仍在 `stringValue` 中却被丢弃），190 条是普通 double；另给出分数文本截断（`9007199254740991.5` → 旧 `9007199254740991`）与 `-9223372036854775804.0` 的接受性翻转。
- 确认 `9007199254740993.0` 是普通 double（数字已丢失，无法恢复），且默认与 7 种 reading-options 配置都不保留数字原文。
- 该审计未给出修复建议；其数据是本轮「修复评估」中两个原型的输入。

**第 3 轮 b（本轮改动的独立审查）**：见下节「本轮审查结论」。

## 本轮审查结论

**第 3 轮 b（opencode / deepseek-v4.1-flash，跨 provider 对抗性审查）**：结论 **1 项 BLOCKER（注释/文档级虚假声明，非运行时代码缺陷）+ 3 项 NIT**；生产解码路径零行为变化，性能与证据链主张基本成立。审查在只读模式下进行，审查结束时仓库状态与本轮改动一致（审查者未修改仓库）。

处理结果（全部已修复）：

- **BLOCKER B1**：`CodexAppServerProtocolTests` 的注释声称该族“不改变消息分类”，但同一测试固定的两条 `-9223372036854775807.0` 用例恰是族 4 的接受→拒绝翻转（审查者在改前树复现：旧树接受，当前实现拒绝），且与本文件族 4 的表格自相矛盾。**已修复**：注释重写为“值映射按 double 像、接受性唯一例外是族 4 的 `Int64.min` 拒绝”，测试更名为 `testFloatSyntaxBoundaryNumbersPinValuesAndTheInt64MinRejection`，语料库头与本文件的引用同步更新。
- **NIT N1**：live 测试的数字扫描器对**重复对象键**与 Foundation 不一致（`JSONSerialization` 只保留第一次出现，扫描器把两次都计入），会造成假失败。**已修复**：扫描器改为按每个已打开对象记录已见键（任意深度），重复键只计第一次；新增不依赖进程的 hermetic 对照测试 `testWireNumberScannerAgreesWithTheDecodedEnvelope`，对重复键、未建模顶层键（含容器值）、字符串内数字、转义、`-0.0`、`Int64.min`、次正规数等 15 条帧直接断言 `wireNumbers == decodedNumbers`。审查者的 fuzz（39,182 帧、818 条非法帧、0 mismatch）确认除重复键外扫描器与解码器一致。
- **NIT N2**：本文件“接受性翻转 2→8”混用了“不同文本数”与“差分行数”。**已修复**：表格列改为“接受性翻转（差分行数）”（当前实现 2、原型 A 9、原型 B 2），正文注明 9 行涉及 3 个新文本、其中 `9223372036854775670.0` 在网格里占 3 行。
- **NIT N3**：`reportServerVersion` 无超时，审查者用永不退出的假 `CODEX_BIN` 复现了 170 s 以上的挂起（栈停在 `readDataToEndOfFile`）。**已修复**：版本探测改为 5 s 有界等待，超时即 `terminate()` 并输出 `serverVersion=timed out`。协议层失败路径本身有界（审查者实测：不回答的假 server 下 test 1 在 60.4 s 失败并打印 `frames=0 exit=running stderr=<empty>`，test 2 在 60.2 s 以 `requestTimedOut` 失败，均非静默通过）。

审查者独立复现/确认的关键结论（19 项，摘要）：生产文件差异确为纯注释；`swift test` 642 项 / 10 跳过 / 0 失败（审查时修订；补入扫描器对照测试后最终修订为 643 项 / 10 跳过 / 0 失败）；两项 live 测试在真实 `codex-cli 0.162.1` 上通过；失败路径有界且带诊断；扫描器 fuzz 0 mismatch；最短往返测试的生成器确为最短往返文本且覆盖 `[2^50,2^54)`；legacy 模型在改前树 380,000 个样本上 0 mismatch；固定的期望值与当前实现逐条一致；新增 5 条真实帧除 `codexHome`、3 个 credit `id`、error message 外与捕获逐字段一致且无账号/会话/安装/主机/邮箱/路径材料，并在改前树通过；7510 帧差分 516 条且黄金帧/真实帧 0；binade 扫描 <2^54 为 0、`[2^54,2^55)` 24.7%、`[2^62,2^63)` 99.2%；独立审计的 720,000 条文本与 33571/写者等数字；`Decimal(Double.infinity)` SIGTRAP；真实帧 33 个数字、0 浮点语法、最大 1.79e12；原型 A/B 的 536/186；debug 基准方向与幅度；release 构建、`git diff --check`、Widget target 不含该文件。

审查者**无法验证**的项（已如实记录，不作为验收依据）：5 条帧的原始捕获出处（只能与 /tmp 的另一份捕获交叉印证）、本文件的第 1/2/3a 轮审查历史、「为什么没有既快又逐位相同」一节的 -O 候选表（见该节新增的说明）、第二轮夹具的原始产物。

## 收敛结论

实现提交时的收敛结论（第 2 轮）为：无阻塞问题，十进制精度问题已修复，剩余偏差族记录在案。本轮验收在此基础上更正了三点：

1. 残留偏差族比原文档描述的更大：**正常最短往返 f64 文本**同样会触发（族 1），实测量级边界为 2^54（`[2^50,2^54)` 80000 样本 0 差异）；原“最短表示扫描 0 不一致”的判据只比较 double 取整值，不构成兼容性证据。
2. 该族无法通过“读取书写数字”归零：原型 A 使差异变多（516→536，接受性翻转差分行数 2→9），原型 B 只能降到 186 且引入 `Decimal(Double.infinity)` 崩溃风险。保持“浮点存储 = double 像”这一条可解释规则是更稳妥的选择。
3. 真实 `codex app-server` 联调已完成：真实帧可解码、数字逐值一致、真实拒绝帧形状符合预期、生产刷新路径可用；真实负载中浮点语法数字为 0，最大数字约 `1.79e12`（2^41），远低于族的 2^54 边界。

因此：现有性能收益（`full` 下降约 59%/77%）可以安全保留；已知语义差异有充分证据证明对配额判定不可达，并由测试与文档固定。

## 剩余风险与未验证项

- **族 1（可达但本协议不可达）**：浮点语法、量级 ≥2^54 且十进制整数与 double 精确整数不同的文本（正常 f64 writer 会产生）在 `.integer` 精确值上与旧解码不同。配额路径消费的字段都远低于该量级，真实 `app-server` 也未出现浮点语法数字，因此无端到端影响；若要彻底消除，需要放弃 `JSONSerialization`（放弃本轮收益）或改变值表示以保留原始文本，代价与风险见「修复评估」。
- **族 2–4（正常 writer 不产生）**：分数文本截断、人为超精度文本、`Int64.min` double 像内的负值浮点文本。均已用测试固定，其中族 4 会把 `id`/`code` 由接受变为拒绝（需要负值恰好落在 `-9223372036854776832…-9223372036854775809` 且写成浮点语法）。
- **未消除的往返转换（后续已处理）**：值树构造（占优化后 `full` 约 50%）与 `foundationObject()`（约 7%）仍在；消除它们需要改变 `CodexAppServerJSONValue` 的表示，未在本轮范围。生产路径现在改为直接消费原始 Foundation 载荷，见 `optimization-2026-10-13-rpc-inbound-frame.md`（类型化消息与其往返仍保留给契约测试）。
- **`convert`/`parse` 阶段的小幅开销**：新值树的数字来自 `JSONSerialization`（含 `NSDecimalNumber`），下游类型判定略慢（实测 0%–10%，本轮 `convert` 为噪声级）；`full` 整体仍下降约 59%/77%。
- **真实联调覆盖有限**：只覆盖一个账号状态与 `codex-cli 0.162.1`；不覆盖超时、进程死亡、认证失败、服务端主动请求等失败路径；需要本机 `codex` 与登录态，默认跳过（报告为 skipped 而非 passed）。
- **计时数据来自本机 debug 构建**；仓库现有测试依赖 DEBUG 默认参数，release 配置下测试不可编译，因此没有 release 计时结论。
- 删除 `Decodable` 后这些类型不再能被 `JSONDecoder` 解码（当前无调用方）；若将来需要该能力需重新实现 `init(from:)`。
- 本轮未执行 `./script/build_and_run.sh --verify`（会替换已安装 bundle，属外部状态变更），也未进行人工 UI 检查。
