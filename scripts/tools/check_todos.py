#!/usr/bin/env python3
"""Require issue references for tracked temporary-work markers."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

SCANNED_SUFFIXES = {
    ".swift",
    ".h",
    ".c",
    ".m",
    ".mm",
    ".cpp",
    ".kt",
    ".kts",
    ".rs",
    ".py",
    ".sh",
    ".yml",
    ".yaml",
    ".json",
    ".rc",
    ".te",
    ".mk",
    ".bp",
}
MARKERS = ("TO" + "DO", "FIX" + "ME")
MARKER_PATTERN = re.compile(r"\b(?:" + "|".join(map(re.escape, MARKERS)) + r")\b")
ISSUE_PATTERN = re.compile(r"^\(#[0-9]+\)")
SKIPPED_PREFIXES = (
    "ThirdParty/patches/",
    "Images/tools/vendor/",
)


def tracked_paths(root: Path) -> list[PurePosixPath]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [
        PurePosixPath(path.decode("utf-8", errors="surrogateescape"))
        for path in result.stdout.split(b"\0")
        if path
    ]


def should_scan(path: PurePosixPath) -> bool:
    value = path.as_posix()
    if path.suffix.lower() not in SCANNED_SUFFIXES:
        return False
    if path.parts[0] == "docs" or path.suffix.lower() == ".md":
        return False
    return not any(value.startswith(prefix) for prefix in SKIPPED_PREFIXES)


def violations(root: Path) -> list[str]:
    failures: list[str] = []
    for relative_path in tracked_paths(root):
        if not should_scan(relative_path):
            continue
        file_path = root / relative_path
        try:
            contents = file_path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            failures.append(f"{relative_path}: cannot read tracked file: {error}")
            continue
        for line_number, line in enumerate(contents.splitlines(), start=1):
            for match in MARKER_PATTERN.finditer(line):
                marker = match.group(0)
                if ISSUE_PATTERN.match(line[match.end() :]) is None:
                    failures.append(
                        f"{relative_path}:{line_number}: {marker} must be followed by an issue reference like (#123)"
                    )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="repository root; defaults to the current directory",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    try:
        failures = violations(root)
    except subprocess.CalledProcessError as error:
        print(
            f"check-todos: git ls-files failed in {root}: {error}",
            file=sys.stderr,
        )
        return 1

    if failures:
        for failure in failures:
            print(f"ERROR {failure}")
        return 1
    print("check-todos: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
