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

    let accountColumns = try DatabaseSchemaInspector.columnNames(in: "accounts", databaseQueue: databaseQueue)
    #expect(accountColumns.isSuperset(of: [
        "account_key",
        "email_address",
        "provider_hint",
        "display_name",
        "is_default",
        "emoji"
    ]))

    let messageColumns = try DatabaseSchemaInspector.columnNames(in: "messages", databaseQueue: databaseQueue)
    #expect(messageColumns.isSuperset(of: [
        "account_key",
        "rfc_message_id",
        "fallback_dedupe_key",
        "subject",
        "from_sender_id",
        "message_date",
        "has_attachments"
    ]))

    let messageEntityColumns = try DatabaseSchemaInspector.columnNames(in: "message_entities", databaseQueue: databaseQueue)
    #expect(messageEntityColumns.isSuperset(of: [
        "message_id",
        "entity_id",
        "relation_kind",
        "timeline_direction"
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

    let checkpointColumns = try DatabaseSchemaInspector.columnNames(in: "sync_checkpoints", databaseQueue: databaseQueue)
    #expect(checkpointColumns.isSuperset(of: [
        "last_successful_sync_at",
        "last_successful_sync_started_at",
        "last_successful_sync_finished_at",
        "last_successful_query_start_at",
        "oldest_synced_message_date"
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

@Test
func workspacePolicyDefinesVisibleFolderRoles() {
    #expect(WorkspacePolicy.visibleRoles(for: .main) == [.normal, .sent])
    #expect(WorkspacePolicy.visibleRoles(for: .junk) == [.junk])
    #expect(WorkspacePolicy.visibleRoles(for: .flagged) == [.normal, .sent, .junk])
}

@Test
func entityActionPolicyDefinesSourceAndTargetRoles() {
    #expect(EntityActionPolicy.visibleActions(for: .main) == [.moveToJunk, .flagImportant, .moveToTrash])
    #expect(EntityActionPolicy.visibleActions(for: .junk) == [.moveToInbox, .flagImportant, .moveToTrash])
    #expect(EntityActionPolicy.visibleActions(for: .flagged) == [.moveToJunk, .removeFlag, .moveToTrash])

    #expect(EntityActionPolicy.hidesEntityInCurrentWorkspace(.moveToJunk, workspace: .main))
    #expect(EntityActionPolicy.hidesEntityInCurrentWorkspace(.moveToInbox, workspace: .junk))
    #expect(EntityActionPolicy.hidesEntityInCurrentWorkspace(.moveToTrash, workspace: .flagged))
    #expect(!EntityActionPolicy.hidesEntityInCurrentWorkspace(.flagImportant, workspace: .main))
    #expect(EntityActionPolicy.hidesEntityInCurrentWorkspace(.removeFlag, workspace: .flagged))
    #expect(!EntityActionPolicy.hidesEntityInCurrentWorkspace(.removeFlag, workspace: .main))

    #expect(EntityActionPolicy.sourceRoles(for: .moveToInbox) == [.junk])
    #expect(EntityActionPolicy.sourceRoles(for: .moveToJunk) == [.normal])
    #expect(EntityActionPolicy.sourceRoles(for: .moveToTrash) == WorkspacePolicy.visibleRoles(for: .flagged))
    #expect(EntityActionPolicy.sourceRoles(for: .flagImportant) == WorkspacePolicy.visibleRoles(for: .flagged))
    #expect(EntityActionPolicy.sourceRoles(for: .removeFlag) == WorkspacePolicy.visibleRoles(for: .flagged))

    #expect(EntityActionPolicy.targetRole(for: .moveToInbox) == .normal)
    #expect(EntityActionPolicy.targetRole(for: .moveToJunk) == .junk)
    #expect(EntityActionPolicy.targetRole(for: .moveToTrash) == .trash)
    #expect(EntityActionPolicy.targetRole(for: .flagImportant) == nil)
    #expect(EntityActionPolicy.targetRole(for: .removeFlag) == nil)
}
