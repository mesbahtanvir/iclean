#!/usr/bin/env python3
"""Checks an app that was built, not the sources it was built from.

    scripts/check-built-app.py path/to/iclean.app [--configuration Release]

What a person installs is what the constitution (Principle V) and the privacy manifest promise
about, and a build setting can change it without one line of source changing. For the iPhone and the
Mac bundle alike:

  - Info.plist: the bundle id, the Photos text that says nothing leaves the device, no App Transport
    Security exceptions, no export-compliance prompt; on the iPhone the background mode a scan that
    continues needs, on the Mac the minimum system version
  - the privacy manifest is in the bundle and tracks nothing
  - the app links no networking framework, and its binary names no networking API
  - a Release binary holds none of the tooling that is only compiled into DEBUG builds

The binary checks need `otool` and `strings` (macOS) and are skipped, with a note, without them.
Prints one line per problem and exits 1 when there is any.
"""

import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

BUNDLE_ID = "com.mesbahtanvir.iclean"
MIN_MAC = (15, 0)

# Frameworks an app that never talks to a network has no reason to link.
FORBIDDEN_FRAMEWORKS = {
    "Network",
    "CFNetwork",
    "SystemConfiguration",
    "WebKit",
    "SafariServices",
    "CloudKit",
}
# Names a binary carries when its code uses the API (Objective-C class names, mangled Swift names).
FORBIDDEN_NAMES = (
    "URLSession",
    "NWConnection",
    "NWPathMonitor",
    "NWBrowser",
    "CKContainer",
    "WKWebView",
    "SFSafariViewController",
    "SCNetworkReachability",
)
# Compiled only into DEBUG builds (`#if DEBUG`): a Release binary must not name them.
DEBUG_ONLY_NAMES = (
    "NetworkTripwire",
    "DemoPhotoLibrary",
    "DebugSeeding",
    "BaselineView",
    "WindowSnapshot",
)


def layout(app: Path):
    """(platform, Info.plist, binary directory, resources directory) of a bundle."""
    if (app / "Contents" / "Info.plist").exists():
        return "mac", app / "Contents" / "Info.plist", app / "Contents" / "MacOS", app / "Contents" / "Resources"
    return "ios", app / "Info.plist", app, app


def version_tuple(text: str):
    return tuple(int(part) for part in re.findall(r"\d+", str(text))[:2])


def check_info(info: dict, platform: str):
    problems = []
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        problems.append(f"Info.plist: the bundle id is {info.get('CFBundleIdentifier')!r}, not {BUNDLE_ID}")
    if "nothing leaves" not in str(info.get("NSPhotoLibraryUsageDescription", "")):
        problems.append("Info.plist: the Photos usage text does not say that nothing leaves the device")
    if "NSAppTransportSecurity" in info:
        problems.append("Info.plist: NSAppTransportSecurity is set; the app has no network")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        problems.append("Info.plist: ITSAppUsesNonExemptEncryption must be false")
    if platform == "ios":
        if info.get("UIBackgroundModes") != ["processing"]:
            problems.append(f"Info.plist: UIBackgroundModes is {info.get('UIBackgroundModes')!r}, not ['processing']")
        if not info.get("BGTaskSchedulerPermittedIdentifiers"):
            problems.append("Info.plist: no BGTaskSchedulerPermittedIdentifiers (a scan could not continue)")
    else:
        minimum = version_tuple(info.get("LSMinimumSystemVersion", "0"))
        if minimum < MIN_MAC:
            problems.append(f"Info.plist: LSMinimumSystemVersion {minimum} is below {MIN_MAC}")
    return problems


def check_privacy(manifest):
    if manifest is None:
        return ["the privacy manifest (PrivacyInfo.xcprivacy) is not in the bundle"]
    problems = []
    if manifest.get("NSPrivacyTracking") is not False:
        problems.append("PrivacyInfo.xcprivacy: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains"):
        problems.append("PrivacyInfo.xcprivacy: tracking domains are listed")
    if manifest.get("NSPrivacyCollectedDataTypes"):
        problems.append("PrivacyInfo.xcprivacy: collected data types are listed")
    return problems


def check_linked(otool_output: str):
    """From `otool -L`: the frameworks the binary links directly."""
    linked = set(re.findall(r"/(\w+)\.framework/", otool_output))
    return [f"the binary links {name}.framework" for name in sorted(linked & FORBIDDEN_FRAMEWORKS)]


def check_names(strings_text: str, release: bool):
    """From `strings`: networking APIs, and in a Release binary the DEBUG tooling."""
    problems = [f"the binary names {name}" for name in FORBIDDEN_NAMES if name in strings_text]
    if release:
        problems += [f"the Release binary names {name}, which is DEBUG-only" for name in DEBUG_ONLY_NAMES if name in strings_text]
    return problems


def read_plist(path: Path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, ValueError):
        return None


def check_app(app: Path, release: bool):
    """Returns (problems, notes)."""
    platform, info_path, binary_dir, resources = layout(app)
    info = read_plist(info_path)
    if info is None:
        return [f"{info_path}: cannot be read"], []
    problems = check_info(info, platform)
    problems += check_privacy(read_plist(resources / "PrivacyInfo.xcprivacy"))

    notes = []
    binary = binary_dir / info.get("CFBundleExecutable", app.stem)
    if not binary.exists():
        problems.append(f"{binary}: the executable is missing")
    elif shutil.which("otool") and shutil.which("strings"):
        linked = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
        names = subprocess.run(["strings", "-a", str(binary)], capture_output=True, text=True).stdout
        problems += check_linked(linked)
        problems += check_names(names, release)
        notes.append(f"{binary.name}: {len(names.splitlines())} strings, {len(linked.splitlines()) - 1} linked libraries")
        if release and "BaselineKit" in names:
            notes.append("BaselineKit is linked into the Release binary (linked, never called)")
    else:
        notes.append("otool or strings is missing: the binary was not read")
    return problems, notes


def main() -> int:
    args = sys.argv[1:]
    release = False
    if "--configuration" in args:
        i = args.index("--configuration")
        release = args[i + 1] == "Release"
        del args[i : i + 2]
    if len(args) != 1 or not Path(args[0]).is_dir():
        print(__doc__)
        return 2
    problems, notes = check_app(Path(args[0]), release)
    for note in notes:
        print(f"note: {note}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s)")
        return 1
    print(f"{args[0]}: the built app keeps its promises")
    return 0


if __name__ == "__main__":
    sys.exit(main())
