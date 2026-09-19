import SwiftUI

struct MonitoringSettingsView: View {
    @EnvironmentObject private var monitor: KeyboardDepthMonitor

    @State private var editingIndex: Int?
    @State private var keyIndex = 0
    @State private var keyName = ""
    @State private var fullPressDepth = 720
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Monitored Keys")
                .font(.title2.weight(.semibold))

            Text("Depth events are received for every key. This list controls which keys appear in the main monitor.")
                .foregroundStyle(.secondary)

            Toggle(
                "Also show detected keys that are not in the list",
                isOn: Binding(
                    get: { monitor.showUnconfiguredKeys },
                    set: { monitor.setShowUnconfiguredKeys($0) }
                )
            )

            GroupBox("Original Keyboard Input") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(
                        "Block W/A/S/D in",
                        selection: Binding(
                            get: { monitor.keyboardSuppressionScope },
                            set: { monitor.setKeyboardSuppressionScope($0) }
                        )
                    ) {
                        ForEach(KeyboardSuppressionScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        monitor.keyboardSuppressionScope == .geForceNow
                            ? "Recommended. Other applications continue receiving W/A/S/D normally."
                            : "Use with caution: W/A/S/D are blocked in every application until key blocking or the virtual gamepad is turned off."
                    )
                    .font(.caption)
                    .foregroundStyle(
                        monitor.keyboardSuppressionScope == .geForceNow ? Color.secondary : Color.orange
                    )
                }
                .padding(8)
            }

            keyList
            editor

            HStack {
                Button("Restore Defaults") {
                    monitor.resetMonitoredKeys()
                    clearEditor()
                }
                Spacer()
                Text("Settings are saved automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 600, height: 600)
    }

    private var keyList: some View {
        List {
            if monitor.monitoredKeys.isEmpty {
                Text("No keys configured. Press a key and use “Last detected”, or enter its HID index manually.")
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.monitoredKeys) { key in
                HStack(spacing: 12) {
                    Text(key.label)
                        .fontWeight(.medium)
                        .frame(minWidth: 100, alignment: .leading)
                    Text("Index \(key.index)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Full press \(key.fullPressDepth)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        edit(key)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit \(key.label)")
                    Button(role: .destructive) {
                        monitor.removeMonitoredKey(index: key.index)
                        if editingIndex == key.index { clearEditor() }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(key.label)")
                }
                .padding(.vertical, 3)
            }
        }
        .frame(minHeight: 220)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var editor: some View {
        GroupBox(editingIndex == nil ? "Add Key" : "Edit Key") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Name", text: $keyName)
                        .frame(minWidth: 160)
                    TextField("HID index", value: $keyIndex, format: .number)
                        .frame(width: 100)
                    TextField("Full press", value: $fullPressDepth, format: .number)
                        .frame(width: 110)
                }

                HStack {
                    if let last = monitor.lastKeyIndex {
                        Button("Use Last Detected (\(last))") {
                            keyIndex = last
                            if keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                keyName = "Key \(last)"
                            }
                            validationMessage = nil
                        }
                    } else {
                        Text("Press a key on the connected keyboard to discover its index.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    if editingIndex != nil {
                        Button("Cancel") { clearEditor() }
                    }
                    Button(editingIndex == nil ? "Add" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }

    private func edit(_ key: MonitoredKey) {
        editingIndex = key.index
        keyIndex = key.index
        keyName = key.label
        fullPressDepth = key.fullPressDepth
        validationMessage = nil
    }

    private func save() {
        validationMessage = monitor.saveMonitoredKey(
            originalIndex: editingIndex,
            index: keyIndex,
            label: keyName,
            fullPressDepth: fullPressDepth
        )
        if validationMessage == nil { clearEditor() }
    }

    private func clearEditor() {
        editingIndex = nil
        keyIndex = monitor.lastKeyIndex ?? 0
        keyName = ""
        fullPressDepth = 720
        validationMessage = nil
    }
}
