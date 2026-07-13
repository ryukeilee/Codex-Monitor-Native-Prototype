import XCTest
@testable import CodexMonitorNative

final class MechanicalEnergyCoreLayoutTests: XCTestCase {
    func testFortyPointCoreUsesCrispReducedCompactLayers() {
        let layout = MechanicalEnergyCoreLayout(diameter: 40)

        XCTAssertEqual(layout.scale, .compact)
        XCTAssertEqual(layout.tickCount, 8)
        XCTAssertEqual(layout.strutCount, 4)
        XCTAssertEqual(layout.armorSegmentCount, 4)
        XCTAssertEqual(layout.emitterCount, 0)
        XCTAssertFalse(layout.usesBlurredCoreGlow)
        XCTAssertFalse(layout.usesOuterGlow)
        XCTAssertFalse(layout.usesCenterReadabilityPlate)
    }

    func testWidgetCorePreservesMechanicalLayersAndPrioritizesQuotaReadability() {
        for diameter in [72.0, 74.0] {
            let layout = MechanicalEnergyCoreLayout(diameter: diameter)
            let standard = MechanicalEnergyCoreLayout(diameter: 88)

            XCTAssertEqual(layout.scale, .widget)
            XCTAssertEqual(layout.tickCount, 16)
            XCTAssertEqual(layout.strutCount, 8)
            XCTAssertEqual(layout.armorSegmentCount, 6)
            XCTAssertEqual(layout.emitterCount, 8)
            XCTAssertTrue(layout.usesBlurredCoreGlow)
            XCTAssertTrue(layout.usesOuterGlow)
            XCTAssertTrue(layout.usesCenterReadabilityPlate)
            XCTAssertGreaterThan(layout.progressLineWidthFactor, standard.progressLineWidthFactor)
            XCTAssertLessThan(layout.progressPaddingFactor, standard.progressPaddingFactor)
            XCTAssertGreaterThan(layout.coreOrbDiameterFactor, standard.coreOrbDiameterFactor)
            XCTAssertGreaterThan(layout.centerContentDiameterFactor, standard.centerContentDiameterFactor)
        }
    }

    func testLayoutScaleBoundariesAreStable() {
        XCTAssertEqual(MechanicalEnergyCoreLayout(diameter: 44).scale, .compact)
        XCTAssertEqual(MechanicalEnergyCoreLayout(diameter: 45).scale, .widget)
        XCTAssertEqual(MechanicalEnergyCoreLayout(diameter: 76).scale, .widget)
        XCTAssertEqual(MechanicalEnergyCoreLayout(diameter: 77).scale, .standard)
    }
}
