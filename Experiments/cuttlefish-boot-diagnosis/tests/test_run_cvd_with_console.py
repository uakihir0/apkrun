from __future__ import annotations

import os
import runpy
import signal
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import capture_bounded

RUNNER = Path(__file__).parents[1] / "run_cvd_with_console.py"


def _runner_command(
    home: Path,
    stage: Path,
    summary_root: Path,
    start_helper: Path,
    console_helper: Path,
    *,
    memory_mb: int = 4096,
    timeout_seconds: int = 8,
) -> list[str]:
    return [
        sys.executable,
        str(RUNNER),
        "--home",
        str(home),
        "--stage",
        str(stage),
        "--summary-root",
        str(summary_root),
        "--cvd-start-helper",
        str(start_helper),
        "--console-helper",
        str(console_helper),
        "--console-summary",
        str(summary_root / "bootloader-console-summary.json"),
        "--group-name",
        "apkrun_test",
        "--gpu-mode",
        "none",
        "--console-enabled",
        "true",
        "--memory-mb",
        str(memory_mb),
        "--timeout-seconds",
        str(timeout_seconds),
        "--handoff-timeout-seconds",
        "2",
    ]


def _write_fake_cvd_start_helper(tools: Path) -> Path:
    start_helper = tools / "capture_cvd_start.py"
    start_helper.write_text(
        """from __future__ import annotations
import os
import signal
import subprocess
import sys
import time

running = None
requested_signal = None

def _terminate_child(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=1)

def stop(signum, _frame):
    global requested_signal
    requested_signal = signum

def main():
    global running, requested_signal
    signal.signal(signal.SIGTERM, stop)
    command = sys.argv[sys.argv.index("--") + 1:]
    running = subprocess.Popen(command, start_new_session=True)
    while running.poll() is None:
        if requested_signal is not None:
            _terminate_child(running)
            raise SystemExit(128 + requested_signal)
        time.sleep(0.01)
    raise SystemExit(running.returncode)

if __name__ == "__main__":
    main()
""",
        encoding="utf-8",
    )
    return start_helper


