import Foundation

enum ConnectionFailureKind: Equatable, Sendable {
    case notConfigured
    case sshAuthenticationFailed
    case remoteCommandMissing
    case invalidResponse
    case transportFailure
}

struct ConnectionFailure: Error, LocalizedError, Sendable {
    let kind: ConnectionFailureKind
    let message: String
    let stdout: String
    let stderr: String

    var errorDescription: String? {
        message
    }
}

struct ConnectionDiagnostic: Sendable {
    let kind: ConnectionFailureKind?
    let summary: String
    let stdout: String
    let stderr: String
    let jobCount: Int?

    var isSuccess: Bool {
        kind == nil
    }
}

struct SlurmQueueSnapshot: Sendable {
    let jobs: [SlurmJob]
    let runningCount: Int
    let pendingCount: Int
    let otherCount: Int

    var totalCount: Int {
        runningCount + pendingCount + otherCount
    }
}

struct RemoteJobState: Sendable {
    let jobSelector: String
    let state: JobState

    var baseSelector: String {
        if let underscore = jobSelector.firstIndex(of: "_") {
            return String(jobSelector[..<underscore])
        }
        return jobSelector
    }

    var countsAsRunning: Bool {
        switch state {
        case .running, .configuring, .completing:
            return true
        default:
            return false
        }
    }
}

struct SlurmService {
    let connection: ConnectionSettings
    let cancellationToken: SSHCancellationToken?

    init(connection: ConnectionSettings, cancellationToken: SSHCancellationToken? = nil) {
        self.connection = connection
        self.cancellationToken = cancellationToken
    }

    func fetchJobs() throws -> [SlurmJob] {
        try fetchSnapshot().jobs
    }

    func fetchSnapshot(visibleJobLimit: Int = AppConfig.maxVisibleJobs) throws -> SlurmQueueSnapshot {
        if let issue = connection.configurationIssue {
            throw ConnectionFailure(kind: .notConfigured, message: issue, stdout: "", stderr: "")
        }

        if connection.resolvedRemoteCommand == AppConfig.remoteCommand {
            return try fetchOptimizedDefaultSnapshot(visibleJobLimit: visibleJobLimit)
        }

        return try fetchLegacySnapshot(
            using: connection.resolvedRemoteCommand,
            visibleJobLimit: visibleJobLimit
        )
    }

    private func fetchLegacySnapshot(using command: String, visibleJobLimit: Int) throws -> SlurmQueueSnapshot {
        try throwIfCancelled()
        let result = try sshClient.execute(command)
        guard result.succeeded else {
            throw Self.classifyFailure(from: result)
        }

        let jobs = try Self.parseJobs(from: result.stdout, stderr: result.stderrText)
        return SlurmQueueSnapshot(
            jobs: Array(jobs.prefix(max(visibleJobLimit, 0))),
            runningCount: jobs.filter { $0.displayState == .running }.count,
            pendingCount: jobs.filter { $0.displayState == .pending }.count,
            otherCount: jobs.filter { !($0.displayState == .running || $0.displayState == .pending) }.count
        )
    }

    func diagnoseConnection() -> ConnectionDiagnostic {
        if let issue = connection.configurationIssue {
            return ConnectionDiagnostic(
                kind: .notConfigured,
                summary: issue,
                stdout: "",
                stderr: "",
                jobCount: nil
            )
        }

        do {
            try throwIfCancelled()
            let result = try sshClient.execute(connection.resolvedRemoteCommand)
            guard result.succeeded else {
                let failure = Self.classifyFailure(from: result)
                return ConnectionDiagnostic(
                    kind: failure.kind,
                    summary: failure.message,
                    stdout: failure.stdout,
                    stderr: failure.stderr,
                    jobCount: nil
                )
            }

            let jobs = try Self.parseJobs(from: result.stdout, stderr: result.stderrText)
            return ConnectionDiagnostic(
                kind: nil,
                summary: "Connection succeeded. Decoded \(jobs.count) jobs.",
                stdout: result.stdoutText,
                stderr: result.stderrText,
                jobCount: jobs.count
            )
        } catch let failure as ConnectionFailure {
            return ConnectionDiagnostic(
                kind: failure.kind,
                summary: failure.message,
                stdout: failure.stdout,
                stderr: failure.stderr,
                jobCount: nil
            )
        } catch let error as SSHClientError {
            return ConnectionDiagnostic(
                kind: .transportFailure,
                summary: error.localizedDescription,
                stdout: "",
                stderr: error.localizedDescription,
                jobCount: nil
            )
        } catch {
            let message = error.localizedDescription
            return ConnectionDiagnostic(
                kind: .transportFailure,
                summary: message,
                stdout: "",
                stderr: message,
                jobCount: nil
            )
        }
    }

    static func parseJobs(from data: Data, stderr: String = "") throws -> [SlurmJob] {
        guard !data.isEmpty else {
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "Remote command returned no stdout, so there was no Slurm JSON to decode.",
                stdout: "",
                stderr: stderr
            )
        }

