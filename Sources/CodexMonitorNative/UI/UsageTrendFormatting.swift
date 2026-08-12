import Foundation

enum UsageTrendFormatting {
    struct Display: Equatable {
        let speedText: String
        let exhaustionText: String
        let resetRemainingText: String
        let detailText: String
    }

    static func display(
        for analysis: UsageTrendAnalysis,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> Display {
        let resetRemainingText = StatusPopoverFormatting.relativeRecoveryLine(
            for: analysis.resetAt,
            now: now
        )
        switch analysis.state {
        case .unavailable:
            return Display(
                speedText: "--",
                exhaustionText: "暂无可信周额度",
                resetRemainingText: resetRemainingText,
                detailText: "等待真实额度样本"
            )

        case .insufficientData:
            let detailText: String
            switch analysis.latestNotice {
            case .quotaReset:
                detailText = "检测到额度重置，正在重新收集"
            case .anomalousJump:
                detailText = "已隔离异常跳变，正在重新收集"
            case nil:
                detailText = "至少需要 3 次连续样本（跨度 10 分钟）"
            }
            return Display(
                speedText: "收集中",
                exhaustionText: "数据不足，暂不预测",
                resetRemainingText: resetRemainingText,
                detailText: detailText
            )

        case .stable:
            return Display(
                speedText: "0%/小时",
                exhaustionText: "当前速度下不会耗尽",
                resetRemainingText: resetRemainingText,
                detailText: "近期周额度保持稳定"
            )

        case .consuming:
            let rate = analysis.ratePercentPerHour ?? 0
            let exhaustionText: String
            if analysis.willExhaustBeforeReset == false {
                exhaustionText = "预计重置前不会耗尽"
            } else if let exhaustionAt = analysis.exhaustionAt {
                exhaustionText = exhaustionAt <= now
                    ? "按当前速度可能已耗尽"
                    : StatusPopoverFormatting.shortTimestamp(
                        for: exhaustionAt,
                        now: now,
                        calendar: calendar,
                        locale: locale,
                        timeZone: timeZone
                    )
            } else {
                exhaustionText = "暂不预测"
            }
            return Display(
                speedText: String(format: "%.1f%%/小时", rate),
                exhaustionText: exhaustionText,
                resetRemainingText: resetRemainingText,
                detailText: "基于最近 \(analysis.samples.count) 次连续样本"
            )
        }
    }
}
