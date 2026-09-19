import AppKit
import ApplicationServices
import Foundation

enum KeyboardSuppressionScope: String, CaseIterable, Codable, Identifiable {
    case geForceNow
    case systemWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geForceNow: return "GeForce NOW only"
        case .systemWide: return "System-wide"
        }
    }
}

final class KeyboardSuppressor {
    static let geForceNowBundleIdentifier = "com.nvidia.gfnpc.mall"
    static let wasdKeyCodes: Set<Int64> = [0, 1, 2, 13]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var scope: KeyboardSuppressionScope = .geForceNow
    var onUnexpectedDisable: ((String) -> Void)?

    var isActive: Bool { eventTap != nil }

    func start(scope: KeyboardSuppressionScope) -> String? {
        stop()
        self.scope = scope

        let permissionOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(permissionOptions) else {
            return "Accessibility permission is required to suppress keyboard events. Grant it in System Settings, then try again."
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return "Could not create the keyboard filter. Check Accessibility permission and relaunch the app."
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return "Could not attach the keyboard filter to the main run loop."
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }

    static func shouldSuppress(
        keyCode: Int64,
        scope: KeyboardSuppressionScope,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard wasdKeyCodes.contains(keyCode) else { return false }
        switch scope {
        case .geForceNow:
            return frontmostBundleIdentifier == geForceNowBundleIdentifier
        case .systemWide:
            return true
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stop()
                self.onUnexpectedDisable?(
                    "macOS disabled the keyboard filter. Check Accessibility permission and enable it again."
                )
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if Self.shouldSuppress(
            keyCode: keyCode,
            scope: scope,
            frontmostBundleIdentifier: frontmost
        ) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let suppressor = Unmanaged<KeyboardSuppressor>.fromOpaque(userInfo).takeUnretainedValue()
        return suppressor.handle(type: type, event: event)
    }
}
