"""Tests of the repository's own check scripts, run by the Repo checks workflow:

    python3 -m unittest discover -s scripts/tests -v

Each check is shown to fail on what it is there to catch, not only to pass on the tree as it is.
"""

import importlib.util
import pathlib
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent


def load(filename: str):
    spec = importlib.util.spec_from_file_location(filename.replace("-", "_")[:-3], SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


doc_links = load("check-doc-links.py")
spec_folders = load("check-spec-folders.py")
pick_simulator = load("pick-simulator.py")
coverage_summary = load("coverage-summary.py")
xcresult_summary = load("xcresult-summary.py")
compare_bench = load("compare-bench.py")
repo_files = load("check-repo-files.py")
workflows = load("check-workflows.py")
ui_shards = load("ui-test-shards.py")
junit_summary = load("junit-summary.py")
built_app = load("check-built-app.py")


def write(root: pathlib.Path, relative: str, text: str = "x\n"):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class DocLinksTests(unittest.TestCase):
    def broken(self, files: dict):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for relative, text in files.items():
                write(root, relative, text)
            return sorted((str(r), n, t) for r, n, t in doc_links.broken_links(root))

    def test_a_link_to_a_missing_file_is_reported_with_its_line(self):
        found = self.broken({"README.md": "intro\n[gone](docs/nope.md)\n", "docs/a.md": "a\n"})
        self.assertEqual(found, [("README.md", 2, "docs/nope.md")])

    def test_links_that_resolve_pass(self):
        text = "[a](docs/a.md) [frag](docs/a.md#section) [dir](docs) [root](/docs/a.md)\n"
        self.assertEqual(self.broken({"README.md": text, "docs/a.md": "a\n"}), [])

    def test_a_percent_encoded_name_resolves(self):
        text = "[sp](docs/with%20space.md)\n"
        self.assertEqual(self.broken({"README.md": text, "docs/with space.md": "a\n"}), [])

    def test_external_links_and_bare_anchors_are_not_checked(self):
        text = "[w](https://example.com/x) [m](mailto:a@b.c) [h](#top)\n"
        self.assertEqual(self.broken({"README.md": text}), [])

    def test_images_and_reference_links_are_checked(self):
        text = "![img](img/missing.png)\n\n[ref]: gone.md\n"
        found = self.broken({"README.md": text})
        self.assertEqual([t for _, _, t in found], ["img/missing.png", "gone.md"])

    def test_code_fences_and_code_spans_are_ignored(self):
        text = "```\n[bad](fenced.md)\n```\nand `[bad](inline.md)`\n~~~\n[bad](tilde.md)\n~~~\n"
        self.assertEqual(self.broken({"README.md": text}), [])

    def test_templates_are_skipped_and_other_folders_are_not(self):
        broken_link = "[x](nowhere.md)\n"
        found = self.broken({".specify/templates/t.md": broken_link, "specs/s.md": broken_link})
        self.assertEqual([r for r, _, _ in found], ["specs/s.md"])

    def test_links_are_resolved_from_the_file_they_are_in(self):
        files = {"specs/a/spec.md": "[b](../b/spec.md) [c](../c/spec.md)\n", "specs/b/spec.md": "b\n"}
        self.assertEqual(self.broken(files), [("specs/a/spec.md", 1, "../c/spec.md")])


class SpecFolderTests(unittest.TestCase):
    def check(self, files: dict):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "specs").mkdir()
            for relative, text in files.items():
                write(root, relative, text)
            return list(spec_folders.problems(root))

    def test_well_formed_folders_pass(self):
        files = {
            "specs/001-first/spec.md": "# one\n",
            "specs/002-second-thing/spec.md": "# two\n",
            "specs/002-second-thing/tasks.md": "- [X] T001 a\n- [ ] T002 b\n- [x] T003 c\n",
        }
        self.assertEqual(self.check(files), [])

    def test_a_gap_in_the_numbering_is_reported(self):
        found = self.check({"specs/001-a/spec.md": "a\n", "specs/003-c/spec.md": "c\n"})
        self.assertTrue(any("003" in line and "expected 002" in line for line in found), found)

    def test_a_repeated_number_is_reported(self):
        found = self.check({"specs/001-a/spec.md": "a\n", "specs/001-b/spec.md": "b\n"})
        self.assertTrue(any("numbering" in line for line in found), found)

    def test_a_badly_named_folder_is_reported(self):
        found = self.check({"specs/04-x/spec.md": "a\n", "specs/005_y/spec.md": "a\n"})
        self.assertEqual(sum("must look like" in line for line in found), 2, found)

    def test_a_missing_or_empty_spec_is_reported(self):
        found = self.check({"specs/001-a/tasks.md": "- [ ] T001 a\n", "specs/002-b/spec.md": " \n"})
        self.assertEqual(sum("missing or empty" in line for line in found), 2, found)

    def test_a_legend_line_in_the_notes_is_not_a_task(self):
        files = {
            "specs/001-a/spec.md": "a\n",
            "specs/001-a/tasks.md": "- [X] T001 a\n\n## Notes\n\n- [P] = different files\n",
        }
        self.assertEqual(self.check(files), [])

    def test_a_malformed_checkbox_and_a_repeated_task_id_are_reported(self):
        files = {
            "specs/001-a/spec.md": "a\n",
            "specs/001-a/tasks.md": "- [?] T001 a\n- [ ] T002 b\n- [X] T002 again\n",
        }
        found = self.check(files)
        self.assertTrue(any("tasks.md:1" in line and "[?]" in line for line in found), found)
        self.assertTrue(any("tasks.md:3" in line and "T002" in line for line in found), found)


