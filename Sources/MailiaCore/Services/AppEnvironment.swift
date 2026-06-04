import Foundation
import GRDB

public struct MailiaEnvironment: Sendable {
    public var applicationSupportDirectory: URL
    public var databaseURL: URL
    public var downloadsDirectory: URL
    public var himalayaBridge: any HimalayaBridge

    public init(
        applicationSupportDirectory: URL,
        databaseURL: URL,
        downloadsDirectory: URL,
        himalayaBridge: any HimalayaBridge
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.databaseURL = databaseURL
        self.downloadsDirectory = downloadsDirectory
        self.himalayaBridge = himalayaBridge
    }

    public static func live(
        fileManager: FileManager = .default,
        himalayaBridge: (any HimalayaBridge)? = nil
    ) throws -> MailiaEnvironment {
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let supportDirectory = supportRoot.appendingPathComponent("Mailia", isDirectory: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

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
            himalayaBridge: himalayaBridge ?? ProcessHimalayaBridge()
        )
    }

    public func openDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try DatabaseMigratorFactory.makeMigrator().migrate(queue)
        return queue
    }
}
