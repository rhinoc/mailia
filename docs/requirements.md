# Mailia Requirements

## Summary

Mailia is a native macOS email app for browsing multiple mail accounts as one people-first timeline.

Instead of starting from accounts, folders, and message lists, Mailia starts from entities: people, organizations, services, newsletters, and recurring senders. Accounts and folders remain visible as source metadata, but they do not define the primary workflow.

The first version is a local macOS app built on top of an existing Himalaya configuration. It focuses on reading, syncing, safe HTML display, sender/entity grouping, Junk review, and a lightweight IM-like timeline. Sending, deletion, archive workflows, full mailbox administration, provider OAuth onboarding, and AI features are outside the MVP.

## Product Intent

Email clients are usually message-first. Every incoming message appears as another row in a flat inbox. That works for triage, but it is weak for understanding relationships and recurring senders.

Mailia treats email as a record of ongoing relationships:

- People you talk to.
- Services you depend on.
- Newsletters you read.
- Receipts and security events you may need later.

The app should make it easy to answer:

- What has this person or service sent me recently?
- Which account did they contact me on?
- What did GitHub, PayPal, Microsoft, or another service send across all accounts?
- What did I send back, and from which account?
- Which normal senders were incorrectly sent to Junk?

## Current Mail Setup

Mailia assumes Himalaya is already installed and configured locally. Himalaya manages provider configuration, OAuth tokens, and credentials. Mailia must not manage OAuth credentials directly in the MVP.

Known account pattern:

- `gmail`
- `gmail-imseonwong`
- `gmail-outtascope`
- `outlook`

The app discovers configured accounts with:

```bash
himalaya account list
```

## Principles

### Entity First

The main list is a list of entities, not accounts, folders, or raw messages. Accounts and folders are source badges and optional filters.

### Source Is Always Visible

Every message must show which account and folder it came from. This matters because multiple accounts are combined into one timeline.

### Normal Mail Is Unified

All non-Junk, non-Trash, non-Draft mail belongs in Main by default, including mail that provider rules moved into custom folders or labels.

### Junk Is Separate

Junk/Spam is a separate workspace because true spam pollutes context. Normal mail found in Junk is corrected at the sender/entity level.

### Local and Private

Message metadata, sanitized content cache, sync state, trusted sender rules, and action logs stay local. AI features are not part of the MVP and must be opt-in later.

### Visible Side Effects

Mailia may mark displayed messages as read and may move trusted Junk senders back to Inbox. These side effects must be deliberate, logged, and diagnosable.

## Non-Goals

The MVP should not implement:

- Gmail, Outlook, or provider OAuth onboarding inside Mailia.
- Full IMAP/SMTP client logic independent of Himalaya.
- Reply, compose, draft, signature, attachment sending, or full MIME authoring.
- Delete, archive, move-to-folder, or mailbox management workflows.
- Provider spam-classifier training guarantees.
- Full offline mirror of every mailbox.
- Full body search or attachment content search.
- Calendar support.
- Menu bar daemon or app-closed background sync.
- macOS system notifications.
- Manual mark-read or mark-unread actions.
- Open-in-source-provider URLs.

## Core Concepts

### Account

An email identity configured in Himalaya.

Fields:

- Account key, such as `gmail` or `outlook`.
- Email address when discoverable.
- Provider hint when discoverable.
- Display name when discoverable.
- Enabled for Mailia sync.
- Last sync status.

Accounts are source metadata. They are not the primary navigation model.

### Folder

A provider mailbox, Gmail label exposed through IMAP, or similar Himalaya folder.

Fields:

- Account key.
- Provider folder name.
- Canonical role: `normal`, `sent`, `junk`, `trash`, `drafts`, `outbox`, or `unknown`.
- Sync enabled state.
- First seen timestamp.
- Last seen timestamp.
- Missing since timestamp.
- Last successful sync timestamp.

Mailia performs folder discovery before sync:

```bash
himalaya folder list -a <account> -o json
```

New normal folders are automatically included in Main sync scope. Missing folders are marked missing, not immediately deleted.

### Sender

The raw identity from message headers.

Fields:

- Display name.
- Email address.
- Normalized email address.
- Domain.
- Kind hint when rule-derived.

Sender data is factual and preserved even when grouped into an entity.

### Entity

The normalized object shown in the UI. An entity can represent a person, organization, service, newsletter, or unknown source.

