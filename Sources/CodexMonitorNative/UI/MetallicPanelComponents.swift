import SwiftUI

enum MetallicPalette {
    static let red = Color(red: 0.94, green: 0.16, blue: 0.18)
    static let redBright = Color(red: 1.0, green: 0.32, blue: 0.30)
    static let foreground = Color(red: 0.97, green: 0.96, blue: 0.96)
    static let muted = Color(red: 0.64, green: 0.62, blue: 0.64)
    static let separator = Color.white.opacity(0.10)
    static let border = Color.white.opacity(0.13)
    static let card = Color.black.opacity(0.23)
    static let innerCard = Color.white.opacity(0.055)
    static let track = Color.white.opacity(0.10)
    static let redGradient = LinearGradient(
        colors: [red, redBright],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct MetallicPanelBackground<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.24, green: 0.015, blue: 0.02),
                            Color(red: 0.075, green: 0.03, blue: 0.035),
                            Color(red: 0.015, green: 0.012, blue: 0.014)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [MetallicPalette.red.opacity(0.55), Color.white.opacity(0.08), Color.black.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 12)
            content()
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(MetallicPalette.foreground)
    }
}

struct ReactorView: View {
    let isPanelActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isPanelActive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                    reactorCore(phase: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                reactorCore(phase: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度反应堆")
    }

    @ViewBuilder
    private func reactorCore(phase: TimeInterval) -> some View {
        let rotation = Angle(degrees: phase.truncatingRemainder(dividingBy: 30) * 4)
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)

            MechanicalEnergyCore(diameter: diameter, rotation: rotation) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
