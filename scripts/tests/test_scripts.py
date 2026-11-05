"""Tests of the repository's own check scripts, run by the Repo checks workflow:

    python3 -m unittest discover -s scripts/tests -v

Each check is shown to fail on what it is there to catch, not only to pass on the tree as it is.
"""

import base64
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import stat
import tempfile
import unittest

import yaml

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
flaky_tests = load("flaky-tests.py")
testflight = load("testflight.py")


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

    # photokit
    LIBRARY = "Packages/CleanupKit/Sources/CleanupKit/Library/PhotoKitLibrary.swift"

    def test_a_look_up_by_identifier_without_options_is_reported_where_it_is(self):
        text = (
            "let a = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.lookupOptions())\n"
            "let b = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)\n"
            "let c = PHAsset.fetchAssets(\n    withLocalIdentifiers: missing,\n    options: nil\n)\n"
        )
        found = self.problems("photokit", {self.LIBRARY: text})
        self.assertEqual(len(found), 2)
        self.assertIn(f"{self.LIBRARY}:2:", found[0])
        self.assertIn(f"{self.LIBRARY}:3:", found[1])
        self.assertIn("lookupOptions", found[0])

    def test_other_fetches_and_other_files_are_left_alone(self):
        album = "PHAsset.fetchAssets(in: album, options: nil)\nPHAsset.fetchAssets(with: nil)\n"
        by_identifier = "PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)\n"
        self.assertEqual(self.problems("photokit", {self.LIBRARY: album}), [])
        self.assertEqual(self.problems("photokit", {"scripts/a.swift": by_identifier}), [])
        self.assertEqual(self.problems("photokit", {"iclean/App/B.swift": by_identifier})[0][:19], "iclean/App/B.swift:")

    def test_one_call_with_options_does_not_hide_the_next_without(self):
        text = (
            "PHAsset.fetchAssets(withLocalIdentifiers: ids, options: opts)\n"
            "PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)\n"
        )
        found = self.problems("photokit", {self.LIBRARY: text})
        self.assertEqual(len(found), 1)
        self.assertIn(":2:", found[0])

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

    def test_a_secret_is_read_only_by_a_job_under_an_environment(self):
        step = "- run: scripts/tool.sh\n        env:\n          KEY: ${{ secrets.KEY }}"
        bare = self.GOOD.replace("- run: scripts/tool.sh", step)
        self.assertTrue(any("without an `environment`" in p for p in self.problems(bare)))
        gated = bare.replace("    timeout-minutes: 5\n", "    timeout-minutes: 5\n    environment: release\n")
        self.assertEqual(self.problems(gated), [])
        token = self.GOOD.replace("- run: scripts/tool.sh", step.replace("secrets.KEY", "secrets.GITHUB_TOKEN"))
        self.assertEqual(self.problems(token), [])

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
        "UIDeviceFamily": [1],
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
            "iPad support": {"UIDeviceFamily": [1, 2]},
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

    def test_the_version_and_build_number_a_build_was_given_are_checked(self):
        stamped = {**self.IOS, "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"}
        self.assertEqual(built_app.check_version(stamped, "1.2.0", "42"), [])
        self.assertEqual(built_app.check_version(stamped, None, None), [])
        self.assertEqual(len(built_app.check_version(stamped, "1.3.0", "42")), 1)
        self.assertEqual(len(built_app.check_version(stamped, "1.2.0", "43")), 1)
        # An Info.plist that spells the numbers out ignores the build settings, and says so.
        spelled = {**self.IOS, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}
        found = built_app.check_version(spelled, "1.2.0", "42")
        self.assertEqual(len(found), 2)
        self.assertIn("MARKETING_VERSION", found[0])
        self.assertIn("CURRENT_PROJECT_VERSION", found[1])
        self.assertEqual(len(built_app.check_version(self.IOS, "1.2.0", None)), 1)

    def test_main_checks_the_version_only_when_asked(self):
        stamped = {**self.IOS, "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"}
        with tempfile.TemporaryDirectory() as tmp:
            app = str(self.write_bundle(pathlib.Path(tmp), "ios", stamped, self.MANIFEST))
            for arguments, status in (
                ([app], 0),
                ([app, "--configuration", "Release", "--expect-version", "1.2.0", "--expect-build", "42"], 0),
                ([app, "--expect-version", "9.9.9"], 1),
                ([app, "--expect-build", "7"], 1),
                ([app + "-missing"], 2),
            ):
                with self.subTest(arguments), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
                    io.StringIO()
                ):
                    self.assertEqual(built_app.main(arguments), status)


