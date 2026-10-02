from __future__ import annotations

import fcntl
import hashlib
import json
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

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


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="verified capture snapshots use sealed Linux memfds",
)
def test_capture_supervisor_runs_verified_snapshot_after_source_changes(
    tmp_path: Path,
) -> None:
    script_path = tmp_path / "capture.sh"
    original_source = b'printf "verified source\\n"\n'
    script_path.write_bytes(original_source)
    descriptor = run_capture._open_verified_script_snapshot(
        script_path,
        hashlib.sha256(original_source).hexdigest(),
    )
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    try:
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        required_seals = (
            fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_WRITE
        )
        assert seals & required_seals == required_seals

        script_path.write_bytes(b'printf "substituted source\\n"\n')
        status = run_capture.supervise(
            ["/bin/bash", f"/proc/self/fd/{descriptor}"],
            timeout_seconds=5,
            cleanup_grace_seconds=1,
            output_log=output_path,
            output_status=output_status_path,
            pass_fds=(descriptor,),
        )
    finally:
        os.close(descriptor)

    assert status["childExitCode"] == 0
    assert status["cleanupComplete"] is True
    assert output_path.read_text(encoding="utf-8") == "verified source\n"


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="verified capture snapshots use sealed Linux memfds",
)
def test_verified_capture_snapshot_rejects_a_mismatched_digest(
    tmp_path: Path,
) -> None:
    script_path = tmp_path / "capture.sh"
    script_path.write_text("exit 0\n", encoding="utf-8")

    with pytest.raises(ValueError, match="differs from its verified SHA-256"):
        run_capture._open_verified_script_snapshot(script_path, "0" * 64)


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="verified capture snapshots use sealed Linux memfds",
)
def test_verified_capture_snapshot_rejects_fifo_without_blocking(
    tmp_path: Path,
) -> None:
    script_path = tmp_path / "capture.sh"
    os.mkfifo(script_path)
    started = time.monotonic()

    with pytest.raises(ValueError, match="regular file"):
        run_capture._open_verified_script_snapshot(script_path, "a" * 64)

    assert time.monotonic() - started < 1


def test_verified_capture_digest_comes_from_the_host_identity(
    tmp_path: Path,
) -> None:
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "experimentSources": {
                    "patched-capture.sh": "a" * 64,
                }
            }
        ),
        encoding="utf-8",
    )

    assert run_capture._verified_capture_sha256(host_identity) == "a" * 64

    host_identity.write_text(
        json.dumps({"experimentSources": {"patched-capture.sh": "invalid"}}),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="source digest is invalid"):
        run_capture._verified_capture_sha256(host_identity)


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="the host identity is loaded by the Linux diagnostic runner",
)
def test_verified_capture_digest_rejects_fifo_without_blocking(
    tmp_path: Path,
) -> None:
    host_identity = tmp_path / "host-identity.json"
    os.mkfifo(host_identity)
    started = time.monotonic()

    with pytest.raises(ValueError, match="host identity is unreadable"):
        run_capture._verified_capture_sha256(host_identity)

    assert time.monotonic() - started < 1


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="verified capture snapshots use sealed Linux memfds",
)
def test_capture_runner_cli_executes_snapshot_with_private_tool_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    private_tool_root = tmp_path / "reference"
    private_tool_root.mkdir()
    script_path = private_tool_root / "capture.sh"
    script_path.write_text(
        'printf "%s|%s\\n" "$1" "$APKRUN_CAPTURE_SCRIPT_DIR"\n',
        encoding="utf-8",
    )
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "experimentSources": {
                    "patched-capture.sh": hashlib.sha256(
                        script_path.read_bytes()
                    ).hexdigest()
                }
            }
        ),
        encoding="utf-8",
    )
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    supervisor_status_path = tmp_path / "capture-supervisor.json"
    monkeypatch.setenv("APKRUN_CAPTURE_SCRIPT_DIR", str(private_tool_root))
    monkeypatch.setattr(run_capture, "requested_signal", None)
    monkeypatch.setattr(run_capture, "finalizing", False)
    monkeypatch.setattr(run_capture, "final_status_path", None)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "run_capture.py",
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(supervisor_status_path),
            "--output-log",
            str(output_path),
            "--output-status",
            str(output_status_path),
            "--verified-script",
            str(script_path),
            "--host-identity",
            str(host_identity),
            "--script-argument",
            "default",
        ],
    )

    assert run_capture.main() == 0
    assert output_path.read_text(encoding="utf-8") == (f"default|{private_tool_root}\n")
    assert json.loads(supervisor_status_path.read_text(encoding="utf-8"))[
        "cleanupComplete"
    ]


