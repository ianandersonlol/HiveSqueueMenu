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
            username: AppConfig.defaultUsername,
            identityFilePath: nil,
            password: nil
        )
    }
}