        do {
            let response = try JSONDecoder().decode(SlurmResponse.self, from: data)
            return response.jobs.sorted(by: jobSort)
        } catch {
            let preview = String(String(decoding: data, as: UTF8.self).prefix(500))
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "Remote command ran, but the response was not valid Slurm JSON.",
                stdout: preview,
                stderr: stderr
            )
        }
    }

    static func parseStateRows(from text: String) -> [RemoteJobState] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                let selector = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let stateText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selector.isEmpty, let state = JobState(rawValue: stateText) else { return nil }
                return RemoteJobState(jobSelector: selector, state: state)
            }
    }

    static func parseCompleteStateRows(from text: String) -> [RemoteJobState]? {
        let rows = parseStateRows(from: text)
        let nonemptyLineCount = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return rows.count == nonemptyLineCount ? rows : nil
    }

    static func selectDetailedJobSelectors(from states: [RemoteJobState], limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var selected: [String] = []
        var seen = Set<String>()

        func append(_ selector: String) {
            guard selected.count < limit else { return }
            guard seen.insert(selector).inserted else { return }
            selected.append(selector)
        }

        for state in states where state.countsAsRunning {
            append(state.jobSelector)
        }

        for state in states where state.state == .pending {
            append(state.baseSelector)
        }

        for state in states where !state.countsAsRunning && state.state != .pending {
            append(state.jobSelector)
        }

        return selected
    }

    static func classifyFailure(from result: SSHCommandResult) -> ConnectionFailure {
        let stderr = result.stderrText
        let stdout = result.stdoutText
        let combined = (stderr + "\n" + stdout).lowercased()

        if result.timedOut {
            return ConnectionFailure(
                kind: .transportFailure,
                message: "SSH command timed out after \(Int(AppConfig.sshCommandTimeout))s.",
                stdout: stdout,
                stderr: stderr
            )
        }

        if combined.contains("permission denied")
            || combined.contains("authentication failed")
            || combined.contains("too many authentication failures") {
            return ConnectionFailure(
                kind: .sshAuthenticationFailed,
                message: "SSH authentication failed. Verify the selected auth mode, key, password, or agent.",
                stdout: stdout,
                stderr: stderr
            )
        }

        if combined.contains("command not found")
            || combined.contains("no such file or directory")
            || combined.contains("unable to locate")
            || combined.contains("not a valid command")
            || combined.contains("invalid option")
            || combined.contains("module command not found") {
            return ConnectionFailure(
                kind: .remoteCommandMissing,
                message: "The remote Slurm command could not be executed. Check the command override and module setup.",
                stdout: stdout,
                stderr: stderr
            )
        }

        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "SSH command failed with exit code \(result.terminationStatus)."
            : "SSH command failed before valid Slurm JSON was returned."

        return ConnectionFailure(
            kind: .transportFailure,
            message: message,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func jobSort(lhs: SlurmJob, rhs: SlurmJob) -> Bool {
        let lhsPriority = lhs.displayState.priority
        let rhsPriority = rhs.displayState.priority
        if lhsPriority == rhsPriority {
            return lhs.id < rhs.id
        }
        return lhsPriority < rhsPriority
    }

    private func fetchOptimizedDefaultSnapshot(visibleJobLimit: Int) throws -> SlurmQueueSnapshot {
        try throwIfCancelled()
        let stateResult = try sshClient.execute(Self.optimizedStateCommand)
        if !stateResult.succeeded {
            let failure = Self.classifyFailure(from: stateResult)
            if failure.kind == .remoteCommandMissing {
                return try fetchLegacySnapshot(
                    using: connection.resolvedRemoteCommand,
                    visibleJobLimit: visibleJobLimit
                )
            }
            throw failure
        }

        guard let states = Self.parseCompleteStateRows(from: stateResult.stdoutText) else {
            return try fetchLegacySnapshot(
                using: connection.resolvedRemoteCommand,
                visibleJobLimit: visibleJobLimit
            )
        }
        let runningCount = states.filter(\.countsAsRunning).count
        let pendingCount = states.filter { $0.state == .pending }.count
        let otherCount = max(states.count - runningCount - pendingCount, 0)

        let selectors = Self.selectDetailedJobSelectors(from: states, limit: visibleJobLimit)
        guard !selectors.isEmpty else {
            return SlurmQueueSnapshot(
                jobs: [],
                runningCount: runningCount,
                pendingCount: pendingCount,
                otherCount: otherCount
            )
        }

        try throwIfCancelled()
        let detailResult = try sshClient.execute(
            Self.optimizedDetailCommand(for: selectors)
        )
        guard detailResult.succeeded else {
            throw Self.classifyFailure(from: detailResult)
        }

        let jobs = try Self.parseJobs(from: detailResult.stdout, stderr: detailResult.stderrText)
        return SlurmQueueSnapshot(
            jobs: Array(jobs.prefix(max(visibleJobLimit, 0))),
            runningCount: runningCount,
            pendingCount: pendingCount,
            otherCount: otherCount
        )
    }

    private static let optimizedStateCommand =
        "export SLURM_BITSTR_LEN=0; squeue --me --array --noheader --format='%i|%T'"

    private static func optimizedDetailCommand(for selectors: [String]) -> String {
        let joinedSelectors = selectors.joined(separator: ",")
        return "export SLURM_JSON=compact; squeue --me --json --jobs=\(shellSingleQuoted(joinedSelectors))"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var sshClient: SSHClient {
        SSHClient(connection: connection, cancellationToken: cancellationToken)
    }

    private func throwIfCancelled() throws {
        if cancellationToken?.isCancelled == true {
            throw CancellationError()
        }
    }
}

private extension JobState {
    var priority: Int {
        switch self {
        case .running:
            return 0
        case .pending:
            return 1
        case .completing, .configuring:
            return 2
        case .completed:
            return 3
        case .cancelled, .suspended:
            return 4
        case .failed:
            return 5
        case .unknown:
            return 6
        }
    }
}
