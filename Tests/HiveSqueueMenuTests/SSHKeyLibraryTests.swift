import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("SSH key discovery")
struct SSHKeyLibraryTests {
    @Test
    func missingSSHDirectoryReturnsNoKeys() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(SSHKeyLibrary.availableKeys(in: directory).isEmpty)
    }

    @Test
    func onlyPrivateKeyFilesAreReturned() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let files: [String: String] = [
            "id_ed25519": "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture",
            "id_ed25519.pub": "ssh-ed25519 public",
            "id_rsa": "-----BEGIN RSA PRIVATE KEY-----\nfixture",
            "known_hosts": "example.invalid ssh-ed25519 fixture",
            "config": "Host example.invalid",
            "environment": "NOT_A_PRIVATE_KEY=1"
        ]

        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }

        let keys = SSHKeyLibrary.availableKeys(in: directory)
        #expect(keys.map(\.name) == ["id_ed25519", "id_rsa"])
    }
}
