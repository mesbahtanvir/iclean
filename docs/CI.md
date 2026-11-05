# Continuous integration

Every pull request runs five workflows (a sixth, `testflight.yml`, ships the app). They test the same app in different ways: the sources, the
files around them, the compiled app, the app driven like a person, and the engine pushed past what a
quick run does. Each says what it found in its **job summary** (the page of a run) and keeps what it
made as an **artifact**.

| Workflow | Runs on | Starts when | Answers |
|---|---|---|---|
| `repo-checks.yml` | Linux, under a minute | every push and pull request | Are the workflows, scripts, documents, specs and data files sound? Does the no-network check still catch what it is there to catch? |
| `ci.yml` | macOS | every push and pull request | Do the CleanupKit tests pass? Is the code free of networking APIs? (Lint is reported, not enforced.) |
| `app.yml` | macOS | the app, the project or CleanupKit's sources change | Does the app build for iPhone and Mac, Debug and Release? Does the built app keep its promises? Do the app target's unit tests pass? |
| `ui-tests.yml` | macOS | the same, and nightly | Do the UI tests pass, run on four simulators at once? Does the full flow make zero network requests? What does every screen look like? |
| `package-deep.yml` | macOS | CleanupKit changes, and nightly | Does the engine hold under an optimized build, the sanitizers, repetition, a strict compiler, every platform, and the real analyzer? |
| `testflight.yml` | macOS | the release files change (a dry run), a `v*` tag, or by hand | Does the app archive for release with the version and build number it was given, and does the archive keep its promises? On a tag or by hand, once a reviewer approves, it also signs the archive and sends it to TestFlight ([RELEASING.md](RELEASING.md)). |

## What each one checks

### Repo checks (Linux)

- **Workflows**: `actionlint` (syntax, expressions, and ShellCheck on every `run:` script), then
  `scripts/check-workflows.py`: least-privilege `permissions`, a `timeout-minutes` on every job, a
  `concurrency` group, every action pinned to a tag or commit, `retention-days` on every artifact, no
  event text (a title, a branch name) pasted into a script, and every script or path a workflow names
  exists.
- **Scripts**: ShellCheck on `scripts/*.sh`; the unit tests of the scripts themselves
  (`scripts/tests`); the UI test plan; the no-network check and its canary
  (`scripts/test-no-network-guard.sh`, which plants each forbidden token and entitlement in a copy of
  the sources and requires the check to fail on every one); and the script every UI job runs
  (`scripts/test-run-ui-tests.sh`, against a stand-in for `xcodebuild`).
- **Documents, specs and files**: every Markdown link resolves; every `specs/` folder is numbered and
  has a spec and a well-formed task list; every JSON file, test plan, string catalog and property list
  parses; every test a test plan names exists; the privacy manifest tracks and collects nothing; no
  test is switched off without a reason or commented out; no key, token or signing team is committed;
  no build output or oversized file is committed; no merge conflict markers; every "spec 017" in the
  code and the documents names a spec folder that exists; no package comes from a remote URL; the
  layers hold (CleanupKit imports no UI framework but for converting an image, and the app reads
  photos, runs Vision and imports BaselineKit only in files that are wholly `#if DEBUG`).

### App

- **Build** iPhone Debug, iPhone Release, Mac Debug and Mac Release, with the warnings counted in the
  job summary.
- **The built app keeps its promises** (`scripts/check-built-app.py`): the bundle id, the Photos text
  that says nothing leaves the device, no App Transport Security exceptions, the iPhone's background
  mode for a scan that continues, the Mac's minimum system version, a privacy manifest in the bundle,
  no networking framework linked, no networking API named in the binary (a Debug build keeps its code
  in a debug dylib, which is read too), and in Release none of the tooling that is only compiled into
  Debug. The size of the bundle is reported.
- **Unit tests** of the app target (`icleanTests`) on a simulator, with the result summarized
  (`scripts/xcresult-summary.py`) and the coverage of the app target.

### UI tests

- The app is built once for testing; **four shards** run the UI test classes at once
  (`scripts/ui-test-shards.py` puts every class into exactly one shard, so a class that is added runs
  without anyone editing a workflow).
- **No network**: the `NoNetwork` test plan runs the full flow with a tripwire on every URL load.
- **Screenshots**: `ScreenshotTour` saves a PNG of every screen in light, dark, large text and the
  largest text (two looks on a pull request, four nightly). Download them from the run's artifacts.
- **Environments** (informational): tests written for the default size and look, run again with the
  simulator in dark mode (four classes) and at the largest text size (the Home states and the tier rows).
  The first complete run at the largest size passed 18 of 25; the other seven look for a row that is below
  the fold at that size and do not scroll, or are the audit judging a sheet whose own test covers that
  size. None was shown to be a finding about the app, so that run keeps the tests that find their rows
  without scrolling. Making the rest scroll would extend what it checks.

### Package deep tests

- **Coverage** and a **test report** (counts, failures, skips, the slowest tests).
- **Optimized build**: the tests in release mode.
- **Sanitizers**: the thread and the address sanitizer over the whole suite. Two tests wait on the clock
  (a quick check against 30 seconds, a pause for up to 20), and beside ~380 others at the sanitizer's
  slowdown they overrun without any report, so they run alone, one at a time, in a second pass.
