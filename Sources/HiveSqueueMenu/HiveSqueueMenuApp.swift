import AppKit
import SwiftUI

@main
struct HiveSqueueMenuApp: App {
    @StateObject private var appModel: HiveSqueueAppModel

    init() {
        _appModel = StateObject(wrappedValue: HiveSqueueAppModel())
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            SlurmMenuView(monitor: appModel.monitor)
        } label: {
            MenuBarStatusLabel(monitor: appModel.monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appModel.settingsStore)
        }
    }
}
