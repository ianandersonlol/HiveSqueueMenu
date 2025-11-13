import Foundation

struct SSHKeyOption: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String

    init(path: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.id = path
    }
}

enum SSHKeyLibrary {
    static func availableKeys() -> [SSHKeyOption] {
        let fileManager = FileManager.default
        let sshDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: sshDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let ignoredNames: Set<String> = ["known_hosts", "config", "authorized_keys", "authorized_keys2"]

        let options = contents.compactMap { url -> SSHKeyOption? in
            guard ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false) else {
                return nil
            }
            let name = url.lastPathComponent
            if ignoredNames.contains(name) || name.hasSuffix(".pub") {
                return nil
            }
            return SSHKeyOption(path: url.path)
        }

        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
