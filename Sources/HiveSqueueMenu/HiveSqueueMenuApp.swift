import AppKit
import SwiftUI

@main
struct HiveSqueueMenuApp: App {
    @StateObject private var settingsStore = UserSettings()
    @StateObject private var monitor = SlurmMonitor()

    var body: some Scene {
        MenuBarExtra {
            SlurmMenuView(monitor: monitor)
        } label: {
            Label {
                Text(monitor.menuTitle)
            } icon: {
                Image(systemName: monitor.error == nil ? "chart.bar.fill" : "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settingsStore, monitor: monitor)
        }
    }

    init() {
        print("[App] Initializing HiveSqueueMenuApp...")
        NSApplication.shared.setActivationPolicy(.accessory)
        print("[App] Initialization complete")
    }
}
