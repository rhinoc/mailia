import Foundation
import GRDB

public struct MailRepository {
    private let databaseQueue: DatabaseQueue
    private let groupingRules: EntityGroupingRules
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(
        databaseQueue: DatabaseQueue,
        groupingRules: EntityGroupingRules = EntityGroupingRules()
    ) {
        self.databaseQueue = databaseQueue
        self.groupingRules = groupingRules
        self.jsonEncoder = JSONEncoder()
        self.jsonDecoder = JSONDecoder()
    }

    public func upsertAccounts(_ accounts: [DiscoveredAccount]) throws {
        try databaseQueue.write { db in
            for account in accounts where !account.accountKey.trimmed.isEmpty {
                try db.execute(
                    sql: """
                        INSERT INTO accounts (
                            account_key, email_address, provider_hint, display_name, updated_at
                        )
                        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                        ON CONFLICT(account_key) DO UPDATE SET
                            email_address = excluded.email_address,
                            provider_hint = excluded.provider_hint,
                            display_name = excluded.display_name,
                            updated_at = CURRENT_TIMESTAMP
                        """,
                    arguments: [
                        account.accountKey.trimmed,
                        account.emailAddress?.nilIfBlank,
                        account.providerHint?.nilIfBlank,
                        account.displayName?.nilIfBlank
                    ]
                )
            }
        }
    }

    public func upsertFolders(_ folders: [DiscoveredFolder]) throws {
        try databaseQueue.write { db in
            for folder in folders where !folder.accountKey.trimmed.isEmpty && !folder.providerName.trimmed.isEmpty {
                try db.execute(
                    sql: """
                        INSERT INTO folders (
                            account_key, provider_name, role, last_seen_at, missing_since_at
                        )
                        VALUES (?, ?, ?, CURRENT_TIMESTAMP, NULL)
                        ON CONFLICT(account_key, provider_name) DO UPDATE SET
                            role = excluded.role,
                            last_seen_at = CURRENT_TIMESTAMP,
                            missing_since_at = NULL
                        """,
                    arguments: [
                        folder.accountKey.trimmed,
                        folder.providerName.trimmed,
                        folder.role.rawValue
                    ]
                )
            }
        }
    }

    @discardableResult
    public func upsertEnvelopes(_ envelopes: [EnvelopeMessage]) throws -> [Int64] {
        try databaseQueue.write { db in
            var messageIDs: [Int64] = []
            for envelope in envelopes {
                guard !envelope.accountKey.trimmed.isEmpty,
                      !envelope.folderName.trimmed.isEmpty,
                      !envelope.himalayaEnvelopeID.trimmed.isEmpty
                else {
                    continue
                }

                let folderID = try requireFolderID(
                    db,
                    accountKey: envelope.accountKey.trimmed,
                    providerName: envelope.folderName.trimmed
                )
                let fromSenderID = try envelope.from.map { try upsertSender(db, address: $0) }
                let toJSON = try encodeAddresses(envelope.to)
                let ccJSON = try encodeAddresses(envelope.cc)
                let fallbackKey = fallbackDedupeKey(for: envelope)
                let messageID = try upsertMessage(
                    db,
                    envelope: envelope,
                    fromSenderID: fromSenderID,
                    toJSON: toJSON,
                    ccJSON: ccJSON,
                    fallbackDedupeKey: fallbackKey
                )

                try upsertLocation(
                    db,
                    messageID: messageID,
                    folderID: folderID,
                    envelope: envelope
                )
                try upsertMessageEntities(db, messageID: messageID, envelope: envelope)

                messageIDs.append(messageID)
            }
            return messageIDs
        }
    }

