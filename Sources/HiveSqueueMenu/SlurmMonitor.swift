import Foundation
import SwiftUI

struct MonitorIssue: Equatable {
    enum Kind: Equatable {
        case notConfigured
        case sshAuthenticationFailed
        case remoteCommandMissing
        case invalidResponse
        case transportFailure
        case throttled
    }

    let kind: Kind
    let message: String

    var title: String {
        switch kind {
        case .notConfigured:
            return "Setup Required"
        case .sshAuthenticationFailed:
            return "SSH Authentication Failed"
        case .remoteCommandMissing:
            return "Remote Command Failed"
        case .invalidResponse:
            return "Unexpected Slurm Output"
        case .transportFailure:
            return "Connection Failed"
        case .throttled:
            return "Refresh Paused"
        }
    }
}

@MainActor
final class SlurmMonitor: ObservableObject {
    typealias SnapshotFetcher = @Sendable (ConnectionSettings, SSHCancellationToken) async throws -> SlurmQueueSnapshot

    @Published var jobs: [SlurmJob] = []
    @Published var issue: MonitorIssue?
    @Published private(set) var host: String
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var lastSuccessfulFetchDate: Date?
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var runningJobCount: Int = 0
    @Published private(set) var pendingJobCount: Int = 0
    @Published private(set) var otherJobCount: Int = 0

