import Foundation

fileprivate let jobIdFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    return formatter
}()

extension SlurmJob {
    var formattedId: String {
        jobSelector
    }

    var jobSelector: String {
        let baseId = arrayJobId ?? heterogeneousJobId ?? id
        let formattedBase = jobIdFormatter.string(from: NSNumber(value: baseId)) ?? "\(baseId)"
        if let arrayTaskId, arrayTaskId >= 0 {
            return "\(formattedBase)_\(arrayTaskId)"
        }
        if let heterogeneousJobOffset, heterogeneousJobOffset >= 0 {
            return "\(formattedBase)+\(heterogeneousJobOffset)"
        }
        return formattedBase
    }

    var displayName: String {
        name.isEmpty ? "(unnamed job)" : name
    }

    var partitionDisplay: String {
        partition.isEmpty ? "—" : partition.uppercased()
    }

    var qosDisplay: String {
        qos.isEmpty ? "Default QoS" : qos
    }

    var stateReasonDisplay: String? {
        let trimmed = stateReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare("none") != .orderedSame else { return nil }
        return trimmed
    }

    var formattedTimeRemaining: String {
        if let seconds = timeRemainingSeconds, seconds > 0 {
            return Self.durationString(for: seconds)
        }

        if isLimitInfinite {
            return "∞"
        }

        return "—"
    }

    var formattedElapsedTime: String {
        if let elapsed = elapsedSeconds, elapsed > 0 {
            return Self.durationString(for: elapsed)
        }
        if let description = rawElapsedDescription, !description.isEmpty {
            return description
        }
        return "—"
    }

    var formattedTimeLimit: String {
        if isLimitInfinite {
            return "∞"
        }
        guard let limitSeconds, limitSeconds > 0 else { return "—" }
        return Self.durationString(for: limitSeconds)
    }

    var nodeSummary: String {
        if !nodes.isEmpty {
            return nodes
        }
        if let nodeCount, nodeCount > 0 {
            return nodeCount == 1 ? "1 node" : "\(nodeCount) nodes"
        }
        return "—"
    }

    var taskSummary: String {
        guard let tasks, tasks > 0 else { return "—" }
        return tasks == 1 ? "1 task" : "\(tasks) tasks"
    }

    var memorySummary: String {
        if let value = requestedTresValues["mem"] ?? requestedTresValues["memory"] {
            return value.uppercased()
        }
        if let memoryPerNodeMB, memoryPerNodeMB > 0 {
            return Self.formatMemory(megabytes: memoryPerNodeMB)
        }
        return "—"
    }

