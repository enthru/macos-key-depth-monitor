import Combine
import Foundation
import IOKit.hid

struct KeyReading: Identifiable {
    let index: Int
    let label: String
    let depth: Int
    let observedMaximum: Int

    var id: Int { index }
    var normalized: Double {
        min(max(Double(depth) / Double(max(observedMaximum, 1)), 0), 1)
    }
}

struct HIDCollectionDiagnostic: Identifiable {
    let id: UInt64
    let productID: Int
    let product: String
    let usagePage: Int
    let usage: Int
    let locationID: Int?
    let inputReportIDs: [Int]
    let maxInputReportSize: Int?
    let maxFeatureReportSize: Int?
    let role: String?

    var summary: String {
        let ids = inputReportIDs.isEmpty
            ? "—"
            : inputReportIDs.map { String(format: "%02X", $0) }.joined(separator: ",")
        let location = locationID.map { String(format: "%08X", $0) } ?? "—"
        let sizes = "in=\(maxInputReportSize.map(String.init) ?? "—") feat=\(maxFeatureReportSize.map(String.init) ?? "—")"
        let selected = role.map { "  [\($0)]" } ?? ""
        return "3151:\(String(format: "%04X", productID)) loc=\(location) page=\(String(format: "%04X", usagePage))/\(String(format: "%04X", usage)) reports=\(ids) \(sizes) \(product)\(selected)"
    }
}

final class KeyboardDepthMonitor: ObservableObject {
    enum VirtualGamepadState: Equatable {
        case off
        case active
        case failed(String)

