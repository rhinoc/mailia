# Contributing to Mailia

Mailia is a native macOS email companion built around a local Himalaya
configuration. Contributions need to preserve both code behavior and user mail
privacy.

## Development Setup

Requirements:

- macOS 26.0 or newer.
- Xcode 26.4 or a compatible Swift 6.2 toolchain.
- Node.js 22 for the timeline web island.
- Git.
- Himalaya installed and configured locally for manual app testing.

Install frontend dependencies:

```bash
npm --prefix Web/Timeline ci
```

Build and test the project:

```bash
npm --prefix Web/Timeline run build:app
swift build
swift test
```

`build:app` compiles the React timeline and syncs the generated files into
`Sources/MailiaApp/Resources/TimelineWeb`, which is the bundle SwiftPM packages
with the native app. The generated bundle is ignored by Git and should be
rebuilt from `Web/Timeline`.

Run frontend type checking:

```bash
npm --prefix Web/Timeline run typecheck
```

Run the app from the package:

```bash
swift run Mailia
```

## Pull Requests

- Open an issue first for large UI, database, sync, sanitizer, release, or
  dependency changes.
- Keep pull requests focused on one behavior or one small set of related files.
- Include tests when changing sync policy, repository behavior, grouping rules,
  HTML normalization, sanitizer behavior, reply/send flows, or release scripts.
- Run `npm --prefix Web/Timeline run build:app`, `swift test`, and
  `npm --prefix Web/Timeline run typecheck` before submitting.
- Update `README.md`, `ARCHITECTURE.md`, `CREDITS.md`, or `SPARKLE.md` when
  behavior, dependencies, release artifacts, privacy boundaries, user setup, or
  module ownership changes.

## Code Style

- Prefer existing SwiftUI/AppKit, actor, repository, and service patterns in
  `Sources/MailiaApp` and `Sources/MailiaCore`.
- Treat HTML email as untrusted content. Do not relax sanitizer behavior without
  tests that describe the user-facing risk.
- Keep Himalaya command construction structured and covered by tests.
- Avoid global state unless it matches an existing app-level model or cache
  pattern.
- Do not add logging that prints secrets, full local paths containing usernames,
  account configuration, message bodies, OAuth tokens, or private release
  configuration.

## Test Data

Use synthetic domains such as `example.com`, `example.net`, and
`example.org`. Do not commit:

- Real mailbox exports.
- Real email addresses.
- Local paths with personal usernames.
- Himalaya account configuration.
- OAuth tokens, app passwords, certificates, or signing keys.

## Release and Signing

Do not commit release DMGs, `.app` bundles, notarization logs, certificates,
private keys, passwords, or local Sparkle signing exports.

Release automation lives in:

- `.github/workflows/release.yml`
- `scripts/build_release.sh`
- `scripts/update_appcast.sh`
- `scripts/code_sign.sh`
- `scripts/sign_built_app.sh`
- `SPARKLE.md`

Changes to these files should explain how local builds, GitHub Releases,
Sparkle appcast entries, signing, and notarization are affected.

## Security Reports

For credential exposure, sanitizer bypasses, private mail disclosure, update
feed compromise, or other sensitive issues, follow [SECURITY.md](./SECURITY.md)
instead of opening a public issue.
