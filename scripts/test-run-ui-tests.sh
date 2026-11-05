#!/usr/bin/env bash
# Shows that scripts/run-ui-tests.sh reruns, reports and fails the way its header says, with a stand-in
# for xcodebuild that prints the lines XCTest prints. Runs on Linux, in a second.
#
#   scripts/test-run-ui-tests.sh
#
# The small predicates below are passed to `expect` by name, which ShellCheck cannot see.
# shellcheck disable=SC2329
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A copy of the scripts, so that the script's `cd` to its parent lands in the sandbox.
mkdir -p "$work/scripts" "$work/bin" "$work/build/DerivedData/Build/Products"
cp "$root/scripts/run-ui-tests.sh" "$root/scripts/flaky-tests.py" "$work/scripts/"
touch "$work/build/DerivedData/Build/Products/iclean_Default_iphonesimulator26.5-arm64.xctestrun"

# xcrun: `simctl bootstatus` hangs for the first $FAKE_BOOT_HANGS calls (counted in $FAKE_BOOTS), as a
# simulator that never finishes booting does; everything else succeeds.
cat >"$work/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "simctl bootstatus" ]]; then
  n="$(cat "$FAKE_BOOTS" 2>/dev/null || echo 0)"
  echo $((n + 1)) >"$FAKE_BOOTS"
  if ((n < ${FAKE_BOOT_HANGS:-0})); then exec sleep 60; fi
fi
exit 0
EOF

# Each call takes the next line of $FAKE_CALLS: words like `Class/test:passed`, `Class/test:failed`, or
# `crash` (a failure that names no test). The arguments of every call are kept in $FAKE_ARGS.
cat >"$work/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
line="$(head -n 1 "$FAKE_CALLS")"
sed -i.bak '1d' "$FAKE_CALLS" && rm -f "$FAKE_CALLS.bak"
echo "$*" >>"$FAKE_ARGS"
status=0
for word in $line; do
  if [[ "$word" == crash ]]; then
    status=65
    continue
  fi
  test="${word%%:*}"
  result="${word##*:}"
  echo "Test Case '-[icleanUITests.${test%%/*} ${test##*/}]' $result (1.0 seconds)."
  [[ "$result" == failed ]] && status=65
done
exit "$status"
EOF
chmod +x "$work/bin/xcrun" "$work/bin/xcodebuild"

failed=0
status=0

# run <reruns> <planned calls...>: runs the script against the stand-in; $status is its exit status.
run() {
  local reruns="$1"
  shift
  : >"$work/args"
  rm -f "$work/boots"
  printf '%s\n' "$@" >"$work/calls"
  (cd "$work" && FAKE_CALLS="$work/calls" FAKE_ARGS="$work/args" FAKE_BOOTS="$work/boots" \
    FAKE_BOOT_HANGS="${FAKE_BOOT_HANGS:-0}" \
    PATH="$work/bin:$PATH" UI_TEST_RERUNS="$reruns" UI_TEST_BOOT_TIMEOUT=1 \
    scripts/run-ui-tests.sh UDID Default shard -only-testing:icleanUITests/X >"$work/out" 2>&1)
  status=$?
}

calls() { wc -l <"$work/args" | tr -d ' '; }

expect() { # expect <what> <command...>: the command must succeed
  local what="$1"
  shift
  if ! "$@"; then
    echo "FAIL: $what"
    echo "---- output"
    sed 's/^/  /' "$work/out"
    echo "---- calls"
    sed 's/^/  /' "$work/args"
    failed=1
  fi
}

is_zero() { [[ "$status" -eq 0 ]]; }
is_nonzero() { [[ "$status" -ne 0 ]]; }
calls_are() { [[ "$(calls)" == "$1" ]]; }
output_has() { grep -q -- "$1" "$work/out"; }
output_lacks() { ! grep -q -- "$1" "$work/out"; }
args_have() { grep -q -- "$1" "$work/args"; }

# 1. Everything passes: one run, no report.
run 2 "A/testOne:passed A/testTwo:passed"
expect "a clean run succeeds" is_zero
expect "a clean run is one call" calls_are 1
expect "a clean run reports nothing flaky" output_lacks "Flaky"

# 2. A test fails and passes on its rerun: success, run alone, reported as flaky.
run 2 "A/testOne:passed B/testTwo:failed" "B/testTwo:passed"
expect "a test that passes on its rerun succeeds" is_zero
expect "it takes two calls" calls_are 2
expect "only the failed test is run again" args_have "-only-testing:icleanUITests/B/testTwo"
expect "it is reported as flaky" output_has "B/testTwo. took 2 tries"

# 3. A test that fails every time still fails, after exactly the reruns it was given.
run 2 "B/testTwo:failed" "B/testTwo:failed" "B/testTwo:failed"
expect "a test that always fails fails the run" is_nonzero
expect "it is run three times in all" calls_are 3

# 4. No reruns unless asked.
run 0 "B/testTwo:failed" "B/testTwo:passed"
expect "without reruns a failure fails" is_nonzero
expect "without reruns there is one call" calls_are 1

# 5. A failure that names no test (the build, the simulator) is not rerun.
run 2 "crash" "A/testOne:passed"
expect "a failure with no test fails" is_nonzero
expect "it is not rerun" calls_are 1

# 6. Several failed tests are rerun together, and a pass for all of them succeeds.
run 2 "A/t1:failed B/t2:failed C/t3:passed" "A/t1:passed B/t2:passed"
expect "two reruns that pass succeed" is_zero
expect "both are run again in one call" calls_are 2
expect "the first is named" args_have "-only-testing:icleanUITests/A/t1"
expect "the second is named" args_have "-only-testing:icleanUITests/B/t2"
expect "the one that passed is not named" output_lacks "C/t3. took"

# 7. One of two fails again: the second round runs only that one, and passes.
run 2 "A/t1:failed B/t2:failed" "A/t1:passed B/t2:failed" "B/t2:passed"
expect "a test that passes in the second round succeeds" is_zero
expect "it takes three calls" calls_are 3
expect "the last call is for the one that was still failing" \
  bash -c "tail -n 1 '$work/args' | grep -q 'B/t2' && ! tail -n 1 '$work/args' | grep -q 'A/t1'"

# 8. A simulator that does not boot the first time is restarted, and the tests then run.
FAKE_BOOT_HANGS=1 run 0 "A/testOne:passed"
expect "a simulator that boots on the second try runs the tests" is_zero
expect "the tests run once" calls_are 1
expect "the restart is said" output_has "was not up after 1 s (attempt 1 of 3)"

# 9. A simulator that never boots fails the run, without running a test.
FAKE_BOOT_HANGS=9 run 0 "A/testOne:passed"
expect "a simulator that never boots fails" is_nonzero
expect "no test is run" calls_are 0
expect "it says why" output_has "would not boot"

exit "$failed"
