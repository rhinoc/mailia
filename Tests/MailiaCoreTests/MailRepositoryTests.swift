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
    #expect(mainEntities.map(\.displayName) == ["GitHub"])

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
        htmlVariants: EmailHTMLDisplayVariants(
            remoteContentBlockedHTML: "<p>Build passed</p>",
            quotedReplyHiddenHTML: "<p>Build passed</p>",
            quotedReplyHiddenRemoteContentBlockedHTML: "<p>Build passed</p>"
        ),
        textFallback: "Build passed",
        sanitizerVersion: EmailHTMLDisplayPipeline.sanitizerVersion
    )
    let entitiesWithCachedPreview = try repository.entityList(workspace: .main)
    #expect(entitiesWithCachedPreview.first?.latestBodyPreview == "Build passed")

    messages = try repository.messages(entityID: mainEntity.id, workspace: .main)
    #expect(messages[0].sanitizedHTML == "<p>Build passed</p>")
    #expect(messages[0].htmlVariants?.remoteContentBlockedHTML == "<p>Build passed</p>")
    #expect(messages[0].textFallback == "Build passed")
    messages = try repository.messages(entityID: mainEntity.id, workspace: .main, includeBodies: false)
    #expect(messages[0].sanitizedHTML == nil)
    #expect(messages[0].textFallback == nil)
    let cachedBody = try #require(try repository.messageBody(messageID: messages[0].messageID))
    #expect(cachedBody.sanitizedHTML == "<p>Build passed</p>")
    #expect(cachedBody.htmlVariants?.remoteContentBlockedHTML == "<p>Build passed</p>")
    #expect(cachedBody.htmlVariants?.quotedReplyHiddenHTML == "<p>Build passed</p>")
    #expect(cachedBody.htmlVariants?.quotedReplyHiddenRemoteContentBlockedHTML == "<p>Build passed</p>")
    #expect(cachedBody.textFallback == "Build passed")
    #expect(cachedBody.sanitizerVersion == EmailHTMLDisplayPipeline.sanitizerVersion)
    let bodyCacheStats = try repository.messageBodyCacheStats()
    #expect(bodyCacheStats.itemCount == 1)
    #expect(bodyCacheStats.byteSize > 0)
    try repository.clearMessageBodyCache()
    #expect(try repository.messageBodyCacheStats().itemCount == 0)
    #expect(try repository.messageBody(messageID: messages[0].messageID) == nil)
    #expect(try repository.targetFolderName(accountKey: "work", role: .normal) == "INBOX")
    #expect(try repository.targetFolderName(accountKey: "work", role: .junk) == "Spam")
    #expect(try repository.targetFolderName(accountKey: "work", role: .trash) == "Trash")

    let locations = try repository.messageLocations(entityID: mainEntity.id, workspace: .main, sourceRoles: [.normal])
    #expect(locations.map(\.sourceFolderName).sorted() == ["Archive", "INBOX"])
    let messageLocations = try repository.messageLocations(messageID: messages[0].messageID)
    #expect(messageLocations.map(\.sourceFolderName).sorted() == ["Archive", "INBOX"])
    let didSetAttachments = try repository.setMessageHasAttachments(
        messageID: messages[0].messageID,
        hasAttachments: true
    )
    #expect(didSetAttachments)
    messages = try repository.messages(entityID: mainEntity.id, workspace: .main)
    #expect(messages[0].hasAttachments)
    let flaggedEntities = try repository.entityList(workspace: .flagged)
    #expect(flaggedEntities.map(\.displayName) == ["GitHub"])
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
func repositoryKeepsStableEntityWhenSenderDisplayNameChanges() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let senderWithoutName = MailAddress(emailAddress: "notifications@github.com")
    let senderWithName = MailAddress(displayName: "nextop-os/vibe-design", emailAddress: "notifications@github.com")
    let messageDate = "2026-05-31T01:47:00Z"

    let firstIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Build passed",
            from: senderWithoutName,
            messageDate: messageDate
        )
    ])
    let firstEntities = try repository.entityList(workspace: .main)
    #expect(firstEntities.count == 1)
    #expect(firstEntities[0].displayName == "Github")

    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Build passed",
            from: senderWithName,
            messageDate: messageDate
        )
    ])

    let refreshedEntities = try repository.entityList(workspace: .main)
    #expect(refreshedEntities.count == 1)
    #expect(refreshedEntities[0].id == firstEntities[0].id)
    #expect(refreshedEntities[0].displayName == "Github")

    let messages = try repository.messages(entityID: refreshedEntities[0].id, workspace: .main)
    #expect(messages.count == 1)
    #expect(messages[0].messageID == firstIDs[0])
}

