import Testing
@testable import MailiaCore

@Test
func exposesVersion() {
    #expect(MailiaCore.version == "0.1.0")
}

@Test
func databaseMigrationCreatesCoreTables() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()
    let tableNames = try DatabaseSchemaInspector.tableNames(in: databaseQueue)

    let expectedTables: Set<String> = [
        "accounts",
        "folders",
        "messages",
        "message_locations",
        "message_bodies",
        "senders",
        "entities",
        "entity_senders",
        "message_entities",
        "trusted_senders",
        "sync_runs",
        "sync_checkpoints",
        "action_log"
    ]

    #expect(expectedTables.isSubset(of: tableNames))
}

@Test
func databaseMigrationCreatesKeyColumns() throws {
    let databaseQueue = try DatabaseSchemaInspector.makeMigratedInMemoryDatabase()

    let messageColumns = try DatabaseSchemaInspector.columnNames(in: "messages", databaseQueue: databaseQueue)
    #expect(messageColumns.isSuperset(of: [
        "account_key",
        "rfc_message_id",
        "fallback_dedupe_key",
        "subject",
        "from_sender_id",
        "message_date",
        "direction",
        "has_attachments"
    ]))

    let locationColumns = try DatabaseSchemaInspector.columnNames(in: "message_locations", databaseQueue: databaseQueue)
    #expect(locationColumns.isSuperset(of: [
        "message_id",
        "account_key",
        "folder_id",
        "himalaya_envelope_id",
        "flags_json",
        "is_primary"
    ]))
}

@Test
func modelEnumsUsePersistableRawValues() {
    #expect(FolderRole.junk.rawValue == "junk")
    #expect(MessageDirection.outgoing.rawValue == "outgoing")
    #expect(EntityKind.newsletter.rawValue == "newsletter")
    #expect(RelationKind.from.rawValue == "from")
    #expect(ActionType.moveToInbox.rawValue == "move_to_inbox")
}
