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
    @Published private(set) var isConfigured: Bool = false

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
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5
    private var isThrottled = false

    init(
        connection: ConnectionSettings = .empty,
        sshPath: String = AppConfig.sshPath,
        remoteCommand: String = AppConfig.remoteCommand,
        refreshCooldown: TimeInterval = AppConfig.manualRefreshCooldown
    ) {
        self.connection = connection
        self.sshPath = sshPath
        self.remoteCommand = remoteCommand
        self.refreshCooldown = refreshCooldown
        self.host = connection.host.isEmpty ? "Not configured" : connection.host
        self.isConfigured = connection.isConfigured
        if connection.isConfigured {
            print("[SlurmMonitor] Initialized with connection: \(connection.username)@\(connection.host)")
        } else {
            print("[SlurmMonitor] Initialized without valid connection - waiting for user configuration")
        }
    }

    func fetch(force: Bool = false) {
        print("[SlurmMonitor] fetch called - force: \(force), fetchInFlight: \(fetchInFlight), consecutiveFailures: \(consecutiveFailures), throttled: \(isThrottled)")
        Task {
            if !connection.isConfigured {
                print("[SlurmMonitor] Connection not configured, skipping fetch")
                error = "Please configure your credentials in Preferences"
                return
            }

            if isThrottled {
                print("[SlurmMonitor] THROTTLED - Too many consecutive failures (\(consecutiveFailures)). Please check your credentials and try again later.")
                error = "Connection throttled after \(consecutiveFailures) failures. Please verify your credentials in Preferences and wait before retrying."
                return
            }

            if fetchInFlight {
                print("[SlurmMonitor] Fetch already in flight, skipping")
                return
            }

            let now = Date()
            // ALWAYS enforce minimum cooldown, even with force=true (anti-spam protection)
            if let last = latestFetchDate {
                let minCooldown: TimeInterval = force ? 5.0 : refreshCooldown
                let elapsed = now.timeIntervalSince(last)
                if elapsed < minCooldown {
                    let remaining = minCooldown - elapsed
                    print("[SlurmMonitor] Anti-spam cooldown active, \(remaining)s remaining (force=\(force))")
                    return
                }
            }

            fetchInFlight = true
            isFetching = true
            print("[SlurmMonitor] Starting fetch - connection: \(connection.username)@\(connection.host)")

            do {
                let service = SlurmService(connection: connection)
                print("[SlurmMonitor] Created SlurmService, starting detached task...")
                // Run blocking SSH operation on background thread
                let jobs = try await Task.detached(priority: .utility) {
                    print("[SlurmMonitor] Inside detached task, calling fetchJobs()...")
                    let result = try service.fetchJobs()
                    print("[SlurmMonitor] fetchJobs() returned \(result.count) jobs")
                    return result
                }.value
                print("[SlurmMonitor] Detached task completed successfully")
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.jobs = jobs
                }
                self.error = nil
                // Reset failure counter on success
                consecutiveFailures = 0
                print("[SlurmMonitor] Updated UI with jobs - failure counter reset")
            } catch {
                consecutiveFailures += 1
                let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[SlurmMonitor] Fetch failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(errorMsg)")

                if consecutiveFailures >= maxConsecutiveFailures {
                    isThrottled = true
                    self.error = "Connection failed \(consecutiveFailures) times. Automatic retries disabled. Please check your credentials and manually retry."
                    print("[SlurmMonitor] THROTTLE ACTIVATED - Too many failures")
                } else {
                    self.error = errorMsg + " (Attempt \(consecutiveFailures)/\(maxConsecutiveFailures))"
                }
            }

            let finished = Date()
            latestFetchDate = finished
            lastFetchDate = finished
            isFetching = false
            fetchInFlight = false
            print("[SlurmMonitor] Fetch complete")
        }
    }

    func updateConnection(_ newConnection: ConnectionSettings) {
        let wasConfigured = isConfigured
        if newConnection.isConfigured {
            print("[SlurmMonitor] updateConnection called: \(newConnection.username)@\(newConnection.host)")
        } else {
            print("[SlurmMonitor] updateConnection called with incomplete settings - not connecting")
        }
        connection = newConnection
        isConfigured = newConnection.isConfigured
        latestFetchDate = nil
        fetchInFlight = false
        host = newConnection.host.isEmpty ? "Not configured" : newConnection.host
        jobs = []
        lastFetchDate = nil
        error = newConnection.isConfigured ? nil : "Please configure your credentials in Preferences"
        isFetching = false
        // Reset throttle and failure counter when connection settings change
        consecutiveFailures = 0
        isThrottled = false
        print("[SlurmMonitor] Throttle and failure counter reset")

        // Auto-fetch when connection becomes valid
        if newConnection.isConfigured && !wasConfigured {
            print("[SlurmMonitor] Connection now valid - auto-triggering fetch")
            fetch(force: false)
        }
    }

    func timeUntilNextAllowedRefresh(from date: Date = Date()) -> TimeInterval? {
        guard let lastFetchDate else { return nil }
        let remaining = refreshCooldown - date.timeIntervalSince(lastFetchDate)
        return remaining > 0 ? remaining : nil
    }
}