# What the .p8 file Apple gives out looks like, with a body that only has the shape of a key.
FAKE_KEY_BODY = "MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgZmFrZWZha2VmYWtlZmFrZWZha2VmYWtlZmFrZQ" * 2
FAKE_KEY_FILE = (
    "-----BEGIN PRIVATE KEY-----\n"
    + "\n".join(FAKE_KEY_BODY[i : i + 64] for i in range(0, len(FAKE_KEY_BODY), 64))
    + "\n-----END PRIVATE KEY-----\n"
)


class TestflightTests(unittest.TestCase):
    BODY = FAKE_KEY_BODY
    PEM = FAKE_KEY_FILE
    SECRETS = {
        "ASC_KEY_ID": "ABCDE12345",
        "ASC_ISSUER_ID": "11111111-2222-3333-4444-555555555555",
        "ASC_KEY_P8": PEM,
        "APPLE_TEAM_ID": "TEAM123456",
    }

    def run_main(self, argv, environ=None, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = testflight.main(argv, environ=environ or {}, stdin=io.StringIO(stdin))
        return status, out.getvalue(), err.getvalue()

    # --- the version and the build number

    def test_a_tag_names_the_version(self):
        for tag, version in (("v1.2.3", "1.2.3"), ("v2", "2"), ("v1.20", "1.20"), ("v0.9.0", "0.9.0")):
            with self.subTest(tag):
                self.assertEqual(testflight.release_version(f"refs/tags/{tag}", "", "1.0")[0], version)

    def test_a_tag_that_is_not_a_version_is_reported(self):
        for tag in ("v1.2.3-beta", "v1.2.3.4", "v01.2", "release", "v", "1.2.3", "V1.2"):
            with self.subTest(tag), self.assertRaises(testflight.Problem):
                testflight.release_version(f"refs/tags/{tag}", "", "1.0")

    def test_the_tag_and_the_input_must_agree(self):
        self.assertEqual(testflight.release_version("refs/tags/v1.2.0", "1.2.0", "1.0")[0], "1.2.0")
        with self.assertRaises(testflight.Problem):
            testflight.release_version("refs/tags/v1.2.0", "1.3.0", "1.0")

    def test_without_a_tag_the_input_then_project_yml_decide(self):
        self.assertEqual(testflight.release_version("refs/heads/main", "2.1", "1.0"), ("2.1", "the version input"))
        self.assertEqual(testflight.release_version("refs/heads/main", "", "1.4"), ("1.4", "project.yml"))
        self.assertEqual(testflight.release_version("refs/pull/9/merge", "  ", "1.4")[0], "1.4")
        for bad in ("v2", "1.2.3.4", "1.2-beta", "latest", "01.2"):
            with self.subTest(bad), self.assertRaises(testflight.Problem):
                testflight.release_version("refs/heads/main", bad, "1.0")

    def test_project_yml_gives_the_default_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            good = write(root, "a.yml", 'settings:\n  base:\n    # MARKETING_VERSION: "9.9"\n    MARKETING_VERSION: "1.4"  # now\n')
            self.assertEqual(testflight.project_version(good), "1.4")
            self.assertEqual(testflight.project_version(write(root, "b.yml", "  MARKETING_VERSION: 2.0.1\n")), "2.0.1")
            for text in ("settings: {}\n", "MARKETING_VERSION: latest\n"):
                with self.subTest(text), self.assertRaises(testflight.Problem):
                    testflight.project_version(write(root, "c.yml", text))

    def test_the_real_project_yml_has_a_version_both_plists_read(self):
        repo = SCRIPTS.parent
        self.assertRegex(testflight.project_version(repo / "project.yml"), testflight.VERSION)
        for plist in ("iclean/Info.plist", "iclean/Info-macOS.plist"):
            with self.subTest(plist):
                info = plistlib.loads((repo / plist).read_bytes())
                self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
                self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")
        self.assertIn("CURRENT_PROJECT_VERSION", (repo / "project.yml").read_text())

    def test_the_build_number_is_the_run_number_plus_the_offset(self):
        self.assertEqual(testflight.build_number("7", ""), 7)
        self.assertEqual(testflight.build_number("7", "100"), 107)
        self.assertEqual(testflight.build_number(" 7 ", " 0 "), 7)
        for run, offset in (("0", ""), ("abc", ""), ("", ""), ("7", "-1"), ("7", "1.5"), ("7", "x"), ("7", "999999999")):
            with self.subTest(run=run, offset=offset), self.assertRaises(testflight.Problem):
                testflight.build_number(run, offset)

    def test_the_version_command_prints_the_outputs_and_nothing_else_on_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = str(write(pathlib.Path(tmp), "project.yml", 'MARKETING_VERSION: "1.0"\n'))
            argv = ["version", "--project", project, "--run-number", "12", "--offset", "30"]
            status, out, err = self.run_main(argv + ["--ref", "refs/tags/v3.1.0"])
            self.assertEqual((status, out), (0, "marketing_version=3.1.0\nbuild_number=42\n"))
            self.assertIn("::notice", err)
            # Whatever it prints is appended to $GITHUB_OUTPUT, so a failure must leave stdout empty.
            status, out, err = self.run_main(argv + ["--ref", "refs/tags/nightly"])
            self.assertEqual((status, out), (1, ""))
            self.assertIn("::error::", err)

    # --- Xcode

    OLD = "Xcode 26.6\nBuild version 17E100\n"

    def test_an_xcode_older_than_asked_for_fails_unless_it_is_allowed(self):
        self.assertEqual(testflight.check_xcode(self.OLD, 27, False)[0], "error")
        level, message = testflight.check_xcode(self.OLD, 27, True)
        self.assertEqual(level, "warning")
        self.assertIn("Xcode 26.6", message)
        self.assertIn("27", message)
        for newer in ("Xcode 27.0\nBuild version 18A1\n", "Xcode 27\n", "Xcode 28.1\n"):
            with self.subTest(newer):
                self.assertEqual(testflight.check_xcode(newer, 27, False)[0], "ok")

    def test_output_that_is_not_xcodes_is_reported(self):
        for text in ("", "xcode-select: error: no developer tools\n", "Build version 17E100\n"):
            with self.subTest(text), self.assertRaises(testflight.Problem):
                testflight.check_xcode(text, 27, False)

    def test_the_xcode_command_reads_stdin_and_sets_its_status(self):
        self.assertEqual(self.run_main(["xcode", "--require", "27"], stdin=self.OLD)[0], 1)
        status, out, _ = self.run_main(["xcode", "--require", "27", "--allow-older"], stdin=self.OLD)
        self.assertEqual(status, 0)
        self.assertIn("::warning", out)
        status, out, _ = self.run_main(["xcode", "--require", "27"], stdin="Xcode 27.0\n")
        self.assertEqual((status, "::warning" in out), (0, False))

    def test_an_xcode_is_found_by_its_version_in_the_runners_naming(self):
        with tempfile.TemporaryDirectory() as tmp:
            apps = pathlib.Path(tmp)
            (apps / "Xcode_26.6.app").mkdir()
            (apps / "Xcode_27.0.app").mkdir()
            self.assertEqual(testflight.xcode_path("27.0", apps), apps / "Xcode_27.0.app")
            with self.assertRaises(testflight.Problem) as missing:
                testflight.xcode_path("27.1", apps)
            self.assertIn("Xcode_26.6.app, Xcode_27.0.app", str(missing.exception))
            for bad in ("../x", "27;rm", "", "latest", "27.0.0.0"):
                with self.subTest(bad), self.assertRaises(testflight.Problem):
                    testflight.xcode_path(bad, apps)

    # --- the secrets

    def test_secrets_that_are_all_there_and_well_formed_pass(self):
        self.assertEqual(testflight.secret_problems(self.SECRETS), [])

    def test_each_missing_secret_is_named_once(self):
        for name in testflight.SECRETS:
            with self.subTest(name):
                found = testflight.secret_problems({**self.SECRETS, name: "  "})
                self.assertEqual(len(found), 1)
                self.assertIn(f"{name} is not set", found[0])
                self.assertIn("docs/RELEASING.md", found[0])
        self.assertEqual(len(testflight.secret_problems({})), 4)

    def test_each_secret_that_cannot_be_right_is_named_once(self):
        wrong = {
            "ASC_KEY_ID": "my key",
            "ASC_ISSUER_ID": "not-a-uuid",
            "APPLE_TEAM_ID": "TEAM-1234",
            "ASC_KEY_P8": "hello world",
        }
        for name, value in wrong.items():
            with self.subTest(name):
                found = testflight.secret_problems({**self.SECRETS, name: value})
                self.assertEqual(len(found), 1)
                self.assertTrue(found[0].startswith(name), found)

    def test_the_key_is_accepted_however_it_was_pasted(self):
        flat = self.PEM.replace("\n", " ").strip()
        forms = {
            "the file": self.PEM,
            "windows line ends": self.PEM.replace("\n", "\r\n"),
            "padded": "\n\n  " + self.PEM + "\n\n",
            "one line": flat,
            "escaped line ends": self.PEM.replace("\n", "\\n"),
            "base64": base64.b64encode(self.PEM.encode()).decode(),
            "base64 in lines": "\n".join(
                encoded[i : i + 76] for encoded in [base64.b64encode(self.PEM.encode()).decode()] for i in range(0, len(encoded), 76)
            ),
        }
        for label, value in forms.items():
            with self.subTest(label):
                self.assertEqual(testflight.decode_key(value), self.PEM)

    def test_a_key_that_is_not_one_is_reported(self):
        no_end = self.PEM.replace("-----END PRIVATE KEY-----\n", "")
        not_base64 = self.PEM.replace(self.BODY[:20], "!!!! not a key !!!!!")
        for label, value in (("no end", no_end), ("text", "hello"), ("body", not_base64), ("empty body", "x")):
            with self.subTest(label), self.assertRaises(testflight.Problem):
                testflight.decode_key(value)

    def test_the_credentials_command_says_what_is_wrong_and_never_shows_a_secret(self):
        status, out, err = self.run_main(["credentials"], environ=self.SECRETS)
        self.assertEqual(status, 0)
        wrong = {**self.SECRETS, "ASC_KEY_ID": "SECRETSECRETSECRET", "ASC_ISSUER_ID": "SECRET-ISSUER", "ASC_KEY_P8": "SECRET-KEY"}
        for environ in (self.SECRETS, wrong, {"ASC_KEY_ID": "SECRETSECRETSECRET"}):
            status, out, err = self.run_main(["credentials"], environ=environ)
            for secret in list(environ.values()) + [self.BODY[:30], "TEAM123456"]:
                self.assertNotIn(secret, out + err)
        status, out, err = self.run_main(["credentials"], environ=wrong)
        self.assertEqual(status, 1)
        self.assertEqual(err.count("::error::"), 3)
        status, out, err = self.run_main(["credentials"], environ={})
        self.assertEqual(status, 1)
        for name in testflight.SECRETS:
            self.assertIn(name, err)

    # --- the key file and the export options

    def test_the_key_is_written_where_only_its_owner_can_read_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "keys" / "AuthKey_ABCDE12345.p8"
            encoded = base64.b64encode(self.PEM.encode()).decode()
            status, out, err = self.run_main(["write-key", str(path)], environ={"ASC_KEY_P8": encoded})
            self.assertEqual(status, 0)
            self.assertEqual(path.read_text(), self.PEM)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertNotIn(self.BODY[:30], out + err)
            # A second run replaces the file, and keeps the mode.
            self.assertEqual(self.run_main(["write-key", str(path)], environ={"ASC_KEY_P8": self.PEM})[0], 0)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_a_key_that_is_not_one_leaves_no_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "AuthKey.p8"
            status, _, err = self.run_main(["write-key", str(path)], environ={"ASC_KEY_P8": "nonsense"})
            self.assertEqual(status, 1)
            self.assertFalse(path.exists())
            self.assertNotIn("nonsense", err)

    def test_the_export_signs_in_the_cloud_and_uploads_with_the_build_number_it_was_given(self):
        options = testflight.export_options(" TEAM123456 ")
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "upload")
        self.assertEqual(options["signingStyle"], "automatic")
        self.assertEqual(options["teamID"], "TEAM123456")
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)
        self.assertIs(options["uploadSymbols"], True)
        for bad in ("", "short", "TEAM-12345", "TOOLONGTEAMID"):
            with self.subTest(bad), self.assertRaises(testflight.Problem):
                testflight.export_options(bad)

    def test_the_export_options_command_writes_a_property_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "build" / "ExportOptions.plist"
            self.assertEqual(self.run_main(["export-options", "--team", "TEAM123456", str(path)])[0], 0)
            self.assertEqual(plistlib.loads(path.read_bytes()), testflight.export_options("TEAM123456"))
            self.assertEqual(self.run_main(["export-options", "--team", "nope", str(path)])[0], 1)


