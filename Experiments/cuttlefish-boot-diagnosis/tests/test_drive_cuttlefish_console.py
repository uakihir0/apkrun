from __future__ import annotations

import json
import os
import pty
import runpy
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

HELPER = Path(__file__).parents[1] / "drive_cuttlefish_console.py"
CONSOLE_MODULE = runpy.run_path(str(HELPER))
pytestmark = pytest.mark.skipif(
    sys.platform != "linux",
    reason="the Cuttlefish reference console helper runs on Linux",
)


def _private_home(tmp_path: Path) -> Path:
    home = tmp_path / "cvd-home"
    runtime = home / "cuttlefish_runtime"
    runtime.mkdir(parents=True, mode=0o700)
    (runtime / "console").touch(mode=0o600)
    home.chmod(0o700)
    runtime.chmod(0o700)
    return home


def _screen_stub(tmp_path: Path, body: str) -> Path:
    program = tmp_path / "fake-screen"
    program.write_text(
        f"#!/usr/bin/env python3\nimport os\nimport time\n{body}\n",
        encoding="utf-8",
    )
    program.chmod(0o700)
    return program


def _run_helper(
    home: Path,
    result: Path,
    screen: Path,
    *,
    timeout: int = 2,
    handoff_timeout: int = 1,
    output_limit: int = 65_536,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            str(timeout),
            "--handoff-timeout-seconds",
            str(handoff_timeout),
            "--max-output-bytes",
            str(output_limit),
            "--screen-program",
            str(screen),
        ],
        capture_output=True,
        text=True,
        timeout=timeout + 5,
        check=False,
    )


