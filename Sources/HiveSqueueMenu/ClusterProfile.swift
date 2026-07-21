import Foundation

enum ClusterProfile: String, CaseIterable, Identifiable, Sendable {
    case standard
    case ucDavisHive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:
            return "Standard Slurm"
        case .ucDavisHive:
            return "UC Davis HIVE"
        }
    }

    var bootstrap: RemoteBootstrap {
        switch self {
        case .standard:
            return .none
        case .ucDavisHive:
            return RemoteBootstrap(
                moduleInitScript: "/etc/profile.d/modules.sh",
                slurmModule: "slurm",
                moduleCommandPath: "/usr/share/Modules/bin/modulecmd"
            )
        }
    }

    static func inferred(forHost host: String) -> ClusterProfile {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(AppConfig.clusterHost) == .orderedSame ? .ucDavisHive : .standard
    }
}

struct RemoteBootstrap: Equatable, Sendable {
    let moduleInitScript: String?
    let slurmModule: String?
    let moduleCommandPath: String?

    static let none = RemoteBootstrap(
        moduleInitScript: nil,
        slurmModule: nil,
        moduleCommandPath: nil
    )
}