Examples:

```text
notifications@github.com
noreply@github.com
github-actions[bot] <notifications@github.com>
=> GitHub
```

```text
pragmaticengineer@substack.com
pragmaticengineer+deepdives@substack.com
pragmaticengineer+the-pulse@substack.com
=> The Pragmatic Engineer
```

MVP grouping is deterministic and conservative:

- Obvious service/notification addresses may be grouped.
- Personal addresses at the same company are not automatically grouped into the company.
- Public consumer domains such as `gmail.com`, `outlook.com`, and `icloud.com` must not be grouped by domain.
- AI grouping is not part of the MVP.
- Manual merge/split UI is not part of the MVP, but the schema should not block it later.

### Message

A logical email message within one account. Gmail labels or provider folders may expose the same logical message in multiple locations.

Fields:

- Account key.
- RFC Message-ID when available.
- Subject.
- From.
- To.
- Cc.
- Date.
- Direction: incoming or outgoing.
- Attachment presence.
- Sanitized body cache when fetched.
- Text fallback cache when fetched.

### Message Location

The concrete place where a logical message appears.

Fields:

- Account key.
- Folder id.
- Himalaya envelope id for that folder context.
- Flags.
- Primary location marker.
- First seen timestamp.
- Last seen timestamp.
- Missing since timestamp.

All operations that touch provider state must use:

```text
account + folder + envelope id
```

Envelope ids must not be treated as globally stable.

## MVP Scope

### 1. Account Discovery

Mailia discovers Himalaya accounts and lets the user enable or disable them for indexing.

The app should show:

- Account key.
- Read status.
- Last sync status.
- Himalaya errors when discovery or sync fails.

Mailia must not store OAuth tokens or provider credentials.

### 2. Folder Discovery and Classification

Before each sync, Mailia reconciles the folder catalog for each enabled account.

Rules:

- `normal`: Inbox, Archive, All Mail, custom folders, custom labels, and unknown non-special folders.
- `sent`: Sent folders.
- `junk`: Junk/Spam folders.
- `trash`: Trash/Deleted folders.
- `drafts`: Draft folders.
- `outbox`: Outbox folders.

Default sync:

- Main workspace: all `normal` and `sent` folders.
- Junk workspace: all `junk` folders.
- Excluded: `trash`, `drafts`, and `outbox`.

New normal folders discovered after first launch are automatically included in Main.

### 3. Sync

Initial sync is bounded:

- Main folders: latest 90 days.
- Junk folders: latest 30 days.
- Per-folder hard cap: 500 envelopes.

Incremental sync uses per-account and per-folder checkpoints:

- Store `last_successful_sync_at`.
- Query from `last_successful_sync_at - 24 hours`.
- Never go earlier than the configured historical sync window during normal incremental sync.
- Per-folder incremental cap: 200 envelopes.
- Dedupe locally after every sync.

Sync triggers:

- On app launch.
- Every 10 minutes while the app is open.
- Manual refresh.

No sync occurs while the app is closed.

Concurrency limits:

- Max concurrent accounts: 2.
- Max concurrent folder syncs per account: 1.
- Max global Himalaya processes: 3.
- UI body reads have higher priority than background sync.

### 4. Dedupe

Mailia dedupes only within the same account.

Primary dedupe key:

```text
account_key + RFC Message-ID
```

Fallback key:

```text
account_key + normalized from + normalized subject + date
```

The timeline displays one logical message. All locations are retained in `message_locations`.

Primary source badge priority:

```text
Sent > INBOX > custom normal folder > Archive/All Mail > Junk > Trash
```

Main excludes Junk and Trash locations. Junk has its own workspace.

Cross-account duplicates are not deduped in the MVP. If the same external email appears in two configured accounts, both messages remain visible because the receiving identity matters.

### 5. Main Entity List

The left pane shows a single Main entity list for all non-Junk mail.

The MVP left pane contains:

- Search.
- Workspace tabs: `Main` and `Junk`.
- Entity list.

It does not contain People/Services/Newsletters filter chips.

Entity rows show:

- Avatar or generated initials.
- Entity name.
- Latest subject or snippet.
- Latest activity date.
- Source account badges when useful.
- Unread count when greater than zero.

Main sorting:

```text
latest activity across all non-Junk, non-Trash, non-Draft locations
```

Newsletters and services appear in Main like all other entities. Badges may be shown, but they are not primary navigation.

