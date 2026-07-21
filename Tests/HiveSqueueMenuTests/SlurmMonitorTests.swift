import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("Monitor lifecycle")
@MainActor
struct SlurmMonitorTests {
    @Test
    func obsoleteFetchCannotOverwriteNewConnection() async throws {
        let oldConnection = connection(host: "old.example")
        let newConnection = connection(host: "new.example")
        let oldSnapshot = try snapshot(jobID: 1, name: "old")
        let newSnapshot = try snapshot(jobID: 2, name: "new")

        let monitor = SlurmMonitor(connection: oldConnection, refreshCooldown: 0) { connection, _ in
            if connection.host == oldConnection.host {
                try await Task.sleep(for: .milliseconds(150))
                return oldSnapshot
            }
            return newSnapshot
        }

        monitor.fetch(force: true)
        monitor.updateConnection(newConnection)
        monitor.fetch(force: true)
        await waitUntil { !monitor.isFetching }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(monitor.host == "new.example")
        #expect(monitor.jobs.map(\.name) == ["new"])
    }

    @Test
    func forcedRetryBypassesManualCooldown() async throws {
        let counter = CallCounter()
        let value = try snapshot(jobID: 3, name: "job")
        let monitor = SlurmMonitor(connection: connection(host: "cluster.example"), refreshCooldown: 60) { _, _ in
            await counter.increment()
            return value
        }

        monitor.fetch(force: true)
        await waitUntil { !monitor.isFetching }
        monitor.fetch()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await counter.value == 1)

        monitor.fetch(force: true)
        await waitUntil { !monitor.isFetching }
        #expect(await counter.value == 2)
    }

    private func connection(host: String) -> ConnectionSettings {
        ConnectionSettings(
            host: host,
            username: "user",
            clusterProfile: .standard,
            authentication: .agent,
            password: nil,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    private func snapshot(jobID: Int, name: String) throws -> SlurmQueueSnapshot {
        let json = """
        {"jobs":[{"job_id":\(jobID),"name":"\(name)","partition":"cpu","job_state":"RUNNING"}]}
        """
        let jobs = try SlurmService.parseJobs(from: Data(json.utf8))
        return SlurmQueueSnapshot(jobs: jobs, runningCount: 1, pendingCount: 0, otherCount: 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for monitor state")
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
