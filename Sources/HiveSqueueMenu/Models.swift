import Foundation

// Slurm wraps numeric values in a structure with set/infinite/number fields
struct SlurmNumber: Decodable {
    let set: Bool
    let infinite: Bool
    let number: Int?

    var value: Int {
        number ?? 0
    }
}

// Slurm wraps string values similarly
struct SlurmString: Decodable {
    let set: Bool
    let infinite: Bool
    let number: String?

    var value: String {
        number ?? ""
    }
}

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try to decode as wrapped number first, fall back to plain Int
        if let wrappedId = try? container.decode(SlurmNumber.self, forKey: .id) {
            self.id = wrappedId.value
        } else {
            self.id = try container.decode(Int.self, forKey: .id)
        }

        // Try to decode as wrapped string first, fall back to plain String
        if let wrappedName = try? container.decode(SlurmString.self, forKey: .name) {
            self.name = wrappedName.value
        } else {
            self.name = try container.decode(String.self, forKey: .name)
        }

        if let wrappedPartition = try? container.decode(SlurmString.self, forKey: .partition) {
            self.partition = wrappedPartition.value
        } else {
            self.partition = try container.decode(String.self, forKey: .partition)
        }

        if let wrappedState = try? container.decode(SlurmString.self, forKey: .state) {
            self.state = wrappedState.value
        } else {
            self.state = try container.decode(String.self, forKey: .state)
        }
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