class TestflightWorkflowTests(unittest.TestCase):
    """What keeps the signing key away from everything but a release that someone approved."""

    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load((SCRIPTS.parent / ".github" / "workflows" / "testflight.yml").read_text())
        cls.on = cls.doc.get("on", cls.doc.get(True))
        cls.jobs = cls.doc["jobs"]

    def test_the_two_jobs_are_an_archive_without_secrets_and_a_gated_upload(self):
        self.assertEqual(set(self.jobs), {"archive", "upload"})
        self.assertNotIn("environment", self.jobs["archive"])
        self.assertEqual(self.jobs["upload"]["environment"], "testflight")
        self.assertEqual(self.jobs["upload"]["needs"], "archive")

    def test_only_the_upload_reads_a_secret_or_signs(self):
        archive = json.dumps(self.jobs["archive"])
        for word in ("secrets.", "authenticationKey", "allowProvisioningUpdates", "exportArchive"):
            self.assertNotIn(word, archive)
        upload = json.dumps(self.jobs["upload"])
        for name in testflight.SECRETS:
            self.assertIn(f"secrets.{name}", upload)

    def test_a_pull_request_never_reaches_the_upload(self):
        self.assertIn("pull_request", self.on)
        self.assertNotIn("pull_request_target", self.on)
        self.assertIn("github.event_name != 'pull_request'", self.jobs["upload"]["if"])
        self.assertIn("!inputs.dry_run", self.jobs["upload"]["if"])

    def test_only_a_version_tag_or_a_person_starts_a_release(self):
        self.assertEqual(self.on["push"], {"tags": ["v*"]})
        self.assertIn("workflow_dispatch", self.on)
        self.assertIn("pull_request", self.doc["concurrency"]["cancel-in-progress"])

    def test_the_iphone_app_has_no_entitlements_for_an_unsigned_archive_to_lose(self):
        """An archive built without signing carries no entitlements, so a capability that needs one (iCloud,
        push, Sign in with Apple, App Groups) would be missing from the build that is signed later. When
        the iPhone app gets one, the archive step has to sign (docs/RELEASING.md); this is the reminder."""
        project = yaml.safe_load((SCRIPTS.parent / "project.yml").read_text())
        app = project["targets"]["iclean"]
        self.assertNotIn("entitlements", app)
        for key in app["settings"]["base"]:
            if key.startswith("CODE_SIGN_ENTITLEMENTS"):
                self.assertIn("sdk=macosx", key, f"{key} gives the iPhone app entitlements")

    def test_the_pull_request_dry_run_watches_the_files_a_release_depends_on(self):
        watched = self.on["pull_request"]["paths"]
        for path in (".github/workflows/testflight.yml", "scripts/testflight.py", "project.yml", "iclean/Info.plist"):
            self.assertIn(path, watched)


