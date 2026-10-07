"""Bounded subprocess handling for guest-side reference capture commands."""

from __future__ import annotations

import os
import resource
import subprocess
import sys
import time
from pathlib import Path

TOOLS_ROOT = Path(__file__).parents[1]
HELPER = TOOLS_ROOT / "reference/capture_guest_command.py"


def _run_helper(
    tmp_path: Path,
    command: list[str],
    *,
    timeout_seconds: float = 2,
    max_bytes: int = 16,
) -> tuple[subprocess.CompletedProcess[str], Path]:
    output = tmp_path / "captured.txt"
    result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--timeout-seconds",
            str(timeout_seconds),
            "--max-bytes",
            str(max_bytes),
            "--output",
            str(output),
            "--",
            *command,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    return result, output


def _fake_adb(tmp_path: Path, script: str) -> Path:
    executable = tmp_path / "fake-adb"
    executable.write_text(f"#!/bin/sh\n{script}\n", encoding="utf-8")
    executable.chmod(0o755)
    return executable


def test_guest_command_atomically_captures_output_at_the_limit(tmp_path: Path) -> None:
    fake_adb = _fake_adb(tmp_path, "printf '1234567890123456'")

    result, output = _run_helper(tmp_path, [str(fake_adb)])

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "16"
    assert output.read_bytes() == b"1234567890123456"
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_discards_output_that_exceeds_the_limit(tmp_path: Path) -> None:
    fake_adb = _fake_adb(tmp_path, "printf '12345678901234567'")

    result, output = _run_helper(tmp_path, [str(fake_adb)], max_bytes=16)

    assert result.returncode == 125
    assert "output exceeded 16 bytes" in result.stderr
    assert not output.exists()
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_deadline_stops_a_hung_fake_adb(tmp_path: Path) -> None:
    fake_adb = _fake_adb(
        tmp_path,
        "trap '' TERM\nwhile :; do sleep 1; done",
    )
    started_at = time.monotonic()

    result, output = _run_helper(
        tmp_path,
        [str(fake_adb)],
        timeout_seconds=0.2,
        max_bytes=16,
    )

    assert time.monotonic() - started_at < 3
    assert result.returncode == 124
    assert "exceeded its deadline" in result.stderr
    assert not output.exists()
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_waits_when_child_closes_stdout_before_deadline(
    tmp_path: Path,
) -> None:
    fake_adb = _fake_adb(tmp_path, "exec 1>&-\nexec sleep 5")
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started_at = time.monotonic()

    result, output = _run_helper(
        tmp_path,
        [str(fake_adb)],
        timeout_seconds=0.4,
        max_bytes=16,
    )

    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    helper_cpu_seconds = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
    assert time.monotonic() - started_at < 3
    assert helper_cpu_seconds < 0.25
    assert result.returncode == 124
    assert not output.exists()
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_kills_descendant_after_parent_exits_normally(
    tmp_path: Path,
) -> None:
    grandchild_pid_file = tmp_path / "grandchild.pid"
    fake_adb = tmp_path / "fake-adb"
    descendant_code = (
        "import os, signal, time\n"
        "from pathlib import Path\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        f"Path({str(grandchild_pid_file)!r}).write_text(str(os.getpid()))\n"
        "time.sleep(30)\n"
    )
    fake_adb.write_text(
        "#!/usr/bin/env python3\n"
        "import os, subprocess, sys, time\n"
        "from pathlib import Path\n"
        f"child = subprocess.Popen([sys.executable, '-c', {descendant_code!r}],\n"
        "    stdout=subprocess.DEVNULL,\n"
        "    stderr=subprocess.DEVNULL,\n"
        ")\n"
        "pid_deadline = time.monotonic() + 3\n"
        f"while not Path({str(grandchild_pid_file)!r}).exists():\n"
        "    if time.monotonic() >= pid_deadline:\n"
        "        raise SystemExit('grandchild did not start')\n"
        "    time.sleep(0.01)\n"
        "sys.stdout.write('parent output')\n"
        "sys.stdout.flush()\n"
        "sys.stdout.close()\n"
        "os._exit(0)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o755)

    result, output = _run_helper(tmp_path, [str(fake_adb)])

    assert result.returncode == 0, result.stderr
    assert output.read_text(encoding="utf-8") == "parent output"
    grandchild_pid = int(grandchild_pid_file.read_text(encoding="utf-8"))
    process_deadline = time.monotonic() + 5
    while time.monotonic() < process_deadline:
        try:
            os.kill(grandchild_pid, 0)
        except ProcessLookupError:
            break
        process_state = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(grandchild_pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if process_state.startswith(("Z", "X")):
            break
        time.sleep(0.02)
    else:
        raise AssertionError("the guest command left a live descendant behind")


def test_guest_command_removes_temporary_output_if_group_cleanup_fails(
    tmp_path: Path,
) -> None:
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    fake_ps.chmod(0o755)
    fake_adb = _fake_adb(tmp_path, "printf partial\nexec sleep 5")
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    output = tmp_path / "captured.txt"
    result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--timeout-seconds",
            "0.2",
            "--max-bytes",
            "16",
            "--output",
            str(output),
            "--",
            str(fake_adb),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
        env=environment,
    )

    assert result.returncode == 2
    assert "could not inspect the Cuttlefish process group" in result.stderr
    assert not output.exists()
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_nonzero_exit_does_not_publish_partial_output(tmp_path: Path) -> None:
    fake_adb = _fake_adb(tmp_path, "printf partial\nexit 1")

    result, output = _run_helper(tmp_path, [str(fake_adb)])

    assert result.returncode == 1
    assert not output.exists()
    assert list(tmp_path.glob(".captured.txt.*")) == []


def test_guest_command_requires_a_fresh_output_path(tmp_path: Path) -> None:
    fake_adb = _fake_adb(tmp_path, "printf replacement")
    output = tmp_path / "captured.txt"
    output.write_text("preserve", encoding="utf-8")

    result, actual_output = _run_helper(tmp_path, [str(fake_adb)])

    assert actual_output == output
    assert result.returncode == 2
    assert output.read_text(encoding="utf-8") == "preserve"
    assert list(tmp_path.glob(".captured.txt.*")) == []
