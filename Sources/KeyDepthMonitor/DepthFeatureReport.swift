import Foundation

enum DepthFeatureReport {
    static let command: UInt8 = 0x1B
    static let payloadLength = 64

    /// Native IOHID payload. The report ID is passed separately to
    /// IOHIDDeviceSetReport and therefore must not be prepended here.
    static func monitoring(enabled: Bool) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: payloadLength)
        payload[0] = command
        payload[1] = enabled ? 0x01 : 0x00
        let sum = payload[0..<7].reduce(0) { ($0 + Int($1)) & 0xFF }
        payload[7] = UInt8(255 - sum)
        return payload
    }

    /// hidapi transports include report ID 0 as a leading byte. Kept here so
    /// tests and diagnostics make the distinction explicit.
    static func hidAPIReport(enabled: Bool) -> [UInt8] {
        [0] + monitoring(enabled: enabled)
    }
}
