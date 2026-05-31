import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct HimalayaCommand: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]
    public var standardInput: Data?

    public init(
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
    }
}

public struct HimalayaResult: Equatable, Sendable {
    public var command: HimalayaCommand
    public var exitCode: Int32
    public var stdoutData: Data
    public var stderrData: Data
    public var duration: TimeInterval

    public init(
        command: HimalayaCommand,
        exitCode: Int32,
        stdoutData: Data,
        stderrData: Data,
        duration: TimeInterval
    ) {
        self.command = command
        self.exitCode = exitCode
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.duration = duration
    }

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public func requireSuccess() throws -> HimalayaResult {
        guard succeeded else {
            throw HimalayaError.nonZeroExit(self)
        }
        return self
    }

    public func decodeJSON<T: Decodable>(
        as type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: stdoutData)
        } catch {
            throw HimalayaError.jsonDecodeFailed(message: error.localizedDescription, stdout: stdout)
        }
    }
}

public enum HimalayaError: LocalizedError, Equatable, Sendable {
    case invalidTimeout(TimeInterval)
    case launchFailed(String)
    case timedOut(command: HimalayaCommand, timeout: TimeInterval, stdout: String, stderr: String)
    case nonZeroExit(HimalayaResult)
    case jsonDecodeFailed(message: String, stdout: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTimeout(timeout):
            "Invalid Himalaya timeout: \(timeout)."
        case let .launchFailed(message):
            "Unable to launch Himalaya: \(message)"
        case let .timedOut(command, timeout, stdout, stderr):
            "Himalaya timed out after \(timeout)s while running \(command.arguments.joined(separator: " ")). \(Self.outputDescription(stdout: stdout, stderr: stderr))"
        case let .nonZeroExit(result):
            "Himalaya exited with status \(result.exitCode) while running \(result.command.arguments.joined(separator: " ")). \(Self.outputDescription(stdout: result.stdout, stderr: result.stderr))"
        case let .jsonDecodeFailed(message, stdout):
            "Unable to decode Himalaya JSON: \(message). Output: \(stdout)"
        }
    }

    private static func outputDescription(stdout: String, stderr: String) -> String {
        let output = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return output.map { "Output: \($0)" } ?? "No output was captured."
    }
}

public protocol HimalayaBridge: Sendable {
    func run(_ command: HimalayaCommand, timeout: TimeInterval?) async throws -> HimalayaResult
}

public extension HimalayaBridge {
    func run(_ command: HimalayaCommand) async throws -> HimalayaResult {
        try await run(command, timeout: nil)
    }
}

