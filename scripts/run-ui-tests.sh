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
# build/<result name>.log. The exit status is xcodebuild's, unless UI_TEST_RERUNS says otherwise:
#
#   UI_TEST_RERUNS=2   a test whose last result is a failure is run again on its own, in a fresh test
#                      runner, up to twice. A simulator that times out under a query, or takes the runner
#                      down with it, fails a test that nothing is wrong with, and xcodebuild's own retry
#                      does not run it again. If every failed test passes in the end the status is 0, and
#                      scripts/flaky-tests.py lists them as flaky. A test that fails every time still fails.
#
# The reruns' results go to build/<result name>-rerun<N>.xcresult and .log.
#
# A simulator that never finishes booting would leave `simctl bootstatus` waiting for the rest of the job
# (it did, for an hour). Each wait is limited to UI_TEST_BOOT_TIMEOUT seconds (default 240); a simulator
# that is not up by then is shut down and booted again, up to three times, before the script gives up (2).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

UDID="${1:?usage: scripts/run-ui-tests.sh <simulator udid> <test plan> <result name> [xcodebuild arguments...]}"
PLAN="${2:?missing the test plan}"
NAME="${3:?missing the result name}"
shift 3
RERUNS="${UI_TEST_RERUNS:-0}"

PRODUCTS=build/DerivedData/Build/Products
RUN="$(find "$PRODUCTS" -maxdepth 1 -name "*_${PLAN}_*.xctestrun" 2>/dev/null | head -1)"
if [[ -z "$RUN" ]]; then
  echo "no .xctestrun for the $PLAN plan in $PRODUCTS; there is:" >&2
  ls "$PRODUCTS" >&2
  exit 2
fi

# with_timeout <seconds> <command...>: the command's status, or 143 if it was still running at the limit.
# Pure bash (macOS has no `timeout`), and the watchdog keeps no pipe open after the command is done.
with_timeout() {
  local seconds="$1" pid watchdog status
  shift
  "$@" &
  pid=$!
  (sleep "$seconds" && kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"
  status=$?
  pkill -P "$watchdog" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$status"
}

# boot_simulator: the simulator up, or not at all.
boot_simulator() {
  local attempt
  for attempt in 1 2 3; do
    if with_timeout "${UI_TEST_BOOT_TIMEOUT:-240}" xcrun simctl bootstatus "$UDID" -b >/dev/null; then
      return 0
    fi
    echo "::warning::The simulator $UDID was not up after ${UI_TEST_BOOT_TIMEOUT:-240} s (attempt $attempt of 3); restarting it"
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    sleep 3
  done
  return 1
}

echo "Running $RUN on $UDID"
if ! boot_simulator; then
  echo "::error::The simulator $UDID would not boot" >&2
  exit 2
fi

if command -v xcbeautify >/dev/null; then
  pretty=(xcbeautify --renderer github-actions)
else
  pretty=(cat)
fi

# xctest <result bundle> <log> [xcodebuild arguments...]: one run of xcodebuild, with the status it ended with.
xctest() {
  local bundle="$1" log="$2"
  shift 2
  rm -rf "$bundle"
  xcodebuild test-without-building \
    -xctestrun "$RUN" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -resultBundlePath "$bundle" \
    "$@" 2>&1 | tee "$log" | "${pretty[@]}"
  return "${PIPESTATUS[0]}"
}

xctest "build/$NAME.xcresult" "build/$NAME.log" "$@"
status=$?
logs=("build/$NAME.log")

round=1
while ((status != 0 && round <= RERUNS)); do
  failing=()
  while IFS= read -r test; do
    [[ -n "$test" ]] && failing+=("$test")
  done < <(python3 scripts/flaky-tests.py --failing "${logs[@]}")
  # A failure with no test to name (the build, the simulator) is not one a rerun can help.
  ((${#failing[@]} > 0)) || break

  only=()
  for test in "${failing[@]}"; do only+=("-only-testing:icleanUITests/$test"); done
  echo "::notice::Running ${#failing[@]} failed test(s) again, round $round of $RERUNS: ${failing[*]}"
  log="build/$NAME-rerun$round.log"
  xctest "build/$NAME-rerun$round.xcresult" "$log" "${only[@]}"
  rerun_status=$?
  logs+=("$log")

  still=()
  while IFS= read -r test; do
    [[ -n "$test" ]] && still+=("$test")
  done < <(python3 scripts/flaky-tests.py --failing "${logs[@]}")
  if ((${#still[@]} == 0 && rerun_status == 0)); then status=0; fi
  round=$((round + 1))
done

# What the tests printed that the pretty log leaves out: the accessibility audit says which element it
# means there, and the result bundle (the only other place) cannot be read from a log.
if grep -q 'AUDIT' "${logs[@]}"; then
  echo "::group::What the accessibility audit printed"
  grep -h 'AUDIT' "${logs[@]}" | sort -u | head -80
  echo "::endgroup::"
fi

# A test that failed and then passed on a retry is reported, not hidden.
python3 scripts/flaky-tests.py "${logs[@]}" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit "$status"
