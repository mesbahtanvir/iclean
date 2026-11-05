#!/usr/bin/env python3
"""Checks the files of the repository that no compiler reads until it is too late.

    scripts/check-repo-files.py [root]

Each check names what it protects:

  data     every JSON file, test plan, string catalog and property list parses
  plans    every test a test plan selects or skips is a test class that exists, and every test plan
           the project names is a file
  privacy  the privacy manifest tracks nothing and collects nothing, and no Info.plist loosens
           App Transport Security
  skips    no test is switched off without saying why, and none is commented out
  secrets  no private key or access token is committed, and no signing team
  junk     no build output or editor state is committed, and no file is too big for a repository
  markers  no merge conflict markers
  references  every "spec 017" or "specs/017" in code and documents names a spec folder that exists
  dependencies  no package or project dependency comes from a remote URL (the app is local-only, and
           what it is built from is in this repository)
  layers   the logic stays in CleanupKit and the tooling stays in Debug: the package imports no UI
           framework (but for converting an image), the app reads photos and runs Vision only in
           files that are wholly `#if DEBUG`, and BaselineKit is imported only there
  photokit a look-up of photos by identifier is given options (PhotoKitLibrary.lookupOptions()): with
           none, PhotoKit returns only the one frame of a burst that Photos shows, and every other
           frame of the burst gets no thumbnail, no preview and no removal

Prints one line per problem and exits 1 when there is any.
"""

import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

MAX_BYTES = 5 * 1024 * 1024
SKIPPED_DIRS = {".git"}

SECRET_PATTERNS = {
    "a private key": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY"),
    "an AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "a GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"),
    "a Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
    "a Google API key": re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    "a secret key": re.compile(r"\bsk-(?:ant-)?[A-Za-z0-9_-]{32,}"),
}
CONFLICT = re.compile(r"^(?:<{7}|>{7}) \S")
TEAM = re.compile(r"^\s*DEVELOPMENT_TEAM:\s*\"?([A-Z0-9]{10})\"?\s*$")

JUNK_NAMES = {".DS_Store"}
JUNK_PARTS = ("xcuserdata/", "DerivedData/", ".build/", ".swiftpm/", "__pycache__/")
JUNK_SUFFIXES = (".xcresult", ".profraw", ".pyc")

TEST_DIRS = ("Tests/", "icleanTests/", "icleanUITests/")

# Files that name the patterns they look for, so they cannot be read for them.
SELF = {"scripts/check-repo-files.py", "scripts/tests/test_scripts.py"}


