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

public enum HimalayaError: Error, Equatable, Sendable {
    case invalidTimeout(TimeInterval)
    case launchFailed(String)
    case timedOut(command: HimalayaCommand, timeout: TimeInterval, stdout: String, stderr: String)
    case nonZeroExit(HimalayaResult)
    case jsonDecodeFailed(message: String, stdout: String)
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

        return try await Task.detached {
            try Self.runSynchronously(
                command,
                executableURL: executableURL,
                environment: environment,
                workingDirectoryURL: workingDirectoryURL,
                timeout: timeout
            )
        }.value
    }

    private static func runSynchronously(
        _ command: HimalayaCommand,
        executableURL: URL,
        environment bridgeEnvironment: [String: String],
        workingDirectoryURL: URL?,
        timeout: TimeInterval?
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
        } catch {
            throw HimalayaError.launchFailed(error.localizedDescription)
        }

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

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return HimalayaResult(
            command: command,
            exitCode: process.terminationStatus,
            stdoutData: stdoutData,
            stderrData: stderrData,
            duration: Date().timeIntervalSince(startedAt)
        )
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
