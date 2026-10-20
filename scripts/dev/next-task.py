#!/usr/bin/env python3
"""Print the tasks that can be worked on now.

    scripts/dev/next-task.py [--all]

Reads the task index (docs/04-plan/issues/README.md §3, in working order) and the state of each task's
GitHub issue (`gh issue list`), then prints:

1. tasks labeled `needs-verification`: their code is on `main`, and T2, T3, or gate runs are left;
2. tasks in progress (open and assigned);
3. open, unassigned tasks whose dependencies are met, in working order. A dependency is met when its
   issue is closed or labeled `needs-verification` (docs/05-development/workflow.md §2.2).

Without --all, the third list stops after five tasks.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

INDEX = Path(__file__).resolve().parents[2] / "docs/04-plan/issues/README.md"
ROW = re.compile(r"^\|\s*#(\d+)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$")


def read_index() -> list[tuple[int, str, str, str]]:
    rows = []
    for line in INDEX.read_text(encoding="utf-8").splitlines():
        match = ROW.match(line)
        if match:
            number, title, milestone, depends, _gate = match.groups()
            rows.append((int(number), title, milestone, depends))
    if not rows:
        sys.exit(f"next-task: no task rows in {INDEX}")
    return rows


def read_issues() -> dict[int, dict]:
    try:
        output = subprocess.run(
            ["gh", "issue", "list", "--state", "all", "--limit", "1000",
             "--json", "number,state,labels,assignees"],
            check=True, capture_output=True, text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"next-task: cannot read GitHub issues with gh: {error}")
    issues = {}
    for issue in json.loads(output):
        issues[issue["number"]] = {
            "closed": issue["state"] != "OPEN",
            "labels": {label["name"] for label in issue["labels"]},
            "assigned": bool(issue["assignees"]),
        }
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="list every ready task")
    arguments = parser.parse_args()

    rows = read_index()
    issues = read_issues()

    def met(number: int) -> bool:
        issue = issues.get(number)
        return issue is not None and (issue["closed"] or "needs-verification" in issue["labels"])

    verify, progress, ready, manual = [], [], [], []
    for number, title, milestone, depends in rows:
        issue = issues.get(number)
        if issue is None:
            print(f"warning: #{number} {title} has no GitHub issue", file=sys.stderr)
            continue
        if issue["closed"]:
            continue
        line = f"#{number} {title} ({milestone})"
        if "needs-verification" in issue["labels"]:
            verify.append(line)
            continue
        if issue["assigned"]:
            progress.append(line)
            continue
        if "blocked" in issue["labels"]:
            continue
        dependencies = [int(value) for value in re.findall(r"#(\d+)", depends)]
        if not dependencies and depends.strip().lower() not in {"none", ""}:
            manual.append(f"{line}: depends on {depends}")
            continue
        if all(met(value) for value in dependencies):
            ready.append(line)

    sections = [
        ("Needs verification on a real Mac", verify),
        ("In progress", progress),
        ("Ready, in working order", ready if arguments.all else ready[:5]),
        ("Check the dependencies by hand", manual if arguments.all else []),
    ]
    for heading, lines in sections:
        if lines:
            print(f"{heading}:")
            for line in lines:
                print(f"  {line}")
    if not ready:
        print("No task is ready. Verify or finish the tasks above first.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
