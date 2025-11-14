import XCTest
@testable import HiveSqueueMenu

final class SSHKeyLibraryTests: XCTestCase {
    func testAvailableKeys_WhenSSHDirectoryIsMissing_ReturnsEmptyArray() {
        // Given
        let fileManager = FileManager.default
        let sshDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let backupSSHDirectory = sshDirectory.appendingPathExtension("backup")

        // When
        if fileManager.fileExists(atPath: sshDirectory.path) {
            try? fileManager.moveItem(at: sshDirectory, to: backupSSHDirectory)
        }

        let keys = SSHKeyLibrary.availableKeys()

        // Then
        XCTAssertTrue(keys.isEmpty)

        // Teardown
        if fileManager.fileExists(atPath: backupSSHDirectory.path) {
            try? fileManager.moveItem(at: backupSSHDirectory, to: sshDirectory)
        }
    }
}