@Test
func repositoryUpdatesServiceEntityDisplayNameFromLaterMatchingSender() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-1",
            subject: "Build passed",
            from: MailAddress(displayName: "nextop-os/vibe-design", emailAddress: "notifications@github.com"),
            messageDate: "2026-05-31T01:47:00Z"
        )
    ])

    var entities = try repository.entityList(workspace: .main)
    #expect(entities.count == 1)
    #expect(entities[0].displayName == "Github")

    _ = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-2",
            subject: "Security notice",
            from: MailAddress(displayName: "GitHub", emailAddress: "noreply@github.com"),
            messageDate: "2026-05-31T02:47:00Z"
        )
    ])

    entities = try repository.entityList(workspace: .main)
    #expect(entities.count == 1)
    #expect(entities[0].displayName == "GitHub")
}

@Test
func repositoryPersistsExpandedSyncCheckpointMetadata() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)
    try repository.upsertAccounts([DiscoveredAccount(accountKey: "work")])
    try repository.upsertFolders([DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)])
    let folder = try #require(try repository.folders(for: .main).first)
    let startedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:00Z"))
    let finishedAt = try #require(HimalayaDateParser.parse("2026-05-30T00:00:05Z"))
    let queryStartAt = try #require(HimalayaDateParser.parse("2026-05-29T00:00:00Z"))
    let oldest = try #require(HimalayaDateParser.parse("2026-05-01T10:00:00Z"))

    try repository.markFolderSyncSucceeded(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main,
        at: startedAt,
        startedAt: startedAt,
        finishedAt: finishedAt,
        queryStartAt: queryStartAt,
        oldestSyncedMessageDate: oldest
    )

    let checkpoint = try #require(try repository.syncCheckpoint(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main
    ))
    #expect(checkpoint.lastSuccessfulSyncAt == startedAt)
    #expect(checkpoint.lastSuccessfulSyncStartedAt == startedAt)
    #expect(checkpoint.lastSuccessfulSyncFinishedAt == finishedAt)
    #expect(checkpoint.lastSuccessfulQueryStartAt == queryStartAt)
    #expect(checkpoint.oldestSyncedMessageDate == oldest)
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
func repositoryOrdersEntityMessagesByParsedDateAcrossTimeZones() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@example.com")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Sent", role: .sent)
    ])

    let ryan = MailAddress(displayName: "Ryan", emailAddress: "ryan@example.com")
    let alice = MailAddress(displayName: "Alice", emailAddress: "alice@example.com")
    try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Sent",
            himalayaEnvelopeID: "sent-middle",
            subject: "Middle reply",
            from: ryan,
            to: [alice],
            messageDate: "2026-05-31 08:55+00:00",
            direction: .outgoing
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Sent",
            himalayaEnvelopeID: "sent-latest",
            subject: "Latest reply",
            from: ryan,
            to: [alice],
            messageDate: "2026-05-31 09:40+00:00",
            direction: .outgoing
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "inbox-earliest",
            subject: "Original",
            from: alice,
            to: [ryan],
            messageDate: "2026-05-31 16:36+08:00",
            direction: .incoming
        )
    ])

    let entity = try #require(try repository.entityList(workspace: .main).first)
    #expect(entity.latestSubject == "Latest reply")

    let messages = try repository.messages(entityID: entity.id, workspace: .main)
    #expect(messages.map(\.subject) == ["Original", "Middle reply", "Latest reply"])
}

@Test
func repositoryExposesHistoricalSubjectsForEntitySearch() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "outlook", emailAddress: "ryan@example.com")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "outlook", providerName: "INBOX", role: .normal)
    ])

    let paddle = MailAddress(displayName: "Paddle", emailAddress: "help@paddle.com")
    try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "outlook",
            folderName: "INBOX",
            himalayaEnvelopeID: "order",
            subject: "Your order: Swish",
            from: paddle,
            messageDate: "2019-06-30T02:41:00Z"
        ),
        EnvelopeMessage(
            accountKey: "outlook",
            folderName: "INBOX",
            himalayaEnvelopeID: "receipt",
            subject: "Your Highly Opinionated Purchases",
            from: paddle,
            messageDate: "2019-06-30T02:43:00Z"
        )
    ])

    let entity = try #require(try repository.entityList(workspace: .main).first)
    #expect(entity.displayName == "Paddle")
    #expect(entity.latestSubject == "Your Highly Opinionated Purchases")
    #expect(entity.searchableText?.contains("Your order: Swish") == true)
}