def test_capture_supervisor_does_not_wait_out_cleanup_grace_after_empty_exit() -> None:
    started = time.monotonic()
    status = run_capture.supervise(
        [sys.executable, "-c", "pass"],
        timeout_seconds=5,
        cleanup_grace_seconds=2,
    )

    assert time.monotonic() - started < 0.5
    assert status["childExitCode"] == 0
    assert status["cleanupComplete"] is True


def test_capture_supervisor_passes_private_home_and_tmpdir_to_the_child(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "h.abcdef"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("TMPDIR", str(home))
    output_path = tmp_path / "capture-environment.log"
    output_status_path = tmp_path / "capture-environment.json"

    status = run_capture.supervise(
        [
            sys.executable,
            "-c",
            (
                "import json, os; "
                "print(json.dumps({'home': os.environ['HOME'], "
                "'tmpdir': os.environ['TMPDIR']}))"
            ),
        ],
        timeout_seconds=5,
        cleanup_grace_seconds=1,
        output_log=output_path,
        output_status=output_status_path,
    )

    assert status["cleanupComplete"] is True
    assert json.loads(output_path.read_text(encoding="utf-8")) == {
        "home": str(home),
        "tmpdir": str(home),
    }


def test_capture_supervisor_keeps_bounded_private_process_output(
    tmp_path: Path,
) -> None:
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    status = run_capture.supervise(
        [
            sys.executable,
            "-c",
            (
                "import os; os.write(1, b'out:'); os.write(2, b'err:'); "
                "os.write(1, b'x' * 200000)"
            ),
        ],
        timeout_seconds=5,
        cleanup_grace_seconds=1,
        output_log=output_path,
        output_status=output_status_path,
        maximum_output_bytes=64,
    )

    output_status = json.loads(output_status_path.read_text(encoding="utf-8"))
    assert status["childExitCode"] == 0
    assert status["cleanupComplete"] is True
    assert output_path.read_bytes() == b"out:err:" + b"x" * 56
    assert output_path.stat().st_mode & 0o077 == 0
    assert output_status["bytesWritten"] == 64
    assert output_status["truncated"] is True
    assert output_status["cleanupComplete"] is True


def test_capture_supervisor_stops_child_when_output_setup_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    stopped: list[tuple[int | None, bool]] = []
    original_stop_group = run_capture._stop_group

    def fail_selector() -> selectors.BaseSelector:
        raise OSError("selector unavailable")

    def record_group_stop(
        process: subprocess.Popen[bytes],
        grace_seconds: float,
        drain_output: object | None = None,
    ) -> tuple[int | None, bool]:
        result = original_stop_group(process, grace_seconds, drain_output)
        stopped.append((process.poll(), result[1]))
        return result

    monkeypatch.setattr(run_capture.selectors, "DefaultSelector", fail_selector)
    monkeypatch.setattr(run_capture, "_stop_group", record_group_stop)
    with pytest.raises(OSError, match="selector unavailable"):
        run_capture.supervise(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            timeout_seconds=5,
            cleanup_grace_seconds=1,
            output_log=output_path,
            output_status=output_status_path,
        )

    output_status = json.loads(output_status_path.read_text(encoding="utf-8"))
    assert stopped == [(-signal.SIGTERM, True)]
    assert output_status["childExitCode"] == -signal.SIGTERM
    assert output_status["cleanupComplete"] is False


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="detached descendant cleanup uses Linux child subreaper support",
)
def test_capture_supervisor_stops_detached_descendants_after_command_exit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    child_pid_path = tmp_path / "child.pid"
    output_path = tmp_path / "capture.log"
    output_status_path = tmp_path / "capture-output.json"
    root_pinned_during_reaping: list[bool] = []
    original_reap = run_capture.capture_processes.reap_adopted_descendants

    def record_reap(supervised_pid: int) -> bool:
        process = run_capture.child
        if process is not None and process.pid == supervised_pid:
            root_pinned_during_reaping.append(process.returncode is None)
        return original_reap(supervised_pid)

    monkeypatch.setattr(
        run_capture.capture_processes,
        "reap_adopted_descendants",
        record_reap,
    )
    status = run_capture.supervise(
        [
            sys.executable,
            "-c",
            (
                "import pathlib, subprocess, sys; "
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import signal, time; signal.signal(signal.SIGTERM, "
                "signal.SIG_IGN); time.sleep(30)'], "
                "stdin=subprocess.DEVNULL, start_new_session=True); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
            ),
            str(child_pid_path),
        ],
        timeout_seconds=5,
        cleanup_grace_seconds=1,
        output_log=output_path,
        output_status=output_status_path,
    )

    assert status["childExitCode"] == 0
    assert status["cleanupComplete"] is True
    assert root_pinned_during_reaping
    assert all(root_pinned_during_reaping)
    assert child_pid_path.is_file()
    child_pid = int(child_pid_path.read_text(encoding="ascii"))
    assert not Path("/proc", str(child_pid)).exists()
    assert (
        json.loads(output_status_path.read_text(encoding="utf-8"))["cleanupComplete"]
        is True
    )


def test_capture_cli_forwards_signal_and_records_cleanup(tmp_path: Path) -> None:
    status_path = tmp_path / "capture-status.json"
    child_ready_path = tmp_path / "child-ready"
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
            "import pathlib, sys, time; "
            "pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(30)",
            str(child_ready_path),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 5
        while (
            not child_ready_path.exists()
            and process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        assert child_ready_path.exists(), "supervised child did not become ready"
        os.kill(process.pid, signal.SIGTERM)
        assert process.wait(timeout=5) == 128 + signal.SIGTERM
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["signal"] == signal.SIGTERM
    assert status["cleanupComplete"] is True


def test_capture_cli_preserves_signal_received_while_installing_handlers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status_path = tmp_path / "early-signal-status.json"
    original_signal = signal.signal
    original_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    real_signal = os.kill
    signal_injected = False

    def install_handler_and_inject(
        signum: int,
        handler: object,
    ) -> object:
        nonlocal signal_injected
        previous = original_signal(signum, handler)
        if signum == signal.SIGTERM and not signal_injected:
            signal_injected = True
            real_signal(os.getpid(), signal.SIGTERM)
        return previous

    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(run_capture.__file__),
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
    )
    monkeypatch.setattr(run_capture.signal, "signal", install_handler_and_inject)
    try:
        assert run_capture.main() == 128 + signal.SIGTERM
    finally:
        for signum, handler in original_handlers.items():
            original_signal(signum, handler)
        run_capture.requested_signal = None
        run_capture.finalizing = False
        run_capture.final_status_path = None

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert signal_injected is True
    assert status["signal"] == signal.SIGTERM
    assert status["cleanupComplete"] is True


def test_capture_cli_reconciles_signal_delivered_after_supervision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status_path = tmp_path / "late-signal-status.json"
    original_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    original_supervise = run_capture.supervise

    def supervise_then_signal(
        *args: object,
        **kwargs: object,
    ) -> dict[str, int | bool | None]:
        status = original_supervise(*args, **kwargs)
        os.kill(os.getpid(), signal.SIGTERM)
        return status

    monkeypatch.setattr(run_capture, "supervise", supervise_then_signal)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(run_capture.__file__),
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "pass",
        ],
    )
    try:
        assert run_capture.main() == 128 + signal.SIGTERM
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
        run_capture.requested_signal = None
        run_capture.finalizing = False
        run_capture.final_status_path = None

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["signal"] == signal.SIGTERM
    assert status["childExitCode"] == 0