    public func folders(for workspace: Workspace? = nil) throws -> [StoredFolder] {
        return try databaseQueue.read { db in
            let whereClause: String
            let arguments: StatementArguments
            switch workspace {
            case .main:
                whereClause = "WHERE is_sync_enabled = 1 AND role IN ('normal', 'sent')"
                arguments = []
            case .junk:
                whereClause = "WHERE is_sync_enabled = 1 AND role = ?"
                arguments = [FolderRole.junk.rawValue]
            case .flagged:
                whereClause = "WHERE is_sync_enabled = 1 AND role IN ('normal', 'sent', 'junk')"
                arguments = []
            case .none:
                whereClause = "WHERE is_sync_enabled = 1"
                arguments = []
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, account_key, provider_name, role
                    FROM folders
                    \(whereClause)
                    ORDER BY account_key, provider_name
                    """,
                arguments: arguments
            )

            return rows.map { row in
                StoredFolder(
                    id: row["id"],
                    accountKey: row["account_key"],
                    providerName: row["provider_name"],
                    role: FolderRole(rawValue: row["role"]) ?? .unknown
                )
            }
        }
    }

    public func lastSuccessfulSyncAt(
        accountKey: String,
        folderID: Int64,
        workspace: Workspace
    ) throws -> Date? {
        try databaseQueue.read { db in
            let folderValue = try String.fetchOne(
                db,
                sql: """
                    SELECT last_successful_sync_at
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id = ?
                      AND workspace = ?
                    """,
                arguments: [accountKey, folderID, workspace.rawValue]
            )

            if let folderDate = Self.parseCheckpointDate(folderValue) {
                return folderDate
            }

            let accountValue = try String.fetchOne(
                db,
                sql: """
                    SELECT last_successful_sync_at
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id IS NULL
                      AND workspace = ?
                    """,
                arguments: [accountKey, workspace.rawValue]
            )
            return Self.parseCheckpointDate(accountValue)
        }
    }

    public func markFolderSyncSucceeded(
        accountKey: String,
        folderID: Int64,
        workspace: Workspace,
        at date: Date = Date()
    ) throws {
        let checkpointValue = Self.formatCheckpointDate(date)
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE folders
                    SET last_successful_sync_at = ?
                    WHERE id = ?
                    """,
                arguments: [checkpointValue, folderID]
            )
            try upsertSyncCheckpoint(
                db,
                accountKey: accountKey,
                folderID: folderID,
                workspace: workspace,
                checkpointValue: checkpointValue
            )
        }
    }

    public func markAccountSyncSucceeded(
        accountKey: String,
        workspace: Workspace,
        at date: Date = Date()
    ) throws {
        let checkpointValue = Self.formatCheckpointDate(date)
        try databaseQueue.write { db in
            try upsertSyncCheckpoint(
                db,
                accountKey: accountKey,
                folderID: nil,
                workspace: workspace,
                checkpointValue: checkpointValue
            )
        }
    }

