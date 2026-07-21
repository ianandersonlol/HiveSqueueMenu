import Foundation

enum SSHAuthenticationMode: String, CaseIterable, Identifiable, Sendable {
    case agent
    case key
    case passwordOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent:
            return "SSH Agent"
        case .key:
            return "SSH Key File"
        case .passwordOnly:
            return "Password Only"
        }
    }
}

enum SSHAuthentication: Equatable, Sendable {
    case agent
    case key(path: String)
    case passwordOnly

    var mode: SSHAuthenticationMode {
        switch self {
        case .agent:
            return .agent
        case .key:
            return .key
        case .passwordOnly:
            return .passwordOnly
        }
    }

    var identityFilePath: String? {
        guard case .key(let path) = self else { return nil }
        return path
    }
}

struct ConnectionSettings: Equatable, Sendable {
    var host: String
    var username: String
    var clusterProfile: ClusterProfile
    var authentication: SSHAuthentication
    var password: String?
    var remoteCommand: String
}

extension ConnectionSettings {
    static var `default`: ConnectionSettings {
        ConnectionSettings(
            host: AppConfig.clusterHost,
            username: "",
            clusterProfile: .ucDavisHive,
            authentication: .agent,
            password: nil,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    static var empty: ConnectionSettings {
        ConnectionSettings(
            host: "",
            username: "",
            clusterProfile: .standard,
            authentication: .agent,
            password: nil,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    var isConfigured: Bool {
        !trimmedHost.isEmpty && !trimmedUsername.isEmpty
    }

    var configurationIssue: String? {
        if !isConfigured {
            return "Enter a host and username before connecting."
        }

        if case .key(let path) = authentication,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Select an SSH key file or switch to SSH Agent / Password Only."
        }

        if authentication == .passwordOnly,
           password?.isEmpty != false {
            return "Enter a password for Password Only authentication."
        }

        return nil
    }

    var resolvedRemoteCommand: String {
        let trimmed = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConfig.remoteCommand : trimmed
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