### 6. Entity Timeline

The main window uses a two-pane layout:

```text
Left: Entity list and Main/Junk workspace tabs
Right: selected entity's IM-like timeline
```

The right pane is not a message list plus separate reading pane. It is a continuous timeline where each message body appears inline.

Timeline behavior:

- Incoming messages align left.
- Outgoing messages align right.
- Oldest messages appear above newer messages.
- Opening an entity scrolls to the latest message.
- Timeline is virtualized.
- Metadata loads from SQLite first.
- Body content loads progressively near the viewport.
- Each card shows account, folder/source, date, direction, and participants.
- Messages are grouped by day when helpful.

Incoming relation:

```text
From sender -> Entity
```

Outgoing relation:

```text
To recipients -> Entity
```

For outgoing messages with multiple `To` recipients, the same message is related to each `To` entity without duplicating the message body. `Cc` is displayed as metadata but does not create a default timeline relation. `Bcc` is not used for entity relations in the MVP.

### 7. Read State

Mailia marks a message as read only when the user has actually seen its content.

Rule:

```text
message card at least 60% visible for 1.5 seconds -> mark as seen
```

Background prefetch does not mark messages as read.

Marking read uses:

```bash
himalaya flag add -a <account> -f <folder> <id> seen
```

On success:

- Update local flags.
- Update unread counts.
- Record the action.

On failure:

- Keep local unread state unchanged.
- Record the error.

Junk follows the same read-state behavior. Viewing Junk does not move it to Inbox.

MVP does not provide manual `Mark as read` or `Mark as unread`.

### 8. Body Loading and HTML Rendering

Mailia supports safe HTML rendering in the MVP.

Body fetch must avoid accidental read side effects until visibility rules trigger mark-as-read. Use Himalaya preview reads or exports as appropriate:

```bash
himalaya message read -a <account> -f <folder> --preview -o json <id>
himalaya message export -a <account> -f <folder> <id>
```

Rendering pipeline:

```text
MIME/body source
-> select text/html when available, fallback text/plain
-> parse HTML with a real parser
-> sanitize
-> rewrite blocked resources
-> render in an isolated WKWebView-backed component
```

Security requirements:

- JavaScript disabled.
- Scripts removed.
- Event handler attributes removed.
- Dangerous URL schemes disabled.
- Remote images blocked by default.
- Remote fonts blocked.
- Remote stylesheets blocked.
- Iframes, video, audio, object, and embed blocked.
- Links do not navigate inside the email WebView.
- `http` and `https` links open externally through the system browser.
- `javascript:`, unsafe `data:`, and unknown schemes are blocked.

Blocked remote images should preserve layout when possible:

- Preserve explicit `width` and `height`.
- Preserve safe CSS sizing when available.
- Use a local placeholder when dimensions are known.
- Use a reasonable placeholder when dimensions are unknown.
- Do not delete the image node in a way that collapses the email layout.

MVP does not provide a `Load Remote Content` button. Remote content remains blocked.

Cache:

- Cache sanitized HTML and text fallback.
- Do not cache raw HTML by default.
- Store `sanitizer_version`.
- Rebuild sanitized cache when sanitizer rules change.

### 9. Search

MVP search is metadata-only.

Search fields:

- Entity name.
- Sender display name.
- Sender email.
- Domain.
- Subject.
- Account key.
- Folder/source.
- Recipient email when indexed.

MVP does not search:

- Full body text.
- Raw HTML.
- Attachment content.
- Remote content.

### 10. Junk Workspace

Junk is a separate workspace with the same two-pane shape:

```text
Left: Junk entities
Right: selected entity's Junk timeline
```

Junk messages do not appear in Main by default.

Junk correction is entity-level, not per-message:

- The user right-clicks a Junk entity row in the left pane.
- The context action is `Trust / Move to Inbox`.
- Mailia moves all current Junk messages for the entity's current raw senders to the account's Inbox.
- Mailia records trusted sender rules at the raw sender email level.
- Future syncs automatically move trusted raw senders from Junk to Inbox.
- Each automatic move is recorded in the action log.

Move command:

```bash
himalaya message move -a <account> -f <junk-folder> INBOX <id>
```

Mailia must not claim this trains Gmail or Outlook spam classifiers. It can only guarantee that it moves messages out of Junk using available provider/Himalaya operations.

Future provider-specific enhancements may add:

