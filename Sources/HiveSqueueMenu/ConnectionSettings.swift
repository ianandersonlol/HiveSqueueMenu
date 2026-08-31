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

enum SSHHostTrustPolicy: String, CaseIterable, Identifiable, Sendable {
    case strict
    case acceptNew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strict:
            return "Verified Hosts Only"
        case .acceptNew:
            return "Trust New Hosts Automatically"
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
    var hostTrustPolicy: SSHHostTrustPolicy
    var accountPassword: String?
    var keyPassphrase: String?
    var remoteCommand: String
}

extension ConnectionSettings {
    static var `default`: ConnectionSettings {
        ConnectionSettings(
            host: AppConfig.clusterHost,
            username: "",
            clusterProfile: .ucDavisHive,
            authentication: .agent,
            hostTrustPolicy: .strict,
            accountPassword: nil,
            keyPassphrase: nil,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    static var empty: ConnectionSettings {
        ConnectionSettings(
            host: "",
            username: "",
            clusterProfile: .standard,
            authentication: .agent,
            hostTrustPolicy: .strict,
            accountPassword: nil,
            keyPassphrase: nil,
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
           accountPassword?.isEmpty != false {
            return "Enter an account password for Password Only authentication."
        }

        if authentication == .passwordOnly, hostTrustPolicy == .acceptNew {
            return "Password Only requires Verified Hosts Only. Verify the host fingerprint and add it to known_hosts before sending an account password."
        }

        if let accountPassword,
           accountPassword.utf8.count > AppConfig.maxCredentialUTF8Bytes {
            return "The account password is too large to pass safely to OpenSSH."
        }

        if let keyPassphrase,
           keyPassphrase.utf8.count > AppConfig.maxCredentialUTF8Bytes {
            return "The private-key passphrase is too large to pass safely to OpenSSH."
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
