import Foundation

public struct MailiaTimingField: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = MailiaTiming.sanitizedKey(key)
        self.value = MailiaTiming.sanitizedPublicValue(value)
    }

    public static func label(_ key: String, _ value: some CustomStringConvertible) -> MailiaTimingField {
        MailiaTimingField(key: key, value: String(describing: value))
    }

    public static func redacted(_ key: String, _ value: String?) -> MailiaTimingField {
        MailiaTimingField(
            key: key,
            value: MailiaTiming.redactedIdentifier(value)
        )
    }
}

public enum MailiaTiming {
    public static func measure<Result>(
        operation: String,
        fields: [MailiaTimingField] = [],
        _ body: () throws -> Result
    ) throws -> Result {
        let startedAt = Date()
        do {
            let result = try body()
            log(operation: operation, startedAt: startedAt, status: "success", fields: fields)
            return result
        } catch {
            log(operation: operation, startedAt: startedAt, status: "failure", fields: fields)
            throw error
        }
    }

    public static func log(
        operation: String,
        startedAt: Date,
        finishedAt: Date = Date(),
        status: String = "success",
        fields: [MailiaTimingField] = []
    ) {
        let durationMilliseconds = max(0, Int((finishedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
        let line = formatLine(
            operation: operation,
            durationMilliseconds: durationMilliseconds,
            status: status,
            fields: fields
        )
        NSLog("%@", line)
        MailiaTimingFileLog.shared.append(line)
    }

    public static func formatLine(
        operation: String,
        durationMilliseconds: Int,
        status: String = "success",
        fields: [MailiaTimingField] = []
    ) -> String {
        let baseFields = [
            MailiaTimingField(key: "operation", value: sanitizedOperation(operation)),
            MailiaTimingField(key: "duration_ms", value: String(max(0, durationMilliseconds))),
            MailiaTimingField(key: "status", value: status)
        ]
        let renderedFields = (baseFields + fields)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "MailiaTiming \(renderedFields)"
    }

    public static func redactedIdentifier(_ value: String?) -> String {
        guard let value else { return "redacted:none" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "redacted:empty" }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "redacted:\(String(format: "%016llx", hash))"
    }

    static func persistentLogURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        MailiaTimingFileLog.logURL(fileManager: fileManager, environment: environment)
    }

    static func sanitizedKey(_ key: String) -> String {
        let sanitized = key.map { character in
            character.isLetter || character.isNumber || character == "_" || character == "." || character == "-"
                ? character
                : "_"
        }
        let value = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? "field" : value
    }

    static func sanitizedPublicValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        guard !containsPrivateNeedle(trimmed) else {
            return redactedIdentifier(trimmed)
        }

        let sanitized = trimmed.unicodeScalars.map { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                ? "_"
                : Character(scalar)
        }
        return String(sanitized)
    }

    private static func sanitizedOperation(_ operation: String) -> String {
        sanitizedPublicValue(operation.replacingOccurrences(of: "/", with: "_"))
    }

    private static func containsPrivateNeedle(_ value: String) -> Bool {
        value.contains("@") || value.contains("/") || value.contains("\\") || value.lowercased().contains("application support")
    }
}

private final class MailiaTimingFileLog: @unchecked Sendable {
    static let shared = MailiaTimingFileLog()

    private let lock = NSLock()
    private let fileManager: FileManager
    private let environment: [String: String]
    private var didReportWriteFailure = false
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func append(_ line: String) {
        guard let logURL = Self.logURL(fileManager: fileManager, environment: environment) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            let timestampedLine = "\(timestampFormatter.string(from: Date())) \(line)\n"
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = timestampedLine.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            guard !didReportWriteFailure else { return }
            didReportWriteFailure = true
            NSLog("MailiaTiming file_log_write_failed")
        }
    }

    static func logURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let overridePath = environment["MAILIA_TIMING_LOG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath)
        }

        guard environment["XCTestConfigurationFilePath"] == nil else {
            return nil
        }

        guard let supportRoot = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return supportRoot
            .appendingPathComponent("Mailia", isDirectory: true)
            .appendingPathComponent("mailia-timing.log")
    }
}
