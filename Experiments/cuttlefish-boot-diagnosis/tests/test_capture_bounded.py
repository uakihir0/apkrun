from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import capture_bounded


def test_capture_stops_after_writing_the_byte_limit(tmp_path: Path) -> None:
    output = tmp_path / "bounded.raw"
    status_path = tmp_path / "bounded.json"
    exit_code, status = capture_bounded.capture(
        [
            sys.executable,
            "-c",
            "import sys; sys.stdout.buffer.write(b'x' * 1000000)",
        ],
        output,
        status_path,
        4096,
    )

    assert exit_code == 0
    assert output.stat().st_size == 4096
    assert status["bytesWritten"] == 4096
    assert status["truncated"] is True
    assert status["cleanupComplete"] is True
    assert json.loads(status_path.read_text(encoding="utf-8"))["truncated"] is True


def test_capture_can_fail_closed_when_control_output_is_truncated(
    tmp_path: Path,
) -> None:
    output = tmp_path / "control.raw"
    status_path = tmp_path / "control.json"
    exit_code, status = capture_bounded.capture(
        [sys.executable, "-c", "print('x' * 128)"],
        output,
        status_path,
        8,
        fail_on_truncate=True,
    )

    assert exit_code == 75
    assert output.stat().st_size == 8
    assert status["truncated"] is True


def test_capture_can_merge_stderr_with_stdout_under_the_same_byte_limit(
    tmp_path: Path,
) -> None:
    output = tmp_path / "combined.txt"
    status_path = tmp_path / "combined.json"
    exit_code, status = capture_bounded.capture(
        [
            sys.executable,
            "-c",
            (
                "import sys; "
                "print('version: 1.57.0', file=sys.stderr); "
                "print('{\"groups\": []}')"
            ),
        ],
        output,
        status_path,
        4096,
        merge_stderr=True,
    )

    assert exit_code == 0
    assert "version: 1.57.0" in output.read_text(encoding="utf-8")
    assert '{"groups": []}' in output.read_text(encoding="utf-8")
    assert status["cleanupComplete"] is True


def test_capture_preserves_a_small_successful_stream(tmp_path: Path) -> None:
    output = tmp_path / "bounded.raw"
    status_path = tmp_path / "bounded.json"
    exit_code, status = capture_bounded.capture(
        [sys.executable, "-c", "print('safe output')"],
        output,
        status_path,
        4096,
    )

    assert exit_code == 0
    assert output.read_text(encoding="utf-8") == "safe output\n"
    assert status["truncated"] is False


def test_capture_returns_child_failure(tmp_path: Path) -> None:
    output = tmp_path / "bounded.raw"
    status_path = tmp_path / "bounded.json"
    exit_code, status = capture_bounded.capture(
        [sys.executable, "-c", "import sys; print('partial'); sys.exit(7)"],
        output,
        status_path,
        4096,
    )

    assert exit_code == 7
    assert status["childExitCode"] == 7
    assert output.read_text(encoding="utf-8") == "partial\n"


def test_capture_times_out_and_kills_term_ignoring_child(tmp_path: Path) -> None:
    output = tmp_path / "bounded.raw"
    status_path = tmp_path / "bounded.json"
    exit_code, status = capture_bounded.capture(
        [
            sys.executable,
            "-c",
            (
                "import signal, time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "time.sleep(30)"
            ),
        ],
        output,
        status_path,
        4096,
        timeout_seconds=0.2,
    )

    assert exit_code == 124
    assert status["timedOut"] is True
    assert status["childExitCode"] == -9
    assert status["cleanupComplete"] is True
    assert output.stat().st_size == 0


def test_capture_times_out_when_child_closes_stdout_but_keeps_running(
    tmp_path: Path,
) -> None:
    output = tmp_path / "bounded.raw"
    status_path = tmp_path / "bounded.json"
    exit_code, status = capture_bounded.capture(
        [
            sys.executable,
            "-c",
            "import os, time; os.close(1); time.sleep(30)",
        ],
        output,
        status_path,
        4096,
        timeout_seconds=0.2,
    )

    assert exit_code == 124
    assert status["timedOut"] is True
    assert output.stat().st_size == 0


def test_stdin_mode_caps_and_reports_console_output(tmp_path: Path) -> None:
    output = tmp_path / "console.log"
    status_path = tmp_path / "console.json"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(capture_bounded.__file__)),
            "--stdin",
            "--max-bytes",
            "128",
            "--output",
            str(output),
            "--status",
            str(status_path),
            "--append",
        ],
        input=b"x" * 4096,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 75
    assert output.stat().st_size == 128
    assert json.loads(status_path.read_text(encoding="utf-8"))["truncated"] is True


def test_stdin_mode_exits_on_signal_and_closes_the_producer_pipe(
    tmp_path: Path,
) -> None:
    output = tmp_path / "interrupted-console.log"
    status_path = tmp_path / "interrupted-console.json"
    producer = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import sys\n"
                "import time\n"
                "chunk = b'x' * 1024\n"
                "while True:\n"
                "    sys.stdout.buffer.write(chunk)\n"
                "    sys.stdout.flush()\n"
                "    time.sleep(0.02)\n"
            ),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert producer.stdout is not None
    helper = subprocess.Popen(
        [
            sys.executable,
            str(Path(capture_bounded.__file__)),
            "--stdin",
            "--max-bytes",
            str(10 * 1024 * 1024),
            "--output",
            str(output),
            "--status",
            str(status_path),
        ],
        stdin=producer.stdout,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    producer.stdout.close()
    try:
        time.sleep(0.1)
        os.kill(helper.pid, signal.SIGTERM)
        assert helper.wait(timeout=3) == 128 + signal.SIGTERM
    finally:
        if helper.poll() is None:
            helper.kill()
            helper.wait()
        if producer.poll() is None:
            producer.terminate()
        producer.wait(timeout=3)

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["signal"] == signal.SIGTERM


def test_capture_refuses_existing_or_symlink_output(tmp_path: Path) -> None:
    existing = tmp_path / "existing.raw"
    existing.write_text("keep", encoding="utf-8")
    with pytest.raises(ValueError, match="non-symlink"):
        capture_bounded.capture(
            [sys.executable, "-c", "pass"],
            existing,
            tmp_path / "existing.json",
            32,
        )

    target = tmp_path / "target.raw"
    target.write_text("keep", encoding="utf-8")
    link = tmp_path / "linked.raw"
    link.symlink_to(target)
    with pytest.raises(ValueError, match="symlink"):
        capture_bounded.capture(
            [sys.executable, "-c", "pass"],
            link,
            tmp_path / "linked.json",
            32,
        )
