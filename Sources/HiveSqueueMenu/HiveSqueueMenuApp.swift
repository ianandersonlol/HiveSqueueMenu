import AppKit
import SwiftUI

@main
struct HiveSqueueMenuApp: App {
    @StateObject private var monitor: SlurmMonitor
    @StateObject private var settingsStore: UserSettings

    var body: some Scene {
        MenuBarExtra {
            SlurmMenuView(monitor: monitor)
                .onReceive(settingsStore.$connectionSettings.removeDuplicates()) { newConfig in
                    monitor.updateConnection(newConfig)
                }
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
            SettingsView(settings: settingsStore)
        }
    }

    init() {
        let settings = UserSettings()
        _settingsStore = StateObject(wrappedValue: settings)
        let monitor = SlurmMonitor(connection: settings.connectionSettings)
        _monitor = StateObject(wrappedValue: monitor)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
