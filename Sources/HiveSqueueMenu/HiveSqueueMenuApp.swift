import AppKit
import SwiftUI

@main
struct HiveSqueueMenuApp: App {
    @StateObject private var settingsStore: UserSettings
    @StateObject private var monitor: SlurmMonitor

    init() {
        let settings = UserSettings()
        let monitor = SlurmMonitor(connection: settings.connectionSettings)
        _settingsStore = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: monitor)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            SlurmMenuView(monitor: monitor)
                .onAppear {
                    monitor.updateConnection(settingsStore.connectionSettings)
                }
                .onChange(of: settingsStore.connectionSettings) { oldValue, newValue in
                    monitor.updateConnection(newValue)
                }
        } label: {
            HStack(spacing: 4) {
                MenuStatusIcon(
                    runningCount: monitor.runningJobCount,
                    pendingCount: monitor.pendingJobCount,
                    otherCount: monitor.otherJobCount,
                    isFetching: monitor.isFetching,
                    issue: monitor.issue
                )
                Text(monitor.menuTitle)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settingsStore)
        }
    }
}
