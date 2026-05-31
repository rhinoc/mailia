# AGENTS.md

## Evidence-First Debugging

When the user reports a concrete runtime fact, verify it from the local project
state before changing code.

- Inspect relevant files, tests, logs, process state, and generated resources
  before proposing a cause.
- Separate diagnosis from implementation. If the user asks for review or
  analysis, keep the turn read-only.
- Do not add workaround code for unverified hypotheses.
- When a claim is testable locally, test it before claiming completion.
- In final replies, state what was checked, what changed, and what remains
  unverified.

## Mailia Runtime Checks

Useful probes before editing sync, account, or rendering bugs:

- `defaults read dev.rhinoc.mailia`
- `pgrep -af 'Mailia|mailia'`
- `ps -p <pid> -o pid,ppid,comm,args,lstart`
- `log show --style compact --last 10m --predicate 'process CONTAINS "Mailia" OR eventMessage CONTAINS "Mailia"'`
- `himalaya account list -o json`
- `himalaya folder list -a <account> -o json`

## Privacy and Test Data

- Treat mailbox content, account names, sender metadata, and attachment paths as
  private by default.
- Use `example.com`, `example.net`, and synthetic local paths in tests and docs.
- Do not commit real mailbox exports, local Himalaya config files, OAuth tokens,
  app passwords, signing keys, or user-specific paths.
- Avoid logs that print message bodies, secrets, account configuration, or full
  local paths containing usernames.

## HTML Email

- HTML email is untrusted input.
- Do not relax sanitizer behavior without tests for scripts, event handlers,
  unsafe URLs, remote images, style filtering, and layout placeholders.
- Keep native and web-side display normalization behavior aligned.

## Current Architecture Reminders

- `MailiaCore` owns models, database schema, Himalaya commands, sync policy,
  grouping rules, and HTML normalization.
- `MailiaApp` owns the SwiftUI/AppKit shell, timeline state, reply composer,
  avatars, and WebKit bridge.
- `Web/Timeline` owns the embedded React timeline island. Rebuild it with
  `npm --prefix Web/Timeline run build:app` before relying on bundled web
  resources.