def test_console_helper_sends_boot_only_at_prompt_and_observes_handoff(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot\\n=> ')\n"
        "command = os.read(0, 32)\n"
        "if b'boot\\r' not in command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["screenStarted"] is True
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["cleanupComplete"] is True
    assert summary["exitCode"] == 0
    assert stat.S_IMODE(result.stat().st_mode) == 0o600


def test_console_helper_ignores_kernel_marker_received_before_boot(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'Starting kernel ...\\nU-Boot\\n=> ')\n"
        "command = os.read(0, 32)\n"
        "if b'boot\\r' not in command:\n"
        "    raise SystemExit(19)\n"
        "time.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=3, handoff_timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is False
    assert summary["handoffTimedOut"] is True


def test_console_summary_is_not_published_when_atomic_link_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = tmp_path / "bootloader-console-summary.json"

    def fail_link(*_args: object, **_kwargs: object) -> None:
        raise OSError("injected link failure")

    monkeypatch.setattr(os, "link", fail_link)

    with pytest.raises(OSError, match="injected link failure"):
        CONSOLE_MODULE["_write_result"](
            result,
            {"schemaVersion": 1, "exitCode": 0},
        )

    assert not result.exists()
    assert not list(tmp_path.glob(".bootloader-console-summary.json.*"))


def test_console_helper_times_out_without_sending_boot_when_prompt_is_absent(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'no bootloader prompt\\n')\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["kernelHandoffObserved"] is False
    assert summary["timedOut"] is True
    assert summary["cleanupComplete"] is True
    assert summary["screenExitCode"] == -15


def test_console_helper_bounds_output_and_never_sends_boot_without_prompt(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'x' * 4096)\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, output_limit=64)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["outputBytesObserved"] == 64
    assert summary["outputTruncated"] is True
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.parametrize("bad_path", ("home", "result"))
def test_console_helper_rejects_symlinked_private_paths(
    tmp_path: Path,
    bad_path: str,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")
    if bad_path == "home":
        target = tmp_path / "home-link"
        target.symlink_to(home, target_is_directory=True)
        home = target
    else:
        existing = tmp_path / "existing-summary"
        existing.write_text("{}", encoding="utf-8")
        result.symlink_to(existing)

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    if bad_path == "home":
        assert not result.exists()
    else:
        assert result.is_symlink()


def test_console_helper_accepts_runtime_symlink_within_home(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    runtime = home / "cuttlefish_runtime"
    private_runtime = home / "private-runtime"
    runtime.rename(private_runtime)
    runtime.symlink_to(private_runtime, target_is_directory=True)
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot\\n=> ')\n"
        "command = os.read(0, 32)\n"
        "if b'boot\\r' not in command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["exitCode"] == 0


def test_console_helper_rejects_runtime_symlink_outside_home(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")
    runtime = home / "cuttlefish_runtime"
    (runtime / "console").unlink()
    runtime.rmdir()
    outside_runtime = tmp_path / "outside-runtime"
    outside_runtime.mkdir()
    runtime.symlink_to(outside_runtime, target_is_directory=True)

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    assert (
        "private Cuttlefish runtime directory symlink resolves outside its HOME"
        in completed.stderr
    )
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is False
    assert summary["exitCode"] == 1


def test_console_helper_follows_owned_devpts_console_symlink(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    master_fd, slave_fd = pty.openpty()
    console = home / "cuttlefish_runtime/console"
    console.unlink()
    console.symlink_to(os.ttyname(slave_fd))
    screen = _screen_stub(
        tmp_path,
        "import stat\n"
        "import sys\n"
        "if not stat.S_ISCHR(os.stat(sys.argv[-1]).st_mode):\n"
        "    raise SystemExit(20)\n"
        "os.write(1, b'U-Boot\\n=> ')\n"
        "command = os.read(0, 32)\n"
        "if b'boot\\r' not in command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    try:
        completed = _run_helper(home, result, screen, timeout=1)
    finally:
        os.close(master_fd)
        os.close(slave_fd)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["exitCode"] == 0


def test_console_helper_rejects_group_accessible_home(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    home.chmod(0o750)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    assert not result.exists()


def test_console_helper_handles_term_and_records_cleanup(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    started = home / "screen-started"
    screen = _screen_stub(
        tmp_path,
        f"Path = __import__('pathlib').Path({str(started)!r})\n"
        "Path.touch()\n"
        "time.sleep(10)",
    )
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            "30",
            "--screen-program",
            str(screen),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 5
    while not started.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert started.exists(), "fake Screen did not start"

    process.terminate()
    _, stderr = process.communicate(timeout=5)

    assert process.returncode == 143, stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["signal"] == 15
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


def test_console_helper_does_not_send_boot_after_cancellation_while_prompt_is_pending(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "import signal\n"
        "os.kill(os.getppid(), signal.SIGTERM)\n"
        "time.sleep(0.05)\n"
        "os.write(1, b'U-Boot\\n=> ')\n"
        "time.sleep(10)",
    )
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            "30",
            "--screen-program",
            str(screen),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    _, stderr = process.communicate(timeout=5)

    assert process.returncode == 143, stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["signal"] == 15
    assert isinstance(summary["promptObserved"], bool)
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.skipif(
    sys.platform != "linux" or not hasattr(os, "waitid"),
    reason="group cleanup must keep the Screen leader unreaped until verification",
)
def test_console_helper_stops_screen_group_descendants(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    term_marker = home / "descendant-term"
    ready_marker = home / "descendant-ready"
    pid_path = home / "descendant.pid"
    child_body = (
        "import signal,time\n"
        "from pathlib import Path\n"
        f"marker = Path({str(term_marker)!r})\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "def stop(_signum, _frame):\n"
        "    marker.write_text('term', encoding='ascii')\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
        "ready.write_text('ready', encoding='ascii')\n"
        "time.sleep(30)\n"
    )
    screen = _screen_stub(
        tmp_path,
        "import subprocess\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([__import__('sys').executable, '-c', "
        f"{child_body!r}])\n"
        f"Path({str(pid_path)!r}).write_text(str(child.pid), encoding='ascii')\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "deadline = time.monotonic() + 2\n"
        "while not ready.exists() and time.monotonic() < deadline:\n"
        "    time.sleep(0.01)\n"
        "if not ready.exists():\n"
        "    raise SystemExit('descendant did not become ready')\n"
        "raise SystemExit(0)",
    )

    completed = _run_helper(home, result, screen, timeout=2)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["screenExitCode"] == 0
    assert summary["cleanupComplete"] is True
    assert term_marker.read_text(encoding="ascii") == "term"


@pytest.mark.skipif(sys.platform != "linux", reason="Linux process groups are required")
def test_screen_group_cleanup_falls_back_without_waitid(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    term_marker = home / "descendant-term"
    ready_marker = home / "descendant-ready"
    child_body = (
        "import signal,time\n"
        "from pathlib import Path\n"
        f"marker = Path({str(term_marker)!r})\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "def stop(_signum, _frame):\n"
        "    marker.write_text('term', encoding='ascii')\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
        "ready.write_text('ready', encoding='ascii')\n"
        "time.sleep(30)\n"
    )
    screen = _screen_stub(
        tmp_path,
        "import subprocess\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([__import__('sys').executable, '-c', "
        f"{child_body!r}])\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "deadline = time.monotonic() + 2\n"
        "while not ready.exists() and time.monotonic() < deadline:\n"
        "    time.sleep(0.01)\n"
        "if not ready.exists():\n"
        "    raise SystemExit('descendant did not become ready')\n"
        "raise SystemExit(0)",
    )
    console_os = SimpleNamespace(**{**vars(os), "waitid": None})
    CONSOLE_MODULE["os"] = console_os
    try:
        pid, master_fd = CONSOLE_MODULE["_start_screen"](
            screen,
            home / "cuttlefish_runtime/console",
            home,
        )
        try:
            deadline = time.monotonic() + 2
            while not ready_marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert ready_marker.exists()
            exit_code, cleanup_complete, cleanup_failure, _ = CONSOLE_MODULE[
                "_stop_screen"
            ](pid, master_fd)
        finally:
            os.close(master_fd)
    finally:
        CONSOLE_MODULE["os"] = os

    assert exit_code in (0, -signal.SIGTERM, -signal.SIGKILL)
    assert cleanup_complete is True, cleanup_failure
    assert term_marker.read_text(encoding="ascii") == "term"
