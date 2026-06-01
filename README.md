<div align="center">
  <br />
  <img src="./assets/app-icon-transparent.png" alt="Mailia app icon" width="112" height="112" />
  <h1>Mailia</h1>
  <p>All your mailboxes, organized around people instead of folders.<br />
  Mailia gives your email a lightweight, timeline-style home on macOS, so you can follow conversations across accounts without living inside a traditional inbox.</p>
  <p>
    <a href="https://github.com/rhinoc/mailia/releases">Releases</a>
    &nbsp;·&nbsp;
    <a href="./LICENSE">License</a>
    &nbsp;·&nbsp;
    <a href="./CREDITS.md">Credits</a>
    &nbsp;·&nbsp;
    <a href="./CONTRIBUTING.md">Contributing</a>
    &nbsp;·&nbsp;
    <a href="./SPARKLE.md">Updates</a>
  </p>
  <br />
</div>

Mailia is a native macOS email companion for people who use multiple mailboxes
but want one clear place to read, review, and reply. It groups mail by senders,
organizations, newsletters, and services, then shows the history as a durable
conversation timeline.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="./assets/showcase-main.png" width="380" alt="Mailia main timeline with a people-first inbox and message history" /></td>
    <td align="center"><img src="./assets/showcase-info.png" width="380" alt="Mailia account and sender detail view for a selected conversation" /></td>
  </tr>
</table>

## Features

- 👥 **People-first mail** — Start from a sender, company, newsletter, or
  service, then read the full cross-account history in one place.
- 🧵 **Timeline conversations** — Browse email like an IM thread, with incoming
  and outgoing messages, account labels, folders, dates, and attachments kept in
  context.
- 📬 **Multiple mailboxes, one view** — Use your existing accounts without
  switching between inboxes just to understand who said what.
- 🧹 **Junk review without losing context** — Review likely false positives by
  sender and move messages back when something important lands in Junk.
- 🖼️ **Safer HTML mail** — Read rich email with remote images blocked by default,
  unsafe content filtered, and message layout preserved.
- ✍️ **Reply from the right account** — Reply or start a message from the
  mailbox identity that already belongs to the conversation.
- 🔒 **Local-first by design** — Mailia keeps app data local and leaves account
  credentials with your existing mail toolchain.
- 🔄 **Native macOS updates** — Sparkle powers in-app updates for packaged
  releases.

## Requirements

- **macOS** 26.0 or newer.
- A configured [Himalaya](https://github.com/pimalaya/himalaya) mail setup for
  account access.

Mailia does not manage provider OAuth, app passwords, or IMAP/SMTP credentials.
Those credentials remain in the user's Himalaya configuration.

## Install

Mailia ships as a macOS disk image. Download the latest
**`Mailia-<version>-macos.dmg`** from
**[GitHub Releases](https://github.com/rhinoc/mailia/releases)**.

1. Open the DMG.
2. Drag **Mailia.app** to **Applications**.
3. Launch **Mailia** from Applications or Spotlight.

### First Launch and Gatekeeper

Browser downloads are tagged with Gatekeeper quarantine. If macOS warns that
the app cannot be opened or is from an unidentified developer, use
**Control-click → Open** once and confirm in the dialog.

You can also remove quarantine from the installed app:

```bash
xattr -dr com.apple.quarantine /Applications/Mailia.app
```

## Himalaya Setup

Mailia uses [Himalaya](https://github.com/pimalaya/himalaya) as its mail
engine. Install Himalaya and configure your email accounts there first, then
open Mailia.

Start with the official Himalaya project:

- [Himalaya on GitHub](https://github.com/pimalaya/himalaya)
- [Pimalaya project](https://github.com/pimalaya)

After Himalaya can list and read your accounts from the command line, Mailia
can discover the same accounts automatically. If you keep the Himalaya
configuration in a nonstandard location, launch Mailia with `HIMALAYA_CONFIG`
pointing at that file.

## Local Data and Privacy

Mailia is a local macOS app. It stores app-managed state and synced mail
metadata locally, while credentials stay with Himalaya.

| Data | Location or owner |
| --- | --- |
| Provider credentials and OAuth tokens | Himalaya configuration and credential storage |
| Mailia database and app state | Mailia application support storage |
| Attachment downloads | User-selected or configured download directory |

HTML email is treated as untrusted content. Mailia sanitizes message display,
filters unsafe links and styles, and blocks remote images by default while
preserving message layout.

## Contributing

For source builds, development setup, tests, release scripts, and contribution
boundaries, read [CONTRIBUTING.md](./CONTRIBUTING.md).

## Third-Party Notices

Original project source code is licensed under the Mozilla Public License 2.0.
See [LICENSE](./LICENSE).

Third-party dependencies and generated data keep their own licenses and terms.
See [CREDITS.md](./CREDITS.md).

Mailia uses [Sparkle](https://sparkle-project.org/) for native macOS updates.
Release signing and appcast setup are documented in [SPARKLE.md](./SPARKLE.md).
