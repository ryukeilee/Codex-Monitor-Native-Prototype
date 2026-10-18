# 账号边界 1 Hz 轮询的字节级 memo（2026-10-18）

## 目标与结论

`CodexAuthBoundaryObserver` 是本 App 唯一的常驻周期定时器（`pollInterval` 默认 1 s，主 actor，
`AppDelegate.swift:235` 未覆盖）。它每秒调用 `CodexAuthIdentityReader.currentBoundary()`，而该调用
的绝大部分成本是把一份绝大多数时候没变的 `auth.json` 重新做一次 JSON 解析。本轮让轮询在**文件
原始字节未变化**时跳过解析：本机真实 `auth.json`（4099 B）上的单次轮询从 **239.9 µs 降到 44.8 µs
（−81.3%，×5.36）**，可观察行为不变。基准的 `real` 列测的是生产接线本身（默认参数工厂返回的闭包），
不是手搓的 poller，因此这个比值与实际装配路径同源。

## 问题与触发条件

- 触发：App 常驻运行期间每秒一次的主线程轮询，与账号是否变化无关；只有登录、令牌轮换会真正改变
  `auth.json`，因此绝大多数轮询解析的是同一份字节。
- 计时构成（本机 debug 构建，真实 `~/.codex/auth.json` 4099 B）：`currentBoundary()` 240.9 µs，其中
  `parse(data:)` 194.2 µs（80.6%）、`readData(contentsOf:)` 10.9 µs、`isReadableFile` 7.1 µs、
  `defaultCodexHomeURL` 22.4 µs。其余观察者（时钟、网络、睡眠）都是通知驱动，没有周期轮询。
- 唯一可去掉的是重复解析；文件读取与 `CODEX_HOME` 解析必须每次照做（见等价性）。

## 等价性论证

`CodexAuthIdentityReader.parse(data:)` 是 `data` 的纯函数（只读取入参 `data` 与文件内的静态常量，
不访问环境变量、文件系统、时钟或全局状态），所以：字节相同 ⇒ 解析结果必然相同 ⇒ 跳过解析不可能
改变任何可观察结果；字节不同 ⇒ 照常重新解析并重新判定；文件不可读 ⇒ 仍然返回 `nil`，不退回缓存值。

被保留的行为：每次轮询仍重新解析 `CODEX_HOME`（每次调用都重新读 `ProcessInfo.processInfo.environment`）
并真实读取 `auth.json`；`pollInterval` 默认值、`start`/`stop`、generation 守卫、`lastBoundary` 语义与
`onChange` 触发时机全部未改；注入式测试一行未改。

## 改动清单

- `Core/RealQuotaProvider.swift`：纯抽取。新增 `authData(codexHome:fileManager:)`（展开 `~` → 拼
  `auth.json` → `isReadableFile` + `Data(contentsOf:)`）与 `currentAuthData(environment:fileManager:)`
  （解析 `CODEX_HOME` 后取字节）；`boundary(codexHome:)` 与 `currentBoundary()` 改为「取字节 + 解析字节」。
- `System/CodexAuthBoundaryObserver.swift`：新增 `CodexAuthBoundaryPoller`（约 25 行），以原始字节为键
  memo 已解析的边界，无全局状态、无锁、不跨 observer 共享。`boundaryProvider` 的默认值改为工厂
  `CodexAuthBoundaryObserver.makeDefaultAuthBoundaryProvider()`，它在每次 `init` 求值时只创建一个 poller，
  返回的闭包持有它。
- 测试：`CodexAuthIdentityReaderTests` 覆盖 `authData` 的读字节/缺失返回 `nil`，以及
  `boundary(codexHome:) == parse(data: authData(...))` 的抽取等价性；`CodexAuthBoundaryPollerTests`
  覆盖跳过解析、字节变化重解析、不可读返回 `nil` 且不退回缓存、恒不可读时从不解析、
  「先不可读→出现可读字节」（登录这一真实转换）、畸形字节重复命中、每次调用都真实读取；
  `OptimizationBenchmarkTests` 新增 opt-in `testAuthBoundaryPollBaseline`，其 `real` 列的被测对象是
  `CodexAuthBoundaryObserver.makeDefaultAuthBoundaryProvider()` 的返回值，即 `AppDelegate` 实际走的那条路径。