        var title: String {
            switch self {
            case .off: return "Gamepad Off"
            case .active: return "Gamepad On"
            case .failed: return "Gamepad Failed"
            }
        }

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    enum KeyboardSuppressionState: Equatable {
        case off
        case active(KeyboardSuppressionScope)
        case failed(String)

        var title: String {
            switch self {
            case .off: return "Keys Pass Through"
            case .active(.geForceNow): return "W/A/S/D Blocked in GFN"
            case .active(.systemWide): return "W/A/S/D Blocked System-wide"
            case .failed: return "Key Blocking Failed"
            }
        }

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    enum ConnectionState: Equatable {
        case stopped
        case searching
        case connected(String)
        case failed(String)

        var title: String {
            switch self {
            case .stopped: return "Stopped"
            case .searching: return "Searching for keyboard…"
            case .connected(let name): return "Connected: \(name)"
            case .failed(let message): return message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var state: ConnectionState = .stopped
    @Published private(set) var depths: [Int: Int] = [:]
    @Published private(set) var maxima: [Int: Int]
    @Published private(set) var eventCount = 0
    @Published private(set) var rawReportCount = 0
    @Published private(set) var lastReportHex = "—"
    @Published private(set) var lastKeyIndex: Int?
    @Published private(set) var virtualGamepadState: VirtualGamepadState = .off
    @Published private(set) var keyboardSuppressionState: KeyboardSuppressionState = .off
    @Published private(set) var keyboardSuppressionScope: KeyboardSuppressionScope
    @Published private(set) var monitoredKeys: [MonitoredKey]
    @Published private(set) var showUnconfiguredKeys: Bool
    @Published private(set) var collections: [HIDCollectionDiagnostic] = []
    @Published private(set) var diagnosticMessages: [String] = []

    private static let vendorID = 0x3151
    private static let preferredProducts = [0x5030, 0x5038]
    private let preferences: UserDefaults
    private let virtualGamepad = VirtualGamepad()
    private let keyboardSuppressor = KeyboardSuppressor()
    private var manager: IOHIDManager?
    private var configDevice: IOHIDDevice?
    private var inputDevice: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private var idleTimer: Timer?
    private var lastEventAt = Date.distantPast
    private var reenableSentDuringIdle = false

    var readings: [KeyReading] {
        let configured = Dictionary(uniqueKeysWithValues: monitoredKeys.map { ($0.index, $0) })
        var indexes = Set(configured.keys)
        if showUnconfiguredKeys { indexes.formUnion(depths.keys) }
        return indexes.sorted().map { index in
            let key = configured[index]
            return KeyReading(
                index: index,
                label: key?.label ?? "Key \(index)",
                depth: depths[index, default: 0],
                observedMaximum: maxima[index, default: key?.fullPressDepth ?? 720]
            )
        }
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let keys = MonitoringPreferences.loadKeys(from: preferences)
        monitoredKeys = keys
        maxima = Dictionary(uniqueKeysWithValues: keys.map { ($0.index, $0.fullPressDepth) })
        showUnconfiguredKeys = preferences.object(forKey: MonitoringPreferences.showUnconfiguredKey) as? Bool ?? false
        keyboardSuppressionScope = preferences.string(
            forKey: MonitoringPreferences.keyboardSuppressionScopeKey
        ).flatMap(KeyboardSuppressionScope.init(rawValue:)) ?? .geForceNow
        keyboardSuppressor.onUnexpectedDisable = { [weak self] message in
            self?.keyboardSuppressionState = .failed(message)
            self?.log(message)
        }
    }

    deinit {
        stop()
        inputBuffer.deallocate()
    }

    func start() {
        guard manager == nil else {
            rescan()
            return
        }

        state = .searching
        log("Starting HID scan for vendor 3151")
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = newManager

        let matching = [kIOHIDVendorIDKey as String: Self.vendorID] as CFDictionary
        IOHIDManagerSetDeviceMatching(newManager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let detail = Self.ioResult(result)
            state = .failed("Could not open HID manager (\(detail))")
            log("IOHIDManagerOpen failed: \(detail)")
            return
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.serviceIdleDevice()
        }
        rescan()
    }

    func stop() {
        keyboardSuppressor.stop()
        keyboardSuppressionState = .off
        virtualGamepad.stop()
        virtualGamepadState = .off
        idleTimer?.invalidate()
        idleTimer = nil
        disconnect(sendDisable: true)

        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let result = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess { log("IOHIDManagerClose failed: \(Self.ioResult(result))") }
        }
        manager = nil
        state = .stopped
    }

    func rescan() {
        guard let manager else { return }
        if inputDevice != nil || configDevice != nil {
            log("Manual rescan: closing the current device pair")
            disconnect(sendDisable: true)
        }
        state = .searching
        let found = devices(in: manager)
        refreshDiagnostics(found)
        connect(from: found)
    }

    func clearValues() {
        depths = [:]
        maxima = Dictionary(uniqueKeysWithValues: monitoredKeys.map { ($0.index, $0.fullPressDepth) })
        eventCount = 0
        rawReportCount = 0
        lastReportHex = "—"
        lastKeyIndex = nil
    }

    @discardableResult
    func saveMonitoredKey(
        originalIndex: Int? = nil,
        index: Int,
        label: String,
        fullPressDepth: Int
    ) -> String? {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (0...255).contains(index) else { return "Key index must be between 0 and 255." }
        guard !cleanLabel.isEmpty else { return "Key name cannot be empty." }
        guard (1...65535).contains(fullPressDepth) else { return "Full-press depth must be between 1 and 65535." }
        if monitoredKeys.contains(where: { $0.index == index && $0.index != originalIndex }) {
            return "Key index \(index) is already being monitored."
        }

        var next = monitoredKeys
        if let originalIndex {
            next.removeAll { $0.index == originalIndex }
            if originalIndex != index { maxima.removeValue(forKey: originalIndex) }
        }
        next.removeAll { $0.index == index }
        next.append(MonitoredKey(index: index, label: cleanLabel, fullPressDepth: fullPressDepth))
        next.sort { $0.index < $1.index }
        monitoredKeys = next
        maxima[index] = fullPressDepth
        MonitoringPreferences.saveKeys(next, to: preferences)
        return nil
    }

    func removeMonitoredKey(index: Int) {
        monitoredKeys.removeAll { $0.index == index }
        maxima.removeValue(forKey: index)
        MonitoringPreferences.saveKeys(monitoredKeys, to: preferences)
    }

    func resetMonitoredKeys() {
        monitoredKeys = MonitoredKey.defaults
        maxima = Dictionary(uniqueKeysWithValues: MonitoredKey.defaults.map { ($0.index, $0.fullPressDepth) })
        MonitoringPreferences.saveKeys(monitoredKeys, to: preferences)
    }

    func setShowUnconfiguredKeys(_ enabled: Bool) {
        showUnconfiguredKeys = enabled
        preferences.set(enabled, forKey: MonitoringPreferences.showUnconfiguredKey)
    }

    func toggleVirtualGamepad() {
        if virtualGamepad.isActive {
            stopKeyboardSuppression()
            virtualGamepad.stop()
            virtualGamepadState = .off
            log("Virtual gamepad stopped")
            return
        }

        if let error = virtualGamepad.start() {
            virtualGamepadState = .failed(error)
            log(error)
        } else {
            virtualGamepadState = .active
            sendVirtualGamepadReport()
            log("Virtual gamepad started as F055:4B44")
        }
    }

    func toggleKeyboardSuppression() {
        if keyboardSuppressor.isActive {
            stopKeyboardSuppression()
            return
        }
        guard virtualGamepad.isActive else {
            let message = "Enable the virtual gamepad before blocking keyboard keys."
            keyboardSuppressionState = .failed(message)
            log(message)
            return
        }
        startKeyboardSuppression()
    }

    func setKeyboardSuppressionScope(_ scope: KeyboardSuppressionScope) {
        keyboardSuppressionScope = scope
        preferences.set(scope.rawValue, forKey: MonitoringPreferences.keyboardSuppressionScopeKey)
        if keyboardSuppressor.isActive {
            keyboardSuppressor.stop()
            startKeyboardSuppression()
        }
    }

    private func startKeyboardSuppression() {
        if let error = keyboardSuppressor.start(scope: keyboardSuppressionScope) {
            keyboardSuppressionState = .failed(error)
            log(error)
        } else {
            keyboardSuppressionState = .active(keyboardSuppressionScope)
            log("Keyboard suppression enabled: \(keyboardSuppressionScope.title)")
        }
    }

    private func stopKeyboardSuppression() {
        keyboardSuppressor.stop()
        keyboardSuppressionState = .off
        log("Keyboard suppression disabled")
    }

    private func devices(in manager: IOHIDManager) -> [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        return Array(set as! Set<IOHIDDevice>)
    }

    private func connect(from devices: [IOHIDDevice]) {
        guard inputDevice == nil else { return }
        guard !devices.isEmpty else {
            state = .failed("No MonsGeek/Akko HID collections with vendor 3151 found")
            log("No matching HID collections. Connect USB-C or the paired 2.4 GHz dongle, then Rescan.")
            return
        }

        let grouped = Dictionary(grouping: devices) { device in
            DeviceGroup(
                productID: propertyInt(device, kIOHIDProductIDKey) ?? -1,
                locationID: propertyInt(device, kIOHIDLocationIDKey) ?? -1
            )
        }
        let groups = grouped.keys.sorted { lhs, rhs in
            let leftRank = Self.preferredProducts.firstIndex(of: lhs.productID) ?? Int.max
            let rightRank = Self.preferredProducts.firstIndex(of: rhs.productID) ?? Int.max
            return (leftRank, lhs.productID, lhs.locationID) < (rightRank, rhs.productID, rhs.locationID)
        }

        var lastFailure: String?
        for group in groups {
            guard let candidates = grouped[group] else { continue }
            guard let config = candidates.first(where: {
                propertyInt($0, kIOHIDPrimaryUsagePageKey) == 0xFFFF &&
                propertyInt($0, kIOHIDPrimaryUsageKey) == 0x02
            }) else {
                log("3151:\(String(format: "%04X", group.productID)) has no FFFF/0002 config collection")
                continue
            }

            let inputs = candidates
                .filter { !CFEqual($0, config) }
                .sorted { inputScore($0) > inputScore($1) }
            guard !inputs.isEmpty else {
                log("Config collection found, but no separate input collection exists")
                continue
            }

            let configResult = IOHIDDeviceOpen(config, IOOptionBits(kIOHIDOptionsTypeNone))
            guard configResult == kIOReturnSuccess else {
                lastFailure = "config open failed: \(Self.ioResult(configResult))"
                log(lastFailure!)
                continue
            }

            for input in inputs {
                let page = propertyInt(input, kIOHIDPrimaryUsagePageKey) ?? 0
                let usage = propertyInt(input, kIOHIDPrimaryUsageKey) ?? 0
                let ids = inputReportIDs(input).map { String(format: "%02X", $0) }.joined(separator: ",")
                log("Trying input page/usage \(String(format: "%04X/%04X", page, usage)), report IDs [\(ids)]")

                let inputResult = IOHIDDeviceOpen(input, IOOptionBits(kIOHIDOptionsTypeNone))
                guard inputResult == kIOReturnSuccess else {
                    lastFailure = "input open failed: \(Self.ioResult(inputResult))"
                    log(lastFailure!)
                    continue
                }

                configDevice = config
                inputDevice = input
                inputBuffer.initialize(repeating: 0, count: 256)
                IOHIDDeviceRegisterInputReportCallback(
                    input, inputBuffer, 256, Self.inputReport,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                IOHIDDeviceScheduleWithRunLoop(input, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

                guard sendMonitoring(enabled: true) else {
                    lastFailure = "depth enable feature report failed"
                    IOHIDDeviceUnscheduleFromRunLoop(
                        input, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
                    )
                    IOHIDDeviceClose(input, IOOptionBits(kIOHIDOptionsTypeNone))
                    inputDevice = nil
                    continue
                }

                lastEventAt = Date()
                reenableSentDuringIdle = false
                let product = propertyString(config, kIOHIDProductKey) ?? "MonsGeek/Akko HE"
                state = .connected("\(product) [3151:\(String(format: "%04x", group.productID))]")
                refreshDiagnostics(devices, config: config, input: input)
                log("Depth monitoring enabled; waiting for report ID 05 / event 1B")
                return
            }
            IOHIDDeviceClose(config, IOOptionBits(kIOHIDOptionsTypeNone))
            configDevice = nil
        }

        if let lastFailure {
            state = .failed("Keyboard found, but \(lastFailure)")
        } else {
            state = .failed("No compatible config/input collection pair found")
        }
    }

    private func disconnect(sendDisable: Bool) {
        neutralizeVirtualGamepad()
        if sendDisable, configDevice != nil { _ = sendMonitoring(enabled: false) }
        if let inputDevice {
            IOHIDDeviceUnscheduleFromRunLoop(inputDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let result = IOHIDDeviceClose(inputDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess { log("Input close failed: \(Self.ioResult(result))") }
        }
        if let configDevice {
            let result = IOHIDDeviceClose(configDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess { log("Config close failed: \(Self.ioResult(result))") }
        }
        inputDevice = nil
        configDevice = nil
    }

    private func sendMonitoring(enabled: Bool) -> Bool {
        guard let configDevice else { return false }
        let payload = DepthFeatureReport.monitoring(enabled: enabled)
        let result = payload.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                configDevice,
                kIOHIDReportTypeFeature,
                0,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                payload.count
            )
        }
        let verb = enabled ? "enable" : "disable"
        if result == kIOReturnSuccess {
            log("Feature \(verb) sent: reportID=00 length=64 bytes=\(Self.hex(payload.prefix(9)))")
            return true
        }
        log("Feature \(verb) failed: \(Self.ioResult(result)); reportID=00 length=64 bytes=\(Self.hex(payload.prefix(9)))")
        return false
    }

    private func serviceIdleDevice() {
        guard state.isConnected else { return }
        if Date().timeIntervalSince(lastEventAt) > 3, !reenableSentDuringIdle {
            log("No depth events for 3 seconds; re-sending enable once")
            _ = sendMonitoring(enabled: true)
            reenableSentDuringIdle = true
        }
    }

    private func receive(reportID: UInt32, bytes: [UInt8]) {
        rawReportCount += 1
        lastReportHex = "ID \(String(format: "%02X", reportID)) · \(Self.hex(bytes.prefix(24)))"
        guard let event = DepthReportDecoder.decode(reportID: reportID, bytes: bytes) else { return }

        var nextDepths = depths
        nextDepths[event.keyIndex] = event.depth
        depths = nextDepths

        if event.depth > maxima[event.keyIndex, default: 0] {
            var nextMaxima = maxima
            nextMaxima[event.keyIndex] = event.depth
            maxima = nextMaxima
        }

        eventCount += 1
        lastKeyIndex = event.keyIndex
        sendVirtualGamepadReport()
        lastEventAt = Date()
        reenableSentDuringIdle = false
    }

    private func handleInputError(_ result: IOReturn) {
        log("Input report callback failed: \(Self.ioResult(result))")
    }

    private func sendVirtualGamepadReport() {
        guard virtualGamepad.isActive else { return }
        let configuredDepths = Dictionary(
            uniqueKeysWithValues: monitoredKeys.map { ($0.index, $0.fullPressDepth) }
        )
        let report = VirtualGamepadReport.wasd(
            depths: depths,
            fullPressDepths: configuredDepths
        )
        let result = virtualGamepad.send(report)
        if result != kIOReturnSuccess {
            let message = "Virtual gamepad report failed: \(Self.ioResult(result))"
            stopKeyboardSuppression()
            virtualGamepad.stop()
            virtualGamepadState = .failed(message)
            log(message)
        }
    }

    private func neutralizeVirtualGamepad() {
        guard virtualGamepad.isActive else { return }
        _ = virtualGamepad.send(
            VirtualGamepadReport(leftX: 0, leftY: 0, rightX: 0, rightY: 0, buttons: 0)
        )
    }

    private func handleMatchedDevice() {
        guard let manager, inputDevice == nil else { return }
        let found = devices(in: manager)
        refreshDiagnostics(found)
        connect(from: found)
    }

    private func handleRemovedDevice(_ device: IOHIDDevice) {
        let wasActive = (inputDevice.map { CFEqual($0, device) } ?? false) ||
            (configDevice.map { CFEqual($0, device) } ?? false)
        guard wasActive else {
            if let manager { refreshDiagnostics(devices(in: manager)) }
            return
        }
        log("Active HID collection removed; scanning again")
        disconnect(sendDisable: false)
        state = .searching
        if let manager {
            let found = devices(in: manager)
            refreshDiagnostics(found)
            connect(from: found)
        }
    }

    private func inputScore(_ device: IOHIDDevice) -> Int {
        let page = propertyInt(device, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = propertyInt(device, kIOHIDPrimaryUsageKey) ?? 0
        var score = inputReportIDs(device).contains(Int(DepthReportDecoder.vendorReportID)) ? 100 : 0
        if page == 0xFFFF && usage == 0x01 { score += 50 }
        if page == 0x01 && usage == 0x06 { score += 40 }
        if page & 0xFF00 == 0xFF00 { score += 20 }
        return score
    }

    private func inputReportIDs(_ device: IOHIDDevice) -> [Int] {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return [] }
        let inputTypes: Set<IOHIDElementType> = [
            kIOHIDElementTypeInput_Misc,
            kIOHIDElementTypeInput_Button,
            kIOHIDElementTypeInput_Axis,
            kIOHIDElementTypeInput_ScanCodes
        ]
        return Array(Set(elements.compactMap { element in
            inputTypes.contains(IOHIDElementGetType(element))
                ? Int(IOHIDElementGetReportID(element))
                : nil
        })).sorted()
    }

    private func refreshDiagnostics(
        _ devices: [IOHIDDevice],
        config: IOHIDDevice? = nil,
        input: IOHIDDevice? = nil
    ) {
        collections = devices.map { device in
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
            let role: String?
            if config.map({ CFEqual($0, device) }) == true { role = "CONFIG" }
            else if input.map({ CFEqual($0, device) }) == true { role = "INPUT" }
            else { role = nil }
            return HIDCollectionDiagnostic(
                id: registryID,
                productID: propertyInt(device, kIOHIDProductIDKey) ?? -1,
                product: propertyString(device, kIOHIDProductKey) ?? "Unknown",
                usagePage: propertyInt(device, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: propertyInt(device, kIOHIDPrimaryUsageKey) ?? 0,
                locationID: propertyInt(device, kIOHIDLocationIDKey),
                inputReportIDs: inputReportIDs(device),
                maxInputReportSize: propertyInt(device, kIOHIDMaxInputReportSizeKey),
                maxFeatureReportSize: propertyInt(device, kIOHIDMaxFeatureReportSizeKey),
                role: role
            )
        }.sorted { ($0.productID, $0.usagePage, $0.usage) < ($1.productID, $1.usagePage, $1.usage) }
        log("Found \(collections.count) matching HID collection(s)")
    }

    private func propertyInt(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func propertyString(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func log(_ message: String) {
        print("[KeyDepthMonitor] \(message)")
        var next = diagnosticMessages
        next.append(message)
        diagnosticMessages = Array(next.suffix(20))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func ioResult(_ result: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, result, _, _ in
        guard result == kIOReturnSuccess, let context else { return }
        Unmanaged<KeyboardDepthMonitor>.fromOpaque(context).takeUnretainedValue().handleMatchedDevice()
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<KeyboardDepthMonitor>.fromOpaque(context).takeUnretainedValue().handleRemovedDevice(device)
    }

    private static let inputReport: IOHIDReportCallback = {
        context, result, _, _, reportID, report, reportLength in
        guard let context else { return }
        let monitor = Unmanaged<KeyboardDepthMonitor>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess else {
            monitor.handleInputError(result)
            return
        }
        guard reportLength > 0 else { return }
        monitor.receive(
            reportID: reportID,
            bytes: Array(UnsafeBufferPointer(start: report, count: reportLength))
        )
    }
}

private struct DeviceGroup: Hashable {
    let productID: Int
    let locationID: Int
}
