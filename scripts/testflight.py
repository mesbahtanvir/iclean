#!/usr/bin/env python3
"""The logic of the TestFlight workflow (.github/workflows/testflight.yml), kept out of the YAML so that it
can be tested: which version and build number a release gets, whether the secrets can work, how the key is
written, what the export is told, and whether Xcode is new enough.

    scripts/testflight.py version --ref REF --run-number N [--input-version V] [--offset N] [--project project.yml]
    scripts/testflight.py xcode --require MAJOR [--allow-older]        (reads `xcodebuild -version` on stdin)
    scripts/testflight.py xcode-path VERSION
    scripts/testflight.py credentials
    scripts/testflight.py write-key PATH
    scripts/testflight.py export-options --team TEAM PATH

`credentials` and `write-key` read ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 and APPLE_TEAM_ID from the
environment. No command prints a secret, not even to say that it is wrong: a mistake is described, never
shown. A problem is printed as a workflow error annotation and the exit status is 1.

The version of a release is the one its tag names (v1.2.0), else the workflow's input, else the one in
project.yml. Its build number is the number of the workflow run plus TESTFLIGHT_BUILD_OFFSET (a repository
variable, for when builds were uploaded some other way first): App Store Connect needs each upload of a
version to have a build number that no earlier upload had.
"""

import argparse
import base64
import binascii
import os
import plistlib
import re
import sys
from pathlib import Path

NUMBER = r"(?:0|[1-9][0-9]{0,8})"
VERSION = re.compile(rf"{NUMBER}(?:\.{NUMBER}){{0,2}}")
TAG = re.compile(rf"v({NUMBER}(?:\.{NUMBER}){{0,2}})")
# Far beyond any run number; a bigger one is a typo in the offset, and Apple's message about it is obscure.
MAX_BUILD = 999_999_999

SECRETS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_TEAM_ID")
KEY_ID = re.compile(r"[A-Za-z0-9]{10}")
TEAM_ID = re.compile(r"[A-Za-z0-9]{10}")
ISSUER_ID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
# Written in two pieces so that the repository's own secret scan does not take this file for a key.
PEM_BEGIN = "-----BEGIN " + "PRIVATE KEY-----"
PEM_END = "-----END " + "PRIVATE KEY-----"

WHAT_EACH_SECRET_IS = {
    "ASC_KEY_ID": "the 10 letters and digits beside the key in App Store Connect (Users and Access, Integrations), not the key's name",
    "ASC_ISSUER_ID": "the issuer ID above the list of keys, a UUID like 00000000-0000-0000-0000-000000000000",
    "ASC_KEY_P8": "the whole AuthKey_XXXXXXXXXX.p8 file you downloaded, or that file encoded as base64",
    "APPLE_TEAM_ID": "your 10-character team ID (developer.apple.com, Membership details)",
}


class Problem(Exception):
    """Something the person running the workflow can fix; the message says what."""


def project_version(project: Path) -> str:
    """The MARKETING_VERSION project.yml gives every build that is not told another."""
    for line in project.read_text(encoding="utf-8").splitlines():
        found = re.match(r'\s*MARKETING_VERSION:\s*"?([^"\s#]+)"?\s*(?:#.*)?$', line)
        if found:
            if not VERSION.fullmatch(found.group(1)):
                raise Problem(f"{project}: MARKETING_VERSION {found.group(1)!r} is not one to three numbers like 1.2.0")
            return found.group(1)
    raise Problem(f"{project}: sets no MARKETING_VERSION")


def release_version(ref: str, requested: str, default: str):
    """(version, where it came from): a tag names its own version, else the input, else project.yml."""
    requested = requested.strip()
    if ref.startswith("refs/tags/"):
        tag = ref[len("refs/tags/") :]
        found = TAG.fullmatch(tag)
        if not found:
            raise Problem(
                f"The tag {tag!r} is not a v followed by one to three numbers (v1.2.0). "
                "A version cannot carry a suffix such as -beta; the build number tells builds apart."
            )
        if requested and requested != found.group(1):
            raise Problem(f"The tag says {found.group(1)} and the version input says {requested}; give only one")
        return found.group(1), f"the tag {tag}"
    if requested:
        if not VERSION.fullmatch(requested):
            raise Problem(f"The version {requested!r} is not one to three numbers like 1.2.0")
        return requested, "the version input"
    return default, "project.yml"