- Outlook/Microsoft Graph report-not-junk behavior.
- Gmail never-spam filters.
- Provider safe-sender lists.

These are not part of the Himalaya-only MVP.

### 11. Attachments

MVP does not automatically download attachments.

Timeline cards should show:

- Attachment indicator.
- Filename and size when discoverable.
- A `Download attachments` action when attachments exist.

Manual download uses Himalaya:

```bash
himalaya attachment download -a <account> -f <folder> -d <downloads-dir> <id>
```

MVP behavior:

- Downloads all attachments for the selected message.
- Defaults to the user's Downloads folder.
- Shows the downloaded files in Finder when possible.
- Does not provide inline preview.
- Does not provide single-attachment selection unless MIME parsing later supports it cleanly.

### 12. Activity and Diagnostics

Mailia has a lightweight Activity log.

It records:

- Sync runs.
- Sync errors.
- Mark-as-read actions.
- Trusted sender moves from Junk to Inbox.
- Attachment download failures.
- Himalaya command failures.

The UI should expose:

- Last sync time.
- Current sync status.
- Recent errors.
- Recent automatic actions.
- Himalaya path and version.

### 13. Settings

MVP Settings are minimal:

- Accounts: discovered accounts, enabled accounts, last sync state.
- Sync: interval status, manual refresh, current sync window.
- Downloads: attachment download location, defaulting to Downloads.
- Privacy: remote content blocked state.
- Diagnostics: Himalaya version, recent errors, Activity log.

No MVP settings for:

- Theme customization.
- Notification rules.
- Signatures.
- Compose behavior.
- Custom grouping rules.
- Provider login.

## Technical Architecture

### App Structure

Mailia is a native macOS app:

- SwiftUI for app UI.
- AppKit where needed for macOS-specific behavior.
- WKWebView for sanitized HTML rendering.
- Swift Concurrency for async work.
- GRDB + SQLite for local persistence.
- Himalaya CLI through `Process`.

Recommended project structure:

```text
Mailia.xcodeproj
MailiaApp/
  App entry, assets, entitlements
Packages/MailiaCore/
  HimalayaBridge
  Sync
  Database
  EntityGrouping
  HTMLSanitization
  Models
  Tests
```

The Xcode app target should remain thin. Core logic belongs in the Swift package so it can be tested with `swift test`.

### Himalaya Bridge

All Himalaya usage must go through a centralized bridge. SwiftUI views and view models must not spawn processes directly.

The bridge captures:

- Command.
- Arguments.
- Exit code.
- Stdout.
- Stderr.
- Duration.
- Account and folder context when applicable.
- Timeout.

The bridge should normalize errors for:

- Himalaya not installed.
- Account not found.
- OAuth or credential failure.
- Folder not found.
- Provider/network failure.
- JSON decoding failure.
- Timeout.

Example commands:

```bash
himalaya account list -o json
himalaya folder list -a outlook -o json
himalaya envelope list -a outlook -f INBOX "after 2026-03-01 order by date desc" -s 500 -o json
himalaya message read -a outlook -f INBOX --preview -o json 35880
himalaya flag add -a outlook -f INBOX 35880 seen
himalaya message move -a outlook -f Junk INBOX 35880
himalaya attachment download -a outlook -f INBOX -d ~/Downloads 35880
```

### Services

Expected service boundaries:

- `AccountService`
- `FolderDiscoveryService`
- `SyncService`
- `EntityGroupingService`
- `TimelineService`
- `BodyFetchService`
- `HTMLSanitizationService`
- `ReadStateService`
- `JunkTrustService`
- `AttachmentService`
- `ActivityLogService`

View models call services. Services call repositories and `HimalayaBridge`.

### Persistence

Use GRDB and SQLite.

Suggested tables:

- `accounts`
- `folders`
- `messages`
- `message_locations`
- `message_bodies`
- `senders`
- `entities`
- `entity_senders`
- `message_entities`
- `trusted_senders`
- `sync_runs`
- `sync_checkpoints`
- `action_log`

The cache should be rebuildable from Himalaya metadata, except for local-only preferences such as trusted senders and account enablement.

## UX Shape

### Main Window

Layout:

```text
Left pane:
  Search
  Main / Junk workspace tabs
  Entity list

Right pane:
  Selected entity header
  IM-like virtualized timeline
```

There is no third column in the MVP.

### Entity Row

Required data:

