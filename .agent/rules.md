# Agent Rules（项目级边界）

本文件定义智能体在本项目中工作的强制边界。适用于所有维护与开发任务。权威项目规范为根目录 `AGENTS.md`；本文件是其可执行摘要与约束，冲突时以 `AGENTS.md` 为准。

---

## 必须（Must）

- **基于证据工作**：所有修改必须来自可复现 Bug、测试失败、明确行为异常、用户反馈、稳定性/性能风险或测试缺口。无证据不修改。
- **最小修改**：每次只解决一个最高价值问题，diff 小范围，不扩大改动面。
- **尊重现有架构**：遵循 `Sources/CodexMonitorNative/{App,Core,Shared,System,UI}` 目录分层与既有类型设计；不引入新分层、不改变模块边界。
- **保留用户修改**：不覆盖、不丢弃工作区中未提交的用户改动；先 `git status`/`git diff` 确认现状。
- **明确验证结果**：修改后必须运行相应验证（测试/构建/验收），并如实报告结果；无法运行的验证项要说明原因。
- **保持兼容**：产品不变量（见 `AGENTS.md` "Product Invariants"）任何情况下不得破坏；持久化 payload、Widget 双编译上下文保持兼容。
- **维护记录**：每次 Loop 在 `.agent/history.md` 记录问题、证据、修改、验证、剩余风险。

---

## 禁止（Forbidden）

- **禁止 commit / push / 创建 PR / 发布 / 部署**：除非用户在当前任务中明确要求。
- **禁止修改凭证或敏感数据**：不读取、不写入 token、auth 文件内容、原始账号/会话标识、密钥、证书私钥；不修改权限与签名身份配置。
- **禁止删除用户数据**：不删除持久化状态、UserDefaults、App Group 文件、用户工作区内容。
- **禁止伪造测试结果**：不隐藏失败、不修改测试绕过问题、不宣称未运行的验证已通过。
- **禁止无证据修改**：不做纯风格调整、猜测式修复、无验证方式的问题。
- **禁止破坏不变量**：不把 mock/演示数据当真实数据展示；失败刷新不清空上次成功快照；菜单栏不用 5 小时/月/未知窗口替代周额度；账号边界失败必须 fail-closed。
- **禁止提交生成产物与敏感文件**：`dist/`、`.build/`、`build/`、签名产物、auth 内容不入库。

---

## 项目专属约束

- **Widget 双编译上下文**：被 Widget 复用的文件（`AGENTS.md` widget 文件表）必须在 SwiftPM 与 Xcode widget target 两种编译上下文下都可用；文件清单以 `project.pbxproj` 的 Sources build phase 为准。
- **账号边界 fail-closed**：真实快照仅在已验证的账号/会话边界与当前身份匹配时展示；身份缺失、变更或不可验证时清空并显示 `--%`；持久化不可用时同样必须发布失效。
- **单一展示投影**：菜单栏、Popover、Widget 的额度窗口/恢复时间/可信度必须走共享展示路径，语义对齐；改动需同时覆盖三处测试。
- **时间语义**：墙钟语义唯一来源是 `QuotaTemporalSemantics`；测试使用注入时钟，不依赖真实 run loop。
- **验证门槛**：交付前 `swift test` + `swift build -c debug`；打包/签名/安装/Widget 集成改动跑 `./script/build_and_run.sh --verify`；UI 可见行为对照 `QA_CHECKLIST.md`。

---

## 环境覆盖（本项目可用）

- `CODEX_MONITOR_FORCE_MOCK=1` — 确定性 mock 数据
- `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` — 强制刷新成功路径
- `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` — 强制刷新失败路径
- `CODEX_BIN` / `CODEX_EXECUTABLE` — codex 可执行文件覆盖

仅用于 QA/验证，不用于绕过真实行为断言。
