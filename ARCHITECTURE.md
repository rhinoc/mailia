# Mailia Architecture

Mailia is a native macOS app with a Swift core, a SwiftUI/AppKit shell, and an
embedded React timeline. Account access is delegated to the user's local
Himalaya setup.

## Runtime Boundaries

`MailiaCore` owns persistent mail state and mailbox-facing behavior:

- Database schema and migrations.
- Repository queries and DTO mapping.
- Himalaya command construction and process execution.
- Account metadata read/write for Himalaya TOML configuration.
- Sync policy, sync windows, workspace folder selection, and entity grouping.
- HTML email sanitizing, normalization, preview extraction, and display
  variants.

`MailiaApp` owns the macOS application experience:

- SwiftUI/AppKit window shell, menus, settings, and About window.
- Timeline selection, workspace state, reply drafts, send state, and visible
  fetch queues.
- Reply and new-message composer UI.
- Attachment download location, Finder reveal behavior, and app preferences.
- Entity avatars, brand metadata lookup, and WebKit bridge messages.

`Web/Timeline` owns the embedded message timeline:

- React rendering for timeline rows and message cards.
- HTML and Markdown body display modes.
- Remote-image and quoted-reply display switches.
- Reverse scrolling, lazy body requests, measured body heights, and attachment
  download bridge events.

Generated timeline assets are copied into
`Sources/MailiaApp/Resources/TimelineWeb` before Swift builds so SwiftPM can
bundle them with the native app. The copied bundle is ignored by Git and should
be rebuilt from `Web/Timeline`:

```bash
npm --prefix Web/Timeline run build:app
```

## Mail Access

Mailia shells out to Himalaya for account discovery, folder listing, message
sync, message export, sending, flag updates, and moves. It does not store mail
provider credentials.

Himalaya configuration is discovered from `HIMALAYA_CONFIG`,
`~/Library/Application Support/himalaya/config.toml`,
`$XDG_CONFIG_HOME/himalaya/config.toml`, `~/.config/himalaya/config.toml`, or
`~/.himalayarc`.

## Local State

Mailia stores its SQLite database at
`~/Library/Application Support/Mailia/mailia.sqlite`. User preferences are kept
in macOS user defaults for `dev.rhinoc.mailia`. Attachments are downloaded to
Downloads unless the user selects another directory in settings.

## HTML Email

HTML email is untrusted input. The display pipeline in `MailiaCore/HTML`
sanitizes exported message HTML, inlines safe local images from Himalaya export
directories, removes unsafe elements and attributes, filters styles and URLs,
normalizes layout, and builds display variants for remote-image blocking and
quoted-reply hiding.

Native and web-side display behavior should stay aligned. Sanitizer or display
changes need tests for scripts, event handlers, unsafe URLs, remote images,
style filtering, and layout placeholders.

## Releases

CI builds the timeline bundle, then runs Swift build and tests. The release
workflow bumps the version, builds a DMG, updates `appcast.xml`, uploads the
GitHub Release asset, and commits the release metadata. Sparkle setup is
documented in `SPARKLE.md`.
