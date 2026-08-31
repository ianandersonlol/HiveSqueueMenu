import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("SSH process transport")
struct SSHClientTests {
    @Test
    func acceptNewPolicyUsesKnownHostsWithoutDisablingVerification() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            /usr/bin/printf '%s\n' "$@"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let isolatedKnownHosts = executable.deletingLastPathComponent()
            .appendingPathComponent("tofu", isDirectory: true)
            .appendingPathComponent("known_hosts")

        let result = try SSHClient(
            connection: connection(hostTrustPolicy: .acceptNew),
            sshPath: executable.path,
            acceptNewKnownHostsURL: isolatedKnownHosts
        ).execute("true")
        #expect(result.succeeded)
        #expect(result.stdoutText.contains("StrictHostKeyChecking=accept-new"))
        #expect(result.stdoutText.contains("UserKnownHostsFile=\(isolatedKnownHosts.path)"))
        #expect(!result.stdoutText.contains("UserKnownHostsFile=/dev/null"))
        #expect(FileManager.default.fileExists(atPath: isolatedKnownHosts.path))
    }

    @Test
    func strictHostVerificationIsTheDefault() throws {
        let arguments = try SSHClient(connection: connection()).makeArguments()
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(!arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.contains("UserKnownHostsFile=~/.ssh/known_hosts"))
    }

    @Test
    func passwordOnlyRejectsTrustOnFirstUse() {
        let unverified = connection(
            authentication: .passwordOnly,
            hostTrustPolicy: .acceptNew,
            accountPassword: "account-secret"
        )

        #expect(unverified.configurationIssue?.contains("Verified Hosts Only") == true)
        do {
            _ = try SSHClient(connection: unverified).makeArguments()
            Issue.record("Expected Password Only with accept-new to be rejected")
        } catch let error as SSHClientError {
            #expect(error.localizedDescription.contains("Verified Hosts Only"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func preservesExistingRemotePathEntries() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            executable_directory="$(/usr/bin/dirname "$0")"
            export PATH="$executable_directory/custom-bin:/usr/bin:/bin"
            exec /bin/bash --noprofile --norc -s
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let customBin = directory.appendingPathComponent("custom-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: customBin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            /usr/bin/printf 'found-on-original-path\n'
            """,
            to: customBin.appendingPathComponent("path-only-command")
        )

        let result = try SSHClient(connection: connection(), sshPath: executable.path)
            .execute("path-only-command")

        #expect(result.succeeded)
        #expect(result.stdoutText == "found-on-original-path\n")
    }

    @Test
    func loadedModuleEnvironmentPersistsForRemoteCommand() throws {
        let executable = try makeExecutable(
            """
            #!/bin/bash
            executable_directory="$(/usr/bin/dirname "$0")"
            export HIVE_TEST_MODULE_BIN="$executable_directory/module-bin"
            module() {
                if [ "$1" != "load" ] || [ "$2" != "slurm" ]; then
                    return 64
                fi
                export PATH="$HIVE_TEST_MODULE_BIN:$PATH"
            }
            export -f module
            exec /bin/bash --noprofile --norc -s
            """
        )
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleBin = directory.appendingPathComponent("module-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleBin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            /usr/bin/printf 'found-after-module-load\n'
            """,
            to: moduleBin.appendingPathComponent("module-only-command")
        )

        let result = try SSHClient(
            connection: connection(clusterProfile: .ucDavisHive),
            sshPath: executable.path
        ).execute("module-only-command")

        #expect(result.succeeded)
        #expect(result.stdoutText == "found-after-module-load\n")
    }

    @Test
    func moduleLoadFailureStopsBeforeRemoteCommand() throws {
        let executable = try makeExecutable(
            """
            #!/bin/bash
            module() { return 42; }
            export -f module
            exec /bin/bash --noprofile --norc -s
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try SSHClient(
            connection: connection(clusterProfile: .ucDavisHive),
            sshPath: executable.path
        ).execute("echo command-should-not-run")

        #expect(result.terminationStatus == 42)
        #expect(result.stdoutText.isEmpty)
        #expect(result.stderrText.contains("failed to load the configured Slurm module"))
    }

    @Test
    func transportsBackslashesWithoutNestedShellCorruption() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            exec /bin/bash --noprofile --norc -s
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = #"/usr/bin/printf '%s\n' '\d+\s+\$HOME\\path'"#

        let result = try SSHClient(connection: connection(), sshPath: executable.path)
            .execute(command)

        #expect(result.succeeded)
        #expect(result.stdoutText == #"\d+\s+\$HOME\\path"# + "\n")
    }

    @Test
    func askpassReturnsMetacharactersVerbatim() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            if [ "${HIVESQUEUE_ASKPASS_SECRET+x}" = x ]; then
                exit 91
            fi
            if [ ! -p "$HIVESQUEUE_ASKPASS_FIFO" ]; then
                exit 92
            fi
            exec "$SSH_ASKPASS" "Password:"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let password = "p$HOME `not-a-command` $(still-data) \\\" '"

        let result = try SSHClient(
            connection: connection(authentication: .passwordOnly, accountPassword: password),
            sshPath: executable.path
        ).execute("true")

        #expect(result.succeeded)
        #expect(result.stdoutText == password + "\n")
    }

    @Test
    func keyAskpassCanServeRepeatedPromptsFromTheProtectedFIFO() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            if [ "${HIVESQUEUE_ASKPASS_SECRET+x}" = x ]; then
                exit 91
            fi
            "$SSH_ASKPASS" "Enter passphrase for key '/tmp/id_test':" || exit $?
            exec "$SSH_ASKPASS" "Enter passphrase for key '/tmp/id_test':"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let passphrase = "local-$HOME-$(not-a-command)"

        let result = try SSHClient(
            connection: connection(
                authentication: .key(path: "/tmp/id_test"),
                keyPassphrase: passphrase
            ),
            sshPath: executable.path
        ).execute("true")

        #expect(result.succeeded)
        #expect(result.stdoutText == passphrase + "\n" + passphrase + "\n")
    }

    @Test
    func keyModeCannotFallBackToRemotePasswordAuthentication() throws {
        let arguments = try SSHClient(
            connection: connection(
                authentication: .key(path: "/tmp/id_test"),
                keyPassphrase: "local-passphrase"
            )
        ).makeArguments()

        #expect(arguments.contains("PreferredAuthentications=publickey"))
        #expect(arguments.contains("PasswordAuthentication=no"))
        #expect(arguments.contains("KbdInteractiveAuthentication=no"))
        #expect(arguments.contains("BatchMode=no"))
        #expect(!arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
    }

    @Test
    func passwordModeOverridesUserBatchMode() throws {
        let arguments = try SSHClient(
            connection: connection(
                authentication: .passwordOnly,
                accountPassword: "account-secret"
            )
        ).makeArguments()

        #expect(arguments.contains("BatchMode=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
    }

    @Test
    func keyAskpassRejectsPasswordPrompts() throws {
        let executable = try makeExecutable(
            """
            #!/bin/sh
            exec "$SSH_ASKPASS" "Password:"
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try SSHClient(
            connection: connection(
                authentication: .key(path: "/tmp/id_test"),
                keyPassphrase: "must-stay-local"
            ),
            sshPath: executable.path
        ).execute("true")

        #expect(!result.succeeded)
        #expect(!result.stdoutText.contains("must-stay-local"))
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
    func captureBufferRetainsOnlyItsConfiguredLimit() {
        let buffer = ThreadSafeDataBuffer(maxBytes: 4)
        buffer.append(Data("abcdef".utf8))

        #expect(String(decoding: buffer.snapshot(), as: UTF8.self) == "abcd")
        #expect(buffer.wasTruncated)
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
        clusterProfile: ClusterProfile = .standard,
        authentication: SSHAuthentication = .agent,
        hostTrustPolicy: SSHHostTrustPolicy = .strict,
        accountPassword: String? = nil,
        keyPassphrase: String? = nil
    ) -> ConnectionSettings {
        ConnectionSettings(
            host: "cluster.example",
            username: "user",
            clusterProfile: clusterProfile,
            authentication: authentication,
            hostTrustPolicy: hostTrustPolicy,
            accountPassword: accountPassword,
            keyPassphrase: keyPassphrase,
            remoteCommand: AppConfig.remoteCommand
        )
    }

    private func makeExecutable(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-ssh")
        try writeExecutable(source, to: executable)
        return executable
    }

    private func writeExecutable(_ source: String, to executable: URL) throws {
        try Data(source.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
    }
}
