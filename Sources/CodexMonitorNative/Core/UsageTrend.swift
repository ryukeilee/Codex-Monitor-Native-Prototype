import Foundation

enum UsageTrendNotice: String, Codable, Equatable {
    case quotaReset
    case anomalousJump
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

    mutating func append(_ sample: UsageTrendSample) {
        guard let previous = samples.last else {
            samples = [sample]
            latestNotice = nil
            return
        }

        guard sample.recordedAt > previous.recordedAt else { return }

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
            return
        }

        let isUnexpectedIncrease = change > 0
        let isRapidDrop = elapsed < 30 * 60 && change < -20
        let isExtremeDrop = change < -50
        guard !isUnexpectedIncrease, !isRapidDrop, !isExtremeDrop else {
            samples = [sample]
            latestNotice = .anomalousJump
            return
        }

        samples.append(sample)
        latestNotice = nil
        prune(relativeTo: sample.recordedAt)
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

        let consumed = first.remainingPercent - last.remainingPercent
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

        let rate = Double(consumed) / (span / 3600)
        guard rate.isFinite, rate > 0 else {
            return UsageTrendAnalysis(
                state: .insufficientData,
                samples: samples,
                ratePercentPerHour: nil,
                exhaustionAt: nil,
                resetAt: resetAt,
                latestNotice: history.latestNotice
            )
        }

        let hoursToExhaustion = Double(last.remainingPercent) / rate
        return UsageTrendAnalysis(
            state: .consuming,
            samples: samples,
            ratePercentPerHour: rate,
            exhaustionAt: last.recordedAt.addingTimeInterval(hoursToExhaustion * 3600),
            resetAt: resetAt,
            latestNotice: history.latestNotice
        )
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
