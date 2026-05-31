# Credits and Third-Party Notices

Mailia source code is licensed under the Mozilla Public License 2.0. See
[LICENSE](./LICENSE).

That license covers this project's original source code. Third-party
dependencies, generated data, services, and tools keep their own licenses and
terms.

## Swift Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift), licensed under MIT.
- [Sparkle](https://github.com/sparkle-project/Sparkle), used for macOS app
  update support. Sparkle is distributed under the terms in its upstream
  `LICENSE` file, including notices for bundled components.
- [SwiftSoup](https://github.com/scinfu/SwiftSoup), licensed under MIT.
- [TOMLKit](https://github.com/LebJe/TOMLKit), licensed under MIT.

Exact resolved versions are recorded in [Package.resolved](./Package.resolved).

## Web Timeline Dependencies

The timeline web island is built from [Web/Timeline](./Web/Timeline) and bundled
into the native app resources.

- [DOMPurify](https://github.com/cure53/DOMPurify), licensed under MPL-2.0 or
  Apache-2.0.
- [React](https://react.dev/) and [React DOM](https://react.dev/), licensed
  under MIT.
- [react-markdown](https://github.com/remarkjs/react-markdown), licensed under
  MIT.
- [React Virtuoso](https://virtuoso.dev/), licensed under MIT.
- [Turndown](https://github.com/mixmark-io/turndown), licensed under MIT.
- TypeScript, Vite, and type packages used during development keep their
  upstream licenses as recorded in `Web/Timeline/package-lock.json`.

## Icons and Brand Metadata

[Sources/MailiaApp/SimpleIconCatalog.swift](./Sources/MailiaApp/SimpleIconCatalog.swift)
contains generated brand domain metadata derived from
[simple-icons](https://github.com/simple-icons/simple-icons), which is licensed
under CC0-1.0. Brand names, marks, and colors remain the property of their
respective owners.

## Mail Transport

Mailia shells out to [Himalaya](https://github.com/pimalaya/himalaya) for mail
account discovery and IMAP/SMTP operations. Himalaya is not vendored in this
repository and must be installed and configured by the user.

## Maintainer Notes

- Add a new entry here when introducing a runtime dependency, generated data
  source, bundled asset, icon source, or service integration.
- Do not add real mailbox exports, private account configuration, OAuth tokens,
  certificates, signing keys, or user mail content to the repository.
