import GRDB

public enum DatabaseMigratorFactory {
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_schema") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    account_key TEXT PRIMARY KEY NOT NULL,
                    email_address TEXT,
                    provider_hint TEXT,
                    display_name TEXT,
                    is_sync_enabled INTEGER NOT NULL DEFAULT 1,
                    last_sync_status TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE folders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_key TEXT NOT NULL REFERENCES accounts(account_key) ON DELETE CASCADE,
                    provider_name TEXT NOT NULL,
                    role TEXT NOT NULL DEFAULT 'unknown',
                    is_sync_enabled INTEGER NOT NULL DEFAULT 1,
                    first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    last_seen_at TEXT,
                    missing_since_at TEXT,
                    last_successful_sync_at TEXT,
                    UNIQUE (account_key, provider_name)
                );

                CREATE TABLE senders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    display_name TEXT,
                    email_address TEXT NOT NULL,
                    normalized_email_address TEXT NOT NULL UNIQUE,
                    domain TEXT,
                    kind_hint TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE entities (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    display_name TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'unknown',
                    canonical_key TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE entity_senders (
                    entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    sender_id INTEGER NOT NULL REFERENCES senders(id) ON DELETE CASCADE,
                    relation_kind TEXT NOT NULL DEFAULT 'from',
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (entity_id, sender_id, relation_kind)
                );

                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_key TEXT NOT NULL REFERENCES accounts(account_key) ON DELETE CASCADE,
                    rfc_message_id TEXT,
                    fallback_dedupe_key TEXT,
                    subject TEXT,
                    from_sender_id INTEGER REFERENCES senders(id) ON DELETE SET NULL,
                    to_recipients_json TEXT,
                    cc_recipients_json TEXT,
                    message_date TEXT,
                    direction TEXT NOT NULL DEFAULT 'incoming',
                    has_attachments INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE (account_key, rfc_message_id),
                    UNIQUE (account_key, fallback_dedupe_key)
                );

                CREATE TABLE message_locations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    account_key TEXT NOT NULL REFERENCES accounts(account_key) ON DELETE CASCADE,
                    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    himalaya_envelope_id TEXT NOT NULL,
                    flags_json TEXT,
                    is_primary INTEGER NOT NULL DEFAULT 0,
                    first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    last_seen_at TEXT,
                    missing_since_at TEXT,
                    UNIQUE (account_key, folder_id, himalaya_envelope_id)
                );

                CREATE TABLE message_bodies (
                    message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    sanitized_html TEXT,
                    text_fallback TEXT,
                    sanitizer_version INTEGER NOT NULL,
                    fetched_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE message_entities (
                    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    relation_kind TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (message_id, entity_id, relation_kind)
                );

                CREATE TABLE trusted_senders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    normalized_email_address TEXT NOT NULL UNIQUE,
                    entity_id INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                    is_active INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE sync_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_key TEXT REFERENCES accounts(account_key) ON DELETE SET NULL,
                    folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
                    scope TEXT,
                    status TEXT NOT NULL,
                    started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    finished_at TEXT,
                    error_message TEXT
                );

                CREATE TABLE sync_checkpoints (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_key TEXT NOT NULL REFERENCES accounts(account_key) ON DELETE CASCADE,
                    folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
                    workspace TEXT NOT NULL,
                    last_successful_sync_at TEXT,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE action_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    action_type TEXT NOT NULL,
                    account_key TEXT REFERENCES accounts(account_key) ON DELETE SET NULL,
                    folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
                    message_id INTEGER REFERENCES messages(id) ON DELETE SET NULL,
                    sender_id INTEGER REFERENCES senders(id) ON DELETE SET NULL,
                    entity_id INTEGER REFERENCES entities(id) ON DELETE SET NULL,
                    himalaya_envelope_id TEXT,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    metadata_json TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX idx_folders_account_role ON folders(account_key, role);
                CREATE INDEX idx_messages_account_date ON messages(account_key, message_date);
                CREATE INDEX idx_message_locations_message ON message_locations(message_id);
                CREATE INDEX idx_message_locations_folder ON message_locations(folder_id);
                CREATE INDEX idx_message_entities_entity ON message_entities(entity_id);
                CREATE INDEX idx_sync_runs_started ON sync_runs(started_at);
                CREATE UNIQUE INDEX idx_sync_checkpoints_account
                    ON sync_checkpoints(account_key, workspace)
                    WHERE folder_id IS NULL;
                CREATE UNIQUE INDEX idx_sync_checkpoints_folder
                    ON sync_checkpoints(account_key, folder_id, workspace)
                    WHERE folder_id IS NOT NULL;
                CREATE INDEX idx_action_log_created ON action_log(created_at);
                """)
        }

        return migrator
    }
}

public enum DatabaseSchemaInspector {
    public static func makeMigratedInMemoryDatabase() throws -> DatabaseQueue {
        let databaseQueue = try DatabaseQueue()
        try DatabaseMigratorFactory.makeMigrator().migrate(databaseQueue)
        return databaseQueue
    }

    public static func tableNames(in databaseQueue: DatabaseQueue) throws -> Set<String> {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name NOT LIKE 'sqlite_%'
                    """
            )

            return Set(rows.compactMap { row in row["name"] as String? })
        }
    }

    public static func columnNames(in tableName: String, databaseQueue: DatabaseQueue) throws -> Set<String> {
        try databaseQueue.read { db in
            let columns = try db.columns(in: tableName)
            return Set(columns.map(\.name))
        }
    }
}
