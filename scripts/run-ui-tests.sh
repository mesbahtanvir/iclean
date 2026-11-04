#!/usr/bin/env bash
# Runs tests from products that `xcodebuild build-for-testing` built earlier, on a simulator.
#
#   scripts/run-ui-tests.sh <simulator udid> <test plan> <result name> [xcodebuild arguments...]
#
#   scripts/run-ui-tests.sh "$UDID" Default shard-1 -only-testing:icleanUITests/HomeStatesTests
#   scripts/run-ui-tests.sh "$UDID" NoNetwork nonetwork
#
# The products are read from build/DerivedData/Build/Products, where the plan's .xctestrun file is named
# `<scheme>_<plan>_<sdk>.xctestrun`. The result bundle goes to build/<result name>.xcresult and the log to
# build/<result name>.log. The exit status is xcodebuild's.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

UDID="${1:?usage: scripts/run-ui-tests.sh <simulator udid> <test plan> <result name> [xcodebuild arguments...]}"
PLAN="${2:?missing the test plan}"
NAME="${3:?missing the result name}"
shift 3

PRODUCTS=build/DerivedData/Build/Products
RUN="$(find "$PRODUCTS" -maxdepth 1 -name "*_${PLAN}_*.xctestrun" 2>/dev/null | head -1)"
if [[ -z "$RUN" ]]; then
  echo "no .xctestrun for the $PLAN plan in $PRODUCTS; there is:" >&2
  ls "$PRODUCTS" >&2
  exit 2
fi

echo "Running $RUN on $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
rm -rf "build/$NAME.xcresult"

if command -v xcbeautify >/dev/null; then
  pretty=(xcbeautify --renderer github-actions)
else
  pretty=(cat)
fi

xcodebuild test-without-building \
  -xctestrun "$RUN" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -resultBundlePath "build/$NAME.xcresult" \
  "$@" 2>&1 | tee "build/$NAME.log" | "${pretty[@]}"
status="${PIPESTATUS[0]}"

# What the tests printed that the pretty log leaves out: the accessibility audit says which element it
# means there, and the result bundle (the only other place) cannot be read from a log.
if grep -q 'AUDIT' "build/$NAME.log"; then
  echo "::group::What the accessibility audit printed"
  grep 'AUDIT' "build/$NAME.log" | sort -u | head -80
  echo "::endgroup::"
fi
exit "$status"
