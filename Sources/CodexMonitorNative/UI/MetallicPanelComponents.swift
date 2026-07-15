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

enum MetallicControlMetrics {
    static let accessorySize: CGFloat = 24
    static let accessoryHitSize: CGFloat = 32
    static let accessoryBorderWidth: CGFloat = 1.5
    static let rowSpacing: CGFloat = 8
    static let iconColumnWidth: CGFloat = 22
    static let textColumnOffset: CGFloat = iconColumnWidth + rowSpacing
    static let sectionHorizontalInset: CGFloat = 10
    static let disclosureContentIndent: CGFloat = 14
    static let actionRowHeight: CGFloat = 28
}

struct MetallicDisclosureGroupStyle: DisclosureGroupStyle {
    let horizontalInset: CGFloat

    init(horizontalInset: CGFloat = MetallicControlMetrics.sectionHorizontalInset) {
        self.horizontalInset = horizontalInset
    }

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MetallicDisclosureHeader(
                isExpanded: configuration.isExpanded,
                horizontalInset: horizontalInset
            ) {
                configuration.isExpanded.toggle()
            } label: {
                configuration.label
            }

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, MetallicControlMetrics.disclosureContentIndent)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
            }
        }
    }
}

private struct MetallicDisclosureHeader<Label: View>: View {
    let isExpanded: Bool
    let horizontalInset: CGFloat
    let onToggle: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(disclosureAnimation) {
                onToggle()
            }
        } label: {
            HStack(spacing: MetallicControlMetrics.rowSpacing) {
                label()
                    .font(.caption.weight(.semibold))

                Spacer(minLength: MetallicControlMetrics.rowSpacing)

                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MetallicPalette.red.opacity(isHovering ? 0.28 : 0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    MetallicPalette.redBright.opacity(isHovering ? 0.95 : 0.72),
                                    lineWidth: MetallicControlMetrics.accessoryBorderWidth
                                )
                        }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MetallicPalette.redBright)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(
                    width: MetallicControlMetrics.accessorySize,
                    height: MetallicControlMetrics.accessorySize
                )
                .shadow(
                    color: isHovering ? MetallicPalette.red.opacity(0.38) : .clear,
                    radius: 4
                )
            }
            .frame(
                maxWidth: .infinity,
                minHeight: MetallicControlMetrics.accessoryHitSize,
                alignment: .leading
            )
            .padding(.horizontal, horizontalInset)
            .foregroundStyle(MetallicPalette.foreground)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MetallicPalette.red.opacity(isHovering ? 0.12 : 0.055))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MetallicDisclosureButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(hoverAnimation, value: isHovering)
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }
}

private struct MetallicDisclosureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MetallicPalette.redBright.opacity(0.10))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
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
    let allowsAnimation: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isPanelActive: Bool, allowsAnimation: Bool = true) {
        self.isPanelActive = isPanelActive
        self.allowsAnimation = allowsAnimation
    }

    var body: some View {
        Group {
            if isPanelActive && allowsAnimation && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { context in
                    reactorCore(phase: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                reactorCore(phase: 0)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