@Test
func repositoryComputesDirectionPerEntityWhenSelfOwnedAccountsExchangeMail() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@work.example", displayName: "Ryan Work"),
        DiscoveredAccount(accountKey: "personal", emailAddress: "ryan@personal.example", displayName: "Ryan Personal")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "work", providerName: "Sent", role: .sent),
        DiscoveredFolder(accountKey: "personal", providerName: "INBOX", role: .normal),
        DiscoveredFolder(accountKey: "personal", providerName: "Sent", role: .sent)
    ])

    let workAddress = MailAddress(displayName: "Ryan Work", emailAddress: "ryan@work.example")
    let personalAddress = MailAddress(displayName: "Ryan Personal", emailAddress: "ryan@personal.example")

    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "Sent",
            himalayaEnvelopeID: "work-sent-1",
            rfcMessageID: "<self-owned-1@example.com>",
            subject: "Lunch",
            from: workAddress,
            to: [personalAddress],
            messageDate: "2026-05-04T09:00:00Z",
            direction: .outgoing
        ),
        EnvelopeMessage(
            accountKey: "personal",
            folderName: "INBOX",
            himalayaEnvelopeID: "personal-inbox-1",
            rfcMessageID: "<self-owned-1@example.com>",
            subject: "Lunch",
            from: workAddress,
            to: [personalAddress],
            messageDate: "2026-05-04T09:00:00Z",
            direction: .incoming
        ),
        EnvelopeMessage(
            accountKey: "personal",
            folderName: "Sent",
            himalayaEnvelopeID: "personal-sent-1",
            rfcMessageID: "<self-owned-2@example.com>",
            subject: "Re: Lunch",
            from: personalAddress,
            to: [workAddress],
            messageDate: "2026-05-04T09:05:00Z",
            direction: .outgoing
        ),
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "work-inbox-1",
            rfcMessageID: "<self-owned-2@example.com>",
            subject: "Re: Lunch",
            from: personalAddress,
            to: [workAddress],
            messageDate: "2026-05-04T09:05:00Z",
            direction: .incoming
        )
    ])

    #expect(messageIDs[0] != messageIDs[1])
    #expect(messageIDs[2] != messageIDs[3])

    let entities = try repository.entityList(workspace: .main)
    let workEntity = try #require(entities.first { $0.primaryEmailAddress == "ryan@work.example" })
    let personalEntity = try #require(entities.first { $0.primaryEmailAddress == "ryan@personal.example" })

    let workMessages = try repository.messages(entityID: workEntity.id, workspace: .main)
    #expect(workMessages.map(\.messageID) == [messageIDs[1], messageIDs[2]])
    #expect(workMessages.map(\.direction) == [.incoming, .outgoing])
    #expect(workMessages.map(\.folderName) == ["INBOX", "Sent"])
    #expect(workMessages.map(\.accountKey) == ["personal", "personal"])

    let personalMessages = try repository.messages(entityID: personalEntity.id, workspace: .main)
    #expect(personalMessages.map(\.messageID) == [messageIDs[0], messageIDs[3]])
    #expect(personalMessages.map(\.direction) == [.outgoing, .incoming])
    #expect(personalMessages.map(\.folderName) == ["Sent", "INBOX"])
    #expect(personalMessages.map(\.accountKey) == ["work", "work"])
}

