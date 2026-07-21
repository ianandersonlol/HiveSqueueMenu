import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("Slurm service planning and failures")
struct SlurmServiceTests {
    @Test
    func rejectsPartiallyMalformedStateOutput() {
        #expect(SlurmService.parseCompleteStateRows(from: "123|RUNNING\n124|PENDING")?.count == 2)
        #expect(SlurmService.parseCompleteStateRows(from: "123|RUNNING\nunexpected warning") == nil)
    }

    @Test
    func detailSelectionPrioritizesRunningAndDeduplicatesPendingArrays() {
        let states = [
            RemoteJobState(jobSelector: "200_1", state: .pending),
            RemoteJobState(jobSelector: "100_3", state: .running),
            RemoteJobState(jobSelector: "200_2", state: .pending),
            RemoteJobState(jobSelector: "300", state: .failed)
        ]

        #expect(SlurmService.selectDetailedJobSelectors(from: states, limit: 3) == ["100_3", "200", "300"])
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