    public func entityList(workspace: Workspace) throws -> [EntityListItem] {
        try databaseQueue.read { db in
            let roles = workspaceRoles(workspace)
            let entityFlagPredicate = workspaceEntityFlagPredicate(workspace: workspace)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH workspace_messages AS (
                        SELECT DISTINCT me.entity_id, m.id AS message_id
                        FROM message_entities me
                        JOIN messages m ON m.id = me.message_id
                        JOIN message_locations ml ON ml.message_id = m.id
                        JOIN folders f ON f.id = ml.folder_id
                        WHERE f.role IN (\(rolePlaceholders(count: roles.count)))
                          AND ml.missing_since_at IS NULL
                          \(entityFlagPredicate)
                    ),
                    latest_messages AS (
                        SELECT wm.entity_id, wm.message_id
                        FROM workspace_messages wm
                        JOIN messages m ON m.id = wm.message_id
                        WHERE NOT EXISTS (
                            SELECT 1
                            FROM workspace_messages newer_wm
                            JOIN messages newer_m ON newer_m.id = newer_wm.message_id
                            WHERE newer_wm.entity_id = wm.entity_id
                              AND COALESCE(newer_m.message_date, newer_m.created_at) >
                                  COALESCE(m.message_date, m.created_at)
                        )
                    ),
                    primary_senders AS (
                        SELECT
                            es.entity_id,
                            s.email_address,
                            ROW_NUMBER() OVER (
                                PARTITION BY es.entity_id
                                ORDER BY
                                    CASE es.relation_kind
                                        WHEN 'from' THEN 0
                                        WHEN 'to' THEN 1
                                        ELSE 2
                                    END,
                                    es.created_at ASC,
                                    s.normalized_email_address ASC
                            ) AS rank
                        FROM entity_senders es
                        JOIN senders s ON s.id = es.sender_id
                    )
                    SELECT
                        e.id AS entity_id,
                        e.display_name,
                        ps.email_address AS primary_email_address,
                        e.kind,
                        latest.subject AS latest_subject,
                        COALESCE(latest.message_date, latest.created_at) AS latest_message_date,
                        COUNT(DISTINCT wm.message_id) AS message_count,
                        GROUP_CONCAT(DISTINCT latest.account_key) AS account_keys
                    FROM workspace_messages wm
                    JOIN entities e ON e.id = wm.entity_id
                    JOIN latest_messages lm ON lm.entity_id = wm.entity_id
                    JOIN messages latest ON latest.id = lm.message_id
                    LEFT JOIN primary_senders ps ON ps.entity_id = e.id AND ps.rank = 1
                    GROUP BY e.id
                    ORDER BY latest_message_date DESC, e.display_name COLLATE NOCASE
                    """,
                arguments: StatementArguments(roles.map(\.rawValue))
            )

            return rows.map { row in
                EntityListItem(
                    id: row["entity_id"],
                    displayName: row["display_name"],
                    primaryEmailAddress: row["primary_email_address"],
                    latestSubject: row["latest_subject"],
                    latestDate: HimalayaDateParser.parse(row["latest_message_date"] as String?),
                    unreadCount: 0,
                    accountKeys: splitAccountKeys(row["account_keys"])
                )
            }
        }
    }

    public func messages(
        entityID: Int64,
        workspace: Workspace,
        includeBodies: Bool = true,
        limit: Int? = nil,
        beforeMessageID: Int64? = nil,
        afterMessageID: Int64? = nil
    ) throws -> [TimelineMessage] {
        precondition(!(beforeMessageID != nil && afterMessageID != nil), "Use either beforeMessageID or afterMessageID, not both")

        return try databaseQueue.read { db in
            let roles = workspaceRoles(workspace)
            var arguments = StatementArguments(roles.map(\.rawValue))
            _ = arguments.append(contentsOf: StatementArguments([entityID]))
            _ = arguments.append(contentsOf: StatementArguments([beforeMessageID ?? afterMessageID]))
            _ = arguments.append(contentsOf: StatementArguments([beforeMessageID]))
            _ = arguments.append(contentsOf: StatementArguments([afterMessageID]))
            if let limit {
                _ = arguments.append(contentsOf: StatementArguments([limit]))
            }
            _ = arguments.append(contentsOf: StatementArguments(roles.map(\.rawValue)))
            let bodySelect = includeBodies
                ? """
                        mb.sanitized_html,
                        mb.text_fallback
                """
                : """
                        NULL AS sanitized_html,
                        NULL AS text_fallback
                """
            let bodyJoin = includeBodies
                ? "LEFT JOIN message_bodies mb ON mb.message_id = m.id"
                : ""
            let limitClause = limit.map { _ in "LIMIT ?" } ?? ""
            let windowOrder = afterMessageID == nil
                ? "sm.sort_key DESC, sm.id DESC"
                : "sm.sort_key ASC, sm.id ASC"

            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH scoped_messages AS (
                        SELECT DISTINCT
                            m.id,
                            COALESCE(m.message_date, m.created_at) AS sort_key
                        FROM messages m
                        JOIN message_entities me ON me.message_id = m.id
                        JOIN message_locations ml ON ml.message_id = m.id
                        JOIN folders f ON f.id = ml.folder_id
                        WHERE f.role IN (\(rolePlaceholders(count: roles.count)))
                          AND ml.missing_since_at IS NULL
                          AND me.entity_id = ?
                    ),
                    cursor_message AS (
                        SELECT
                            id,
                            COALESCE(message_date, created_at) AS sort_key
                        FROM messages
                        WHERE id = ?
                    ),
                    windowed_messages AS (
                        SELECT sm.id
                        FROM scoped_messages sm
                        WHERE (
                            ? IS NULL
                            OR sm.sort_key < (SELECT sort_key FROM cursor_message)
                            OR (
                                sm.sort_key = (SELECT sort_key FROM cursor_message)
                                AND sm.id < (SELECT id FROM cursor_message)
                            )
                        )
                        AND (
                            ? IS NULL
                            OR sm.sort_key > (SELECT sort_key FROM cursor_message)
                            OR (
                                sm.sort_key = (SELECT sort_key FROM cursor_message)
                                AND sm.id > (SELECT id FROM cursor_message)
                            )
                        )
                        ORDER BY \(windowOrder)
                        \(limitClause)
                    ),
                    preferred_locations AS (
                        SELECT
                            ml.message_id,
                            f.provider_name,
                            ml.himalaya_envelope_id,
                            ml.flags_json,
                            ROW_NUMBER() OVER (
                                PARTITION BY ml.message_id
                                ORDER BY
                                    \(preferredFlagRank(workspace))
                                    CASE f.role
                                        WHEN 'sent' THEN 0
                                        WHEN 'normal' THEN 1
                                        WHEN 'junk' THEN 2
                                        ELSE 3
                                    END,
                                    ml.is_primary DESC,
                                    ml.id ASC
                            ) AS rank
                        FROM message_locations ml
                        JOIN folders f ON f.id = ml.folder_id
                        JOIN windowed_messages wm ON wm.id = ml.message_id
                        WHERE f.role IN (\(rolePlaceholders(count: roles.count)))
                          AND ml.missing_since_at IS NULL
                    )
                    SELECT
                        m.id AS message_id,
                        m.account_key,
                        pl.provider_name AS folder_name,
                        pl.himalaya_envelope_id,
                        pl.flags_json,
                        m.subject,
                        s.display_name AS from_display_name,
                        s.email_address AS from_email_address,
                        m.to_recipients_json,
                        m.cc_recipients_json,
                        m.message_date,
                        m.direction,
                        m.has_attachments,
                        \(bodySelect)
                    FROM windowed_messages wm
                    JOIN messages m ON m.id = wm.id
                    LEFT JOIN preferred_locations pl ON pl.message_id = m.id AND pl.rank = 1
                    LEFT JOIN senders s ON s.id = m.from_sender_id
                    \(bodyJoin)
                    ORDER BY COALESCE(m.message_date, m.created_at) ASC, m.id ASC
                    """,
                arguments: arguments
            )

            return try rows.map { row in
                let hasAttachments: Int = row["has_attachments"]
                return TimelineMessage(
                    messageID: row["message_id"],
                    accountKey: row["account_key"],
                    folderName: row["folder_name"],
                    himalayaEnvelopeID: row["himalaya_envelope_id"],
                    flags: try decodeStrings(row["flags_json"]),
                    subject: row["subject"],
                    from: makeAddress(displayName: row["from_display_name"], emailAddress: row["from_email_address"]),
                    to: try decodeAddresses(row["to_recipients_json"]),
                    cc: try decodeAddresses(row["cc_recipients_json"]),
                    messageDate: row["message_date"],
                    direction: MessageDirection(rawValue: row["direction"]) ?? .incoming,
                    hasAttachments: hasAttachments != 0,
                    sanitizedHTML: row["sanitized_html"],
                    textFallback: row["text_fallback"]
                )
            }
        }
    }

    public func messageBody(messageID: Int64) throws -> TimelineMessageBody? {
        try databaseQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT sanitized_html, text_fallback
                    FROM message_bodies
                    WHERE message_id = ?
                    """,
                arguments: [messageID]
            ) else {
                return nil
            }

            return TimelineMessageBody(
                sanitizedHTML: row["sanitized_html"],
                textFallback: row["text_fallback"]
            )
        }
    }

    public func messageLocations(
        entityID: Int64,
        workspace: Workspace,
        sourceRoles: [FolderRole]? = nil
    ) throws -> [MessageLocationTarget] {
        try databaseQueue.read { db in
            let roles = sourceRoles ?? workspaceRoles(workspace)
            guard !roles.isEmpty else { return [] }
            let flagPredicate = workspaceFlagPredicate(alias: "ml", workspace: workspace)

            var arguments = StatementArguments(roles.map(\.rawValue))
            _ = arguments.append(contentsOf: StatementArguments([entityID]))

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT
                        ml.message_id,
                        ml.account_key,
                        f.provider_name,
                        f.role,
                        ml.himalaya_envelope_id
                    FROM message_locations ml
                    JOIN folders f ON f.id = ml.folder_id
                    JOIN message_entities me ON me.message_id = ml.message_id
                    WHERE f.role IN (\(rolePlaceholders(count: roles.count)))
                      AND ml.missing_since_at IS NULL
                      \(flagPredicate)
                      AND me.entity_id = ?
                    ORDER BY ml.account_key, f.provider_name, ml.himalaya_envelope_id
                    """,
                arguments: arguments
            )

            return rows.map { row in
                MessageLocationTarget(
                    messageID: row["message_id"],
                    accountKey: row["account_key"],
                    sourceFolderName: row["provider_name"],
                    sourceFolderRole: FolderRole(rawValue: row["role"]) ?? .unknown,
                    himalayaEnvelopeID: row["himalaya_envelope_id"]
                )
            }
        }
    }

    @discardableResult
    public func setMessageLocationFlag(
        accountKey: String,
        folderName: String,
        himalayaEnvelopeID: String,
        flag: String,
        isEnabled: Bool
    ) throws -> Bool {
        let normalizedFlag = flag.trimmed.lowercased()
        guard !normalizedFlag.isEmpty else { return false }

        return try databaseQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT flags_json
                    FROM message_locations ml
                    JOIN folders f ON f.id = ml.folder_id
                    WHERE ml.account_key = ?
                      AND f.provider_name = ?
                      AND ml.himalaya_envelope_id = ?
                """,
                arguments: [accountKey, folderName, himalayaEnvelopeID]
            ) else {
                return false
            }

            var flags = try decodeStrings(row["flags_json"])
            flags.removeAll { $0.lowercased() == normalizedFlag }
            if isEnabled {
                flags.append(flag)
            }

            try db.execute(
                sql: """
                    UPDATE message_locations
                    SET flags_json = ?, last_seen_at = CURRENT_TIMESTAMP
                    WHERE account_key = ?
                      AND folder_id = (SELECT id FROM folders WHERE account_key = ? AND provider_name = ?)
                      AND himalaya_envelope_id = ?
                    """,
                arguments: [
                    try encodeStrings(flags),
                    accountKey,
                    accountKey,
                    folderName,
                    himalayaEnvelopeID
                ]
            )
            return db.changesCount > 0
        }
    }

    public func targetFolderName(accountKey: String, role: FolderRole) throws -> String? {
        try databaseQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT provider_name
                    FROM folders
                    WHERE account_key = ? AND role = ?
                    ORDER BY
                        CASE
                            WHEN ? = 'normal' AND UPPER(provider_name) = 'INBOX' THEN 0
                            WHEN ? = 'normal' THEN 1
                            ELSE 0
                        END,
                        provider_name COLLATE NOCASE
                    LIMIT 1
                    """,
                arguments: [accountKey, role.rawValue, role.rawValue, role.rawValue]
            )
        }
    }

    public func markMessageLocationMissing(
        accountKey: String,
        folderName: String,
        himalayaEnvelopeID: String
    ) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE message_locations
                    SET missing_since_at = CURRENT_TIMESTAMP
                    WHERE account_key = ?
                      AND himalaya_envelope_id = ?
                      AND folder_id = (
                          SELECT id
                          FROM folders
                          WHERE account_key = ? AND provider_name = ?
                      )
                    """,
                arguments: [accountKey, himalayaEnvelopeID, accountKey, folderName]
            )
        }
    }

    public func cacheMessageBody(
        messageID: Int64,
        sanitizedHTML: String?,
        textFallback: String?,
        sanitizerVersion: Int
    ) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message_bodies (
                        message_id, sanitized_html, text_fallback, sanitizer_version, fetched_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    ON CONFLICT(message_id) DO UPDATE SET
                        sanitized_html = excluded.sanitized_html,
                        text_fallback = excluded.text_fallback,
                        sanitizer_version = excluded.sanitizer_version,
                        updated_at = CURRENT_TIMESTAMP
                    """,
                arguments: [messageID, sanitizedHTML, textFallback, sanitizerVersion]
            )
        }
    }

    public func markFolderSyncSucceeded(folderID: Int64) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE folders
                    SET last_successful_sync_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                arguments: [folderID]
            )
        }
    }

    private func upsertSyncCheckpoint(
        _ db: Database,
        accountKey: String,
        folderID: Int64?,
        workspace: Workspace,
        checkpointValue: String
    ) throws {
        let existingID: Int64?
        if let folderID {
            existingID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id = ?
                      AND workspace = ?
                    """,
                arguments: [accountKey, folderID, workspace.rawValue]
            )
        } else {
            existingID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id IS NULL
                      AND workspace = ?
                    """,
                arguments: [accountKey, workspace.rawValue]
            )
        }

        if let existingID {
            try db.execute(
                sql: """
                    UPDATE sync_checkpoints
                    SET last_successful_sync_at = ?,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                arguments: [checkpointValue, existingID]
            )
            return
        }

        try db.execute(
            sql: """
                INSERT INTO sync_checkpoints (
                    account_key, folder_id, workspace, last_successful_sync_at, updated_at
                )
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                """,
            arguments: [accountKey, folderID, workspace.rawValue, checkpointValue]
        )
    }

    private func requireFolderID(_ db: Database, accountKey: String, providerName: String) throws -> Int64 {
        if let id = try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM folders
                WHERE account_key = ? AND provider_name = ?
                """,
            arguments: [accountKey, providerName]
        ) {
            return id
        }

        try db.execute(
            sql: """
                INSERT INTO folders (account_key, provider_name, role, last_seen_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                """,
            arguments: [accountKey, providerName, FolderRole.unknown.rawValue]
        )
        return db.lastInsertedRowID
    }

    private func upsertSender(_ db: Database, address: MailAddress) throws -> Int64 {
        let normalizedEmail = normalizeEmail(address.emailAddress)
        let domain = normalizedEmail.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init)
        try db.execute(
            sql: """
                INSERT INTO senders (
                    display_name, email_address, normalized_email_address, domain, updated_at
                )
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(normalized_email_address) DO UPDATE SET
                    display_name = COALESCE(excluded.display_name, senders.display_name),
                    email_address = excluded.email_address,
                    domain = excluded.domain,
                    updated_at = CURRENT_TIMESTAMP
                """,
            arguments: [
                address.displayName?.nilIfBlank,
                address.emailAddress.trimmed,
                normalizedEmail,
                domain
            ]
        )

        return try Int64.fetchOne(
            db,
            sql: "SELECT id FROM senders WHERE normalized_email_address = ?",
            arguments: [normalizedEmail]
        )!
    }

    private func upsertMessage(
        _ db: Database,
        envelope: EnvelopeMessage,
        fromSenderID: Int64?,
        toJSON: String?,
        ccJSON: String?,
        fallbackDedupeKey: String
    ) throws -> Int64 {
        let accountKey = envelope.accountKey.trimmed
        if let rfcMessageID = envelope.rfcMessageID?.nilIfBlank {
            try db.execute(
                sql: """
                    INSERT INTO messages (
                        account_key, rfc_message_id, fallback_dedupe_key, subject, from_sender_id,
                        to_recipients_json, cc_recipients_json, message_date, direction,
                        has_attachments, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    ON CONFLICT(account_key, rfc_message_id) DO UPDATE SET
                        fallback_dedupe_key = excluded.fallback_dedupe_key,
                        subject = excluded.subject,
                        from_sender_id = excluded.from_sender_id,
                        to_recipients_json = excluded.to_recipients_json,
                        cc_recipients_json = excluded.cc_recipients_json,
                        message_date = excluded.message_date,
                        direction = excluded.direction,
                        has_attachments = excluded.has_attachments,
                        updated_at = CURRENT_TIMESTAMP
                    """,
                arguments: messageArguments(
                    accountKey: accountKey,
                    rfcMessageID: rfcMessageID,
                    fallbackDedupeKey: fallbackDedupeKey,
                    envelope: envelope,
                    fromSenderID: fromSenderID,
                    toJSON: toJSON,
                    ccJSON: ccJSON
                )
            )

            return try Int64.fetchOne(
                db,
                sql: "SELECT id FROM messages WHERE account_key = ? AND rfc_message_id = ?",
                arguments: [accountKey, rfcMessageID]
            )!
        }

        try db.execute(
            sql: """
                INSERT INTO messages (
                    account_key, rfc_message_id, fallback_dedupe_key, subject, from_sender_id,
                    to_recipients_json, cc_recipients_json, message_date, direction,
                    has_attachments, updated_at
                )
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(account_key, fallback_dedupe_key) DO UPDATE SET
                    subject = excluded.subject,
                    from_sender_id = excluded.from_sender_id,
                    to_recipients_json = excluded.to_recipients_json,
                    cc_recipients_json = excluded.cc_recipients_json,
                    message_date = excluded.message_date,
                    direction = excluded.direction,
                    has_attachments = excluded.has_attachments,
                    updated_at = CURRENT_TIMESTAMP
                """,
            arguments: [
                accountKey,
                fallbackDedupeKey,
                envelope.subject?.nilIfBlank,
                fromSenderID,
                toJSON,
                ccJSON,
                envelope.messageDate?.nilIfBlank,
                envelope.direction.rawValue,
                envelope.hasAttachments ? 1 : 0
            ]
        )

        return try Int64.fetchOne(
            db,
            sql: "SELECT id FROM messages WHERE account_key = ? AND fallback_dedupe_key = ?",
            arguments: [accountKey, fallbackDedupeKey]
        )!
    }

    private func messageArguments(
        accountKey: String,
        rfcMessageID: String,
        fallbackDedupeKey: String,
        envelope: EnvelopeMessage,
        fromSenderID: Int64?,
        toJSON: String?,
        ccJSON: String?
    ) -> StatementArguments {
        [
            accountKey,
            rfcMessageID,
            fallbackDedupeKey,
            envelope.subject?.nilIfBlank,
            fromSenderID,
            toJSON,
            ccJSON,
            envelope.messageDate?.nilIfBlank,
            envelope.direction.rawValue,
            envelope.hasAttachments ? 1 : 0
        ]
    }

    private func upsertLocation(
        _ db: Database,
        messageID: Int64,
        folderID: Int64,
        envelope: EnvelopeMessage
    ) throws {
        let flagsJSON = try encodeStrings(envelope.flags)
        try db.execute(
            sql: """
                INSERT INTO message_locations (
                    message_id, account_key, folder_id, himalaya_envelope_id,
                    flags_json, is_primary, last_seen_at, missing_since_at
                )
                VALUES (?, ?, ?, ?, ?, 1, CURRENT_TIMESTAMP, NULL)
                ON CONFLICT(account_key, folder_id, himalaya_envelope_id) DO UPDATE SET
                    message_id = excluded.message_id,
                    flags_json = excluded.flags_json,
                    last_seen_at = CURRENT_TIMESTAMP,
                    missing_since_at = NULL
                """,
            arguments: [
                messageID,
                envelope.accountKey.trimmed,
                folderID,
                envelope.himalayaEnvelopeID.trimmed,
                flagsJSON
            ]
        )
    }

    private func upsertMessageEntities(
        _ db: Database,
        messageID: Int64,
        envelope: EnvelopeMessage
    ) throws {
        switch envelope.direction {
        case .incoming:
            guard let from = envelope.from else { return }
            let senderID = try upsertSender(db, address: from)
            let entityID = try upsertEntity(db, address: from, senderID: senderID, relationKind: .from)
            try upsertMessageEntity(db, messageID: messageID, entityID: entityID, relationKind: .from)
        case .outgoing:
            for recipient in envelope.to {
                let senderID = try upsertSender(db, address: recipient)
                let entityID = try upsertEntity(db, address: recipient, senderID: senderID, relationKind: .to)
                try upsertMessageEntity(db, messageID: messageID, entityID: entityID, relationKind: .to)
            }
        }
    }

    private func upsertEntity(
        _ db: Database,
        address: MailAddress,
        senderID: Int64,
        relationKind: RelationKind
    ) throws -> Int64 {
        let grouping = groupingRules.group(
            sender: SenderIdentity(displayName: address.displayName, email: address.emailAddress)
        )
        let kind: EntityKind = grouping.canonicalKey.hasPrefix("domain:") ? .service : .person
        try db.execute(
            sql: """
                INSERT INTO entities (display_name, kind, canonical_key, updated_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(canonical_key) DO UPDATE SET
                    display_name = excluded.display_name,
                    kind = excluded.kind,
                    updated_at = CURRENT_TIMESTAMP
                """,
            arguments: [grouping.displayName, kind.rawValue, grouping.canonicalKey]
        )

        let entityID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM entities WHERE canonical_key = ?",
            arguments: [grouping.canonicalKey]
        )!

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO entity_senders (entity_id, sender_id, relation_kind)
                VALUES (?, ?, ?)
                """,
            arguments: [entityID, senderID, relationKind.rawValue]
        )

        return entityID
    }

    private func upsertMessageEntity(
        _ db: Database,
        messageID: Int64,
        entityID: Int64,
        relationKind: RelationKind
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO message_entities (message_id, entity_id, relation_kind)
                VALUES (?, ?, ?)
                """,
            arguments: [messageID, entityID, relationKind.rawValue]
        )
    }

    private func fallbackDedupeKey(for envelope: EnvelopeMessage) -> String {
        if let provided = envelope.fallbackDedupeKey?.nilIfBlank {
            return provided
        }

        let senderKey = envelope.from.map { normalizeEmail($0.emailAddress) } ?? "unknown-sender"
        let subjectKey = envelope.subject?.normalizedDedupeComponent ?? "no-subject"
        if let messageDate = envelope.messageDate?.nilIfBlank {
            return "\(senderKey)|\(subjectKey)|\(messageDate)"
        }

        return "envelope|\(envelope.folderName.trimmed)|\(envelope.himalayaEnvelopeID.trimmed)"
    }

    private func encodeAddresses(_ addresses: [MailAddress]) throws -> String? {
        guard !addresses.isEmpty else { return nil }
        return String(data: try jsonEncoder.encode(addresses), encoding: .utf8)
    }

    private func decodeAddresses(_ json: String?) throws -> [MailAddress] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return try jsonDecoder.decode([MailAddress].self, from: data)
    }

    private func decodeStrings(_ json: String?) throws -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return try jsonDecoder.decode([String].self, from: data)
    }

    private func encodeStrings(_ strings: [String]) throws -> String? {
        guard !strings.isEmpty else { return nil }
        return String(data: try jsonEncoder.encode(strings), encoding: .utf8)
    }

    private func makeAddress(displayName: String?, emailAddress: String?) -> MailAddress? {
        guard let emailAddress, !emailAddress.trimmed.isEmpty else { return nil }
        return MailAddress(displayName: displayName?.nilIfBlank, emailAddress: emailAddress)
    }

    private func workspaceRoles(_ workspace: Workspace) -> [FolderRole] {
        switch workspace {
        case .main:
            return [.normal, .sent]
        case .junk:
            return [.junk]
        case .flagged:
            return [.normal, .sent, .junk]
        }
    }

    private func workspaceFlagPredicate(alias: String, workspace: Workspace) -> String {
        guard workspace == .flagged else { return "" }
        return "AND LOWER(COALESCE(\(alias).flags_json, '')) LIKE '%flagged%'"
    }

    private func preferredFlagRank(_ workspace: Workspace) -> String {
        guard workspace == .flagged else { return "" }
        return "CASE WHEN LOWER(COALESCE(ml.flags_json, '')) LIKE '%flagged%' THEN 0 ELSE 1 END,"
    }

    private func workspaceEntityFlagPredicate(workspace: Workspace) -> String {
        guard workspace == .flagged else { return "" }
        return """
        AND EXISTS (
            SELECT 1
            FROM message_entities flagged_me
            JOIN message_locations flagged_ml ON flagged_ml.message_id = flagged_me.message_id
            JOIN folders flagged_f ON flagged_f.id = flagged_ml.folder_id
            WHERE flagged_me.entity_id = me.entity_id
              AND flagged_f.role IN (\(roleLiterals(workspaceRoles(workspace))))
              AND flagged_ml.missing_since_at IS NULL
              AND LOWER(COALESCE(flagged_ml.flags_json, '')) LIKE '%flagged%'
        )
        """
    }

    private func roleLiterals(_ roles: [FolderRole]) -> String {
        roles.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    private func rolePlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func splitAccountKeys(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map(String.init)
    }

    private func normalizeEmail(_ emailAddress: String) -> String {
        emailAddress.trimmed.lowercased()
    }

    private static func formatCheckpointDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseCheckpointDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let date = HimalayaDateParser.parse(value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

extension MailRepository: @unchecked Sendable {}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    var normalizedDedupeComponent: String? {
        let value = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}