- Avatar or initials.
- Name.
- Latest subject/snippet.
- Latest date.
- Unread count when non-zero.
- Small source account indication when useful.

### Timeline Card

Required data:

- Subject.
- Body content inline.
- Sender and recipients.
- Date.
- Source account badge.
- Source folder badge.
- Direction styling.
- Attachment indicator/action when present.
- Remote-content-blocked indicator when applicable.

Incoming cards align left. Outgoing cards align right.

## Testing

MVP test emphasis is core logic, not pixel-perfect UI.

Required unit tests:

- Himalaya JSON decoding fixtures.
- Folder classification.
- Folder discovery reconciliation.
- Sync checkpoint window calculation.
- Message dedupe.
- Primary source selection.
- Entity grouping rules.
- Incoming/outgoing entity relation creation.
- Trusted sender auto-move decisions.
- HTML sanitizer fixtures.
- Remote resource placeholder behavior.
- Link rewriting and unsafe scheme blocking.
- Read-state visibility threshold logic.

Required integration tests:

- Fake `HimalayaBridge` -> sync service -> SQLite repositories.
- Junk trust flow with fake move success/failure.
- Body fetch -> sanitize -> cache.

UI tests are limited to smoke coverage for:

- Main/Junk workspace switching.
- Entity selection.
- Timeline rendering with fake data.

## Risks

### Himalaya Envelope IDs

Envelope ids may be folder and listing-context dependent. Mailia must store account and folder alongside ids.

### Gmail Label Duplication

Gmail labels can expose the same logical email in multiple folders. Mailia must dedupe within an account and retain all locations.

### Provider Folder Names

Folder names vary across Gmail, Outlook, IMAP providers, and locales. Mailia must discover folders and classify them conservatively.

### Large Mailboxes

Scanning every folder can be expensive. The MVP uses a time window, per-folder caps, checkpoints, overlap, and concurrency limits.

### HTML Email

HTML email is untrusted content. Mailia must sanitize before rendering and block remote resources by default while preserving layout placeholders.

### Read State Side Effects

Auto mark-as-read is expected for a mail app, but it changes provider state. The trigger must be tied to actual visibility and recorded in the action log.

### Junk Trust Semantics

Himalaya can move messages out of Junk, but it does not provide a unified spam-classifier training API. Mailia must not overstate what `Trust / Move to Inbox` guarantees.

### Sending Complexity

Sending introduces drafts, signatures, MIME, attachments, aliases, reply context, undo, and failure recovery. It comes after the browsing model works.

## Milestones

### Milestone 1: Local Data and Sync

- Discover Himalaya accounts.
- Discover and classify folders.
- Sync all normal/sent folders into Main.
- Sync Junk folders into Junk.
- Dedupe messages within each account.
- Store local cache in SQLite.

### Milestone 2: Entity Timeline UI

- Two-pane SwiftUI main window.
- Main/Junk workspace tabs.
- Entity list sorted by latest activity.
- IM-like virtualized timeline.
- Incoming left, outgoing right.
- Account and folder source badges.

### Milestone 3: Safe Reading

- Progressive body loading.
- Sanitized HTML rendering.
- Remote content blocked with layout-preserving placeholders.
- Text fallback.
- Sanitized body cache.
- Auto mark-as-read after visibility threshold.

### Milestone 4: Junk Trust

- Junk entity review.
- Entity-level `Trust / Move to Inbox`.
- Raw sender trusted rules.
- Background auto-move for trusted senders.
- Action log entries for moves and failures.

### Milestone 5: Attachments and Settings

- Attachment indicator.
- Manual attachment download to Downloads.
- Minimal Settings.
- Activity and diagnostics UI.
- Himalaya version/path display.

### Later: Reply Prototype

- Detect send-capable accounts.
- Timeline-bottom composer.
- Reply using the relevant source account.
- From selector when ambiguous.
- Plaintext sending first.

### Later: Intelligence Layer

- Sender summaries.
- Newsletter migration helper.
- Sender grouping suggestions.
- Full body search with explicit indexing settings.
- Provider-specific trusted sender integrations.

## Product Positioning

Short version:

> A people-first inbox for all your email accounts.

Long version:

> Mailia turns scattered Gmail, Outlook, and IMAP accounts into one local, sender-first timeline. See who contacted you, what they sent, what you sent back, and which identity each message reached, without living inside a folder-first inbox.