def tracked_files(root: Path):
    """The files git tracks or would track (new ones that are not ignored); outside a repository,
    every file."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=root,
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8")
        paths = {p for p in out.split("\0") if p}
        return sorted(p for p in paths if (root / p).is_file())
    except (OSError, subprocess.CalledProcessError):
        found = []
        for folder, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIPPED_DIRS]
            for name in names:
                found.append(str((Path(folder) / name).relative_to(root)))
        return sorted(found)


def text_of(root: Path, relative: str):
    try:
        return (root / relative).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


# MARK: Checks. Each returns a list of "path: what is wrong".


def check_data(root: Path, files):
    problems = []
    for relative in files:
        suffix = Path(relative).suffix
        path = root / relative
        try:
            if suffix in {".json", ".xctestplan", ".xcstrings"}:
                json.loads(path.read_text(encoding="utf-8"))
            elif suffix in {".plist", ".entitlements", ".xcprivacy"}:
                plistlib.loads(path.read_bytes())
        except (OSError, ValueError, ExpatError) as error:
            problems.append(f"{relative}: does not parse ({type(error).__name__}: {error})")
    return problems


def swift_types(root: Path, files, folder: str):
    """The names of the classes and structs declared in the Swift files of a folder."""
    names = set()
    for relative in files:
        if relative.endswith(".swift") and relative.startswith(folder + "/"):
            text = text_of(root, relative) or ""
            names.update(re.findall(r"\b(?:class|struct|actor|enum)\s+(\w+)", text))
    return names


def check_plans(root: Path, files):
    problems = []
    for relative in files:
        if not relative.endswith(".xctestplan"):
            continue
        try:
            plan = json.loads((root / relative).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue  # `data` reports it
        for entry in plan.get("testTargets", []):
            target = entry.get("target", {}).get("name", "")
            if not any(f.startswith(target + "/") for f in files):
                problems.append(f"{relative}: the test target {target!r} has no folder")
                continue
            known = swift_types(root, files, target)
            for key in ("selectedTests", "skippedTests"):
                for test in entry.get(key, []):
                    owner = test.split("/")[0].removesuffix("()")
                    if owner not in known:
                        problems.append(
                            f"{relative}: {key} names {owner!r}, which {target} does not declare"
                        )
    project = text_of(root, "project.yml") or ""
    for match in re.finditer(r"path:\s*(\S+\.xctestplan)", project):
        if match.group(1) not in files:
            problems.append(f"project.yml: the test plan {match.group(1)} does not exist")
    return problems


def check_privacy(root: Path, files):
    problems = []
    for relative in files:
        path = root / relative
        if relative.endswith(".xcprivacy"):
            try:
                manifest = plistlib.loads(path.read_bytes())
            except (OSError, ValueError, ExpatError):
                continue  # `data` reports it
            if manifest.get("NSPrivacyTracking") is not False:
                problems.append(f"{relative}: NSPrivacyTracking must be false")
            if manifest.get("NSPrivacyTrackingDomains"):
                problems.append(f"{relative}: tracking domains are listed")
            if manifest.get("NSPrivacyCollectedDataTypes"):
                problems.append(f"{relative}: collected data types are listed")
        elif Path(relative).name.startswith("Info") and relative.endswith(".plist"):
            try:
                info = plistlib.loads(path.read_bytes())
            except (OSError, ValueError, ExpatError):
                continue  # `data` reports it
            if "NSAppTransportSecurity" in info:
                problems.append(f"{relative}: NSAppTransportSecurity is set; the app has no network")
    project = text_of(root, "project.yml") or ""
    if "NSAppTransportSecurity" in project:
        problems.append("project.yml: NSAppTransportSecurity is set; the app has no network")
    return problems


def check_skips(root: Path, files):
    problems = []
    for relative in files:
        if not relative.endswith(".swift") or not any(d in relative for d in TEST_DIRS):
            continue
        for number, line in enumerate((text_of(root, relative) or "").splitlines(), 1):
            code = line.strip()
            if code.startswith("//"):
                # A test commented out is a test nobody runs and nobody sees missing.
                if re.match(r"//\s*(@Test\b|func test\w*\()", code):
                    problems.append(f"{relative}:{number}: a test is commented out")
                continue
            if re.search(r"\.disabled\(\s*\)|\.disabled\b(?!\()", code):
                problems.append(f"{relative}:{number}: .disabled without a reason")
            if re.search(r"XCTSkip\(\s*\)", code):
                problems.append(f"{relative}:{number}: XCTSkip without a message")
    return problems


def check_secrets(root: Path, files):
    problems = []
    for relative in files:
        if relative in SELF:
            continue
        text = text_of(root, relative)
        if text is None:
            continue
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                problems.append(f"{relative}: looks like {label}")
        if relative == "project.yml":
            for number, line in enumerate(text.splitlines(), 1):
                found = TEAM.match(line)
                if found:
                    problems.append(f"{relative}:{number}: a signing team ({found.group(1)}) is committed")
    return problems


def check_junk(root: Path, files):
    problems = []
    for relative in files:
        path = Path(relative)
        if path.name in JUNK_NAMES or relative.endswith(JUNK_SUFFIXES):
            problems.append(f"{relative}: build output or editor state is committed")
        elif any(part in relative + "/" for part in JUNK_PARTS) or relative.startswith("build/"):
            problems.append(f"{relative}: build output or editor state is committed")
        try:
            size = (root / relative).stat().st_size
        except OSError:
            continue
        if size > MAX_BYTES:
            problems.append(f"{relative}: {size / 1024 / 1024:.1f} MB is too big for a repository")
    return problems


def check_markers(root: Path, files):
    problems = []
    for relative in files:
        if relative in SELF:
            continue
        text = text_of(root, relative)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if CONFLICT.match(line):
                problems.append(f"{relative}:{number}: a merge conflict marker")
    return problems


SPEC_REFERENCE = re.compile(r"\bspecs?[ /](\d{3})\b", re.IGNORECASE)
REFERENCE_SUFFIXES = (".swift", ".md", ".sh", ".py", ".yml")
REMOTE_PACKAGE = re.compile(r"\.package\(\s*url:")
REMOTE_PROJECT_PACKAGE = re.compile(r"^\s*url:\s", re.MULTILINE)


def check_references(root: Path, files):
    folders = {f.split("/")[1][:3] for f in files if f.startswith("specs/") and f.count("/") >= 2}
    problems = []
    for relative in files:
        if relative in SELF or relative.startswith("specs/") or not relative.endswith(REFERENCE_SUFFIXES):
            continue
        for number, line in enumerate((text_of(root, relative) or "").splitlines(), 1):
            for found in SPEC_REFERENCE.finditer(line):
                if found.group(1) not in folders:
                    problems.append(f"{relative}:{number}: refers to spec {found.group(1)}, which has no folder")
    return problems


def check_dependencies(root: Path, files):
    problems = []
    for relative in files:
        name = Path(relative).name
        text = text_of(root, relative) if name in ("Package.swift", "project.yml") else None
        if text is None:
            continue
        if name == "Package.swift" and REMOTE_PACKAGE.search(text):
            problems.append(f"{relative}: a package comes from a remote URL; use a path")
        if name == "project.yml" and REMOTE_PROJECT_PACKAGE.search(text):
            problems.append(f"{relative}: a package comes from a remote URL; use a path")
    return problems


UI_IMPORT = re.compile(r"^\s*import\s+(SwiftUI|UIKit|AppKit|WatchKit)\b", re.MULTILINE)
LOGIC_IMPORT = re.compile(r"^\s*import\s+(Photos|Vision|BaselineKit)\b", re.MULTILINE)
# The one place the package turns an image into a platform one.
UI_IMPORT_ALLOWED = {"Packages/CleanupKit/Sources/CleanupKit/Library/PhotoKitLibrary.swift"}
PACKAGE_SOURCES = "Packages/CleanupKit/Sources/CleanupKit/"


def first_code_line(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("//"):
            return stripped
    return ""


def check_layers(root: Path, files):
    problems = []
    for relative in files:
        if not relative.endswith(".swift"):
            continue
        text = text_of(root, relative) or ""
        if relative.startswith(PACKAGE_SOURCES):
            if UI_IMPORT.search(text) and relative not in UI_IMPORT_ALLOWED:
                problems.append(f"{relative}: the package imports a UI framework")
            if re.search(r"^\s*import\s+BaselineKit\b", text, re.MULTILINE):
                problems.append(f"{relative}: CleanupKit imports BaselineKit, which depends on it")
        elif relative.startswith("iclean/"):
            found = LOGIC_IMPORT.search(text)
            if found and first_code_line(text) != "#if DEBUG":
                problems.append(
                    f"{relative}: the app imports {found.group(1)} outside `#if DEBUG` tooling"
                )
    return problems


# PhotoKit hides all but one frame of a burst from a fetch that is given no options. The scan asks for every
# frame (`includeAllBurstAssets`), so a look-up by identifier with `options: nil` cannot find them again.
BY_IDENTIFIER_WITHOUT_OPTIONS = re.compile(
    r"fetchAssets\(\s*withLocalIdentifiers:(?:(?!fetchAssets).){0,200}?options:\s*nil\b", re.DOTALL
)


def check_photokit(root: Path, files):
    problems = []
    for relative in files:
        if not relative.endswith(".swift") or not relative.startswith((PACKAGE_SOURCES, "iclean/")):
            continue
        text = text_of(root, relative)
        if text is None:
            continue
        for found in BY_IDENTIFIER_WITHOUT_OPTIONS.finditer(text):
            line = text.count("\n", 0, found.start()) + 1
            problems.append(
                f"{relative}:{line}: a look-up by identifier without options finds only the key photo of "
                "a burst; pass PhotoKitLibrary.lookupOptions()"
            )
    return problems


CHECKS = {
    "data": check_data,
    "plans": check_plans,
    "privacy": check_privacy,
    "skips": check_skips,
    "secrets": check_secrets,
    "junk": check_junk,
    "markers": check_markers,
    "references": check_references,
    "dependencies": check_dependencies,
    "layers": check_layers,
    "photokit": check_photokit,
}


def run(root: Path):
    """Returns {check name: [problems]}."""
    files = tracked_files(root)
    return {name: check(root, files) for name, check in CHECKS.items()}


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    results = run(root)
    failed = 0
    for name, problems in results.items():
        for problem in problems:
            print(f"[{name}] {problem}")
        failed += len(problems)
    if failed:
        print(f"\n{failed} problem(s)")
        return 1
    print(f"{len(results)} checks passed: {', '.join(results)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
