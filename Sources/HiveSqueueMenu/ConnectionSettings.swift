import Foundation

struct ConnectionSettings: Equatable {
    var host: String
    var username: String
    var identityFilePath: String?
    var password: String?
}

extension ConnectionSettings {
    static var `default`: ConnectionSettings {
        ConnectionSettings(
            host: AppConfig.clusterHost,
            username: "",
            identityFilePath: nil,
            password: nil
        )
    }

    static var empty: ConnectionSettings {
        ConnectionSettings(
            host: "",
            username: "",
            identityFilePath: nil,
            password: nil
        )
    }

    var isConfigured: Bool {
        // Only require host, username, and SSH key - password is optional
        !host.isEmpty && !username.isEmpty && identityFilePath != nil
    }
}
