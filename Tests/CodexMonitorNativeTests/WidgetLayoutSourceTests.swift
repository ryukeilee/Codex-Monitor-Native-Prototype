import XCTest

final class WidgetLayoutSourceTests: XCTestCase {
    func testWidgetFooterUsesIndependentBottomOverlayWithoutReservedContentSpace() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorWidgetExtension/CodexMonitorWidget.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".overlay(alignment: .bottom) {"))
        XCTAssertTrue(source.contains("footerDock(resetCreditFooterText)"))
        XCTAssertTrue(source.contains(".padding(.top, isSmall ? 14 : 11)"))
        XCTAssertTrue(source.contains(".padding(.top, isSmall ? 4 : 5)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
        XCTAssertTrue(source.contains(".containerBackground(for: .widget) {"))
        XCTAssertTrue(source.contains("panelBackground"))
        XCTAssertFalse(source.contains(".padding(.top, isSmall ? 8 : 5)"))
        XCTAssertFalse(source.contains(".padding(.top, 0)"))
        XCTAssertFalse(source.contains("@Environment(\\.widgetContentMargins)"))
        XCTAssertFalse(source.contains("panelExpansionInsets"))
        XCTAssertFalse(source.contains("GeometryReader"))
        XCTAssertFalse(source.contains(".padding(.bottom, isSmall ? 13 : 15)"))
        XCTAssertFalse(source.contains(".frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)"))
    }

    func testWidgetFooterDisplayRemovesEarliestResetPrefix() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexMonitorWidgetExtension/CodexMonitorWidget.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("if line.hasPrefix(\"最早重置 \") {"))
        XCTAssertTrue(source.contains("return String(line.dropFirst(\"最早重置 \".count))"))
    }
}
