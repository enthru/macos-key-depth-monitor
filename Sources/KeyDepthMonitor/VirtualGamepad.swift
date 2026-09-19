import Darwin
import Foundation
import IOKit.hid

struct VirtualGamepadReport: Equatable {
    static let reportID: UInt8 = 0x01
    static let axisMaximum = 32_767

    let leftX: Int16
    let leftY: Int16
    let rightX: Int16
    let rightY: Int16
    let buttons: UInt16

    static func wasd(depths: [Int: Int], fullPressDepths: [Int: Int]) -> VirtualGamepadReport {
        let left = normalizedDepth(index: 9, depths: depths, fullPressDepths: fullPressDepths)
        let right = normalizedDepth(index: 21, depths: depths, fullPressDepths: fullPressDepths)
        let up = normalizedDepth(index: 14, depths: depths, fullPressDepths: fullPressDepths)
        let down = normalizedDepth(index: 15, depths: depths, fullPressDepths: fullPressDepths)
        return VirtualGamepadReport(
            leftX: axis(right - left),
            leftY: axis(down - up),
            rightX: 0,
            rightY: 0,
            buttons: 0
        )
    }

    var bytes: [UInt8] {
        var result = [Self.reportID]
        for value in [leftX, leftY, rightX, rightY] {
            let raw = UInt16(bitPattern: value)
            result.append(UInt8(raw & 0xFF))
            result.append(UInt8(raw >> 8))
        }
        result.append(UInt8(buttons & 0xFF))
        result.append(UInt8(buttons >> 8))
        return result
    }

    private static func normalizedDepth(
        index: Int,
        depths: [Int: Int],
        fullPressDepths: [Int: Int]
    ) -> Double {
        let depth = max(0, depths[index, default: 0])
        let maximum = max(1, fullPressDepths[index, default: 720])
        return min(Double(depth) / Double(maximum), 1)
    }

    private static func axis(_ value: Double) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16((clamped * Double(axisMaximum)).rounded())
    }
}

final class VirtualGamepad {
    static let productName = "Key Depth Virtual Gamepad"
    static let vendorID = 0xF055
    static let productID = 0x4B44

    private var device: IOHIDUserDevice?

    var isActive: Bool { device != nil }

    func start() -> String? {
        guard device == nil else { return nil }
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(Self.reportDescriptor),
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDVersionNumberKey as String: 1,
            kIOHIDManufacturerKey as String: "Key Depth Monitor",
            kIOHIDProductKey as String: Self.productName,
            kIOHIDSerialNumberKey as String: "KEYDEPTH-0001",
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x05,
            "GCSyntheticDevice": true
        ]

        guard let created = IOHIDUserDeviceCreateWithProperties(
            kCFAllocatorDefault,
            properties as CFDictionary,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) else {
            return "macOS rejected virtual HID creation. The signed app needs com.apple.developer.hid.virtual.device."
        }
        device = created
        let result = send(.init(leftX: 0, leftY: 0, rightX: 0, rightY: 0, buttons: 0))
        if result != kIOReturnSuccess {
            device = nil
            return "Virtual gamepad was created, but the initial report failed (\(Self.ioResult(result)))."
        }
        return nil
    }

    func stop() {
        if device != nil {
            _ = send(.init(leftX: 0, leftY: 0, rightX: 0, rightY: 0, buttons: 0))
        }
        device = nil
    }

    @discardableResult
    func send(_ report: VirtualGamepadReport) -> IOReturn {
        guard let device else { return kIOReturnNotOpen }
        let bytes = report.bytes
        return bytes.withUnsafeBytes { buffer in
            IOHIDUserDeviceHandleReportWithTimeStamp(
                device,
                mach_absolute_time(),
                buffer.bindMemory(to: UInt8.self).baseAddress!,
                bytes.count
            )
        }
    }

    private static func ioResult(_ result: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }

    /// Generic Desktop / Game Pad, report 1: four signed 16-bit axes and 16 buttons.
    private static let reportDescriptor: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x05,       // Usage (Game Pad)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       // Report ID (1)
        0x09, 0x01,       // Usage (Pointer)
        0xA1, 0x00,       // Collection (Physical)
        0x16, 0x01, 0x80, // Logical Minimum (-32767)
        0x26, 0xFF, 0x7F, // Logical Maximum (32767)
        0x75, 0x10,       // Report Size (16)
        0x95, 0x04,       // Report Count (4)
        0x09, 0x30,       // Usage (X)
        0x09, 0x31,       // Usage (Y)
        0x09, 0x33,       // Usage (Rx)
        0x09, 0x34,       // Usage (Ry)
        0x81, 0x02,       // Input (Data, Variable, Absolute)
        0xC0,             // End Collection
        0x05, 0x09,       // Usage Page (Button)
        0x19, 0x01,       // Usage Minimum (Button 1)
        0x29, 0x10,       // Usage Maximum (Button 16)
        0x15, 0x00,       // Logical Minimum (0)
        0x25, 0x01,       // Logical Maximum (1)
        0x75, 0x01,       // Report Size (1)
        0x95, 0x10,       // Report Count (16)
        0x81, 0x02,       // Input (Data, Variable, Absolute)
        0xC0              // End Collection
    ]
}
