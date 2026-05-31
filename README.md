# mailia

Mailia is a native macOS email companion that turns multiple mailboxes into a people-first inbox.

Instead of starting from accounts, folders, and message lists, Mailia starts from senders, organizations, and services. It uses Himalaya as the mail transport layer and builds a local SwiftUI experience for browsing cross-account email history like a lightweight IM timeline.

The product requirements live in [docs/requirements.md](docs/requirements.md).

## Development

Build the Swift package and app executable:

```bash
swift build
```

Rebuild the timeline web island and copy it into the app bundle resources:

```bash
npm --prefix Web/Timeline run build:app
```

Run the core test suite:

```bash
swift test
```

Run the app from the package:

```bash
swift run Mailia
```

Current targets:

- `MailiaCore`: shared models, Himalaya bridge, sync policy, database schema, grouping rules, and HTML sanitization.
- `MailiaApp`: thin native SwiftUI macOS app shell.
