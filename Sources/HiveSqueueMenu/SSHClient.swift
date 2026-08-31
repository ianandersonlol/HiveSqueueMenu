import Darwin
import Foundation

struct SSHCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let timedOut: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    init(
        stdout: Data,
        stderr: Data,
        terminationStatus: Int32,
        timedOut: Bool,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    var succeeded: Bool {
        terminationStatus == 0 && !timedOut
    }

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

struct SSHClient {
    let connection: ConnectionSettings
    private let sshPath: String
    private let connectTimeout: TimeInterval
    private let commandTimeout: TimeInterval
    private let cancellationToken: SSHCancellationToken?
    private let acceptNewKnownHostsURL: URL

    init(
        connection: ConnectionSettings,
        sshPath: String = AppConfig.sshPath,
        connectTimeout: TimeInterval = AppConfig.sshConnectTimeout,
        commandTimeout: TimeInterval = AppConfig.sshCommandTimeout,
        cancellationToken: SSHCancellationToken? = nil,
        acceptNewKnownHostsURL: URL? = nil
    ) {
        self.connection = connection
        self.sshPath = sshPath
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.cancellationToken = cancellationToken
        self.acceptNewKnownHostsURL = acceptNewKnownHostsURL ?? Self.defaultAcceptNewKnownHostsURL
    }

    func execute(_ command: String) throws -> SSHCommandResult {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw SSHClientError.sshUnavailable(sshPath)
        }
        let arguments = try makeArguments()
        try prepareAcceptNewKnownHostsStoreIfNeeded()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let stderrHandle = stderr.fileHandleForReading
        let stdoutHandle = stdout.fileHandleForReading
        let stdoutBuffer = ThreadSafeDataBuffer(maxBytes: AppConfig.maxSSHStdoutBytes)
        let stderrBuffer = ThreadSafeDataBuffer(maxBytes: AppConfig.maxSSHStderrBytes)
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutBuffer.append(chunk)
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
        }

        var askPassContext: AskPassContext?
        let environment = try makeEnvironment(using: &askPassContext)
        if !environment.isEmpty {
            process.environment = environment
        }

        let timeoutLock = NSLock()
        var timeoutTriggered = false
        let timeoutWorkItem = DispatchWorkItem {
            guard process.isRunning else { return }
            timeoutLock.lock()
            timeoutTriggered = true
            timeoutLock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        do {
            try process.run()
            cancellationToken?.register(process)
            DispatchQueue.global().asyncAfter(
                deadline: .now() + commandTimeout,
                execute: timeoutWorkItem
            )
            if let stdinPipe = process.standardInput as? Pipe {
                stdinPipe.fileHandleForWriting.write(Data(nonInteractiveCommandScript(for: command).utf8))
                stdinPipe.fileHandleForWriting.closeFile()
            }
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            askPassContext?.cleanup()
            throw SSHClientError.unableToLaunch(error.localizedDescription)
        }

        process.waitUntilExit()
        cancellationToken?.clear(process)
        timeoutWorkItem.cancel()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
        }
        let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
        }

        askPassContext?.cleanup()

        timeoutLock.lock()
        let timedOut = timeoutTriggered
        timeoutLock.unlock()

        return SSHCommandResult(
            stdout: stdoutBuffer.snapshot(),
            stderr: stderrBuffer.snapshot(),
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            stdoutTruncated: stdoutBuffer.wasTruncated,
            stderrTruncated: stderrBuffer.wasTruncated
        )
    }

    func makeArguments() throws -> [String] {
        var arguments: [String] = []

        switch connection.hostTrustPolicy {
        case .strict:
            arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=yes"])
            arguments.append(contentsOf: ["-o", "UserKnownHostsFile=~/.ssh/known_hosts"])
        case .acceptNew:
            arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=accept-new"])
            arguments.append(contentsOf: [
                "-o",
                "UserKnownHostsFile=\(acceptNewKnownHostsURL.path)"
            ])
        }
        arguments.append(contentsOf: ["-o", "ConnectTimeout=\(Int(connectTimeout))"])
        arguments.append("-T")

        switch connection.authentication {
        case .agent:
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        case .key(let path):
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                throw SSHClientError.invalidConfiguration("SSH key mode is selected, but no key path is set.")
            }
            arguments.append(contentsOf: ["-i", trimmedPath.expandingTilde])
            arguments.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
            arguments.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
            arguments.append(contentsOf: ["-o", "PasswordAuthentication=no"])
            arguments.append(contentsOf: ["-o", "KbdInteractiveAuthentication=no"])
            if connection.keyPassphrase == nil || connection.keyPassphrase?.isEmpty == true {
                arguments.append(contentsOf: ["-o", "BatchMode=yes"])
            } else {
                arguments.append(contentsOf: ["-o", "BatchMode=no"])
            }
        case .passwordOnly:
            guard connection.hostTrustPolicy == .strict else {
                throw SSHClientError.invalidConfiguration(
                    "Password Only requires Verified Hosts Only so an account password is never sent on an unverified first connection."
                )
            }
            arguments.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            arguments.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
            arguments.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
            arguments.append(contentsOf: ["-o", "BatchMode=no"])
        }

        let destination = "\(connection.trimmedUsername)@\(connection.trimmedHost)"
        arguments.append(destination)
        arguments.append(contentsOf: ["/bin/bash", "--noprofile", "--norc", "-s"])
        return arguments
    }

    private func makeEnvironment(using askPassContext: inout AskPassContext?) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "HIVESQUEUE_ASKPASS_SECRET")

        let secret: String?
        let askPassKind: AskPassKind?
        switch connection.authentication {
        case .key:
            secret = connection.keyPassphrase
            askPassKind = .keyPassphrase
        case .passwordOnly:
            secret = connection.accountPassword
            askPassKind = .accountPassword
        case .agent:
            secret = nil
            askPassKind = nil
        }

        if let secret, !secret.isEmpty, let askPassKind {
            let context = try generateAskPassContext(kind: askPassKind, secret: secret)
            askPassContext = context
            environment["DISPLAY"] = environment["DISPLAY"] ?? "HiveSqueueMenu"
            environment["SSH_ASKPASS"] = context.scriptURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["LC_ALL"] = "C"
            environment[AskPassContext.fifoEnvironmentKey] = context.fifoURL.path
            environment[AskPassContext.lengthEnvironmentKey] = String(secret.utf8.count)
        }

        return environment
    }

    private func nonInteractiveCommandScript(for command: String) -> String {
        var scriptLines: [String] = []
        scriptLines.append("set +e")
        scriptLines.append("status=0")
        scriptLines.append(#"export PATH="${PATH:+$PATH:}/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin""#)
        scriptLines.append("export LC_ALL=C")
        let bootstrap = connection.clusterProfile.bootstrap
        if let initScript = bootstrap.moduleInitScript {
            let quotedInitScript = Self.shellSingleQuoted(initScript)
            scriptLines.append(
                """
                if [ -f \(quotedInitScript) ]; then
                    source \(quotedInitScript)
                    bootstrap_status=$?
                    if [ "$bootstrap_status" -ne 0 ]; then
                        echo "Error: failed to initialize the remote module environment" >&2
                        exit "$bootstrap_status"
                    fi
                fi
                """
            )
        }
        if let slurmModule = bootstrap.slurmModule {
            let quotedModule = Self.shellSingleQuoted(slurmModule)
            var moduleLoader = """
            if command -v module >/dev/null 2>&1; then
                module load \(quotedModule)
                bootstrap_status=$?
            """
            if let moduleCmdPath = bootstrap.moduleCommandPath {
                let quotedModuleCommand = Self.shellSingleQuoted(moduleCmdPath)
                moduleLoader += """

                elif [ -x \(quotedModuleCommand) ]; then
                    module_commands="$(\(quotedModuleCommand) bash load \(quotedModule))"
                    bootstrap_status=$?
                    if [ "$bootstrap_status" -eq 0 ]; then
                        eval "$module_commands"
                        bootstrap_status=$?
                    fi
                """
            }
            moduleLoader += """

            else
                echo "Error: module command not found on remote host" >&2
                exit 127
            fi
            if [ "$bootstrap_status" -ne 0 ]; then
                echo "Error: failed to load the configured Slurm module" >&2
                exit "$bootstrap_status"
            fi
            """
            scriptLines.append(moduleLoader)
        }
        scriptLines.append(command)
        scriptLines.append("status=$?")
        scriptLines.append("echo '[HiveSqueueMenu] Remote command finished with status' \"$status\" >&2")
        scriptLines.append("exit \"$status\"")

        return scriptLines.joined(separator: "\n") + "\n"
    }

    private func generateAskPassContext(kind: AskPassKind, secret: String) throws -> AskPassContext {
        let secretData = Data(secret.utf8)
        guard secretData.count <= AppConfig.maxCredentialUTF8Bytes else {
            throw SSHClientError.invalidConfiguration("The SSH credential exceeds the supported size limit.")
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiveSqueueMenu-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var shouldRemoveDirectory = true
        defer {
            if shouldRemoveDirectory {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        let scriptURL = directoryURL.appendingPathComponent("askpass")
        let fifoURL = directoryURL.appendingPathComponent("secret")
        let fifoStatus = fifoURL.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoStatus == 0 else {
            throw SSHClientError.unableToLaunch(
                "Unable to create the protected askpass channel: \(Self.currentPOSIXError())."
            )
        }

        let fifoDescriptor = fifoURL.path.withCString {
            Darwin.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        }
        guard fifoDescriptor >= 0 else {
            throw SSHClientError.unableToLaunch(
                "Unable to open the protected askpass channel: \(Self.currentPOSIXError())."
            )
        }
        var shouldCloseFIFO = true
        defer {
            if shouldCloseFIFO {
                _ = Darwin.close(fifoDescriptor)
            }
        }

        var preparedResponses = 0
        for _ in 0..<AskPassContext.maximumPromptResponses {
            let written = secretData.withUnsafeBytes { bytes in
                Darwin.write(fifoDescriptor, bytes.baseAddress, bytes.count)
            }
            guard written == secretData.count else { break }
            preparedResponses += 1
        }
        guard preparedResponses >= 2 else {
            throw SSHClientError.unableToLaunch(
                "Unable to prepare enough protected askpass responses."
            )
        }

        let acceptedPrompt: String
        switch kind {
        case .keyPassphrase:
            acceptedPrompt = "*[Pp]assphrase*"
        case .accountPassword:
            acceptedPrompt = "*[Pp]assword*"
        }
        let script = """
        #!/bin/sh
        case "${1:-}" in
          \(acceptedPrompt))
            secret_length="${\(AskPassContext.lengthEnvironmentKey):-}"
            case "$secret_length" in
              ''|*[!0-9]*) exit 1 ;;
            esac
            /bin/dd if="$\(AskPassContext.fifoEnvironmentKey)" bs=1 count="$secret_length" 2>/dev/null || exit 1
            exec /usr/bin/printf '\\n'
            ;;
          *) exit 1 ;;
        esac
        """
        guard let data = script.data(using: .utf8) else {
            throw SSHClientError.unableToLaunch("Unable to encode password for askpass.")
        }
        try data.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)
        shouldCloseFIFO = false
        shouldRemoveDirectory = false
        return AskPassContext(
            directoryURL: directoryURL,
            scriptURL: scriptURL,
            fifoURL: fifoURL,
            fifoDescriptor: fifoDescriptor
        )
    }

    private static func currentPOSIXError() -> String {
        String(cString: strerror(errno))
    }

    private func prepareAcceptNewKnownHostsStoreIfNeeded() throws {
        guard connection.hostTrustPolicy == .acceptNew else { return }
        let directory = acceptNewKnownHostsURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )

            if !FileManager.default.fileExists(atPath: acceptNewKnownHostsURL.path) {
                guard FileManager.default.createFile(
                    atPath: acceptNewKnownHostsURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
                ) else {
                    throw SSHClientError.unableToLaunch(
                        "Unable to create the isolated trust-on-first-use host-key store."
                    )
                }
            }

            let attributes = try FileManager.default.attributesOfItem(
                atPath: acceptNewKnownHostsURL.path
            )
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw SSHClientError.unableToLaunch(
                    "The isolated trust-on-first-use host-key store is not a regular file."
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: acceptNewKnownHostsURL.path
            )
        } catch {
            if let sshError = error as? SSHClientError {
                throw sshError
            }
            throw SSHClientError.unableToLaunch(
                "Unable to prepare the isolated trust-on-first-use host-key store: \(error.localizedDescription)"
            )
        }
    }

    private static var defaultAcceptNewKnownHostsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hivesqueuemenu", isDirectory: true)
            .appendingPathComponent("known_hosts.accept-new")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum AskPassKind {
    case keyPassphrase
    case accountPassword
}

private final class AskPassContext {
    static let fifoEnvironmentKey = "HIVESQUEUE_ASKPASS_FIFO"
    static let lengthEnvironmentKey = "HIVESQUEUE_ASKPASS_LENGTH"
    static let maximumPromptResponses = 4

    let directoryURL: URL
    let scriptURL: URL
    let fifoURL: URL

    private let lock = NSLock()
    private var fifoDescriptor: Int32

    init(directoryURL: URL, scriptURL: URL, fifoURL: URL, fifoDescriptor: Int32) {
        self.directoryURL = directoryURL
        self.scriptURL = scriptURL
        self.fifoURL = fifoURL
        self.fifoDescriptor = fifoDescriptor
    }

    func cleanup() {
        lock.lock()
        let descriptor = fifoDescriptor
        fifoDescriptor = -1
        lock.unlock()

        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    deinit {
        cleanup()
    }
}

final class SSHCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancellationRequested = false
    private weak var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancellationRequested
    }

    func register(_ process: Process) {
        lock.lock()
        if isCancellationRequested {
            lock.unlock()
            Self.terminate(process)
            return
        }
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancellationRequested = true
        let activeProcess = process
        lock.unlock()
        if let activeProcess {
            Self.terminate(activeProcess)
        }
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

enum SSHClientError: LocalizedError {
    case sshUnavailable(String)
    case unableToLaunch(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .sshUnavailable(let path):
            return "SSH client missing at \(path)."
        case .unableToLaunch(let reason):
            return "Unable to launch ssh: \(reason)"
        case .invalidConfiguration(let message):
            return message
        }
    }
}

final class ThreadSafeDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var storage = Data()
    private var truncated = false

    init(maxBytes: Int = .max) {
        self.maxBytes = max(maxBytes, 0)
    }

    func append(_ chunk: Data) {
        lock.lock()
        let remaining = max(maxBytes - storage.count, 0)
        if chunk.count > remaining {
            truncated = true
        }
        if remaining > 0 {
            storage.append(chunk.prefix(remaining))
        }
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }

    var wasTruncated: Bool {
        lock.lock()
        let value = truncated
        lock.unlock()
        return value
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
