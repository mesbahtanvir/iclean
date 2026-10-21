#!/usr/bin/env bash
# Fails if app or CleanupKit source uses networking APIs, or if an app entitlements file asks
# for network access (constitution Principle V).
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='URLSession|NSURLSession|URLRequest|NWConnection|NWPathMonitor|import Network|SystemConfiguration|CFNetwork|WKWebView|SFSafariViewController|import CloudKit|CKContainer|isNetworkAccessAllowed *= *true'
# The DEBUG-only tripwire that detects network attempts in UI tests is the single exception.
ALLOWLIST='iclean/App/NetworkTripwire.swift'

failed=0

matches=$(grep -rnE "$PATTERN" iclean Packages/CleanupKit/Sources --include='*.swift' \
  | grep -v "^${ALLOWLIST}:" || true)

if [[ -n "$matches" ]]; then
  echo "Networking APIs found (not allowed):"
  echo "$matches"
  failed=1
fi

# The Mac app is sandboxed. With no network entitlement the system itself blocks its sockets,
# so the sandbox must never name one (spec 005 research R4). Applies to every entitlements file.
entitlement_files=$(find iclean -name '*.entitlements' -type f)
entitlement_matches=""
if [[ -n "$entitlement_files" ]]; then
  # shellcheck disable=SC2086
  entitlement_matches=$(grep -nE 'com\.apple\.security\.network\.|com\.apple\.developer\.networking\.' \
    $entitlement_files || true)
fi

if [[ -n "$entitlement_matches" ]]; then
  echo "Network entitlements found (not allowed):"
  echo "$entitlement_matches"
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "no networking APIs or network entitlements found"
