import Foundation

struct SlurmJob: Decodable, Sendable {
    let id: Int
    let arrayJobId: Int?
    let arrayTaskId: Int?
    let heterogeneousJobId: Int?
    let heterogeneousJobOffset: Int?
    let name: String
    let partition: String
    let state: String
    let stateFlags: [String]
    private let decodedElapsedSeconds: Int?
    let startEpoch: Int?
    let submitEpoch: Int?
    let limitSeconds: Int?
    let isLimitInfinite: Bool
    let rawElapsedDescription: String?
    let resources: SlurmJobResources?
    let requestedTres: String
    let allocatedTres: String
    let nodes: String
    let nodeCount: Int?
    let tasks: Int?
    let memoryPerNodeMB: Int?
    let qos: String
    let submitLine: String
    let workingDirectory: String
    let stateReason: String

    enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case arrayJobId = "array_job_id"
        case arrayTaskId = "array_task_id"
        case heterogeneousJobId = "het_job_id"
        case heterogeneousJobOffset = "het_job_offset"
        case name
        case partition
        case state = "job_state"
        case time
        case startTime = "start_time"
        case submitTime = "submit_time"
        case timeLimit = "time_limit"
        case resources = "job_resources"
        case requestedTres = "tres_req_str"
        case allocatedTres = "tres_alloc_str"
        case nodes
        case nodeCount = "node_count"
        case tasks
        case memoryPerNode = "memory_per_node"
        case qos
        case submitLine = "submit_line"
        case workingDirectory = "current_working_directory"
        case stateReason = "state_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeSlurmInt(forKey: .id)
        self.arrayJobId = SlurmJob.normalizedEpoch(container.decodeSlurmOptionalInt(forKey: .arrayJobId))
        self.arrayTaskId = container.decodeSlurmOptionalInt(forKey: .arrayTaskId)
        self.heterogeneousJobId = SlurmJob.normalizedEpoch(container.decodeSlurmOptionalInt(forKey: .heterogeneousJobId))
        self.heterogeneousJobOffset = container.decodeSlurmOptionalInt(forKey: .heterogeneousJobOffset)
        self.name = container.decodeSlurmString(forKey: .name)
        self.partition = container.decodeSlurmString(forKey: .partition)
        let states = container.decodeSlurmStateArray(forKey: .state)
        self.state = states.first ?? ""
        self.stateFlags = Array(states.dropFirst())
        let timeInfo = try? container.decodeIfPresent(SlurmTimeInfo.self, forKey: .time)
        self.decodedElapsedSeconds = timeInfo?.elapsedSeconds
        self.startEpoch = SlurmJob.normalizedEpoch(
            container.decodeSlurmOptionalInt(forKey: .startTime) ?? timeInfo?.startEpoch
        )
        self.submitEpoch = SlurmJob.normalizedEpoch(container.decodeSlurmOptionalInt(forKey: .submitTime))
        self.limitSeconds = container.decodeSlurmDurationSeconds(forKey: .timeLimit) ?? timeInfo?.limitSeconds
        self.isLimitInfinite = timeInfo?.isLimitInfinite ?? false
        self.rawElapsedDescription = timeInfo?.rawElapsedDescription
        self.resources = try? container.decodeIfPresent(SlurmJobResources.self, forKey: .resources)
        self.requestedTres = container.decodeSlurmString(forKey: .requestedTres)
        self.allocatedTres = container.decodeSlurmString(forKey: .allocatedTres)
        self.nodes = container.decodeSlurmString(forKey: .nodes)
        self.nodeCount = SlurmJob.normalizedCount(container.decodeSlurmOptionalInt(forKey: .nodeCount))
        self.tasks = SlurmJob.normalizedCount(container.decodeSlurmOptionalInt(forKey: .tasks))
        self.memoryPerNodeMB = SlurmJob.normalizedCount(container.decodeSlurmOptionalInt(forKey: .memoryPerNode))
        self.qos = container.decodeSlurmString(forKey: .qos)
        self.submitLine = container.decodeSlurmString(forKey: .submitLine)
        self.workingDirectory = container.decodeSlurmString(forKey: .workingDirectory)
        self.stateReason = container.decodeSlurmString(forKey: .stateReason)
    }

    var displayState: JobState {
        JobState(rawValue: state) ?? .unknown(state)
    }

    var elapsedSeconds: Int? {
        if let startEpoch {
            return max(Int(Date().timeIntervalSince1970) - startEpoch, 0)
        }
        return decodedElapsedSeconds
    }

    var timeRemainingSeconds: Int? {
        guard !isLimitInfinite else { return nil }
        guard let limitSeconds else { return nil }
        let elapsed = max(elapsedSeconds ?? 0, 0)
        return max(limitSeconds - elapsed, 0)
    }
}

struct SlurmJobResources: Decodable, Sendable {
    let cpus: Int?
    let nodes: SlurmJobResourceNodes?
}

struct SlurmJobResourceNodes: Decodable, Sendable {
    let count: Int?
}
