#!/usr/bin/env bash
# Runs the baseline library check on a simulator or a physical device and saves the report.
#
#   scripts/run-baseline.sh sim    "iPhone 17 Pro"          # a simulator, by name or UDID
#   scripts/run-baseline.sh device 00008150-000234441EF2401C # a connected device, by UDID
#
# Options (before the target): --no-build   reuse the app that is already installed
#                              --remove     remove the baseline photos instead of checking
#
# What it does: builds and installs the DEBUG app, lets it add the baseline photos to the
# Photos library (in the "iclean Baseline" album), scans only those through the real
# pipeline, compares the result with the expected one, copies the report to
# Fixtures/baseline-reports/ and exits 0 on pass, 1 on fail, 2 if it could not run.
# See docs/BASELINE_LIBRARY.md. The first run on any device or simulator asks for Photos
# access once (`simctl privacy grant` does not replace the prompt): tap Allow Full Access
# (on a phone, unlock it first). The answer is remembered, so later runs go straight through.
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD=1
REMOVE=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --remove) REMOVE=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
MODE="${1:?usage: scripts/run-baseline.sh [--no-build] [--remove] sim|device <name-or-udid>}"
TARGET="${2:?usage: scripts/run-baseline.sh [--no-build] [--remove] sim|device <name-or-udid>}"
BUNDLE_ID="com.mesbahtanvir.iclean"
DERIVED="${ICLEAN_DERIVED_DATA:-$PWD/build/DerivedData}"
REPORTS="Fixtures/baseline-reports"
mkdir -p "$REPORTS"
ARGS=(-BaselineRun -BaselineExit)
[[ $REMOVE -eq 1 ]] && ARGS=(-BaselineRun -BaselineRemove -BaselineExit)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build() { # build <destination> <sdk-dir-name>
  command -v xcodegen >/dev/null || { echo "xcodegen is needed: brew install xcodegen" >&2; exit 2; }
  xcodegen generate >/dev/null
  local extra=()
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] && extra=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
  echo "Building for $1 ..."
  xcodebuild build -project iclean.xcodeproj -scheme iclean -configuration Debug \
    -destination "$1" -derivedDataPath "$DERIVED" ${extra[@]+"${extra[@]}"} 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  APP="$(find "$DERIVED/Build/Products" -name iclean.app -path "*$2*" | head -1)"
  [[ -d "$APP" ]] || { echo "build did not produce an app" >&2; exit 2; }
}

summarize() { # summarize <report.json>
  python3 - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
d = r["device"]
for c in r["checks"]:
    mark = {"pass": "PASS", "fail": "FAIL", "skipped": "SKIP"}[c["status"]]
    print(f'{mark} {c["id"]:22} {c["title"]}' + (f'  ({c["detail"]})' if c["detail"] else ""))
failed = [c for c in r["checks"] if c["status"] == "fail"]
ran = [c for c in r["checks"] if c["status"] != "skipped"]
print(f'\nBASELINE {"FAIL" if failed else "PASS"}  {len(ran) - len(failed)}/{len(ran)} checks  '
      f'{d["platform"]} {d["model"]} {d["osVersion"]}{" (simulator)" if d["isSimulator"] else ""}  '
      f'scan {r["timings"].get("scanSeconds", 0):.1f}s  {r["timings"].get("itemsPerSecond", 0):.1f} items/s')
print("capabilities:", r["capabilities"])
sys.exit(1 if failed else 0)
PY
}

name_for() { python3 - "$1" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))["device"]
print(re.sub(r"[^A-Za-z0-9.-]+", "_", f'{d["platform"]}-{d["model"]}-{d["osVersion"].split(" ")[1] if " " in d["osVersion"] else d["osVersion"]}{"-sim" if d["isSimulator"] else ""}'))
PY
}

if [[ "$MODE" == sim ]]; then
  UDID="$(xcrun simctl list devices available | grep -F "$TARGET" | grep -Eo '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
  [[ -n "$UDID" ]] || UDID="$TARGET"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  if [[ $BUILD -eq 1 ]]; then
    build "platform=iOS Simulator,id=$UDID" iphonesimulator
    xcrun simctl install "$UDID" "$APP" || exit 2
  fi
  rm -f "$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents/baseline-report.json"
  echo "Running on simulator $UDID ... (if a Photos prompt shows, tap Allow Full Access once)"
  xcrun simctl launch --console --terminate-running-process "$UDID" "$BUNDLE_ID" "${ARGS[@]}" 2>&1 | grep --line-buffered "^\[baseline\]"
  [[ $REMOVE -eq 1 ]] && exit 0
  SRC="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents/baseline-report.json"
  [[ -f "$SRC" ]] || { echo "no report was written" >&2; exit 2; }
  cp "$SRC" "$TMP/report.json"
elif [[ "$MODE" == device ]]; then
  UDID="$TARGET"
  if [[ $BUILD -eq 1 ]]; then
    build "id=$UDID" iphoneos
    xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null || exit 2
  fi
  echo "Running on device $UDID (unlock it; the first run asks for Photos access) ..."
  xcrun devicectl device process launch --console --terminate-existing --device "$UDID" "$BUNDLE_ID" "${ARGS[@]}" 2>&1 | grep --line-buffered "^\[baseline\]"
  [[ $REMOVE -eq 1 ]] && exit 0
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source Documents/baseline-report.json \
    --destination "$TMP/report.json" >/dev/null 2>&1 || { echo "no report was written" >&2; exit 2; }
else
  echo "mode must be sim or device" >&2; exit 2
fi

NAME="$(name_for "$TMP/report.json")"
cp "$TMP/report.json" "$REPORTS/$NAME.json"
echo "Report saved: $REPORTS/$NAME.json"
echo
summarize "$REPORTS/$NAME.json"
