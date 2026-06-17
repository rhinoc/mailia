import Foundation

public struct MailAppServerInitializeResult: Decodable, Equatable, Sendable {
    public var serverName: String
    public var protocolVersion: Int
}

public struct MailAppServerAccount: Decodable, Equatable, Sendable {
    public var name: String
    public var backend: String?
    public var isDefault: Bool
    public var emailAddress: String?
    public var displayName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case backend
        case isDefault = "default"
        case emailAddress
        case displayName
    }
}

public struct MailAppServerAccountListResult: Decodable, Equatable, Sendable {
    public var accounts: [MailAppServerAccount]
}

public struct MailAppServerFolder: Decodable, Equatable, Sendable {
    public var name: String
    public var desc: String?
}

public struct MailAppServerFolderListResult: Decodable, Equatable, Sendable {
    public var folders: [MailAppServerFolder]
}

public struct MailAppServerMessageAddress: Decodable, Equatable, Sendable {
    public var name: String?
    public var addr: String
}

public struct MailAppServerMessageEnvelope: Decodable, Equatable, Sendable {
    public var id: String
    public var flags: [String]
    public var subject: String?
    public var from: MailAppServerMessageAddress?
    public var to: MailAppServerMessageAddress?
    public var date: String?
    public var hasAttachment: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case flags
        case subject
        case from
        case to
        case date
        case hasAttachment = "has_attachment"
    }
}

public struct MailAppServerMessageListResult: Decodable, Equatable, Sendable {
    public var envelopes: [MailAppServerMessageEnvelope]
}

public struct MailAppServerMessageGetResult: Decodable, Equatable, Sendable {
    public var id: String
    public var text: String?
    public var html: String?
    public var hasAttachment: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case html
        case hasAttachment = "has_attachment"
    }
}

public struct MailAppServerMessageModifyResult: Decodable, Equatable, Sendable {
    public var id: String
    public var folder: String
}

public struct MailAppServerMessageSendResult: Decodable, Equatable, Sendable {
    public var sent: Bool
}

public struct MailAppServerDownloadedAttachment: Decodable, Equatable, Sendable {
    public var id: String
    public var filename: String?
    public var path: String
    public var size: UInt64
}

public struct MailAppServerAttachmentDownloadResult: Decodable, Equatable, Sendable {
    public var attachments: [MailAppServerDownloadedAttachment]
}

public enum MailAppServerAccountHealthStatus: String, Decodable, Equatable, Sendable {
    case ok
    case warning
}

public struct MailAppServerAccountHealthIssue: Decodable, Equatable, Sendable {
    public var code: String
    public var message: String
}

public struct MailAppServerAccountHealthResult: Decodable, Equatable, Sendable {
    public var account: MailAppServerAccount
    public var status: MailAppServerAccountHealthStatus
    public var issues: [MailAppServerAccountHealthIssue]
}

public enum MailAppServerError: LocalizedError, Equatable, Sendable {
    case invalidTimeout(TimeInterval)
    case launchFailed(String)
    case notRunning
    case timedOut(method: String, timeout: TimeInterval)
    case serverExited(status: Int32, stderr: String)
    case rpcError(code: String, message: String, retryable: Bool?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTimeout(timeout):
            return "Invalid app-server timeout: \(timeout)."
        case let .launchFailed(message):
            return "Unable to launch Mailia app-server: \(message)"
        case .notRunning:
            return "Mailia app-server is not running."
        case let .timedOut(method, timeout):
            return "Mailia app-server timed out after \(timeout)s while running \(method)."
        case let .serverExited(status, stderr):
            let capturedStderr = !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return "Mailia app-server exited with status \(status).\(capturedStderr ? " Stderr output was captured." : "")"
        case let .rpcError(code, message, _):
            if let publicMessage = AppServerPublicErrorDescription.sanitized(message) {
                return "Mailia app-server returned \(code): \(publicMessage)"
            }
            return "Mailia app-server returned \(code)."
        case let .invalidResponse(message):
            return "Mailia app-server returned an invalid response: \(message)"
        }
    }
}