    var runningJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .running }
    }

    var pendingJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .pending }
    }

    var totalJobCount: Int {
        runningJobCount + pendingJobCount + otherJobCount
    }

    var menuTitle: String {
        let prefix = "H"

        if isFetching && lastSuccessfulFetchDate == nil {
            return "\(prefix) …"
        }

        if let issue {
            return issue.kind == .notConfigured ? "\(prefix) --" : "\(prefix) !"
        }

        return "\(prefix) \(Self.abbreviatedJobCount(totalJobCount))"
    }

    private var connection: ConnectionSettings
    private let refreshCooldown: TimeInterval
    private var fetchInFlight = false
    private var latestFetchDate: Date?
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5
    private var isThrottled = false
    private let snapshotFetcher: SnapshotFetcher
    private var fetchTask: Task<Void, Never>?
    private var fetchCancellationToken: SSHCancellationToken?
    private var fetchGeneration: UInt = 0

    init(
        connection: ConnectionSettings = .empty,
        refreshCooldown: TimeInterval = AppConfig.manualRefreshCooldown,
        snapshotFetcher: SnapshotFetcher? = nil
    ) {
        self.connection = connection
        self.refreshCooldown = refreshCooldown
        self.snapshotFetcher = snapshotFetcher ?? { connection, cancellationToken in
            try await Task.detached(priority: .utility) {
                try SlurmService(
                    connection: connection,
                    cancellationToken: cancellationToken
                ).fetchSnapshot()
            }.value
        }
        self.host = connection.host.isEmpty ? "Not configured" : connection.host
        self.isConfigured = connection.isConfigured
        self.issue = connection.configurationIssue.map {
            MonitorIssue(kind: .notConfigured, message: $0)
        }
    }

    func fetch(force: Bool = false) {
        if let configurationIssue = connection.configurationIssue {
            issue = MonitorIssue(kind: .notConfigured, message: configurationIssue)
            return
        }

        if isThrottled {
            if force {
                isThrottled = false
                consecutiveFailures = 0
            } else {
                issue = MonitorIssue(
                    kind: .throttled,
                    message: "Refresh is paused after repeated failures. Use Retry after fixing settings, or test the connection in Preferences."
                )
                return
            }
        }

        if fetchInFlight {
            return
        }

        if !force {
            let now = Date()
            if let last = latestFetchDate {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < refreshCooldown {
                    return
                }
            }
        }

        fetchGeneration &+= 1
        let generation = fetchGeneration
        let connectionAtStart = connection
        let cancellationToken = SSHCancellationToken()
        fetchCancellationToken = cancellationToken
        fetchInFlight = true
        isFetching = true

        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await snapshotFetcher(connectionAtStart, cancellationToken)
                guard !Task.isCancelled, generation == fetchGeneration else { return }

                withAnimation(.easeInOut(duration: 0.2)) {
                    self.jobs = snapshot.jobs
                }
                runningJobCount = snapshot.runningCount
                pendingJobCount = snapshot.pendingCount
                otherJobCount = snapshot.otherCount
                issue = nil
                consecutiveFailures = 0
            } catch {
                guard !Task.isCancelled, generation == fetchGeneration else { return }
                consecutiveFailures += 1
                issue = monitorIssue(for: error)

                if consecutiveFailures >= maxConsecutiveFailures {
                    isThrottled = true
                    issue = MonitorIssue(
                        kind: .throttled,
                        message: "Refresh is paused after \(consecutiveFailures) failures. Fix the connection settings, then use Retry or Test Connection."
                    )
                }
            }

            let finished = Date()
            latestFetchDate = finished
            lastFetchDate = finished
            if issue == nil {
                lastSuccessfulFetchDate = finished
            }
            isFetching = false
            fetchInFlight = false
            fetchTask = nil
            fetchCancellationToken = nil
        }
    }

    func updateConnection(_ newConnection: ConnectionSettings) {
        host = newConnection.host.isEmpty ? "Not configured" : newConnection.host
        let isNewConfiguration = newConnection != connection
        isConfigured = newConnection.isConfigured

        guard isNewConfiguration else {
            issue = newConnection.configurationIssue.map {
                MonitorIssue(kind: .notConfigured, message: $0)
            }
            return
        }

        fetchTask?.cancel()
        fetchCancellationToken?.cancel()
        fetchTask = nil
        fetchCancellationToken = nil
        fetchGeneration &+= 1
        connection = newConnection
        latestFetchDate = nil
        fetchInFlight = false
        jobs = []
        runningJobCount = 0
        pendingJobCount = 0
        otherJobCount = 0
        lastFetchDate = nil
        lastSuccessfulFetchDate = nil
        issue = newConnection.configurationIssue.map {
            MonitorIssue(kind: .notConfigured, message: $0)
        }
        isFetching = false
        consecutiveFailures = 0
        isThrottled = false
    }

    func timeUntilNextAllowedRefresh(from date: Date = Date()) -> TimeInterval? {
        guard let lastFetchDate else { return nil }
        let remaining = refreshCooldown - date.timeIntervalSince(lastFetchDate)
        return remaining > 0 ? remaining : nil
    }

    private func monitorIssue(for error: Error) -> MonitorIssue {
        if let failure = error as? ConnectionFailure {
            switch failure.kind {
            case .notConfigured:
                return MonitorIssue(kind: .notConfigured, message: failure.message)
            case .sshAuthenticationFailed:
                return MonitorIssue(kind: .sshAuthenticationFailed, message: failure.message)
            case .remoteCommandMissing:
                return MonitorIssue(kind: .remoteCommandMissing, message: failure.message)
            case .invalidResponse:
                return MonitorIssue(kind: .invalidResponse, message: failure.message)
            case .transportFailure:
                return MonitorIssue(kind: .transportFailure, message: failure.message)
            }
        }

        if let sshError = error as? SSHClientError {
            return MonitorIssue(kind: .transportFailure, message: sshError.localizedDescription)
        }

        return MonitorIssue(kind: .transportFailure, message: error.localizedDescription)
    }

    nonisolated static func abbreviatedJobCount(_ count: Int) -> String {
        switch count {
        case ..<100:
            return "\(count)"
        case 100..<1_000:
            return "100+"
        case 1_000..<10_000:
            return "1K+"
        case 10_000..<100_000:
            return "10K+"
        case 100_000..<1_000_000:
            return "100K+"
        case 1_000_000..<10_000_000:
            return "1M+"
        case 10_000_000..<100_000_000:
            return "10M+"
        default:
            return "100M+"
        }
    }
}
