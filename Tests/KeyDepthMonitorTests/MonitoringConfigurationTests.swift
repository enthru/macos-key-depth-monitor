import XCTest
@testable import KeyDepthMonitor

final class MonitoringConfigurationTests: XCTestCase {
    private var suiteName: String!
    private var preferences: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeyDepthMonitorTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suiteName)
        preferences.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        preferences.removePersistentDomain(forName: suiteName)
        preferences = nil
        suiteName = nil
        super.tearDown()
    }

    func testUsesDefaultKeysForNewInstallation() {
        let monitor = KeyboardDepthMonitor(preferences: preferences)
        XCTAssertEqual(monitor.monitoredKeys, MonitoredKey.defaults)
        XCTAssertFalse(monitor.showUnconfiguredKeys)
    }

    func testAddsAndPersistsCustomKey() {
        let monitor = KeyboardDepthMonitor(preferences: preferences)
        XCTAssertNil(monitor.saveMonitoredKey(index: 77, label: "  Custom  ", fullPressDepth: 705))

        let reloaded = KeyboardDepthMonitor(preferences: preferences)
        XCTAssertEqual(
            reloaded.monitoredKeys.first(where: { $0.index == 77 }),
            MonitoredKey(index: 77, label: "Custom", fullPressDepth: 705)
        )
    }

    func testRejectsDuplicateAndInvalidKey() {
        let monitor = KeyboardDepthMonitor(preferences: preferences)
        XCTAssertNotNil(monitor.saveMonitoredKey(index: 14, label: "Duplicate W", fullPressDepth: 720))
        XCTAssertNotNil(monitor.saveMonitoredKey(index: 256, label: "Invalid", fullPressDepth: 720))
        XCTAssertNotNil(monitor.saveMonitoredKey(index: 50, label: "   ", fullPressDepth: 720))
    }

    func testEditsAndRemovesKey() {
        let monitor = KeyboardDepthMonitor(preferences: preferences)
        XCTAssertNil(
            monitor.saveMonitoredKey(
                originalIndex: 14,
                index: 99,
                label: "Forward",
                fullPressDepth: 700
            )
        )
        XCTAssertFalse(monitor.monitoredKeys.contains { $0.index == 14 })
        XCTAssertTrue(monitor.monitoredKeys.contains { $0.index == 99 })

        monitor.removeMonitoredKey(index: 99)
        XCTAssertFalse(monitor.monitoredKeys.contains { $0.index == 99 })
    }

    func testPersistsUnconfiguredVisibility() {
        let monitor = KeyboardDepthMonitor(preferences: preferences)
        monitor.setShowUnconfiguredKeys(true)
        XCTAssertTrue(KeyboardDepthMonitor(preferences: preferences).showUnconfiguredKeys)
    }

    func testWASDGamepadReportUsesAnalogDepth() {
        let report = VirtualGamepadReport.wasd(
            depths: [9: 360, 14: 720],
            fullPressDepths: [9: 720, 14: 720, 15: 720, 21: 720]
        )
        XCTAssertEqual(report.leftX, -16_384)
        XCTAssertEqual(report.leftY, -32_767)
        XCTAssertEqual(report.bytes.count, 11)
        XCTAssertEqual(report.bytes[0], VirtualGamepadReport.reportID)
    }

    func testOpposingGamepadDirectionsCancel() {
        let report = VirtualGamepadReport.wasd(
            depths: [9: 500, 21: 500, 14: 300, 15: 300],
            fullPressDepths: [:]
        )
        XCTAssertEqual(report.leftX, 0)
        XCTAssertEqual(report.leftY, 0)
    }

    func testGeForceNowSuppressionIsForegroundOnly() {
        XCTAssertTrue(
            KeyboardSuppressor.shouldSuppress(
                keyCode: 13,
                scope: .geForceNow,
                frontmostBundleIdentifier: "com.nvidia.gfnpc.mall"
            )
        )
        XCTAssertFalse(
            KeyboardSuppressor.shouldSuppress(
                keyCode: 13,
                scope: .geForceNow,
                frontmostBundleIdentifier: "com.apple.TextEdit"
            )
        )
    }

    func testSystemWideSuppressionStillPassesUnmappedKeys() {
        XCTAssertTrue(
            KeyboardSuppressor.shouldSuppress(
                keyCode: 0,
                scope: .systemWide,
                frontmostBundleIdentifier: nil
            )
        )
        XCTAssertFalse(
            KeyboardSuppressor.shouldSuppress(
                keyCode: 3,
                scope: .systemWide,
                frontmostBundleIdentifier: nil
            )
        )
    }
}