public extension MailAppServerError {
    var timingErrorKind: String {
        switch self {
        case .invalidTimeout:
            "invalid_timeout"
        case .launchFailed:
            "launch_failed"
        case .notRunning:
            "not_running"
        case .timedOut:
            "timeout"
        case .serverExited:
            "server_exited"
        case let .rpcError(code, message, retryable):
            if Self.isMessageNotFound(code: code, message: message) {
                "message_not_found"
            } else if Self.isInvalidFolder(code: code, message: message) {
                "invalid_folder"
            } else if retryable == true {
                "rpc_retryable"
            } else {
                "rpc_\(Self.sanitizedTimingValue(code))"
            }
        case .invalidResponse:
            "invalid_response"
        }
    }

    var marksMessageLocationMissing: Bool {
        switch self {
        case let .rpcError(code, message, _):
            Self.isMessageNotFound(code: code, message: message) ||
                Self.isInvalidFolder(code: code, message: message)
        default:
            false
        }
    }

    fileprivate static func isMessageNotFound(code: String, message: String) -> Bool {
        guard code == "invalid_request" else { return false }
        let normalized = message.lowercased()
        return normalized.contains("message") &&
            normalized.contains("was not found") &&
            normalized.contains("folder")
    }

    private static func isInvalidFolder(code: String, message: String) -> Bool {
        guard code == "invalid_request" else { return false }
        return message.lowercased().contains("invalid folder")
    }

    private static func sanitizedTimingValue(_ value: String) -> String {
        let sanitized = value.lowercased().map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
                ? character
                : "_"
        }
        let normalized = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? "unknown" : normalized
    }
}

enum AppServerPublicErrorDescription {
    static func sanitized(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsSensitiveNeedle(trimmed) else {
            return "details redacted"
        }
        return trimmed
    }

    private static func containsSensitiveNeedle(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let sensitiveNeedles = [
            "/",
            "@",
            "`",
            "application support",
            "keychain",
            "keyring",
            "oauth",
            "password",
            "secret",
            "token"
        ]
        return sensitiveNeedles.contains { lowercased.contains($0) }
    }
}

