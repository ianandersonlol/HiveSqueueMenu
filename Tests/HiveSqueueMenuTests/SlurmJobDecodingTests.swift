import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("Slurm decoding and domain behavior")
struct SlurmJobDecodingTests {
    @Test
    func decodesWrappedPlainAndMissingFields() throws {
        let jobs = try parse(
            """
            {"jobs":[
              {"job_id":{"set":true,"number":42},"name":{"set":true,"string":"wrapped"},"partition":"gpu","job_state":"RUNNING"},
              {"job_id":7,"name":"plain","partition":"cpu","job_state":"PENDING"},
              {"job_id":9}
            ]}
            """
        )

        #expect(jobs.count == 3)
        #expect(jobs[0].id == 42)
        #expect(jobs[0].name == "wrapped")
        #expect(jobs[1].id == 7)
        #expect(jobs[1].state == "PENDING")
        #expect(jobs[2].name.isEmpty)
        #expect(jobs[2].partition.isEmpty)
    }

    @Test
    func decodesFlexibleNumbersAndStrings() throws {
        let jobs = try parse(
            """
            {"jobs":[
              {"job_id":{"number":"128"},"name":{"number":42},"partition":null,"job_state":{"number":5}},
              {"job_id":{"number":41.0},"name":123,"job_state":{"number":"3.0"}}
            ]}
            """
        )

        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        #expect(jobsByID[128]?.name == "42")
        #expect(jobsByID[128]?.state == "5")
        #expect(jobsByID[41]?.name == "123")
    }

    @Test
    func parsesTimeStateFlagsAndUnlimitedLimits() throws {
        let jobs = try parse(
            """
            {"jobs":[
              {"job_id":1,"job_state":"RUNNING","time":{"elapsed":61,"limit":{"number":70}}},
              {"job_id":2,"job_state":["RUNNING","NODE_FAIL"],"time":{"elapsed":60,"limit":"1-02:03:04"}},
              {"job_id":3,"job_state":"RUNNING","time":{"limit":{"infinite":true}}}
            ]}
            """
        )

        #expect(jobs[0].timeRemainingSeconds == (70 * 60) - 61)
        #expect(jobs[0].formattedTimeRemaining == "1h 08m")
        #expect(jobs[1].timeRemainingSeconds == (86_400 + 2 * 3_600 + 3 * 60 + 4) - 60)
        #expect(jobs[1].stateFlags == ["NODE_FAIL"])
        #expect(jobs[2].formattedTimeRemaining == "∞")
    }

    @Test
    func parsesTypedGPUResources() throws {
        let jobs = try parse(
            """
            {"jobs":[
              {"job_id":4,"job_state":"RUNNING","tres_req_str":"cpu=4,mem=32768M,gres/gpu:l40s=1"},
              {"job_id":5,"job_state":"PENDING","tres_req_str":"cpu=8,gres/gpu=a100:2"}
            ]}
            """
        )

        #expect(jobs[0].gpuSummary == "1 L40S")
        #expect(jobs[0].resourceSummaryDisplay == "4 CPU • 32768M • 1 L40S")
        #expect(jobs[1].gpuSummary == "2 A100")
    }

    @Test
    func arrayAndHeterogeneousJobsHaveStableDistinctSelectors() throws {
        let jobs = try parse(
            """
            {"jobs":[
              {"job_id":123,"array_job_id":123,"array_task_id":1,"job_state":"RUNNING"},
              {"job_id":123,"array_job_id":123,"array_task_id":2,"job_state":"RUNNING"},
              {"job_id":456,"het_job_id":456,"het_job_offset":3,"job_state":"PENDING"}
            ]}
            """
        )

        #expect(jobs.map(\.jobSelector) == ["123_1", "123_2", "456+3"])
        #expect(Set(jobs.map(\.renderIdentity)).count == 3)
    }

    @Test
    func mapsSlurmTerminalAndRequeueStatesCorrectly() {
        #expect(JobState(rawValue: "OUT_OF_MEMORY") == .failed)
        #expect(JobState(rawValue: "PREEMPTED") == .cancelled)
        #expect(JobState(rawValue: "REQUEUED") == .pending)
        #expect(JobState(rawValue: "NODE_FAIL") == .failed)
    }

    @Test
    func invalidJSONReportsCapturedOutput() {
        do {
            _ = try SlurmService.parseJobs(from: Data("not-json".utf8), stderr: "wrapper stderr")
            Issue.record("Expected invalid-response failure")
        } catch let failure as ConnectionFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.stderr == "wrapper stderr")
            #expect(failure.stdout == "not-json")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func authenticationValidationMatchesSelectedMode() {
        let passwordless = settings(authentication: .passwordOnly, password: nil)
        #expect(passwordless.isConfigured)
        #expect(passwordless.configurationIssue != nil)

        let withPassword = settings(authentication: .passwordOnly, password: "secret")
        #expect(withPassword.configurationIssue == nil)

        let missingKey = settings(authentication: .key(path: ""), password: nil)
        #expect(missingKey.configurationIssue != nil)
    }

    @Test
    func abbreviatesMenuCounts() {
        #expect(SlurmMonitor.abbreviatedJobCount(42) == "42")
        #expect(SlurmMonitor.abbreviatedJobCount(100) == "100+")
        #expect(SlurmMonitor.abbreviatedJobCount(1_000) == "1K+")
        #expect(SlurmMonitor.abbreviatedJobCount(250_000) == "100K+")
    }

    private func parse(_ json: String) throws -> [SlurmJob] {
        try SlurmService.parseJobs(from: Data(json.utf8))
    }

    private func settings(authentication: SSHAuthentication, password: String?) -> ConnectionSettings {
        ConnectionSettings(
            host: "cluster.example",
            username: "user",
            clusterProfile: .standard,
            authentication: authentication,
            password: password,
            remoteCommand: AppConfig.remoteCommand
        )
    }
}
