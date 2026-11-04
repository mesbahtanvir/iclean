#!/usr/bin/env python3
"""Checks the rules every GitHub Actions workflow of this repository follows, beyond what actionlint
checks (it does the syntax, the expressions and the shell).

    scripts/check-workflows.py [root]

  - the token is least-privilege: `permissions` is written, at the top or on every job
  - `defaults.run.shell` is `bash`, which is `bash -eo pipefail`: a pipeline fails when any command in
    it fails, so a check piped into `tee` still fails the step
  - a job that can hang has `timeout-minutes`
  - a workflow that starts on `pull_request` or `push` has a `concurrency` group, so a new push
    does not leave the old run holding a runner
  - every action is pinned to a tag or a commit, never a branch
  - an uploaded artifact has `retention-days`
  - no `pull_request_target` (it runs the base branch's workflow with a token for the fork's code)
  - no event text (a title, a branch name, a body) is pasted into a `run:` script, where it is code
  - the files a workflow's `paths:` filter and its scripts name exist

Needs PyYAML. Prints one line per problem and exits 1 when there is any.
"""

import re
import sys
from pathlib import Path

import yaml

TAGGED = re.compile(r"^[\w.-]+/[\w./-]+@(?:v?\d[\w.]*|[0-9a-f]{40})$")
# Text anyone who can open a pull request or an issue writes. In a `run:` script it is code.
UNTRUSTED = (
    r"github\.head_ref",
    r"github\.event\.pull_request\.(?:title|body|head\.ref|head\.label)",
    r"github\.event\.issue\.(?:title|body)",
    r"github\.event\.(?:comment|review)\.body",
    r"github\.event\.head_commit\.(?:message|author\.(?:name|email))",
    r"github\.event\.commits",
    r"github\.event\.workflow_run\.(?:head_branch|head_commit\.message)",
)
INJECTABLE = re.compile(r"\$\{\{[^}]*\b(?:" + "|".join(UNTRUSTED) + r")")
SCRIPT = re.compile(r"\bscripts/[\w./-]*\w\.(?:py|sh|swift)\b")
LOCAL_ACTION = re.compile(r"^\./(\.github/actions/[\w./-]+)$")


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def triggers(doc: dict):
    """YAML 1.1 reads the key `on` as true."""
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {name: None for name in on}
    return on or {}


def steps_of(job: dict):
    return [s for s in job.get("steps", []) if isinstance(s, dict)]


def check_workflow(root: Path, path: Path):
    problems = []
    name = str(path.relative_to(root))
    doc = load(path)
    on = triggers(doc)
    jobs = doc.get("jobs", {}) or {}

    if "pull_request_target" in on:
        problems.append(f"{name}: pull_request_target runs fork code with a token")

    if "permissions" not in doc and not all("permissions" in job for job in jobs.values()):
        problems.append(f"{name}: no `permissions` (write them at the top, or on every job)")

    if ((doc.get("defaults") or {}).get("run") or {}).get("shell") != "bash":
        problems.append(f"{name}: no `defaults: run: shell: bash` (a pipeline would hide a failure)")

    if ("pull_request" in on or "push" in on) and "concurrency" not in doc:
        problems.append(f"{name}: no `concurrency` group")

    for key in ("pull_request", "push"):
        section = on.get(key)
        if not isinstance(section, dict):
            continue
        for pattern in section.get("paths") or []:
            prefix = re.split(r"[*?\[]", pattern.lstrip("!"))[0].rstrip("/")
            if prefix and not (root / prefix).exists():
                problems.append(f"{name}: the paths filter {pattern!r} names nothing that exists")

    for job_name, job in jobs.items():
        where = f"{name}: job {job_name}"
        if "uses" not in job and "timeout-minutes" not in job:
            problems.append(f"{where}: no `timeout-minutes`")
        for step in steps_of(job):
            uses = str(step.get("uses", ""))
            problems += check_step(root, where, step, uses)
    return problems


def check_step(root: Path, where: str, step: dict, uses: str):
    problems = []
    local = LOCAL_ACTION.match(uses)
    if local:
        if not (root / local.group(1) / "action.yml").exists():
            problems.append(f"{where}: the action {uses} has no action.yml")
    elif uses and not TAGGED.match(uses):
        problems.append(f"{where}: {uses} is not pinned to a tag or a commit")
    if uses.startswith("actions/upload-artifact") and "retention-days" not in (step.get("with") or {}):
        problems.append(f"{where}: an uploaded artifact without `retention-days`")
    script = str(step.get("run", ""))
    if INJECTABLE.search(script):
        problems.append(f"{where}: event text is pasted into a script (pass it as an env value)")
    for found in SCRIPT.findall(script):
        if not (root / found).exists():
            problems.append(f"{where}: runs {found}, which does not exist")
    return problems


def check_action(root: Path, path: Path):
    problems = []
    name = str(path.relative_to(root))
    for step in steps_of(load(path).get("runs", {})):
        if "run" in step and "shell" not in step:
            problems.append(f"{name}: a `run` step without `shell`")
        for found in SCRIPT.findall(str(step.get("run", ""))):
            if not (root / found).exists():
                problems.append(f"{name}: runs {found}, which does not exist")
    return problems


def check(root: Path):
    problems = []
    workflows = sorted((root / ".github" / "workflows").glob("*.y*ml"))
    if not workflows:
        problems.append(".github/workflows: no workflows")
    for path in workflows:
        problems += check_workflow(root, path)
    for path in sorted((root / ".github" / "actions").glob("*/action.y*ml")):
        problems += check_action(root, path)
    return problems


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    problems = check(root)
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s)")
        return 1
    count = len(list((root / ".github" / "workflows").glob("*.y*ml")))
    print(f"{count} workflows follow the rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
