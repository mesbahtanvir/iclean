#!/usr/bin/env bash
# Imports labeled fixtures into a simulator's Photos library for manual testing.
# Usage: scripts/seed-simulator.sh "iPhone 17 Pro"
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:?Usage: scripts/seed-simulator.sh <simulator name or UDID>}"
BUNDLE_ID="com.mesbahtanvir.iclean"

if [[ -f Fixtures/labels.json ]]; then
  ROOT=Fixtures
else
  echo "No real fixtures; generating the synthetic set..."
  ICLEAN_EXPORT_FIXTURES=1 swift test --package-path Packages/CleanupKit --filter FixtureExport >/dev/null
  ROOT=Fixtures/generated
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "Importing media from $ROOT..."
find "$ROOT" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.mov' -o -iname '*.mp4' \) -print0 \
  | xargs -0 xcrun simctl addmedia "$DEVICE"

# Mark favorites (needs the app installed and Photos access).
FAVORITES=$(python3 -c "import json,os,sys; print(','.join(os.path.basename(l['file']) for l in json.load(open('$ROOT/labels.json')) if l.get('favorite')))")
if [[ -n "$FAVORITES" ]]; then
  xcrun simctl privacy "$DEVICE" grant photos "$BUNDLE_ID" || true
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -SeedFavorites "$FAVORITES" >/dev/null \
    && echo "Marked favorites: $FAVORITES" \
    || echo "Install the app first to mark favorites."
fi
echo "Done."
