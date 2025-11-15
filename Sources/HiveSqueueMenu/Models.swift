import Foundation

// Slurm wraps numeric values in a structure with set/infinite/number fields
struct SlurmNumber: Decodable {
    let set: Bool
    let infinite: Bool
    private let rawNumber: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        set = (try? container.decode(Bool.self, forKey: .set)) ?? false
        infinite = (try? container.decode(Bool.self, forKey: .infinite)) ?? false

        if let intValue = try? container.decode(Int.self, forKey: .number) {
            rawNumber = intValue
        } else if let doubleValue = try? container.decode(Double.self, forKey: .number) {
            rawNumber = Int(doubleValue)
        } else if let stringValue = try? container.decode(String.self, forKey: .number) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                rawNumber = intValue
            } else if let doubleValue = Double(trimmed) {
                rawNumber = Int(doubleValue)
            } else {
                rawNumber = nil
            }
        } else {
            rawNumber = nil
        }
    }

    var value: Int {
        rawNumber ?? 0
    }

    var optionalValue: Int? {
        guard !infinite else { return nil }
        return rawNumber
    }

    private enum CodingKeys: String, CodingKey {
        case set
        case infinite
        case number
    }
}

// Slurm wraps string values similarly
struct SlurmString: Decodable {
    let set: Bool
    let infinite: Bool
    private let rawValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        set = (try? container.decode(Bool.self, forKey: .set)) ?? false
        infinite = (try? container.decode(Bool.self, forKey: .infinite)) ?? false

        if let stringValue = try? container.decode(String.self, forKey: .string) {
            rawValue = stringValue
            return
        }

        if let stringValue = try? container.decode(String.self, forKey: .number) {
            rawValue = stringValue
            return
        }

        if let intValue = try? container.decode(Int.self, forKey: .number) {
            rawValue = String(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self, forKey: .number) {
            rawValue = String(doubleValue)
            return
        }

        if let boolValue = try? container.decode(Bool.self, forKey: .number) {
            rawValue = boolValue ? "true" : "false"
            return
        }

        rawValue = nil
    }

    var value: String {
        rawValue ?? ""
    }

    var optionalValue: String? {
        rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case set
        case infinite
        case number
        case string
    }
}

struct SlurmJob: Identifiable, Decodable {
    let id: Int
    let name: String
    let partition: String
    let state: String
    let stateFlags: [String]
    let timeRemainingSeconds: Int?
    fileprivate let timeInfo: SlurmTimeInfo?
    let resources: SlurmJobResources?
    let requestedTres: String
    let allocatedTres: String

    enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case name
        case partition
        case state = "job_state"
        case time
        case resources = "job_resources"
        case requestedTres = "tres_req_str"
        case allocatedTres = "tres_alloc_str"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeSlurmInt(forKey: .id)
        self.name = container.decodeSlurmString(forKey: .name)
        self.partition = container.decodeSlurmString(forKey: .partition)
        let states = container.decodeSlurmStateArray(forKey: .state)
        self.state = states.first ?? ""
        self.stateFlags = Array(states.dropFirst())
        self.timeInfo = try? container.decodeIfPresent(SlurmTimeInfo.self, forKey: .time)
        self.timeRemainingSeconds = SlurmJob.computeTimeRemaining(from: timeInfo)
        self.resources = try? container.decodeIfPresent(SlurmJobResources.self, forKey: .resources)
        self.requestedTres = container.decodeSlurmString(forKey: .requestedTres)
        self.allocatedTres = container.decodeSlurmString(forKey: .allocatedTres)
    }

    var displayState: JobState {
        JobState(rawValue: state) ?? .unknown(state)
    }
}

struct SlurmResponse: Decodable {
    let jobs: [SlurmJob]
}

struct SlurmTimeInfo: Decodable {
    let elapsedSeconds: Int?
    let startEpoch: Int?
    let limitSeconds: Int?
    let isLimitInfinite: Bool
    let rawElapsedDescription: String?

