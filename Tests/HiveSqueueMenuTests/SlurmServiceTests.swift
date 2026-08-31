import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("Slurm service planning and failures")
struct SlurmServiceTests {
    @Test
    func rejectsPartiallyMalformedStateOutput() {
        #expect(SlurmService.parseCompleteStateRows(from: "123|RUNNING\n124|PENDING")?.count == 2)
        #expect(SlurmService.parseCompleteStateRows(from: "123|RUNNING\nunexpected warning") == nil)
        #expect(SlurmService.parseCompleteStateRows(
            from: "123|RUNNING\n124|PENDING",
            maxRows: 1,
            maxUTF8Bytes: 1_024
        ) == nil)
        #expect(SlurmService.parseCompleteStateRows(
            from: "123|RUNNING",
            maxRows: 1,
            maxUTF8Bytes: 4
        ) == nil)
    }

    @Test
    func detailSelectionPrioritizesRunningAndUsesConcreteArrayRepresentatives() {
        let states = [
            RemoteJobState(jobSelector: "200_[1-1000000]", state: .pending),
            RemoteJobState(jobSelector: "100_3", state: .running),
            RemoteJobState(jobSelector: "300", state: .failed)
        ]

        #expect(SlurmService.selectDetailedJobSelectors(from: states, limit: 3) == ["100_3", "200_1", "300"])
    }

    @Test
    func parsesCompressedArrayCardinalityWithoutExpansion() {
        #expect(SlurmArrayExpression.taskCount(in: "1,3,5-9:2") == 5)
        #expect(SlurmArrayExpression.taskCount(in: "[0-999999]") == 1_000_000)
        #expect(SlurmArrayExpression.taskCount(in: "1-10%2") == 10)
        #expect(SlurmArrayExpression.taskCount(in: "7-1") == nil)
        #expect(SlurmArrayExpression.taskCount(in: "1,,2") == nil)
        #expect(SlurmArrayExpression.taskCount(in: "1-2:0") == nil)
        #expect(SlurmArrayExpression.representativeSelector(from: "1080_[5-1024%4]") == "1080_5")
        #expect(QueueCounts.saturatingAdd(Int.max, 1) == Int.max)
    }

    @Test
    func optimizedAndJSONPathsUseIdenticalBucketsAndArrayTaskCounts() throws {
        let optimizedStates = try #require(SlurmService.parseCompleteStateRows(from: """
        10_[1-3]|PENDING
        20|CONFIGURING
        21|COMPLETING
        22|RUNNING
        23|SIGNALING
        30|FAILED
        """))
        let optimizedCounts = SlurmService.queueCounts(for: optimizedStates)

        let json = """
        {"jobs":[
          {"job_id":10,"array_job_id":10,"array_task_string":"1-3","job_state":"PENDING"},
          {"job_id":20,"job_state":["PENDING","CONFIGURING"]},
          {"job_id":21,"job_state":["CANCELLED","COMPLETING"]},
          {"job_id":22,"job_state":"RUNNING"},
          {"job_id":23,"job_state":["RUNNING","SIGNALING"]},
          {"job_id":30,"job_state":"FAILED"}
        ]}
        """
        let jobs = try SlurmService.parseJobs(from: Data(json.utf8))
        let jsonCounts = SlurmService.queueCounts(for: jobs)

        #expect(optimizedCounts == jsonCounts)
        #expect(optimizedCounts.running == 3)
        #expect(optimizedCounts.pending == 3)
        #expect(optimizedCounts.other == 2)
        #expect(optimizedCounts.total == 8)
    }

    @Test
    func optimizedCommandUsesCompressedUserScopedStateOutput() throws {
        let command = SlurmService.optimizedSnapshotCommand(visibleJobLimit: 20)

        #expect(command.contains("unset SQUEUE_ARRAY"))
        #expect(command.contains("squeue --me --noheader --format='%i|%T'"))
        #expect(!command.contains("--only-job-state"))
        #expect(!command.contains("squeue --me --array"))
        #expect(command.contains("hivesqueue-state.XXXXXX"))
        #expect(command.contains("__HIVESQUEUE_DETAIL_JSON_V1__"))

        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
        syntaxCheck.arguments = ["-n", "-c", command]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        #expect(syntaxCheck.terminationStatus == 0)
    }

    @Test
    func vanishedLoneDetailJobStillReturnsUsableCounts() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiveSqueueMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeSqueue = temporaryDirectory.appendingPathComponent("squeue")
        let fakeSqueueScript = """
        #!/bin/bash
        mode=""
        selectors=""
        for argument in "$@"; do
            case "$argument" in
                --noheader) mode="state" ;;
                --json) mode="detail" ;;
                --jobs=*) selectors="${argument#--jobs=}" ;;
            esac
        done

        if [ "$mode" = "state" ]; then
            printf '%s\n' '123|RUNNING'
            exit 0
        fi
        if [ "$mode" = "detail" ] && [ "$selectors" = "123,123" ]; then
            printf '%s\n' '{"jobs":[]}'
            exit 0
        fi
        if [ "$mode" = "detail" ] && [ "$selectors" = "123" ]; then
            echo 'slurm_load_jobs error: Invalid job id specified' >&2
            exit 1
        fi
        echo "unexpected fake squeue invocation: $*" >&2
        exit 64
        """
        try Data(fakeSqueueScript.utf8).write(to: fakeSqueue)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeSqueue.path
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", SlurmService.optimizedSnapshotCommand(visibleJobLimit: 1)]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(temporaryDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory.path
        ]) { _, testValue in testValue }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, Comment(rawValue: stderrText))
        let payload = try SlurmService.parseOptimizedSnapshotPayload(from: stdoutData, stderr: stderrText)
        #expect(SlurmService.queueCounts(for: payload.states).running == 1)
        #expect(try SlurmService.parseJobs(from: payload.details).isEmpty)
    }

    @Test
    func stateProducerIsStoppedAtInjectedRowLimit() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiveSqueueMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let completionMarker = temporaryDirectory.appendingPathComponent("producer-completed")
        let fakeSqueue = temporaryDirectory.appendingPathComponent("squeue")
        let fakeSqueueScript = """
        #!/bin/bash
        index=1
        while [ "$index" -le 20000 ]; do
            printf '%s|RUNNING\n' "$index" || exit 141
            index=$((index + 1))
        done
        printf '%s\n' completed > "$FAKE_SQUEUE_COMPLETION_MARKER"
        """
        try Data(fakeSqueueScript.utf8).write(to: fakeSqueue)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeSqueue.path
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile",
            "--norc",
            "-c",
            SlurmService.optimizedSnapshotCommand(
                visibleJobLimit: 1,
                stateRowLimit: 1,
                stateByteLimit: 1_024
            )
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "FAKE_SQUEUE_COMPLETION_MARKER": completionMarker.path,
            "PATH": "\(temporaryDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory.path
        ]) { _, testValue in testValue }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, Comment(rawValue: stderrText))
        #expect(stdoutText == "__HIVESQUEUE_STATE_LIMIT_EXCEEDED_V1__\n")
        #expect(!FileManager.default.fileExists(atPath: completionMarker.path))
    }

    @Test
    func parsesFramedOptimizedSnapshotAndRejectsRemoteLimitMarker() throws {
        let response = """
        10_[1-1000000]|PENDING
        20|RUNNING

        __HIVESQUEUE_DETAIL_JSON_V1__
        {"jobs":[{"job_id":20,"job_state":"RUNNING"}]}
        """
        let payload = try SlurmService.parseOptimizedSnapshotPayload(from: Data(response.utf8))
        let counts = SlurmService.queueCounts(for: payload.states)

        #expect(counts.pending == 1_000_000)
        #expect(counts.running == 1)
        #expect(try SlurmService.parseJobs(from: payload.details).map(\.id) == [20])

        do {
            _ = try SlurmService.parseOptimizedSnapshotPayload(
                from: Data("__HIVESQUEUE_STATE_LIMIT_EXCEEDED_V1__\n".utf8)
            )
            Issue.record("Expected the bounded state response to be rejected")
        } catch let failure as ConnectionFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.message.contains("too large"))
        }
    }

    @Test
    func classifiesAuthenticationCommandAndTimeoutFailures() {
        let authentication = SlurmService.classifyFailure(
            from: result(status: 255, stderr: "Permission denied (publickey).")
        )
        #expect(authentication.kind == .sshAuthenticationFailed)

        let command = SlurmService.classifyFailure(
            from: result(status: 127, stderr: "squeue: command not found")
        )
        #expect(command.kind == .remoteCommandMissing)

        let timeout = SlurmService.classifyFailure(
            from: result(status: 15, stderr: "", timedOut: true)
        )
        #expect(timeout.kind == .transportFailure)
        #expect(timeout.message.contains("timed out"))

        do {
            try SlurmService.requireCompleteStdout(
                SSHCommandResult(
                    stdout: Data("partial".utf8),
                    stderr: Data(),
                    terminationStatus: 0,
                    timedOut: false,
                    stdoutTruncated: true
                )
            )
            Issue.record("Expected truncated stdout to be rejected")
        } catch let failure as ConnectionFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.message.contains("safety limit"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func result(status: Int32, stderr: String, timedOut: Bool = false) -> SSHCommandResult {
        SSHCommandResult(
            stdout: Data(),
            stderr: Data(stderr.utf8),
            terminationStatus: status,
            timedOut: timedOut
        )
    }
}