    var workingDirectoryDisplay: String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return trimmed
    }

    var workingDirectoryName: String {
        let path = workingDirectoryDisplay
        guard path != "—" else { return path }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    var submitCommandDisplay: String {
        let trimmed = submitLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return trimmed
    }

    var runtimeSummary: String {
        if displayState == .pending {
            return "Queued"
        }
        if formattedElapsedTime == "—" {
            return "Runtime unavailable"
        }
        return "\(formattedElapsedTime) elapsed"
    }

    var runtimeDetailSummary: String {
        if formattedTimeLimit == "—" {
            return runtimeSummary
        }
        return "\(runtimeSummary) • limit \(formattedTimeLimit)"
    }

    var runtimeFactValue: String {
        if formattedTimeLimit == "—" {
            return formattedElapsedTime
        }
        return "\(formattedElapsedTime) / \(formattedTimeLimit)"
    }

    var runtimeBadgeDisplay: String {
        if displayState == .pending {
            return "Queued"
        }
        if runtimeFactValue != "—" {
            return runtimeFactValue
        }
        return runtimeSummary
    }

    var resourceSummaryDisplay: String {
        var parts: [String] = []
        if cpuSummary != "—" {
            parts.append("\(cpuSummary) CPU")
        }
        if memorySummary != "—" {
            parts.append(memorySummary)
        }
        if gpuSummary != "—" {
            parts.append(gpuSummary)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " • ")
    }

    var folderSummaryDisplay: String {
        workingDirectoryName
    }

    var nodeSummaryDisplay: String {
        if !nodes.isEmpty {
            return nodes
        }
        if let nodeCount, nodeCount > 0 {
            return nodeCount == 1 ? "1 node" : "\(nodeCount) nodes"
        }
        return "—"
    }

    var compactMetadataLine: String {
        var parts = ["#\(formattedId)", partitionDisplay]
        if !qos.isEmpty {
            parts.append(qosDisplay)
        }
        return parts.joined(separator: " • ")
    }

    var resourceLineDisplay: String {
        var parts: [String] = []
        if resourceSummaryDisplay != "—" {
            parts.append(resourceSummaryDisplay)
        }
        if nodeSummaryDisplay != "—" {
            parts.append(nodeSummaryDisplay)
        }
        if taskSummary != "—" {
            parts.append(taskSummary)
        }
        return parts.isEmpty ? "Resource details unavailable" : parts.joined(separator: " • ")
    }

    var pathLineDisplay: String {
        if workingDirectoryDisplay != "—" {
            return workingDirectoryDisplay
        }
        if submitCommandDisplay != "—" {
            return submitCommandDisplay
        }
        return "Working directory unavailable"
    }

    var submittedAtDisplay: String? {
        guard let submitEpoch else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(submitEpoch))
        return Self.timestampFormatter.string(from: date)
    }

    var subtitle: String {
        var parts = ["#\(formattedId)", partitionDisplay]
        if !qos.isEmpty {
            parts.append(qosDisplay)
        }
        return parts.joined(separator: " • ")
    }

    var renderIdentity: String {
        "\(jobSelector)|\(submitEpoch ?? 0)|\(submitLine)|\(workingDirectory)|\(nodes)"
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

    static func normalizedEpoch(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func normalizedCount(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private var requestedTresValues: [String: String] {
        SlurmJob.parseTresString(requestedTres)
    }

    private var allocatedTresValues: [String: String] {
        SlurmJob.parseTresString(allocatedTres)
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

    var gpuSummary: String {
        let allocated = Self.gpuDescriptor(from: allocatedTresValues)
        let requested = Self.gpuDescriptor(from: requestedTresValues)

        if let allocated, !Self.isGenericGPUDescriptor(allocated) {
            return allocated
        }
        if let requested, !Self.isGenericGPUDescriptor(requested) {
            return requested
        }
        if let allocated {
            return allocated
        }
        if let requested {
            return requested
        }
        return "—"
    }

    private static func gpuDescriptor(from tres: [String: String]) -> String? {
        let candidates = tres
            .filter { key, _ in key.lowercased().contains("gpu") }
            .sorted { lhs, rhs in lhs.key < rhs.key }

        for (key, value) in candidates {
            if let descriptor = gpuDescriptor(key: key, value: value) {
                return descriptor
            }
        }

        return nil
    }

    private static func gpuDescriptor(key: String, value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let typeFromKey = key
            .split(separator: ":", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let count = Int(trimmedValue) {
            return formatGPUDescriptor(count: count, type: typeFromKey)
        }

        let parts = trimmedValue
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let last = parts.last, let count = Int(last) {
            let rawType = parts.dropLast().joined(separator: " ")
            return formatGPUDescriptor(count: count, type: rawType.isEmpty ? typeFromKey : rawType)
        }

        if let first = parts.first, let count = Int(first) {
            let rawType = parts.dropFirst().joined(separator: " ")
            return formatGPUDescriptor(count: count, type: rawType.isEmpty ? typeFromKey : rawType)
        }

        return formatGPUDescriptor(count: nil, type: trimmedValue.isEmpty ? typeFromKey : trimmedValue)
    }

    private static func formatGPUDescriptor(count: Int?, type rawType: String?) -> String? {
        let cleanedType = rawType?
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.uppercased() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let count, count > 0 {
            if let cleanedType, !cleanedType.isEmpty {
                return "\(count) \(cleanedType)"
            }
            return "\(count) GPU"
        }

        if let cleanedType, !cleanedType.isEmpty {
            return cleanedType
        }

        return nil
    }

    private static func isGenericGPUDescriptor(_ descriptor: String) -> Bool {
        descriptor == "GPU" || descriptor.hasSuffix(" GPU")
    }

    private static func formatMemory(megabytes: Int) -> String {
        if megabytes >= 1024 {
            let gigabytes = Double(megabytes) / 1024
            if gigabytes.rounded(.towardZero) == gigabytes {
                return "\(Int(gigabytes))G"
            }
            return String(format: "%.1fG", gigabytes)
        }
        return "\(megabytes)M"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
