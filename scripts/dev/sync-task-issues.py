#!/usr/bin/env python3
"""Make each task's GitHub issue match its entry in docs/04-plan/issues/.

    scripts/dev/sync-task-issues.py [--apply] [N ...]

For every task entry (`## #N Title` in a milestone file), the issue gets:

- the title `Title`;
- a body generated from the entry: a link to the entry, the milestone, dependencies, gate, and goal;
- the GitHub milestone named by the milestone file's title (`# M6 Update system`), created when missing;
- the label `task`.

The issue state (open or closed) and other labels are not changed. Without --apply, the script only
prints what it would change. With task numbers, only those tasks are synced.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ISSUES = ROOT / "docs/04-plan/issues"
MARKER = "Generated from the task entry by `scripts/dev/sync-task-issues.py`."


@dataclass
class Entry:
    number: int
    title: str
    file: str
    milestone: str
    fields: dict[str, str]
    goal: str


def slug(text: str) -> str:
    text = text.replace("`", "").strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def gh(*arguments: str, input_text: str | None = None) -> str:
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True, input=input_text)
    if result.returncode != 0:
        sys.exit(f"sync-task-issues: gh {' '.join(arguments[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def read_entries() -> list[Entry]:
    entries = []
    for path in sorted(ISSUES.glob("*.md")):
        if path.name == "README.md":
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        milestone = next((line[2:].strip() for line in lines if line.startswith("# ")), path.stem)
        current: Entry | None = None
        for line in lines:
            heading = re.match(r"^## #(\d+) (.+?)\s*$", line)
            if heading:
                current = Entry(int(heading.group(1)), heading.group(2), path.name, milestone, {}, "")
                entries.append(current)
                continue
            if current is None:
                continue
            if line.startswith("## "):
                current = None
                continue
            field = re.match(r"^\|\s*(Milestone|Depends on|Gate|Design|Code)\s*\|\s*(.*?)\s*\|\s*$", line)
            if field:
                current.fields[field.group(1)] = field.group(2)
            goal = re.match(r"^\*\*Goal\.\*\*\s*(.*)$", line)
            if goal:
                current.goal = goal.group(1)
    return entries


def absolute_links(text: str, repository: str, file: str) -> str:
    def replace(match: re.Match[str]) -> str:
        target = match.group(2)
        if re.match(r"^[a-z]+:", target):
            return match.group(0)
        path = (Path("docs/04-plan/issues") / target).as_posix()
        parts: list[str] = []
        for part in path.split("/"):
            if part == "..":
                parts.pop()
            elif part != ".":
                parts.append(part)
        return f"[{match.group(1)}](https://github.com/{repository}/blob/main/{'/'.join(parts)})"

    return re.sub(r"\[([^\]]*)\]\(([^)\s]+)\)", replace, text)


def body_for(entry: Entry, repository: str) -> str:
    anchor = slug(f"#{entry.number} {entry.title}")
    link = f"https://github.com/{repository}/blob/main/docs/04-plan/issues/{entry.file}#{anchor}"
    rows = [f"| {name} | {absolute_links(entry.fields[name], repository, entry.file)} |"
            for name in ("Milestone", "Depends on", "Gate", "Design") if name in entry.fields]
    parts = [
        f"**Task entry:** [{entry.file} → #{entry.number}]({link})",
        "",
        "| Field | Value |",
        "|---|---|",
        *rows,
        "",
    ]
    if entry.goal:
        parts += [f"**Goal.** {absolute_links(entry.goal, repository, entry.file)}", ""]
    parts.append(f"<sub>{MARKER} Edit the entry, not this issue.</sub>")
    return "\n".join(parts) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the changes to GitHub")
    parser.add_argument("tasks", nargs="*", type=int, help="only these task numbers")
    arguments = parser.parse_args()

    repository = json.loads(gh("repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
    issues = {
        issue["number"]: issue
        for issue in json.loads(gh("issue", "list", "--state", "all", "--limit", "1000",
                                   "--json", "number,title,body,milestone,labels"))
    }
    milestones = {
        item["title"] for item in json.loads(gh("api", f"repos/{repository}/milestones?state=all&per_page=100"))
    }

    entries = read_entries()
    seen: set[int] = set()
    changes = 0
    for entry in entries:
        if entry.number in seen:
            sys.exit(f"sync-task-issues: #{entry.number} has two entries")
        seen.add(entry.number)
        if arguments.tasks and entry.number not in arguments.tasks:
            continue
        issue = issues.get(entry.number)
        if issue is None:
            print(f"#{entry.number}: no GitHub issue; open one first (workflow.md §2.4)")
            continue
        body = body_for(entry, repository)
        wanted = {
            "title": entry.title,
            "body": body,
            "milestone": entry.milestone,
            "task label": True,
        }
        current = {
            "title": issue["title"],
            "body": issue["body"],
            "milestone": (issue.get("milestone") or {}).get("title"),
            "task label": any(label["name"] == "task" for label in issue["labels"]),
        }
        current["body"] = (current["body"] or "").replace("\r\n", "\n").strip()
        wanted["body"] = body.strip()
        different = [key for key in wanted if wanted[key] != current[key]]
        if not different:
            continue
        changes += 1
        print(f"#{entry.number} {entry.title}: {', '.join(different)}")
        if not arguments.apply:
            continue
        if entry.milestone not in milestones:
            gh("api", "-X", "POST", f"repos/{repository}/milestones", "-f", f"title={entry.milestone}")
            milestones.add(entry.milestone)
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as file:
            file.write(body)
            body_file = file.name
        gh("issue", "edit", str(entry.number), "--title", entry.title, "--body-file", body_file,
           "--milestone", entry.milestone, "--add-label", "task")
        Path(body_file).unlink()

    if changes == 0:
        print("sync-task-issues: every issue matches its entry")
    elif not arguments.apply:
        print(f"sync-task-issues: {changes} issue(s) differ; run with --apply to update them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
