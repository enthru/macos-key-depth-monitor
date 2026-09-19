import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: KeyboardDepthMonitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            keyTable
            Divider()
            diagnostics
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 30))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text("Key Depth Monitor")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.state.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(monitor.state.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            Button {
                monitor.toggleVirtualGamepad()
            } label: {
                Label(
                    monitor.virtualGamepadState.title,
                    systemImage: monitor.virtualGamepadState.isActive ? "gamecontroller.fill" : "gamecontroller"
                )
            }
            .help(virtualGamepadHelp)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            Button("Clear") { monitor.clearValues() }
            Button("Rescan") { monitor.rescan() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(18)
    }

    private var virtualGamepadHelp: String {
        if case .failed(let message) = monitor.virtualGamepadState { return message }
        return "Create a virtual HID gamepad and map W/A/S/D depth to its left stick"
    }

    private var summary: some View {
        HStack(spacing: 12) {
            metric(title: "Depth events", value: "\(monitor.eventCount)")
            metric(title: "Raw reports", value: "\(monitor.rawReportCount)")
            metric(title: "Keys seen", value: "\(monitor.depths.count)")
            VStack(alignment: .leading, spacing: 5) {
                Text("Last raw report")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(monitor.lastReportHex)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var diagnostics: some View {
        DisclosureGroup("HID diagnostics · \(monitor.collections.count) collections") {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 5) {
                    if monitor.collections.isEmpty {
                        Text("No HID collections with vendor ID 3151 are currently visible.")
                    } else {
                        ForEach(monitor.collections) { collection in
                            Text(collection.summary)
                        }
                    }
                    if !monitor.diagnosticMessages.isEmpty {
                        Divider()
                        ForEach(Array(monitor.diagnosticMessages.enumerated()), id: \.offset) { _, message in
                            Text("› \(message)")
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 8)
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
        }
        .padding(12)
        .frame(width: 130, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var keyTable: some View {
        Table(monitor.readings) {
            TableColumn("Key") { reading in
                Text(reading.label).fontWeight(.medium)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Index") { reading in
                Text("\(reading.index)").monospacedDigit()
            }
            .width(70)

            TableColumn("Live depth") { reading in
                HStack(spacing: 10) {
                    ProgressView(value: reading.normalized)
                        .progressViewStyle(.linear)
                    Text("\(reading.depth)")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            TableColumn("Peak") { reading in
                Text("\(reading.observedMaximum)").monospacedDigit()
            }
            .width(70)

            TableColumn("Press") { reading in
                Text(reading.normalized, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
            }
            .width(80)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text("Press keys slowly: released ≈ 0, fully pressed ≈ 700–720")
            Spacer()
            Button {
                monitor.toggleKeyboardSuppression()
            } label: {
                Label(
                    monitor.keyboardSuppressionState.title,
                    systemImage: monitor.keyboardSuppressionState.isActive
                        ? "keyboard.badge.ellipsis.fill"
                        : "keyboard"
                )
            }
            .disabled(!monitor.virtualGamepadState.isActive && !monitor.keyboardSuppressionState.isActive)
            .help(keyboardSuppressionHelp)
            Text("VID 3151 · reports 05/1B")
                .font(.system(.caption, design: .monospaced))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(14)
    }

    private var keyboardSuppressionHelp: String {
        if case .failed(let message) = monitor.keyboardSuppressionState { return message }
        return monitor.keyboardSuppressionScope == .geForceNow
            ? "Block W/A/S/D only while GeForce NOW is the foreground application"
            : "Block W/A/S/D in every application while the virtual gamepad is enabled"
    }
}