    private enum CodingKeys: String, CodingKey {
        case elapsed
        case start
        case limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .elapsed) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rawElapsedDescription = trimmed.isEmpty ? nil : trimmed
            if let parsedInt = Int(trimmed) {
                elapsedSeconds = parsedInt
            } else if let duration = SlurmJob.seconds(fromTimeString: trimmed) {
                elapsedSeconds = duration
            } else {
                elapsedSeconds = nil
            }
        } else if let wrapper = try? container.decodeIfPresent(SlurmNumber.self, forKey: .elapsed),
                  let numeric = wrapper.optionalValue {
            elapsedSeconds = numeric
            rawElapsedDescription = nil
        } else if let intValue = try? container.decodeIfPresent(Int.self, forKey: .elapsed) {
            elapsedSeconds = intValue
            rawElapsedDescription = nil
        } else {
            elapsedSeconds = nil
            rawElapsedDescription = nil
        }

        startEpoch = SlurmTimeInfo.decodeFlexibleInt(container, key: .start)

        if let wrapper = try? container.decode(SlurmNumber.self, forKey: .limit) {
            if let minutes = wrapper.optionalValue {
                limitSeconds = minutes * 60
            } else {
                limitSeconds = nil
            }
            isLimitInfinite = wrapper.infinite
        } else if let limitValue = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limitSeconds = limitValue * 60
            isLimitInfinite = false
        } else if let limitString = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let seconds = SlurmJob.seconds(fromTimeString: limitString) {
            limitSeconds = seconds
            isLimitInfinite = false
        } else {
            limitSeconds = nil
            isLimitInfinite = false
        }
    }
}

private extension SlurmTimeInfo {
    private static func decodeFlexibleInt(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
            if let seconds = SlurmJob.seconds(fromTimeString: trimmed) {
                return seconds
            }
        }
        if let wrapper = try? container.decodeIfPresent(SlurmNumber.self, forKey: key) {
            return wrapper.optionalValue
        }
        return nil
    }
}

fileprivate let jobIdFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    return formatter
}()

extension SlurmJob {
    var formattedId: String {
        if let text = jobIdFormatter.string(from: NSNumber(value: id)) {
            return text
        }
        return "\(id)"
    }

    var displayName: String {
        name.isEmpty ? "(unnamed job)" : name
    }

    var partitionDisplay: String {
        partition.isEmpty ? "—" : partition.uppercased()
    }

    var formattedTimeRemaining: String {
        if let seconds = timeRemainingSeconds, seconds > 0 {
            return Self.durationString(for: seconds)
        }

        if timeInfo?.isLimitInfinite == true {
            return "∞"
        }

        return "—"
    }

    var formattedElapsedTime: String {
        if let elapsed = timeInfo?.elapsedSeconds, elapsed > 0 {
            return Self.durationString(for: elapsed)
        }
        if let description = timeInfo?.rawElapsedDescription, !description.isEmpty {
            return description
        }
        return "—"
    }

    static func seconds(fromTimeString raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let uppercased = trimmed.uppercased()
        if uppercased == "UNLIMITED" || uppercased == "N/A" || uppercased == "NONE" {
            return nil
        }

        let parts = trimmed.split(separator: "-")
        var dayComponent = 0
        var timeComponent = trimmed

        if parts.count == 2, let parsedDays = Int(parts[0]) {
            dayComponent = parsedDays
            timeComponent = String(parts[1])
        } else if parts.count > 2 {
            return nil
        }

        let timePieces = timeComponent.split(separator: ":").map { String($0) }
        guard (2...3).contains(timePieces.count) else {
            return nil
        }

        let hourIndexOffset = timePieces.count == 3 ? 0 : -1
        let hourString = hourIndexOffset == 0 ? timePieces[0] : "0"
        let minuteString = timePieces[hourIndexOffset == 0 ? 1 : 0]
        let secondString = timePieces.last!

        guard
            let hours = Int(hourString),
            let minutes = Int(minuteString),
            let seconds = Int(secondString)
        else {
            return nil
        }

        return dayComponent * 86_400 + hours * 3600 + minutes * 60 + seconds
    }

    private static func durationString(for seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours >= 24 {
            let days = hours / 24
            let remHours = hours % 24
            return "\(days)d \(String(format: "%02dh", remHours))"
        } else if hours > 0 {
            return "\(hours)h \(String(format: "%02dm", minutes))"
        } else if minutes > 0 {
            return "\(minutes)m \(String(format: "%02ds", secs))"
        } else {
            return "\(secs)s"
        }
    }

    private static func computeTimeRemaining(from info: SlurmTimeInfo?) -> Int? {
        guard let info else { return nil }
        if info.isLimitInfinite {
            return nil
        }
        guard let limitSeconds = info.limitSeconds else {
            return nil
        }
        let elapsed = max(info.elapsedSeconds ?? 0, 0)
        return max(limitSeconds - elapsed, 0)
    }

