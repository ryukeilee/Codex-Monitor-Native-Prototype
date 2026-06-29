import SwiftUI
import WidgetKit

struct CodexMonitorWidgetEntry: TimelineEntry {
    let date: Date
    let state: WidgetDisplayState
}

struct CodexMonitorWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexMonitorWidgetEntry {
        CodexMonitorWidgetEntry(date: .now, state: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (CodexMonitorWidgetEntry) -> Void
    ) {
        completion(CodexMonitorWidgetEntry(date: .now, state: WidgetDisplayStateStore.load()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<CodexMonitorWidgetEntry>) -> Void
    ) {
        let now = Date.now
        let entry = CodexMonitorWidgetEntry(date: now, state: WidgetDisplayStateStore.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct CodexMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexMonitorWidgetEntry
    let familyOverride: WidgetFamily?

    init(entry: CodexMonitorWidgetEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var activeFamily: WidgetFamily {
        familyOverride ?? family
    }

    private var isSmall: Bool {
        activeFamily == .systemSmall
    }

    var body: some View {
        dashboardLayout
        .padding(.top, isSmall ? 14 : 11)
        .padding(.horizontal, isSmall ? 13 : 15)
        .padding(.bottom, isSmall ? 11 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerBackground(for: .widget) {
            panelBackground
        }
    }

    private var dashboardLayout: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 6) {
            topBar

            energyCore(
                diameter: isSmall ? 72 : 74,
                valueFont: .system(
                    size: isSmall ? 19 : 20,
                    weight: .heavy,
                    design: .rounded
                )
            )
            .frame(maxWidth: .infinity)

            metricBoard
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Codex Monitor")
                .font(.system(size: isSmall ? 10 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(isSmall ? 0.2 : 0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.leading, isSmall ? 1 : 0)

            Spacer(minLength: 4)

            if isSmall {
                compactStatusIndicator
            } else {
                statusBadge
            }
        }
        .padding(.top, isSmall ? 4 : 5)
        .padding(.horizontal, isSmall ? 3 : 4)
    }

    private var metricBoard: some View {
        VStack(spacing: isSmall ? 6 : 6) {
            metricRow(leading: ("周额度", entry.state.weeklyQuotaText), trailing: ("刷新状态", entry.state.statusText))
            metricRow(leading: ("恢复时间", shortRecoveryText), trailing: ("更新时间", updatedShortText))
        }
        .padding(.horizontal, isSmall ? 9 : 13)
        .padding(.vertical, isSmall ? 8 : 7)
        .background(panelFill(cornerRadius: isSmall ? 18 : 18))
        .offset(y: isSmall ? -3 : -3)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
            .fill(Color(red: 0.24, green: 0.04, blue: 0.07))
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.78, green: 0.18, blue: 0.17).opacity(0.98),
                                Color(red: 0.51, green: 0.08, blue: 0.11).opacity(0.95),
                                Color(red: 0.19, green: 0.03, blue: 0.06).opacity(0.96)
                            ],
                            center: UnitPoint(x: 0.34, y: 0.32),
                            startRadius: 6,
                            endRadius: activeFamily == .systemSmall ? 130 : 190
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color(red: 0.95, green: 0.44, blue: 0.26).opacity(0.12),
                                Color.black.opacity(0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.softLight)
            }
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.87, green: 0.26, blue: 0.20).opacity(0.20),
                                Color(red: 0.44, green: 0.06, blue: 0.10).opacity(0.10),
                                Color(red: 0.17, green: 0.02, blue: 0.06).opacity(0.26)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .overlay {
                bottomArmorBands
            }
            .overlay(alignment: .center) {
                reactorBackdrop
            }
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color(red: 0.25, green: 0.03, blue: 0.05).opacity(0.08),
                                Color(red: 0.07, green: 0.01, blue: 0.03).opacity(0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color(red: 0.92, green: 0.42, blue: 0.24).opacity(0.24),
                                Color(red: 0.42, green: 0.08, blue: 0.10).opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: activeFamily == .systemSmall ? 28 : 32, style: .continuous)
                    .inset(by: 8)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.7)
            }
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    .frame(
                        width: activeFamily == .systemSmall ? 118 : 142,
                        height: activeFamily == .systemSmall ? 118 : 142
                    )
                    .offset(y: activeFamily == .systemSmall ? -6 : -8)
            }
    }

    private var reactorBackdrop: some View {
        ZStack {
            let outerDiameter = activeFamily == .systemSmall ? 106.0 : 136.0
            let chamberDiameter = activeFamily == .systemSmall ? 82.0 : 104.0
            let yOffset = activeFamily == .systemSmall ? -4.0 : -6.0

            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: outerDiameter, height: outerDiameter)
                .offset(y: yOffset)

            Circle()
                .stroke(Color(red: 0.70, green: 0.20, blue: 0.18).opacity(0.22), lineWidth: activeFamily == .systemSmall ? 9 : 12)
                .frame(width: chamberDiameter, height: chamberDiameter)
                .offset(y: yOffset)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color(red: 0.83, green: 0.28, blue: 0.20).opacity(0.20),
                            Color(red: 0.30, green: 0.04, blue: 0.08).opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: activeFamily == .systemSmall ? 1.2 : 1.4
                )
                .frame(width: chamberDiameter + 12, height: chamberDiameter + 12)
                .offset(y: yOffset)

            Circle()
                .fill(Color(red: 0.44, green: 0.84, blue: 1.0).opacity(activeFamily == .systemSmall ? 0.18 : 0.22))
                .blur(radius: activeFamily == .systemSmall ? 18 : 24)
                .frame(width: activeFamily == .systemSmall ? 54 : 70, height: activeFamily == .systemSmall ? 54 : 70)
                .offset(y: yOffset - 1)

            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.06) : Color(red: 0.73, green: 0.22, blue: 0.17).opacity(0.14))
                    .frame(width: activeFamily == .systemSmall ? 6 : 7, height: activeFamily == .systemSmall ? 16 : 20)
                    .offset(y: (activeFamily == .systemSmall ? -42 : -52) + yOffset)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
    }

    private var compactStatusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.16))
                .frame(width: 15, height: 15)

            Circle()
                .fill(statusColor.opacity(0.92))
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.35), radius: 2)
        }
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.8), radius: 4)

            Text(entry.state.statusText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.12))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(statusColor.opacity(0.24), lineWidth: 0.8)
                )
        )
    }

    private func energyCore(diameter: CGFloat, valueFont: Font) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.90, green: 0.97, blue: 1.0).opacity(0.98),
                            Color(red: 0.58, green: 0.89, blue: 1.0).opacity(0.96),
                            Color(red: 0.16, green: 0.43, blue: 0.68).opacity(0.52)
                        ],
                        center: .center,
                        startRadius: 3,
                        endRadius: diameter * 0.42
                    )
                )
                .blur(radius: 1.2)
                .padding(diameter * 0.24)

            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(red: 0.52, green: 0.88, blue: 1.0).opacity(0.60)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: diameter * 0.045, height: diameter * 0.22)
                    .offset(y: -diameter * 0.18)
                    .rotationEffect(.degrees(Double(index) * 60))
                    .blur(radius: 0.2)
            }

            Circle()
                .stroke(
                    Color.white.opacity(0.12),
                    lineWidth: diameter * 0.08
                )
                .padding(diameter * 0.11)

            Circle()
                .trim(from: 0, to: gaugeProgress)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.64, green: 0.93, blue: 1.0),
                            Color.white,
                            Color(red: 0.41, green: 0.84, blue: 1.0)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: diameter * 0.10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(diameter * 0.09)
                .shadow(color: Color(red: 0.62, green: 0.92, blue: 1.0).opacity(0.50), radius: 12)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.15, green: 0.26, blue: 0.34).opacity(0.24),
                            Color(red: 0.05, green: 0.09, blue: 0.16).opacity(0.46)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: diameter * 0.22
                    )
                )
                .padding(diameter * 0.27)

            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                .padding(diameter * 0.27)

            Text(centerQuotaNumberText)
                .font(valueFont)
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .shadow(color: Color(red: 0.52, green: 0.90, blue: 1.0).opacity(0.24), radius: 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(width: diameter, height: diameter)
        .offset(y: isSmall ? -1 : -3)
    }

    private func metricRow(
        leading: (label: String, value: String),
        trailing: (label: String, value: String)
    ) -> some View {
        HStack(spacing: isSmall ? 11 : 14) {
            metricCell(label: leading.label, value: leading.value)
            metricCell(label: trailing.label, value: trailing.value)
        }
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shortMetricLabel(label))
                .font(.system(size: isSmall ? 8 : 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.94, green: 0.83, blue: 0.71).opacity(0.86))
                .lineLimit(1)

            Text(value)
                .font(.system(size: isSmall ? 11 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panelFill(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isSmall ? 0.09 : 0.10),
                        Color(red: 0.45, green: 0.08, blue: 0.12).opacity(isSmall ? 0.22 : 0.20),
                        Color(red: 0.13, green: 0.02, blue: 0.06).opacity(isSmall ? 0.20 : 0.18)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: isSmall ? 18 : 20)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isSmall ? 0.08 : 0.07), lineWidth: 0.75)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color(red: 0.77, green: 0.24, blue: 0.18).opacity(isSmall ? 0.24 : 0.20), lineWidth: 0.6)
            )
    }

    private var bottomArmorBands: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
                .frame(
                    width: activeFamily == .systemSmall ? 126 : 182,
                    height: activeFamily == .systemSmall ? 40 : 48
                )
                .offset(x: activeFamily == .systemSmall ? -18 : -54, y: activeFamily == .systemSmall ? 57 : 60)

            Capsule(style: .continuous)
                .fill(Color(red: 0.82, green: 0.24, blue: 0.18).opacity(0.10))
                .frame(
                    width: activeFamily == .systemSmall ? 136 : 190,
                    height: activeFamily == .systemSmall ? 42 : 50
                )
                .offset(x: activeFamily == .systemSmall ? 24 : 58, y: activeFamily == .systemSmall ? 59 : 62)

            Rectangle()
                .fill(Color.white.opacity(0.02))
                .frame(width: activeFamily == .systemSmall ? 0.8 : 1, height: activeFamily == .systemSmall ? 22 : 30)
                .offset(x: activeFamily == .systemSmall ? 0 : 8, y: activeFamily == .systemSmall ? 56 : 59)
        }
        .blendMode(.screen)
    }

    private var shortRecoveryText: String {
        let line = recoveryPair.value
        if line == "--" {
            return line
        }

        return condensedTimeText(from: line)
    }

    private var recoveryPair: (label: String, value: String) {
        let recovery = entry.state.recoveryDetails(now: entry.date)
        return ("恢复时间", recovery.resetText)
    }

    private var updatedShortText: String {
        var line = entry.state.updatedLine(now: entry.date)

        if line.hasPrefix("更新 ") {
            line = String(line.dropFirst(3))
        }

        if let range = line.range(of: " · ") {
            line = String(line[..<range.lowerBound])
        }

        return condensedTimeText(from: line)
    }

    private func condensedTimeText(from line: String) -> String {
        let normalized = line
            .replacingOccurrences(of: "今天 ", with: "")
            .replacingOccurrences(of: "明天 ", with: "")
            .replacingOccurrences(of: "月", with: "/")
            .replacingOccurrences(of: "日 ", with: " ")

        if normalized.count > 5,
           let suffix = normalized.split(separator: " ").last,
           suffix.contains(":") {
            return String(suffix)
        }

        return normalized
    }

    private var centerQuotaNumberText: String {
        entry.state.fiveHourQuotaText.replacingOccurrences(of: "%", with: "")
    }

    private func shortMetricLabel(_ label: String) -> String {
        switch label {
        case "周额度":
            return "周额度"
        case "刷新状态":
            return "状态"
        case "恢复时间":
            return "恢复"
        case "更新时间":
            return "更新"
        default:
            return label
        }
    }

    private var gaugeProgress: CGFloat {
        let value = Double(entry.state.fiveHourQuotaText.replacingOccurrences(of: "%", with: "")) ?? 0
        let clamped = min(max(value / 100, 0.05), 1.0)
        return clamped
    }

    private var statusColor: Color {
        switch entry.state.status {
        case .success:
            return .green
        case .refreshing:
            return .blue
        case .stale, .networkFailed, .authRequired, .parseFailed:
            return .orange
        case .noSnapshot, .idle, .demoMode:
            return .secondary
        }
    }
}

struct CodexMonitorQuotaWidget: Widget {
    let kind = CodexMonitorWidgetConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexMonitorWidgetProvider()) { entry in
            CodexMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Monitor")
        .description("显示 Codex 5小时额度、周额度、恢复时间和刷新状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct CodexMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexMonitorQuotaWidget()
    }
}