class PickSimulatorTests(unittest.TestCase):
    @staticmethod
    def device(name, udid, available=True):
        return {"name": name, "udid": udid, "isAvailable": available}

    def listing(self, **runtimes):
        prefix = "com.apple.CoreSimulator.SimRuntime."
        return {"devices": {prefix + key.replace("_", "-", 1).replace("_", "-"): value for key, value in runtimes.items()}}

    def test_the_newest_ios_runtime_and_the_preferred_name_win(self):
        listing = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [self.device("iPhone 17 Pro", "OLD")],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
                    self.device("iPhone Air", "AIR"),
                    self.device("iPhone 17", "SEVENTEEN"),
                    self.device("iPhone 17 Pro", "PRO"),
                ],
                "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [self.device("Apple Watch", "W")],
            }
        }
        self.assertEqual(pick_simulator.pick(listing)["udid"], "PRO")

    def test_runtimes_are_compared_as_numbers_not_text(self):
        listing = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-9-3": [self.device("iPhone 17", "NINE")],
                "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [self.device("iPhone 17", "EIGHTEEN")],
            }
        }
        self.assertEqual(pick_simulator.pick(listing)["udid"], "EIGHTEEN")

    def test_without_a_preferred_name_any_iphone_is_chosen_first_by_name(self):
        listing = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    self.device("iPad Pro", "IPAD"),
                    self.device("iPhone Air", "AIR"),
                    self.device("iPhone 15", "FIFTEEN"),
                ]
            }
        }
        self.assertEqual(pick_simulator.pick(listing)["udid"], "FIFTEEN")

    def test_unavailable_devices_and_other_platforms_are_ignored(self):
        listing = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [self.device("iPhone 17 Pro", "GONE", False)],
                "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [self.device("iPhone 17 Pro", "TV")],
            }
        }
        self.assertIsNone(pick_simulator.pick(listing))
        self.assertIsNone(pick_simulator.pick({}))


class CoverageSummaryTests(unittest.TestCase):
    EXPORT = {
        "data": [
            {
                "files": [
                    {"filename": "/w/Sources/CleanupKit/A.swift", "summary": {"lines": {"count": 10, "covered": 9}}},
                    {"filename": "/w/Sources/CleanupKit/B.swift", "summary": {"lines": {"count": 10, "covered": 2}}},
                    {"filename": "/w/Sources/CleanupKit/Empty.swift", "summary": {"lines": {"count": 0, "covered": 0}}},
                    {"filename": "/w/Tests/CleanupKitTests/T.swift", "summary": {"lines": {"count": 99, "covered": 99}}},
                ]
            }
        ]
    }

    def test_only_files_under_the_prefix_count_and_the_least_covered_come_first(self):
        rows, covered, count = coverage_summary.summarize(self.EXPORT, "Sources/CleanupKit/")
        self.assertEqual([name for name, _, _ in rows], ["B.swift", "A.swift", "Empty.swift"])
        self.assertEqual((covered, count), (11, 20))

    def test_the_table_has_a_total_row(self):
        rows, covered, count = coverage_summary.summarize(self.EXPORT, "Sources/CleanupKit/")
        text = coverage_summary.table(rows, covered, count)
        self.assertIn("| `B.swift` | 10 | 20.0% |", text)
        self.assertIn("| **Total** | **20** | **55.0%** |", text)

    def test_an_empty_file_counts_as_fully_covered_and_nothing_divides_by_zero(self):
        self.assertEqual(coverage_summary.percent(0, 0), 100.0)

    def test_no_matching_files_is_an_empty_result(self):
        self.assertEqual(coverage_summary.summarize(self.EXPORT, "Nowhere/")[0], [])



