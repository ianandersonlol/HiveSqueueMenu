import XCTest
@testable import HiveSqueueMenu

final class SlurmJobDecodingTests: XCTestCase {
    func testDecodesWrappedAndPlainFields() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": { "set": true, "number": 42 },
                    "name": { "set": true, "string": "wrapped-job" },
                    "partition": { "set": true, "string": "gpu" },
                    "job_state": { "set": true, "string": "RUNNING" }
                },
                {
                    "job_id": 7,
                    "name": "plain-job",
                    "partition": "cpu",
                    "job_state": "PENDING"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        XCTAssertEqual(response.jobs.count, 2)

        let wrapped = response.jobs[0]
        XCTAssertEqual(wrapped.id, 42)
        XCTAssertEqual(wrapped.name, "wrapped-job")
        XCTAssertEqual(wrapped.partition, "gpu")
        XCTAssertEqual(wrapped.state, "RUNNING")

        let plain = response.jobs[1]
        XCTAssertEqual(plain.id, 7)
        XCTAssertEqual(plain.name, "plain-job")
        XCTAssertEqual(plain.partition, "cpu")
        XCTAssertEqual(plain.state, "PENDING")
    }

    func testHandlesWrappedNumberProvidedAsString() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": { "set": true, "number": "128" },
                    "name": "plain-job",
                    "partition": "cpu",
                    "job_state": "RUNNING"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        XCTAssertEqual(response.jobs.first?.id, 128)
    }

    func testHandlesWrappedStringWithNumericPayload() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": 1,
                    "name": { "set": true, "number": 42 },
                    "partition": { "set": true, "string": "cpu" },
                    "job_state": { "set": true, "number": 5 }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        XCTAssertEqual(response.jobs.first?.name, "42")
        XCTAssertEqual(response.jobs.first?.state, "5")
    }

    func testHandlesMissingStringFields() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": 9
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        let job = try XCTUnwrap(response.jobs.first)
        XCTAssertEqual(job.id, 9)
        XCTAssertEqual(job.name, "")
        XCTAssertEqual(job.partition, "")
        XCTAssertEqual(job.state, "")
    }

    func testHandlesDoubleNumericValues() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": { "set": true, "number": 41.0 },
                    "name": 123,
                    "partition": null,
                    "job_state": { "set": true, "number": "3.0" }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        let job = try XCTUnwrap(response.jobs.first)
        XCTAssertEqual(job.id, 41)
        XCTAssertEqual(job.name, "123")
        XCTAssertEqual(job.partition, "")
        XCTAssertEqual(job.state, "3.0")
    }

    func testDecodesTimeRemaining() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": 1,
                    "name": "timed",
                    "partition": "cpu",
                    "job_state": "RUNNING",
                    "time": {
                        "elapsed": 61,
                        "limit": { "set": true, "number": 70 }
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        let job = try XCTUnwrap(response.jobs.first)
        XCTAssertEqual(job.timeRemainingSeconds, (70 * 60) - 61)
        XCTAssertEqual(job.formattedTimeRemaining, "1h 08m")
        XCTAssertEqual(job.formattedElapsedTime, "1m 01s")
    }

    func testParsesStateArrayAndStringTimeLimit() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": 2,
                    "name": "string-time",
                    "partition": "gpu",
                    "job_state": ["RUNNING", "NODE_FAIL"],
                    "time": {
                        "elapsed": 60,
                        "limit": "1-02:03:04"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        let job = try XCTUnwrap(response.jobs.first)
        XCTAssertEqual(job.timeRemainingSeconds, (1 * 86_400 + 2 * 3600 + 3 * 60 + 4) - 60)
        XCTAssertEqual(job.formattedElapsedTime, "1m 00s")
        XCTAssertEqual(job.displayState, .running)
        XCTAssertEqual(job.stateFlags, ["NODE_FAIL"])
    }

    func testDisplaysInfinityForUnlimited() throws {
        let json = """
        {
            "jobs": [
                {
                    "job_id": 3,
                    "name": "unlimited-time",
                    "partition": "long",
                    "job_state": "RUNNING",
                    "time": {
                        "limit": { "set": true, "infinite": true }
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SlurmResponse.self, from: json)
        let job = try XCTUnwrap(response.jobs.first)
        XCTAssertNil(job.timeRemainingSeconds)
        XCTAssertEqual(job.formattedTimeRemaining, "∞")
        XCTAssertEqual(job.formattedElapsedTime, "—")
    }
}