def build_number(run_number: str, offset: str) -> int:
    """The run's number plus the offset, which is nothing unless a repository variable says otherwise."""
    run_number, offset = run_number.strip(), offset.strip() or "0"
    if not re.fullmatch(r"[0-9]+", run_number) or int(run_number) < 1:
        raise Problem(f"The run number {run_number!r} is not a whole number from 1")
    if not re.fullmatch(r"[0-9]+", offset):
        raise Problem("TESTFLIGHT_BUILD_OFFSET must be a whole number of 0 or more")
    total = int(run_number) + int(offset)
    if total > MAX_BUILD:
        raise Problem(f"The build number {total} is far too big; is TESTFLIGHT_BUILD_OFFSET a typo?")
    return total


def xcode_major(version_output: str) -> int:
    found = re.search(r"^Xcode (\d+)", version_output, re.MULTILINE)
    if not found:
        raise Problem("Cannot read the Xcode version from `xcodebuild -version`")
    return int(found.group(1))


def check_xcode(version_output: str, required: int, allow_older: bool):
    """(level, message), the level being "ok", "warning" or "error". Older than the README asks for is an
    error unless it was allowed, and then a warning."""
    major = xcode_major(version_output)
    name = version_output.splitlines()[0].strip()
    if major >= required:
        return "ok", f"{name} (the README asks for Xcode {required})"
    advice = (
        f"{name} is older than the Xcode {required} the README asks for. A toolchain that old compiles out the "
        "code written for the newer SDK (for example the scan that continues after the app is left), so this "
        "build would not have it. Pick a newer Xcode with the xcode input, or build anyway: tick allow_older_xcode, "
        "or set the repository variable TESTFLIGHT_ALLOW_OLDER_XCODE to true (a run started by a tag has no inputs)."
    )
    return ("warning" if allow_older else "error"), advice


def xcode_path(version: str, applications: Path = Path("/Applications")) -> Path:
    """The Xcode.app of a version on a GitHub runner, which names them Xcode_26.6.app."""
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version.strip()):
        raise Problem(f"The Xcode version {version!r} is not a number like 27 or 27.0")
    path = applications / f"Xcode_{version.strip()}.app"
    if not path.is_dir():
        installed = sorted(p.name for p in applications.glob("Xcode*.app")) or ["none"]
        raise Problem(f"{path} is not on this runner. Installed: {', '.join(installed)}")
    return path


