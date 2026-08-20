import Foundation

enum UsageTrendNotice: String, Codable, Equatable {
    case quotaReset
    case anomalousJump
}

struct QuotaAnomaly: Equatable {
    let previous: UsageTrendSample
    let current: UsageTrendSample

    var change: Int {
        current.remainingPercent - previous.remainingPercent
    }
}

struct UsageTrendSample: Codable, Equatable, Identifiable {
    let recordedAt: Date
    let remainingPercent: Int
    let resetAt: Date?

    var id: Date { recordedAt }

    init(recordedAt: Date, remainingPercent: Int, resetAt: Date?) {
        self.recordedAt = recordedAt
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetAt = resetAt
    }
}

struct UsageTrendHistory: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumSampleCount = 96
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    let accountBoundary: QuotaAccountBoundary?
    private(set) var samples: [UsageTrendSample]
    private(set) var latestNotice: UsageTrendNotice?
    let schemaVersion: Int

    init(
        accountBoundary: QuotaAccountBoundary?,
        samples: [UsageTrendSample] = [],
        latestNotice: UsageTrendNotice? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.accountBoundary = accountBoundary
        self.samples = samples.sorted { $0.recordedAt < $1.recordedAt }
        self.latestNotice = latestNotice
        self.schemaVersion = schemaVersion
    }

    @discardableResult
    mutating func append(_ sample: UsageTrendSample) -> QuotaAnomaly? {
        guard let previous = samples.last else {
            samples = [sample]
            latestNotice = nil
            return nil
        }

        guard sample.recordedAt > previous.recordedAt else { return nil }

        let elapsed = sample.recordedAt.timeIntervalSince(previous.recordedAt)
        let change = sample.remainingPercent - previous.remainingPercent
        let resetDeadlineAdvanced = resetDeadlineAdvanced(
            from: previous.resetAt,
            to: sample.resetAt
        )
        let crossedKnownReset = previous.resetAt.map {
            previous.recordedAt < $0 && sample.recordedAt >= $0
        } == true

        if change >= 10 || (change > 0 && resetDeadlineAdvanced) || crossedKnownReset {
            samples = [sample]
            latestNotice = .quotaReset
            return nil
        }

        let isUnexpectedIncrease = change > 0
        let isRapidDrop = elapsed < 30 * 60 && change < -20
        let isExtremeDrop = change < -50
        guard !isUnexpectedIncrease, !isRapidDrop, !isExtremeDrop else {
            samples = [sample]
            latestNotice = .anomalousJump
            return QuotaAnomaly(previous: previous, current: sample)
        }

        samples.append(sample)
        latestNotice = nil
        prune(relativeTo: sample.recordedAt)
        return nil
    }

    private mutating func prune(relativeTo newestDate: Date) {
        let cutoff = newestDate.addingTimeInterval(-Self.retentionInterval)
        samples.removeAll { $0.recordedAt < cutoff }
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }

    private func resetDeadlineAdvanced(from previous: Date?, to current: Date?) -> Bool {
        guard let previous, let current else { return false }
        return current.timeIntervalSince(previous) > 60 * 60
    }
}

struct UsageTrendAnalysis: Equatable {
    enum State: Equatable {
        case unavailable
        case insufficientData
        case stable
        case consuming
    }

    static let unavailable = UsageTrendAnalysis(
        state: .unavailable,
        samples: [],
        ratePercentPerHour: nil,
        exhaustionAt: nil,
        resetAt: nil,
        latestNotice: nil
    )

    let state: State
    let samples: [UsageTrendSample]
    let ratePercentPerHour: Double?
    let exhaustionAt: Date?
    let resetAt: Date?
    let latestNotice: UsageTrendNotice?

    var willExhaustBeforeReset: Bool? {
        guard let exhaustionAt else { return nil }
        guard let resetAt else { return true }
        return exhaustionAt < resetAt
    }
}

enum UsageTrendAnalyzer {
    static let minimumSampleCount = 3
    static let minimumObservationInterval: TimeInterval = 10 * 60
    // Robustness tuning — conservative to avoid false exhaustion.
    private static let idleGapThreshold: TimeInterval = 90 * 60
    private static let idleMaxConsumption: Int = 1
    private static let lowVariationThreshold: Int = 2
    private static let lowRateThreshold: Double = 0.7 // %/h below this is considered stable/noise
    private static let maximumCredibleExhaustionHours: Double = 14 * 24

