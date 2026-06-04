import Foundation
import MailiaCore

enum MailiaHimalayaExecutableSettings {
    static func bridge(defaults: UserDefaults = .standard) -> ProcessHimalayaBridge {
        if let executableURL = effectiveExecutableURL(defaults: defaults) {
            return ProcessHimalayaBridge(executableURL: executableURL)
        }
        return ProcessHimalayaBridge()
    }

    static func effectiveExecutableURL(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let overridePath = overridePath(defaults: defaults) {
            return URL(fileURLWithPath: overridePath)
        }
        return HimalayaExecutableResolver.discoveredExecutableURL(environment: environment)
    }

    static func effectiveDisplayPath(defaults: UserDefaults = .standard) -> String {
        effectiveExecutableURL(defaults: defaults)?.path ?? "himalaya"
    }

    static func autoDetectedDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        HimalayaExecutableResolver.discoveredExecutableURL(environment: environment)?.path ?? "himalaya"
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
}
