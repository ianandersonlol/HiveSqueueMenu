import Foundation

struct ConnectionSettingsDraft: Equatable, Sendable {
    var host: String
    var username: String
    var clusterProfile: ClusterProfile
    var authenticationMode: SSHAuthenticationMode
    var identityFilePath: String
    var hostTrustPolicy: SSHHostTrustPolicy
    var accountPassword: String
    var keyPassphrase: String
    var remoteCommand: String

    init(connection: ConnectionSettings) {
        host = connection.host
        username = connection.username
        clusterProfile = connection.clusterProfile
        authenticationMode = connection.authentication.mode
        identityFilePath = connection.authentication.identityFilePath ?? ""
        hostTrustPolicy = connection.hostTrustPolicy
        accountPassword = connection.accountPassword ?? ""
        keyPassphrase = connection.keyPassphrase ?? ""
        remoteCommand = connection.remoteCommand
    }

    static let empty = ConnectionSettingsDraft(connection: .empty)

    var connectionSettings: ConnectionSettings {
        ConnectionSettings(
            host: host,
            username: username,
            clusterProfile: clusterProfile,
            authentication: authentication,
            hostTrustPolicy: hostTrustPolicy,
            accountPassword: authenticationMode == .passwordOnly ? accountPassword.nonEmpty : nil,
            keyPassphrase: authenticationMode == .key ? keyPassphrase.nonEmpty : nil,
            remoteCommand: remoteCommand
        )
    }

    var accountCredentialIdentity: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUsername.isEmpty else { return nil }
        return "\(trimmedUsername)@\(trimmedHost)"
    }

    var keyCredentialIdentity: String? {
        let trimmed = identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private var authentication: SSHAuthentication {
        switch authenticationMode {
        case .agent:
            return .agent
        case .key:
            return .key(path: identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines))
        case .passwordOnly:
            return .passwordOnly
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
