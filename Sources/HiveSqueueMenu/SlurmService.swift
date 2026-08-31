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
        QueueCounts.saturatingAdd(
            QueueCounts.saturatingAdd(runningCount, pendingCount),
            otherCount
        )
    }
}

struct RemoteJobState: Sendable {
    let jobSelector: String
    let state: JobState
    let taskCount: Int

    init(jobSelector: String, state: JobState, taskCount: Int? = nil) {
        self.jobSelector = jobSelector
        self.state = state
        self.taskCount = max(taskCount ?? SlurmArrayExpression.taskCount(inJobSelector: jobSelector), 1)
    }

    var countsAsRunning: Bool {
        state.queueBucket == .running
    }
}

struct QueueCounts: Equatable, Sendable {
    private(set) var running = 0
    private(set) var pending = 0
    private(set) var other = 0

    var total: Int {
        Self.saturatingAdd(Self.saturatingAdd(running, pending), other)
    }

    mutating func add(_ count: Int, to bucket: QueueBucket) {
        guard count > 0 else { return }
        switch bucket {
        case .running:
            running = Self.saturatingAdd(running, count)
        case .pending:
            pending = Self.saturatingAdd(pending, count)
        case .other:
            other = Self.saturatingAdd(other, count)
        }
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

struct OptimizedSnapshotPayload: Sendable {
    let states: [RemoteJobState]
    let details: Data
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
        try Self.requireCompleteStdout(result)

        let jobs = try Self.parseJobs(from: result.stdout, stderr: result.stderrText)
        let counts = Self.queueCounts(for: jobs)
        return SlurmQueueSnapshot(
            jobs: Array(jobs.prefix(max(visibleJobLimit, 0))),
            runningCount: counts.running,
            pendingCount: counts.pending,
            otherCount: counts.other
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
            try Self.requireCompleteStdout(result)

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

    static let optimizedStateRowLimit = 50_000
    static let optimizedStateByteLimit = 8 * 1_024 * 1_024

    static func parseStateRows(from text: String) -> [RemoteJobState] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap(parseStateRow)
    }

    static func parseCompleteStateRows(
        from text: String,
        maxRows: Int = optimizedStateRowLimit,
        maxUTF8Bytes: Int = optimizedStateByteLimit
    ) -> [RemoteJobState]? {
        guard maxRows >= 0, maxUTF8Bytes >= 0, text.utf8.count <= maxUTF8Bytes else {
            return nil
        }

        let nonemptyLines = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonemptyLines.count <= maxRows else { return nil }

        let rows = nonemptyLines.compactMap(parseStateRow)
        return rows.count == nonemptyLines.count ? rows : nil
    }

    static func parseOptimizedSnapshotPayload(
        from data: Data,
        stderr: String = ""
    ) throws -> OptimizedSnapshotPayload {
        let overflowMarkerData = Data((stateLimitExceededMarker + "\n").utf8)
        if data.range(of: overflowMarkerData) != nil {
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "The Slurm queue is too large to summarize safely (limit: \(optimizedStateRowLimit) state rows or \(optimizedStateByteLimit / 1_024 / 1_024) MiB). Narrow the queue or use a custom aggregate command.",
                stdout: stateLimitExceededMarker,
                stderr: stderr
            )
        }

        let detailMarkerData = Data(detailSectionMarker.utf8)
        guard let markerRange = data.range(of: detailMarkerData) else {
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "The optimized Slurm response was missing its detail section.",
                stdout: String(decoding: data.prefix(500), as: UTF8.self),
                stderr: stderr
            )
        }

        let stateData = Data(data[..<markerRange.lowerBound])
        guard let stateText = String(data: stateData, encoding: .utf8),
              let states = parseCompleteStateRows(from: stateText) else {
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "The optimized Slurm state response was malformed or exceeded its safety limit.",
                stdout: String(decoding: stateData.prefix(500), as: UTF8.self),
                stderr: stderr
            )
        }

        let details = Data(data[markerRange.upperBound...])
        guard !details.isEmpty else {
            throw ConnectionFailure(
                kind: .invalidResponse,
                message: "The optimized Slurm response contained no detail JSON.",
                stdout: String(decoding: stateData.prefix(500), as: UTF8.self),
                stderr: stderr
            )
        }

