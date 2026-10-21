#!/usr/bin/env python3
"""Check G4's evidence summary, required artifacts, and xcresult verdict without starting a VM."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_g4_evidence", ROOT / "scripts/tools/check-g4-evidence.py")
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)

G4 = "G4NativeWindowTests/testHelloTextLaunchesAndAcceptsHostInputInANativeWindow()"


def case(identifier: str, result: str) -> dict:
    return {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result}


def tree(*cases: dict) -> dict:
    return {"testNodes": [{"nodeType": "Test Plan", "children": list(cases)}]}


def passing_summary() -> dict:
    return {
        "gate": "G4",
        "result": "passed",
        "clicks_observed": 100,
        "click_sequence_valid": True,
        "typed_text": "Hello, APKRun 123!",
        "screen_after_escape": "main",
        "adb_shell_count_before_events": 37,
        "adb_shell_count_after_events": 37,
        "apkrun_exit_code": 130,
        "apkrun_termination_reason": "exit",
        "window_capture": "screenshots/hellotext.png",
        "screen_recording": "screen-recording.mov",
        "screen_recording_bytes": 8,
        "screen_recording_finished_successfully": True,
        "screen_recording_failure": None,
        "screen_recording_video_track_count": 1,
        "screen_recording_duration_ms": 10_000,
        "screen_recording_frame_count": 300,
        "host_input_event_count": 216,
        "recorded_host_input_event_count": 216,
        "screen_recording_started_before_first_host_event": True,
        "screen_recording_first_frame_offset_ms": 50,
        "first_host_input_offset_ms": 1_100,
        "last_host_input_offset_ms": 8_400,
        "screen_recording_last_frame_offset_ms": 9_000,
        "screen_recording_frames_bracket_host_input": True,
        "failures": [],
    }


class SummaryTests(unittest.TestCase):
    def test_all_g4_conditions_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.json"
            path.write_text(json.dumps(passing_summary()), encoding="utf-8")
            self.assertTrue(checker.summary_check(path)[0])

    def test_cli_must_exit_normally_after_test_cleanup(self) -> None:
        for status, reason in ((9, "uncaughtSignal"), (0, "exit"), (130, "uncaughtSignal")):
            with self.subTest(status=status, reason=reason), tempfile.TemporaryDirectory() as directory:
                summary = passing_summary()
                summary["apkrun_exit_code"] = status
                summary["apkrun_termination_reason"] = reason
                path = Path(directory) / "summary.json"
                path.write_text(json.dumps(summary), encoding="utf-8")
                self.assertFalse(checker.summary_check(path)[0])

    def test_each_required_condition_is_checked(self) -> None:
        for key, value in (
            ("clicks_observed", 99),
            ("click_sequence_valid", False),
            ("typed_text", "Hello, APKRun 12!"),
            ("screen_after_escape", "details"),
            ("adb_shell_count_after_events", 38),
            ("apkrun_exit_code", None),
            ("apkrun_exit_code", 0),
            ("apkrun_exit_code", 1),
            ("apkrun_exit_code", 9),
            ("apkrun_termination_reason", "uncaughtSignal"),
            ("apkrun_termination_reason", None),
            ("window_capture", None),
            ("screen_recording", None),
            ("screen_recording_finished_successfully", False),
            ("screen_recording_failure", "recording failed"),
            ("screen_recording_video_track_count", 0),
            ("screen_recording_duration_ms", 0),
            ("screen_recording_frame_count", 0),
            ("screen_recording_bytes", 0),
            ("host_input_event_count", 0),
            ("recorded_host_input_event_count", 215),
            ("screen_recording_started_before_first_host_event", False),
            ("screen_recording_first_frame_offset_ms", 1_101),
            ("first_host_input_offset_ms", -1),
            ("last_host_input_offset_ms", 60_001),
            ("screen_recording_last_frame_offset_ms", 8_399),
            ("screen_recording_frames_bracket_host_input", False),
            ("failures", ["step failed"]),
        ):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                summary = passing_summary()
                summary[key] = value
                path = Path(directory) / "summary.json"
                path.write_text(json.dumps(summary), encoding="utf-8")
                self.assertFalse(checker.summary_check(path)[0])

    def test_a_missing_or_invalid_summary_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.json"
            self.assertFalse(checker.summary_check(path)[0])
            path.write_text("{not json", encoding="utf-8")
            self.assertFalse(checker.summary_check(path)[0])


class ArtifactTests(unittest.TestCase):
    def test_required_artifacts_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (
                checker.EXPECTED_SCREENSHOT,
                "apkrun-dev-launch.log",
                "commands.log",
                "install-image.log",
                "text-query.log",
                "summary.json",
                checker.EXPECTED_RECORDING,
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                if relative == "summary.json":
                    path.write_text(json.dumps(passing_summary()), encoding="utf-8")
                else:
                    path.write_bytes(b"evidence")
            self.assertTrue(checker.artifact_check(root)[0])

    def test_a_missing_artifact_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(checker.artifact_check(Path(directory))[0])

    def test_movie_size_must_match_recorded_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (
                checker.EXPECTED_SCREENSHOT,
                "apkrun-dev-launch.log",
                "commands.log",
                "install-image.log",
                "text-query.log",
                "summary.json",
                checker.EXPECTED_RECORDING,
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                if relative == "summary.json":
                    path.write_text(json.dumps(passing_summary()), encoding="utf-8")
                else:
                    path.write_bytes(b"evidence")
            self.assertTrue(checker.artifact_check(root)[0])
            (root / checker.EXPECTED_RECORDING).write_bytes(b"larger than expected")
            self.assertFalse(checker.artifact_check(root)[0])


class XCResultTests(unittest.TestCase):
    def test_the_passed_g4_test_passes(self) -> None:
        self.assertTrue(checker.xcresult_check(tree(case(G4, "Passed")))[0])

    def test_a_skipped_or_failed_g4_test_fails(self) -> None:
        for result in ("Skipped", "Failed"):
            with self.subTest(result=result):
                self.assertFalse(checker.xcresult_check(tree(case(G4, result)))[0])

    def test_a_run_without_the_g4_test_fails(self) -> None:
        self.assertFalse(checker.xcresult_check(tree())[0])
        self.assertFalse(checker.xcresult_check(tree(case("LinuxGuestTests/testBoot()", "Passed")))[0])

    def test_another_failed_test_in_the_run_fails(self) -> None:
        other = case("G4HelperTests/testA()", "Failed")
        self.assertFalse(checker.xcresult_check(tree(case(G4, "Passed"), other))[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