def decode_key(value: str) -> str:
    """The key as PEM text from the PEM itself or from its base64, whatever the pasting did to its lines."""
    text = value.strip()
    if PEM_BEGIN not in text:
        try:
            text = base64.b64decode("".join(text.split()), validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            raise Problem("ASC_KEY_P8 is neither the text of the .p8 file nor that text as base64") from None
    text = text.replace("\\n", "\n")
    start, end = text.find(PEM_BEGIN), text.find(PEM_END)
    if start < 0 or end < start:
        raise Problem("ASC_KEY_P8 lacks the BEGIN and END lines of a private key")
    body = "".join(text[start + len(PEM_BEGIN) : end].split())
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", body):
        raise Problem("ASC_KEY_P8 holds something other than a key between its BEGIN and END lines")
    lines = [body[i : i + 64] for i in range(0, len(body), 64)]
    return "\n".join([PEM_BEGIN, *lines, PEM_END]) + "\n"


def secret_problems(environ) -> list:
    """One sentence for each secret that is missing or cannot be right. Never the secret itself."""
    shapes = {"ASC_KEY_ID": KEY_ID, "ASC_ISSUER_ID": ISSUER_ID, "APPLE_TEAM_ID": TEAM_ID}
    problems = []
    for name in SECRETS:
        value = environ.get(name, "").strip()
        should = f"{name} should be {WHAT_EACH_SECRET_IS[name]}"
        if not value:
            problems.append(
                f"{name} is not set. Add it as a secret of the testflight environment "
                f"(Settings, Environments, testflight). {should}. docs/RELEASING.md has the steps."
            )
        elif name in shapes and not shapes[name].fullmatch(value):
            problems.append(f"{name} does not look right. {should}.")
        elif name == "ASC_KEY_P8":
            try:
                decode_key(value)
            except Problem as problem:
                problems.append(f"{problem}. {should}.")
    return problems


def write_key(path: Path, pem: str) -> None:
    """The key in a file that only its owner can read, where xcodebuild is told to look."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(pem)


def export_options(team: str) -> dict:
    """What `xcodebuild -exportArchive` is told: sign with Apple's cloud signing and send the result to
    App Store Connect, with the build number the archive already has."""
    if not TEAM_ID.fullmatch(team.strip()):
        raise Problem(f"The team ID is {WHAT_EACH_SECRET_IS['APPLE_TEAM_ID']}")
    return {
        "method": "app-store-connect",
        "destination": "upload",
        "signingStyle": "automatic",
        "teamID": team.strip(),
        "uploadSymbols": True,
        # Xcode would otherwise raise a build number that was used before, and the number uploaded
        # would no longer be the one that was archived, checked and written in the summary.
        "manageAppVersionAndBuildNumber": False,
    }


def fail(message: str) -> int:
    print(f"::error::{message}", file=sys.stderr)
    return 1


def command_version(args, environ, stdin) -> int:
    default = project_version(Path(args.project))
    version, source = release_version(args.ref, args.input_version, default)
    build = build_number(args.run_number, args.offset)
    print(f"marketing_version={version}")
    print(f"build_number={build}")
    print(f"::notice title=TestFlight::Version {version} (from {source}), build {build}", file=sys.stderr)
    return 0


def command_xcode(args, environ, stdin) -> int:
    level, message = check_xcode(stdin.read(), args.require, args.allow_older)
    if level == "error":
        return fail(message)
    print(f"::warning title=Xcode::{message}" if level == "warning" else message)
    return 0


def command_xcode_path(args, environ, stdin) -> int:
    print(xcode_path(args.version))
    return 0


def command_credentials(args, environ, stdin) -> int:
    problems = secret_problems(environ)
    for problem in problems:
        fail(problem)
    if problems:
        return 1
    print("The four secrets are set and have the right shape.")
    return 0


def command_write_key(args, environ, stdin) -> int:
    write_key(Path(args.path), decode_key(environ.get("ASC_KEY_P8", "")))
    print(f"The API key is in {args.path}")
    return 0


def command_export_options(args, environ, stdin) -> int:
    path = Path(args.path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(export_options(args.team)))
    print(f"Export options are in {args.path}")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = top.add_subparsers(dest="command", required=True)

    version = commands.add_parser("version", help="the version and build number of this run")
    version.add_argument("--ref", required=True, help="github.ref")
    version.add_argument("--run-number", required=True, help="github.run_number")
    version.add_argument("--input-version", default="", help="a version asked for by hand")
    version.add_argument("--offset", default="", help="added to the run number")
    version.add_argument("--project", default="project.yml")
    version.set_defaults(run=command_version)

    xcode = commands.add_parser("xcode", help="Xcode is new enough; `xcodebuild -version` is read from stdin")
    xcode.add_argument("--require", required=True, type=int, help="the oldest major version allowed")
    xcode.add_argument("--allow-older", action="store_true", help="warn instead of failing")
    xcode.set_defaults(run=command_xcode)

    path = commands.add_parser("xcode-path", help="the Xcode.app of a version")
    path.add_argument("version")
    path.set_defaults(run=command_xcode_path)

    credentials = commands.add_parser("credentials", help="the four secrets are set and look right")
    credentials.set_defaults(run=command_credentials)

    key = commands.add_parser("write-key", help="write ASC_KEY_P8 to a file only its owner can read")
    key.add_argument("path")
    key.set_defaults(run=command_write_key)

    options = commands.add_parser("export-options", help="write the options of the export")
    options.add_argument("--team", required=True)
    options.add_argument("path")
    options.set_defaults(run=command_export_options)
    return top


def main(argv=None, environ=None, stdin=None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.run(args, os.environ if environ is None else environ, sys.stdin if stdin is None else stdin)
    except Problem as problem:
        return fail(str(problem))


if __name__ == "__main__":
    sys.exit(main())
