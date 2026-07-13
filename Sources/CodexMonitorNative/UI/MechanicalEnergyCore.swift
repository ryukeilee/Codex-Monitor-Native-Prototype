import SwiftUI

struct MechanicalEnergyCoreLayout: Equatable {
    enum Scale: Equatable {
        case compact
        case widget
        case standard
    }

    let scale: Scale

    init(diameter: CGFloat) {
        if diameter <= 44 {
            scale = .compact
        } else if diameter <= 76 {
            scale = .widget
        } else {
            scale = .standard
        }
    }

    var tickCount: Int {
        switch scale {
        case .compact: 8
        case .widget: 16
        case .standard: 18
        }
    }

    var strutCount: Int {
        switch scale {
        case .compact: 4
        case .widget, .standard: 8
        }
    }

    var emitterCount: Int {
        switch scale {
        case .compact: 0
        case .widget, .standard: 8
        }
    }

    var armorSegmentCount: Int {
        switch scale {
        case .compact: 4
        case .widget, .standard: 6
        }
    }

    var usesBlurredCoreGlow: Bool { scale != .compact }
    var usesOuterGlow: Bool { scale != .compact }
    var usesCenterReadabilityPlate: Bool { scale == .widget }

    var progressLineWidthFactor: CGFloat {
        scale == .widget ? 0.065 : 0.055
    }

    var progressPaddingFactor: CGFloat {
        scale == .widget ? 0.19 : 0.22
    }

    var coreOrbDiameterFactor: CGFloat {
        switch scale {
        case .compact: 0.30
        case .widget: 0.38
        case .standard: 0.34
        }
    }

    var centerContentDiameterFactor: CGFloat {
        switch scale {
        case .compact: 0.28
        case .widget: 0.42
        case .standard: 0.32
        }
    }
}

struct MechanicalEnergyCore<CenterContent: View>: View {
    let diameter: CGFloat
    let rotation: Angle
    let progress: CGFloat?
    private let centerContent: CenterContent

    init(
        diameter: CGFloat,
        rotation: Angle = .zero,
        progress: CGFloat? = nil,
        @ViewBuilder centerContent: () -> CenterContent
    ) {
        self.diameter = diameter
        self.rotation = rotation
        self.progress = progress.map { min(max($0, 0), 1) }
        self.centerContent = centerContent()
    }

