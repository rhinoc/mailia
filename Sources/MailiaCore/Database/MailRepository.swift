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
                            account_key, email_address, provider_hint, display_name, is_default, sort_order, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                        ON CONFLICT(account_key) DO UPDATE SET
                            email_address = excluded.email_address,
                            provider_hint = excluded.provider_hint,
                            display_name = excluded.display_name,
                            is_default = excluded.is_default,
                            sort_order = COALESCE(excluded.sort_order, accounts.sort_order),
                            updated_at = CURRENT_TIMESTAMP
                        """,
                    arguments: [
                        account.accountKey.trimmed,
                        account.emailAddress?.nilIfBlank,
                        account.providerHint?.nilIfBlank,
                        account.displayName?.nilIfBlank,
                        account.isDefault,
                        account.sortOrder
                    ]
                )
            }
        }
    }

    public func accounts() throws -> [DiscoveredAccount] {
        try databaseQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT account_key, email_address, provider_hint, display_name, is_default, emoji, sort_order,
                           last_sync_status, last_sync_error_message, last_sync_checked_at
                    FROM accounts
                    ORDER BY is_default DESC, sort_order IS NULL, sort_order, account_key
                    """
            )
            .map { row in
                DiscoveredAccount(
                    accountKey: row["account_key"],
                    emailAddress: row["email_address"],
                    providerHint: row["provider_hint"],
                    displayName: row["display_name"],
                    isDefault: row["is_default"],
                    emoji: row["emoji"],
                    sortOrder: row["sort_order"],
                    syncStatus: row["last_sync_status"],
                    syncErrorMessage: row["last_sync_error_message"],
                    syncCheckedAt: Self.parseCheckpointDate(row["last_sync_checked_at"] as String?)
                )
            }
        }
    }

    public func updateAccountEmoji(accountKey: String, emoji: String?) throws {
        let trimmedKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET emoji = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE account_key = ?
                    """,
                arguments: [emoji?.nilIfBlank, trimmedKey]
            )
        }
    }

    public func updateAccountSortOrder(accountKey: String, sortOrder: Int?) throws {
        let trimmedKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET sort_order = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE account_key = ?
                    """,
                arguments: [sortOrder, trimmedKey]
            )
        }
    }

    public func markAccountSyncStatus(
        accountKey: String,
        status: String,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) throws {
        let trimmedKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET last_sync_status = ?,
                        last_sync_error_message = ?,
                        last_sync_checked_at = ?,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE account_key = ?
                    """,
                arguments: [
                    status.nilIfBlank,
                    Self.normalizedSyncError(errorMessage),
                    Self.formatCheckpointDate(date),
                    trimmedKey
                ]
            )
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
                let ownEmailAddresses = try ownEmailAddresses(db)
                let accountEmailAddress = try accountEmailAddress(db, accountKey: envelope.accountKey.trimmed)
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
                try rebuildMessageEntities(
                    db,
                    messageID: messageID,
                    envelope: envelope,
                    ownEmailAddresses: ownEmailAddresses,
                    accountEmailAddress: accountEmailAddress
                )

                messageIDs.append(messageID)
            }
            return messageIDs
        }
    }

    public func folders(for workspace: Workspace? = nil) throws -> [StoredFolder] {
        return try databaseQueue.read { db in
            let whereClause: String
            let arguments: StatementArguments
            if let workspace {
                let roles = WorkspacePolicy.visibleRoles(for: workspace)
                guard !roles.isEmpty else { return [] }
                let placeholders = Array(repeating: "?", count: roles.count).joined(separator: ", ")
                whereClause = "WHERE is_sync_enabled = 1 AND role IN (\(placeholders))"
                arguments = StatementArguments(roles.map(\.rawValue))
            } else {
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
        try syncCheckpoint(accountKey: accountKey, folderID: folderID, workspace: workspace)?.lastSuccessfulSyncAt
    }

    public func lastSuccessfulRefreshFinishedAt() throws -> Date? {
        try databaseQueue.read { db in
            let value = try String.fetchOne(
                db,
                sql: """
                    SELECT MAX(datetime(COALESCE(last_successful_sync_finished_at, last_successful_sync_at)))
                    FROM sync_checkpoints
                    WHERE folder_id IS NULL
                    """
            )
            return Self.parseCheckpointDate(value)
        }
    }

    public func syncCheckpoint(
        accountKey: String,
        folderID: Int64?,
        workspace: Workspace
    ) throws -> SyncCheckpoint? {
        try databaseQueue.read { db in
            if let folderID,
               let checkpoint = try fetchSyncCheckpoint(
                    db,
                    accountKey: accountKey,
                    folderID: folderID,
                    workspace: workspace
               ) {
                return checkpoint
            }

            return try fetchSyncCheckpoint(
                db,
                accountKey: accountKey,
                folderID: nil,
                workspace: workspace
            )
        }
    }

    public func markFolderSyncSucceeded(
        accountKey: String,
        folderID: Int64,
        workspace: Workspace,
        at date: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        queryStartAt: Date? = nil,
        oldestSyncedMessageDate: Date? = nil
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
                checkpointValue: checkpointValue,
                startedValue: startedAt.map(Self.formatCheckpointDate),
                finishedValue: Self.formatCheckpointDate(finishedAt ?? date),
                queryStartValue: queryStartAt.map(Self.formatCheckpointDate),
                oldestSyncedMessageValue: oldestSyncedMessageDate.map(Self.formatCheckpointDate)
            )
        }
    }

    public func markAccountSyncSucceeded(
        accountKey: String,
        workspace: Workspace,
        at date: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        queryStartAt: Date? = nil,
        oldestSyncedMessageDate: Date? = nil
    ) throws {
        let checkpointValue = Self.formatCheckpointDate(date)
        try databaseQueue.write { db in
            try upsertSyncCheckpoint(
                db,
                accountKey: accountKey,
                folderID: nil,
                workspace: workspace,
                checkpointValue: checkpointValue,
                startedValue: startedAt.map(Self.formatCheckpointDate),
                finishedValue: Self.formatCheckpointDate(finishedAt ?? date),
                queryStartValue: queryStartAt.map(Self.formatCheckpointDate),
                oldestSyncedMessageValue: oldestSyncedMessageDate.map(Self.formatCheckpointDate)
            )
        }
    }

    public func entityList(workspace: Workspace) throws -> [EntityListItem] {
        try databaseQueue.read { db in
            let scope = WorkspaceScopeSQL(workspace: workspace)
            let messageSortKey = scope.messageSortKey(alias: "m")
            let newerMessageSortKey = scope.messageSortKey(alias: "newer_m")
            let latestMessageSortKey = scope.messageSortKey(alias: "latest")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH workspace_messages AS (
                        SELECT DISTINCT
                            me.entity_id,
                            m.id AS message_id,
                            CASE
                                WHEN LOWER(COALESCE(ml.flags_json, '')) LIKE '%seen%' THEN 0
                                ELSE 1
                            END AS is_unread
                        FROM message_entities me
                        JOIN messages m ON m.id = me.message_id
                        JOIN message_locations ml ON ml.message_id = m.id
                        JOIN folders f ON f.id = ml.folder_id
                        WHERE \(scope.locationVisibilityPredicate(locationAlias: "ml", folderAlias: "f"))
                          \(scope.entityVisibilityPredicate(entityAlias: "me"))
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
                              AND \(newerMessageSortKey) > \(messageSortKey)
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
                    ),
                    entity_email_addresses AS (
                        SELECT
                            es.entity_id,
                            GROUP_CONCAT(DISTINCT s.email_address) AS email_addresses
                        FROM entity_senders es
                        JOIN senders s ON s.id = es.sender_id
                        GROUP BY es.entity_id
                    )
                    SELECT
                        e.id AS entity_id,
                        e.display_name,
                        ps.email_address AS primary_email_address,
                        eea.email_addresses,
                        e.kind,
                        latest.id AS latest_message_id,
                        latest.subject AS latest_subject,
                        GROUP_CONCAT(DISTINCT search_message.subject) AS searchable_text,
                        latest_body.text_fallback AS latest_body_preview,
                        COALESCE(latest.message_date, latest.created_at) AS latest_message_date,
                        \(latestMessageSortKey) AS latest_sort_key,
                        COUNT(DISTINCT wm.message_id) AS message_count,
                        COUNT(DISTINCT CASE WHEN wm.is_unread = 1 THEN wm.message_id END) AS unread_count,
                        GROUP_CONCAT(DISTINCT latest.account_key) AS account_keys
                    FROM workspace_messages wm
                    JOIN entities e ON e.id = wm.entity_id
                    JOIN latest_messages lm ON lm.entity_id = wm.entity_id
                    JOIN messages latest ON latest.id = lm.message_id
                    LEFT JOIN messages search_message ON search_message.id = wm.message_id
                    LEFT JOIN message_bodies latest_body
                      ON latest_body.message_id = latest.id
                     AND latest_body.sanitizer_version = \(EmailHTMLDisplayPipeline.sanitizerVersion)
                    LEFT JOIN primary_senders ps ON ps.entity_id = e.id AND ps.rank = 1
                    LEFT JOIN entity_email_addresses eea ON eea.entity_id = e.id
                    GROUP BY e.id
                    ORDER BY latest_sort_key DESC, e.display_name COLLATE NOCASE
                    """,
                arguments: StatementArguments(scope.roleValues)
            )

            return rows.map { row in
                EntityListItem(
                    id: row["entity_id"],
                    displayName: row["display_name"],
                    primaryEmailAddress: row["primary_email_address"],
                    emailAddresses: splitCommaSeparatedValues(row["email_addresses"]),
                    latestSubject: row["latest_subject"],
                    searchableText: row["searchable_text"],
                    latestBodyPreview: row["latest_body_preview"],
                    latestMessageID: row["latest_message_id"],
                    latestDate: HimalayaDateParser.parse(row["latest_message_date"] as String?),
                    unreadCount: row["unread_count"],
                    accountKeys: splitCommaSeparatedValues(row["account_keys"])
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
            let scope = WorkspaceScopeSQL(workspace: workspace)
            var arguments = StatementArguments(scope.roleValues)
            _ = arguments.append(contentsOf: StatementArguments([entityID]))
            _ = arguments.append(contentsOf: StatementArguments([beforeMessageID ?? afterMessageID]))
            _ = arguments.append(contentsOf: StatementArguments([beforeMessageID]))
            _ = arguments.append(contentsOf: StatementArguments([afterMessageID]))
            if let limit {
                _ = arguments.append(contentsOf: StatementArguments([limit]))
            }
            _ = arguments.append(contentsOf: StatementArguments(scope.roleValues))
            let bodySelect = includeBodies
                ? """
                        mb.sanitized_html,
                        mb.remote_blocked_html,
                        mb.quoted_reply_hidden_html,
                        mb.quoted_reply_hidden_remote_blocked_html,
                        mb.text_fallback,
                        mb.sanitizer_version
                """
                : """
                        NULL AS sanitized_html,
                        NULL AS remote_blocked_html,
                        NULL AS quoted_reply_hidden_html,
                        NULL AS quoted_reply_hidden_remote_blocked_html,
                        NULL AS text_fallback,
                        NULL AS sanitizer_version
                """
            let bodyJoin = includeBodies
                ? """
                    LEFT JOIN message_bodies mb
                      ON mb.message_id = m.id
                     AND mb.sanitizer_version = \(EmailHTMLDisplayPipeline.sanitizerVersion)
                """
                : ""
            let limitClause = limit.map { _ in "LIMIT ?" } ?? ""
            let windowOrder = afterMessageID == nil
                ? "sm.sort_key DESC, sm.id DESC"
                : "sm.sort_key ASC, sm.id ASC"
            let messageSortKey = scope.messageSortKey(alias: "m")
            let bareMessageSortKey = scope.messageSortKey(alias: nil)

            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH eligible_locations AS (
                        SELECT
                            ml.message_id,
                            MAX(CASE WHEN f.role = 'sent' THEN 1 ELSE 0 END) AS has_sent_location,
                            MAX(CASE WHEN f.role = 'normal' THEN 1 ELSE 0 END) AS has_normal_location
                        FROM message_locations ml
                        JOIN folders f ON f.id = ml.folder_id
                        WHERE \(scope.locationVisibilityPredicate(locationAlias: "ml", folderAlias: "f"))
                        GROUP BY ml.message_id
                    ),
                    ranked_message_relations AS (
                        SELECT
                            m.id,
                            me.timeline_direction,
                            \(messageSortKey) AS sort_key,
                            ROW_NUMBER() OVER (
                                PARTITION BY m.id
                                ORDER BY
                                    CASE
                                        WHEN me.timeline_direction = 'outgoing' AND el.has_sent_location = 1 THEN 0
                                        WHEN me.timeline_direction = 'incoming' AND el.has_normal_location = 1 THEN 0
                                        ELSE 1
                                    END,
                                    CASE me.relation_kind
                                        WHEN 'from' THEN 0
                                        WHEN 'to' THEN 1
                                        WHEN 'cc' THEN 2
                                        WHEN 'bcc' THEN 3
                                        ELSE 4
                                    END,
                                    me.timeline_direction
                            ) AS relation_rank
                        FROM messages m
                        JOIN message_entities me ON me.message_id = m.id
                        JOIN eligible_locations el ON el.message_id = m.id
                        WHERE me.entity_id = ?
                    ),
                    scoped_messages AS (
                        SELECT id, timeline_direction, sort_key
                        FROM ranked_message_relations
                        WHERE relation_rank = 1
                    ),
                    cursor_message AS (
                        SELECT
                            id,
                            \(bareMessageSortKey) AS sort_key
                        FROM messages
                        WHERE id = ?
                    ),
                    windowed_messages AS (
                        SELECT sm.id, sm.timeline_direction
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
                            wm.timeline_direction,
                            f.provider_name,
                            ml.himalaya_envelope_id,
                            ml.flags_json,
                            ROW_NUMBER() OVER (
                                PARTITION BY ml.message_id
                                ORDER BY \(scope.preferredLocationOrder(
                                    locationAlias: "ml",
                                    folderAlias: "f",
                                    directionExpression: "wm.timeline_direction"
                                ))
                            ) AS rank
                        FROM message_locations ml
                        JOIN folders f ON f.id = ml.folder_id
                        JOIN windowed_messages wm ON wm.id = ml.message_id
                        WHERE \(scope.locationVisibilityPredicate(locationAlias: "ml", folderAlias: "f"))
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
                        wm.timeline_direction,
                        m.has_attachments,
                        \(bodySelect)
                    FROM windowed_messages wm
                    JOIN messages m ON m.id = wm.id
                    LEFT JOIN preferred_locations pl ON pl.message_id = m.id AND pl.rank = 1
                    LEFT JOIN senders s ON s.id = m.from_sender_id
                    \(bodyJoin)
                    ORDER BY \(messageSortKey) ASC, m.id ASC
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
                    direction: MessageDirection(rawValue: row["timeline_direction"]) ?? .incoming,
                    hasAttachments: hasAttachments != 0,
                    sanitizedHTML: row["sanitized_html"],
                    htmlVariants: Self.htmlVariants(from: row),
                    textFallback: row["text_fallback"],
                    sanitizerVersion: row["sanitizer_version"]
                )
            }
        }
    }

    public func messageBody(messageID: Int64) throws -> TimelineMessageBody? {
        try databaseQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        sanitized_html,
                        remote_blocked_html,
                        quoted_reply_hidden_html,
                        quoted_reply_hidden_remote_blocked_html,
                        text_fallback,
                        sanitizer_version
                    FROM message_bodies
                    WHERE message_id = ?
                      AND sanitizer_version = ?
                    """,
                arguments: [messageID, EmailHTMLDisplayPipeline.sanitizerVersion]
            ) else {
                return nil
            }

            return TimelineMessageBody(
                sanitizedHTML: row["sanitized_html"],
                htmlVariants: Self.htmlVariants(from: row),
                textFallback: row["text_fallback"],
                sanitizerVersion: row["sanitizer_version"]
            )
        }
    }

    public func messageBodyCacheStats() throws -> CacheStats {
        try databaseQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS item_count,
                        COALESCE(SUM(
                            LENGTH(COALESCE(sanitized_html, '')) +
                            LENGTH(COALESCE(remote_blocked_html, '')) +
                            LENGTH(COALESCE(quoted_reply_hidden_html, '')) +
                            LENGTH(COALESCE(quoted_reply_hidden_remote_blocked_html, '')) +
                            LENGTH(COALESCE(text_fallback, ''))
                        ), 0) AS byte_size
                    FROM message_bodies
                    """
            )

            return CacheStats(
                itemCount: row?["item_count"] ?? 0,
                byteSize: row?["byte_size"] ?? 0
            )
        }
    }

    public func clearMessageBodyCache() throws {
        try databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM message_bodies")
        }
    }

    public func messageLocations(
        entityID: Int64,
        workspace: Workspace,
        sourceRoles: [FolderRole]? = nil,
        onlyUnread: Bool = false
    ) throws -> [MessageLocationTarget] {
        try databaseQueue.read { db in
            let scope = WorkspaceScopeSQL(workspace: workspace, roleOverride: sourceRoles)
            let roles = scope.roles
            guard !roles.isEmpty else { return [] }
            let unreadPredicate = onlyUnread
                ? "AND LOWER(COALESCE(ml.flags_json, '')) NOT LIKE '%seen%'"
                : ""

            var arguments = StatementArguments(scope.roleValues)
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
                    WHERE \(scope.locationVisibilityPredicate(locationAlias: "ml", folderAlias: "f"))
                      \(scope.flaggedLocationPredicate(locationAlias: "ml"))
                      \(unreadPredicate)
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

    public func messageLocations(messageID: Int64) throws -> [MessageLocationTarget] {
        try databaseQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        ml.message_id,
                        ml.account_key,
                        f.provider_name,
                        f.role,
                        ml.himalaya_envelope_id
                    FROM message_locations ml
                    JOIN folders f ON f.id = ml.folder_id
                    WHERE ml.message_id = ?
                      AND ml.missing_since_at IS NULL
                    ORDER BY
                        ml.is_primary DESC,
                        CASE f.role
                            WHEN 'sent' THEN 0
                            WHEN 'normal' THEN 1
                            WHEN 'junk' THEN 2
                            ELSE 3
                        END,
                        ml.id ASC
                    """,
                arguments: [messageID]
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

    @discardableResult
    public func setMessageHasAttachments(messageID: Int64, hasAttachments: Bool) throws -> Bool {
        try databaseQueue.write { db in
            let value = hasAttachments ? 1 : 0
            try db.execute(
                sql: """
                    UPDATE messages
                    SET has_attachments = ?,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                      AND has_attachments != ?
                    """,
                arguments: [value, messageID, value]
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
        htmlVariants: EmailHTMLDisplayVariants? = nil,
        textFallback: String?,
        sanitizerVersion: Int
    ) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message_bodies (
                        message_id,
                        sanitized_html,
                        remote_blocked_html,
                        quoted_reply_hidden_html,
                        quoted_reply_hidden_remote_blocked_html,
                        text_fallback,
                        sanitizer_version,
                        fetched_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    ON CONFLICT(message_id) DO UPDATE SET
                        sanitized_html = excluded.sanitized_html,
                        remote_blocked_html = excluded.remote_blocked_html,
                        quoted_reply_hidden_html = excluded.quoted_reply_hidden_html,
                        quoted_reply_hidden_remote_blocked_html = excluded.quoted_reply_hidden_remote_blocked_html,
                        text_fallback = excluded.text_fallback,
                        sanitizer_version = excluded.sanitizer_version,
                        updated_at = CURRENT_TIMESTAMP
                    """,
                arguments: [
                    messageID,
                    sanitizedHTML,
                    htmlVariants?.remoteContentBlockedHTML,
                    htmlVariants?.quotedReplyHiddenHTML,
                    htmlVariants?.quotedReplyHiddenRemoteContentBlockedHTML,
                    textFallback,
                    sanitizerVersion
                ]
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
        checkpointValue: String,
        startedValue: String?,
        finishedValue: String?,
        queryStartValue: String?,
        oldestSyncedMessageValue: String?
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
                        last_successful_sync_started_at = ?,
                        last_successful_sync_finished_at = ?,
                        last_successful_query_start_at = ?,
                        oldest_synced_message_date = COALESCE(
                            MIN(datetime(oldest_synced_message_date), datetime(?)),
                            oldest_synced_message_date,
                            ?
                        ),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                arguments: [
                    checkpointValue,
                    startedValue,
                    finishedValue,
                    queryStartValue,
                    oldestSyncedMessageValue,
                    oldestSyncedMessageValue,
                    existingID
                ]
            )
            return
        }

        try db.execute(
            sql: """
                INSERT INTO sync_checkpoints (
                    account_key, folder_id, workspace,
                    last_successful_sync_at,
                    last_successful_sync_started_at,
                    last_successful_sync_finished_at,
                    last_successful_query_start_at,
                    oldest_synced_message_date,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                """,
            arguments: [
                accountKey,
                folderID,
                workspace.rawValue,
                checkpointValue,
                startedValue,
                finishedValue,
                queryStartValue,
                oldestSyncedMessageValue
            ]
        )
    }

    private func fetchSyncCheckpoint(
        _ db: Database,
        accountKey: String,
        folderID: Int64?,
        workspace: Workspace
    ) throws -> SyncCheckpoint? {
        let row: Row?
        if let folderID {
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_key, folder_id, workspace,
                           last_successful_sync_at,
                           last_successful_sync_started_at,
                           last_successful_sync_finished_at,
                           last_successful_query_start_at,
                           oldest_synced_message_date
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id = ?
                      AND workspace = ?
                    """,
                arguments: [accountKey, folderID, workspace.rawValue]
            )
        } else {
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_key, folder_id, workspace,
                           last_successful_sync_at,
                           last_successful_sync_started_at,
                           last_successful_sync_finished_at,
                           last_successful_query_start_at,
                           oldest_synced_message_date
                    FROM sync_checkpoints
                    WHERE account_key = ?
                      AND folder_id IS NULL
                      AND workspace = ?
                    """,
                arguments: [accountKey, workspace.rawValue]
            )
        }

        guard let row else { return nil }
        return SyncCheckpoint(
            accountKey: row["account_key"],
            folderID: row["folder_id"],
            workspace: Workspace(rawValue: row["workspace"]) ?? workspace,
            lastSuccessfulSyncAt: Self.parseCheckpointDate(row["last_successful_sync_at"]),
            lastSuccessfulSyncStartedAt: Self.parseCheckpointDate(row["last_successful_sync_started_at"]),
            lastSuccessfulSyncFinishedAt: Self.parseCheckpointDate(row["last_successful_sync_finished_at"]),
            lastSuccessfulQueryStartAt: Self.parseCheckpointDate(row["last_successful_query_start_at"]),
            oldestSyncedMessageDate: Self.parseCheckpointDate(row["oldest_synced_message_date"])
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
                        to_recipients_json, cc_recipients_json, message_date, has_attachments,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    ON CONFLICT(account_key, rfc_message_id) DO UPDATE SET
                        fallback_dedupe_key = excluded.fallback_dedupe_key,
                        subject = excluded.subject,
                        from_sender_id = excluded.from_sender_id,
                        to_recipients_json = excluded.to_recipients_json,
                        cc_recipients_json = excluded.cc_recipients_json,
                        message_date = excluded.message_date,
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
                    to_recipients_json, cc_recipients_json, message_date, has_attachments,
                    updated_at
                )
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(account_key, fallback_dedupe_key) DO UPDATE SET
                    subject = excluded.subject,
                    from_sender_id = excluded.from_sender_id,
                    to_recipients_json = excluded.to_recipients_json,
                    cc_recipients_json = excluded.cc_recipients_json,
                    message_date = excluded.message_date,
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

    private func rebuildMessageEntities(
        _ db: Database,
        messageID: Int64,
        envelope: EnvelopeMessage,
        ownEmailAddresses: Set<String>,
        accountEmailAddress: String?
    ) throws {
        try db.execute(
            sql: "DELETE FROM message_entities WHERE message_id = ?",
            arguments: [messageID]
        )

        var participants: [(MailAddress, RelationKind)] = []
        if let from = envelope.from {
            participants.append((from, .from))
        }
        participants += envelope.to.map { ($0, RelationKind.to) }
        participants += envelope.cc.map { ($0, RelationKind.cc) }

        let visibleParticipants: [(MailAddress, RelationKind)]
        let isSelfConversation: Bool
        if ownEmailAddresses.isEmpty {
            isSelfConversation = false
            visibleParticipants = participants.filter { _, relationKind in
                switch (envelope.direction, relationKind) {
                case (.incoming, .from), (.outgoing, .to), (.outgoing, .cc), (.outgoing, .bcc):
                    true
                case (.incoming, .to), (.incoming, .cc), (.incoming, .bcc), (.outgoing, .from):
                    false
                }
            }
        } else {
            let externalParticipants = participants.filter { participant in
                !ownEmailAddresses.contains(normalizeEmail(participant.0.emailAddress))
            }
            isSelfConversation = !participants.isEmpty && externalParticipants.isEmpty
            if isSelfConversation, let accountEmailAddress {
                visibleParticipants = participants.filter {
                    normalizeEmail($0.0.emailAddress) != accountEmailAddress
                }
            } else {
                visibleParticipants = isSelfConversation ? participants : externalParticipants
            }
        }

        for (address, relationKind) in visibleParticipants {
            let senderID = try upsertSender(db, address: address)
            let entityID = try upsertEntity(db, address: address, senderID: senderID, relationKind: relationKind)
            try upsertMessageEntity(
                db,
                messageID: messageID,
                entityID: entityID,
                relationKind: relationKind,
                timelineDirection: timelineDirection(
                    envelopeDirection: envelope.direction,
                    relationKind: relationKind,
                    isSelfConversation: isSelfConversation
                )
            )
        }
    }

    private func upsertEntity(
        _ db: Database,
        address: MailAddress,
        senderID: Int64,
        relationKind: RelationKind
    ) throws -> Int64 {
        if let existingEntityID = try existingEntityID(
            db,
            senderID: senderID,
            relationKind: relationKind
        ) {
            try refreshServiceEntityDisplayName(db, entityID: existingEntityID)
            return existingEntityID
        }

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
        try refreshServiceEntityDisplayName(db, entityID: entityID)

        return entityID
    }

    private func refreshServiceEntityDisplayName(_ db: Database, entityID: Int64) throws {
        guard let canonicalKey = try String.fetchOne(
            db,
            sql: "SELECT canonical_key FROM entities WHERE id = ?",
            arguments: [entityID]
        ), canonicalKey.hasPrefix("domain:") else {
            return
        }

        let domain = String(canonicalKey.dropFirst("domain:".count))
        let displayNameRows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.display_name
                FROM entity_senders es
                JOIN senders s ON s.id = es.sender_id
                WHERE es.entity_id = ?
                  AND es.relation_kind = ?
                ORDER BY es.created_at ASC, s.created_at ASC, s.id ASC
                """,
            arguments: [entityID, RelationKind.from.rawValue]
        )
        let candidateDisplayNames: [String?] = displayNameRows.map { row in
            let displayName: String? = row["display_name"]
            return displayName
        }
        let displayName = groupingRules.displayName(
            forDomain: domain,
            candidateDisplayNames: candidateDisplayNames
        )

        try db.execute(
            sql: """
                UPDATE entities
                SET display_name = ?, kind = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                  AND (display_name <> ? OR kind <> ?)
                """,
            arguments: [
                displayName,
                EntityKind.service.rawValue,
                entityID,
                displayName,
                EntityKind.service.rawValue
            ]
        )
    }

    private func existingEntityID(
        _ db: Database,
        senderID: Int64,
        relationKind: RelationKind
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT entity_id
                FROM entity_senders
                WHERE sender_id = ? AND relation_kind = ?
                ORDER BY entity_id ASC
                LIMIT 1
                """,
            arguments: [senderID, relationKind.rawValue]
        )
    }

    private func upsertMessageEntity(
        _ db: Database,
        messageID: Int64,
        entityID: Int64,
        relationKind: RelationKind,
        timelineDirection: MessageDirection
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO message_entities (
                    message_id, entity_id, relation_kind, timeline_direction
                )
                VALUES (?, ?, ?, ?)
                """,
            arguments: [messageID, entityID, relationKind.rawValue, timelineDirection.rawValue]
        )
    }

    private func timelineDirection(
        envelopeDirection: MessageDirection,
        relationKind: RelationKind,
        isSelfConversation: Bool
    ) -> MessageDirection {
        if isSelfConversation {
            return envelopeDirection
        }

        switch relationKind {
        case .from:
            return .incoming
        case .to, .cc, .bcc:
            return .outgoing
        }
    }

    private func ownEmailAddresses(_ db: Database) throws -> Set<String> {
        let emails = try String.fetchAll(
            db,
            sql: """
                SELECT email_address
                FROM accounts
                WHERE email_address IS NOT NULL
                """
        )
        return Set(emails.map(normalizeEmail).filter { !$0.isEmpty })
    }

    private func accountEmailAddress(_ db: Database, accountKey: String) throws -> String? {
        let email = try String.fetchOne(
            db,
            sql: """
                SELECT email_address
                FROM accounts
                WHERE account_key = ?
                """,
            arguments: [accountKey]
        )
        return email.map(normalizeEmail)?.nilIfBlank
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

    private func splitCommaSeparatedValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map(String.init)
    }

    private func normalizeEmail(_ emailAddress: String) -> String {
        emailAddress.trimmed.lowercased()
    }

    private static func htmlVariants(from row: Row) -> EmailHTMLDisplayVariants? {
        let variants = EmailHTMLDisplayVariants(
            remoteContentBlockedHTML: row["remote_blocked_html"],
            quotedReplyHiddenHTML: row["quoted_reply_hidden_html"],
            quotedReplyHiddenRemoteContentBlockedHTML: row["quoted_reply_hidden_remote_blocked_html"]
        )
        if variants.remoteContentBlockedHTML == nil,
           variants.quotedReplyHiddenHTML == nil,
           variants.quotedReplyHiddenRemoteContentBlockedHTML == nil {
            return nil
        }
        return variants
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

    private static func normalizedSyncError(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let singleLine = value
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(800))
    }
}

extension MailRepository: @unchecked Sendable {}

private struct WorkspaceScopeSQL {
    let workspace: Workspace
    let roles: [FolderRole]

    init(workspace: Workspace, roleOverride: [FolderRole]? = nil) {
        self.workspace = workspace
        self.roles = roleOverride ?? WorkspacePolicy.visibleRoles(for: workspace)
    }

    var roleValues: [String] {
        roles.map(\.rawValue)
    }

    func messageSortKey(alias: String?) -> String {
        let prefix = alias.map { "\($0)." } ?? ""
        return "COALESCE(datetime(\(prefix)message_date), datetime(\(prefix)created_at), \(prefix)message_date, \(prefix)created_at)"
    }

    func locationVisibilityPredicate(locationAlias: String, folderAlias: String) -> String {
        "\(folderAlias).role IN (\(Self.placeholders(count: roles.count))) AND \(locationAlias).missing_since_at IS NULL"
    }

    func flaggedLocationPredicate(locationAlias: String) -> String {
        guard workspace == .flagged else { return "" }
        return "AND \(flaggedExpression(locationAlias: locationAlias))"
    }

    func entityVisibilityPredicate(entityAlias: String) -> String {
        guard workspace == .flagged else { return "" }
        return """
        AND EXISTS (
            SELECT 1
            FROM message_entities flagged_me
            JOIN message_locations flagged_ml ON flagged_ml.message_id = flagged_me.message_id
            JOIN folders flagged_f ON flagged_f.id = flagged_ml.folder_id
            WHERE flagged_me.entity_id = \(entityAlias).entity_id
              AND flagged_f.role IN (\(roleLiterals))
              AND flagged_ml.missing_since_at IS NULL
              AND \(flaggedExpression(locationAlias: "flagged_ml"))
        )
        """
    }

    func preferredLocationOrder(
        locationAlias: String,
        folderAlias: String,
        directionExpression: String
    ) -> String {
        var terms: [String] = []
        if workspace == .flagged {
            terms.append("CASE WHEN \(flaggedExpression(locationAlias: locationAlias)) THEN 0 ELSE 1 END")
        }

        terms.append(
            """
            CASE
                WHEN \(directionExpression) = 'outgoing' AND \(folderAlias).role = 'sent' THEN 0
                WHEN \(directionExpression) = 'incoming' AND \(folderAlias).role = 'normal' THEN 0
                ELSE 1
            END
            """
        )
        terms.append(
            """
            CASE \(folderAlias).role
                WHEN 'sent' THEN 0
                WHEN 'normal' THEN 1
                WHEN 'junk' THEN 2
                ELSE 3
            END
            """
        )
        terms.append("\(locationAlias).is_primary DESC")
        terms.append("\(locationAlias).id ASC")
        return terms.joined(separator: ",\n                                    ")
    }

    private var roleLiterals: String {
        roles.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    private func flaggedExpression(locationAlias: String) -> String {
        "LOWER(COALESCE(\(locationAlias).flags_json, '')) LIKE '%flagged%'"
    }

    private static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

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
