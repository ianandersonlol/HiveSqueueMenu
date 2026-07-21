import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("SSH process transport")
struct SSHClientTests {
    @Test
    func usesKnownHostsAndAcceptNew() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            /usr/bin/printf '%s\n' "$@"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try SSHClient(connection: connection(), sshPath: executable.path).execute("true")
        #expect(result.succeeded)
        #expect(result.stdoutText.contains("StrictHostKeyChecking=accept-new"))
        #expect(!result.stdoutText.contains("UserKnownHostsFile=/dev/null"))
    }

    @Test
    func askpassReturnsMetacharactersVerbatim() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            exec "$SSH_ASKPASS"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let password = "p$HOME `not-a-command` $(still-data) \\\" '"

        let result = try SSHClient(
            connection: connection(authentication: .passwordOnly, password: password),
            sshPath: executable.path
        ).execute("true")

        #expect(result.succeeded)
        #expect(result.stdoutText == password + "\n")
    }

    @Test
    func drainsLargeStdoutWithoutDeadlocking() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            /usr/bin/head -c 1000000 /dev/zero | /usr/bin/tr '\\0' x
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try SSHClient(
            connection: connection(),
            sshPath: executable.path,
            commandTimeout: 5
        ).execute("true")

        #expect(result.succeeded)
        #expect(result.stdout.count == 1_000_000)
    }

    @Test
    func terminatesCommandsAtTheConfiguredTimeout() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            exec /bin/sleep 2
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try SSHClient(
            connection: connection(),
            sshPath: executable.path,
            commandTimeout: 0.1
        ).execute("true")

        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test
    func cancellationTerminatesTheActiveProcess() async throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            exec /bin/sleep 5
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let cancellationToken = SSHCancellationToken()
        let testConnection = connection()
        let started = Date()

        let task = Task.detached {
            try SSHClient(
                connection: testConnection,
                sshPath: executable.path,
                commandTimeout: 10,
                cancellationToken: cancellationToken
            ).execute("true")
        }
        try await Task.sleep(for: .milliseconds(100))
        cancellationToken.cancel()
        let result = try await task.value

        #expect(!result.succeeded)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    private func connection(
        authentication: SSHAuthentication = .agent,
        password: String? = nil
    ) -> ConnectionSettings {
        ConnectionSettings(
            host: "cluster.example",
            username: "user",
            clusterProfile: .standard,
            authentication: authentication,
            password: password,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    private func makeExecutable(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-ssh")
        try Data(source.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
