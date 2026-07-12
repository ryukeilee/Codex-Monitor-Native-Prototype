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
    private enum MetricValueTone {
        case normal
        case subdued
    }

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
            .padding(.horizontal, isSmall ? 13 : 8)
            .padding(.bottom, isSmall ? 11 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                if let resetCreditFooterText {
                    footerDock(resetCreditFooterText)
                        .padding(.bottom, isSmall ? 12 : 14)
                }
            }
            .containerBackground(for: .widget) {
                panelBackground
            }
    }

    private var dashboardLayout: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 6) {
            topBar

            instrumentCluster
        }
    }

    private var instrumentCluster: some View {
        HStack(alignment: .center, spacing: isSmall ? 8 : 18) {
            metricColumn(
                top: (
                    "周额度",
                    entry.state.weeklyQuotaDisplay.percentText,
                    entry.state.weeklyQuotaDisplay.historyCaption
                ),
                bottom: ("恢复时间", shortRecoveryText),
                alignment: .trailing
            )

            energyCore(
                diameter: isSmall ? 72 : 74,
                valueFont: .system(
                    size: isSmall ? 19 : 20,
                    weight: .heavy,
                    design: .rounded
                )
            )

            metricColumn(
                top: ("刷新状态", entry.state.statusText, nil),
                bottom: ("更新时间", updatedShortText),
                alignment: .leading,
                topValueTone: .subdued
            )
        }
        .frame(maxWidth: .infinity)
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

    private func metricColumn(
        top: (label: String, value: String, caption: String?),
        bottom: (label: String, value: String),
        alignment: HorizontalAlignment,
        topValueTone: MetricValueTone = .normal,
        bottomValueTone: MetricValueTone = .normal
    ) -> some View {
        VStack(alignment: alignment, spacing: isSmall ? 12 : 14) {
            metricCell(label: top.label, value: top.value, caption: top.caption, alignment: alignment, tone: topValueTone)
            metricCell(label: bottom.label, value: bottom.value, alignment: alignment, tone: bottomValueTone)
        }
        .frame(maxWidth: .infinity)
    }

    private var panelBackground: some View {
        ContainerRelativeShape()
            .fill(Color(red: 0.24, green: 0.04, blue: 0.07))
            .overlay {
                panelRadialOverlay
            }
            .overlay {
                panelSoftLightOverlay
            }
            .overlay {
                panelLateralHeatOverlay
            }
            .overlay {
                bottomArmorBands
            }
            .overlay(alignment: .center) {
                reactorBackdrop
            }
            .overlay {
                panelBottomShadeOverlay
            }
            .overlay {
                panelBorderOverlay
            }
            .overlay {
                panelInnerBorderOverlay
            }
            .overlay {
                panelHaloOverlay
            }
    }

    private var panelRadialOverlay: some View {
        ContainerRelativeShape()
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

    private var panelSoftLightOverlay: some View {
        ContainerRelativeShape()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.09),
                        Color(red: 0.95, green: 0.44, blue: 0.26).opacity(0.08),
                        Color.black.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.softLight)
    }

    private var panelLateralHeatOverlay: some View {
        ContainerRelativeShape()
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

    private var panelBottomShadeOverlay: some View {
        ContainerRelativeShape()
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

    private var panelBorderOverlay: some View {
        ContainerRelativeShape()
            .stroke(
                LinearGradient(
                    colors: [
                        Color(red: 0.54, green: 0.11, blue: 0.10).opacity(0.20),
                        Color(red: 0.78, green: 0.23, blue: 0.16).opacity(0.12),
                        Color(red: 0.20, green: 0.03, blue: 0.06).opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.55
            )
    }

    private var panelInnerBorderOverlay: some View {
        ContainerRelativeShape()
            .inset(by: 8)
            .stroke(Color(red: 0.78, green: 0.24, blue: 0.18).opacity(0.08), lineWidth: 0.55)
    }

    private var panelHaloOverlay: some View {
        Circle()
            .stroke(Color.white.opacity(0.04), lineWidth: 1)
            .frame(
                width: activeFamily == .systemSmall ? 118 : 142,
                height: activeFamily == .systemSmall ? 118 : 142
            )
            .offset(y: activeFamily == .systemSmall ? -6 : -8)
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
        MechanicalEnergyCore(diameter: diameter, progress: gaugeProgress) {
            Text(centerQuotaNumberText)
                .font(valueFont)
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .shadow(color: Color(red: 0.52, green: 0.90, blue: 1.0).opacity(0.24), radius: 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .offset(y: isSmall ? -1 : -3)
    }

    private func metricCell(
        label: String,
        value: String,
        caption: String? = nil,
        alignment: HorizontalAlignment,
        tone: MetricValueTone = .normal
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(shortMetricLabel(label))
                .font(.system(size: isSmall ? 8 : 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.94, green: 0.83, blue: 0.71).opacity(0.86))
                .lineLimit(1)

            Text(value)
                .font(metricValueFont(for: tone))
                .foregroundStyle(metricValueColor(for: tone))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            if let caption {
                Text(caption)
                    .font(.system(size: isSmall ? 7 : 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.97, green: 0.91, blue: 0.84).opacity(0.66))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func metricValueFont(for tone: MetricValueTone) -> Font {
        switch tone {
        case .normal:
            return .system(size: isSmall ? 12 : 15, weight: .bold, design: .rounded)
        case .subdued:
            return .system(size: isSmall ? 11 : 13, weight: .semibold, design: .rounded)
        }
    }

    private func metricValueColor(for tone: MetricValueTone) -> Color {
        switch tone {
        case .normal:
            return .white.opacity(0.95)
        case .subdued:
            return Color(red: 0.97, green: 0.91, blue: 0.84).opacity(isSmall ? 0.80 : 0.72)
        }
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

    private var resetCreditFooterText: String? {
        guard let line = entry.state.resetCreditFooterText else {
            return nil
        }

        if line.hasPrefix("最早重置 ") {
            return String(line.dropFirst("最早重置 ".count))
        }

        return line
    }

    private var footerDockHeight: CGFloat {
        isSmall ? 12 : 13
    }

    private func footerDock(_ line: String) -> some View {
        Text(line)
            .font(.system(size: isSmall ? 8.5 : 9, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.98, green: 0.93, blue: 0.86).opacity(isSmall ? 0.58 : 0.62))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, minHeight: footerDockHeight, alignment: .center)
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
        guard entry.state.snapshot.fiveHourQuotaState.isDisplayable else {
            return "--"
        }

        return entry.state.fiveHourQuotaDisplay.percentText.replacingOccurrences(of: "%", with: "")
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
        guard entry.state.snapshot.fiveHourQuotaState.isDisplayable else {
            return 0.05
        }

        let value = Double(entry.state.snapshot.fiveHourQuotaPercent)
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
        .containerBackgroundRemovable()
    }
}

@main
struct CodexMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexMonitorQuotaWidget()
    }
}