    static func analyze(
        history: UsageTrendHistory,
        currentResetAt: Date?
    ) -> UsageTrendAnalysis {
        let samples = history.samples
        guard let first = samples.first, let last = samples.last else {
            return .unavailable
        }

        let resetAt = currentResetAt ?? last.resetAt
        let span = last.recordedAt.timeIntervalSince(first.recordedAt)
        guard samples.count >= minimumSampleCount,
              span >= minimumObservationInterval else {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        // 1. Effective window after long idle with near-zero consumption.
        let effective = trimmedAfterIdleGap(samples)
        let working: [UsageTrendSample]
        let workingSpan: TimeInterval
        if effective.count >= minimumSampleCount,
           let ef = effective.first, let el = effective.last,
           el.recordedAt.timeIntervalSince(ef.recordedAt) >= minimumObservationInterval {
            working = effective
            workingSpan = el.recordedAt.timeIntervalSince(ef.recordedAt)
        } else {
            working = samples
            workingSpan = span
        }

        guard let wFirst = working.first, let wLast = working.last else {
            return .unavailable
        }

        let consumed = wFirst.remainingPercent - wLast.remainingPercent
        guard consumed > 0 else {
            return UsageTrendAnalysis(
                state: .stable,
                samples: samples,
                ratePercentPerHour: 0,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        // Low variation: require meaningful total drop to predict exhaustion.
        // Evidence不足时宁可不预测
        if consumed < lowVariationThreshold {
            // If span is at least 30 min and drop is only 1%, it's noise
            if workingSpan >= 30 * 60 {
                return UsageTrendAnalysis(
                    state: .insufficientData,
                    samples: samples,
                    ratePercentPerHour: nil,
                    exhaustionAt: nil,
                    resetAt: resetAt,
                    latestNotice: history.latestNotice
                )
            }
            // For shorter spans, 1% drop is also weak — treat as insufficient
            // but keep compatibility for edge where 1% over 10-20 min could be noise
            // Require at least 2% total to be confident.
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        // Base rate from end-to-end (time-weighted, robust to irregular intervals)
        let baseRate = Double(consumed) / (workingSpan / 3600)
        guard baseRate.isFinite, baseRate > 0 else {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        // Very low rate is indistinguishable from stable given sample noise.
        if baseRate < lowRateThreshold {
            // Check if recent segment shows stronger evidence
            let recentRateForLow = recentWindowRate(working)
            if let rr = recentRateForLow.rate, rr >= 1.5, recentRateForLow.consumed >= 2 {
                // Recent stronger signal overrides low average — continue to burst logic
            } else {
                return UsageTrendAnalysis(
                    state: .stable,
                    samples: samples,
                    ratePercentPerHour: 0,
                    exhaustionAt: nil,
                    resetAt: resetAt,
                    latestNotice: history.latestNotice
                )
            }
        }

        // 2. Recent burst handling — avoid long-term average diluting recent spike.
        var finalRate = baseRate
        let recent = recentWindowRate(working)
        if let rRate = recent.rate, let rSpan = recent.span, rSpan >= minimumObservationInterval,
           recent.consumed >= 2, rRate.isFinite, rRate > 0 {
            // Only blend if recent is meaningfully faster than base
            if rRate > baseRate * 1.5 && rRate - baseRate > 1.5 {
                finalRate = 0.75 * rRate + 0.25 * baseRate
            } else if rRate > baseRate * 1.3 && rRate - baseRate > 1.0 {
                finalRate = 0.60 * rRate + 0.40 * baseRate
            }
        }

        guard finalRate.isFinite, finalRate > 0 else {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        // 3. Variance / irregular-interval sanity: suppress if residuals show high noise relative to signal
        if isPredictionUnreliable(samples: working, rate: finalRate) {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        let hoursToExhaustion = Double(wLast.remainingPercent) / finalRate
        guard hoursToExhaustion.isFinite, hoursToExhaustion > 0,
              hoursToExhaustion <= maximumCredibleExhaustionHours else {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        return UsageTrendAnalysis(
            state: .consuming,
            samples: samples,
            ratePercentPerHour: finalRate,
            exhaustionAt: wLast.recordedAt.addingTimeInterval(hoursToExhaustion * 3600),
            resetAt: resetAt,
            latestNotice: history.latestNotice
        )
    }

    // MARK: - Idle trimming

    private static func trimmedAfterIdleGap(_ samples: [UsageTrendSample]) -> [UsageTrendSample] {
        guard samples.count >= 3 else { return samples }
        var lastIdleIndex: Int?
        for i in 1..<samples.count {
            let gap = samples[i].recordedAt.timeIntervalSince(samples[i - 1].recordedAt)
            let consumed = samples[i - 1].remainingPercent - samples[i].remainingPercent
            // Long gap with near-zero consumption signals idle period
            if gap >= idleGapThreshold && consumed <= idleMaxConsumption && consumed >= 0 {
                lastIdleIndex = i
            }
        }
        if let idx = lastIdleIndex, samples.count - idx >= 2 {
            return Array(samples[idx...])
        }
        return samples
    }

    // MARK: - Recent window

    private struct RecentInfo {
        let rate: Double?
        let span: TimeInterval?
        let consumed: Int
    }

    private static func recentWindowRate(_ samples: [UsageTrendSample]) -> RecentInfo {
        guard samples.count >= 2, let last = samples.last else {
            return RecentInfo(rate: nil, span: nil, consumed: 0)
        }
        // Target at least 30 min or at least 3 points, whichever covers more recent history
        let targetSpan: TimeInterval = 30 * 60
        var startIndex = samples.count - 1
        // Walk backwards until we cover targetSpan or have 4 points
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            let span = last.recordedAt.timeIntervalSince(samples[i].recordedAt)
            let count = samples.count - i
            if span >= targetSpan || count >= 4 {
                startIndex = i
                break
            }
            // If we reach the beginning without hitting target, include all
            if i == 0 { startIndex = 0 }
        }
        let window = Array(samples[startIndex...])
        guard window.count >= 2, let first = window.first else {
            return RecentInfo(rate: nil, span: nil, consumed: 0)
        }
        let span = last.recordedAt.timeIntervalSince(first.recordedAt)
        let consumed = first.remainingPercent - last.remainingPercent
        guard span > 0 else { return RecentInfo(rate: nil, span: span, consumed: consumed) }
        let rate = Double(consumed) / (span / 3600)
        return RecentInfo(rate: rate, span: span, consumed: consumed)
    }

    // MARK: - Unreliability check (low evidence / high variance)

    private static func isPredictionUnreliable(samples: [UsageTrendSample], rate: Double) -> Bool {
        guard samples.count >= 3, rate > 0 else { return true }
        // Compute linear fit residuals to detect high noise vs small slope
        // x = hours since first, y = remaining
        guard let first = samples.first else { return false }
        let n = Double(samples.count)
        var sumX = 0.0, sumY = 0.0, sumX2 = 0.0, sumXY = 0.0
        var ys: [Double] = []
        var xs: [Double] = []
        for s in samples {
            let x = s.recordedAt.timeIntervalSince(first.recordedAt) / 3600
            let y = Double(s.remainingPercent)
            xs.append(x); ys.append(y)
            sumX += x; sumY += y; sumX2 += x * x; sumXY += x * y
        }
        let denom = n * sumX2 - sumX * sumX
        // If denom ~0 (all x same, shouldn't happen due to span check), skip
        guard abs(denom) > 1e-9 else { return false }
        let slope = (n * sumXY - sumX * sumY) / denom // negative for consumption
        let intercept = (sumY - slope * sumX) / n
        // R^2 and residual std
        let meanY = sumY / n
        var ssTot = 0.0, ssRes = 0.0
        var maxAbsResidual = 0.0
        for i in 0..<samples.count {
            let pred = slope * xs[i] + intercept
            let res = ys[i] - pred
            ssRes += res * res
            ssTot += (ys[i] - meanY) * (ys[i] - meanY)
            maxAbsResidual = max(maxAbsResidual, abs(res))
        }
        // If total variance is tiny (<1% range), it's low variation — already handled, but high residual relative to slope is unreliable
        let rmse = sqrt(ssRes / n)
        // If RMSE is large (>3%) and rate is modest (<4%/h), evidence is weak
        if rmse > 3.0 && rate < 4.0 {
            // Also require R^2 low
            let r2: Double = ssTot > 1e-9 ? 1 - ssRes / ssTot : 0
            if r2 < 0.35 {
                return true
            }
            if maxAbsResidual > 5.0 {
                return true
            }
        }
        // If RMSE dominates the total drop, unreliable
        if let firstS = samples.first, let lastS = samples.last {
            let totalDrop = Double(firstS.remainingPercent - lastS.remainingPercent)
            if totalDrop > 0 && rmse > totalDrop * 0.6 && totalDrop < 5 {
                return true
            }
        }
        return false
    }
}

struct UsageTrendStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "codex.monitor.native.usage-trend.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load(
        matching boundary: QuotaAccountBoundary?,
        allowsUnboundHistory: Bool = false
    ) -> UsageTrendHistory? {
        guard let data = defaults.data(forKey: key),
              let history = try? decoder.decode(UsageTrendHistory.self, from: data),
              history.schemaVersion == UsageTrendHistory.currentSchemaVersion else {
            return nil
        }

        if allowsUnboundHistory, boundary == nil, history.accountBoundary == nil {
            return history
        }
        guard history.accountBoundary?.matches(boundary) == true else { return nil }
        return history
    }

    @discardableResult
    func save(_ history: UsageTrendHistory) -> Bool {
        guard history.schemaVersion == UsageTrendHistory.currentSchemaVersion,
              let data = try? encoder.encode(history) else {
            return false
        }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }
}

enum UsageTrendMetric {
    static func weeklySample(from snapshot: QuotaSnapshot) -> UsageTrendSample? {
        guard snapshot.dataSource == .real else { return nil }

        let weeklyWindows = snapshot.quotaWindows.filter {
            $0.kind == .weekly && $0.state.isCurrent
        }
        let window = weeklyWindows.first {
            $0.limitId == "codex" && $0.windowId == "secondary"
        } ?? weeklyWindows.sorted { $0.id < $1.id }.first

        if let window {
            return UsageTrendSample(
                recordedAt: snapshot.refreshedAt,
                remainingPercent: window.remainingPercent,
                resetAt: window.resetAt
            )
        }

        guard snapshot.weeklyQuotaState.isCurrent else { return nil }
        return UsageTrendSample(
            recordedAt: snapshot.refreshedAt,
            remainingPercent: snapshot.weeklyQuotaPercent,
            resetAt: nil
        )
    }
}