public struct ProcessHimalayaBridge: HimalayaBridge {
    public var executableURL: URL
    public var environment: [String: String]
    public var workingDirectoryURL: URL?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
    }

    public func run(_ command: HimalayaCommand, timeout: TimeInterval? = nil) async throws -> HimalayaResult {
        let executableURL = executableURL
        let environment = environment
        let workingDirectoryURL = workingDirectoryURL
        let cancellation = ProcessCancellation()

        let task = Task.detached {
            try Self.runSynchronously(
                command,
                executableURL: executableURL,
                environment: environment,
                workingDirectoryURL: workingDirectoryURL,
                timeout: timeout,
                cancellation: command.allowsProcessCancellation ? cancellation : nil
            )
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if command.allowsProcessCancellation {
                cancellation.cancel()
            }
        }
    }

    private static func runSynchronously(
        _ command: HimalayaCommand,
        executableURL: URL,
        environment bridgeEnvironment: [String: String],
        workingDirectoryURL: URL?,
        timeout: TimeInterval?,
        cancellation: ProcessCancellation?
    ) throws -> HimalayaResult {
        if let timeout, timeout <= 0 {
            throw HimalayaError.invalidTimeout(timeout)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = executableURL.lastPathComponent == "env"
            ? ["himalaya"] + command.arguments
            : command.arguments
        process.currentDirectoryURL = workingDirectoryURL

        var environment = ProcessInfo.processInfo.environment
        environment.merge(bridgeEnvironment) { _, new in new }
        environment.merge(command.environment) { _, new in new }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var standardInputPipe: Pipe?
        if command.standardInput != nil {
            let stdinPipe = Pipe()
            standardInputPipe = stdinPipe
            process.standardInput = stdinPipe
        }

        let startedAt = Date()
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
            cancellation?.setProcess(process)
        } catch {
            throw HimalayaError.launchFailed(error.localizedDescription)
        }

        let stdoutReader = PipeDataReader()
        let stderrReader = PipeDataReader()
        stdoutReader.start(reading: stdoutPipe.fileHandleForReading)
        stderrReader.start(reading: stderrPipe.fileHandleForReading)

        if let standardInput = command.standardInput, let standardInputPipe {
            standardInputPipe.fileHandleForWriting.write(standardInput)
            try? standardInputPipe.fileHandleForWriting.close()
        }

        if let timeout {
            let waitResult = termination.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                process.terminate()

                #if canImport(Darwin)
                if termination.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = termination.wait(timeout: .now() + 1)
                }
                #else
                _ = termination.wait(timeout: .now() + 1)
                #endif

                let stdoutData = stdoutReader.waitForData()
                let stderrData = stderrReader.waitForData()
                throw HimalayaError.timedOut(
                    command: command,
                    timeout: timeout,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )
            }
        } else {
            termination.wait()
        }

        let stdoutData = stdoutReader.waitForData()
        let stderrData = stderrReader.waitForData()

        return HimalayaResult(
            command: command,
            exitCode: process.terminationStatus,
            stdoutData: stdoutData,
            stderrData: stderrData,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func setProcess(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        if isCancelled, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

private final class PipeDataReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    func start(reading fileHandle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let output = fileHandle.readDataToEndOfFile()
            lock.lock()
            data = output
            lock.unlock()
            group.leave()
        }
    }

    func waitForData() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private extension HimalayaCommand {
    var allowsProcessCancellation: Bool {
        let commandArguments = arguments.filter { argument in
            argument != "--output" && argument != "json" && argument != "--quiet"
        }
        guard let command = commandArguments.first else {
            return false
        }

        switch command {
        case "account", "folder", "envelope":
            return true
        case "message":
            guard commandArguments.count > 1 else { return false }
            return commandArguments[1] == "read" || commandArguments[1] == "export"
        default:
            return false
        }
    }
}

public extension HimalayaCommand {
    static func accountList() -> HimalayaCommand {
        HimalayaCommand(arguments: jsonArguments(["account", "list"]))
    }

    static func folderList(account: String? = nil) -> HimalayaCommand {
        HimalayaCommand(arguments: jsonArguments(["folder", "list"] + accountArguments(account)))
    }

    static func envelopeList(
        folder: String = "INBOX",
        account: String? = nil,
        query: String? = nil,
        page: Int = 1,
        pageSize: Int? = nil
    ) -> HimalayaCommand {
        var arguments = ["envelope", "list", "--folder", folder, "--page", String(page)]
        if let pageSize {
            arguments += ["--page-size", String(pageSize)]
        }
        arguments += accountArguments(account)
        if let query, !query.isEmpty {
            arguments += query.split(separator: " ").map(String.init)
        }
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func messageReadPreview(
        id: String,
        folder: String = "INBOX",
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["message", "read", "--preview", "--folder", folder]
        arguments += accountArguments(account)
        arguments.append(id)
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func flagSeen(
        id: String,
        folder: String = "INBOX",
        account: String? = nil
    ) -> HimalayaCommand {
        flagAdd(id: id, flag: "seen", folder: folder, account: account)
    }

    static func flagAdd(
        id: String,
        flag: String,
        folder: String = "INBOX",
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["flag", "add", "--folder", folder]
        arguments += accountArguments(account)
        arguments += [id, flag]
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func flagRemove(
        id: String,
        flag: String,
        folder: String = "INBOX",
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["flag", "remove", "--folder", folder]
        arguments += accountArguments(account)
        arguments += [id, flag]
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func messageMove(
        id: String,
        from sourceFolder: String = "INBOX",
        to targetFolder: String,
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["message", "move", "--folder", sourceFolder]
        arguments += accountArguments(account)
        arguments += [targetFolder, id]
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func messageExport(
        id: String,
        folder: String = "INBOX",
        account: String? = nil,
        destination: URL
    ) -> HimalayaCommand {
        var arguments = ["message", "export", "--folder", folder, "--destination", destination.path]
        arguments += accountArguments(account)
        arguments.append(id)
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func attachmentDownload(
        messageID: String,
        folder: String = "INBOX",
        account: String? = nil,
        downloadsDirectory: URL? = nil
    ) -> HimalayaCommand {
        var arguments = ["attachment", "download", "--folder", folder]
        arguments += accountArguments(account)
        if let downloadsDirectory {
            arguments += ["--downloads-dir", downloadsDirectory.path]
        }
        arguments.append(messageID)
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func templateReply(
        id: String,
        body: String,
        folder: String = "INBOX",
        account: String? = nil,
        replyAll: Bool = false
    ) -> HimalayaCommand {
        var arguments = ["template", "reply", "--folder", folder]
        if replyAll {
            arguments.append("--all")
        }
        arguments += accountArguments(account)
        arguments += [id, body]
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func templateWrite(
        body: String,
        headers: [String],
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["template", "write"]
        for header in headers {
            arguments += ["--header", header]
        }
        arguments += accountArguments(account)
        arguments.append(body)
        return HimalayaCommand(arguments: jsonArguments(arguments))
    }

    static func templateSend(
        template: String,
        account: String? = nil
    ) -> HimalayaCommand {
        var arguments = ["template", "send"]
        arguments += accountArguments(account)
        return HimalayaCommand(
            arguments: jsonArguments(arguments),
            standardInput: template.data(using: .utf8)
        )
    }

    private static func jsonArguments(_ arguments: [String]) -> [String] {
        ["--output", "json", "--quiet"] + arguments
    }

    private static func accountArguments(_ account: String?) -> [String] {
        guard let account, !account.isEmpty else {
            return []
        }
        return ["--account", account]
    }
}
