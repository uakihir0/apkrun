#!/usr/bin/env python3
"""Check the parts of the G3 evidence that the exit status of xcodebuild cannot show (#023 review).

    python3 -I scripts/tools/check-g3-evidence.py ARTIFACTS XCRESULT REPOSITORY

One line per check goes to standard output, and the script exits 1 when any check fails:

- ARTIFACTS/summary.txt has the line `result: passed`, which G3GraphicsTests writes only when every condition of
  roadmap.md §2 holds.
- XCRESULT holds G3GraphicsTests, and that test was executed and passed. No other test in the run failed, was
  skipped, or was left out: a run with no executed test, or one where the check skipped, fails.
- The fixed-size statement of condition 6 (roadmap.md §2) is in the design, with the exact text pinned below.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

TEST_PREFIX = "G3GraphicsTests/"

# The fixed-size statement of condition 6 (roadmap.md §2). Each entry names the design file, the heading that starts
# the section that must hold the text, and the exact text. A change to these lines needs a change to this file.
FIXED_SIZE_STATEMENTS = (
    (
        "docs/02-design/graphics.md",
        "### #023 SurfaceFlinger to Metal",
        "3. The window is **fixed-size**: display 0 keeps the image's default mode, and the window scales the layer "
        "with aspect fit.",
    ),
    (
        "docs/02-design/display-and-windowing.md",
        "### 5.3 Wrapper presentation algorithm",
        "**Development window (#023), fixed-size:** display 0 keeps the image's default mode, and the window scales the "
        "layer with aspect fit when it is resized (graphics.md §12 #023, step 3).",
    ),
)


def summary_check(path: Path) -> tuple[bool, str]:
    """The test's own verdict: a `result: passed` line in summary.txt."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return False, f"summary: {path} cannot be read ({error.strerror})"
    if "result: passed" in lines:
        return True, "summary: result: passed"
    return False, "summary: no `result: passed` line in summary.txt"


def test_cases(node: object) -> list[tuple[str, str]]:
    """Every test case of an xcresult test tree, as (identifier, result)."""
    found: list[tuple[str, str]] = []
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            identifier = str(node.get("nodeIdentifier") or node.get("name") or "")
            found.append((identifier, str(node.get("result") or "none")))
        for value in node.values():
            found.extend(test_cases(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(test_cases(item))
    return found


def xcresult_check(tree: dict) -> tuple[bool, list[str]]:
    """The G3 test ran and passed, and nothing else in the run failed or was skipped."""
    cases = test_cases(tree.get("testNodes", []))
    lines: list[str] = []
    ok = True
    g3_cases = [case for case in cases if case[0].startswith(TEST_PREFIX)]
    if not g3_cases:
        ok = False
        lines.append("failed: xcresult: no G3GraphicsTests test was executed")
    for identifier, result in g3_cases:
        if result == "Passed":
            lines.append(f"passed: xcresult: {identifier} executed and passed")
        else:
            ok = False
            lines.append(f"failed: xcresult: {identifier} has result {result}")
    others = [case for case in cases if not case[0].startswith(TEST_PREFIX)]
    not_passed = [case for case in others if case[1] != "Passed"]
    if not_passed:
        ok = False
        lines.append(f"failed: xcresult: {len(not_passed)} other test(s) in the run did not pass")
    lines.append(f"info: xcresult: {len(cases)} test case(s) in the run, {len(g3_cases)} of G3GraphicsTests")
    return ok, lines


def read_xcresult(path: Path) -> dict:
    """The test tree of an xcresult bundle, from xcresulttool."""
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(path), "--compact"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"xcresulttool failed on {path}: {completed.stderr.strip()[-300:]}")
    return json.loads(completed.stdout)


def section(text: str, heading: str) -> str | None:
    """The text from `heading` to the next heading of the same or a higher level."""
    start = text.find(heading)
    if start < 0:
        return None
    level = len(heading) - len(heading.lstrip("#"))
    body = text[start + len(heading):]
    lines = body.split("\n")
    kept: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("#") and stripped.split(" ", 1)[0].count("#") <= level:
            break
        kept.append(line)
    return "\n".join(kept)


def fixed_size_check(repository: Path) -> tuple[bool, list[str]]:
    """The fixed-size statement is in each design section, with the pinned text."""
    lines: list[str] = []
    ok = True
    for relative, heading, statement in FIXED_SIZE_STATEMENTS:
        path = repository / relative
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            ok = False
            lines.append(f"failed: fixed-size: {relative} cannot be read ({error.strerror})")
            continue
        body = section(text, heading)
        if body is None:
            ok = False
            lines.append(f"failed: fixed-size: {relative} has no section `{heading}`")
        elif statement in body:
            lines.append(f"passed: fixed-size: {relative} states it in `{heading}`")
        else:
            ok = False
            lines.append(f"failed: fixed-size: {relative} lacks the pinned statement in `{heading}`")
    return ok, lines


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: check-g3-evidence.py ARTIFACTS XCRESULT REPOSITORY", file=sys.stderr)
        return 64
    artifacts, xcresult, repository = Path(argv[1]), Path(argv[2]), Path(argv[3])
    failures = 0
    ok, message = summary_check(artifacts / "summary.txt")
    failures += 0 if ok else 1
    print(("passed: " if ok else "failed: ") + message)
    try:
        ok, lines = xcresult_check(read_xcresult(xcresult))
    except (RuntimeError, OSError, json.JSONDecodeError) as error:
        ok, lines = False, [f"failed: xcresult: {error}"]
    failures += 0 if ok else 1
    for line in lines:
        print(line)
    ok, lines = fixed_size_check(repository)
    failures += 0 if ok else 1
    for line in lines:
        print(line)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
