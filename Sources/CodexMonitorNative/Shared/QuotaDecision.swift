import Foundation

enum QuotaDecisionLevel: String {
    case safe = "安全"
    case observe = "观察"
    case conserve = "节制"
    case stop = "停手"
}

struct QuotaDecision: Equatable {
    let level: QuotaDecisionLevel
    let recommendation: String
}

enum QuotaDecisionEngine {
    static func evaluate(snapshot: QuotaSnapshot, hasUsableRealData: Bool) -> QuotaDecision {
        guard hasUsableRealData else {
            return QuotaDecision(
                level: .observe,
                recommendation: "先完成同步，再决定任务强度"
            )
        }

        let fiveHour = snapshot.fiveHourQuotaPercent
        let weekly = snapshot.weeklyQuotaPercent

        if fiveHour <= 10 || weekly <= 5 {
            return QuotaDecision(
                level: .stop,
                recommendation: "暂停大任务，等待恢复"
            )
        }

        if fiveHour <= 25 || weekly <= 15 {
            return QuotaDecision(
                level: .conserve,
                recommendation: "建议只做轻量修复"
            )
        }

        if fiveHour <= 45 || weekly <= 30 {
            return QuotaDecision(
                level: .observe,
                recommendation: "留意消耗，优先短任务"
            )
        }

        return QuotaDecision(
            level: .safe,
            recommendation: "可以继续跑日常 medium"
        )
    }

    static func effectiveFiveHourResetAt(for snapshot: QuotaSnapshot, hasUsableRealData: Bool) -> Date? {
        guard hasUsableRealData else {
            return nil
        }

        return snapshot.fiveHourResetAt ?? snapshot.refreshedAt.addingTimeInterval(5 * 60 * 60)
    }
}
