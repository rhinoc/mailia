import Foundation
import GRDB

public struct MailiaEnvironment: Sendable {
    public var applicationSupportDirectory: URL
    public var databaseURL: URL
    public var downloadsDirectory: URL
    public var appServerClient: MailAppServerClient

    public init(
        applicationSupportDirectory: URL,
        databaseURL: URL,
        downloadsDirectory: URL,
        appServerClient: MailAppServerClient
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.databaseURL = databaseURL
        self.downloadsDirectory = downloadsDirectory
        self.appServerClient = appServerClient
    }

    public static func live(
        fileManager: FileManager = .default,
        appServerClient: MailAppServerClient
    ) throws -> MailiaEnvironment {
        let supportDirectory = try applicationSupportDirectory(fileManager: fileManager)
        let downloadsDirectory = try fileManager.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return MailiaEnvironment(
            applicationSupportDirectory: supportDirectory,
            databaseURL: supportDirectory.appendingPathComponent("mailia.sqlite"),
            downloadsDirectory: downloadsDirectory,
            appServerClient: appServerClient
        )
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let supportDirectory = supportRoot.appendingPathComponent("Mailia", isDirectory: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        return supportDirectory
    }

    public func openDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try DatabaseSchemaFactory.initialize(queue)
        return queue
    }
}
