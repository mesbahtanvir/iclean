#!/usr/bin/env bash
# Fails if app or CleanupKit source uses networking APIs (constitution Principle V).
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='URLSession|URLRequest|NWConnection|import Network|CFNetwork|WKWebView|SFSafariViewController|import CloudKit|CKContainer|isNetworkAccessAllowed *= *true'
# The DEBUG-only tripwire that detects network attempts in UI tests is the single exception.
ALLOWLIST='iclean/App/NetworkTripwire.swift'

matches=$(grep -rnE "$PATTERN" iclean Packages/CleanupKit/Sources --include='*.swift' \
  | grep -v "^${ALLOWLIST}:" || true)

if [[ -n "$matches" ]]; then
  echo "Networking APIs found (not allowed):"
  echo "$matches"
  exit 1
fi
echo "no networking APIs found"
