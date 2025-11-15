import AppKit
import SwiftUI

@main
struct HiveSqueueMenuApp: App {
    @StateObject private var settingsStore: UserSettings
    @StateObject private var monitor: SlurmMonitor

    init() {
        print("[App] Initializing HiveSqueueMenuApp...")
        let settings = UserSettings()
        _settingsStore = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: SlurmMonitor(connection: settings.connectionSettings))
        NSApplication.shared.setActivationPolicy(.accessory)
        print("[App] Initialization complete")
    }

    var body: some Scene {
        MenuBarExtra {
            SlurmMenuView(monitor: monitor)
                .onAppear {
                    print("[App] Menu appeared - applying initial connection settings")
                    monitor.updateConnection(settingsStore.connectionSettings)
                }
                .onChange(of: settingsStore.connectionSettings) { oldValue, newValue in
                    print("[App] Detected settings change - triggering monitor update (host: \(newValue.host))")
                    monitor.updateConnection(newValue)
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
}
