import Foundation

struct DepthEvent: Equatable, Sendable {
    let keyIndex: Int
    let depth: Int
}

enum DepthReportDecoder {
    static let depthEvent: UInt8 = 0x1B
    static let vendorReportID: UInt8 = 0x05

    /// Decodes both hidapi-style buffers (report ID included as byte 0) and
    /// IOHID-style buffers (report ID supplied separately and omitted from bytes).
    static func decode(reportID: UInt32, bytes: [UInt8]) -> DepthEvent? {
        guard !bytes.isEmpty else { return nil }

        let payload: ArraySlice<UInt8>
        if bytes[0] == vendorReportID {
            guard bytes.count >= 5 else { return nil }
            payload = bytes.dropFirst()
        } else {
            guard reportID == UInt32(vendorReportID) || bytes[0] == depthEvent else {
                return nil
            }
            guard bytes.count >= 4 else { return nil }
            payload = bytes[...]
        }

        guard payload.count >= 4 else { return nil }
        let start = payload.startIndex
        guard payload[start] == depthEvent else { return nil }

        let low = Int(payload[payload.index(start, offsetBy: 1)])
        let high = Int(payload[payload.index(start, offsetBy: 2)])
        let keyIndex = Int(payload[payload.index(start, offsetBy: 3)])
        return DepthEvent(keyIndex: keyIndex, depth: low | (high << 8))
    }
}
