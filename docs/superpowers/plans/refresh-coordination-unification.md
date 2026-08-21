# 刷新协调统一化（Refresh Coordination Unification）

状态账本（跨轮次更新；完成一项就把 Open 移到 Verified）。

## Goal（done 的含义）
统一后台刷新协调：消除无关状态发布对调度锚点的重置（D1）、数据新鲜时环境恢复触发的无效请求（D2）；
保持失败退避、账号边界校验、真实数据优先、Widget/菜单栏行为与持久化格式不变；
增加刷新原因与生命周期可观测性（D4）；确定性测试覆盖 D1/D2/D4；全量测试通过（单实例测试的预存在时序波动如实记录）。

## Verified（已定案，有验证覆盖）
- [x] D1 已实施：updateSchedule 幂等重调度（输入未变且已有未来 deadline 时跳过）。测试 testUnchangedSchedulingUpdateDoesNotPostponePendingDeadline / testChangedSchedulingInputsRecomputePendingDeadline 锁定。
- [x] D2 已实施：wake/networkRestored/networkChanged 在 failureCount==0 && 真实快照 fresh && now<lastSuccess+stableInterval 时折叠进现有 cadence，deadline 收紧到 ≤ stableAnchor。7 个门控测试锁定（含失败退避旁路、manual/accountBoundary 不门控、mock/无数据不门控、老化新鲜数据立即刷新）。
- [x] D4 已实施：RefreshScheduler.lastFiredTrigger/lastFiredAt/freshnessGatedTriggerCount/hasDeferredAutomaticTrigger/activePauseReasons；AppState.activeRefreshTrigger(computed)/lastRefreshTrigger；门控日志带触发名与数据年龄。2 个诊断测试锁定。
- [x] RefreshSchedulerTests 25/0；AppState+关联套件 158/0。
- [x] 触发关系审查完成：生产环境所有刷新入口都经 RefreshScheduler.requestRefresh（manual/networkRestored/networkChanged/systemClockChange 直接调用；temporalBoundary/accountBoundaryChanged 经 AppState.refresh→onRefreshRequested 回环；scheduler 定时器自身 .scheduled/.temporalBoundary）。AppState.enqueueRefresh 的 active/pending 与 scheduler 的 refreshInFlight 双层保证同一时间只有一个物理请求（已有测试锁定 maximumConcurrentCalls==1）。
- [x] `.wake` 触发在生产代码中无发射点（唤醒恢复经 network observer 重启后的 .networkRestored 完成），仅测试用作旁路退避的代表触发——保留不改（删除属无关重构）。
- [x] 基线：566 测试，SingleInstanceCoordinatorTests 存在预存在时序波动（3/8/9/16 失败不等，fixture 为 UUID 隔离临时目录，deadline 型断言受 CPU 负载影响）；刷新相关套件全绿。工作树 clean @ 04ef8b9。

## Core 设计（最小修改）
- **D1 调度锚点幂等**：`RefreshScheduler.updateSchedule` 在「非刷新中 && 输入未变 && 已有未来 deadline」时跳过重调度，任何 commitState（时钟/时区/日历 reconcile、网络不可用等）不再把下一次自动刷新推迟一个完整间隔。输入比较用 RefreshSchedulingState 的 Equatable。
- **D2 新鲜度门控**：`.wake/.networkRestored/.networkChanged` 在 failureCount==0 且真实快照 fresh（QuotaTemporalSemantics.freshness，staleAfterInterval 由 AppState 传入 RefreshSchedulingState）且 now < lastSuccess+stableInterval 时折叠进现有调度，并把 deadline 收紧到 ≤ lastSuccess+stableInterval（不产生 stale 窗口）；否则维持现行立即刷新。manual/accountBoundaryChanged 永不门控；退避窗口内行为不变（门控仅在 failureCount==0 分支）。
- **D4 可观测性**：RefreshScheduler 暴露 lastFiredTrigger/lastFiredAt/freshnessGatedTriggerCount/hasDeferredAutomaticTrigger/activePauseReasons；AppState 暴露 activeRefreshTrigger/lastRefreshTrigger；门控与触发日志带原因。
- **D3（评估后接受现状）**：AppState freshness task 与 scheduler resetBoundary 双跟踪同一时间边界，边界处多一次 reconciliation 发布+合并计数，但物理请求始终唯一且发布携带 savedAt 重锚定语义——重构所有权风险大于收益，记录不改动。

## Open（待验证问题 → settled-by）
- 全量测试在安静机器上的稳定性？→ 已关闭：改后 ×2（13/7 失败）与基线 ×3（3/8/9）同族同特征，全部位于预存在 SingleInstanceCoordinatorTests 时序敏感族；刷新相关套件每次全绿。
- ~~D1 是否破坏 trailing/coalesced 完成路径的重调度？~~ → 已关闭：RefreshSchedulerTests 全量 + 关联套件 158/0 通过
- ~~D2 门控是否引入 stale 展示窗口？~~ → 已关闭：cap 收紧由 testFreshnessGateTightensDeadlineToStableAnchorForAgedFreshData 验证
- D1 是否破坏 trailing/coalesced 完成路径的重调度？→ 现有 RefreshSchedulerTests 全量 + 新增幂等测试
- D2 门控是否引入 stale 展示窗口？→ cap 收紧逻辑的单测（resetBoundary 远于 stable 锚点时被收紧）
- 全量测试在安静机器上的稳定性？→ 改动后连续 2 次安静全量运行对比基线失败集

## Next
（本轮已完成：全量 ×2 失败集均为预存在 SingleInstanceCoordinatorTests 波动族；build exit 0；Loop 10 已记录 history/memory/AGENTS 同步。剩余后续项见 history Loop 10 剩余风险。）
1. 实施 D1+D2+D4 于 RefreshScheduler.swift / AppState.swift（非 Widget 双编译文件，无需 pbxproj 同步）
2. RefreshSchedulerTests 新增 ~8 个确定性测试（ManualRefreshSchedulerClock）
3. swift test --filter RefreshSchedulerTests → AppState 相关套件 → 全量 ×2（安静）→ swift build -c debug
4. 更新 .agent/history.md Loop 记录 + memory.md（若架构事实变化）

## 约束提醒
- 不改 QuotaSnapshot 解码、Widget payload、菜单栏展示、持久化格式；不动 .wake 枚举；不 commit。
- 单实例测试波动为预存在问题：以「失败集 ⊆ 基线波动集 且 刷新套件全绿」为通过标准，并在 history 如实记录。