def test_capture_cli_invalidates_status_for_signal_after_status_commit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status_path = tmp_path / "interrupted-status.json"
    original_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    original_write_status = run_capture._write_status

    def write_status_then_signal(
        path: Path,
        status: dict[str, int | bool | None],
    ) -> None:
        original_write_status(path, status)
        if path == status_path:
            os.kill(os.getpid(), signal.SIGTERM)

    monkeypatch.setattr(run_capture, "_write_status", write_status_then_signal)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(run_capture.__file__),
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "raise SystemExit(143)",
        ],
    )
    try:
        with pytest.raises(SystemExit) as exit_info:
            run_capture.main()
        assert exit_info.value.code == 128 + signal.SIGTERM
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
        run_capture.requested_signal = None
        run_capture.finalizing = False
        run_capture.final_status_path = None

    assert not status_path.exists()
    assert status_path.with_name(f"{status_path.name}.interrupted").is_file()


def test_capture_cli_returns_failure_if_late_status_invalidation_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    status_path = tmp_path / "invalidation-failure-status.json"
    original_handlers = {
        signum: signal.getsignal(signum)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    original_write_status = run_capture._write_status

    def fail_marker_open(*_args: object, **_kwargs: object) -> int:
        raise OSError("simulated marker creation failure")

    def fail_status_unlink(
        _path: Path,
        *,
        missing_ok: bool = False,
    ) -> None:
        del missing_ok
        raise OSError("simulated status invalidation failure")

    def commit_then_block_invalidation(
        path: Path,
        status: dict[str, int | bool | None],
    ) -> None:
        original_write_status(path, status)
        if path == status_path:
            monkeypatch.setattr(run_capture.os, "open", fail_marker_open)
            monkeypatch.setattr(Path, "unlink", fail_status_unlink)
            os.kill(os.getpid(), signal.SIGTERM)

    monkeypatch.setattr(
        run_capture,
        "_write_status",
        commit_then_block_invalidation,
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(run_capture.__file__),
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "raise SystemExit(143)",
        ],
    )
    try:
        with pytest.raises(SystemExit) as exit_info:
            run_capture.main()
        assert exit_info.value.code == 125
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)
        run_capture.requested_signal = None
        run_capture.finalizing = False
        run_capture.final_status_path = None

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["signal"] is None
    assert status["childExitCode"] == 143
    assert not status_path.with_name(f"{status_path.name}.interrupted").exists()