        return OptimizedSnapshotPayload(states: states, details: details)
    }

    static func queueCounts(for states: [RemoteJobState]) -> QueueCounts {
        var counts = QueueCounts()
        for state in states {
            counts.add(state.taskCount, to: state.state.queueBucket)
        }
        return counts
    }

    static func queueCounts(for jobs: [SlurmJob]) -> QueueCounts {
        var counts = QueueCounts()
        for job in jobs {
            counts.add(job.queueTaskCount, to: job.displayState.queueBucket)
        }
        return counts
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
            append(SlurmArrayExpression.representativeSelector(from: state.jobSelector))
        }

        for state in states where state.state == .pending {
            append(SlurmArrayExpression.representativeSelector(from: state.jobSelector))
        }

        for state in states where !state.countsAsRunning && state.state != .pending {
            append(SlurmArrayExpression.representativeSelector(from: state.jobSelector))
        }

        return selected
    }

    private static func parseStateRow(_ rawLine: Substring) -> RemoteJobState? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let selector = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let stateText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, let state = JobState(rawValue: stateText) else { return nil }
        return RemoteJobState(jobSelector: selector, state: state)
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

    static func requireCompleteStdout(_ result: SSHCommandResult) throws {
        guard result.stdoutTruncated else { return }
        throw ConnectionFailure(
            kind: .invalidResponse,
            message: "The remote response exceeded the \(AppConfig.maxSSHStdoutBytes / 1_024 / 1_024) MiB safety limit and was truncated.",
            stdout: String(decoding: result.stdout.prefix(500), as: UTF8.self),
            stderr: result.stderrText
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
        let result = try sshClient.execute(
            Self.optimizedSnapshotCommand(visibleJobLimit: visibleJobLimit)
        )
        if !result.succeeded {
            let failure = Self.classifyFailure(from: result)
            if failure.kind == .remoteCommandMissing {
                return try fetchLegacySnapshot(
                    using: connection.resolvedRemoteCommand,
                    visibleJobLimit: visibleJobLimit
                )
            }
            throw failure
        }
        try Self.requireCompleteStdout(result)

        let payload = try Self.parseOptimizedSnapshotPayload(
            from: result.stdout,
            stderr: result.stderrText
        )
        let counts = Self.queueCounts(for: payload.states)
        let jobs = try Self.parseJobs(from: payload.details, stderr: result.stderrText)
        return SlurmQueueSnapshot(
            jobs: Array(jobs.prefix(max(visibleJobLimit, 0))),
            runningCount: counts.running,
            pendingCount: counts.pending,
            otherCount: counts.other
        )
    }

    static func optimizedSnapshotCommand(
        visibleJobLimit: Int,
        stateRowLimit: Int = optimizedStateRowLimit,
        stateByteLimit: Int = optimizedStateByteLimit
    ) -> String {
        let detailLimit = max(visibleJobLimit, 0)
        let rowLimit = max(stateRowLimit, 0)
        let byteLimit = max(stateByteLimit, 0)
        return """
        unset SQUEUE_ARRAY
        export SLURM_BITSTR_LEN=0
        state_file="$(mktemp "${TMPDIR:-/tmp}/hivesqueue-state.XXXXXX")" || exit 70
        cleanup_hivesqueue_state() {
            rm -f "$state_file"
        }
        trap cleanup_hivesqueue_state EXIT HUP INT TERM

        LC_ALL=C squeue --me --noheader --format='%i|%T' |
            LC_ALL=C awk -v max_rows=\(rowLimit) -v max_bytes=\(byteLimit) '
                {
                    row_bytes = length($0) + 1
                    if (NR > max_rows || bytes + row_bytes > max_bytes) exit 42
                    bytes += row_bytes
                    print
                }
            ' > "$state_file"
        state_pipeline_status=("${PIPESTATUS[@]}")
        state_status="${state_pipeline_status[0]}"
        limiter_status="${state_pipeline_status[1]}"
        if [ "$limiter_status" -eq 42 ]; then
            printf '%s\n' '\(stateLimitExceededMarker)'
            exit 0
        fi
        if [ "$limiter_status" -ne 0 ]; then
            exit "$limiter_status"
        fi
        if [ "$state_status" -ne 0 ]; then
            exit "$state_status"
        fi

        cat "$state_file"
        cat_status=$?
        if [ "$cat_status" -ne 0 ]; then
            exit "$cat_status"
        fi
        printf '\n%s\n' '\(detailSectionMarker.trimmingCharacters(in: .newlines))'

        detail_limit=\(detailLimit)
        selectors="$(
            awk -F'|' '
                function trim(value) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                    return value
                }
                function priority(state) {
                    state = trim(state)
                    if (state == "RUNNING" || state == "CONFIGURING" || state == "COMPLETING") return 0
                    if (state == "PENDING" || state == "REQUEUED" || state == "REQUEUE_HOLD") return 1
                    return 2
                }
                function representative(selector, bracket, expression, pieces, first, bounds) {
                    selector = trim(selector)
                    bracket = index(selector, "_[")
                    if (bracket == 0 || substr(selector, length(selector), 1) != "]") return selector
                    expression = substr(selector, bracket + 2, length(selector) - bracket - 2)
                    split(expression, pieces, ",")
                    first = pieces[1]
                    sub(/%.*/, "", first)
                    sub(/:.*/, "", first)
                    split(first, bounds, "-")
                    if (bounds[1] !~ /^[0-9]+$/) return selector
                    return substr(selector, 1, bracket - 1) "_" bounds[1]
                }
                NF == 2 {
                    print priority($2) "|" NR "|" representative($1)
                }
            ' "$state_file" |
            sort -t'|' -k1,1n -k2,2n |
            awk -F'|' '!seen[$3]++ { print $3 }' |
            head -n "$detail_limit" |
            paste -sd, -
        )"

        if [ -n "$selectors" ]; then
            case "$selectors" in
                *,*) ;;
                *) selectors="$selectors,$selectors" ;;
            esac
            export SLURM_JSON=compact
            squeue --me --json --jobs="$selectors"
        else
            printf '%s\n' '{"jobs":[]}'
        fi
        """
    }

    private static let stateLimitExceededMarker = "__HIVESQUEUE_STATE_LIMIT_EXCEEDED_V1__"
    private static let detailSectionMarker = "\n__HIVESQUEUE_DETAIL_JSON_V1__\n"

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
