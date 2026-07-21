import Darwin
import Foundation

struct SSHCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let timedOut: Bool

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

    init(
        connection: ConnectionSettings,
        sshPath: String = AppConfig.sshPath,
        connectTimeout: TimeInterval = AppConfig.sshConnectTimeout,
        commandTimeout: TimeInterval = AppConfig.sshCommandTimeout,
        cancellationToken: SSHCancellationToken? = nil
    ) {
        self.connection = connection
        self.sshPath = sshPath
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.cancellationToken = cancellationToken
    }

    func execute(_ command: String) throws -> SSHCommandResult {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw SSHClientError.sshUnavailable(sshPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = try makeArguments(for: command)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let stderrHandle = stderr.fileHandleForReading
        let stdoutHandle = stdout.fileHandleForReading
        let stdoutBuffer = ThreadSafeDataBuffer()
        let stderrBuffer = ThreadSafeDataBuffer()
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

        var askPassURL: URL?
        let environment = try makeEnvironment(using: &askPassURL)
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
            if let stdinPipe = process.standardInput as? Pipe {
                stdinPipe.fileHandleForWriting.closeFile()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + commandTimeout,
                execute: timeoutWorkItem
            )
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if let askPassURL {
                try? FileManager.default.removeItem(at: askPassURL)
            }
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

        if let askPassURL {
            try? FileManager.default.removeItem(at: askPassURL)
        }

        timeoutLock.lock()
        let timedOut = timeoutTriggered
        timeoutLock.unlock()

        return SSHCommandResult(
            stdout: stdoutBuffer.snapshot(),
            stderr: stderrBuffer.snapshot(),
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }

    func makeArguments(for command: String) throws -> [String] {
        var arguments: [String] = []

        arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=accept-new"])
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
            if connection.password == nil || connection.password?.isEmpty == true {
                arguments.append(contentsOf: ["-o", "BatchMode=yes"])
            }
        case .passwordOnly:
            arguments.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            arguments.append(contentsOf: ["-o", "PubkeyAuthentication=no"])
            arguments.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
        }

        let destination = "\(connection.trimmedUsername)@\(connection.trimmedHost)"
        arguments.append(destination)
        arguments.append(nonInteractiveCommandWrapper(for: command))
        return arguments
    }

    private func makeEnvironment(using askPassURL: inout URL?) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let shouldUseAskPass: Bool
        switch connection.authentication {
        case .key:
            shouldUseAskPass = connection.password?.isEmpty == false
        case .passwordOnly:
            shouldUseAskPass = connection.password?.isEmpty == false
        case .agent:
            shouldUseAskPass = false
        }

        if shouldUseAskPass, let password = connection.password, !password.isEmpty {
            askPassURL = try generateAskPassScript()
            environment["DISPLAY"] = environment["DISPLAY"] ?? "HiveSqueueMenu"
            environment["SSH_ASKPASS"] = askPassURL?.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment[AppConfig.askPassSecretEnvironmentKey] = password
        }

        return environment
    }

    private func nonInteractiveCommandWrapper(for command: String) -> String {
        var scriptLines: [String] = []
        scriptLines.append("set +e")
        scriptLines.append("status=0")
        scriptLines.append("export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")
        scriptLines.append("export LC_ALL=C")
        let bootstrap = connection.clusterProfile.bootstrap
        if let initScript = bootstrap.moduleInitScript {
            scriptLines.append("if [ -f \(Self.shellSingleQuoted(initScript)) ]; then source \(Self.shellSingleQuoted(initScript)); fi")
        }
        if let slurmModule = bootstrap.slurmModule {
            let quotedModule = Self.shellSingleQuoted(slurmModule)
            var moduleLoader = "if command -v module >/dev/null 2>&1; then module load \(quotedModule);"
            if let moduleCmdPath = bootstrap.moduleCommandPath {
                let quotedModuleCommand = Self.shellSingleQuoted(moduleCmdPath)
                moduleLoader += " elif [ -x \(quotedModuleCommand) ]; then eval \"$(\(quotedModuleCommand) bash load \(quotedModule))\";"
            }
            moduleLoader += " else echo \"Warning: module command not found on remote host\" >&2; fi"
            scriptLines.append("(\(moduleLoader)) || true")
        }
        scriptLines.append("\(command) || status=$?")
        scriptLines.append("echo '[HiveSqueueMenu] Remote command finished with status' \"$status\" >&2")
        scriptLines.append("exit \"$status\"")

        let script = scriptLines.joined(separator: " ; ")
        let sanitized = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        return #"/bin/bash --noprofile --norc -c '"# + sanitized + "'"
    }

    private func generateAskPassScript() throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiveSqueueMenu-askpass-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        exec /usr/bin/printf '%s\\n' "$\(AppConfig.askPassSecretEnvironmentKey)"
        """
        guard let data = script.data(using: .utf8) else {
            throw SSHClientError.unableToLaunch("Unable to encode password for askpass.")
        }
        try data.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
