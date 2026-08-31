import Combine
import Foundation

@MainActor
final class HiveSqueueAppModel: ObservableObject {
    let settingsStore: UserSettings
    let monitor: SlurmMonitor

    private let connectionSynchronization: MonitorConnectionSynchronization

    init(
        settingsStore: UserSettings? = nil,
        monitor: SlurmMonitor? = nil
    ) {
        let settingsStore = settingsStore ?? UserSettings()
        let monitor = monitor ?? SlurmMonitor(connection: settingsStore.connectionSettings)

        self.settingsStore = settingsStore
        self.monitor = monitor
        self.connectionSynchronization = MonitorConnectionSynchronization(
            monitor: monitor,
            connections: settingsStore.$connectionSettings
        )
    }
}

/// Owns the settings-to-monitor subscription independently of transient menu content.
@MainActor
final class MonitorConnectionSynchronization {
    private var cancellable: AnyCancellable?

    init<Connections: Publisher>(
        monitor: SlurmMonitor,
        connections: Connections
    ) where Connections.Output == ConnectionSettings, Connections.Failure == Never {
        cancellable = connections
            .removeDuplicates()
            .dropFirst()
            .sink { [weak monitor] connection in
                monitor?.updateConnection(connection)
            }
    }
}
