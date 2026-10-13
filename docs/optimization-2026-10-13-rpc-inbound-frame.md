# RPC 入站帧表示优化（2026-10-13）

本轮在上一轮「单次 JSON 解析」的基础上，消除 `CodexAppServerCodec.decodeLine` 到
`RealQuotaProvider.handleRateLimitsResponse` 之间的值树构造与 `foundationObject()` 往返转换。
生产客户端改用新的入站帧表示直接消费 `JSONSerialization` 已产出的 Foundation 对象；类型化
`CodexAppServerMessage` 仍然保留为线上契约（黄金帧 / 数值类型语义测试继续走它），由同一份解析
结果按需构造。本文件包含两轮独立审查后的修正。

## 目标与改动

上一轮文档（`optimization-2026-10-11-rpc-parse.md`）把「值树构造 + `foundationObject()` 往返」
列为未完成项。本轮改动：

1. `CodexAppServerProtocol.swift` 新增 `enum CodexAppServerInboundFrame`：`response` 携带原始
   Foundation 载荷，`error` 携带类型化的 `CodexAppServerRemoteError`（错误 `data` 不在配额路径
   上），`request` / `notification` 仍携带类型化 `params`——在信封判定时按旧顺序（method →
   params → id）一次性构建，`message()` 直接复用，不重复遍历。
2. `decodeLine` 与新的 `decodeInboundFrame` 共享一次 `JSONSerialization` 解析：
   - `decodeInboundFrame`（生产路径）对响应载荷用 `finiteValue(from:)` 直接遍历 ObjC 容器校验，
     不构造值树、不复制容器，并保留非有限数（`-1e400`）的 `invalidMessage` 分类；
   - `decodeLine`（线上契约 / 测试路径）跳过响应载荷扫描，由 `message()` 在构建值树时校验与转换；
     request / notification 的 `params` 只构建一次，因此类型化路径与改动前成本一致。
3. `RealQuotaProvider.swift`：
   - `handleLine` 改用 `decodeInboundFrame`，三个处理器直接读取原始 `[String: Any]`；
   - 原始载荷保留 `JSONSerialization` 的存储与容器类型，因此新增
     `CodexAppServerCodec.foundationNumber(from:)`（镜像 typed 值树的数字契约，含精确十进制文本）
     用于 `parsePercentage` / `parseInteger` / `parseDate`；`mergeAliasedValues` 改用
     `CodexAppServerCodec.rawValuesAreEqual`，避免 `NSObject.isEqual` 把整数存储与浮点存储的同一
     量级（如 `9007199254740993` 与 `9007199254740993.0`）误判为相等，而 typed 树把后者读成
     `9007199254740992` 并判为冲突。
4. 测试：
   - `CodexAppServerProtocolTests` 新增 `testInboundFrameRejectsNonFiniteWireNumbers`，证明生产
     入口自身仍拒绝非有限数；
   - `RealQuotaProviderTests` 新增生产路径的十进制百分比用例、嵌套非有限数拒绝用例，以及
     `testRawInboundPayloadParsesLikeTheConvertedValueTree`：对旧载荷（`foundationObject()` 结果）
     与新原始载荷逐字段比较 `QuotaSnapshot` 决策，含 17 个字面量的数值网格、十进制别名冲突与
     整数/浮点别名冲突；
   - `OptimizationBenchmarkTests.testRPCLineDecodeBaseline` 新增 `inbound` 与 `productionFull`
     两个阶段。

## A/B 基准

命令（debug，与上一轮同一脚本）：

```bash
CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests/testRPCLineDecodeBaseline
```

基线为改动前的 `main`（工作区干净时的同一台机器），每轮 200 次 × 5 轮，取中位数，单位秒：

| 阶段 | realistic 基线 | realistic 现在 | scaled 基线 | scaled 现在 |
|---|---|---|---|---|
| `full`（decodeLine → foundationObject → parse） | 0.00814 | 0.00818（+0.4%） | 0.02922 | 0.02893（-1.0%） |
| `decode`（decodeLine） | 0.00287 | 0.00285（-0.7%） | 0.01776 | 0.01749（-1.5%） |
| `inbound`（decodeInboundFrame） | — | 0.00145 | — | 0.01178 |
| ** `productionFull`（decodeInboundFrame → parse）** | — | **0.00760（-6.7%）** | — | **0.02398（-17.9%）** |

- 生产路径 `productionFull` 相对基线 `full`：realistic 约快 7%，scaled 约快 15%–18%（多次运行区间），
  5 轮内稳定。
- 类型化 `decodeLine` / `full` 与基线一致（差异在噪声内，`decode` 甚至略快），说明上一轮优化未
  回退；request / notification 的 `params` 保持单次构建，未引入二次遍历。
