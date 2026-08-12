import SwiftUI

struct UsageTrendView: View {
    let analysis: UsageTrendAnalysis

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let display = UsageTrendFormatting.display(
                for: analysis,
                now: context.date
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MetallicPalette.red)
                    Text("周额度消耗趋势")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(display.detailText)
                        .font(.caption2)
                        .foregroundStyle(MetallicPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if analysis.samples.count >= 2 {
                    UsageTrendSparkline(samples: analysis.samples)
                        .frame(height: 38)
                        .accessibilityHidden(true)
                }

                HStack(alignment: .top, spacing: 8) {
                    metric(title: "当前速度", value: display.speedText)
                    metric(title: "预计耗尽", value: display.exhaustionText)
                    metric(title: "距离重置", value: display.resetRemainingText)
                }
            }
            .padding(MetallicControlMetrics.sectionHorizontalInset)
            .background(MetallicPalette.card)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(MetallicPalette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("周额度消耗趋势")
            .accessibilityValue(
                "当前速度 \(display.speedText)，预计耗尽 \(display.exhaustionText)，距离重置 \(display.resetRemainingText)"
            )
            .accessibilityHint(display.detailText)
            .accessibilityIdentifier("usage-trend-summary")
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(MetallicPalette.muted)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MetallicPalette.foreground)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageTrendSparkline: View {
    let samples: [UsageTrendSample]

    var body: some View {
        GeometryReader { geometry in
            let points = chartPoints(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MetallicPalette.innerCard)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(MetallicPalette.redBright, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard let first = samples.first, let last = samples.last else { return [] }
        let duration = max(1, last.recordedAt.timeIntervalSince(first.recordedAt))
        let horizontalInset: CGFloat = 6
        let verticalInset: CGFloat = 5
        let width = max(0, size.width - horizontalInset * 2)
        let height = max(0, size.height - verticalInset * 2)
        return samples.map { sample in
            let xRatio = sample.recordedAt.timeIntervalSince(first.recordedAt) / duration
            let yRatio = Double(sample.remainingPercent) / 100
            return CGPoint(
                x: horizontalInset + width * xRatio,
                y: verticalInset + height * (1 - yRatio)
            )
        }
    }
}