@Test
func repositoryComputesDirectionPerEntityForGmailSentAndAllMailLocations() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "gmail", emailAddress: "ryan@gmail.example", providerHint: "gmail")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "gmail", providerName: "[Gmail]/Sent Mail", role: .sent),
        DiscoveredFolder(accountKey: "gmail", providerName: "[Gmail]/All Mail", role: .normal)
    ])

    let sender = MailAddress(displayName: "Ryan", emailAddress: "ryan@gmail.example")
    let recipient = MailAddress(displayName: "Alice", emailAddress: "alice@example.com")

    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "gmail",
            folderName: "[Gmail]/Sent Mail",
            himalayaEnvelopeID: "sent-1",
            rfcMessageID: "<gmail-sent-all-mail-1@example.com>",
            subject: "Gmail duplicate location",
            from: sender,
            to: [recipient],
            messageDate: "2026-05-05T09:00:00Z",
            direction: .outgoing
        ),
        EnvelopeMessage(
            accountKey: "gmail",
            folderName: "[Gmail]/All Mail",
            himalayaEnvelopeID: "all-mail-1",
            rfcMessageID: "<gmail-sent-all-mail-1@example.com>",
            subject: "Gmail duplicate location",
            from: sender,
            to: [recipient],
            messageDate: "2026-05-05T09:00:00Z",
            direction: .incoming
        )
    ])

    #expect(messageIDs[0] == messageIDs[1])

    let entities = try repository.entityList(workspace: .main)
    let recipientEntity = try #require(entities.first { $0.primaryEmailAddress == "alice@example.com" })
    #expect(!(entities.contains { $0.primaryEmailAddress == "ryan@gmail.example" }))

    let recipientMessages = try repository.messages(entityID: recipientEntity.id, workspace: .main)
    #expect(recipientMessages.count == 1)
    #expect(recipientMessages[0].messageID == messageIDs[0])
    #expect(recipientMessages[0].direction == .outgoing)
    #expect(recipientMessages[0].folderName == "[Gmail]/Sent Mail")
}

@Test
func repositoryReturnsOneTimelineRowWhenSameEntityIsSenderAndRecipient() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@work.example")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let alice = MailAddress(displayName: "Alice", emailAddress: "alice@example.com")
    let messageIDs = try repository.upsertEnvelopes([
        EnvelopeMessage(
            accountKey: "work",
            folderName: "INBOX",
            himalayaEnvelopeID: "alice-self-1",
            rfcMessageID: "<alice-self-1@example.com>",
            subject: "Note to self",
            from: alice,
            to: [alice],
            messageDate: "2026-05-05T09:00:00Z",
            direction: .incoming
        )
    ])

    let entity = try #require(try repository.entityList(workspace: .main).first)
    let messages = try repository.messages(entityID: entity.id, workspace: .main, includeBodies: false)
    #expect(messages.map(\.messageID) == [messageIDs[0]])
    #expect(messages.map(\.direction) == [.incoming])
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

@Test
func accountEmojiPersistsAcrossUpsert() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@example.com", isDefault: true)
    ])
    try repository.updateAccountEmoji(accountKey: "work", emoji: "💼")
    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "ryan@work.com", displayName: "Work", isDefault: true)
    ])

    let accounts = try repository.accounts()
    #expect(accounts.count == 1)
    #expect(accounts[0].emailAddress == "ryan@work.com")
    #expect(accounts[0].isDefault == true)
    #expect(accounts[0].emoji == "💼")
}

@Test
func accountDefaultPersistsAsStructuredState() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", isDefault: true),
        DiscoveredAccount(accountKey: "personal", isDefault: false)
    ])

    var accounts = try repository.accounts()
    #expect(accounts.first { $0.accountKey == "work" }?.isDefault == true)
    #expect(accounts.first { $0.accountKey == "personal" }?.isDefault == false)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", isDefault: false),
        DiscoveredAccount(accountKey: "personal", isDefault: true)
    ])

    accounts = try repository.accounts()
    #expect(accounts.first { $0.accountKey == "work" }?.isDefault == false)
    #expect(accounts.first { $0.accountKey == "personal" }?.isDefault == true)
}

@Test
func accountSortOrderPersistsAndSurvivesDiscoveryRefresh() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", isDefault: true),
        DiscoveredAccount(accountKey: "personal"),
        DiscoveredAccount(accountKey: "billing")
    ])

    try repository.updateAccountSortOrder(accountKey: "work", sortOrder: 0)
    try repository.updateAccountSortOrder(accountKey: "billing", sortOrder: 1)
    try repository.updateAccountSortOrder(accountKey: "personal", sortOrder: 2)

    var accounts = try repository.accounts()
    #expect(accounts.map(\.accountKey) == ["work", "billing", "personal"])
    #expect(accounts.map(\.sortOrder) == [0, 1, 2])

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work", emailAddress: "work@example.com", isDefault: true),
        DiscoveredAccount(accountKey: "personal", emailAddress: "personal@example.com"),
        DiscoveredAccount(accountKey: "billing", emailAddress: "billing@example.com")
    ])

    accounts = try repository.accounts()
    #expect(accounts.map(\.accountKey) == ["work", "billing", "personal"])
    #expect(accounts.map(\.sortOrder) == [0, 1, 2])
}

