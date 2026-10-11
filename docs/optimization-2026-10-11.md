# Widget 状态持久化读写路径优化验证（2026-10-11）

以本地代码为准，本轮只优化 `Sources/CodexMonitorNative/Shared/WidgetDisplayState.swift` 中 `WidgetDisplayStateStore` 的持久化读写路径与 `PersistenceEnvelope` 的构造方式，未改动持久化格式、账户边界、revision 规则或锁语义，也未重复优化 `SnapshotStore`。

## 目标与修改内容

同一份持久化字节此前会被反复解析：

- 旧 `load` 对同一份 primary 依次执行 `containsNewerPersistenceVersion`、`decodeEnvelope`、`decodeLegacyState`；`saveUnlocked` 再依次执行 `containsNewerPersistenceVersion`、`decodeEnvelope`/`decodeLegacyState`、`envelopeRevision`、备份可信判定，并在写入后重新完整解码回读字节。
- 旧写入路径把同一个 `WidgetDisplayState` 编码两次：一次作为 envelope payload，一次用于兼容旧版 Widget 的顶层扁平字段。

本轮修改：

1. 新增单次分类 `audit(_:) -> WidgetStateAudit`，一次解析给出：当前格式且 checksum 有效、payload 可解码、schema 受支持的 envelope（含 revision）；仅当字节完全不含 envelope 元数据时才解码的 legacy 状态；是否由更新的持久化格式或更新的 snapshot schema 写入；以及该字节是否可信。`load` 与 `saveUnlocked` 各对 primary、backup 调用一次，并复用结果完成版本判定、可信判定、revision、账户边界与备份判定。
2. 新增 `PersistenceEnvelope.init(payload:revision:)`；`encodedEnvelopeData(payload:revision:)` 复用同一份 payload 字节生成顶层扁平字段，写入路径只编码一次状态。
3. 备份恢复 `restoreEnvelopeBackup` 不再对刚写入的同一份字节重新解码，保留字节相等回读校验（`state` 就是本次 `audit` 对同一份 `data` 得到的结论）。
4. 写入回读校验由 `envelopeRevision(readback) == revision`（envelope + checksum + payload 解码 + isSupported）改为 `isEnvelope(data, atRevision:)`（envelope 结构 + checksum + formatVersion + revision）。写入的 payload 来自本次已通过 `isSupported` 的具体状态，不需要再次解码。

保留项：旧版扁平 payload 与 envelope 元数据同时写入、legacy 一次性读取并迁移、未来 `formatVersion`/`schemaVersion` 保护（future primary 不被替换或隔离）、checksum 失败不回退到扁平字段、账户边界与时间排序守卫、revision 递增与 `UInt64.max` 拒绝、原子写入、备份写入 + 字节回读、失败回滚、隔离与 sidecar `flock` + `NSLock` 并发语义。

## 可复现 A/B 基准

基准代码：`Tests/CodexMonitorNativeTests/OptimizationBenchmarkTests.swift` 的 `testWidgetDisplayStateStoreBaseline`（opt-in，不引用任何调试计数器，因此同一文件可在修改前后两棵代码树上运行）。它在隔离的 App Group 目录中重复执行「保存 + 读取」100 次 × 5 轮，并分别使用 `scaled`（256 个 quota window、64 条 reset credit、8 个 reset bank）与 `realistic`（4/3/2）两种 payload。

命令：

```bash
CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests/testWidgetDisplayStateStoreBaseline
```

基线获取方式：`git archive HEAD | tar -x -C <临时目录>`，把上述基准测试文件复制进去后在同一台机器运行；工作目录不受影响。

中位数（单位：秒／100 次操作，debug 配置）：

| 场景 | 基线 save | 优化后 save | 基线 load | 优化后 load | 基线 save+load | 优化后 save+load |
|---|---|---|---|---|---|---|
| scaled | 1.029059 | 0.490274（-52.4%） | 0.246366 | 0.126341（-48.7%） | 1.275880 | 0.616558（-51.7%） |
| realistic | 0.171951 | 0.125658（-26.9%） | 0.028644 | 0.016236（-43.3%） | 0.200043 | 0.141894（-29.1%） |

`scaled` 用于放大 JSON 解析占比以便测量；`realistic` 更接近一次刷新实际写入的载荷，此时保存端由文件 I/O 主导，因此端到端收益（-29.1%）明显小于 JSON 工作量本身的下降。该数字只覆盖本机本次运行，不代表整机能耗、Widget 渲染帧率或真实大 payload 存储成本。

## 确定性计数（不依赖计时）

`WidgetDisplayStateStore` 在 DEBUG 下新增 `Instrumentation`（`decodes` / `payloadEncodes` / `checksumValidations`），由 `WidgetTimelineBridgeTests` 的六个测试固定每条路径的精确次数。基线次数由在临时副本中为旧实现插入同等计数器后实测得到，不是估算：

