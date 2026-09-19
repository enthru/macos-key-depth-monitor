import SwiftUI

@main
struct KeyDepthMonitorApp: App {
    @StateObject private var monitor = KeyboardDepthMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .onAppear {
                    monitor.start()
                    if ProcessInfo.processInfo.environment["KEY_DEPTH_AUTOSTART_GAMEPAD"] == "1",
                       !monitor.virtualGamepadState.isActive {
                        monitor.toggleVirtualGamepad()
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 820, height: 620)

        Settings {
            MonitoringSettingsView()
                .environmentObject(monitor)
        }
    }
}