def test_capture_cli_drains_output_while_child_handles_termination(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "capture-status.json"
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    child_ready = tmp_path / "child-ready"
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
            "--output-log",
            str(output_path),
            "--output-status",
            str(output_status_path),
            "--max-output-bytes",
            "64",
            "--",
            sys.executable,
            "-c",
            (
                "import os, pathlib, signal, sys, time; "
                "signal.signal(signal.SIGTERM, lambda *_: "
                "[os.write(1, b'x' * 65536) for _ in range(32)]); "
                "pathlib.Path(sys.argv[1]).write_text('ready'); "
                "time.sleep(30)"
            ),
            str(child_ready),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        ready_deadline = time.monotonic() + 5
        while not child_ready.exists() and time.monotonic() < ready_deadline:
            if process.poll() is not None:
                break
            time.sleep(0.01)
        assert child_ready.is_file()
        os.kill(process.pid, signal.SIGTERM)
        assert process.wait(timeout=5) == 128 + signal.SIGTERM
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    status = json.loads(status_path.read_text(encoding="utf-8"))
    output_status = json.loads(output_status_path.read_text(encoding="utf-8"))
    assert status["cleanupComplete"] is True
    assert output_status["bytesWritten"] == 64
    assert output_status["truncated"] is True
    assert output_status["cleanupComplete"] is True
    assert output_path.stat().st_size == 64


def test_capture_cli_records_bounded_child_output(tmp_path: Path) -> None:
    status_path = tmp_path / "capture-status.json"
    output_path = tmp_path / "capture-output.log"
    output_status_path = tmp_path / "capture-output.json"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(run_capture.__file__)),
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(status_path),
            "--output-log",
            str(output_path),
            "--output-status",
            str(output_status_path),
            "--max-output-bytes",
            "32",
            "--",
            sys.executable,
            "-c",
            (
                "import os; os.write(1, b'out:'); os.write(2, b'err:'); "
                "os.write(1, b'a' * 128)"
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    output_status = json.loads(output_status_path.read_text(encoding="utf-8"))
    assert result.returncode == 0, result.stderr
    assert output_path.read_bytes() == b"out:err:" + b"a" * 24
    assert status["cleanupComplete"] is True
    assert output_status["truncated"] is True
    assert output_status["cleanupComplete"] is True


def test_capture_cli_separates_supervisor_status_from_child_exit_code(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "nonzero-child-status.json"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(run_capture.__file__)),
            "--timeout-seconds",
            "5",
            "--cleanup-grace-seconds",
            "1",
            "--status",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "raise SystemExit(143)",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert result.returncode == 0, result.stderr
    assert status["childExitCode"] == 143
    assert status["signal"] is None
    assert status["cleanupComplete"] is True
