import Combine
import Foundation
import SwiftUI

@MainActor
final class SlurmMonitor: ObservableObject {
    @Published var jobs: [SlurmJob] = []
    @Published var error: String?
    @Published private(set) var host: String
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastFetchDate: Date?

    var runningJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .running }
    }

    var pendingJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .pending }
    }

    var menuTitle: String {
        if error != nil {
            return "Slurm: !"
        }

        let runningCount = runningJobs.count
        let pendingCount = pendingJobs.count
        return "Slurm: \(runningCount)R \(pendingCount)Q"
    }

    private var connection: ConnectionSettings
    private let sshPath: String
    private let remoteCommand: String
    private let refreshCooldown: TimeInterval
    private var fetchInFlight = false
    private var latestFetchDate: Date?

    init(
        connection: ConnectionSettings,
        sshPath: String = AppConfig.sshPath,
        remoteCommand: String = AppConfig.remoteCommand,
        refreshCooldown: TimeInterval = AppConfig.manualRefreshCooldown
    ) {
        self.connection = connection
        self.sshPath = sshPath
        self.remoteCommand = remoteCommand
        self.refreshCooldown = refreshCooldown
        self.host = connection.host
    }

    func fetch(force: Bool = false) {
        Task {
            if fetchInFlight {
                return
            }

            let now = Date()
            if !force, let last = latestFetchDate, now.timeIntervalSince(last) < refreshCooldown {
                return
            }

            fetchInFlight = true
            isFetching = true

            do {
                let service = SlurmService(connection: connection)
                let jobs = try await Task { try service.fetchJobs() }.value
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.jobs = jobs
                }
                self.error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            let finished = Date()
            latestFetchDate = finished
            lastFetchDate = finished
            isFetching = false
            fetchInFlight = false
        }
    }

    func updateConnection(_ newConnection: ConnectionSettings) {
        connection = newConnection
        latestFetchDate = nil
        fetchInFlight = false
        host = newConnection.host
        jobs = []
        lastFetchDate = nil
        error = nil
        isFetching = false
    }

    func timeUntilNextAllowedRefresh(from date: Date = Date()) -> TimeInterval? {
        guard let lastFetchDate else { return nil }
        let remaining = refreshCooldown - date.timeIntervalSince(lastFetchDate)
        return remaining > 0 ? remaining : nil
    }
}
