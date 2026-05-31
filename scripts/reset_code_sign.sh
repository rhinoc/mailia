#!/usr/bin/env bash
set -euo pipefail

KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/app-signing.keychain-db"
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
