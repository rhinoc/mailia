import Foundation
import Testing
@testable import MailiaCore

@Test
func himalayaConfigStoreSetsExactlyOneDefaultAccount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-himalaya-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    try """
    display-name = "Ryan"

    [accounts.work]
    default = true
    email = "ryan@work.example"

    [accounts.personal]
    email = "ryan@example.com"

    [accounts.personal.backend]
    default = "not an account default"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    try HimalayaConfigStore(configURLs: [configURL]).setDefaultAccount(accountKey: "personal")

    let updated = try String(contentsOf: configURL, encoding: .utf8)
    #expect(updated.contains("""
    [accounts.work]
    default = false
    email = "ryan@work.example"
    """))
    #expect(updated.contains("""
    [accounts.personal]
    default = true
    email = "ryan@example.com"
    """))
    #expect(updated.contains("""
    [accounts.personal.backend]
    default = "not an account default"
    """))
}

@Test
func himalayaConfigStoreSupportsQuotedAccountNames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-himalaya-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    try """
    [accounts."work.mail"]
    email = "ryan@work.example"

    [accounts.personal]
    default = true
    """.write(to: configURL, atomically: true, encoding: .utf8)

    try HimalayaConfigStore(configURLs: [configURL]).setDefaultAccount(accountKey: "work.mail")

    let updated = try String(contentsOf: configURL, encoding: .utf8)
    #expect(updated.contains("""
    [accounts."work.mail"]
    default = true
    email = "ryan@work.example"
    """))
    #expect(updated.contains("""
    [accounts.personal]
    default = false
    """))
}

@Test
func himalayaConfigStoreRejectsUnknownAccount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-himalaya-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    try """
    [accounts.work]
    default = true
    """.write(to: configURL, atomically: true, encoding: .utf8)

    #expect(throws: HimalayaConfigStoreError.accountNotFound("personal")) {
        try HimalayaConfigStore(configURLs: [configURL]).setDefaultAccount(accountKey: "personal")
    }
}

@Test
func himalayaConfigStoreReadsAccountMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-himalaya-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    try """
    [accounts.work]
    default = true
    email = "ryan@work.example"
    display-name = "Work"

    [accounts.personal]
    default = false
    email = "ryan@example.com"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let metadata = try HimalayaConfigStore(configURLs: [configURL]).accountMetadata()
    #expect(metadata["work"]?.emailAddress == "ryan@work.example")
    #expect(metadata["work"]?.displayName == "Work")
    #expect(metadata["work"]?.isDefault == true)
    #expect(metadata["personal"]?.emailAddress == "ryan@example.com")
    #expect(metadata["personal"]?.isDefault == false)
}

@Test
func himalayaConfigStoreUpdatesAccountDisplayName() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailia-himalaya-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    try """
    [accounts.work]
    default = true
    email = "ryan@work.example"

    [accounts.personal]
    display-name = "Old"
    email = "ryan@example.com"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = HimalayaConfigStore(configURLs: [configURL])
    try store.setAccountDisplayName(accountKey: "work", displayName: "Work Mail")
    try store.setAccountDisplayName(accountKey: "personal", displayName: "Personal \"Mail\"")

    var updated = try String(contentsOf: configURL, encoding: .utf8)
    #expect(updated.contains("""
    [accounts.work]
    display-name = "Work Mail"
    default = true
    email = "ryan@work.example"
    """))
    #expect(updated.contains("""
    [accounts.personal]
    display-name = "Personal \\"Mail\\""
    email = "ryan@example.com"
    """))

    try store.setAccountDisplayName(accountKey: "personal", displayName: "")
    updated = try String(contentsOf: configURL, encoding: .utf8)
    #expect(!updated.contains("display-name = \"Personal"))
}

@Test
func himalayaConfigStoreErrorsHaveReadableDescriptions() {
    #expect(HimalayaConfigStoreError.accountNotFound("gmail").localizedDescription ==
        "Unable to find account gmail in the Himalaya configuration file.")
    #expect(HimalayaConfigStoreError.configNotFound.localizedDescription ==
        "Unable to find the Himalaya configuration file.")
}
