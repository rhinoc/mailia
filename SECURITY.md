# Security Policy

Mailia handles local email metadata and message content. Please report security
issues privately instead of opening a public issue.

## Supported Versions

The `main` branch is the supported development line until versioned releases
are published.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting when available for this repository.
If it is not available, contact the maintainer through the email address listed
on the GitHub profile for `rhinoc`.

Useful reports include:

- HTML sanitizer bypasses or unsafe remote resource loading.
- Exposure of OAuth tokens, app passwords, signing keys, or certificates.
- Private mail content, sender metadata, or local file path disclosure.
- Unsafe Himalaya command construction.
- Sparkle update feed or release artifact integrity problems.

Include reproduction steps, affected files or commands, and whether the issue
requires a configured mailbox. Do not attach real mailbox exports or live
credentials.
