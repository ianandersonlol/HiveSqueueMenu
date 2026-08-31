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

enum SlurmMonitorState: Equatable {
    case idle
    case loading(previousSnapshotAvailable: Bool)
    case loaded
    case failed(issue: MonitorIssue, previousSnapshotAvailable: Bool)
}

@MainActor
final class SlurmMonitor: ObservableObject {
    typealias SnapshotFetcher = @Sendable (ConnectionSettings, SSHCancellationToken) async throws -> SlurmQueueSnapshot

    @Published var jobs: [SlurmJob] = []
    @Published private(set) var state: SlurmMonitorState
    @Published private(set) var host: String
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var lastSuccessfulFetchDate: Date?
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var runningJobCount: Int = 0
    @Published private(set) var pendingJobCount: Int = 0
    @Published private(set) var otherJobCount: Int = 0

    var runningJobs: [SlurmJob] {
        jobs.filter { $0.displayState.queueBucket == .running }
    }

    var issue: MonitorIssue? {
        guard case .failed(let issue, _) = state else { return nil }
        return issue
    }

    var isFetching: Bool {
        guard case .loading = state else { return false }
        return true
    }

    var pendingJobs: [SlurmJob] {
        jobs.filter { $0.displayState.queueBucket == .pending }
    }

    var totalJobCount: Int {
        QueueCounts.saturatingAdd(
            QueueCounts.saturatingAdd(runningJobCount, pendingJobCount),
            otherJobCount
        )
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

    var accessibilityStatus: String {
        switch state {
        case .idle:
            return "No queue data loaded."
        case .loading:
            let counts = "\(runningJobCount) running, \(pendingJobCount) pending, \(otherJobCount) other."
            return "Refreshing queue. \(counts)"
        case .loaded:
            return "\(runningJobCount) running, \(pendingJobCount) pending, \(otherJobCount) other."
        case .failed(let issue, _):
            return "\(issue.title). \(issue.message)"
        }
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
        if let configurationIssue = connection.configurationIssue {
            self.state = .failed(
                issue: MonitorIssue(kind: .notConfigured, message: configurationIssue),
                previousSnapshotAvailable: false
            )
        } else {
            self.state = .idle
        }
    }

    func fetch(force: Bool = false) {
        if let configurationIssue = connection.configurationIssue {
            state = .failed(
                issue: MonitorIssue(kind: .notConfigured, message: configurationIssue),
                previousSnapshotAvailable: lastSuccessfulFetchDate != nil
            )
            return
        }

        if isThrottled {
            if force {
                isThrottled = false
                consecutiveFailures = 0
            } else {
                state = .failed(
                    issue: MonitorIssue(
                        kind: .throttled,
                        message: "Refresh is paused after repeated failures. Use Retry after fixing settings, or test the connection in Preferences."
                    ),
                    previousSnapshotAvailable: lastSuccessfulFetchDate != nil
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
        state = .loading(previousSnapshotAvailable: lastSuccessfulFetchDate != nil)

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
                state = .loaded
                consecutiveFailures = 0
            } catch {
                guard !Task.isCancelled, generation == fetchGeneration else { return }
                consecutiveFailures += 1
                let fetchIssue: MonitorIssue

                if consecutiveFailures >= maxConsecutiveFailures {
                    isThrottled = true
                    fetchIssue = MonitorIssue(
                        kind: .throttled,
                        message: "Refresh is paused after \(consecutiveFailures) failures. Fix the connection settings, then use Retry or Test Connection."
                    )
                } else {
                    fetchIssue = monitorIssue(for: error)
                }

                state = .failed(
                    issue: fetchIssue,
                    previousSnapshotAvailable: lastSuccessfulFetchDate != nil
                )
            }

            let finished = Date()
            latestFetchDate = finished
            lastFetchDate = finished
            if issue == nil {
                lastSuccessfulFetchDate = finished
            }
            fetchInFlight = false
            fetchTask = nil
            fetchCancellationToken = nil
        }
    }

    func updateConnection(_ newConnection: ConnectionSettings) {
        guard newConnection != connection else { return }

        fetchTask?.cancel()
        fetchCancellationToken?.cancel()
        fetchTask = nil
        fetchCancellationToken = nil
        fetchGeneration &+= 1
        connection = newConnection
        host = newConnection.host.isEmpty ? "Not configured" : newConnection.host
        isConfigured = newConnection.isConfigured
        latestFetchDate = nil
        fetchInFlight = false
        jobs = []
        runningJobCount = 0
        pendingJobCount = 0
        otherJobCount = 0
        lastFetchDate = nil
        lastSuccessfulFetchDate = nil
        if let configurationIssue = newConnection.configurationIssue {
            state = .failed(
                issue: MonitorIssue(kind: .notConfigured, message: configurationIssue),
                previousSnapshotAvailable: false
            )
        } else {
            state = .idle
        }
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
