#!/usr/bin/env bash
# A test of the no-network guard (scripts/check-no-network.sh): it must pass on the tree as it is, and
# fail when a networking API or a network entitlement is planted in a copy of the tree. A guard that
# cannot fail protects nothing (constitution Principle V).
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/Packages/CleanupKit"
cp scripts/check-no-network.sh "$work/scripts/"
cp -R iclean "$work/iclean"
cp -R Packages/CleanupKit/Sources "$work/Packages/CleanupKit/Sources"

passes() { (cd "$work" && scripts/check-no-network.sh >/dev/null 2>&1); }
fail() { echo "FAIL: $*" >&2; exit 1; }

passes || fail "the guard rejects the tree as it is"

tokens=(
  'URLSession.shared'
  'NSURLSession'
  'URLRequest(url: u)'
  'NWConnection'
  'NWPathMonitor()'
  'import Network'
  'SystemConfiguration'
  'CFNetwork'
  'WKWebView()'
  'SFSafariViewController'
  'import CloudKit'
  'CKContainer.default()'
  'options.isNetworkAccessAllowed = true'
)

for token in "${tokens[@]}"; do
  for place in "iclean" "Packages/CleanupKit/Sources"; do
    planted="$work/$place/Planted.swift"
    printf '%s\n' "$token" >"$planted"
    if passes; then fail "the guard missed '$token' in $place"; fi
    rm "$planted"
  done
done

# Network access switched off is not an API use.
printf '%s\n' 'options.isNetworkAccessAllowed = false' >"$work/iclean/Planted.swift"
passes || fail "the guard rejects isNetworkAccessAllowed = false"
rm "$work/iclean/Planted.swift"

# A network entitlement is caught, whatever it is called after the prefix.
for key in 'com.apple.security.network.client' 'com.apple.security.network.server' \
  'com.apple.developer.networking.wifi-info'; do
  printf '<plist><dict><key>%s</key><true/></dict></plist>\n' "$key" >"$work/iclean/Planted.entitlements"
  if passes; then fail "the guard missed the entitlement $key"; fi
  rm "$work/iclean/Planted.entitlements"
done

# The one exception is the DEBUG tripwire, by its exact path, and nothing else with that name.
printf '%s\n' 'URLSession' >"$work/iclean/App/NetworkTripwire.swift"
passes || fail "the guard rejects the DEBUG tripwire at its allowed path"
mkdir -p "$work/iclean/Other"
printf '%s\n' 'URLSession' >"$work/iclean/Other/NetworkTripwire.swift"
if passes; then fail "the guard let a file named NetworkTripwire.swift through from another folder"; fi

echo "the no-network guard catches ${#tokens[@]} APIs in two places, 3 entitlements, and allows only its one exception"
