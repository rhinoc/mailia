#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' <VERSION)"

git config user.name github-actions
git config user.email github-actions@github.com
git add VERSION Sources/MailiaApp/Info.plist appcast.xml
git commit -m "chore: auto release $VERSION"
git push