- **Repeat**: the suites that use concurrency, run over and over in parallel and one at a time.
- **Accuracy**: the accuracy suites, with what they measured.
- **Platforms**: the package compiles for macOS, iOS and visionOS.
- **Warnings**: the library and its tests build with warnings as errors (the count is zero).
- **One pass against tiered**: the same synthetic library scanned both ways with the real analyzer
  (`ScaleBench --real-scan`); the results digest and the analysis digest must be equal
  (spec 017: a tiered scan finds exactly what a one-pass scan finds).

### TestFlight

- **Archive** (reads no secret): the iPhone app is archived in Release, unsigned, with the version and
  build number the run chose (`scripts/testflight.py`). `scripts/check-built-app.py` reads the archive for
  the promises above and for those two numbers. It runs for a pull request that changes the release files,
  and by hand as a dry run.
- **Upload** (a `v*` tag or a run by hand, once a reviewer of the `testflight` environment approves): signs
  with Apple's cloud signing and sends the build to App Store Connect. It is the only job that reads a
  secret; `scripts/check-workflows.py` fails any job that reads one without an environment.
- Setup, shipping and what to do when it fails: [RELEASING.md](RELEASING.md).

## Run the same checks yourself

```bash
python3 -m unittest discover -s scripts/tests      # the scripts' own tests
python3 scripts/check-workflows.py                 # needs PyYAML
python3 scripts/check-doc-links.py
python3 scripts/check-spec-folders.py
python3 scripts/check-repo-files.py
scripts/test-no-network-guard.sh
scripts/test-run-ui-tests.sh                       # the UI runner's reruns, against a fake xcodebuild
python3 scripts/ui-test-shards.py --table          # which test class runs in which shard
python3 scripts/check-built-app.py path/to/iclean.app --configuration Release
```

`actionlint` and `shellcheck` are on PyPI (`pip install actionlint-py shellcheck-py`).

## Adding a test

- A Swift Testing or XCTest case in CleanupKit runs in `ci.yml` and every job of `package-deep.yml`.
- A test in `icleanTests` runs in `app.yml`.
- A UI test class in `icleanUITests` runs in a shard of `ui-tests.yml` by itself. A class that must not
  (it needs another plan or an environment variable) goes in `EXCLUDED` in
  `scripts/ui-test-shards.py` with the reason, and the plan fails if an excluded class is renamed or
  deleted without it.
- A script in `scripts/` gets a test in `scripts/tests/test_scripts.py` that shows it fails on what it
  is there to catch, not only that it passes on the tree as it is.

## What is not checked, and why

- **A real photo library and a real device.** CI uses the demo library (`-UITesting`). The baseline
  library check (`scripts/run-baseline.sh`) and the Mac checks in `specs/012-calm-polish/mac-checks.md`
  need a Mac with Photos or a phone.
- **Performance on a phone.** A CI machine is a virtual one: timings are reported, never gated. The
  scroll-performance test is a measurement and runs on request (`SCROLL_PERF=1`).
- **Xcode 27.** The README asks for Xcode 27; the runner has an earlier Xcode, so code that needs the
  iOS 27 SDK is compiled only where the compiler is new enough (`ScanContinuation.swift`). A TestFlight
  upload therefore stops on such a runner unless it is told to build anyway (`allow_older_xcode`).
- **Signing and the upload to App Store Connect.** They need the Apple credentials, which a pull request
  never has. The dry run builds the archive that would be signed; the first real run tests the rest.

## Where the runner differs from a Mac with Xcode 27

The runner has Xcode 26.6 and iOS 26.5 simulators. These came out of that, each found by a run:

- The system's abbreviations for a duration differ ("12 secs." on iOS 27, "12 sec" on iOS 26), so
  `FormatTests` compares the numbers and the units, not the plural style.
- How alike a photo and its crop are is Vision's to say, and a release says it differently: in the demo
  library the edited pair is a second Similar group on iOS 26.5. `SimilarFlowTests` therefore checks that
  what is removed is what was selected, not that the category holds only the twins.
- The accessibility audit (`AccessibilityTests`) is not deterministic: the same code passed and failed it
  on the runner (the test's own comments say the audit flags a different row from run to run). A UI test
  that fails is run again, up to three times, and **a test that needed a retry is listed as flaky** in the
  job summary and as a warning; a test that fails every time still fails the shard. The NoNetwork plan is
  never run again.
- A simulator that times out under a query ("Timed out while evaluating UI query") takes the test runner
  with it, and xcodebuild's own retry does not run that test again. `scripts/run-ui-tests.sh` therefore
  runs any test whose last result is a failure again on its own, in a fresh runner, up to twice
  (`UI_TEST_RERUNS`). `scripts/test-run-ui-tests.sh` shows that it reruns only what failed, forgives only
  what then passes, and still fails a test that fails every time, using a stand-in for xcodebuild.
- A simulator can fail to finish booting, and `simctl bootstatus` then waits for ever: one shard sat on it
  for 61 minutes, until the job limit, without running a test. Each wait is now limited
  (`UI_TEST_BOOT_TIMEOUT`, 240 s), and a simulator that is not up is shut down and booted again, up to
  three times, before the script gives up. `scripts/test-run-ui-tests.sh` shows both outcomes.
- The audit of the removal confirmation sheet flagged its lines as "may be clipped at larger sizes" when it
  ran before the sheet had finished moving to its tall detent; the test now waits for the sheet to stop.

## Good to know

- A pull request's path filters look at the whole pull request, so every push starts every workflow again
  and cancels the run it replaces. GitHub runs five macOS jobs at a time, so a full run takes about an hour.
- The job summaries and artifacts are on the run's page. The logs print what matters too (the failures,
  what the accessibility audit flagged, which tests were flaky), so a run can be read from the log alone.