@pytest.mark.skipif(
    sys.platform != "linux", reason="Cuttlefish supervision runs on Linux"
)
@pytest.mark.parametrize(
    ("failure_side", "expected_exit_code"),
    (("console", 9), ("cvd", 17)),
)
def test_cvd_and_console_failures_stop_the_peer_process(
    tmp_path: Path,
    failure_side: str,
    expected_exit_code: int,
) -> None:
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    stage = tmp_path / "stage"
    stage.mkdir(mode=0o700)
    tools = tmp_path / "tools"
    tools.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(mode=0o700)
    cvd_started = tmp_path / "cvd-started"
    cvd_stopped = tmp_path / "cvd-stopped"
    console_ready = tmp_path / "console-ready"
    console_stopped = tmp_path / "console-stopped"

    start_helper = tools / "capture_cvd_start.py"
    start_helper.write_text(
        """from __future__ import annotations
import os
import signal
import subprocess
import sys
import time

running = None
requested_signal = None

def _terminate_child(process, *, term_grace_seconds=0.5):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=term_grace_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=1)

def stop(signum, _frame):
    global requested_signal
    requested_signal = signum

def main():
    global running, requested_signal
    signal.signal(signal.SIGTERM, stop)
    command = sys.argv[sys.argv.index("--") + 1:]
    running = subprocess.Popen(command, start_new_session=True)
    while running.poll() is None:
        if requested_signal is not None:
            _terminate_child(running)
            raise SystemExit(128 + requested_signal)
        time.sleep(0.01)
    raise SystemExit(running.returncode)

if __name__ == "__main__":
    main()
""",
        encoding="utf-8",
    )
    (fake_bin / "cvd").write_text(
        """#!/usr/bin/env python3
import os
import signal
import sys
import time
from pathlib import Path

def stop(_signum, _frame):
    Path(os.environ["APKRUN_TEST_CVD_STOPPED"]).write_text("stopped")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
Path(os.environ["APKRUN_TEST_CVD_STARTED"]).write_text("started")
if os.environ["APKRUN_TEST_FAILURE_SIDE"] == "cvd":
    ready = Path(os.environ["APKRUN_TEST_CONSOLE_READY"])
    deadline = time.monotonic() + 3
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not ready.exists():
        raise SystemExit("console helper did not become ready")
    raise SystemExit(17)

while True:
    time.sleep(0.05)
""",
        encoding="utf-8",
    )
    (fake_bin / "cvd").chmod(0o700)
    console_helper = tools / "drive_cuttlefish_console.py"
    console_helper.write_text(
        """import os
import signal
import sys
import time
from pathlib import Path

started = Path(os.environ["APKRUN_TEST_CVD_STARTED"])
deadline = time.monotonic() + 3
while not started.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if not started.exists():
    raise SystemExit("Cuttlefish did not start")

def stop(_signum, _frame):
    Path(os.environ["APKRUN_TEST_CONSOLE_STOPPED"]).write_text("stopped")
    raise SystemExit(143)

signal.signal(signal.SIGTERM, stop)
Path(os.environ["APKRUN_TEST_CONSOLE_READY"]).write_text("ready")
if os.environ["APKRUN_TEST_FAILURE_SIDE"] == "console":
    raise SystemExit(9)
while True:
    time.sleep(0.05)
""",
        encoding="utf-8",
    )

    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "APKRUN_TEST_CVD_STARTED": str(cvd_started),
        "APKRUN_TEST_CVD_STOPPED": str(cvd_stopped),
        "APKRUN_TEST_CONSOLE_READY": str(console_ready),
        "APKRUN_TEST_CONSOLE_STOPPED": str(console_stopped),
        "APKRUN_TEST_FAILURE_SIDE": failure_side,
    }
    result = subprocess.run(
        [
            sys.executable,
            str(RUNNER),
            "--home",
            str(home),
            "--stage",
            str(stage),
            "--summary-root",
            str(tmp_path),
            "--cvd-start-helper",
            str(start_helper),
            "--console-helper",
            str(console_helper),
            "--console-summary",
            str(tmp_path / "bootloader-console-summary.json"),
            "--group-name",
            "apkrun_test",
            "--gpu-mode",
            "none",
            "--console-enabled",
            "true",
            "--memory-mb",
            "4096",
            "--timeout-seconds",
            "8",
            "--handoff-timeout-seconds",
            "2",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=12,
        env=environment,
    )

    assert result.returncode == expected_exit_code, result.stderr
    assert cvd_started.exists()
    if failure_side == "console":
        assert cvd_stopped.read_text(encoding="ascii") == "stopped"
    else:
        assert console_stopped.read_text(encoding="ascii") == "stopped"


@pytest.mark.skipif(
    sys.platform != "linux", reason="Cuttlefish supervision runs on Linux"
)
@pytest.mark.parametrize("blocked_sigterm_at_exec", (False, True))
def test_cancellation_stops_both_helpers_before_waiting_for_either(
    tmp_path: Path,
    blocked_sigterm_at_exec: bool,
) -> None:
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    stage = tmp_path / "stage"
    stage.mkdir(mode=0o700)
    tools = tmp_path / "tools"
    tools.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(mode=0o700)
    cvd_started = tmp_path / "cvd-started"
    cvd_stopped = tmp_path / "cvd-stopped"
    console_term_started = tmp_path / "console-term-started"
    console_term_finished = tmp_path / "console-term-finished"

    start_helper = _write_fake_cvd_start_helper(tools)
    (fake_bin / "cvd").write_text(
        """#!/usr/bin/env python3
import os
import signal
import time
from pathlib import Path

def stop(_signum, _frame):
    Path(os.environ["APKRUN_TEST_CVD_STOPPED"]).write_text(
        str(time.monotonic_ns()), encoding="ascii"
    )
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
Path(os.environ["APKRUN_TEST_CVD_STARTED"]).write_text(
    "started", encoding="ascii"
)
while True:
    time.sleep(0.05)
""",
        encoding="utf-8",
    )
    (fake_bin / "cvd").chmod(0o700)
    console_helper = tools / "drive_cuttlefish_console.py"
    console_helper.write_text(
        """import os
import signal
import time
from pathlib import Path

cvd_started = Path(os.environ["APKRUN_TEST_CVD_STARTED"])
deadline = time.monotonic() + 3
while not cvd_started.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if not cvd_started.exists():
    raise SystemExit("Cuttlefish did not start")

def stop(_signum, _frame):
    Path(os.environ["APKRUN_TEST_CONSOLE_TERM_STARTED"]).write_text(
        str(time.monotonic_ns()), encoding="ascii"
    )
    time.sleep(0.5)
    Path(os.environ["APKRUN_TEST_CONSOLE_TERM_FINISHED"]).write_text(
        str(time.monotonic_ns()), encoding="ascii"
    )
    raise SystemExit(143)

signal.signal(signal.SIGTERM, stop)
os.kill(os.getppid(), signal.SIGTERM)
while True:
    time.sleep(0.05)
""",
        encoding="utf-8",
    )

    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "APKRUN_TEST_CVD_STARTED": str(cvd_started),
        "APKRUN_TEST_CVD_STOPPED": str(cvd_stopped),
        "APKRUN_TEST_CONSOLE_TERM_STARTED": str(console_term_started),
        "APKRUN_TEST_CONSOLE_TERM_FINISHED": str(console_term_finished),
    }
    result = subprocess.run(
        _runner_command(home, stage, tmp_path, start_helper, console_helper),
        check=False,
        capture_output=True,
        text=True,
        timeout=12,
        env=environment,
        preexec_fn=(
            lambda: (
                signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
                if blocked_sigterm_at_exec
                else None
            )
        ),
    )

    assert result.returncode == 143, result.stderr
    assert cvd_stopped.exists()
    assert console_term_started.exists()
    assert console_term_finished.exists()
    assert int(cvd_stopped.read_text(encoding="ascii")) < int(
        console_term_finished.read_text(encoding="ascii")
    )