class XcresultSummaryTests(unittest.TestCase):
    TREE = {
        "testNodes": [
            {
                "nodeType": "Test Plan",
                "name": "iclean",
                "children": [
                    {
                        "nodeType": "UI test bundle",
                        "name": "icleanUITests",
                        "children": [
                            {
                                "nodeType": "Test Suite",
                                "name": "HomeStatesTests",
                                "children": [
                                    {"nodeType": "Test Case", "name": "testA()", "result": "Passed", "durationInSeconds": 2.5},
                                    {
                                        "nodeType": "Test Case",
                                        "name": "testB()",
                                        "result": "Failed",
                                        "durationInSeconds": 30.0,
                                        "children": [
                                            {"nodeType": "Failure Message", "name": "XCTAssertTrue failed\nmore detail"},
                                            {"nodeType": "Repetition", "name": "Run 1"},
                                        ],
                                    },
                                    {"nodeType": "Test Case", "name": "testC()", "result": "Skipped"},
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }

    def test_cases_are_found_whatever_the_nesting(self):
        found = list(xcresult_summary.cases(self.TREE["testNodes"]))
        self.assertEqual([c["name"] for c in found], ["testA()", "testB()", "testC()"])
        self.assertEqual(found[1]["suite"], "HomeStatesTests")
        self.assertEqual(found[1]["failures"], ["XCTAssertTrue failed\nmore detail"])

    def test_the_summary_counts_lists_failures_and_the_slowest_first(self):
        text = xcresult_summary.summarize(self.TREE)
        self.assertIn("**3 tests:** 1 passed, 1 failed, 1 skipped", text)
        self.assertIn("- `HomeStatesTests/testB()`", text)
        self.assertIn("  - XCTAssertTrue failed", text)
        self.assertNotIn("more detail", text)
        self.assertLess(text.index("testB()` | 30.0"), text.index("testA()` | 2.5"))

    def test_a_result_without_cases_says_so(self):
        self.assertIn("No test cases", xcresult_summary.summarize({"testNodes": []}))
        self.assertIn("No test cases", xcresult_summary.summarize({}))


class CompareBenchTests(unittest.TestCase):
    ONE = (
        "Real scan: 1500 items\nscan done (completed): 40.0 s  = 37 items/s  CPU 90.0 s\n"
        "results build: 0.50 s  CPU 1.0 s\n  digest fa169c4d97929604\n"
        "  analysis digest (without feature prints) b99703de218f60a6\n"
    )
    TIERED = (
        "Real scan: 1500 items\nscan done (completed): 46.0 s  = 32 items/s  CPU 99.0 s\n"
        "tiers: photo check done at 22.5 s (66 items/s), deep check compared 610 photos, all done at 46.0 s\n"
        "results build: 0.50 s  CPU 1.0 s\n  digest fa169c4d97929604\n"
        "  analysis digest (without feature prints) b99703de218f60a6\n"
    )

    def test_equal_digests_pass_and_the_table_has_both_times(self):
        text, ok = compare_bench.report(self.ONE, self.TIERED)
        self.assertTrue(ok)
        self.assertIn("| Whole scan | 40.0 s (37/s) | 46.0 s (32/s) |", text)
        self.assertIn("| Photo check done | | 22.5 s (66/s) |", text)
        self.assertIn("| Deep check compared | | 610 photos |", text)
        self.assertNotIn("Not the same scan", text)

    def test_a_different_results_digest_fails(self):
        changed = self.TIERED.replace("fa169c4d97929604", "0000000000000000")
        text, ok = compare_bench.report(self.ONE, changed)
        self.assertFalse(ok)
        self.assertIn("results digest differs", text)

    def test_a_different_analysis_digest_fails(self):
        changed = self.TIERED.replace("b99703de218f60a6", "1111111111111111")
        self.assertFalse(compare_bench.report(self.ONE, changed)[1])

    def test_a_missing_digest_fails_rather_than_passing_by_default(self):
        text, ok = compare_bench.report(self.ONE, "scan done (completed): 1.0 s  = 1 items/s\n")
        self.assertFalse(ok)
        self.assertIn("missing", text)


class RepoFilesTests(unittest.TestCase):
    def problems(self, check: str, files: dict):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for relative, text in files.items():
                write(root, relative, text)
            return repo_files.CHECKS[check](root, repo_files.tracked_files(root))

    PLAN = (
        '{"testTargets": [{"target": {"name": "AppUITests"}, "skippedTests": ["%s"]}], "version": 1}'
    )
    PLIST = (
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>%s</dict></plist>'
    )

    # data
    def test_a_broken_json_file_is_reported(self):
        found = self.problems("data", {"a/Contents.json": "{", "b.json": "{}"})
        self.assertEqual(len(found), 1)
        self.assertIn("a/Contents.json", found[0])

    def test_a_broken_property_list_is_reported(self):
        found = self.problems("data", {"x.entitlements": "<plist>", "y.plist": self.PLIST % ""})
        self.assertEqual([f.split(":")[0] for f in found], ["x.entitlements"])

    # plans
    def test_a_plan_that_names_a_missing_class_is_reported(self):
        files = {
            "p.xctestplan": self.PLAN % "GoneTests",
            "AppUITests/A.swift": "final class RealTests: XCTestCase {}\n",
        }
        found = self.problems("plans", files)
        self.assertEqual(len(found), 1)
        self.assertIn("GoneTests", found[0])

    def test_a_plan_that_names_a_class_and_a_method_resolves(self):
        files = {
            "p.xctestplan": self.PLAN % "RealTests/testOne()",
            "AppUITests/A.swift": "final class RealTests: XCTestCase {}\n",
        }
        self.assertEqual(self.problems("plans", files), [])

    def test_a_plan_for_a_target_without_a_folder_is_reported(self):
        self.assertEqual(len(self.problems("plans", {"p.xctestplan": self.PLAN % "X"})), 1)

    def test_a_project_that_names_a_missing_plan_is_reported(self):
        found = self.problems("plans", {"project.yml": "      - path: Tests/Gone.xctestplan\n"})
        self.assertEqual(len(found), 1)
        self.assertIn("Gone.xctestplan", found[0])

    # privacy
    def tracking(self, tracking="<false/>", domains="<array/>", collected="<array/>"):
        return self.PLIST % (
            f"<key>NSPrivacyTracking</key>{tracking}<key>NSPrivacyTrackingDomains</key>{domains}"
            f"<key>NSPrivacyCollectedDataTypes</key>{collected}"
        )

    def test_a_manifest_that_tracks_nothing_passes(self):
        self.assertEqual(self.problems("privacy", {"P.xcprivacy": self.tracking()}), [])

    def test_a_manifest_that_tracks_is_reported(self):
        found = self.problems("privacy", {"P.xcprivacy": self.tracking(tracking="<true/>")})
        self.assertIn("NSPrivacyTracking", found[0])

    def test_tracking_domains_and_collected_data_are_reported(self):
        manifest = self.tracking(
            domains="<array><string>t.example</string></array>",
            collected="<array><dict/></array>",
        )
        self.assertEqual(len(self.problems("privacy", {"P.xcprivacy": manifest})), 2)

    def test_app_transport_security_is_reported_in_a_plist_and_in_the_project(self):
        plist = self.PLIST % "<key>NSAppTransportSecurity</key><dict/>"
        self.assertEqual(len(self.problems("privacy", {"app/Info.plist": plist})), 1)
        self.assertEqual(len(self.problems("privacy", {"project.yml": "NSAppTransportSecurity: {}"})), 1)

    # skips
    def test_a_test_switched_off_without_a_reason_is_reported(self):
        body = (
            "@Test(.disabled()) func a() {}\n"
            "@Test(.disabled) func b() {}\n"
            "func c() throws { throw XCTSkip() }\n"
        )
        found = self.problems("skips", {"Pkg/Tests/T.swift": body})
        self.assertEqual(len(found), 3)

    def test_a_test_switched_off_with_a_reason_passes(self):
        body = (
            '@Test(.disabled("needs a device")) func a() {}\n'
            'func c() throws { throw XCTSkip("Set SCREENSHOT_DIR.") }\n'
        )
        self.assertEqual(self.problems("skips", {"icleanUITests/T.swift": body}), [])

    def test_a_commented_out_test_is_reported(self):
        body = "// @Test func gone() {}\n//    func testOld() {}\n// a plain comment\n"
        self.assertEqual(len(self.problems("skips", {"icleanTests/T.swift": body})), 2)

    def test_source_outside_the_tests_is_not_read_for_skips(self):
        self.assertEqual(self.problems("skips", {"iclean/App.swift": "x.disabled()\n"}), [])

    # secrets
    def test_keys_and_tokens_are_reported(self):
        files = {
            "a.txt": "-----BEGIN " + "RSA PRIVATE KEY-----\n",
            "b.txt": "key = AK" + "IA" + "A" * 16 + "\n",
            "c.txt": "token gh" + "p_" + "a" * 36 + "\n",
            "d.txt": "nothing to see\n",
        }
        found = self.problems("secrets", files)
        self.assertEqual(sorted(f.split(":")[0] for f in found), ["a.txt", "b.txt", "c.txt"])

    def test_a_committed_signing_team_is_reported_and_an_empty_one_is_not(self):
        self.assertEqual(len(self.problems("secrets", {"project.yml": '    DEVELOPMENT_TEAM: "ABCDE12345"\n'})), 1)
        self.assertEqual(self.problems("secrets", {"project.yml": '    DEVELOPMENT_TEAM: ""\n'}), [])

    # junk
    def test_build_output_and_editor_state_are_reported(self):
        files = {
            ".DS_Store": "x",
            "build/out.txt": "x",
            "App.xcodeproj/xcuserdata/me/x.plist": "x",
            "a.xcresult": "x",
            "fine.swift": "x",
        }
        found = self.problems("junk", files)
        self.assertEqual(len(found), 4)
        self.assertFalse(any("fine.swift" in f for f in found))

    def test_a_file_too_big_for_a_repository_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "big.bin").write_bytes(b"0" * (repo_files.MAX_BYTES + 1))
            found = repo_files.check_junk(root, ["big.bin"])
        self.assertEqual(len(found), 1)

    # markers
    def test_conflict_markers_are_reported_but_an_underline_is_not(self):
        text = "Title\n=======\n<<<<<<< HEAD\nmine\n>>>>>>> branch\n"
        found = self.problems("markers", {"README.md": text})
        self.assertEqual(len(found), 2)

    # references
    def test_a_reference_to_a_spec_that_has_no_folder_is_reported(self):
        files = {
            "specs/017-tiers/spec.md": "x\n",
            "iclean/A.swift": "// spec 017 says so\n// see specs/017-tiers/spec.md\n// spec 099 is gone\n",
        }
        found = self.problems("references", files)
        self.assertEqual(len(found), 1)
        self.assertIn("spec 099", found[0])
        self.assertIn("A.swift:3", found[0])

    def test_the_specs_folder_itself_is_not_read_for_references(self):
        self.assertEqual(self.problems("references", {"specs/001-a/spec.md": "spec 042 will come\n"}), [])

    # dependencies
    def test_a_remote_package_is_reported_and_a_local_one_is_not(self):
        remote = '.package(url: "https://github.com/x/y", from: "1.0.0"),\n'
        local = '.package(path: "../.."),\n'
        self.assertEqual(len(self.problems("dependencies", {"Packages/P/Package.swift": remote})), 1)
        self.assertEqual(self.problems("dependencies", {"Packages/P/Package.swift": local}), [])

    def test_a_remote_package_in_the_project_is_reported(self):
        remote = "packages:\n  Thing:\n    url: https://github.com/x/y\n    from: 1.0.0\n"
        local = "packages:\n  CleanupKit:\n    path: Packages/CleanupKit\n"
        self.assertEqual(len(self.problems("dependencies", {"project.yml": remote})), 1)
        self.assertEqual(self.problems("dependencies", {"project.yml": local}), [])

    # layers
    def test_the_package_may_not_import_a_ui_framework_but_for_the_image_conversion(self):
        files = {
            "Packages/CleanupKit/Sources/CleanupKit/Models/A.swift": "import SwiftUI\n",
            "Packages/CleanupKit/Sources/CleanupKit/Library/PhotoKitLibrary.swift": "import UIKit\n",
            "Packages/CleanupKit/Sources/CleanupKit/Models/B.swift": "import Foundation\n",
        }
        found = self.problems("layers", files)
        self.assertEqual(len(found), 1)
        self.assertIn("Models/A.swift", found[0])

    def test_the_package_may_not_import_the_tooling_that_depends_on_it(self):
        files = {"Packages/CleanupKit/Sources/CleanupKit/A.swift": "import BaselineKit\n"}
        self.assertEqual(len(self.problems("layers", files)), 1)

    def test_the_app_reads_photos_and_runs_vision_only_in_debug_files(self):
        debug = "// DEBUG-only.\n#if DEBUG\n    import Photos\n    import BaselineKit\n#endif\n"
        shipped = "import SwiftUI\nimport Vision\n"
        found = self.problems("layers", {"iclean/App/D.swift": debug, "iclean/Features/S.swift": shipped})
        self.assertEqual(len(found), 1)
        self.assertIn("iclean/Features/S.swift", found[0])
        self.assertIn("Vision", found[0])

    def test_the_whole_run_names_every_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(pathlib.Path(tmp), "a.json", "{}")
            result = repo_files.run(pathlib.Path(tmp))
        self.assertEqual(list(result), list(repo_files.CHECKS))
        self.assertTrue(all(problems == [] for problems in result.values()))


class WorkflowRulesTests(unittest.TestCase):
    GOOD = """
name: Good
on:
  pull_request:
    paths: ["src/**"]
permissions:
  contents: read
defaults:
  run:
    shell: bash
concurrency:
  group: good-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: scripts/tool.sh
      - uses: actions/upload-artifact@v4
        with:
          name: x
          path: x
          retention-days: 7
"""

    def problems(self, workflow: str = None, files: dict = None, action: str = None):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            write(root, ".github/workflows/w.yml", workflow if workflow is not None else self.GOOD)
            write(root, "src/a.txt")
            write(root, "scripts/tool.sh")
            for relative, text in (files or {}).items():
                write(root, relative, text)
            if action is not None:
                write(root, ".github/actions/a/action.yml", action)
            return workflows.check(root)

    def test_a_workflow_that_follows_the_rules_passes(self):
        self.assertEqual(self.problems(), [])

    def test_no_permissions_shell_concurrency_or_timeout_is_reported(self):
        bare = "on: pull_request\njobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo\n"
        found = self.problems(bare)
        self.assertEqual(len(found), 4)
        joined = " ".join(found)
        for word in ("permissions", "shell: bash", "concurrency", "timeout-minutes"):
            self.assertIn(word, joined)

    def test_a_default_shell_other_than_bash_is_reported(self):
        text = self.GOOD.replace("shell: bash", "shell: sh")
        self.assertTrue(any("shell: bash" in p for p in self.problems(text)))

    def test_permissions_on_every_job_are_enough(self):
        text = self.GOOD.replace("permissions:\n  contents: read\n", "").replace(
            "    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    permissions: {}\n"
        )
        self.assertEqual(self.problems(text), [])

    def test_pull_request_target_is_reported(self):
        text = self.GOOD.replace("on:\n  pull_request:", "on:\n  pull_request_target:")
        self.assertTrue(any("pull_request_target" in p for p in self.problems(text)))

    def test_an_action_on_a_branch_is_reported_and_a_tag_or_commit_is_not(self):
        self.assertTrue(any("not pinned" in p for p in self.problems(self.GOOD.replace("@v4", "@main", 1))))
        sha = "a" * 40
        self.assertEqual(self.problems(self.GOOD.replace("checkout@v4", f"checkout@{sha}")), [])

    def test_an_artifact_without_retention_is_reported(self):
        text = self.GOOD.replace("          retention-days: 7\n", "")
        self.assertTrue(any("retention-days" in p for p in self.problems(text)))

    def test_event_text_in_a_script_is_reported_and_in_env_is_not(self):
        bad = self.GOOD.replace("- run: scripts/tool.sh", "- run: echo ${{ github.event.pull_request.title }}")
        self.assertTrue(any("event text" in p for p in self.problems(bad)))
        branch = self.GOOD.replace("- run: scripts/tool.sh", "- run: echo ${{ github.head_ref }}")
        self.assertTrue(any("event text" in p for p in self.problems(branch)))
        safe = self.GOOD.replace(
            "- run: scripts/tool.sh",
            '- run: echo "$TITLE"\n        env:\n          TITLE: ${{ github.event.pull_request.title }}',
        )
        self.assertEqual(self.problems(safe), [])

    def test_a_script_that_does_not_exist_is_reported(self):
        found = self.problems(self.GOOD.replace("scripts/tool.sh", "scripts/typo.sh"))
        self.assertTrue(any("scripts/typo.sh" in p for p in found))

    def test_a_paths_filter_that_matches_nothing_is_reported(self):
        found = self.problems(self.GOOD.replace('"src/**"', '"gone/**"'))
        self.assertTrue(any("gone/**" in p for p in found))

    def test_a_local_action_needs_its_file_and_its_steps_need_a_shell(self):
        local = self.GOOD.replace("- uses: actions/checkout@v4", "- uses: ./.github/actions/a")
        self.assertTrue(any("no action.yml" in p for p in self.problems(local)))
        composite = "runs:\n  using: composite\n  steps:\n    - run: echo\n"
        found = self.problems(local, action=composite)
        self.assertEqual(len(found), 1)
        self.assertIn("without `shell`", found[0])
        fixed = "runs:\n  using: composite\n  steps:\n    - run: scripts/tool.sh\n      shell: bash\n"
        self.assertEqual(self.problems(local, action=fixed), [])


class UiTestShardsTests(unittest.TestCase):
    SOURCE = """
import XCTest
final class AlphaTests: XCTestCase {
    func testOne() {}
    func testTwo() {}
    func helper() {}
}
class BetaTests: XCTestCase {
    func testOne() {}
}
final class ScreenshotTour: XCTestCase {
    func testLight() {}
}
"""

    def classes(self, source: str = None):
        with tempfile.TemporaryDirectory() as tmp:
            write(pathlib.Path(tmp), "T.swift", source or self.SOURCE)
            return ui_shards.discover(pathlib.Path(tmp))

    def test_classes_and_their_test_methods_are_found(self):
        self.assertEqual(self.classes(), {"AlphaTests": 2, "BetaTests": 1, "ScreenshotTour": 1})

    def test_helpers_and_test_helpers_outside_a_class_are_not_counted(self):
        source = "extension XCTestCase {\n    func testNot() {}\n}\nfinal class A: XCTestCase {\n    func testIt() {}\n}\n"
        self.assertEqual(self.classes(source), {"A": 1})

    def test_every_included_class_is_in_exactly_one_shard(self):
        classes = {f"C{i}": i + 1 for i in range(9)}
        shards, problems = ui_shards.plan(classes, 3)
        names = [name for shard in shards for name in shard["classes"]]
        self.assertEqual(sorted(names), sorted(classes))
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(sum(s["tests"] for s in shards), sum(classes.values()))
        self.assertEqual([p for p in problems if "ScreenshotTour" not in p and "NoNetwork" not in p and "ScrollPerf" not in p], [])

    def test_the_shards_come_out_about_as_heavy_as_each_other(self):
        classes = {f"C{i}": 1 + (i % 5) for i in range(30)}
        shards, _ = ui_shards.plan(classes, 4)
        weights = [s["tests"] for s in shards]
        self.assertLessEqual(max(weights) - min(weights), 5)

    def test_excluded_classes_are_not_in_a_shard(self):
        classes = {"A": 2, "ScreenshotTour": 4, "NoNetworkFlowTests": 1, "ScrollPerformanceTests": 1}
        shards, problems = ui_shards.plan(classes, 2)
        self.assertEqual([c for s in shards for c in s["classes"]], ["A"])
        self.assertEqual(problems, [])

    def test_an_exclusion_for_a_class_that_is_gone_is_a_problem(self):
        _, problems = ui_shards.plan({"A": 1}, 2)
        self.assertEqual(len(problems), len(ui_shards.EXCLUDED))

    def test_more_shards_than_classes_makes_no_empty_shard(self):
        classes = {"A": 1, "B": 1, **{name: 1 for name in ui_shards.EXCLUDED}}
        shards, _ = ui_shards.plan(classes, 8)
        self.assertEqual(len(shards), 2)

    def test_the_matrix_has_a_shard_number_and_a_class_list_to_pass_to_xcodebuild(self):
        shards = [{"classes": ["A", "B"], "tests": 3}, {"classes": ["C"], "tests": 1}]
        self.assertEqual(
            ui_shards.matrix(shards),
            {"include": [{"shard": 1, "classes": "A B", "tests": 3}, {"shard": 2, "classes": "C", "tests": 1}]},
        )

    def test_the_real_tests_are_all_planned(self):
        classes = ui_shards.discover(SCRIPTS.parent / "icleanUITests")
        shards, problems = ui_shards.plan(classes, 4)
        self.assertEqual(problems, [])
        planned = {name for shard in shards for name in shard["classes"]}
        self.assertEqual(planned | set(ui_shards.EXCLUDED), set(classes))


class JunitSummaryTests(unittest.TestCase):
    REPORT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="All" tests="5">
    <testcase classname="Pkg.StoreTests" name="testSaves" time="0.5"/>
    <testcase classname="Pkg.StoreTests" name="testLoads" time="2.25"/>
    <testcase classname="Pkg.ScanTests" name="testRetries" time="1.0">
      <failure message="expected 3, got 2">detail line</failure>
    </testcase>
    <testcase classname="Pkg.ScanTests" name="testCrashes" time="0.1">
      <error message="boom"/>
    </testcase>
    <testcase classname="Pkg.Other" name="testLater" time="0.0">
      <skipped message="needs a device"/>
    </testcase>
  </testsuite>
</testsuites>
"""

    def summary(self, *reports: str):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for index, text in enumerate(reports):
                paths.append(str(write(pathlib.Path(tmp), f"r{index}.xml", text)))
            return junit_summary.summarize(paths)

    def test_the_counts_the_failures_and_the_skips_are_listed(self):
        text, total, failures = self.summary(self.REPORT)
        self.assertEqual((total, failures), (5, 2))
        self.assertIn("**5 tests:** 2 passed, 2 failed, 1 skipped", text)
        self.assertIn("`Pkg.ScanTests/testRetries`", text)
        self.assertIn("expected 3, got 2", text)
        self.assertIn("boom", text)
        self.assertIn("`Pkg.Other/testLater`: needs a device", text)

    def test_the_slowest_test_is_first(self):
        text, _, _ = self.summary(self.REPORT)
        table = text.split("### Slowest")[1]
        self.assertLess(table.index("testLoads"), table.index("testRetries"))
        self.assertIn("2.25", table)

    def test_two_reports_are_added_up(self):
        _, total, _ = self.summary(self.REPORT, self.REPORT)
        self.assertEqual(total, 10)

    def test_an_unreadable_report_is_said_and_the_rest_are_still_summarized(self):
        text, total, _ = self.summary(self.REPORT, "<not xml")
        self.assertEqual(total, 5)
        self.assertIn("could not be read", text)

    def test_nothing_to_summarize_says_so(self):
        text, total, _ = self.summary("<testsuites/>")
        self.assertEqual(total, 0)
        self.assertIn("No test cases", text)


class BuiltAppTests(unittest.TestCase):
    IOS = {
        "CFBundleIdentifier": "com.mesbahtanvir.iclean",
        "CFBundleExecutable": "iclean",
        "NSPhotoLibraryUsageDescription": "You choose what to remove, and nothing leaves your iPhone.",
        "ITSAppUsesNonExemptEncryption": False,
        "UIBackgroundModes": ["processing"],
        "BGTaskSchedulerPermittedIdentifiers": ["com.mesbahtanvir.iclean.scan.*"],
    }
    MAC = {
        "CFBundleIdentifier": "com.mesbahtanvir.iclean",
        "CFBundleExecutable": "iclean",
        "NSPhotoLibraryUsageDescription": "nothing leaves your Mac.",
        "ITSAppUsesNonExemptEncryption": False,
        "LSMinimumSystemVersion": "15.0",
    }
    MANIFEST = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": []}

    def test_the_bundles_that_keep_their_promises_pass(self):
        self.assertEqual(built_app.check_info(self.IOS, "ios"), [])
        self.assertEqual(built_app.check_info(self.MAC, "mac"), [])

    def test_each_broken_promise_in_the_info_plist_is_reported(self):
        cases = {
            "bundle id": {"CFBundleIdentifier": "com.other.app"},
            "Photos text": {"NSPhotoLibraryUsageDescription": "We look at your photos."},
            "transport security": {"NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True}},
            "encryption": {"ITSAppUsesNonExemptEncryption": True},
            "background modes": {"UIBackgroundModes": ["processing", "fetch"]},
            "task identifiers": {"BGTaskSchedulerPermittedIdentifiers": []},
        }
        for label, change in cases.items():
            with self.subTest(label):
                self.assertEqual(len(built_app.check_info({**self.IOS, **change}, "ios")), 1)

    def test_the_mac_needs_macos_15(self):
        self.assertEqual(len(built_app.check_info({**self.MAC, "LSMinimumSystemVersion": "14.0"}, "mac")), 1)
        self.assertEqual(built_app.check_info({**self.MAC, "LSMinimumSystemVersion": "26.1"}, "mac"), [])

    def test_the_privacy_manifest_must_exist_and_track_nothing(self):
        self.assertEqual(built_app.check_privacy(self.MANIFEST), [])
        self.assertEqual(len(built_app.check_privacy(None)), 1)
        self.assertEqual(len(built_app.check_privacy({**self.MANIFEST, "NSPrivacyTracking": True})), 1)
        self.assertEqual(len(built_app.check_privacy({**self.MANIFEST, "NSPrivacyTrackingDomains": ["t.example"]})), 1)
        self.assertEqual(len(built_app.check_privacy({**self.MANIFEST, "NSPrivacyCollectedDataTypes": [{}]})), 1)

    def test_a_network_framework_in_otool_output_is_reported(self):
        listing = (
            "iclean:\n"
            "\t/System/Library/Frameworks/SwiftUI.framework/SwiftUI (compatibility version 1.0.0)\n"
            "\t/System/Library/Frameworks/Network.framework/Network (compatibility version 1.0.0)\n"
            "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        )
        self.assertEqual(built_app.check_linked(listing), ["the binary links Network.framework"])
        self.assertEqual(built_app.check_linked("\t/System/Library/Frameworks/Photos.framework/Photos\n"), [])

    def test_networking_names_are_reported_but_the_photo_option_that_forbids_it_is_not(self):
        text = "setNetworkAccessAllowed:\n$s10Foundation10URLSessionC\n_OBJC_CLASS_$_WKWebView\n"
        found = built_app.check_names(text, release=False)
        self.assertEqual(found, ["the binary names URLSession", "the binary names WKWebView"])
        self.assertEqual(built_app.check_names("setNetworkAccessAllowed:\n", release=True), [])

    def test_debug_tooling_is_reported_in_release_only(self):
        text = "$s5iclean15NetworkTripwireC\nDemoPhotoLibrary\n"
        self.assertEqual(built_app.check_names(text, release=False), [])
        self.assertEqual(len(built_app.check_names(text, release=True)), 2)

    def write_bundle(self, root: pathlib.Path, platform: str, info: dict, manifest, executable: bool = True):
        import plistlib

        app = root / "iclean.app"
        base = app / "Contents" if platform == "mac" else app
        binary_dir = base / "MacOS" if platform == "mac" else base
        resources = base / "Resources" if platform == "mac" else base
        for folder in (binary_dir, resources):
            folder.mkdir(parents=True, exist_ok=True)
        (base / "Info.plist").write_bytes(plistlib.dumps(info))
        if manifest is not None:
            (resources / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(manifest))
        if executable:
            (binary_dir / "iclean").write_text("not a Mach-O file\n")
        return app

    def test_a_whole_bundle_is_read_in_either_layout(self):
        for platform, info in (("ios", self.IOS), ("mac", self.MAC)):
            with self.subTest(platform), tempfile.TemporaryDirectory() as tmp:
                app = self.write_bundle(pathlib.Path(tmp), platform, info, self.MANIFEST)
                problems, _ = built_app.check_app(app, release=True)
                self.assertEqual(problems, [])

    def test_a_bundle_without_its_manifest_or_executable_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.write_bundle(pathlib.Path(tmp), "ios", self.IOS, None, executable=False)
            problems, _ = built_app.check_app(app, release=False)
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("privacy manifest" in p for p in problems))
        self.assertTrue(any("executable is missing" in p for p in problems))

    def test_the_size_of_the_bundle_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.write_bundle(pathlib.Path(tmp), "ios", self.IOS, self.MANIFEST)
            (app / "blob.bin").write_bytes(b"0" * 2_000_000)
            problems, notes = built_app.check_app(app, release=False)
        self.assertEqual(problems, [])
        self.assertTrue(notes[0].startswith("the bundle is 2.0 MB"), notes)

    def test_a_debug_dylib_is_read_with_the_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            for name in ("iclean", "iclean.debug.dylib", "__preview.dylib", "other.txt"):
                write(folder, name)
            found = [p.name for p in built_app.binaries(folder / "iclean")]
        self.assertEqual(found, ["iclean", "iclean.debug.dylib"])

    def test_an_unreadable_info_plist_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = pathlib.Path(tmp) / "iclean.app"
            app.mkdir()
            (app / "Info.plist").write_text("<not a plist")
            problems, _ = built_app.check_app(app, release=False)
        self.assertEqual(len(problems), 1)
        self.assertIn("cannot be read", problems[0])


if __name__ == "__main__":
    unittest.main()
