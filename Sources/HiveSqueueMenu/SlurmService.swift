import Foundation

struct SlurmService {
    let connection: ConnectionSettings

    private let remoteCommand: String
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(connection: ConnectionSettings, remoteCommand: String = AppConfig.remoteCommand) {
        self.connection = connection
        self.remoteCommand = remoteCommand
    }

    func fetchJobs() throws -> [SlurmJob] {
        let client = SSHClient(connection: connection)
        let data = try client.runCommand(remoteCommand)
        let response = try decoder.decode(SlurmResponse.self, from: data)
        return response.jobs.sorted(by: Self.jobSort)
    }

    private static func jobSort(lhs: SlurmJob, rhs: SlurmJob) -> Bool {
        let lhsPriority = lhs.displayState.priority
        let rhsPriority = rhs.displayState.priority
        if lhsPriority == rhsPriority {
            return lhs.id < rhs.id
        }
        return lhsPriority < rhsPriority
    }
}

private extension JobState {
    var priority: Int {
        switch self {
        case .running:
            return 0
        case .pending:
            return 1
        case .other:
            return 2
        }
    }
}
