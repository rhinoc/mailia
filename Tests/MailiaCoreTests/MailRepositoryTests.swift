import Foundation
import Testing
@testable import MailiaCore

@Test
func repositoryDedupesFallbackMessagesAndQueriesWorkspaces() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@example.com")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Archive", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Spam", role: .junk),
        DiscoveredFolder(accountKey: "work", providerName: "Trash", role: .trash)
    ])

    let githubSender = MailAddress(displayName: "GitHub", emailAddress: "noreply@github.com")
    let duplicateDate = "2026-05-01T10:00:00Z"
    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Build passed",
            from: githubSender,
            messageDate: duplicateDate,
            flags: ["Flagged"]
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Archive",
            himalayaEnvelopeID: "archive-9",
            subject: "Build passed",
            from: githubSender,
            messageDate: duplicateDate
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Spam",
            himalayaEnvelopeID: "spam-1",
            subject: "Suspicious",
            from: MailAddress(emailAddress: "alerts@example.net"),
            messageDate: "2026-05-02T10:00:00Z"
        )
    ])

    #expect(messageIDs[0] == messageIDs[1])
    #expect(messageIDs[0] != messageIDs[2])

    let mainEntities = try repository.entityList(workspace: .main)
    #expect(mainEntities.map(\.displayName) == ["Github"])

    let mainEntity = try #require(mainEntities.first)
    #expect(mainEntity.primaryEmailAddress == "noreply@github.com")
    var messages = try repository.messages(entityID: mainEntity.id, workspace: .main)
    #expect(messages.count == 1)
    #expect(messages[0].subject == "Build passed")
    #expect(messages[0].folderName == "INBOX")
    #expect(messages[0].flags.contains("Flagged"))

    try repository.cacheMessageBody(
        messageID: messages[0].messageID,
        sanitizedHTML: "<p>Build passed</p>",
        textFallback: "Build passed",
        sanitizerVersion: 1
    )

    messages = try repository.messages(entityID: mainEntity.id, workspace: .main)
    #expect(messages[0].sanitizedHTML == "<p>Build passed</p>")
    #expect(messages[0].textFallback == "Build passed")
    messages = try repository.messages(entityID: mainEntity.id, workspace: .main, includeBodies: false)
    #expect(messages[0].sanitizedHTML == nil)
    #expect(messages[0].textFallback == nil)
    let cachedBody = try #require(try repository.messageBody(messageID: messages[0].messageID))
    #expect(cachedBody.sanitizedHTML == "<p>Build passed</p>")
    #expect(cachedBody.textFallback == "Build passed")
    #expect(try repository.targetFolderName(accountKey: "work", role: .normal) == "INBOX")
    #expect(try repository.targetFolderName(accountKey: "work", role: .junk) == "Spam")
    #expect(try repository.targetFolderName(accountKey: "work", role: .trash) == "Trash")

    let locations = try repository.messageLocations(entityID: mainEntity.id, workspace: .main, sourceRoles: [.normal])
    #expect(locations.map(\.sourceFolderName).sorted() == ["Archive", "INBOX"])
    let flaggedEntities = try repository.entityList(workspace: .flagged)
    #expect(flaggedEntities.map(\.displayName) == ["Github"])
    let flaggedLocations = try repository.messageLocations(entityID: mainEntity.id, workspace: .flagged)
    #expect(flaggedLocations.map(\.sourceFolderName) == ["INBOX"])
    let flaggedMessages = try repository.messages(entityID: mainEntity.id, workspace: .flagged)
    #expect(flaggedMessages[0].folderName == "INBOX")
    #expect(flaggedMessages[0].flags.contains("Flagged"))

    let didRemoveFlag = try repository.setMessageLocationFlag(
        accountKey: "work",
        folderName: "INBOX",
        himalayaEnvelopeID: "inbox-1",
        flag: "flagged",
        isEnabled: false
    )
    #expect(didRemoveFlag)
    #expect(try repository.entityList(workspace: .flagged).isEmpty)

    try repository.markMessageLocationMissing(
        accountKey: "work",
        folderName: "INBOX",
        himalayaEnvelopeID: "inbox-1"
    )
    let remainingLocations = try repository.messageLocations(entityID: mainEntity.id, workspace: .main, sourceRoles: [.normal])
    #expect(remainingLocations.map(\.sourceFolderName) == ["Archive"])

    let junkEntities = try repository.entityList(workspace: .junk)
    #expect(junkEntities.map(\.latestSubject) == ["Suspicious"])
}

@Test
func repositoryRelatesOutgoingMessagesToRecipients() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "Sent", role: .sent)
    ])

    try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Sent",
            himalayaEnvelopeID: "sent-1",
            rfcMessageID: "<sent-1@example.com>",
            subject: "Following up",
            from: MailAddress(displayName: "Ryan", emailAddress: "ryan@example.com"),
            to: [MailAddress(displayName: "Alice", emailAddress: "alice@example.com")],
            messageDate: "2026-05-03T09:00:00Z",
            direction: .outgoing
        )
    ])

    let entities = try repository.entityList(workspace: .main)
    #expect(entities.map(\.displayName) == ["Alice"])

    let entity = try #require(entities.first)
    #expect(entity.primaryEmailAddress == "alice@example.com")
    let messages = try repository.messages(entityID: entity.id, workspace: .main)
    #expect(messages.count == 1)
    #expect(messages[0].direction == .outgoing)
    #expect(messages[0].to.map(\.emailAddress) == ["alice@example.com"])
}

@Test
func repositoryPagesTimelineWithKeysetAnchors() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let sender = MailAddress(displayName: "Alice", emailAddress: "alice@example.com")
    let messageIDs = try repository.upsertEnvelopes((1...6).map { index in
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-\(index)",
            rfcMessageID: "<page-\(index)@example.com>",
            subject: "Message \(index)",
            from: sender,
            messageDate: "2026-05-0\(index)T10:00:00Z"
        )
    })

    let entity = try #require(try repository.entityList(workspace: .main).first)
    let latest = try repository.messages(
        entityID: entity.id,
        workspace: .main,
        includeBodies: false,
        limit: 3
    )
    #expect(latest.map(\.subject) == ["Message 4", "Message 5", "Message 6"])

    let older = try repository.messages(
        entityID: entity.id,
        workspace: .main,
        includeBodies: false,
        limit: 2,
        beforeMessageID: messageIDs[3]
    )
    #expect(older.map(\.subject) == ["Message 2", "Message 3"])

    let newer = try repository.messages(
        entityID: entity.id,
        workspace: .main,
        includeBodies: false,
        limit: 2,
        afterMessageID: messageIDs[2]
    )
    #expect(newer.map(\.subject) == ["Message 4", "Message 5"])
}
