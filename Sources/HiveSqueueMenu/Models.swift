import Foundation

struct SlurmJob: Identifiable, Decodable {
    let id: Int
    let name: String
    let partition: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case name
        case partition
        case state = "job_state"
    }

    var displayState: JobState {
        JobState(rawValue: state.uppercased()) ?? .other(state)
    }
}

struct SlurmResponse: Decodable {
    let jobs: [SlurmJob]
}

enum JobState: Equatable {
    case running
    case pending
    case other(String)

    init?(rawValue: String) {
        switch rawValue {
        case "RUNNING":
            self = .running
        case "PENDING":
            self = .pending
        default:
            self = .other(rawValue)
        }
    }

    var label: String {
        switch self {
        case .running:
            return "Running"
        case .pending:
            return "Pending"
        case .other(let value):
            return value.capitalized
        }
    }
}
