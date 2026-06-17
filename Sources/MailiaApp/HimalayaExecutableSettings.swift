import Foundation
import MailiaCore

enum MailiaHimalayaExecutableSettings {
    static func appServerClient(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MailAppServerClient {
        let launch = appServerLaunch(environment: environment)
        return MailAppServerClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            environment: environment
        )
    }

    static func effectiveDisplayPath(defaults: UserDefaults = .standard) -> String {
        overridePath(defaults: defaults) ?? autoDetectedDisplayPath()
    }

    static func autoDetectedDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let launch = appServerLaunch(environment: environment)
        return launch.executableURL.path
    }

    static func overridePath(defaults: UserDefaults = .standard) -> String? {
        let normalized = normalizedPath(defaults.string(forKey: MailiaPreferenceKeys.himalayaExecutablePath))
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedPath(_ path: String?) -> String {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func appServerLaunch(environment: [String: String]) -> (executableURL: URL, arguments: [String]) {
        appServerLaunch(
            environment: environment,
            executableURL: Bundle.main.executableURL,
            bundleURL: Bundle.main.bundleURL,
            fileManager: .default
        )
    }

    static func appServerLaunch(
        environment: [String: String],
        executableURL: URL?,
        bundleURL: URL,
        fileManager: FileManager
    ) -> (executableURL: URL, arguments: [String]) {
        let overridePath = normalizedPath(environment["MAILIA_APP_SERVER_PATH"])
        if !overridePath.isEmpty {
            return (
                URL(fileURLWithPath: overridePath),
                ["app-server", "--listen", "stdio://"]
            )
        }

        if let bundledURL = bundledAppServerURL(
            executableURL: executableURL,
            bundleURL: bundleURL,
            fileManager: fileManager
        ) {
            return (
                bundledURL,
                ["app-server", "--listen", "stdio://"]
            )
        }

        if let developmentURL = developmentAppServerURL(
            executableURL: executableURL,
            fileManager: fileManager
        ) {
            return (
                developmentURL,
                ["app-server", "--listen", "stdio://"]
            )
        }

        return (
            bundleURL.appendingPathComponent("Contents/MacOS/mailia-mail"),
            ["app-server", "--listen", "stdio://"]
        )
    }

    static func bundledAppServerURL(
        executableURL: URL?,
        bundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let executableDirectory = executableURL?.deletingLastPathComponent()
        let candidates = [
            executableDirectory?.appendingPathComponent("mailia-mail"),
            bundleURL.appendingPathComponent("Contents/MacOS/mailia-mail")
        ].compactMap(\.self)

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func developmentAppServerURL(
        executableURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let executableDirectory = executableURL?.deletingLastPathComponent() else {
            return nil
        }

        let buildDirectory = executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        guard buildDirectory == ".build" else {
            return nil
        }

        let repositoryRoot = executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let targetConfiguration = executableDirectory.lastPathComponent == "release" ? "release" : "debug"
        let candidates = [
            repositoryRoot
                .appendingPathComponent("mailia-mail", isDirectory: true)
                .appendingPathComponent("target", isDirectory: true)
                .appendingPathComponent(targetConfiguration, isDirectory: true)
                .appendingPathComponent("mailia-mail"),
            repositoryRoot
                .appendingPathComponent("mailia-mail", isDirectory: true)
                .appendingPathComponent("target", isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
                .appendingPathComponent("mailia-mail")
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