class FlakyTestsTests(unittest.TestCase):
    LOG = (
        "Test Case '-[icleanUITests.AccessibilityTests testMainScreens]' started.\n"
        "Test Case '-[icleanUITests.AccessibilityTests testMainScreens]' failed (58.3 seconds).\n"
        "Test Case '-[icleanUITests.AccessibilityTests testMainScreens]' started.\n"
        "Test Case '-[icleanUITests.AccessibilityTests testMainScreens]' passed (54.0 seconds).\n"
        "Test Case '-[icleanUITests.SimilarFlowTests testKeeping]' failed (20.0 seconds).\n"
        "Test Case '-[icleanUITests.SimilarFlowTests testKeeping]' failed (21.0 seconds).\n"
        "Test Case '-[icleanUITests.HomeStatesTests testPause]' passed (9.0 seconds).\n"
    )

    def test_a_test_that_failed_and_then_passed_is_flaky(self):
        self.assertEqual(flaky_tests.flaky(self.LOG), {"AccessibilityTests/testMainScreens": 2})

    def test_a_test_that_failed_every_time_or_never_is_not(self):
        flaky = flaky_tests.flaky(self.LOG)
        self.assertNotIn("SimilarFlowTests/testKeeping", flaky)
        self.assertNotIn("HomeStatesTests/testPause", flaky)

    def test_a_test_that_passed_and_then_failed_is_not_reported_as_flaky(self):
        log = (
            "Test Case '-[T.A testOne]' passed (1.0 seconds).\n"
            "Test Case '-[T.A testOne]' failed (1.0 seconds).\n"
        )
        self.assertEqual(flaky_tests.flaky(log), {})

    def test_the_report_names_the_test_and_says_nothing_when_nothing_is_flaky(self):
        self.assertIn("`AccessibilityTests/testMainScreens` took 2 tries", flaky_tests.report(self.LOG))
        self.assertEqual(flaky_tests.report("Test Case '-[T.A testOne]' passed (1.0 seconds).\n"), "")

    def test_the_failing_tests_are_those_whose_last_attempt_failed(self):
        self.assertEqual(flaky_tests.failing(self.LOG), ["SimilarFlowTests/testKeeping"])

    def test_logs_are_read_in_order_so_a_later_pass_clears_an_earlier_failure(self):
        first = "Test Case '-[icleanUITests.ReviewScreensTests testVideo]' failed (52.0 seconds).\n"
        rerun = "Test Case '-[icleanUITests.ReviewScreensTests testVideo]' passed (20.0 seconds).\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            paths = [str(write(root, "a.log", first)), str(write(root, "b.log", rerun))]
            log = flaky_tests.read(paths)
            self.assertEqual(flaky_tests.failing(log), [])
            self.assertEqual(flaky_tests.flaky(log), {"ReviewScreensTests/testVideo": 2})
            # In the other order the failure is the last word.
            self.assertEqual(flaky_tests.failing(flaky_tests.read(paths[::-1])), ["ReviewScreensTests/testVideo"])

    def test_a_log_that_cannot_be_read_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = write(pathlib.Path(tmp), "a.log", "Test Case '-[T.A testOne]' failed (1.0 seconds).\n")
            log = flaky_tests.read(["/no/such/file.log", str(good)])
        self.assertEqual(flaky_tests.failing(log), ["A/testOne"])


if __name__ == "__main__":
    unittest.main()