@Test
func migrationCreatesSyncCheckpointMetadataColumns() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let checkpointColumns = try DatabaseSchemaInspector.columnNames(in: "sync_checkpoints", databaseQueue: databaseQueue)

    #expect(checkpointColumns.isSuperset(of: [
        "last_successful_sync_at",
        "last_successful_sync_started_at",
        "last_successful_sync_finished_at",
        "last_successful_query_start_at"
    ]))
}

@Test
func migrationCreatesMessageBodyDisplayVariantColumns() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let bodyColumns = try DatabaseSchemaInspector.columnNames(in: "message_bodies", databaseQueue: databaseQueue)

    #expect(bodyColumns.isSuperset(of: [
        "remote_blocked_html",
        "quoted_reply_hidden_html",
        "quoted_reply_hidden_remote_blocked_html"
    ]))
}

@Test
func repositoryPersistsFolderSyncCheckpointMetadata() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let folder = try #require(try repository.folders(for: .main).first)
    let queryStartAt = Date(timeIntervalSince1970: 1_800_000_000)
    let startedAt = Date(timeIntervalSince1970: 1_800_010_000)
    let finishedAt = Date(timeIntervalSince1970: 1_800_010_120)

    try repository.markFolderSyncSucceeded(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main,
        at: finishedAt,
        startedAt: startedAt,
        queryStartAt: queryStartAt
    )

    let checkpoint = try #require(try repository.syncCheckpoint(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main
    ))
    #expect(checkpoint.accountKey == "work")
    #expect(checkpoint.folderID == folder.id)
    #expect(checkpoint.workspace == .main)
    #expect(checkpoint.lastSuccessfulSyncAt == finishedAt)
    #expect(checkpoint.lastSuccessfulSyncStartedAt == startedAt)
    #expect(checkpoint.lastSuccessfulSyncFinishedAt == finishedAt)
    #expect(checkpoint.lastSuccessfulQueryStartAt == queryStartAt)
    #expect(try repository.lastSuccessfulSyncAt(accountKey: "work", folderID: folder.id, workspace: .main) == finishedAt)
}

@Test
func repositoryKeepsCheckpointCompatibilityForAccountFallbackAndOldMarkAPI() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work")
    ])

    let finishedAt = Date(timeIntervalSince1970: 1_800_020_000)
    try repository.markAccountSyncSucceeded(accountKey: "work", workspace: .main, at: finishedAt)

    let checkpoint = try #require(try repository.syncCheckpoint(
        accountKey: "work",
        folderID: 42,
        workspace: .main
    ))
    #expect(checkpoint.folderID == nil)
    #expect(checkpoint.lastSuccessfulSyncAt == finishedAt)
    #expect(checkpoint.lastSuccessfulSyncFinishedAt == finishedAt)
    #expect(checkpoint.lastSuccessfulSyncStartedAt == nil)
    #expect(checkpoint.lastSuccessfulQueryStartAt == nil)
    #expect(try repository.lastSuccessfulSyncAt(accountKey: "work", folderID: 42, workspace: .main) == finishedAt)
}

@Test
func repositoryReturnsMostRecentAccountRefreshFinishedAt() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let repository = MailRepository(databaseQueue: databaseQueue)

    try repository.upsertAccounts([
        DiscoveredAccount(accountKey: "work"),
        DiscoveredAccount(accountKey: "personal")
    ])
    try repository.upsertFolders([
        DiscoveredFolder(accountKey: "work", providerName: "INBOX", role: .normal)
    ])

    let folder = try #require(try repository.folders(for: .main).first)
    let olderFinishedAt = Date(timeIntervalSince1970: 1_800_020_000)
    let newerStartedAt = Date(timeIntervalSince1970: 1_800_030_000)
    let newerFinishedAt = Date(timeIntervalSince1970: 1_800_030_120)
    try repository.markAccountSyncSucceeded(accountKey: "work", workspace: .main, at: olderFinishedAt)
    try repository.markAccountSyncSucceeded(
        accountKey: "personal",
        workspace: .junk,
        at: newerStartedAt,
        startedAt: newerStartedAt,
        finishedAt: newerFinishedAt
    )
    try repository.markFolderSyncSucceeded(
        accountKey: "work",
        folderID: folder.id,
        workspace: .main,
        at: newerFinishedAt.addingTimeInterval(60)
    )

    #expect(try repository.lastSuccessfulRefreshFinishedAt() == newerFinishedAt)
}