@pytest.mark.skipif(
    sys.platform != "linux", reason="detached descendant cleanup uses Linux subreaper"
)
def test_outer_capture_supervisor_reaps_detached_screen_after_helper_exit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    stage = tmp_path / "stage"
    stage.mkdir(mode=0o700)
    tools = tmp_path / "tools"
    tools.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(mode=0o700)
    cvd_started = tmp_path / "cvd-started"
    cvd_stopped = tmp_path / "cvd-stopped"
    console_ready = tmp_path / "console-ready"
    screen_pid_path = tmp_path / "screen.pid"

    start_helper = _write_fake_cvd_start_helper(tools)
    (fake_bin / "cvd").write_text(
        """#!/usr/bin/env python3
import os
import signal
import time
from pathlib import Path

def stop(_signum, _frame):
    Path(os.environ["APKRUN_TEST_CVD_STOPPED"]).write_text(
        "stopped", encoding="ascii"
    )
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
Path(os.environ["APKRUN_TEST_CVD_STARTED"]).write_text(
    "started", encoding="ascii"
)
while True:
    time.sleep(0.05)
""",
        encoding="utf-8",
    )
    (fake_bin / "cvd").chmod(0o700)
    console_helper = tools / "drive_cuttlefish_console.py"
    console_helper.write_text(
        """import os
import subprocess
import sys
import time
from pathlib import Path

child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGHUP, signal.SIG_IGN); "
        "time.sleep(30)",
    ],
    start_new_session=True,
)
Path(os.environ["APKRUN_TEST_SCREEN_PID"]).write_text(
    str(child.pid), encoding="ascii"
)
Path(os.environ["APKRUN_TEST_CONSOLE_READY"]).write_text(
    "ready", encoding="ascii"
)
cvd_started = Path(os.environ["APKRUN_TEST_CVD_STARTED"])
deadline = time.monotonic() + 3
while not cvd_started.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if not cvd_started.exists():
    raise SystemExit("Cuttlefish did not start")
raise SystemExit(9)
""",
        encoding="utf-8",
    )

    environment = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "APKRUN_TEST_CVD_STARTED": str(cvd_started),
        "APKRUN_TEST_CVD_STOPPED": str(cvd_stopped),
        "APKRUN_TEST_CONSOLE_READY": str(console_ready),
        "APKRUN_TEST_SCREEN_PID": str(screen_pid_path),
    }
    monkeypatch.setenv("PATH", environment["PATH"])
    monkeypatch.setenv("APKRUN_TEST_CVD_STARTED", str(cvd_started))
    monkeypatch.setenv("APKRUN_TEST_CVD_STOPPED", str(cvd_stopped))
    monkeypatch.setenv("APKRUN_TEST_CONSOLE_READY", str(console_ready))
    monkeypatch.setenv("APKRUN_TEST_SCREEN_PID", str(screen_pid_path))
    output = tmp_path / "capture.log"
    status_path = tmp_path / "capture-status.json"
    exit_code, capture_status = capture_bounded.capture(
        _runner_command(home, stage, tmp_path, start_helper, console_helper),
        output,
        status_path,
        65_536,
        timeout_seconds=12,
        merge_stderr=True,
    )

    screen_pid = int(screen_pid_path.read_text(encoding="ascii"))
    assert exit_code == 9
    assert capture_status["childExitCode"] == 9
    assert capture_status["cleanupComplete"] is True
    assert cvd_stopped.read_text(encoding="ascii") == "stopped"
    assert console_ready.read_text(encoding="ascii") == "ready"
    assert not Path("/proc", str(screen_pid)).exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="Cuttlefish supervision runs on Linux"
)
def test_success_after_the_shared_deadline_is_reported_as_timeout(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    stage = tmp_path / "stage"
    stage.mkdir(mode=0o700)
    tools = tmp_path / "tools"
    tools.mkdir(mode=0o700)
    summary_root = tmp_path / "summary"
    summary_root.mkdir(mode=0o700)
    start_helper = _write_fake_cvd_start_helper(tools)
    console_helper = tools / "drive_cuttlefish_console.py"
    console_helper.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
    console_helper.chmod(0o700)

    read_fd, write_fd = os.pipe()
    os.close(write_fd)
    cvd_stdout = os.fdopen(read_fd, "rb", buffering=0)

    class FinishedProcess:
        def __init__(
            self,
            poll_statuses: list[int | None],
            stdout: object | None = None,
        ) -> None:
            self.returncode: int | None = None
            self.poll_statuses = list(poll_statuses)
            self.stdout = stdout

        def poll(self) -> int | None:
            if self.poll_statuses:
                self.returncode = self.poll_statuses.pop(0)
            return self.returncode

        def send_signal(self, _signum: int) -> None:
            raise AssertionError("an already-finished helper must not be signalled")

    processes = iter(
        (
            FinishedProcess([None, 0]),
            FinishedProcess([0], cvd_stdout),
        )
    )
    popen_commands: list[list[str]] = []

    def fake_popen(command: list[str], *_args: object, **_kwargs: object) -> object:
        popen_commands.append(command)
        return next(processes)

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    capture_module = ModuleType("capture_cvd_start")
    capture_module._terminate_child = lambda _process: None  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "capture_cvd_start", capture_module)

    runner_globals = runpy.run_path(str(RUNNER))
    runner_function = runner_globals["run_start_with_console"]
    monotonic_values = iter((0.0, 1.01))
    monkeypatch.setitem(
        runner_function.__globals__,
        "time",
        SimpleNamespace(monotonic=lambda: next(monotonic_values)),
    )
    arguments = SimpleNamespace(
        timeout_seconds=1,
        handoff_timeout_seconds=1,
        home=home,
        stage=stage,
        summary_root=summary_root,
        cvd_start_helper=start_helper,
        console_helper=console_helper,
        console_summary=summary_root / "bootloader-console-summary.json",
        group_name="apkrun_deadline_test",
        gpu_mode="none",
        console_enabled="true",
        memory_mb=2048,
    )

    assert runner_function(arguments) == 124
    assert any("--memory_mb=2048" in command for command in popen_commands)
    assert any(
        "--boot_timeout_secs=1" in command
        for command in popen_commands
    )