    var body: some View {
        let layout = MechanicalEnergyCoreLayout(diameter: diameter)

        ZStack {
            outerHousing(layout: layout)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.24, green: 0.025, blue: 0.035),
                            MechanicalEnergyCorePalette.red,
                            Color(red: 0.32, green: 0.025, blue: 0.04),
                            MechanicalEnergyCorePalette.redHighlight,
                            Color(red: 0.10, green: 0.01, blue: 0.02),
                            Color(red: 0.24, green: 0.025, blue: 0.035)
                        ],
                        center: .center
                    ),
                    lineWidth: diameter * 0.12
                )
                .padding(diameter * 0.075)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.36), MechanicalEnergyCorePalette.red.opacity(0.34), Color.black.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(0.65, diameter * 0.012)
                )
                .padding(diameter * 0.025)

            segmentedArmorRing
                .rotationEffect(rotation * 0.35)

            ZStack {
                ForEach(0..<layout.tickCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(
                            index.isMultiple(of: 3)
                                ? Color.white.opacity(layout.scale == .compact ? 0.78 : 0.86)
                                : MechanicalEnergyCorePalette.redHighlight.opacity(0.92)
                        )
                        .frame(
                            width: max(1, diameter * 0.022),
                            height: diameter * (index.isMultiple(of: 3) ? 0.074 : 0.05)
                        )
                        .offset(y: -diameter * 0.38)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(layout.tickCount)))
                }
            }
            .rotationEffect(rotation)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.25, green: 0.035, blue: 0.055),
                            Color(red: 0.08, green: 0.015, blue: 0.025)
                        ],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: diameter * 0.35
                    )
                )
                .padding(diameter * 0.19)

            ZStack {
                ForEach(0..<layout.strutCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    MechanicalEnergyCorePalette.red.opacity(0.28),
                                    MechanicalEnergyCorePalette.redHighlight.opacity(0.88),
                                    Color.black.opacity(0.72)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: diameter * (layout.scale == .compact ? 0.052 : 0.045),
                            height: diameter * (layout.scale == .compact ? 0.15 : 0.17)
                        )
                        .offset(y: -diameter * 0.235)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(layout.strutCount)))
                }
            }
            .rotationEffect(Angle(degrees: -rotation.degrees * 0.55))

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            MechanicalEnergyCorePalette.red.opacity(0.32),
                            Color.white.opacity(0.26),
                            MechanicalEnergyCorePalette.redHighlight.opacity(0.78),
                            Color.black.opacity(0.82),
                            MechanicalEnergyCorePalette.red.opacity(0.32)
                        ],
                        center: .center
                    ),
                    lineWidth: diameter * (layout.scale == .compact ? 0.055 : 0.065)
                )
                .padding(diameter * (layout.scale == .compact ? 0.215 : 0.225))

            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [
                                MechanicalEnergyCorePalette.blue,
                                Color.white,
                                MechanicalEnergyCorePalette.blueHighlight
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(
                            lineWidth: diameter * layout.progressLineWidthFactor,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(diameter * layout.progressPaddingFactor)
                    .shadow(
                        color: MechanicalEnergyCorePalette.blue.opacity(layout.scale == .compact ? 0 : 0.52),
                        radius: layout.scale == .widget ? 2 : diameter * 0.07
                    )
            }

            if layout.emitterCount > 0 {
                ZStack {
                    ForEach(0..<layout.emitterCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, MechanicalEnergyCorePalette.blueHighlight],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: diameter * 0.04, height: diameter * 0.105)
                            .offset(y: -diameter * 0.17)
                            .rotationEffect(.degrees(Double(index) * 360 / Double(layout.emitterCount)))
                            .shadow(color: MechanicalEnergyCorePalette.blue.opacity(0.52), radius: 1.25)
                    }
                }
                .rotationEffect(rotation * 0.22)
            }

            if layout.usesBlurredCoreGlow {
                Circle()
                    .fill(MechanicalEnergyCorePalette.blue.opacity(layout.scale == .widget ? 0.25 : 0.36))
                    .frame(width: diameter * 0.46, height: diameter * 0.46)
                    .blur(radius: layout.scale == .widget ? 3 : diameter * 0.075)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.82, green: 0.96, blue: 1.0),
                            MechanicalEnergyCorePalette.blue,
                            Color(red: 0.04, green: 0.16, blue: 0.26)
                        ],
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 1,
                        endRadius: diameter * 0.21
                    )
                )
                .frame(
                    width: diameter * layout.coreOrbDiameterFactor,
                    height: diameter * layout.coreOrbDiameterFactor
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.66), lineWidth: max(0.75, diameter * 0.012))
                }
                .shadow(
                    color: Color.white.opacity(layout.scale == .compact ? 0.46 : 0.68),
                    radius: layout.scale == .compact ? 0.75 : diameter * 0.025
                )
                .shadow(
                    color: MechanicalEnergyCorePalette.blue.opacity(layout.scale == .compact ? 0.42 : 0.74),
                    radius: layout.scale == .compact ? 1.25 : (layout.scale == .widget ? 3 : diameter * 0.09)
                )

            if layout.usesCenterReadabilityPlate {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.035, green: 0.11, blue: 0.16).opacity(0.74),
                                Color(red: 0.015, green: 0.055, blue: 0.09).opacity(0.88)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter * 0.16
                        )
                    )
                    .frame(width: diameter * 0.32, height: diameter * 0.32)
                    .overlay {
                        Circle()
                            .stroke(MechanicalEnergyCorePalette.blueHighlight.opacity(0.62), lineWidth: 0.8)
                    }
            }

            centerContent
                .frame(
                    width: diameter * layout.centerContentDiameterFactor,
                    height: diameter * layout.centerContentDiameterFactor
                )
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func outerHousing(layout: MechanicalEnergyCoreLayout) -> some View {
        let housing = Circle()
            .fill(Color(red: 0.20, green: 0.015, blue: 0.025))

        if layout.usesOuterGlow {
            housing
                .shadow(color: Color.black.opacity(0.68), radius: diameter * 0.07, y: diameter * 0.04)
                .shadow(color: MechanicalEnergyCorePalette.deepRed.opacity(0.48), radius: diameter * 0.05)
        } else {
            housing
                .shadow(color: Color.black.opacity(0.62), radius: 1.5, y: 1)
        }
    }

    private var segmentedArmorRing: some View {
        let layout = MechanicalEnergyCoreLayout(diameter: diameter)

        return ZStack {
            ForEach(0..<layout.armorSegmentCount, id: \.self) { index in
                Circle()
                    .trim(
                        from: CGFloat(index) / CGFloat(layout.armorSegmentCount) + 0.012,
                        to: CGFloat(index) / CGFloat(layout.armorSegmentCount)
                            + (layout.scale == .compact ? 0.17 : 0.118)
                    )
                    .stroke(
                        index.isMultiple(of: 2)
                            ? MechanicalEnergyCorePalette.redHighlight.opacity(0.82)
                            : MechanicalEnergyCorePalette.red.opacity(0.56),
                        style: StrokeStyle(
                            lineWidth: diameter * 0.025,
                            lineCap: .butt
                        )
                    )
                    .padding(diameter * 0.145)
            }
        }
    }
}

private enum MechanicalEnergyCorePalette {
    static let deepRed = Color(red: 0.48, green: 0.025, blue: 0.045)
    static let red = Color(red: 0.72, green: 0.055, blue: 0.075)
    static let redHighlight = Color(red: 1.0, green: 0.22, blue: 0.20)
    static let blue = Color(red: 0.20, green: 0.72, blue: 1.0)
    static let blueHighlight = Color(red: 0.58, green: 0.92, blue: 1.0)
}
