import XCTest
@testable import KeyDepthMonitor

final class DepthReportDecoderTests: XCTestCase {
    func testDecodesReportWithEmbeddedReportID() {
        let event = DepthReportDecoder.decode(
            reportID: 0,
            bytes: [0x05, 0x1B, 0xD0, 0x02, 0x0E]
        )
        XCTAssertEqual(event, DepthEvent(keyIndex: 14, depth: 720))
    }

    func testDecodesIOHIDPayloadWithSeparateReportID() {
        let event = DepthReportDecoder.decode(
            reportID: 0x05,
            bytes: [0x1B, 0xCC, 0x02, 0x09]
        )
        XCTAssertEqual(event, DepthEvent(keyIndex: 9, depth: 716))
    }

    func testRejectsUnrelatedReports() {
        XCTAssertNil(DepthReportDecoder.decode(reportID: 1, bytes: [0x02, 1, 2, 3]))
    }

    func testRejectsTruncatedReports() {
        XCTAssertNil(DepthReportDecoder.decode(reportID: 5, bytes: [0x1B, 1, 2]))
    }

    func testDecodesObservedPressStartPacket() {
        let event = DepthReportDecoder.decode(
            reportID: 0x05,
            bytes: [0x1B, 0x0F, 0x00, 0x29, 0, 0, 0, 0]
        )
        XCTAssertEqual(event, DepthEvent(keyIndex: 41, depth: 15))
    }

    func testDecodesObservedBottomOutAndReleasePackets() {
        XCTAssertEqual(
            DepthReportDecoder.decode(reportID: 0, bytes: [0x05, 0x1B, 0x69, 0x01, 0x29]),
            DepthEvent(keyIndex: 41, depth: 361)
        )
        XCTAssertEqual(
            DepthReportDecoder.decode(reportID: 0x05, bytes: [0x1B, 0x00, 0x00, 0x29]),
            DepthEvent(keyIndex: 41, depth: 0)
        )
    }

    func testNativeFeaturePayloadHasNoLeadingReportID() {
        let payload = DepthFeatureReport.monitoring(enabled: true)
        XCTAssertEqual(payload.count, 64)
        XCTAssertEqual(Array(payload.prefix(9)), [0x1B, 0x01, 0, 0, 0, 0, 0, 0xE3, 0])
    }

    func testHIDAPIFeatureReportPrependsReportID() {
        let report = DepthFeatureReport.hidAPIReport(enabled: false)
        XCTAssertEqual(report.count, 65)
        XCTAssertEqual(Array(report.prefix(9)), [0, 0x1B, 0, 0, 0, 0, 0, 0, 0xE4])
    }
}
