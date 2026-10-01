from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import run_capture


def test_capture_supervisor_enforces_deadline_and_kills_term_ignoring_child() -> None:
    status = run_capture.supervise(
        [
            sys.executable,
            "-c",
            (
                "import signal, time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "time.sleep(30)"
            ),
        ],
        timeout_seconds=0.2,
        cleanup_grace_seconds=0.2,
    )

    assert status["timedOut"] is True
    assert status["childExitCode"] == -9
    assert status["cleanupComplete"] is True


def test_capture_supervisor_preserves_normal_exit_status() -> None:
    status = run_capture.supervise(
        [sys.executable, "-c", "raise SystemExit(7)"],
        timeout_seconds=5,
        cleanup_grace_seconds=1,
    )

    assert status["timedOut"] is False
    assert status["childExitCode"] == 7
    assert status["cleanupComplete"] is True


def test_capture_supervisor_stops_descendants_after_command_exit(
    tmp_path: Path,
) -> None:
    child_pid_path = tmp_path / "child.pid"
    status = run_capture.supervise(
        [
            sys.executable,
            "-c",
            (
                "import pathlib, subprocess, sys; "
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import signal, time; signal.signal(signal.SIGTERM, "
                "signal.SIG_IGN); time.sleep(30)'], "
                "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
                "stderr=subprocess.DEVNULL); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
            ),
            str(child_pid_path),
        ],
        timeout_seconds=5,
        cleanup_grace_seconds=1,
    )

    assert status["childExitCode"] == 0
    assert status["cleanupComplete"] is True
    assert child_pid_path.is_file()


def test_capture_cli_forwards_signal_and_records_cleanup(tmp_path: Path) -> None:
    status_path = tmp_path / "capture-status.json"
    process = subprocess.Popen(
        [
            sys.executable,
            str(Path(run_capture.__file__)),
            "--timeout-seconds",
            "30",
            "--cleanup-grace-seconds",
            "2",
            "--status",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(30)",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.1)
        os.kill(process.pid, signal.SIGTERM)
        assert process.wait(timeout=5) == 128 + signal.SIGTERM
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["signal"] == signal.SIGTERM
    assert status["cleanupComplete"] is True