## 验证

- `swift build -c debug`：Build complete。
- `swift test --filter CodexAuthBoundary`：14 passed（`CodexAuthBoundaryObserverTests` 7 +
  `CodexAuthBoundaryPollerTests` 7），既有 observer 测试未改一行。
- `swift test --filter CodexAuthIdentityReaderTests`：7 passed。
- 完整 `swift test`：`Executed 675 tests, with 12 tests skipped and 0 failures` —— **675 项执行 /
  12 项跳过 / 663 项通过 / 0 失败**（12 skipped 全部是既有 opt-in：10 个基准 + 2 个 live app-server）。
- 新增的三个 poller 用例（`CodexAuthBoundaryPollerTests`）均通过：
  `testUnreadableFileThatBecomesReadableIsParsedOnceAndThenMemoized`（首调用 `nil` 且 `parse`=0；
  字节出现后返回 `isValid` 边界且 `parse`=1；再调用仍是 `parse`=1）、
  `testMalformedBytesAreParsedOnceAndKeepReturningNil`（三次 `nil`，`parse`=1）、
  `testEveryCallReadsTheFileEvenWhenTheBytesAreUnchanged`（四次调用 `readCount`=4、`parse`=1）。
- `CODEX_MONITOR_BENCHMARK=1 swift test --filter OptimizationBenchmarkTests/testAuthBoundaryPollBaseline`，
  5 轮最优值（per call）：

| 口径 | 改动前 | 改动后 | 比值 |
|---|---|---|---|
| 合成 4304 B payload：每次解析 / 命中跳过 | 103.4 µs | 0.18 µs | ×590 |
| 生产轮询（真实 4099 B，读文件+解析 / 读文件+比较） | 239.9 µs | 44.8 µs | ×5.36 |

- 同一基准的 `real` 跳过分支实测：把 `CODEX_HOME` 指向一个可读但身份不可验证的合成 `auth.json`
  （70 B，`auth_mode` 非 chatgpt）时打印
  `BENCH auth-boundary[real] skipped: readable auth.json (bytes=70) but the identity is not verifiable in this CODEX_HOME`
  并且测试通过（0 failures），诊断行不含任何账号/令牌内容。
- `git diff --check`：无输出。

## 被否决的候选

- **mtime/size 提前返回**：内容变了而 mtime+size 恰好不变时会漏报账号切换，把 fail-closed 变成
  fail-open，违反 Product Invariant，禁止。
- **全局 / 跨 observer memo**：被否决的理由不是「必然污染」，而是代价与收益不匹配 —— 跨 observer
  共享需要在主 actor 之外加锁或引入共享可变状态，把 fail-closed 路径上的共享可变状态从 0 增加到 1；
  收益与单 poller memo 完全相同（都只跳过重复解析）。仅当共享 memo 每次都真实读文件、且按**完整字节**
  匹配时它才不引入新的错误可见性，但那只是把一个私有缓存变成一个有并发代价的全局缓存，不值得。
- **缓存 `CODEX_HOME` 路径或复用 `Data` 实例**：会让 `CODEX_HOME` 变化与文件内容变化漏检。
- **`fingerprint` 的 `String(format:"%02x")` 改表驱动**：改后该路径几乎不再执行（只在字节变化时），
  收益不足。

## 剩余风险

- 命中判定是整份文件字节比较（4099 B memcmp ≈ 亚微秒），文件越大成本线性增长；当前实际大小下
  <1% 的轮询成本。
- memo 会在内存里保留最后一份 `auth.json` 字节（不落盘、不写日志、不进入任何模型或 UI 路径）；
  改动前每次轮询也会把同一份字节读进内存，区别只是存活期从一次轮询延长到进程寿命。
- 默认参数工厂的正确性只由“每次 `init` 求值一次”这一语言规则保证：若有人把默认值改写成内联的
  `CodexAuthBoundaryPoller().currentBoundary()`，memo 会静默失效（行为仍正确，只是退回旧成本）。
  基准的 `real` 列测的就是工厂产物，所以在那种情况下它的加速比会退回 ~1×。
- 基准的 `real` 列依赖本机 `auth.json` 可读且身份可验证；不可读、或身份不可验证（未登录、
  `auth_mode` 非 chatgpt、文件损坏）都只打印跳过行，不失败。
