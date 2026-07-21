import Foundation

enum JobState: Equatable, Sendable {
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
        case "BF", "BOOT_FAIL", "DL", "DEADLINE", "F", "FAILED", "NF", "NODE_FAIL", "OOM", "OUT_OF_MEMORY", "TO", "TIMEOUT":
            self = .failed
        case "CA", "CANCELLED", "PR", "PREEMPTED", "RV", "REVOKED":
            self = .cancelled
        case "CF", "CONFIGURING":
            self = .configuring
        case "RQ", "REQUEUED", "RH", "REQUEUE_HOLD":
            self = .pending
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