    private var requestedTresValues: [String: String] {
        SlurmJob.parseTresString(requestedTres)
    }

    static func parseTresString(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .forEach { component in
                let parts = component.split(separator: "=", maxSplits: 1).map { String($0) }
                guard parts.count == 2 else { return }
                let key = parts[0].lowercased()
                let value = parts[1]
                result[key] = value
            }
        return result
    }

    var cpuSummary: String {
        if let cpus = resources?.cpus, cpus > 0 {
            return "\(cpus)"
        }
        if let value = requestedTresValues["cpu"], let number = Int(value) {
            return "\(number)"
        }
        return "—"
    }

    var memorySummary: String {
        if let value = requestedTresValues["mem"] ?? requestedTresValues["memory"] {
            return value.uppercased()
        }
        return "—"
    }

    var gpuSummary: String {
        if let direct = requestedTresValues["gres/gpu"] ?? requestedTresValues["gpu"] {
            return direct
        }
        if let match = requestedTresValues.first(where: { $0.key.contains("gpu") })?.value {
            return match
        }
        return "—"
    }
}

struct SlurmJobResources: Decodable {
    let cpus: Int?
    let nodes: SlurmJobResourceNodes?
}

struct SlurmJobResourceNodes: Decodable {
    let count: Int?
}

private extension KeyedDecodingContainer where Key: CodingKey {
    func decodeSafely<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func decodeNumericValue(forKey key: Key) -> Int? {
        if let wrapped: SlurmNumber = decodeSafely(SlurmNumber.self, forKey: key),
           let numeric = wrapped.optionalValue {
            return numeric
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return intValue
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let doubleValue = Double(trimmed) {
                return Int(doubleValue)
            }
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return Int(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? 1 : 0
        }

        return nil
    }

    func decodeSlurmInt(forKey key: Key) -> Int {
        decodeNumericValue(forKey: key) ?? 0
    }

    func decodeSlurmOptionalInt(forKey key: Key) -> Int? {
        decodeNumericValue(forKey: key)
    }

    func decodeSlurmString(forKey key: Key) -> String {
        if let wrapped: SlurmString = decodeSafely(SlurmString.self, forKey: key) {
            return wrapped.value
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            return stringValue
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return String(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        return ""
    }

    func decodeSlurmOptionalString(forKey key: Key) -> String? {
        if let wrapped: SlurmString = decodeSafely(SlurmString.self, forKey: key),
           let value = wrapped.optionalValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let stringValue: String = decodeSafely(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let intValue: Int = decodeSafely(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue: Double = decodeSafely(Double.self, forKey: key) {
            return String(doubleValue)
        }

        if let boolValue: Bool = decodeSafely(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        return nil
    }

    func decodeSlurmStateArray(forKey key: Key) -> [String] {
        if let stringArray = try? decodeIfPresent([String].self, forKey: key) {
            let trimmed = stringArray
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let wrappedArray = try? decodeIfPresent([SlurmString].self, forKey: key) {
            let values = wrappedArray
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                return values
            }
        }

        let single = decodeSlurmString(forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
        if !single.isEmpty {
            return [single]
        }

        return []
    }
}

enum JobState: Equatable {
    case running
    case pending
    case completing
    case completed
    case failed
    case cancelled
    case configuring
    case suspended
    case unknown(String)

    init?(rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch normalized {
        case "R", "RUNNING":
            self = .running
        case "PD", "PENDING":
            self = .pending
        case "CG", "COMPLETING":
            self = .completing
        case "CD", "COMPLETED":
            self = .completed
        case "F", "FAILED", "NF", "TO", "TIMEOUT":
            self = .failed
        case "CA", "CANCELLED", "PR", "OOM":
            self = .cancelled
        case "CF", "CONFIGURING":
            self = .configuring
        case "S", "SUSPENDED", "ST":
            self = .suspended
        default:
            self = .unknown(rawValue)
        }
    }

    var label: String {
        switch self {
        case .running:
            return "Running"
        case .pending:
            return "Pending"
        case .completing:
            return "Completing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Canceled"
        case .configuring:
            return "Configuring"
        case .suspended:
            return "Suspended"
        case .unknown(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Unknown"
            }
            if trimmed.count <= 3 {
                return trimmed.uppercased()
            }
            return trimmed.capitalized
        }
    }
}