| 路径 | decodes | payloadEncodes | checksumValidations |
|---|---|---|---|
| 已存在有效 primary 的提交 | 10 → 3 | 2 → 1 | 8 → 2 |
| 有效 primary 的读取 | 4 → 2 | 0 → 0 | 3 → 1 |
| checksum 失败 primary 的修复写入 | 6 → 2 | 2 → 1 | 6 → 2 |
| future `formatVersion` primary + 有效 backup 的读取 | 4 → 3 | 0 → 0 | 3 → 2 |
| 无 envelope 的 legacy primary 迁移 | 13 → 5 | 2 → 1 | 2 → 1 |

`checksumValidations` 统计的是校验次数，不含写入时生成 checksum 的那一次 SHA-256；`JSONSerialization` 解析也不计入。

## 边界回归与验证

- 新增计数/边界测试（`WidgetTimelineBridgeTests`）：暖提交与暖读取只分类一次；暖提交把上一份 primary 逐字节写入 backup，checksum 失败的主文件则不得成为 backup；checksum 失败可修复且不回退扁平字段；future primary 仍保留主文件并显示 backup；legacy 迁移只分类一次且迁移结果 revision 为 1；envelope 存在时版本判定不探测扁平字段（与旧行为一致，不与更严格的 `SnapshotStore` 对齐）。
- 交叉验证：修改前代码树（`git archive HEAD` 临时副本）与修改后代码树都运行同一套临时 13 场景行为对照（暖往返、checksum 失败、future `formatVersion`、future `schemaVersion`（envelope 与 raw 两种）、legacy primary 与 legacy backup 迁移、envelope backup 恢复、混合扁平 future schema、账户/时间排序守卫、无 boundary 的 real 拒绝、仅损坏字节的隔离、不可信 `UInt64.max` revision），结果相同且均通过；该对照文件只在临时副本中使用，未提交。
- 同一基线副本运行仓库既有持久化/Widget 测试集（`WidgetTimelineBridgeTests`、`RefreshConsistencyRegressionTests`、`ReliabilityProbeTests`、`StatusSelfCheckSnapshotTests`、`WidgetPresentationTests`、`DeterministicFaultScenarioTests`）：92 项，0 失败。
- `swift test`：627 项，0 失败，7 项 opt-in 基准跳过。
- `swift build -c debug`、`swift build -c release` 通过；Widget 扩展 Xcode Debug 构建通过（`WidgetDisplayState.swift` 同属 Widget 编译单元，Debug 下包含新增的 DEBUG 计数器）。
- `git diff --check` 通过。

## 独立审查

- 第 1 轮（跨 provider，只读静态审查）：未发现 BLOCKER。五项语义等价问题逐条确认：分类分支与旧组合等价（含 checksum 无效不回退、future 格式不解析 payload、payload 解码失败既非 newer 也非 trusted、future schema 判定先于 boundary 支持检查、legacy 分支必须无 envelope 元数据）；两处校验精简没有可达的弱化路径；备份信任条件完全等价；锁/原子性/隔离/排序未变；计数断言不是同义反复。
- 该轮提出的两个 NIT（预先注释中的 checksum 次数偏低、`checksums` 命名未说明只统计校验）已在优化后代码中修正：注释改为实测值，字段更名为 `checksumValidations`，并在文档注释中说明不含生成开销。
- 第 2 轮（另一 provider，从证据可靠性角度独立复核）：未发现 BLOCKER。逐行重算了修改前后的确定性计数表，与本报告一致；确认基准方法可复现且被测的重复 `save` 是真实提交（不是被拒绝后变成空操作）；确认新增测试由真实解析调用点驱动，重引入冗余解析会失败。
- 第 2 轮指出的唯一缺口（新增测试未直接断言备份信任判定）已通过以下断言补齐：暖提交后 backup 逐字节等于上一份 primary；checksum 失败修复后不存在 backup。

## 收敛结论

两轮独立审查均无阻塞问题，指出的 NIT 与覆盖缺口已修复。修改前后行为等价由两棵代码树上的既有测试集、同一套 13 场景对照与确定性计数共同支撑；净收益由同一基准文件在修改前后实测。

## 剩余风险与未验证项

- 本轮未执行会替换已安装 bundle 的 `./script/build_and_run.sh --verify`，也未做人工 UI 检查；改动不涉及 UI、签名、entitlements 或安装路径，行为变化仅限内部读写次数与耗时。
- Widget 扩展的同文件 Debug 构建已通过，但未在 Widget 进程内对 App Group 实际文件做人工观察。
- 计时数据来自单机 debug 构建；未测量 release 下性能（现存测试依赖 DEBUG 默认参数，release 测试不可编译）。
- 未验证真实磁盘 I/O 故障注入（如磁盘满）下的行为；相关分支由现有测试的失败注入覆盖，未新增故障注入。