- 收益有限的原因已用独立 `-O` 微基准定位：`JSONSerialization` 在顶层之下返回 Objective-C 容器
  （`__NSDictionaryI` / `__NSArrayI`），Parser 每读一个容器都要桥接一次；旧路径的
  `value(from:)` + `foundationObject()` 做三次拷贝，新路径只做一次（校验扫描直接迭代 ObjC 容器，
  不拷贝）。桥接成本是共享的，因此总收益为个位数到十几个百分点。

## 行为等价性

- `decodeLine` 输出未变：`CodexAppServerProtocolCorpusTests`（111 条黄金帧 + 5 条真实脱敏帧）与
  `CodexAppServerProtocolTests` 的数值类型、十进制精度、非有限数、`Int64.min`、最短往返边界用例
  全部原样通过。
- `decodeInboundFrame` 的错误分类：新增用例覆盖 `result` / 嵌套对象 / 数组 / `params` /
  notification `params` / `error.data` 中的 `-1e400`，以及 `id`、`1e400` 两个边界。
- 配额决策等价：`testRawInboundPayloadParsesLikeTheConvertedValueTree` 对原始载荷与
  `foundationObject()` 载荷比较 `weekly`/`fiveHour` 百分比与状态、`resetAvailableCount`、
  `fiveHourResetAt`、`quotaWindows`、`resetBanks`，含 `9007199254740993(.0)`、
  `1.152921504606847e+18`、`1.49999999999999985`、`-0.0`、`1e-320` 等字面量网格，以及十进制与
  整数/浮点两种别名冲突用例。
- 生产 RPC 路径：`testRPCClientKeepsDecimalStoredPercentageAtItsWrittenDecision` 固定
  `1.49999999999999985 → 1%`；`testRPCClientRejectsNestedNonFinitePayload` 固定配额字段之外的
  `-1e400` 仍归类为 `responseInvalid`。

## 独立审查与修正

跨 provider 独立审查（codex / gpt-6.1-sol）对照 HEAD 与工作树复现，提出 2 项 BLOCKER，均已修复：

1. **数值别名冲突判定失真**：raw 整数值与浮点值经 `NSObject.isEqual` 会判等，而 typed 树把它们
   读成不同整数。已改为按数字契约递归比较（`rawValuesAreEqual`），并补充两个方向的反例用例。
2. **`decodeLine` 的 request / notification 成本回退约 50%**：`params` 被校验后再转换，遍历两次。
   已改为在信封阶段一次性构建类型化 `params` 并由 `message()` 复用，恢复改动前的单次遍历。
3. **（第二轮 NIT）递归比较的嵌套布尔语义**：`rawValuesAreEqual` 最初在数组/字典内部也强制布尔与
   数字不等，与旧 `NSArray.isEqual` 的值相等不同。已移除该内层检查（顶层布尔/数字不匹配仍由
   `mergeAliasedValues` 保障），并新增 `testRawValuesAreEqualFollowsTheDecodedNumberContract`。

第二轮复核确认：两个 BLOCKER 均已解决（撤回比较修复后两个反例重新出现，修复后两侧均为 `nil`；
request/notification 相对 HEAD 的 `-O` 中位耗时比 1.001× / 1.000×），无新增 BLOCKER；数值读取覆盖
signed/unsigned、plain double、`NSDecimalNumber`、超出 `Int64`、`Int64.min` double image 均与旧
converted 路径一致。

## 验证

- `swift test`：647 项，10 项跳过（8 项 opt-in 基准 + 2 项 opt-in 真实联调），0 失败。
- `swift build -c debug`、`swift build -c release` 通过；`git diff --check` 通过。
- `CodexAppServerProtocol.swift` / `RealQuotaProvider.swift` 均不在 Widget Xcode target 的 Sources
  build phase 中（`project.pbxproj` 无引用），未改动 Widget 共享编译单元或持久化载荷。
- 未执行 `./script/build_and_run.sh --verify`（会替换已安装 bundle，属外部状态变更）与人工 UI 检查：
  本轮不涉及签名、entitlements、安装路径、菜单栏标题、Popover 或 Widget 呈现。

## 剩余风险

- 收益为 debug 基准下的 7%–18%；release 配置下测试不可编译（仓库既有约束），无法给出 release
  计时结论。独立 `-O` 微基准显示值树枚举本身的成本远小于 ObjC→Swift 容器桥接，因此 release 的
  相对收益可能更小。
- `decodeInboundFrame` 仍保留响应载荷的有限数扫描；真实 app-server 不产生浮点语法数字，该扫描在
  实际刷新中是纯开销，但它维持了既有的 `invalidMessage` 拒绝契约。
- 原始载荷读取与别名比较现在都通过 `CodexAppServerCodec` 的数字契约函数完成；若将来数字契约变化，
  这些调用点会随之变化（这是期望行为，但需要在同一处修改）。