public actor MailAppServerClient {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectoryURL: URL?
    private let defaultTimeout: TimeInterval
    private let launchFailureRetryInterval: TimeInterval

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrReader: AppServerStderrReader?
    private var requestMetricsByID: [Int64: AppServerRequestMetric] = [:]
    private var nextID: Int64 = 1
    private var pending: [Int64: PendingRequest] = [:]
    private var responseReader: AppServerResponseReader?
    private var initializeResult: MailAppServerInitializeResult?
    private var launchFailureBackoffUntil: Date?
    private var launchFailureError: MailAppServerError?
    private var suppressedLaunchFailureCount = 0

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil,
        defaultTimeout: TimeInterval = 10,
        launchFailureRetryInterval: TimeInterval = 5
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.defaultTimeout = defaultTimeout
        self.launchFailureRetryInterval = max(0, launchFailureRetryInterval)
    }

    deinit {
        responseReader?.stop()
        stderrReader?.stop()
        try? stdin?.close()
        try? stdout?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    @discardableResult
    public func start(timeout: TimeInterval? = nil) async throws -> MailAppServerInitializeResult {
        guard process == nil else {
            if let initializeResult {
                return initializeResult
            }
            throw MailAppServerError.notRunning
        }

        if let cachedLaunchFailure = cachedLaunchFailureInBackoff() {
            throw cachedLaunchFailure
        }
        if suppressedLaunchFailureCount > 0 {
            NSLog("Mailia app-server launch retry after suppressing %d repeated failures", suppressedLaunchFailureCount)
            suppressedLaunchFailureCount = 0
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrReader = AppServerStderrReader()
        stderrReader.start(
            reading: stderrPipe.fileHandleForReading,
            onLine: { [weak self] line in
                await self?.receiveStderrLine(line)
            }
        )

        do {
            try process.run()
        } catch {
            stderrReader.stop()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            let launchError = MailAppServerError.launchFailed(error.localizedDescription)
            launchFailureError = launchError
            launchFailureBackoffUntil = Date().addingTimeInterval(launchFailureRetryInterval)
            throw launchError
        }

        launchFailureError = nil
        launchFailureBackoffUntil = nil
        suppressedLaunchFailureCount = 0
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderrReader = stderrReader
        let responseReader = AppServerResponseReader(
            onResponse: { [weak self] data in
                await self?.receiveResponse(data)
            },
            onExit: { [weak self] in
                await self?.failAllPendingBecauseServerExited()
            }
        )
        self.responseReader = responseReader
        responseReader.start(reading: stdoutPipe.fileHandleForReading)

        let initializeResult = try await request(
            method: "initialize",
            params: EmptyParams(),
            resultType: MailAppServerInitializeResult.self,
            timeout: timeout
        )
        self.initializeResult = initializeResult
        return initializeResult
    }

    private func cachedLaunchFailureInBackoff() -> MailAppServerError? {
        guard let launchFailureBackoffUntil,
              let launchFailureError,
              Date() < launchFailureBackoffUntil
        else {
            return nil
        }
        suppressedLaunchFailureCount += 1
        return launchFailureError
    }

    public func noop(timeout: TimeInterval? = nil) async throws {
        _ = try await request(
            method: "server/noop",
            params: EmptyParams(),
            resultType: EmptyResult.self,
            timeout: timeout
        )
    }

    public func accountList(timeout: TimeInterval? = nil) async throws -> [MailAppServerAccount] {
        try await request(
            method: "account/list",
            params: EmptyParams(),
            resultType: MailAppServerAccountListResult.self,
            timeout: timeout
        ).accounts
    }

    public func folderList(
        account: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [MailAppServerFolder] {
        try await request(
            method: "folder/list",
            params: FolderListParams(account: account),
            resultType: MailAppServerFolderListResult.self,
            timeout: timeout
        ).folders
    }

    public func accountHealth(
        account: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MailAppServerAccountHealthResult {
        try await request(
            method: "account/health",
            params: AccountHealthParams(account: account),
            resultType: MailAppServerAccountHealthResult.self,
            timeout: timeout
        )
    }

    public func messageList(
        folder: String,
        account: String? = nil,
        query: String? = nil,
        page: Int = 1,
        pageSize: Int? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [MailAppServerMessageEnvelope] {
        try await request(
            method: "message/list",
            params: MessageListParams(
                folder: folder,
                account: account,
                query: query,
                page: page,
                pageSize: pageSize
            ),
            resultType: MailAppServerMessageListResult.self,
            timeout: timeout
        ).envelopes
    }

    public func messageGet(
        id: String,
        folder: String,
        account: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MailAppServerMessageGetResult {
        try await request(
            method: "message/get",
            params: MessageGetParams(id: id, folder: folder, account: account),
            resultType: MailAppServerMessageGetResult.self,
            timeout: timeout
        )
    }

    public func messageModify(
        id: String,
        folder: String,
        account: String? = nil,
        addFlags: [String] = [],
        removeFlags: [String] = [],
        moveTo: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MailAppServerMessageModifyResult {
        try await request(
            method: "message/modify",
            params: MessageModifyParams(
                id: id,
                folder: folder,
                account: account,
                addFlags: addFlags,
                removeFlags: removeFlags,
                moveTo: moveTo
            ),
            resultType: MailAppServerMessageModifyResult.self,
            timeout: timeout
        )
    }

    public func attachmentDownload(
        messageID: String,
        folder: String,
        account: String? = nil,
        downloadsDirectory: URL,
        timeout: TimeInterval? = nil
    ) async throws -> [MailAppServerDownloadedAttachment] {
        try await request(
            method: "attachment/download",
            params: AttachmentDownloadParams(
                messageID: messageID,
                folder: folder,
                account: account,
                downloadsDir: downloadsDirectory.path
            ),
            resultType: MailAppServerAttachmentDownloadResult.self,
            timeout: timeout
        ).attachments
    }

    public func messageSend(
        raw: String,
        account: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MailAppServerMessageSendResult {
        try await request(
            method: "message/send",
            params: MessageSendParams(account: account, raw: raw),
            resultType: MailAppServerMessageSendResult.self,
            timeout: timeout
        )
    }

    public func shutdown(timeout: TimeInterval? = nil) async throws {
        guard process != nil else { return }
        _ = try await request(
            method: "shutdown",
            params: EmptyParams(),
            resultType: EmptyResult.self,
            timeout: timeout
        )
        try? stdin?.close()
        process?.waitUntilExit()
        clearProcessState()
    }

    public func request<Params: Encodable & Sendable, Output: Decodable & Sendable>(
        method: String,
        params: Params,
        resultType: Output.Type = Output.self,
        timeout: TimeInterval? = nil
    ) async throws -> Output {
        let timeout = timeout ?? defaultTimeout
        guard timeout > 0 else {
            throw MailAppServerError.invalidTimeout(timeout)
        }
        let timingStartedAt = Date()
        let timingFields: [MailiaTimingField] = [
            .label("method", method.replacingOccurrences(of: "/", with: "_"))
        ]
        var timingRequestID: Int64?
        var suppressLaunchFailureTiming = false

        do {
            if method != "initialize", method != "shutdown" {
                if process == nil || process?.isRunning != true || stdin == nil {
                    if let cachedLaunchFailure = cachedLaunchFailureInBackoff() {
                        suppressLaunchFailureTiming = true
                        throw cachedLaunchFailure
                    }
                    _ = try await start(timeout: timeout)
                }
            }
            guard let process, process.isRunning, let stdin else {
                throw MailAppServerError.notRunning
            }

            let id = nextID
            nextID += 1
            timingRequestID = id
            let payload = try AppServerRequest(id: id, method: method, params: params)
            let data = try JSONEncoder().encode(payload)
            let pending = PendingRequest()
            self.pending[id] = pending

            stdin.write(data)
            stdin.write(Data([0x0A]))

            let timeoutTask = Task { [pending] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    pending.fail(MailAppServerError.timedOut(method: method, timeout: timeout))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }

            let output = try await withTaskCancellationHandler {
                defer {
                    timeoutTask.cancel()
                    removePendingRequest(id: id)
                }
                return try await pending.value(as: resultType)
            } onCancel: {
                timeoutTask.cancel()
                pending.cancel()
            }
            let metric = await takeRequestMetric(requestID: id, method: method, backendStatus: "ok")
            MailiaTiming.log(
                operation: "app_server.request",
                startedAt: timingStartedAt,
                fields: timingFields + MailAppServerRequestTiming.fields(
                    for: metric,
                    outcome: "backend_ok",
                    errorCode: "none"
                )
            )
            return output
        } catch {
            let metric: AppServerRequestMetric?
            if let timingRequestID {
                metric = await takeRequestMetric(
                    requestID: timingRequestID,
                    method: method,
                    backendStatus: Self.backendStatus(for: error)
                )
            } else {
                metric = nil
            }
            let errorKind = Self.timingErrorKind(for: error)
            if !suppressLaunchFailureTiming {
                MailiaTiming.log(
                    operation: "app_server.request",
                    startedAt: timingStartedAt,
                    status: Self.timingStatus(for: error),
                    fields: timingFields + MailAppServerRequestTiming.fields(
                        for: metric,
                        outcome: Self.timingOutcome(for: error),
                        errorCode: Self.timingErrorCode(for: error)
                    ) + [.label("error_kind", errorKind)]
                )
            }
            throw error
        }
    }

    private func receiveStderrLine(_ line: String) {
        guard let metric = AppServerRequestMetric.parse(line) else { return }
        requestMetricsByID[metric.requestID] = metric
        if requestMetricsByID.count > 100,
           let oldestID = requestMetricsByID.keys.min() {
            requestMetricsByID[oldestID] = nil
        }
    }

    private func takeRequestMetric(
        requestID: Int64,
        method: String,
        backendStatus: String?
    ) async -> AppServerRequestMetric? {
        let deadline = Date().addingTimeInterval(0.05)
        while true {
            if let metric = takeStoredRequestMetric(
                requestID: requestID,
                method: method,
                backendStatus: backendStatus
            ) {
                return metric
            }
            guard Date() < deadline else {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func takeStoredRequestMetric(
        requestID: Int64,
        method: String,
        backendStatus: String?
    ) -> AppServerRequestMetric? {
        guard let metric = requestMetricsByID[requestID] else {
            return nil
        }
        guard metric.method == method else {
            return nil
        }
        if let backendStatus, metric.status != backendStatus {
            return nil
        }
        requestMetricsByID[requestID] = nil
        return metric
    }

    private static func timingStatus(for error: Error) -> String {
        error is CancellationError ? "cancelled" : "failure"
    }

    private static func timingOutcome(for error: Error) -> String {
        if error is CancellationError {
            return "swift_cancelled"
        }
        guard let error = error as? MailAppServerError else {
            return "swift_failure"
        }
        switch error {
        case .timedOut:
            return "swift_timeout"
        case .invalidTimeout, .launchFailed, .notRunning, .serverExited, .invalidResponse:
            return "swift_failure"
        case let .rpcError(code, message, retryable):
            if MailAppServerError.isMessageNotFound(code: code, message: message) {
                return "remote_not_found"
            }
            if retryable == true || code == "internal" || code == "overloaded" {
                return "backend_failure"
            }
            return "remote_error"
        }
    }

    private static func timingErrorCode(for error: Error) -> String {
        if error is CancellationError {
            return "swift_cancelled"
        }
        guard let error = error as? MailAppServerError else {
            return "unknown"
        }
        switch error {
        case .invalidTimeout:
            return "invalid_timeout"
        case .launchFailed:
            return "launch_failed"
        case .notRunning:
            return "not_running"
        case .timedOut:
            return "swift_timeout"
        case .serverExited:
            return "server_exited"
        case let .rpcError(code, _, _):
            return code
        case .invalidResponse:
            return "invalid_response"
        }
    }

    private static func backendStatus(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        guard case .rpcError = error as? MailAppServerError else {
            return nil
        }
        return "error"
    }

    private static func timingErrorKind(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let error = error as? MailAppServerError {
            return error.timingErrorKind
        }
        return "unknown"
    }

    private func removePendingRequest(id: Int64) {
        pending[id] = nil
    }

    private func receiveResponse(_ data: Data) {
        do {
            let response = try JSONDecoder().decode(AppServerResponse.self, from: data)
            guard let id = response.id.pendingRequestID else { return }
            guard let pending = pending[id] else { return }

            if let error = response.error {
                pending.fail(MailAppServerError.rpcError(
                    code: error.code,
                    message: error.message,
                    retryable: error.retryable
                ))
            } else if let result = response.result {
                pending.succeed(result)
            } else {
                pending.fail(MailAppServerError.invalidResponse("missing result and error"))
            }
        } catch {
            failAllPending(MailAppServerError.invalidResponse(error.localizedDescription))
        }
    }

    private func failAllPendingBecauseServerExited() {
        let status: Int32
        if let process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            status = process.terminationStatus
        } else {
            status = -1
        }
        initializeResult = nil
        let stderr = stderrReader.map { String(decoding: $0.waitForData(), as: UTF8.self) } ?? ""
        clearProcessState()
        failAllPending(MailAppServerError.serverExited(status: status, stderr: stderr))
    }

    private func clearProcessState() {
        responseReader?.stop()
        stderrReader?.stop()
        try? stdin?.close()
        try? stdout?.close()
        process = nil
        stdin = nil
        stdout = nil
        stderrReader = nil
        responseReader = nil
        initializeResult = nil
        requestMetricsByID.removeAll()
    }

    private func failAllPending(_ error: MailAppServerError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.fail(error)
        }
    }
}

private final class AppServerResponseReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.rhinoc.mailia.app-server-response-reader", qos: .utility)
    private let lock = NSLock()
    private let onResponse: @Sendable (Data) async -> Void
    private let onExit: @Sendable () async -> Void
    private var fileHandle: FileHandle?
    private var stopped = false
    private var buffer = Data()

    init(
        onResponse: @escaping @Sendable (Data) async -> Void,
        onExit: @escaping @Sendable () async -> Void
    ) {
        self.onResponse = onResponse
        self.onExit = onExit
    }

    func start(reading fileHandle: FileHandle) {
        lock.lock()
        self.fileHandle = fileHandle
        lock.unlock()

        fileHandle.readabilityHandler = { [weak self] handle in
            guard let reader = self else { return }
            reader.queue.async { [weak reader] in
                reader?.readAvailableData(from: handle)
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fileHandle = fileHandle
        self.fileHandle = nil
        lock.unlock()
        fileHandle?.readabilityHandler = nil
    }

    private func readAvailableData(from fileHandle: FileHandle) {
        guard !isStopped else { return }

        let chunk = fileHandle.availableData
        guard !chunk.isEmpty else {
            finishBecausePipeClosed(fileHandle)
            return
        }

        buffer.append(chunk)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            waitForAsync { [self] in
                await self.onResponse(Data(line))
            }
        }
    }

    private func finishBecausePipeClosed(_ fileHandle: FileHandle) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        self.fileHandle = nil
        lock.unlock()

        fileHandle.readabilityHandler = nil
        waitForAsync { [self] in
            await self.onExit()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func waitForAsync(_ operation: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await operation()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

enum MailAppServerRequestTiming {
    static func fields(
        for metric: AppServerRequestMetric?,
        outcome: String,
        errorCode: String
    ) -> [MailiaTimingField] {
        [
            .label("outcome", outcome),
            .label("error_code", errorCode),
            .label("backend_request_id", metric?.requestID ?? -1),
            .label("backend_status", metric?.status ?? "missing"),
            .label("backend_duration_ms", metric?.durationMilliseconds ?? -1),
            .label("config_load_count", metric?.configLoadCount ?? -1),
            .label("auth_refresh_count", metric?.authRefreshCount ?? -1)
        ]
    }
}

struct AppServerRequestMetric: Equatable, Sendable {
    var requestID: Int64
    var method: String
    var status: String
    var durationMilliseconds: Int
    var configLoadCount: Int
    var authRefreshCount: Int

    static func parse(_ line: String) -> AppServerRequestMetric? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.contains("request") else { return nil }

        var values: [String: String] = [:]
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            values[pieces[0]] = pieces[1]
        }

        guard
            let requestID = values["request_id"].flatMap(Int64.init),
            let method = values["method"],
            let status = values["status"],
            let duration = values["duration_ms"].flatMap(Int.init),
            let configLoadCount = values["config_load_count"].flatMap(Int.init),
            let authRefreshCount = values["auth_refresh_count"].flatMap(Int.init)
        else {
            return nil
        }

        return AppServerRequestMetric(
            requestID: requestID,
            method: method,
            status: status,
            durationMilliseconds: duration,
            configLoadCount: configLoadCount,
            authRefreshCount: authRefreshCount
        )
    }
}

private final class AppServerStderrReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.rhinoc.mailia.app-server-stderr-reader", qos: .utility)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    private var buffer = Data()
    private var fileHandle: FileHandle?
    private var stopped = false
    private var didLeaveGroup = false
    private var onLine: (@Sendable (String) async -> Void)?

    func start(
        reading fileHandle: FileHandle,
        onLine: @escaping @Sendable (String) async -> Void
    ) {
        lock.lock()
        self.fileHandle = fileHandle
        self.onLine = onLine
        group.enter()
        lock.unlock()

        fileHandle.readabilityHandler = { [weak self] handle in
            guard let reader = self else { return }
            reader.queue.async { [weak reader] in
                reader?.readAvailableData(from: handle)
            }
        }
    }

    func stop() {
        finish(fileHandle: nil)
    }

    func waitForData() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    private func readAvailableData(from fileHandle: FileHandle) {
        guard !isStopped else { return }

        let chunk = fileHandle.availableData
        guard !chunk.isEmpty else {
            finish(fileHandle: fileHandle)
            return
        }

        lock.lock()
        data.append(chunk)
        buffer.append(chunk)
        let lines = completeBufferedLinesLocked()
        lock.unlock()

        for line in lines {
            emitLine(line)
        }
    }

    private func completeBufferedLinesLocked() -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }

    private func finish(fileHandle: FileHandle?) {
        let trailingLine: String?
        let onLine: (@Sendable (String) async -> Void)?

        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        self.fileHandle?.readabilityHandler = nil
        fileHandle?.readabilityHandler = nil
        self.fileHandle = nil
        onLine = self.onLine
        self.onLine = nil
        if buffer.isEmpty {
            trailingLine = nil
        } else {
            trailingLine = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
        }
        let shouldLeaveGroup = !didLeaveGroup
        didLeaveGroup = true
        lock.unlock()

        if let trailingLine, !trailingLine.isEmpty {
            emitLine(trailingLine, onLine: onLine)
        }
        if shouldLeaveGroup {
            group.leave()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func emitLine(
        _ line: String,
        onLine providedOnLine: (@Sendable (String) async -> Void)? = nil
    ) {
        let callback: (@Sendable (String) async -> Void)?
        if let providedOnLine {
            callback = providedOnLine
        } else {
            lock.lock()
            callback = onLine
            lock.unlock()
        }
        guard let callback else { return }
        Task {
            await callback(line)
        }
    }
}

private struct AppServerRequest: Encodable {
    var id: Int64
    var method: String
    var params: DataBackedJSONValue

    init<Params: Encodable>(id: Int64, method: String, params: Params) throws {
        self.id = id
        self.method = method
        self.params = try DataBackedJSONValue(params)
    }
}

private struct AppServerResponse: Decodable {
    var id: AppServerResponseID
    var result: DataBackedJSONValue?
    var error: AppServerResponseError?
}

private enum AppServerResponseID: Decodable {
    case number(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let id = try? container.decode(Int64.self) {
            self = .number(id)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var pendingRequestID: Int64? {
        switch self {
        case let .number(id):
            id
        case .string:
            nil
        }
    }
}

private struct AppServerResponseError: Decodable {
    var code: String
    var message: String
    var retryable: Bool?
}

private struct DataBackedJSONValue: Codable {
    var data: Data

    init<T: Encodable>(_ value: T) throws {
        data = try JSONEncoder().encode(value)
    }

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        data = try JSONEncoder().encode(value)
    }

    func encode(to encoder: Encoder) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try value.encode(to: encoder)
    }

    func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

private enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct EmptyParams: Encodable {}

private struct AccountHealthParams: Encodable, Sendable {
    var account: String?
}

private struct FolderListParams: Encodable, Sendable {
    var account: String?
}

private struct MessageListParams: Encodable, Sendable {
    var folder: String
    var account: String?
    var query: String?
    var page: Int
    var pageSize: Int?
}

private struct MessageGetParams: Encodable, Sendable {
    var id: String
    var folder: String
    var account: String?
}

private struct MessageModifyParams: Encodable, Sendable {
    var id: String
    var folder: String
    var account: String?
    var addFlags: [String]
    var removeFlags: [String]
    var moveTo: String?
}

private struct MessageSendParams: Encodable, Sendable {
    var account: String?
    var raw: String
}

private struct AttachmentDownloadParams: Encodable, Sendable {
    var messageID: String
    var folder: String
    var account: String?
    var downloadsDir: String

    enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case folder
        case account
        case downloadsDir
    }
}

private struct EmptyResult: Decodable {
    var ok: Bool
}

private final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DataBackedJSONValue, Error>?
    private var completed: Result<DataBackedJSONValue, Error>?

    func value<Result: Decodable>(as type: Result.Type) async throws -> Result {
        let value = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(with: completed)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
        return try value.decode(as: type)
    }

    func succeed(_ value: DataBackedJSONValue) {
        complete(.success(value))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<DataBackedJSONValue, Error>) {
        lock.lock()
        if completed != nil {
            lock.unlock()
            return
        }
        completed = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
