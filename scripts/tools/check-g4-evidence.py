#!/usr/bin/env python3
"""Check that G4's native-window acceptance test ran and produced its required evidence.

    python3 -I scripts/tools/check-g4-evidence.py ARTIFACTS XCRESULT

The gate's xcodebuild status alone is not the verdict. The summary must contain all G4 conditions, the test host must
have written its screenshot and command logs, and xcresult must show G4NativeWindowTests passed.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

TEST_PREFIX = "G4NativeWindowTests/"
EXPECTED_TEXT = "Hello, APKRun 123!"
EXPECTED_SCREENSHOT = "screenshots/hellotext.png"
EXPECTED_RECORDING = "screen-recording.mov"


def summary_check(path: Path) -> tuple[bool, list[str]]:
    """Validate the JSON verdict and every G4 value instead of trusting a single pass marker."""
    try:
        summary = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return False, [f"failed: summary: cannot read valid JSON from {path} ({error})"]
    if not isinstance(summary, dict):
        return False, ["failed: summary: expected one JSON object"]

    checks: list[tuple[str, bool]] = [
        ("gate is G4", summary.get("gate") == "G4"),
        ("result is passed", summary.get("result") == "passed"),
        ("all 100 clicks were observed", summary.get("clicks_observed") == 100),
        ("the click sequence was 1 through 100", summary.get("click_sequence_valid") is True),
        ("the text field contains the exact expected text", summary.get("typed_text") == EXPECTED_TEXT),
        ("Escape returned to screen main", summary.get("screen_after_escape") == "main"),
        (
            "the ADB shell count is present and unchanged",
            type(summary.get("adb_shell_count_before_events")) is int
            and summary.get("adb_shell_count_before_events") == summary.get("adb_shell_count_after_events"),
        ),
        (
            "apkrun returned the handled-interrupt status and exited normally",
            type(summary.get("apkrun_exit_code")) is int
            and summary.get("apkrun_exit_code") == 130
            and summary.get("apkrun_termination_reason") == "exit",
        ),
        ("the native-window screenshot is listed", summary.get("window_capture") == EXPECTED_SCREENSHOT),
        ("the synchronized screen recording is listed", summary.get("screen_recording") == EXPECTED_RECORDING),
        (
            "screencapture finished successfully",
            type(summary.get("screen_recording_exit_code")) is int
            and summary.get("screen_recording_exit_code") == 0,
        ),
        (
            "the recording was ready before host input",
            summary.get("screen_recording_ready_before_first_host_event") is True,
        ),
        (
            "every host input event was posted while screencapture was running",
            type(summary.get("host_input_event_count")) is int
            and summary.get("host_input_event_count") > 0
            and type(summary.get("recorded_host_input_event_count")) is int
            and summary.get("recorded_host_input_event_count") == summary.get("host_input_event_count"),
        ),
        (
            "the first and last host events fall within the recording process lifetime",
            type(summary.get("first_host_input_offset_ms")) is int
            and summary.get("first_host_input_offset_ms") >= 0
            and type(summary.get("last_host_input_offset_ms")) is int
            and summary.get("last_host_input_offset_ms") >= summary.get("first_host_input_offset_ms")
            and type(summary.get("screen_recording_process_duration_ms")) is int
            and summary.get("screen_recording_process_duration_ms") >= summary.get("last_host_input_offset_ms"),
        ),
        (
            "the recorded movie has a positive byte count",
            type(summary.get("screen_recording_bytes")) is int
            and summary.get("screen_recording_bytes") > 0,
        ),
        ("the test recorded no failures", summary.get("failures") == []),
    ]
    lines: list[str] = []
    for description, passed in checks:
        lines.append(f'{"passed" if passed else "failed"}: summary: {description}')
    return all(passed for _, passed in checks), lines


def artifact_check(directory: Path) -> tuple[bool, list[str]]:
    """Require the artifacts the test needs to diagnose the run."""
    required = (
        EXPECTED_SCREENSHOT,
        "apkrun-dev-launch.log",
        "commands.log",
        "install-image.log",
        "text-query.log",
        "summary.json",
        EXPECTED_RECORDING,
    )
    lines: list[str] = []
    ok = True
    for relative in required:
        path = directory / relative
        if path.is_file() and path.stat().st_size > 0:
            lines.append(f"passed: artifact: {relative} is present")
        else:
            ok = False
            lines.append(f"failed: artifact: {relative} is missing or empty")
    summary_path = directory / "summary.json"
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        recorded_bytes = summary.get("screen_recording_bytes") if isinstance(summary, dict) else None
        movie_path = directory / EXPECTED_RECORDING
        movie_matches = type(recorded_bytes) is int and movie_path.is_file() and movie_path.stat().st_size == recorded_bytes
    except (OSError, json.JSONDecodeError):
        movie_matches = False
    if movie_matches:
        lines.append("passed: artifact: screen-recording.mov matches the byte count written by the test")
    else:
        ok = False
        lines.append("failed: artifact: screen-recording.mov does not match the test's recorded byte count")
    return ok, lines


def test_cases(node: object) -> list[tuple[str, str]]:
    """Return every xcresult test case as (identifier, result)."""
    found: list[tuple[str, str]] = []
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            found.append((str(node.get("nodeIdentifier") or node.get("name") or ""), str(node.get("result") or "none")))
        for value in node.values():
            found.extend(test_cases(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(test_cases(item))
    return found


def xcresult_check(tree: dict) -> tuple[bool, list[str]]:
    """Require an executed, passing G4 test and no failed or skipped test in the run."""
    cases = test_cases(tree.get("testNodes", []))
    g4_cases = [case for case in cases if case[0].startswith(TEST_PREFIX)]
    lines: list[str] = []
    ok = True
    if not g4_cases:
        ok = False
        lines.append("failed: xcresult: no G4NativeWindowTests test was executed")
    for identifier, result in g4_cases:
        passed = result == "Passed"
        ok = ok and passed
        lines.append(
            f'{"passed" if passed else "failed"}: xcresult: {identifier} has result {result}'
        )
    not_passed = [case for case in cases if not case[0].startswith(TEST_PREFIX) and case[1] != "Passed"]
    if not_passed:
        ok = False
        lines.append(f"failed: xcresult: {len(not_passed)} other test(s) in the run did not pass")
    lines.append(f"info: xcresult: {len(cases)} test case(s) in the run, {len(g4_cases)} of G4NativeWindowTests")
    return ok, lines


def read_xcresult(path: Path) -> dict:
    """Read the test tree from an xcresult bundle."""
    completed = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(path), "--compact"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"xcresulttool failed on {path}: {completed.stderr.strip()[-300:]}")
    return json.loads(completed.stdout)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: check-g4-evidence.py ARTIFACTS XCRESULT", file=sys.stderr)
        return 64
    artifacts, xcresult = Path(argv[1]), Path(argv[2])
    checks = [
        summary_check(artifacts / "summary.json"),
        artifact_check(artifacts),
    ]
    try:
        checks.append(xcresult_check(read_xcresult(xcresult)))
    except (RuntimeError, OSError, json.JSONDecodeError) as error:
        checks.append((False, [f"failed: xcresult: {error}"]))
    for _, lines in checks:
        for line in lines:
            print(line)
    return 0 if all(ok for ok, _ in checks) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
