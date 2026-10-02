from __future__ import annotations

import errno
import json
import os
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import experiment_support

REFERENCE_HOST = {
    "hostKind": "linux-apple",
    "os": "Ubuntu 24.04.4 LTS",
    "kernel": "Linux 6.8.0-134-generic aarch64 GNU/Linux",
    "architecture": "aarch64",
    "cpuCount": 8,
    "nestedVirtualization": "on",
}


@pytest.fixture(autouse=True)
def _restore_baseline_commit() -> Iterator[None]:
    production_commit = experiment_support.BASELINE_COMMIT
    yield
    experiment_support.BASELINE_COMMIT = production_commit


@pytest.mark.parametrize(
    ("actual_start_time", "should_signal"),
    (("12345", True), ("54321", False)),
)
def test_pidfd_broker_pins_only_the_verified_process(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    actual_start_time: str,
    should_signal: bool,
) -> None:
    sent_signals: list[tuple[int, int]] = []
    pidfd, pidfd_keepalive = os.pipe()
    control_read, control_write = os.pipe()
    os.write(control_write, b"TERM\nCONT\nKILL\nQUIT\n")
    os.close(control_write)
    control_input = os.fdopen(control_read, "rb", buffering=0)
    monkeypatch.setattr(experiment_support.sys, "platform", "linux")
    monkeypatch.setattr(
        experiment_support.os,
        "pidfd_open",
        lambda process_id, flags: pidfd,
        raising=False,
    )
    monkeypatch.setattr(
        experiment_support.signal,
        "pidfd_send_signal",
        lambda descriptor, signal_number: sent_signals.append(
            (descriptor, signal_number)
        ),
        raising=False,
    )
    monkeypatch.setattr(
        experiment_support,
        "_process_start_time",
        lambda _path: actual_start_time,
    )
    monkeypatch.setattr(experiment_support.sys, "stdin", control_input)
    ready_path = tmp_path / "signal-broker.ready"
    exited_path = tmp_path / "signal-broker.exited"
    stopped_path = tmp_path / "signal-broker.stopped"

    try:
        if should_signal:
            experiment_support.run_process_signal_broker(
                321,
                "12345",
                ready_path,
                exited_path,
                stopped_path,
            )
            assert sent_signals == [
                (pidfd, signal.SIGTERM),
                (pidfd, signal.SIGCONT),
                (pidfd, signal.SIGKILL),
            ]
            assert ready_path.read_text(encoding="ascii") == "321 12345\n"
            assert not exited_path.exists()
            assert stopped_path.read_text(encoding="ascii") == "321 12345\n"
        else:
            with pytest.raises(ValueError, match="PID"):
                experiment_support.run_process_signal_broker(
                    321,
                    "12345",
                    ready_path,
                    exited_path,
                    stopped_path,
                )
            assert sent_signals == []
            assert not ready_path.exists()
            assert not stopped_path.exists()
    finally:
        control_input.close()
    with pytest.raises(OSError):
        os.fstat(pidfd)
    os.close(pidfd_keepalive)


@pytest.mark.skipif(
    sys.platform != "linux"
    or not hasattr(os, "pidfd_open")
    or not hasattr(signal, "pidfd_send_signal"),
    reason="process identity signaling requires Linux pidfds",
)
def test_pidfd_broker_signals_the_original_process_and_exits_on_request(
    tmp_path: Path,
) -> None:
    process = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    control_fifo = tmp_path / "signal-broker.control"
    ready_path = tmp_path / "signal-broker.ready"
    exited_path = tmp_path / "signal-broker.exited"
    stopped_path = tmp_path / "signal-broker.stopped"
    os.mkfifo(control_fifo, 0o600)
    control_descriptor = os.open(control_fifo, os.O_RDWR)
    broker: subprocess.Popen[bytes] | None = None
    try:
        start_time = experiment_support._process_start_time(
            Path("/proc") / str(process.pid)
        )
        broker = subprocess.Popen(
            [
                sys.executable,
                str(Path(experiment_support.__file__)),
                "signal-process-broker",
                "--pid",
                str(process.pid),
                "--start-time",
                start_time,
                "--ready-file",
                str(ready_path),
                "--exited-file",
                str(exited_path),
                "--stopped-file",
                str(stopped_path),
            ],
            stdin=control_descriptor,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        ready_deadline = time.monotonic() + 5
        while (
            not ready_path.exists()
            and broker.poll() is None
            and time.monotonic() < ready_deadline
        ):
            time.sleep(0.01)
        assert ready_path.read_text(encoding="ascii") == (
            f"{process.pid} {start_time}\n"
        )

        os.write(control_descriptor, b"TERM\n")
        assert process.wait(timeout=5) == -signal.SIGTERM
        broker_stdout, broker_stderr = broker.communicate(timeout=5)
        assert broker.returncode == 0, (broker_stdout, broker_stderr)
        assert exited_path.read_text(encoding="ascii") == (
            f"{process.pid} {start_time}\n"
        )
        assert stopped_path.read_text(encoding="ascii") == (
            f"{process.pid} {start_time}\n"
        )
    finally:
        os.close(control_descriptor)
        if broker is not None and broker.poll() is None:
            broker.terminate()
            broker.communicate(timeout=5)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


@pytest.mark.skipif(
    sys.platform != "linux"
    or not hasattr(os, "pidfd_open")
    or not hasattr(signal, "pidfd_send_signal"),
    reason="process identity signaling requires Linux pidfds",
)
def test_pidfd_broker_stops_target_when_its_owner_disconnects(
    tmp_path: Path,
) -> None:
    process = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import signal, sys, time; "
                "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); "
                "time.sleep(30)"
            ),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    start_time = experiment_support._process_start_time(
        Path("/proc") / str(process.pid)
    )
    ready_path = tmp_path / "signal-broker.ready"
    exited_path = tmp_path / "signal-broker.exited"
    stopped_path = tmp_path / "signal-broker.stopped"
    broker = subprocess.Popen(
        [
            sys.executable,
            str(Path(experiment_support.__file__)),
            "signal-process-broker",
            "--pid",
            str(process.pid),
            "--start-time",
            start_time,
            "--ready-file",
            str(ready_path),
            "--exited-file",
            str(exited_path),
            "--stopped-file",
            str(stopped_path),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        ready_deadline = time.monotonic() + 5
        while not ready_path.exists() and time.monotonic() < ready_deadline:
            if broker.poll() is not None:
                break
            time.sleep(0.01)
        assert ready_path.is_file()
        assert broker.stdin is not None
        broker.stdin.close()
        broker.stdin = None
        assert process.wait(timeout=10) == 0
        broker_stdout, broker_stderr = broker.communicate(timeout=5)
        assert broker.returncode == 0, (broker_stdout, broker_stderr)
        assert exited_path.read_text(encoding="ascii") == (
            f"{process.pid} {start_time}\n"
        )
        assert stopped_path.read_text(encoding="ascii") == (
            f"{process.pid} {start_time}\n"
        )
    finally:
        if broker.poll() is None:
            broker.kill()
            broker.communicate(timeout=5)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def _mark_generated_workspace(work_root: Path, ownership_token: str) -> None:
    experiment_support.prepare_private_data_root(work_root.parent.parent)
    os.chmod(work_root, 0o700)
    marker = f"APKRun Cuttlefish boot diagnosis v1\n{ownership_token}\n{work_root}\n"
    (work_root / ".apkrun-cuttlefish-workspace").write_text(
        marker,
        encoding="utf-8",
    )


def _write_publication_experiment(
    capture_record: Path,
    gpu_mode_slug: str = "none",
    console_enabled: bool = False,
    pause_in_bootloader: bool = False,
    bootloader_console: dict[str, object] | None = None,
) -> None:
    gpu_mode = {slug: mode for mode, slug in experiment_support.GPU_MODE_SLUGS.items()}[
        gpu_mode_slug
    ]
    console_mode_slug = experiment_support.CONSOLE_MODE_SLUGS[console_enabled]
    (capture_record / "experiment.json").write_text(
        json.dumps(
            {
                "experiment": (
                    f"cuttlefish-gpu-{gpu_mode_slug}-console-{console_mode_slug}-"
                    "boot-diagnosis"
                ),
                "gpuMode": gpu_mode,
                "gpuModeSlug": gpu_mode_slug,
                "consoleEnabled": console_enabled,
                "consoleModeSlug": console_mode_slug,
                "pauseInBootloader": pause_in_bootloader,
                "bootTimeoutSeconds": 600,
                "runnerDeadlineSeconds": 900,
                **(
                    {"bootloaderConsole": bootloader_console}
                    if bootloader_console is not None
                    else {}
                ),
            }
        ),
        encoding="utf-8",
    )
    (capture_record / "cuttlefish_config.json").write_text(
        json.dumps(
            {
                "instances": {
                    "1": {
                        "gpu_mode": gpu_mode,
                        "enable_gpu_vhost_user": False,
                        "cpus": 4,
                        "memory_mb": 4096,
                        "console": console_enabled,
                        "pause_in_bootloader": pause_in_bootloader,
                    }
                }
            }
        ),
        encoding="utf-8",
    )


def _use_reference_host(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        experiment_support,
        "_current_host_fingerprint",
        lambda: dict(REFERENCE_HOST),
    )


def _make_baseline_repository(root: Path) -> tuple[Path, Path, Path, Path]:
    baseline = root / experiment_support.BASELINE_RELATIVE
    baseline.mkdir(parents=True)
    (baseline / "host.json").write_text(
        json.dumps(
            {
                "buildId": "16373615",
                "profile": "default",
                "cvdPackageVersion": "1.57.0",
                **REFERENCE_HOST,
                "cvdInstanceNumber": 1,
            }
        ),
        encoding="utf-8",
    )
    (baseline / "cuttlefish_config.json").write_text(
        json.dumps(
            {
                "instances": {
                    "1": {
                        "gpu_mode": "guest_swiftshader",
                        "cpus": 4,
                        "memory_mb": 4096,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (baseline / "cvd-create-console.log").write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n",
        encoding="utf-8",
    )
    for relative in experiment_support.TOOL_PATHS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"pinned source: {relative}\n", encoding="utf-8")
    experiment_root = root / "Experiments/cuttlefish-boot-diagnosis"
    experiment_root.mkdir(parents=True)
    for name in experiment_support.EXPERIMENT_TOOL_NAMES:
        (experiment_root / name).write_text(
            f"experiment source: {name}\n",
            encoding="utf-8",
        )
    patched_capture = root / "private-capture.sh"
    patched_capture.write_text("private patched capture\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=APKRun Test",
            "-c",
            "user.email=apkrun-test@example.invalid",
            "commit",
            "-q",
            "-m",
            "baseline fixture",
        ],
        cwd=root,
        check=True,
    )
    experiment_support.BASELINE_COMMIT = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return root, baseline, experiment_root, patched_capture


@pytest.mark.parametrize(
    ("field", "value", "message"),
    (
        ("schemaVersion", True, "invalid fields"),
        ("schemaVersion", 1, "invalid fields"),
        ("schemaVersion", 2, "invalid fields"),
        ("schemaVersion", 4.0, "invalid fields"),
        ("cleanupComplete", False, "inconsistent or incomplete"),
        ("outputBytesObserved", 0, "inconsistent or incomplete"),
        ("escapeStrippedBytesObserved", -1, "invalid fields"),
        ("escapeStrippedBytesObserved", 65, "invalid fields"),
        ("escapeSequenceIncomplete", 1, "invalid fields"),
        ("promptObserved", False, "inconsistent or incomplete"),
        ("outputTruncated", True, "inconsistent or incomplete"),
        ("timedOut", True, "inconsistent or incomplete"),
        ("handoffTimedOut", True, "inconsistent or incomplete"),
        ("outputBytesObserved", 65_537, "invalid fields"),
        ("screenExitCode", 256, "invalid fields"),
        ("transcript", "private console text", "unexpected schema"),
    ),
)
def test_bootloader_console_summary_rejects_invalid_status(
    tmp_path: Path,
    field: str,
    value: object,
    message: str,
) -> None:
    summary = {
        "schemaVersion": 3,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    summary[field] = value
    if field == "outputBytesObserved" and value == 0:
        summary["escapeStrippedBytesObserved"] = 0
    path = tmp_path / "bootloader-console-summary.json"
    path.write_text(json.dumps(summary), encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        experiment_support._bootloader_console_summary(path, True)


def test_bootloader_console_summary_accepts_sanitized_bdinfo_addresses() -> None:
    summary: dict[str, object] = {
        "schemaVersion": 4,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponseObserved": True,
        "bdinfoResponseRejected": False,
        "bdinfoTimedOut": False,
        "relocationAddress": 0x17F600000,
        "relocationOffset": 0x8000,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }

    assert experiment_support._validate_bootloader_console_summary(summary) == summary

    legacy_summary = dict(summary)
    legacy_summary.pop("bdinfoResponseRejected")
    assert (
        experiment_support._validate_bootloader_console_summary(legacy_summary)
        == legacy_summary
    )

    summary["bdinfoResponseRejected"] = True
    with pytest.raises(ValueError, match="inconsistent or incomplete"):
        experiment_support._validate_bootloader_console_summary(summary)


def test_bootloader_console_summary_accepts_rejected_bdinfo_with_boot() -> None:
    summary: dict[str, object] = {
        "schemaVersion": 5,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponsePromptObserved": True,
        "bdinfoResponseObserved": False,
        "bdinfoResponseRejected": True,
        "bdinfoTimedOut": False,
        "relocationAddress": None,
        "relocationOffset": None,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_rejects_bdinfo_without_following_prompt() -> None:
    summary: dict[str, object] = {
        "schemaVersion": 5,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponsePromptObserved": False,
        "bdinfoResponseObserved": False,
        "bdinfoResponseRejected": True,
        "bdinfoTimedOut": False,
        "relocationAddress": None,
        "relocationOffset": None,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }

    with pytest.raises(ValueError, match="inconsistent or incomplete"):
        experiment_support._validate_bootloader_console_summary(summary)


@pytest.mark.parametrize(
    ("updates", "message"),
    (
        (
            {"bdinfoResponseObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"promptObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoCommandEchoObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoStartMarkerObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoEndMarkerObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoResponsePromptObserved": False},
            "inconsistent or incomplete",
        ),
        (
            {"relocationAddress": None},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoTimedOut": True},
            "inconsistent or incomplete",
        ),
        (
            {"bdinfoResponseRejected": True},
            "inconsistent or incomplete",
        ),
        (
            {
                "bdinfoResponsePromptObserved": False,
                "bdinfoResponseObserved": False,
                "bdinfoTimedOut": True,
                "relocationAddress": None,
                "relocationOffset": None,
                "bootCommandSent": False,
                "kernelHandoffObserved": False,
                "timedOut": True,
                "exitCode": 1,
            },
            "inconsistent or incomplete",
        ),
        (
            {"relocationAddress": True},
            "invalid fields",
        ),
        (
            {"relocationOffset": 0x1_0000_0000_0000_0000},
            "invalid fields",
        ),
    ),
)
def test_bootloader_console_summary_rejects_inconsistent_bdinfo(
    updates: dict[str, object],
    message: str,
) -> None:
    summary: dict[str, object] = {
        "schemaVersion": 5,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponsePromptObserved": True,
        "bdinfoResponseObserved": True,
        "bdinfoResponseRejected": False,
        "bdinfoTimedOut": False,
        "relocationAddress": 0x17F600000,
        "relocationOffset": 0x8000,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    summary.update(updates)

    with pytest.raises(ValueError, match=message):
        experiment_support._validate_bootloader_console_summary(summary)


def _valid_memory_probe_summary() -> dict[str, object]:
    return {
        "schemaVersion": 6,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "memoryProbePreparationCommandAttempted": True,
        "memoryProbePreparationCommandSent": True,
        "memoryProbePreparationCommandEchoObserved": True,
        "memoryProbePreparationResponsePromptObserved": True,
        "memoryProbeVariablesCleared": True,
        "memoryProbePreparationRejected": False,
        "memoryProbeCommandAttempted": True,
        "memoryProbeCommandSent": True,
        "memoryProbeCommandEchoObserved": True,
        "memoryProbeResponsePromptObserved": True,
        "memoryProbeResponseObserved": True,
        "memoryProbeResponseRejected": False,
        "memoryProbeTimedOut": False,
        "wordAtObservedPc": 0xD50B7E20,
        "wordBeforeObservedPc": 0xD53B0023,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }


def test_bootloader_console_summary_accepts_sanitized_memory_probe_words() -> None:
    summary = _valid_memory_probe_summary()

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_rejected_memory_probe_with_boot() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=True,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_memory_probe_timeout() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        memoryProbeTimedOut=True,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
        bootCommandSent=False,
        kernelHandoffObserved=False,
        exitCode=1,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_memory_read_send_timeout() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbeCommandSent=False,
        memoryProbeCommandEchoObserved=False,
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        memoryProbeTimedOut=True,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
        bootCommandSent=False,
        kernelHandoffObserved=False,
        exitCode=1,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_rejected_preparation_with_boot() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbeVariablesCleared=False,
        memoryProbePreparationRejected=True,
        memoryProbeCommandAttempted=False,
        memoryProbeCommandSent=False,
        memoryProbeCommandEchoObserved=False,
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_preparation_timeout() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbePreparationCommandEchoObserved=False,
        memoryProbePreparationResponsePromptObserved=False,
        memoryProbeVariablesCleared=False,
        memoryProbeCommandAttempted=False,
        memoryProbeCommandSent=False,
        memoryProbeCommandEchoObserved=False,
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        memoryProbeTimedOut=True,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
        bootCommandSent=False,
        kernelHandoffObserved=False,
        exitCode=1,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


def test_bootloader_console_summary_accepts_preparation_send_timeout() -> None:
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbePreparationCommandSent=False,
        memoryProbePreparationCommandEchoObserved=False,
        memoryProbePreparationResponsePromptObserved=False,
        memoryProbeVariablesCleared=False,
        memoryProbeCommandAttempted=False,
        memoryProbeCommandSent=False,
        memoryProbeCommandEchoObserved=False,
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        memoryProbeTimedOut=True,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
        bootCommandSent=False,
        kernelHandoffObserved=False,
        exitCode=1,
    )

    assert experiment_support._validate_bootloader_console_summary(summary) == summary


@pytest.mark.parametrize(
    ("updates", "message"),
    (
        ({"wordAtObservedPc": True}, "invalid fields"),
        ({"wordBeforeObservedPc": 0x1_0000_0000}, "invalid fields"),
        ({"memoryProbeCommandEchoObserved": False}, "inconsistent or incomplete"),
        ({"memoryProbeResponsePromptObserved": False}, "inconsistent or incomplete"),
        ({"memoryProbeTimedOut": True}, "inconsistent or incomplete"),
        ({"memoryProbeResponseRejected": True}, "inconsistent or incomplete"),
        ({"bootCommandSent": False}, "inconsistent or incomplete"),
        ({"wordAtObservedPc": None}, "inconsistent or incomplete"),
        (
            {
                "memoryProbePreparationCommandEchoObserved": False,
                "memoryProbeVariablesCleared": False,
                "memoryProbePreparationRejected": True,
                "memoryProbeCommandAttempted": False,
                "memoryProbeCommandSent": False,
                "memoryProbeCommandEchoObserved": False,
                "memoryProbeResponsePromptObserved": False,
                "memoryProbeResponseObserved": False,
                "memoryProbeResponseRejected": False,
                "wordAtObservedPc": None,
                "wordBeforeObservedPc": None,
            },
            "inconsistent or incomplete",
        ),
    ),
)
def test_bootloader_console_summary_rejects_inconsistent_memory_probe(
    updates: dict[str, object],
    message: str,
) -> None:
    summary = _valid_memory_probe_summary()
    summary.update(updates)

    with pytest.raises(ValueError, match=message):
        experiment_support._validate_bootloader_console_summary(summary)


@pytest.mark.parametrize(
    ("status_change", "message"),
    (
        (
            {"signal": signal.SIGKILL, "exitCode": 128 + signal.SIGKILL},
            "invalid fields",
        ),
        (
            {
                "screenStarted": False,
                "promptObserved": False,
                "bootCommandSent": False,
                "kernelHandoffObserved": False,
                "outputBytesObserved": 0,
                "escapeStrippedBytesObserved": 0,
                "escapeSequenceIncomplete": False,
                "screenExitCode": 0,
                "exitCode": 1,
            },
            "inconsistent or incomplete",
        ),
        (
            {
                "uBootBannerObserved": False,
                "escapeStrippedBytesObserved": 0,
            },
            "inconsistent or incomplete",
        ),
    ),
)
def test_bootloader_console_summary_rejects_impossible_process_status(
    status_change: dict[str, object],
    message: str,
) -> None:
    summary: dict[str, object] = {
        "schemaVersion": 3,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    summary.update(status_change)

    with pytest.raises(ValueError, match=message):
        experiment_support._validate_bootloader_console_summary(summary)


def test_bootloader_console_summary_rejects_simultaneous_timeouts(
    tmp_path: Path,
) -> None:
    summary = {
        "schemaVersion": 3,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bootCommandSent": True,
        "kernelHandoffObserved": False,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": True,
        "handoffTimedOut": True,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 124,
    }
    path = tmp_path / "bootloader-console-summary.json"
    path.write_text(json.dumps(summary), encoding="utf-8")

    with pytest.raises(ValueError, match="inconsistent or incomplete"):
        experiment_support._bootloader_console_summary(path, True)


def test_bootloader_console_summary_is_required_only_when_pause_is_enabled(
    tmp_path: Path,
) -> None:
    path = tmp_path / "bootloader-console-summary.json"

    assert experiment_support._bootloader_console_summary(None, False) is None
    with pytest.raises(ValueError, match="summary is unavailable"):
        experiment_support._bootloader_console_summary(path, True)

    path.write_text("{}", encoding="utf-8")
    with pytest.raises(ValueError, match="unexpected when the pause is disabled"):
        experiment_support._bootloader_console_summary(path, False)


def test_bootloader_pause_requires_console_enabled() -> None:
    with pytest.raises(
        ValueError,
        match="bootloader pause requires the Cuttlefish console to be enabled",
    ):
        experiment_support._verify_gpu_configuration(
            {},
            "none",
            console_enabled=False,
            pause_in_bootloader=True,
        )

    experiment = {
        "gpuMode": "none",
        "gpuModeSlug": "none",
        "consoleEnabled": False,
        "consoleModeSlug": "off",
        "pauseInBootloader": True,
        "experiment": "cuttlefish-gpu-none-console-off-boot-diagnosis",
    }
    with pytest.raises(
        ValueError,
        match="bootloader pause requires the Cuttlefish console to be enabled",
    ):
        experiment_support._verify_publication_mode_labels(
            "gpu-none-console-off.deadbeef",
            "gpu-none-console-off-20261002T120000Z-123",
            experiment,
        )


def test_prepare_private_data_root_locks_custom_directories_and_rejects_shared_parent(
    tmp_path: Path,
) -> None:
    safe_parent = tmp_path / "safe-parent"
    safe_parent.mkdir(mode=0o700)
    data_root = safe_parent / "diagnostics"
    data_root.mkdir(mode=0o777)
    (data_root / "work").mkdir(mode=0o777)
    (data_root / "results").mkdir(mode=0o777)

    experiment_support.prepare_private_data_root(data_root)

    for path in (data_root, data_root / "work", data_root / "results"):
        assert path.stat().st_uid == os.getuid()
        assert path.stat().st_mode & 0o777 == 0o700

    unsafe_parent = tmp_path / "shared-parent"
    unsafe_parent.mkdir(mode=0o777)
    os.chmod(unsafe_parent, 0o777)
    unsafe_root = unsafe_parent / "diagnostics"
    with pytest.raises(ValueError, match="writable parent"):
        experiment_support.prepare_private_data_root(unsafe_root)
    assert not unsafe_root.exists()
    os.chmod(unsafe_parent, 0o700)


def test_prepare_data_root_prints_a_canonical_path_for_workspace_markers(
    tmp_path: Path,
) -> None:
    canonical_root = tmp_path / "diagnostics"
    requested_root = f"{tmp_path}//diagnostics/./"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(experiment_support.__file__)),
            "prepare-data-root",
            "--print-canonical",
            "--data-root",
            requested_root,
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(canonical_root)
    work_root = canonical_root / "work/gpu-none.test123"
    work_root.mkdir(mode=0o700)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    work_descriptor = experiment_support._open_directory_chain(work_root)
    try:
        experiment_support._verify_workspace_marker(
            work_descriptor,
            work_root,
            ownership_token,
        )
    finally:
        os.close(work_descriptor)


def test_unix_socket_path_measurement_includes_the_terminating_nul() -> None:
    assert experiment_support._encoded_unix_socket_path_bytes("x" * 107) == 108
    assert experiment_support._encoded_unix_socket_path_bytes("x" * 108) == 109


def test_unix_socket_audit_measures_complete_physical_paths() -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    socket_path = root / "cvd.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(socket_path))
        metrics = experiment_support.audit_unix_socket_paths([root])
    finally:
        listener.close()
        shutil.rmtree(root)

    encoded_path_bytes = len(os.fsencode(socket_path)) + 1
    assert metrics == {
        "capacityBytes": 108,
        "terminatingNulBytes": 1,
        "socketCount": 1,
        "maxEncodedPathBytes": encoded_path_bytes - 1,
        "maxSunPathBytesIncludingNul": encoded_path_bytes,
    }


def test_unix_socket_audit_rejects_socket_replaced_by_external_symlink(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    socket_path = root / "cvd.sock"
    external_socket_path = external_root / "cvd.sock"
    root_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    external_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    root_listener.bind(str(socket_path))
    external_listener.bind(str(external_socket_path))
    root_stat = os.stat(root, follow_symlinks=False)
    original_stat = os.stat
    entry_stat_count = 0

    def replace_on_socket_recheck(path, *args, **kwargs):
        nonlocal entry_stat_count
        directory_descriptor = kwargs.get("dir_fd")
        is_audit_root = isinstance(
            directory_descriptor, int
        ) and experiment_support._same_inode(
            root_stat,
            os.fstat(directory_descriptor),
        )
        if (
            path == "cvd.sock"
            and is_audit_root
            and kwargs.get("follow_symlinks") is False
        ):
            entry_stat_count += 1
            if entry_stat_count == 2:
                socket_path.unlink()
                socket_path.symlink_to(external_socket_path)
        return original_stat(path, *args, **kwargs)

    try:
        with monkeypatch.context() as patch:
            patch.setattr(experiment_support.os, "stat", replace_on_socket_recheck)
            with pytest.raises(ValueError, match="socket entry changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert entry_stat_count == 2
            assert socket_path.is_symlink()
            assert external_socket_path.exists()
    finally:
        root_listener.close()
        external_listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_rechecks_dangling_symlink_before_skipping(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    socket_alias = root / "socket-alias"
    missing_target = external_root / "missing.sock"
    external_socket_path = external_root / "live.sock"
    socket_alias.symlink_to(missing_target)
    external_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    external_listener.bind(str(external_socket_path))
    root_stat = os.stat(root, follow_symlinks=False)
    original_stat = os.stat
    link_replaced = False

    def replace_after_missing_stat(path, *args, **kwargs):
        nonlocal link_replaced
        directory_descriptor = kwargs.get("dir_fd")
        is_audit_root = isinstance(
            directory_descriptor, int
        ) and experiment_support._same_inode(
            root_stat,
            os.fstat(directory_descriptor),
        )
        if (
            path == "socket-alias"
            and is_audit_root
            and kwargs.get("follow_symlinks") is True
            and not link_replaced
        ):
            try:
                return original_stat(path, *args, **kwargs)
            except FileNotFoundError:
                socket_alias.unlink()
                socket_alias.symlink_to(external_socket_path)
                link_replaced = True
                raise
        return original_stat(path, *args, **kwargs)

    try:
        with monkeypatch.context() as patch:
            patch.setattr(experiment_support.os, "stat", replace_after_missing_stat)
            with pytest.raises(ValueError, match="symlink changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert link_replaced
            assert external_socket_path.exists()
    finally:
        external_listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_rechecks_non_socket_symlink_target_before_skipping(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    socket_alias = root / "socket-alias"
    external_target = external_root / "target"
    external_target.write_text("initial regular file", encoding="utf-8")
    socket_alias.symlink_to(external_target)
    external_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    root_stat = os.stat(root, follow_symlinks=False)
    original_stat = os.stat
    target_replaced = False

    def replace_after_regular_stat(path, *args, **kwargs):
        nonlocal target_replaced
        directory_descriptor = kwargs.get("dir_fd")
        is_audit_root = isinstance(
            directory_descriptor, int
        ) and experiment_support._same_inode(
            root_stat,
            os.fstat(directory_descriptor),
        )
        if (
            path == "socket-alias"
            and is_audit_root
            and kwargs.get("follow_symlinks") is True
            and not target_replaced
        ):
            initial_stat = original_stat(path, *args, **kwargs)
            external_target.unlink()
            external_listener.bind(str(external_target))
            target_replaced = True
            return initial_stat
        return original_stat(path, *args, **kwargs)

    try:
        with monkeypatch.context() as patch:
            patch.setattr(experiment_support.os, "stat", replace_after_regular_stat)
            with pytest.raises(ValueError, match="symlink target changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert target_replaced
            assert external_target.exists()
    finally:
        external_listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


@pytest.mark.parametrize("initial_target", ["dangling", "regular"])
def test_unix_socket_audit_rechecks_skipped_target_after_final_link_check(
    initial_target: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    socket_alias = root / "socket-alias"
    external_target = external_root / "target"
    if initial_target == "regular":
        external_target.write_text("initial regular file", encoding="utf-8")
    socket_alias.symlink_to(external_target)
    external_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    root_stat = os.stat(root, follow_symlinks=False)
    original_readlink = os.readlink
    readlink_count = 0
    target_created = False

    def create_target_during_final_link_check(path, *args, **kwargs):
        nonlocal readlink_count, target_created
        link_text = original_readlink(path, *args, **kwargs)
        directory_descriptor = kwargs.get("dir_fd")
        is_audit_root = isinstance(
            directory_descriptor, int
        ) and experiment_support._same_inode(
            root_stat,
            os.fstat(directory_descriptor),
        )
        if path == "socket-alias" and is_audit_root:
            readlink_count += 1
            if readlink_count == 3:
                if initial_target == "regular":
                    external_target.unlink()
                external_listener.bind(str(external_target))
                target_created = True
        return link_text

    try:
        with monkeypatch.context() as patch:
            patch.setattr(
                experiment_support.os,
                "readlink",
                create_target_during_final_link_check,
            )
            with pytest.raises(ValueError, match="symlink target changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert target_created
            assert readlink_count == 3
            assert external_target.exists()
    finally:
        external_listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_rejects_directory_and_external_socket_symlinks() -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    socket_path = external_root / "cvd.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(socket_path))
        (root / "linked-runtime").symlink_to(external_root, target_is_directory=True)

        with pytest.raises(ValueError, match="symlink"):
            experiment_support.audit_unix_socket_paths([root])

        (root / "linked-runtime").unlink()
        (root / "linked-socket").symlink_to(socket_path)
        with pytest.raises(ValueError, match="escapes its audit roots"):
            experiment_support.audit_unix_socket_paths([root])

        assert socket_path.exists()
    finally:
        listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_measures_contained_socket_symlink_paths() -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    socket_directory = root / "runtime"
    socket_directory.mkdir()
    socket_path = socket_directory / "cvd.sock"
    socket_alias = root / "linked-socket"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(socket_path))
        socket_alias.symlink_to(socket_path)

        metrics = experiment_support.audit_unix_socket_paths([root])
        encoded_socket_path_bytes = len(os.fsencode(socket_path)) + 1
        encoded_alias_path_bytes = len(os.fsencode(socket_alias)) + 1
        maximum_path_bytes = max(
            encoded_socket_path_bytes,
            encoded_alias_path_bytes,
        )
        assert metrics == {
            "capacityBytes": 108,
            "terminatingNulBytes": 1,
            "socketCount": 2,
            "maxEncodedPathBytes": maximum_path_bytes - 1,
            "maxSunPathBytesIncludingNul": maximum_path_bytes,
        }

        long_socket_alias = root / ("a" * 100)
        long_socket_alias.symlink_to(socket_path)
        with pytest.raises(ValueError, match="exceeds Linux sun_path capacity"):
            experiment_support.audit_unix_socket_paths([root])
    finally:
        listener.close()
        shutil.rmtree(root)


def test_unix_socket_audit_rejects_a_directory_replaced_by_external_symlink(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    nested_directory = root / "runtime"
    moved_directory = root / "runtime-moved"
    nested_directory.mkdir()
    socket_path = external_root / "cvd.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    nested_stat = os.stat(nested_directory, follow_symlinks=False)
    original_scandir = os.scandir
    directory_replaced = False

    def replace_directory_before_scan(path: int | str | os.PathLike[str]):
        nonlocal directory_replaced
        if isinstance(path, int):
            path_stat = os.fstat(path)
            is_nested_directory = experiment_support._same_inode(
                nested_stat,
                path_stat,
            )
        else:
            is_nested_directory = Path(path) == nested_directory
        if is_nested_directory and not directory_replaced:
            os.rename(nested_directory, moved_directory)
            nested_directory.symlink_to(external_root, target_is_directory=True)
            directory_replaced = True
        return original_scandir(path)

    monkeypatch.setattr(experiment_support.os, "scandir", replace_directory_before_scan)
    try:
        with pytest.raises(ValueError, match="directory changed"):
            experiment_support.audit_unix_socket_paths([root])

        assert directory_replaced
        assert socket_path.exists()
    finally:
        listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_rejects_socket_target_parent_swap(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    target_directory = root / "runtime-target"
    moved_directory = external_root / "runtime-target"
    socket_path = target_directory / "cvd.sock"
    (root / "socket-alias").symlink_to(socket_path)
    root_stat = os.stat(root, follow_symlinks=False)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    original_scandir = os.scandir
    original_stat = os.stat
    original_open_relative = experiment_support._open_relative_directory
    target_created = False
    target_replaced = False

    def replace_target_directory() -> None:
        nonlocal target_replaced
        os.rename(target_directory, moved_directory)
        target_directory.symlink_to(moved_directory, target_is_directory=True)
        target_replaced = True

    def snapshot_then_create_target(path: int | str | os.PathLike[str]):
        nonlocal target_created
        entries = list(original_scandir(path))
        if isinstance(path, int):
            is_audit_root = experiment_support._same_inode(
                root_stat,
                os.fstat(path),
            )
        else:
            is_audit_root = Path(path) == root
        if is_audit_root and not target_created:
            target_directory.mkdir()
            listener.bind(str(socket_path))
            target_created = True

        class EntrySnapshot:
            def __enter__(self):
                return iter(entries)

            def __exit__(self, *_: object) -> bool:
                return False

            def __iter__(self):
                return iter(entries)

        return EntrySnapshot()

    def racing_stat(path, *args, **kwargs):
        if (
            target_created
            and not target_replaced
            and kwargs.get("dir_fd") is None
            and kwargs.get("follow_symlinks") is False
            and Path(path) == socket_path
        ):
            replace_target_directory()
        return original_stat(path, *args, **kwargs)

    def racing_open_relative(parent_descriptor: int, relative_path: Path) -> int:
        descriptor = original_open_relative(parent_descriptor, relative_path)
        if (
            target_created
            and not target_replaced
            and relative_path == Path("runtime-target")
        ):
            replace_target_directory()
        return descriptor

    try:
        with monkeypatch.context() as patch:
            patch.setattr(
                experiment_support.os,
                "scandir",
                snapshot_then_create_target,
            )
            patch.setattr(experiment_support.os, "stat", racing_stat)
            patch.setattr(
                experiment_support,
                "_open_relative_directory",
                racing_open_relative,
            )
            with pytest.raises(ValueError, match="target directory changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert target_created
            assert target_replaced
            assert socket_path.exists()
    finally:
        listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


def test_unix_socket_audit_rechecks_target_parent_after_root_reopen(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    root = Path(tempfile.mkdtemp(prefix="a.", dir="/tmp")).resolve()
    external_root = Path(tempfile.mkdtemp(prefix="b.", dir="/tmp")).resolve()
    target_directory = root / "runtime-target"
    moved_directory = external_root / "runtime-target"
    socket_path = target_directory / "cvd.sock"
    (root / "socket-alias").symlink_to(socket_path)
    root_stat = os.stat(root, follow_symlinks=False)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    original_scandir = os.scandir
    original_open_directory_chain = experiment_support._open_directory_chain
    root_open_count = 0
    target_created = False
    target_replaced = False

    def replace_target_directory() -> None:
        nonlocal target_replaced
        os.rename(target_directory, moved_directory)
        target_directory.symlink_to(moved_directory, target_is_directory=True)
        target_replaced = True

    def snapshot_then_create_target(path: int | str | os.PathLike[str]):
        nonlocal target_created
        entries = list(original_scandir(path))
        if isinstance(path, int):
            is_audit_root = experiment_support._same_inode(
                root_stat,
                os.fstat(path),
            )
        else:
            is_audit_root = Path(path) == root
        if is_audit_root and not target_created:
            target_directory.mkdir()
            listener.bind(str(socket_path))
            target_created = True

        class EntrySnapshot:
            def __enter__(self):
                return iter(entries)

            def __exit__(self, *_: object) -> bool:
                return False

            def __iter__(self):
                return iter(entries)

        return EntrySnapshot()

    def replace_after_root_reopen(path: Path) -> int:
        nonlocal root_open_count
        descriptor = original_open_directory_chain(path)
        if path == root:
            root_open_count += 1
            if root_open_count == 2 and target_created:
                replace_target_directory()
        return descriptor

    try:
        with monkeypatch.context() as patch:
            patch.setattr(
                experiment_support.os,
                "scandir",
                snapshot_then_create_target,
            )
            patch.setattr(
                experiment_support,
                "_open_directory_chain",
                replace_after_root_reopen,
            )
            with pytest.raises(ValueError, match="target directory changed"):
                experiment_support.audit_unix_socket_paths([root])

            assert target_created
            assert target_replaced
            assert root_open_count == 2
            assert socket_path.exists()
    finally:
        listener.close()
        shutil.rmtree(root)
        shutil.rmtree(external_root)


@pytest.mark.skipif(sys.platform != "linux", reason="cleanup uses Linux renameat2")
def test_short_cvd_root_cleanup_requires_verification_and_preserves_outside_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.test123"
    work_root.mkdir(parents=True, mode=0o700)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    host_dir = tmp_path / "cuttlefish"
    (host_dir / "bin").mkdir(parents=True)
    (host_dir / "bin/cvd").write_text("Cuttlefish executable fixture\n")
    state_root = tmp_path / "cvd-state"
    state_root.mkdir()
    physical_tmp = Path(os.path.realpath("/tmp"))
    root = physical_tmp / f"x.{secrets.token_hex(3)}"
    root.mkdir(mode=0o700)
    temporary = root / "t"
    temporary.mkdir(mode=0o700)
    runtime_data = temporary / "cf_avd_501/cvd-1"
    runtime_data.mkdir(parents=True)
    (runtime_data / "stale.sock").write_text("private runtime data")
    outside_file = tmp_path / "outside.txt"
    outside_file.write_text("preserve")
    outside_link = temporary / "outside-link"
    outside_link.symlink_to(outside_file)
    (root / ".apkrun-cvd-short-home").write_text(
        f"APKRun Cuttlefish short HOME v1\n{ownership_token}\n{work_root}\n{root}\n",
        encoding="utf-8",
    )
    (root / ".apkrun-cvd-short-home").chmod(0o600)
    socket_metrics = work_root / "capture-socket-paths.json"
    socket_metrics.write_text(
        json.dumps(
            {
                "capacityBytes": 108,
                "terminatingNulBytes": 1,
                "socketCount": 0,
                "maxEncodedPathBytes": 0,
                "maxSunPathBytesIncludingNul": 0,
            }
        ),
        encoding="utf-8",
    )
    arguments = (
        root,
        work_root,
        data_root,
        ownership_token,
        host_dir,
        state_root,
        socket_metrics,
    )

    def process_remains(*_args: object, **_kwargs: object) -> int:
        raise ValueError("a Cuttlefish host process still references the private HOME")

    monkeypatch.setattr(
        experiment_support,
        "require_no_private_cvd_processes",
        process_remains,
    )
    with pytest.raises(ValueError, match="still references"):
        experiment_support.discard_short_cvd_home_root(*arguments)
    assert (runtime_data / "stale.sock").read_text(encoding="utf-8") == (
        "private runtime data"
    )

    monkeypatch.setattr(
        experiment_support,
        "require_no_private_cvd_processes",
        lambda *_args, **_kwargs: 0,
    )
    experiment_support.discard_short_cvd_home_root(*arguments)
    assert not root.exists()
    assert not outside_link.exists()
    assert not outside_link.is_symlink()
    assert outside_file.read_text(encoding="utf-8") == "preserve"


def _write_fake_cvd_process(
    proc_root: Path,
    host_dir: Path,
    home: Path,
    tmpdir: Path,
    *,
    pid: int = 321,
    comm: str = "cvd",
    executable_path: Path | None = None,
) -> Path:
    executable = executable_path or host_dir / "bin/cvd"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_text("pinned Cuttlefish executable fixture\n", encoding="utf-8")
    process = proc_root / str(pid)
    process.mkdir(parents=True)
    (process / "exe").symlink_to(executable)
    (process / "comm").write_text(f"{comm}\n", encoding="utf-8")
    (process / "cmdline").write_bytes(b"")
    (process / "cwd").symlink_to("/")
    (process / "fd").mkdir()
    (process / "environ").write_bytes(
        b"HOME=" + os.fsencode(home) + b"\0TMPDIR=" + os.fsencode(tmpdir) + b"\0"
    )
    uid = os.getuid()
    (process / "status").write_text(
        f"Name:\t cvd\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n",
        encoding="ascii",
    )
    stat_fields = ["S", *("0" for _ in range(18)), "98765"]
    (process / "stat").write_text(
        f"{pid} (cvd) {' '.join(stat_fields)}\n",
        encoding="ascii",
    )
    return process


def _write_fake_systemd_user_manager(
    proc_root: Path,
    executable_path: Path,
    *,
    pid: int,
) -> Path:
    executable_path.parent.mkdir(parents=True, exist_ok=True)
    executable_path.write_text("systemd executable fixture\n", encoding="utf-8")
    executable_path.chmod(0o755)
    process = proc_root / str(pid)
    process.mkdir(parents=True)
    (process / "exe").symlink_to(executable_path)
    (process / "comm").write_text("systemd\n", encoding="utf-8")
    (process / "cmdline").write_bytes(
        b"/usr/lib/systemd/systemd\0--user\0--deserialize=8\0"
    )
    (process / "cwd").symlink_to("/")
    (process / "fd").mkdir()
    (process / "environ").write_bytes(b"HOME=/home/systemd\0TMPDIR=/tmp\0")
    (process / "cgroup").write_text(
        f"0::/user.slice/user-{os.getuid()}.slice/"
        f"user@{os.getuid()}.service/init.scope\n",
        encoding="ascii",
    )
    (process / "status").write_text(
        f"Name:\t systemd\nUid:\t{os.getuid()}\t{os.getuid()}\t"
        f"{os.getuid()}\t{os.getuid()}\n",
        encoding="ascii",
    )
    stat_fields = ["S", "1", *("0" for _ in range(17)), "98764"]
    (process / "stat").write_text(
        f"{pid} (systemd) {' '.join(stat_fields)}\n",
        encoding="ascii",
    )
    return process


def _write_fake_process_stat(
    proc_root: Path,
    process_id: int,
    parent_id: int,
    start_time: int,
) -> None:
    process_directory = proc_root / str(process_id)
    process_directory.mkdir(parents=True, exist_ok=True)
    stat_fields = ["S", str(parent_id), *("0" for _ in range(17)), str(start_time)]
    (process_directory / "stat").write_text(
        f"{process_id} (ancestor) {' '.join(stat_fields)}\n",
        encoding="ascii",
    )


def test_process_ancestor_walk_records_a_consistent_parent_chain(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_fake_process_stat(tmp_path, 100, 200, 1000)
    _write_fake_process_stat(tmp_path, 200, 1, 2000)
    _write_fake_process_stat(tmp_path, 1, 0, 3000)
    monkeypatch.setattr(experiment_support.os, "getpid", lambda: 100)

    assert experiment_support._process_ancestor_start_times(tmp_path) == {
        100: "1000",
        200: "2000",
        1: "3000",
    }


def test_process_ancestor_walk_rejects_a_parent_link_change_during_audit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_fake_process_stat(tmp_path, 100, 200, 1000)
    _write_fake_process_stat(tmp_path, 200, 1, 2000)
    _write_fake_process_stat(tmp_path, 1, 0, 3000)
    read_process_state = experiment_support._process_state_and_start_time
    current_process_reads = 0

    def change_parent_link(process_directory: Path) -> tuple[str, str, int] | None:
        nonlocal current_process_reads
        state = read_process_state(process_directory)
        if process_directory.name == "100":
            current_process_reads += 1
            if current_process_reads == 2:
                _write_fake_process_stat(tmp_path, 200, 300, 2000)
        return state

    monkeypatch.setattr(experiment_support.os, "getpid", lambda: 100)
    monkeypatch.setattr(
        experiment_support,
        "_process_state_and_start_time",
        change_parent_link,
    )

    with pytest.raises(ValueError, match="ancestry links changed during audit"):
        experiment_support._process_ancestor_start_times(tmp_path)


def _trust_fake_systemd_fixture(
    monkeypatch: pytest.MonkeyPatch,
    executable_path: Path,
) -> None:
    trusted_identity = executable_path.stat()

    def is_fixture_systemd(executable: str) -> bool:
        try:
            executable_status = Path(executable.removesuffix(" (deleted)")).stat()
        except OSError:
            return False
        return (
            executable_status.st_dev == trusted_identity.st_dev
            and executable_status.st_ino == trusted_identity.st_ino
        )

    monkeypatch.setattr(
        experiment_support,
        "_is_trusted_systemd_executable",
        is_fixture_systemd,
    )


def _set_fake_process_parent(process: Path, parent_pid: int) -> None:
    contents = (process / "stat").read_text(encoding="ascii")
    closing_parenthesis = contents.rfind(")")
    fields = contents[closing_parenthesis + 1 :].split()
    fields[1] = str(parent_pid)
    (process / "stat").write_text(
        f"{process.name} (cvd) {' '.join(fields)}\n",
        encoding="ascii",
    )


def test_private_cvd_process_check_blocks_home_cleanup_until_process_exits(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
    )

    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )

    process.rename(proc_root / "other-user")
    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )


def test_private_cvd_process_check_detects_open_home_reference(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
    )
    (process / "environ").write_bytes(b"HOME=/home/user\0TMPDIR=/tmp\0")
    (process / "cmdline").write_bytes(b"/opt/cuttlefish/bin/cvd\0")
    descriptors = process / "fd"
    descriptors.mkdir(exist_ok=True)
    (descriptors / "3").symlink_to(home_root / "state.sock")

    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


def test_private_cvd_process_scan_ignores_process_exiting_before_environment_read(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=324,
        comm="sleep",
    )
    read_process_environment = experiment_support._process_environment

    def process_exited(process_directory: Path) -> dict[bytes, bytes]:
        if process_directory == process:
            process.rename(proc_root / "exited-sleep")
        return read_process_environment(process_directory)

    monkeypatch.setattr(
        experiment_support,
        "_process_environment",
        process_exited,
    )

    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )


def test_private_cvd_process_scan_fails_closed_for_live_process_missing_environment(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=325,
        comm="sleep",
    )
    (process / "environ").unlink()

    with pytest.raises(
        ValueError,
        match="live Cuttlefish process has an unreadable entry",
    ):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


def test_private_cvd_process_scan_rejects_pid_reuse_during_environment_read(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=326,
        comm="sleep",
    )
    read_process_environment = experiment_support._process_environment

    def reuse_process_id(process_directory: Path) -> dict[bytes, bytes]:
        if process_directory == process:
            process.rename(proc_root / "exited-sleep")
            replacement = _write_fake_cvd_process(
                proc_root,
                host_dir,
                tmp_path / "replacement-home",
                tmp_path / "replacement-tmp",
                pid=326,
                comm="sleep",
            )
            stat_fields = ["S", *("0" for _ in range(18)), "98766"]
            (replacement / "stat").write_text(
                f"326 (sleep) {' '.join(stat_fields)}\n",
                encoding="ascii",
            )
            raise FileNotFoundError("simulated PID reuse during proc scan")
        return read_process_environment(process_directory)

    monkeypatch.setattr(
        experiment_support,
        "_process_environment",
        reuse_process_id,
    )

    with pytest.raises(ValueError, match="identity changed during audit"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


def test_private_cvd_process_scan_uses_pidfd_when_start_time_is_reused(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    process = _write_fake_cvd_process(
        tmp_path / "proc",
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=328,
        comm="sleep",
    )
    process_pidfd, pidfd_writer = os.pipe()
    try:
        os.write(pidfd_writer, b"exited")

        with pytest.raises(ValueError, match="PID was reused during audit"):
            experiment_support._process_is_gone_or_changed(
                process,
                "98765",
                process_pidfd,
            )
    finally:
        os.close(process_pidfd)
        os.close(pidfd_writer)


def test_private_cvd_process_scan_fails_closed_when_live_pidfd_loses_proc_entry(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    process = _write_fake_cvd_process(
        tmp_path / "proc",
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=329,
        comm="sleep",
    )
    process_pidfd, pidfd_writer = os.pipe()
    process.rename(process.parent / "exited-sleep")
    try:
        with pytest.raises(
            ValueError,
            match="live Cuttlefish process through /proc",
        ):
            experiment_support._process_is_gone_or_changed(
                process,
                "98765",
                process_pidfd,
            )
        os.write(pidfd_writer, b"exited")
        assert experiment_support._process_is_gone_or_changed(
            process,
            "98765",
            process_pidfd,
        )
    finally:
        os.close(process_pidfd)
        os.close(pidfd_writer)


@pytest.mark.parametrize("pre_pin_state", ("zombie", "foreign-owner"))
def test_private_cvd_process_scan_pins_before_excluding_process(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    pre_pin_state: str,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process_id = 982_341
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=process_id,
        comm="sleep",
    )
    if pre_pin_state == "zombie":
        stat_fields = ["Z", *("0" for _ in range(18)), "98765"]
        (process / "stat").write_text(
            f"{process_id} (sleep) {' '.join(stat_fields)}\n",
            encoding="ascii",
        )
    else:
        (process / "status").write_text(
            f"Name:\tsleep\nUid:\t{os.getuid() + 1}\t"
            f"{os.getuid() + 1}\t{os.getuid() + 1}\t{os.getuid() + 1}\n",
            encoding="ascii",
        )
    process_pidfd, pidfd_writer = os.pipe()
    ancestry_scan_pidfd_modes: list[bool] = []

    def pin_replacement_process(pid: int, flags: int) -> int:
        assert pid == process_id
        assert flags == 0
        stat_fields = ["S", *("0" for _ in range(18)), "98765"]
        (process / "stat").write_text(
            f"{process_id} (sleep) {' '.join(stat_fields)}\n",
            encoding="ascii",
        )
        (process / "status").write_text(
            f"Name:\tsleep\nUid:\t{os.getuid()}\t{os.getuid()}\t"
            f"{os.getuid()}\t{os.getuid()}\n",
            encoding="ascii",
        )
        return os.dup(process_pidfd)

    def scan_ancestors(
        _process_root: Path,
        *,
        use_pidfds: bool = False,
    ) -> dict[int, str | None]:
        ancestry_scan_pidfd_modes.append(use_pidfds)
        return {os.getpid(): None}

    monkeypatch.setattr(
        experiment_support,
        "_process_root_uses_pidfds",
        lambda _process_root: True,
    )
    monkeypatch.setattr(
        experiment_support,
        "_process_ancestor_start_times",
        scan_ancestors,
    )
    monkeypatch.setattr(
        experiment_support.os,
        "pidfd_open",
        pin_replacement_process,
        raising=False,
    )

    try:
        with pytest.raises(ValueError, match="still references the private HOME"):
            experiment_support.require_no_private_cvd_processes(
                host_dir,
                home_root,
                tmpdir_root,
                proc_root,
            )
    finally:
        os.close(process_pidfd)
        os.close(pidfd_writer)
    assert ancestry_scan_pidfd_modes == [True, True]


@pytest.mark.parametrize("process_state", ("Z", "X"))
def test_private_cvd_process_scan_ignores_verified_exited_process_states(
    tmp_path: Path,
    process_state: str,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=327,
        comm="sleep",
    )
    stat_fields = [process_state, *("0" for _ in range(18)), "98765"]
    (process / "stat").write_text(
        f"327 (sleep) {' '.join(stat_fields)}\n",
        encoding="ascii",
    )

    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )


def test_private_cvd_process_check_includes_external_cvd_helpers(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    (host_dir / "bin").mkdir()
    (host_dir / "bin/cvd").write_text("Cuttlefish executable fixture\n")
    helper_binary = tmp_path / "external" / "python3"
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=322,
        comm="python3",
        executable_path=helper_binary,
    )

    assert "python3" not in experiment_support._host_package_process_names(host_dir)
    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )

    process.rename(proc_root / "exited-helper")
    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )


def test_private_cvd_process_check_skips_its_own_ancestry_only(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    monkeypatch.setattr(experiment_support.os, "getpid", lambda: 400)

    current_process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=400,
        comm="bash",
    )
    parent_process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=401,
        comm="bash",
    )
    stat_fields = (current_process / "stat").read_text(encoding="ascii").split()
    stat_fields[3] = "401"
    (current_process / "stat").write_text(
        "400 (bash) " + " ".join(stat_fields[2:]) + "\n",
        encoding="ascii",
    )
    external_helper = _write_fake_cvd_process(
        proc_root,
        host_dir,
        home_root,
        tmpdir_root,
        pid=402,
        comm="python3",
        executable_path=tmp_path / "external/python3",
    )

    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )

    external_helper.rename(proc_root / "exited-helper")
    assert parent_process.is_dir()
    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )


def test_external_cvd_helper_open_descriptor_blocks_home_cleanup(
    tmp_path: Path,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    (host_dir / "bin").mkdir()
    (host_dir / "bin/cvd").write_text("Cuttlefish executable fixture\n")
    helper = _write_fake_cvd_process(
        proc_root,
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=323,
        comm="python3",
        executable_path=tmp_path / "external/python3",
    )
    (helper / "environ").write_bytes(b"HOME=/home/user\0TMPDIR=/tmp\0")
    (helper / "fd/3").symlink_to(tmpdir_root / "runtime.sock")

    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


def test_process_scan_skips_only_systemd_session_pam_on_environment_denial(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    (host_dir / "bin").mkdir()
    (host_dir / "bin/cvd").write_text("Cuttlefish executable fixture\n")
    systemd_executable = host_dir / "bin/systemd"
    parent = _write_fake_systemd_user_manager(
        proc_root,
        systemd_executable,
        pid=9001,
    )
    monkeypatch.setattr(
        experiment_support,
        "SYSTEMD_EXECUTABLE_PATHS",
        (systemd_executable,),
    )
    _trust_fake_systemd_fixture(monkeypatch, systemd_executable)
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=324,
        comm="sd-pam",
        executable_path=systemd_executable,
    )
    _set_fake_process_parent(process, int(parent.name))
    (process / "cmdline").write_bytes(b"(sd-pam)\0")
    (process / "cgroup").write_text(
        f"0::/user.slice/user-{os.getuid()}.slice/"
        f"user@{os.getuid()}.service/init.scope\n",
        encoding="ascii",
    )

    read_process_environment = experiment_support._process_environment

    def environment_denied(process_directory: Path) -> dict[bytes, bytes]:
        if process_directory == process:
            raise PermissionError("environment is protected")
        return read_process_environment(process_directory)

    monkeypatch.setattr(
        experiment_support,
        "_process_environment",
        environment_denied,
    )
    assert (
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
        == 0
    )

    (process / "exe").unlink()
    (process / "exe").symlink_to(host_dir / "bin/cvd")
    with pytest.raises(
        ValueError, match="could not verify a Cuttlefish process environment"
    ):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )
    (process / "exe").unlink()
    (process / "exe").symlink_to(systemd_executable)

    (process / "cgroup").write_text(
        f"0::/user.slice/user-{os.getuid()}.slice/session-1.scope\n",
        encoding="ascii",
    )
    with pytest.raises(
        ValueError, match="could not verify a Cuttlefish process environment"
    ):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )

    (process / "cgroup").write_text(
        f"0::/user.slice/user-{os.getuid()}.slice/"
        f"user@{os.getuid()}.service/init.scope\n",
        encoding="ascii",
    )
    (process / "cmdline").write_bytes(b"bash\0--user\0")
    with pytest.raises(
        ValueError, match="could not verify a Cuttlefish process environment"
    ):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )

    (process / "comm").write_text("python3\n", encoding="utf-8")
    with pytest.raises(
        ValueError, match="could not verify a Cuttlefish process environment"
    ):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


def test_trusted_systemd_executable_rejects_user_controlled_path(
    tmp_path: Path,
) -> None:
    executable = tmp_path / "systemd"
    executable.write_text("untrusted systemd fixture\n", encoding="utf-8")
    executable.chmod(0o755)

    assert not experiment_support._is_trusted_systemd_executable(str(executable))


@pytest.mark.parametrize("reference_kind", ["cmdline", "cwd", "fd"])
def test_systemd_session_pam_reference_blocks_cleanup_when_environment_is_denied(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    reference_kind: str,
) -> None:
    host_dir = tmp_path / "cuttlefish"
    host_dir.mkdir()
    home_root = tmp_path / "h.abcdef"
    home_root.mkdir()
    tmpdir_root = tmp_path / "t"
    tmpdir_root.mkdir()
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    systemd_executable = host_dir / "bin/systemd"
    parent = _write_fake_systemd_user_manager(
        proc_root,
        systemd_executable,
        pid=9002,
    )
    monkeypatch.setattr(
        experiment_support,
        "SYSTEMD_EXECUTABLE_PATHS",
        (systemd_executable,),
    )
    _trust_fake_systemd_fixture(monkeypatch, systemd_executable)
    process = _write_fake_cvd_process(
        proc_root,
        host_dir,
        tmp_path / "other-home",
        tmp_path / "other-tmp",
        pid=325,
        comm="sd-pam",
        executable_path=systemd_executable,
    )
    _set_fake_process_parent(process, int(parent.name))
    (process / "cmdline").write_bytes(b"(sd-pam)\0")
    (process / "cgroup").write_text(
        f"0::/user.slice/user-{os.getuid()}.slice/"
        f"user@{os.getuid()}.service/init.scope\n",
        encoding="ascii",
    )
    if reference_kind == "cmdline":
        (process / "cmdline").write_bytes(
            b"(sd-pam)\0" + os.fsencode(home_root) + b"\0"
        )
    elif reference_kind == "cwd":
        (process / "cwd").unlink()
        (process / "cwd").symlink_to(home_root)
    else:
        (process / "fd/3").symlink_to(home_root / "state.sock")

    read_process_environment = experiment_support._process_environment

    def environment_denied(process_directory: Path) -> dict[bytes, bytes]:
        if process_directory == process:
            raise PermissionError("environment is protected")
        return read_process_environment(process_directory)

    monkeypatch.setattr(
        experiment_support,
        "_process_environment",
        environment_denied,
    )

    with pytest.raises(ValueError, match="still references the private HOME"):
        experiment_support.require_no_private_cvd_processes(
            host_dir,
            home_root,
            tmpdir_root,
            proc_root,
        )


@pytest.mark.parametrize("control_character", ["\n", "\u0085"])
def test_prepare_data_root_rejects_paths_with_control_characters(
    tmp_path: Path,
    control_character: str,
) -> None:
    unsafe_root = tmp_path / f"diagnostics{control_character}"

    with pytest.raises(ValueError, match="control characters"):
        experiment_support.prepare_private_data_root(unsafe_root)

    assert not unsafe_root.exists()


def test_parse_fleet_report_requires_empty_fleet_and_identity() -> None:
    report = (
        "cvd(57044) I version: 1.57.0 | "
        "VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n'
    )

    assert experiment_support.parse_fleet_report(report) == {
        "packageVersion": "1.57.0",
        "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
    }


def test_parse_fleet_report_rejects_running_groups() -> None:
    report = (
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [{"name": "unexpected"}] }\n'
    )

    with pytest.raises(ValueError, match="must be empty"):
        experiment_support.parse_fleet_report(report)


def test_parse_fleet_report_rejects_unexpected_trailing_content() -> None:
    report = (
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n'
        "unexpected trailing output\n"
    )

    with pytest.raises(ValueError, match="unexpected trailing content"):
        experiment_support.parse_fleet_report(report)


@pytest.mark.parametrize(
    "gpu_mode",
    ("none", "guest_swiftshader"),
)
@pytest.mark.parametrize(
    ("console_enabled", "pause_in_bootloader"),
    ((True, False), (False, False), (True, True)),
)
def test_private_capture_patch_changes_gpu_adb_console_bootloader_and_logcat_capture(
    tmp_path: Path,
    gpu_mode: str,
    console_enabled: bool,
    pause_in_bootloader: bool,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    private_copy.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")

    experiment_support.patch_capture_script(
        private_copy,
        gpu_mode,
        console_enabled,
        pause_in_bootloader,
    )
    patched = private_copy.read_text(encoding="utf-8")
    console_argument = str(console_enabled).lower()
    pause_argument = " --pause_in_bootloader=true" if pause_in_bootloader else ""

    subprocess.run(["bash", "-n", str(private_copy)], check=True)
    assert "script_dir=$APKRUN_CAPTURE_SCRIPT_DIR" in patched
    assert "capture_boot_observer=0" in patched
    assert "capture_boot_observer=${APKRUN_CAPTURE_BOOT_OBSERVER:-0}" not in patched
    assert 'PATH="$APKRUN_DIAGNOSTIC_ADB_SHIM_DIR:$CVD_HOST_DIR/bin:$PATH"' in patched
    assert "${APKRUN_CVD_HOME_TMPDIR:-${TMPDIR:-/tmp}}/h.XXXXXX" in patched
    assert (
        f"create_cvd_group_with_common_options --gpu_mode={gpu_mode} "
        f"--gpu_vhost_user_mode=off --console={console_argument}"
        f"{pause_argument} "
        "--cpus 4 --memory_mb 4096" in patched
    )
    assert "--timeout-seconds 30 --max-bytes 8388608" in patched
    assert '--output "$raw_log"' in patched
    assert "--max-bytes 1048576" in patched
    assert "--stdin --drain-after-limit --max-bytes 8388608" in patched
    assert "capture_adb_value 4096 10 adb devices" in patched
    assert "capture_adb_value 256 10 adb -s" in patched
    assert "record_adb_helper_cleanup" in patched
    assert "adb-helper-cleanup-incomplete.json" in patched
    assert "check-cvd-processes --host-dir" in patched
    assert "audit-unix-sockets --root" in patched
    assert "Cuttlefish HOME retained" in patched
    assert 'capture_adb_value 4096 10 adb connect "127.0.0.1:$adb_port"' in patched
    assert 'capture_adb_value 4096 10 adb -s "$adb_serial" wait-for-device' in patched
    assert "start_cvd_group_with_gpu_mode() {" in patched
    assert "run_with_boot_deadline adb" not in patched
    assert "--fail-on-truncate --output" in patched
    assert "set -euo pipefail" in patched
    assert f"--boot_timeout_secs=$timeout_seconds{pause_argument}" in patched
    default_gpu_mode_arguments = [
        line.strip()
        for line in patched.splitlines()
        if line.strip().startswith(
            (
                "start --gpu_mode=",
                "create_cvd_group_with_common_options --gpu_mode=",
            )
        )
    ]
    assert default_gpu_mode_arguments == [
        (
            f"start --gpu_mode={gpu_mode} --gpu_vhost_user_mode=off "
            f"--console={console_argument} \\"
        ),
        (
            "create_cvd_group_with_common_options "
            f"--gpu_mode={gpu_mode} --gpu_vhost_user_mode=off "
            f"--console={console_argument}{pause_argument} "
            "--cpus 4 --memory_mb 4096"
        ),
    ]
    assert patched.count(f"--console={console_argument}") == 2
    assert patched.count("--pause_in_bootloader=true") == (
        2 if pause_in_bootloader else 0
    )
    if pause_in_bootloader:
        assert patched.index(
            "start_cvd_group_with_bootloader_console() {"
        ) < patched.index("start_cvd_group_with_bootloader_console 2>&1")
        assert "&& ! start_cvd_group_with_gpu_mode 2>&1" not in patched
    else:
        assert patched.index("start_cvd_group_with_gpu_mode() {") < patched.index(
            "&& ! start_cvd_group_with_gpu_mode 2>&1"
        )
    assert (
        "default)\n      create_cvd_group_with_common_options --cpus 4 --memory_mb 4096"
        not in patched
    )


def test_private_capture_patch_rejects_unsupported_gpu_mode_before_writing(
    tmp_path: Path,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    original = source.read_bytes()
    private_copy.write_bytes(original)

    with pytest.raises(ValueError, match="GPU mode must be one of"):
        experiment_support.patch_capture_script(private_copy, "gpu_vulkan")

    assert private_copy.read_bytes() == original


@pytest.mark.parametrize("console_enabled", (1, None, "false"))
def test_private_capture_patch_rejects_non_boolean_console_selection(
    tmp_path: Path,
    console_enabled: object,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    original = source.read_bytes()
    private_copy.write_bytes(original)

    with pytest.raises(ValueError, match="console-enabled selection must be a boolean"):
        experiment_support.patch_capture_script(
            private_copy,
            "guest_swiftshader",
            console_enabled,
        )

    assert private_copy.read_bytes() == original


@pytest.mark.parametrize("pause_in_bootloader", (1, None, "false"))
def test_private_capture_patch_rejects_non_boolean_bootloader_pause(
    tmp_path: Path,
    pause_in_bootloader: object,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    original = source.read_bytes()
    private_copy.write_bytes(original)

    with pytest.raises(
        ValueError,
        match="bootloader-pause selection must be a boolean",
    ):
        experiment_support.patch_capture_script(
            private_copy,
            "guest_swiftshader",
            True,
            pause_in_bootloader,
        )

    assert private_copy.read_bytes() == original


def test_private_capture_patch_rejects_pause_when_console_is_disabled(
    tmp_path: Path,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    original = source.read_bytes()
    private_copy.write_bytes(original)

    with pytest.raises(
        ValueError,
        match="bootloader pause requires the Cuttlefish console to be enabled",
    ):
        experiment_support.patch_capture_script(
            private_copy,
            "none",
            False,
            True,
        )

    assert private_copy.read_bytes() == original


@pytest.mark.parametrize("value", (True, 119, 601, 0, "180", None))
def test_boot_timeout_rejects_values_outside_diagnostic_range(value: object) -> None:
    with pytest.raises(ValueError, match="integer between 120 and 600 seconds"):
        experiment_support._validate_boot_timeout_seconds(value)


@pytest.mark.parametrize("value", (120, 180, 600))
def test_boot_timeout_accepts_values_inside_diagnostic_range(value: int) -> None:
    assert experiment_support._validate_boot_timeout_seconds(value) == value


@pytest.mark.skipif(sys.platform != "linux", reason="GPU-none capture runs on Linux")
@pytest.mark.parametrize(
    "gpu_mode",
    ("none", "guest_swiftshader"),
)
@pytest.mark.parametrize(
    ("console_enabled", "pause_in_bootloader"),
    ((True, False), (False, False), (True, True)),
)
@pytest.mark.parametrize(
    ("persisted_vhost_user", "start_exit_code", "expected_capture_failure"),
    ((False, 0, 0), (True, 0, 0), (False, 17, 1)),
)
def test_gpu_mode_launch_pipeline_passes_flags_and_checks_the_saved_config(
    tmp_path: Path,
    gpu_mode: str,
    console_enabled: bool,
    pause_in_bootloader: bool,
    persisted_vhost_user: bool,
    start_exit_code: int,
    expected_capture_failure: int,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    private_copy.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    experiment_support.patch_capture_script(
        private_copy,
        gpu_mode,
        console_enabled,
        pause_in_bootloader,
    )
    patched = private_copy.read_text(encoding="utf-8")

    def extract_shell_function(function_name: str) -> str:
        function_start = patched.index(f"{function_name}() {{")
        function_end = patched.index("\n}", function_start) + 2
        return patched[function_start:function_end]

    fake_bin = tmp_path / "bin's directory"
    fake_bin.mkdir()
    fake_cvd = fake_bin / "cvd"
    fake_cvd.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
if arguments[0] == "logs":
    raise SystemExit(0)
with Path(os.environ["APKRUN_TEST_CVD_CALLS"]).open(
    "a", encoding="utf-8"
) as stream:
    stream.write(json.dumps(arguments) + "\\n")
config = Path(os.environ["APKRUN_TEST_CONFIG_PATH"])
if arguments[0] == "create":
    if config.exists():
        raise SystemExit("cvd create --nostart unexpectedly produced a config")
elif "start" in arguments:
    calls = [
        json.loads(line)
        for line in Path(os.environ["APKRUN_TEST_CVD_CALLS"])
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    create_arguments = calls[0]
    create_gpu_modes = [
        value.split("=", 1)[1]
        for value in create_arguments
        if value.startswith("--gpu_mode=")
    ]
    start_gpu_modes = [
        value.split("=", 1)[1]
        for value in arguments
        if value.startswith("--gpu_mode=")
    ]
    gpu_mode_selected = (
        len(create_gpu_modes) == 1
        and len(start_gpu_modes) == 1
        and create_gpu_modes[0] == start_gpu_modes[0]
        and create_gpu_modes[0] == os.environ["APKRUN_TEST_GPU_MODE"]
    )
    vhost_user_disabled = (
        "--gpu_vhost_user_mode=off" in create_arguments
        and "--gpu_vhost_user_mode=off" in arguments
    )
    create_console_settings = [
        value.split("=", 1)[1]
        for value in create_arguments
        if value.startswith("--console=")
    ]
    start_console_settings = [
        value.split("=", 1)[1]
        for value in arguments
        if value.startswith("--console=")
    ]
    console_selected = (
        len(create_console_settings) == 1
        and len(start_console_settings) == 1
        and create_console_settings[0] == start_console_settings[0]
        and create_console_settings[0]
        == os.environ["APKRUN_TEST_CONSOLE_ENABLED"]
    )
    create_pause_settings = [
        value.split("=", 1)[1]
        for value in create_arguments
        if value.startswith("--pause_in_bootloader=")
    ]
    start_pause_settings = [
        value.split("=", 1)[1]
        for value in arguments
        if value.startswith("--pause_in_bootloader=")
    ]
    expected_pause_value = "true" if (
        os.environ["APKRUN_TEST_PAUSE_IN_BOOTLOADER"] == "true"
    ) else None
    pause_selected = (
        create_pause_settings == (
            [expected_pause_value] if expected_pause_value is not None else []
        )
        and start_pause_settings == (
            [expected_pause_value] if expected_pause_value is not None else []
        )
    )
    saved_pause_setting = (
        expected_pause_value is not None and pause_selected
    )
    saved_console_setting = (
        create_console_settings[0] == "true"
        if len(create_console_settings) == 1
        else None
    )
    config.parent.mkdir(parents=True)
    config.write_text(
        json.dumps(
            {
                "instances": {
                    "1": {
                        "gpu_mode": (
                            os.environ["APKRUN_TEST_GPU_MODE"]
                            if gpu_mode_selected
                            else "unexpected"
                        ),
                        "enable_gpu_vhost_user": (
                            os.environ["APKRUN_TEST_VHOST_USER"] == "true"
                            or not vhost_user_disabled
                        ),
                        "console": saved_console_setting,
                        "pause_in_bootloader": saved_pause_setting,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    raise SystemExit(int(os.environ["APKRUN_TEST_START_EXIT_CODE"]))
else:
    raise SystemExit("unexpected fake Cuttlefish command")
""",
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)

    runtime_root = tmp_path / "runtime"
    config_path = runtime_root / "instances/cvd-1/cuttlefish_config.json"
    calls_path = tmp_path / "cvd-calls.jsonl"
    tool_directory = tmp_path / "tool's directory"
    tool_directory.mkdir()
    shutil.copyfile(
        repo_root / "Images/tools/reference/capture_cvd_start.py",
        tool_directory / "capture_cvd_start.py",
    )
    shutil.copyfile(
        repo_root / "Experiments/cuttlefish-boot-diagnosis/capture_bounded.py",
        tool_directory / "capture_bounded.py",
    )
    shutil.copyfile(
        repo_root / "Experiments/cuttlefish-boot-diagnosis/capture_processes.py",
        tool_directory / "capture_processes.py",
    )
    shutil.copyfile(
        repo_root / "Experiments/cuttlefish-boot-diagnosis/run_cvd_with_console.py",
        tool_directory / "run_cvd_with_console.py",
    )
    fake_bootloader_helper = tool_directory / "drive_cuttlefish_console.py"
    fake_bootloader_helper.write_text(
        """import json
import sys
from pathlib import Path

arguments = sys.argv[1:]
result = Path(arguments[arguments.index("--result") + 1])
result.write_text(
    json.dumps(
        {
            "schemaVersion": 3,
            "consoleEndpointFound": True,
            "screenStarted": True,
            "uBootBannerObserved": True,
            "promptObserved": True,
            "bootCommandSent": True,
            "kernelHandoffObserved": True,
            "outputBytesObserved": 64,
            "escapeStrippedBytesObserved": 64,
            "escapeSequenceIncomplete": False,
            "outputLimitBytes": 65536,
            "outputTruncated": False,
            "timedOut": False,
            "handoffTimedOut": False,
            "screenExitCode": 0,
            "signal": None,
            "cleanupComplete": True,
            "cleanupFailure": None,
            "cleanupErrorNumber": None,
            "exitCode": 0,
        }
    ),
    encoding="utf-8",
)
""",
        encoding="utf-8",
    )
    stage = tmp_path / "stage"
    stage.mkdir()
    stage.chmod(0o700)
    cvd_home = tmp_path / "cvd-home"
    cvd_home.mkdir()
    cvd_home.chmod(0o700)
    status_root = tmp_path / "status"
    status_root.mkdir()
    capture_status_path = tmp_path / "capture-failure-status"
    harness = tmp_path / "run-patched-launch-block.sh"
    launch_block_start = patched.index(': > "$stage/cvd-create-console.log"\n')
    launch_block_end = patched.index(
        'if [ "$cvd_command_failed" -ne 0 ]; then\n',
        launch_block_start,
    )
    launch_block = patched[launch_block_start:launch_block_end]
    harness.write_text(
        "\n".join(
            (
                "#!/usr/bin/env bash",
                "set -euo pipefail",
                f"PATH={shlex.quote(str(fake_bin))}:$PATH",
                f"script_dir={shlex.quote(str(tool_directory))}",
                f"runtime_root={shlex.quote(str(runtime_root))}",
                f"private_product_out={shlex.quote(str(tmp_path / 'product'))}",
                f"CVD_HOST_DIR={shlex.quote(str(tmp_path / 'host'))}",
                    "cvd_group_name=apkrun_test",
                    "cvd_instance_num=1",
                    f"stage={shlex.quote(str(stage))}",
                    f"cvd_home={shlex.quote(str(cvd_home))}",
                    "timeout_seconds=30",
                    "boot_timeout_deadline=$(($(date +%s) + 30))",
                "boot_deadline_expired=0",
                f"APKRUN_EXPERIMENT_STATUS_ROOT={shlex.quote(str(status_root))}",
                f"APKRUN_EXPERIMENT_TOOLS={shlex.quote(str(tool_directory))}",
                (
                    "APKRUN_EXPERIMENT_BOOTLOADER_SUMMARY="
                    f"{shlex.quote(str(tmp_path / 'bootloader-console-summary.json'))}"
                ),
                (
                    "APKRUN_EXPERIMENT_BOOTLOADER_SUMMARY_ROOT="
                    f"{shlex.quote(str(tmp_path))}"
                ),
                'record_missing() { printf \'%s\\t%s\\n\' "$1" "$2"; }',
                extract_shell_function("create_cvd_group_with_common_options"),
                extract_shell_function("launch_profile"),
                extract_shell_function("start_cvd_group_with_gpu_mode"),
                *(
                    [extract_shell_function("start_cvd_group_with_bootloader_console")]
                    if pause_in_bootloader
                    else []
                ),
                extract_shell_function("run_cvd_command_with_live_logs"),
                "profile=default",
                launch_block,
                f"printf '%s\\n' \"$cvd_command_failed\" > {shlex.quote(str(capture_status_path))}",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    harness.chmod(0o755)

    environment = {
        **os.environ,
        "APKRUN_TEST_CVD_CALLS": str(calls_path),
        "APKRUN_TEST_CONFIG_PATH": str(config_path),
        "APKRUN_TEST_VHOST_USER": "true" if persisted_vhost_user else "false",
        "APKRUN_TEST_START_EXIT_CODE": str(start_exit_code),
        "APKRUN_TEST_GPU_MODE": gpu_mode,
        "APKRUN_TEST_CONSOLE_ENABLED": str(console_enabled).lower(),
        "APKRUN_TEST_PAUSE_IN_BOOTLOADER": str(pause_in_bootloader).lower(),
    }
    result = subprocess.run(
        ["bash", str(harness)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    assert result.returncode == 0, result.stderr
    assert int(capture_status_path.read_text(encoding="ascii").strip()) == (
        expected_capture_failure
    ), (result.stdout, result.stderr)
    summary_path = tmp_path / "bootloader-console-summary.json"
    assert summary_path.exists() is pause_in_bootloader

    calls = [
        json.loads(line) for line in calls_path.read_text(encoding="utf-8").splitlines()
    ]
    start_timeout_arguments = [
        value
        for value in calls[-1]
        if value.startswith("--boot_timeout_secs=")
    ]
    assert len(start_timeout_arguments) == 1
    start_timeout_seconds = int(start_timeout_arguments[0].split("=", 1)[1])
    assert 1 <= start_timeout_seconds <= 30
    if not pause_in_bootloader:
        assert start_timeout_seconds == 30
    assert calls == [
        [
            "create",
            f"--host_path={tmp_path / 'host'}",
            f"--product_path={tmp_path / 'product'}",
            f"--base_directory={runtime_root}",
            "--group_name=apkrun_test",
            "--base_instance_num=1",
            "--num_instances=1",
            "--nostart",
            f"--gpu_mode={gpu_mode}",
            "--gpu_vhost_user_mode=off",
            f"--console={str(console_enabled).lower()}",
            *(["--pause_in_bootloader=true"] if pause_in_bootloader else []),
            "--cpus",
            "4",
            "--memory_mb",
            "4096",
        ],
        [
            "--group_name=apkrun_test",
            "start",
            f"--gpu_mode={gpu_mode}",
            "--gpu_vhost_user_mode=off",
            f"--console={str(console_enabled).lower()}",
            start_timeout_arguments[0],
            *(["--pause_in_bootloader=true"] if pause_in_bootloader else []),
        ],
    ]
    saved_config = json.loads(config_path.read_text(encoding="utf-8"))
    saved_instance = saved_config["instances"]["1"]
    assert saved_instance["gpu_mode"] == gpu_mode
    assert saved_instance["enable_gpu_vhost_user"] is persisted_vhost_user
    assert saved_instance["console"] is console_enabled
    assert saved_instance["pause_in_bootloader"] is pause_in_bootloader

    if persisted_vhost_user:
        capture_record = tmp_path / "capture-record"
        capture_record.mkdir()
        (capture_record / "host.json").write_text("{}", encoding="utf-8")
        shutil.copyfile(config_path, capture_record / "cuttlefish_config.json")
        unused = tmp_path / "unused"
        with pytest.raises(
            ValueError,
            match=(
                "captured Cuttlefish configuration has unexpected "
                "enable_gpu_vhost_user: True"
            ),
        ):
            experiment_support.build_experiment_record(
                capture_record=capture_record,
                repo_root=unused,
                baseline_record=unused,
                tool_copy_root=unused,
                canonical_capture_copy=unused,
                manifest_copy_root=unused,
                experiment_root=unused,
                patched_capture=unused,
                host_identity_path=unused,
                logcat_summary_path=unused,
                adb_state_path=unused,
                capture_exit_code=1,
                adb_endpoint="127.0.0.1:6520",
                capture_status_root=unused,
                capture_run_status_path=unused,
                socket_metrics_path=unused,
                fleet_socket_metrics_path=unused,
                gpu_mode=gpu_mode,
                console_enabled=console_enabled,
                pause_in_bootloader=pause_in_bootloader,
            )


def test_baseline_must_use_the_expected_gpu_and_vm_shape(tmp_path: Path) -> None:
    _, baseline, _, _ = _make_baseline_repository(tmp_path)
    document = json.loads(
        (baseline / "cuttlefish_config.json").read_text(encoding="utf-8")
    )
    document["instances"]["1"]["gpu_mode"] = "none"
    (baseline / "cuttlefish_config.json").write_text(
        json.dumps(document),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError, match="baseline configuration has unexpected gpu_mode"
    ):
        experiment_support.validate_baseline_configuration(baseline)


@pytest.mark.parametrize(
    "gpu_mode",
    ("none", "guest_swiftshader"),
)
@pytest.mark.parametrize(
    ("console_enabled", "pause_in_bootloader"),
    ((True, False), (False, False), (True, True)),
)
def test_host_preflight_checks_tool_blobs_and_cvd_revision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    gpu_mode: str,
    console_enabled: bool,
    pause_in_bootloader: bool,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )
    report = experiment_support.verify_host(
        repo_root,
        baseline,
        fleet_report,
        experiment_root,
        patched_capture,
        gpu_mode=gpu_mode,
        console_enabled=console_enabled,
        pause_in_bootloader=pause_in_bootloader,
    )

    assert report["baselineCvd"] == report["observedCvd"]
    assert report["baselineHost"] == report["observedHost"]
    assert report["gpuMode"] == gpu_mode
    assert report["gpuModeSlug"] == experiment_support.GPU_MODE_SLUGS[gpu_mode]
    assert report["consoleEnabled"] is console_enabled
    assert (
        report["consoleModeSlug"]
        == (experiment_support.CONSOLE_MODE_SLUGS[console_enabled])
    )
    assert report["pauseInBootloader"] is pause_in_bootloader
    assert report["cpuCount"] == 4
    assert len(report["baselineToolBlobs"]) == len(experiment_support.TOOL_PATHS)
    assert report["baselineToolCommit"] == report["observedToolCommit"]
    assert report["baselineToolBlobs"] == report["observedToolBlobs"]
    assert (
        len(report["experimentSources"])
        == len(experiment_support.EXPERIMENT_TOOL_NAMES) + 1
    )


def test_host_preflight_records_committed_tool_updates_separately_from_baseline(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    changed_tool = repo_root / experiment_support.TOOL_PATHS[0]
    changed_tool.write_text("updated committed capture tool\n", encoding="utf-8")
    subprocess.run(
        ["git", "add", str(experiment_support.TOOL_PATHS[0])],
        cwd=repo_root,
        check=True,
    )
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=APKRun Test",
            "-c",
            "user.email=apkrun-test@example.invalid",
            "commit",
            "-q",
            "-m",
            "update capture tool",
        ],
        cwd=repo_root,
        check=True,
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    report = experiment_support.verify_host(
        repo_root, baseline, fleet_report, experiment_root, patched_capture
    )
    tool_path = experiment_support.TOOL_PATHS[0].as_posix()
    assert report["baselineToolCommit"] != report["observedToolCommit"]
    assert (
        report["baselineToolBlobs"][tool_path] != report["observedToolBlobs"][tool_path]
    )


def test_host_preflight_rejects_uncommitted_capture_tool(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    (repo_root / experiment_support.TOOL_PATHS[0]).write_text(
        "uncommitted capture tool change\n",
        encoding="utf-8",
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="uncommitted changes"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_alternate_baseline_path(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, _, experiment_root, patched_capture = _make_baseline_repository(tmp_path)
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="pinned canonical baseline record"):
        experiment_support.verify_host(
            repo_root,
            tmp_path / "alternate-baseline",
            fleet_report,
            experiment_root,
            patched_capture,
        )


def test_tool_copy_provenance_rejects_copy_then_restore_race(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline_record, source_experiment_root, source_patched_capture = (
        _make_baseline_repository(tmp_path / "repository")
    )
    experiment_root = tmp_path / "private-experiment-tools"
    experiment_root.mkdir()
    for name in experiment_support.EXPERIMENT_TOOL_NAMES:
        shutil.copyfile(
            source_experiment_root / name,
            experiment_root / name,
        )
    tool_copy_root = tmp_path / "canonical-tools"
    tool_copy_root.mkdir()
    canonical_capture_copy = tmp_path / "capture.sh.unpatched"
    canonical_capture_copy.write_bytes(
        (repo_root / experiment_support.TOOL_PATHS[0]).read_bytes()
    )
    manifest_copy_root = tmp_path / "manifest-copy"
    manifest_copy_root.mkdir()

    changed_path = repo_root / experiment_support.TOOL_PATHS[0]
    original_contents = changed_path.read_bytes()
    changed_path.write_bytes(b"transient source replacement\n")
    canonical_capture_copy.write_bytes(changed_path.read_bytes())
    changed_path.write_bytes(original_contents)
    for relative in experiment_support.TOOL_PATHS[1:]:
        destination = (
            manifest_copy_root
            if relative == experiment_support.MANIFEST_RELATIVE
            else tool_copy_root
        )
        (destination / relative.name).write_bytes((repo_root / relative).read_bytes())
    for name in ("capture_bounded.py", "capture_processes.py"):
        (tool_copy_root / name).write_bytes((experiment_root / name).read_bytes())
    patched_capture = tool_copy_root / experiment_support.TOOL_PATHS[0].name
    shutil.copyfile(source_patched_capture, patched_capture)

    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )
    host_identity = experiment_support.verify_host(
        repo_root,
        baseline_record,
        fleet_report,
        experiment_root,
        patched_capture,
    )

    with pytest.raises(ValueError, match="copy differs from observed revision"):
        experiment_support.verify_tool_copy(
            repo_root,
            baseline_record,
            host_identity,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
        )


def test_host_preflight_rejects_experiment_source_copied_then_restored(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline_record, source_root, patched_capture = (
        _make_baseline_repository(tmp_path / "repository")
    )
    experiment_root = tmp_path / "private-experiment-tools"
    experiment_root.mkdir()
    for name in experiment_support.EXPERIMENT_TOOL_NAMES:
        shutil.copyfile(source_root / name, experiment_root / name)

    support_path = source_root / "experiment_support.py"
    trusted_source = support_path.read_bytes()
    support_path.write_bytes(b"transient verifier replacement\n")
    (experiment_root / support_path.name).write_bytes(support_path.read_bytes())
    support_path.write_bytes(trusted_source)
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError,
        match="private experiment source differs from committed HEAD: "
        "experiment_support.py",
    ):
        experiment_support.verify_host(
            repo_root,
            baseline_record,
            fleet_report,
            experiment_root,
            patched_capture,
        )


def test_host_preflight_rejects_cvd_revision_drift(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 0000000000000000000000000000000000000000\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from baseline"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_working_tree_baseline_tampering(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    host_path = baseline / "host.json"
    host = json.loads(host_path.read_text(encoding="utf-8"))
    host["cvdPackageVersion"] = "9.99.0"
    host_path.write_text(json.dumps(host), encoding="utf-8")
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 9.99.0 | "
        "VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from its committed revision"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_keeps_baseline_commit_pinned_after_later_record_commit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    pinned_commit = experiment_support._baseline_commit(repo_root, baseline)
    host_path = baseline / "host.json"
    host = json.loads(host_path.read_text(encoding="utf-8"))
    host["buildId"] = "16373616"
    host_path.write_text(json.dumps(host), encoding="utf-8")
    subprocess.run(
        ["git", "add", str(host_path.relative_to(repo_root))],
        cwd=repo_root,
        check=True,
    )
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=APKRun Test",
            "-c",
            "user.email=apkrun-test@example.invalid",
            "commit",
            "-q",
            "-m",
            "change baseline host record",
        ],
        cwd=repo_root,
        check=True,
    )
    assert experiment_support._baseline_commit(repo_root, baseline) == pinned_commit
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from its committed revision"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_different_host_conditions(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    changed_host = dict(REFERENCE_HOST)
    changed_host["kernel"] = "Linux 6.8.1 aarch64 GNU/Linux"
    monkeypatch.setattr(
        experiment_support,
        "_current_host_fingerprint",
        lambda: changed_host,
    )
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="host differs from the pinned baseline"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


@pytest.mark.parametrize(
    "gpu_mode",
    ("none", "guest_swiftshader"),
)
@pytest.mark.parametrize(
    ("console_enabled", "pause_in_bootloader"),
    ((True, False), (False, False), (True, True)),
)
def test_experiment_record_validates_actual_gpu_mode_and_keeps_only_summary(
    tmp_path: Path,
    gpu_mode: str,
    console_enabled: bool,
    pause_in_bootloader: bool,
) -> None:
    repo_root, baseline_record, source_experiment_root, source_patched_capture = (
        _make_baseline_repository(tmp_path / "repository")
    )
    experiment_root = tmp_path / "private-experiment-tools"
    experiment_root.mkdir()
    for name in experiment_support.EXPERIMENT_TOOL_NAMES:
        shutil.copyfile(source_experiment_root / name, experiment_root / name)
    (
        baseline_tool_commit,
        baseline_tool_blobs,
        observed_tool_commit,
        observed_tool_blobs,
    ) = experiment_support._verify_tool_revisions(repo_root, baseline_record)
    tool_copy_root = tmp_path / "canonical-tools"
    tool_copy_root.mkdir()
    for relative in experiment_support.TOOL_PATHS:
        destination = (
            tool_copy_root
            if relative != experiment_support.MANIFEST_RELATIVE
            else tmp_path / "manifest-copy"
        )
        destination.mkdir(exist_ok=True)
        shutil.copyfile(repo_root / relative, destination / relative.name)
    for name in ("capture_bounded.py", "capture_processes.py"):
        shutil.copyfile(experiment_root / name, tool_copy_root / name)
    canonical_capture_copy = tmp_path / "capture.sh.unpatched"
    shutil.copyfile(
        repo_root / experiment_support.TOOL_PATHS[0],
        canonical_capture_copy,
    )
    patched_capture = tool_copy_root / experiment_support.TOOL_PATHS[0].name
    shutil.copyfile(source_patched_capture, patched_capture)
    manifest_copy_root = tmp_path / "manifest-copy"
    capture_record = tmp_path / "capture"
    capture_record.mkdir()
    (capture_record / "host.json").write_text(
        json.dumps(
            {
                "buildId": "16373615",
                "profile": "default",
                "cvdPackageVersion": "1.57.0",
                **REFERENCE_HOST,
                "cvdInstanceNumber": 1,
            }
        ),
        encoding="utf-8",
    )
    (capture_record / "cuttlefish_config.json").write_text(
        json.dumps(
            {
                "instances": {
                    "1": {
                        "gpu_mode": gpu_mode,
                        "enable_gpu_vhost_user": False,
                        "cpus": 4,
                        "memory_mb": 4096,
                        "console": console_enabled,
                        "pause_in_bootloader": pause_in_bootloader,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (capture_record / "cvd-create-console.log").write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n",
        encoding="utf-8",
    )
    bootloader_console_summary_path = tmp_path / "bootloader-console-summary.json"
    if pause_in_bootloader:
        bootloader_console_summary_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 3,
                    "consoleEndpointFound": True,
                    "screenStarted": True,
                    "uBootBannerObserved": True,
                    "promptObserved": True,
                    "bootCommandSent": True,
                    "kernelHandoffObserved": True,
                    "outputBytesObserved": 64,
                    "escapeStrippedBytesObserved": 64,
                    "escapeSequenceIncomplete": False,
                    "outputLimitBytes": 65_536,
                    "outputTruncated": False,
                    "timedOut": False,
                    "handoffTimedOut": False,
                    "screenExitCode": 0,
                    "signal": None,
                    "cleanupComplete": True,
                    "cleanupFailure": None,
                    "cleanupErrorNumber": None,
                    "exitCode": 0,
                }
            ),
            encoding="utf-8",
        )
    else:
        bootloader_console_summary_path = None
    capture_status_root = tmp_path / "capture-status"
    capture_status_root.mkdir()
    (capture_status_root / "guest-logcat.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 4096,
                "truncated": True,
                "timedOut": False,
                "childExitCode": -15,
                "signal": None,
                "cleanupComplete": True,
            }
        ),
        encoding="utf-8",
    )
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "baselineRecord": experiment_support.BASELINE_RELATIVE.as_posix(),
                "buildId": "16373615",
                "baselineHost": {
                    **REFERENCE_HOST,
                    "cvdInstanceNumber": 1,
                },
                "observedHost": {
                    **REFERENCE_HOST,
                    "cvdInstanceNumber": 1,
                },
                "baselineCvd": {
                    "packageVersion": "1.57.0",
                    "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
                },
                "observedCvd": {
                    "packageVersion": "1.57.0",
                    "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
                },
                "gpuMode": gpu_mode,
                "gpuModeSlug": experiment_support.GPU_MODE_SLUGS[gpu_mode],
                "consoleEnabled": console_enabled,
                "consoleModeSlug": experiment_support.CONSOLE_MODE_SLUGS[
                    console_enabled
                ],
                "pauseInBootloader": pause_in_bootloader,
                "baselineToolCommit": baseline_tool_commit,
                "baselineToolBlobs": baseline_tool_blobs,
                "observedToolCommit": observed_tool_commit,
                "observedToolBlobs": observed_tool_blobs,
                "experimentSources": experiment_support._experiment_source_hashes(
                    repo_root,
                    observed_tool_commit,
                    experiment_root,
                    patched_capture,
                ),
            }
        ),
        encoding="utf-8",
    )
    summary = tmp_path / "summary.json"
    summary.write_text(
        json.dumps({"schemaVersion": 1, "lineCount": 12, "systemServerLines": 0}),
        encoding="utf-8",
    )
    adb_state = tmp_path / "adb-state.txt"
    adb_state.write_text("2026-10-01T00:00:00Z\tadb=offline\n", encoding="utf-8")
    capture_run_status = tmp_path / "capture-run-status.json"
    capture_run_status.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "childExitCode": 1,
                "timedOut": False,
                "signal": None,
                "cleanupComplete": True,
            }
        ),
        encoding="utf-8",
    )
    socket_metrics = tmp_path / "socket-metrics.json"
    socket_metrics.write_text(
        json.dumps(
            {
                "capacityBytes": 108,
                "terminatingNulBytes": 1,
                "socketCount": 2,
                "maxEncodedPathBytes": 58,
                "maxSunPathBytesIncludingNul": 59,
            }
        ),
        encoding="utf-8",
    )
    fleet_socket_metrics = tmp_path / "fleet-socket-metrics.json"
    fleet_socket_metrics.write_text(
        json.dumps(
            {
                "capacityBytes": 108,
                "terminatingNulBytes": 1,
                "socketCount": 1,
                "maxEncodedPathBytes": 44,
                "maxSunPathBytesIncludingNul": 45,
            }
        ),
        encoding="utf-8",
    )

    record = experiment_support.build_experiment_record(
        capture_record,
        repo_root,
        baseline_record,
        tool_copy_root,
        canonical_capture_copy,
        manifest_copy_root,
        experiment_root,
        patched_capture,
        host_identity,
        summary,
        adb_state,
        1,
        "127.0.0.1:6520",
        capture_status_root,
        capture_run_status,
        socket_metrics,
        fleet_socket_metrics,
        gpu_mode=gpu_mode,
        console_enabled=console_enabled,
        pause_in_bootloader=pause_in_bootloader,
        bootloader_console_summary_path=bootloader_console_summary_path,
        boot_timeout_seconds=180,
    )

    assert record["gpuMode"] == gpu_mode
    assert record["gpuModeSlug"] == experiment_support.GPU_MODE_SLUGS[gpu_mode]
    assert record["consoleEnabled"] is console_enabled
    assert record["pauseInBootloader"] is pause_in_bootloader
    assert record["bootTimeoutSeconds"] == 180
    assert record["bootloaderConsole"] == (
        json.loads(bootloader_console_summary_path.read_text(encoding="utf-8"))
        if bootloader_console_summary_path is not None
        else None
    )
    assert (
        record["consoleModeSlug"]
        == (experiment_support.CONSOLE_MODE_SLUGS[console_enabled])
    )
    assert record["experiment"] == (
        f"cuttlefish-gpu-{experiment_support.GPU_MODE_SLUGS[gpu_mode]}-"
        f"console-{experiment_support.CONSOLE_MODE_SLUGS[console_enabled]}-"
        "boot-diagnosis"
    )
    assert (
        record["observedCvd"]["vcsRevision"]
        == "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d"
    )
    assert record["guestLogcatCapture"]["truncated"] is True
    assert record["rawLogcatRetained"] is False
    assert record["boundedCapture"]["aggregateBytes"] == 4096
    assert record["unixSocketPaths"]["capture"]["maxSunPathBytesIncludingNul"] == 59
    assert record["unixSocketPaths"]["fleet"]["maxSunPathBytesIncludingNul"] == 45
    assert record["adbServerTransport"] == "localfilesystem"
    assert record["baselineToolCommit"] == baseline_tool_commit
    assert record["baselineToolBlobs"] == baseline_tool_blobs
    assert record["observedToolCommit"] == observed_tool_commit
    assert record["observedToolBlobs"] == observed_tool_blobs
    assert record["experimentSources"] == experiment_support._experiment_source_hashes(
        repo_root,
        observed_tool_commit,
        experiment_root,
        patched_capture,
    )
    assert "logcat.txt.gz" not in json.dumps(record)

    verified_console_identity = json.loads(host_identity.read_text(encoding="utf-8"))

    def rebuild_experiment_record() -> dict[str, object]:
        return experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
            bootloader_console_summary_path=bootloader_console_summary_path,
        )

    mismatched_console_identity = {
        **verified_console_identity,
        "consoleEnabled": not console_enabled,
    }
    host_identity.write_text(
        json.dumps(mismatched_console_identity),
        encoding="utf-8",
    )
    with pytest.raises(
        ValueError,
        match="capture GPU, console, or bootloader mode differs from the verified selection",
    ):
        rebuild_experiment_record()
    mismatched_pause_identity = {
        **verified_console_identity,
        "pauseInBootloader": not pause_in_bootloader,
    }
    host_identity.write_text(
        json.dumps(mismatched_pause_identity),
        encoding="utf-8",
    )
    with pytest.raises(
        ValueError,
        match="capture GPU, console, or bootloader mode differs from the verified selection",
    ):
        rebuild_experiment_record()
    for missing_field in (
        "consoleEnabled",
        "consoleModeSlug",
        "pauseInBootloader",
    ):
        incomplete_console_identity = dict(verified_console_identity)
        incomplete_console_identity.pop(missing_field)
        host_identity.write_text(
            json.dumps(incomplete_console_identity),
            encoding="utf-8",
        )
        with pytest.raises(
            ValueError,
            match="capture GPU, console, or bootloader mode differs from the verified selection",
        ):
            rebuild_experiment_record()
    host_identity.write_text(
        json.dumps(verified_console_identity),
        encoding="utf-8",
    )

    incomplete_provenance = json.loads(host_identity.read_text(encoding="utf-8"))
    incomplete_provenance["observedToolBlobs"].pop(
        experiment_support.TOOL_PATHS[0].as_posix()
    )
    incomplete_host_identity = tmp_path / "incomplete-host-identity.json"
    incomplete_host_identity.write_text(
        json.dumps(incomplete_provenance),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="must contain exactly"):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            incomplete_host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )

    incomplete_experiment_sources = json.loads(
        host_identity.read_text(encoding="utf-8")
    )
    incomplete_experiment_sources["experimentSources"].pop(
        experiment_support.EXPERIMENT_TOOL_NAMES[0]
    )
    with pytest.raises(ValueError, match="exactly the copied experiment tools"):
        experiment_support.verify_tool_copy(
            repo_root,
            baseline_record,
            incomplete_experiment_sources,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
        )

    copied_tool = tool_copy_root / experiment_support.TOOL_PATHS[0].name
    original_tool_contents = copied_tool.read_bytes()
    copied_tool.write_bytes(b"stale copied capture tool\n")
    with pytest.raises(ValueError, match="patched capture copy differs"):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )
    copied_tool.write_bytes(original_tool_contents)

    experiment_tool_path = experiment_root / experiment_support.EXPERIMENT_TOOL_NAMES[0]
    original_experiment_tool = experiment_tool_path.read_bytes()
    experiment_tool_path.write_bytes(b"altered private experiment tool\n")
    with pytest.raises(
        ValueError,
        match="private experiment tool copy differs from committed HEAD",
    ):
        experiment_support.verify_tool_copy(
            repo_root,
            baseline_record,
            json.loads(host_identity.read_text(encoding="utf-8")),
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
        )
    experiment_tool_path.write_bytes(original_experiment_tool)

    runtime_tool_path = tool_copy_root / "capture_bounded.py"
    original_runtime_tool = runtime_tool_path.read_bytes()
    runtime_tool_path.write_bytes(b"altered runtime helper\n")
    with pytest.raises(ValueError, match="runtime experiment tool copy differs"):
        experiment_support.verify_tool_copy(
            repo_root,
            baseline_record,
            json.loads(host_identity.read_text(encoding="utf-8")),
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
        )
    runtime_tool_path.write_bytes(original_runtime_tool)

    config_path = capture_record / "cuttlefish_config.json"
    captured_config = json.loads(config_path.read_text(encoding="utf-8"))
    other_gpu_mode = "guest_swiftshader" if gpu_mode == "none" else "none"
    captured_config["instances"]["1"]["gpu_mode"] = other_gpu_mode
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match=(
            "captured Cuttlefish configuration has unexpected gpu_mode: "
            f"{other_gpu_mode!r}"
        ),
    ):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )
    captured_config["instances"]["1"]["gpu_mode"] = gpu_mode
    captured_config["instances"]["1"]["enable_gpu_vhost_user"] = True
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match="captured Cuttlefish configuration has unexpected "
        "enable_gpu_vhost_user: True",
    ):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )
    captured_config["instances"]["1"]["enable_gpu_vhost_user"] = False
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    captured_config["instances"]["1"]["enable_gpu_vhost_user"] = 0
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match="captured Cuttlefish configuration has unexpected "
        "enable_gpu_vhost_user: 0",
    ):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )
    captured_config["instances"]["1"]["enable_gpu_vhost_user"] = False
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")

    record_arguments = (
        capture_record,
        repo_root,
        baseline_record,
        tool_copy_root,
        canonical_capture_copy,
        manifest_copy_root,
        experiment_root,
        patched_capture,
        host_identity,
        summary,
        adb_state,
        1,
        "127.0.0.1:6520",
        capture_status_root,
        capture_run_status,
        socket_metrics,
        fleet_socket_metrics,
        gpu_mode,
        console_enabled,
        pause_in_bootloader,
        bootloader_console_summary_path,
    )
    instance_config = captured_config["instances"]["1"]
    for console_value in (not console_enabled, None, int(console_enabled)):
        if console_value is None:
            instance_config.pop("console")
        else:
            instance_config["console"] = console_value
        config_path.write_text(json.dumps(captured_config), encoding="utf-8")
        with pytest.raises(
            ValueError,
            match="captured Cuttlefish configuration has unexpected console:",
        ):
            experiment_support.build_experiment_record(*record_arguments)
    instance_config["console"] = console_enabled
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    for pause_value in (
        not pause_in_bootloader,
        None,
        int(pause_in_bootloader),
    ):
        if pause_value is None:
            instance_config.pop("pause_in_bootloader")
        else:
            instance_config["pause_in_bootloader"] = pause_value
        config_path.write_text(json.dumps(captured_config), encoding="utf-8")
        with pytest.raises(
            ValueError,
            match=(
                "captured Cuttlefish configuration has unexpected pause_in_bootloader:"
            ),
        ):
            experiment_support.build_experiment_record(*record_arguments)
    instance_config["pause_in_bootloader"] = pause_in_bootloader
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")

    incomplete_cleanup = capture_status_root / "adb-helper-cleanup-incomplete.json"
    incomplete_cleanup.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 0,
                "truncated": False,
                "timedOut": False,
                "childExitCode": None,
                "signal": None,
                "cleanupComplete": False,
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="cleanup is incomplete"):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )
    incomplete_cleanup.unlink()

    host_identity_doc = json.loads(host_identity.read_text(encoding="utf-8"))
    host_identity_doc["observedCvd"]["vcsRevision"] = "0" * 40
    altered_identity = tmp_path / "altered-host-identity.json"
    altered_identity.write_text(json.dumps(host_identity_doc), encoding="utf-8")
    with pytest.raises(ValueError, match="differs from the pinned baseline"):
        experiment_support.build_experiment_record(
            capture_record,
            repo_root,
            baseline_record,
            tool_copy_root,
            canonical_capture_copy,
            manifest_copy_root,
            experiment_root,
            patched_capture,
            altered_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
            socket_metrics,
            fleet_socket_metrics,
            gpu_mode=gpu_mode,
            console_enabled=console_enabled,
            pause_in_bootloader=pause_in_bootloader,
        )


def test_workspace_removal_is_limited_to_generated_diagnostic_work(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    experiment_support.prepare_private_data_root(data_root)
    ownership_token = "0123456789abcdef" * 4
    outside_workspace = tmp_path / "important-data"
    outside_workspace.mkdir()
    protected_file = outside_workspace / "keep.txt"
    protected_file.write_text("preserve", encoding="utf-8")

    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.discard_private_workspace(
            outside_workspace,
            data_root,
            ownership_token,
        )

    assert protected_file.read_text(encoding="utf-8") == "preserve"

    unmarked_workspace = data_root / "work/gpu-none.backup"
    unmarked_workspace.mkdir()
    os.chmod(unmarked_workspace, 0o700)
    (unmarked_workspace / ".apkrun-cuttlefish-workspace").write_text(
        "APKRun Cuttlefish boot diagnosis v1\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="ownership marker"):
        experiment_support.discard_private_workspace(
            unmarked_workspace,
            data_root,
            ownership_token,
        )

    assert unmarked_workspace.is_dir()


@pytest.mark.parametrize(
    "gpu_mode_slug",
    ("none", "guest-swiftshader"),
)
@pytest.mark.skipif(
    sys.platform != "linux",
    reason="workspace removal uses Linux renameat2",
)
def test_workspace_cleanup_accepts_each_supported_gpu_mode(
    tmp_path: Path,
    gpu_mode_slug: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work" / f"gpu-{gpu_mode_slug}.cleanup123"
    work_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    (work_root / "capture.txt").write_text("private capture", encoding="utf-8")

    experiment_support.discard_private_workspace(
        work_root,
        data_root,
        ownership_token,
    )

    assert not work_root.exists()


def test_log_tree_removal_is_limited_to_generated_diagnostic_work(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    experiment_support.prepare_private_data_root(data_root)
    outside_workspace = tmp_path / "important-data"
    capture_root = outside_workspace / "Images/reference/16373615/default"
    adb_log_root = outside_workspace / "adb-live"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir(parents=True)
    protected_capture = capture_root / "logcat.txt.gz"
    protected_live = adb_log_root / "logcat-001.txt"
    protected_capture.write_bytes(b"preserve guest log")
    protected_live.write_text("preserve live log\n", encoding="utf-8")

    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.scrub_raw_logcat(
            outside_workspace,
            adb_log_root,
            data_root,
            "0123456789abcdef" * 4,
        )
    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.discard_logcat_trees(
            outside_workspace,
            adb_log_root,
            data_root,
            "0123456789abcdef" * 4,
        )

    assert protected_capture.read_bytes() == b"preserve guest log"
    assert protected_live.read_text(encoding="utf-8") == "preserve live log\n"


@pytest.mark.skipif(sys.platform != "linux", reason="race fixture uses /proc/self/fd")
def test_logcat_scrub_does_not_follow_parent_swapped_after_stat(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.test123"
    capture_root = work_root / "Images/reference/16373615"
    capture_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    raw_log = capture_root / "logcat.txt.gz"
    raw_log.write_bytes(b"private guest log")
    external = tmp_path / "external-capture"
    external.mkdir()
    external_log = external / "logcat.txt.gz"
    external_log.write_bytes(b"external data")
    displaced_capture = work_root / "capture-original"
    real_stat = experiment_support._stat_entry_at
    swapped = False

    def swap_after_stat(parent_descriptor: int, name: str) -> os.stat_result:
        nonlocal swapped
        entry_stat = real_stat(parent_descriptor, name)
        if name == "logcat.txt.gz" and not swapped:
            opened_parent = Path(os.readlink(f"/proc/self/fd/{parent_descriptor}"))
            opened_parent.rename(displaced_capture)
            capture_root.symlink_to(external, target_is_directory=True)
            swapped = True
        return entry_stat

    monkeypatch.setattr(experiment_support, "_stat_entry_at", swap_after_stat)
    with pytest.raises(OSError):
        experiment_support.scrub_raw_logcat(
            work_root,
            work_root / "adb-live",
            data_root,
            ownership_token,
        )

    assert swapped
    assert capture_root.is_symlink()
    assert external_log.read_bytes() == b"external data"
    assert not (displaced_capture / "logcat.txt.gz").exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace race fixture is Linux-only"
)
def test_workspace_removal_refuses_replacement_after_marker_validation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    displaced_workspace = tmp_path / "displaced-workspace"
    real_verify = experiment_support._verify_workspace_marker
    verification_count = 0

    def verify_then_replace(
        work_descriptor: int,
        verified_root: Path,
        token: str,
    ) -> None:
        nonlocal verification_count
        real_verify(work_descriptor, verified_root, token)
        verification_count += 1
        if verification_count == 2:
            verified_root.rename(displaced_workspace)
            verified_root.mkdir()
            _mark_generated_workspace(verified_root, token)
            (verified_root / "keep.txt").write_text("preserve", encoding="utf-8")

    monkeypatch.setattr(
        experiment_support,
        "_verify_workspace_marker",
        verify_then_replace,
    )
    with pytest.raises(OSError, match="directory changed"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    assert (displaced_workspace / ".apkrun-cuttlefish-workspace").is_file()
    assert (work_root / "keep.txt").read_text(encoding="utf-8") == "preserve"
    assert (work_root / ".apkrun-cuttlefish-workspace").is_file()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace removal fixture is Linux-only"
)
def test_workspace_removal_keeps_marker_when_partial_cleanup_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    first_file = work_root / "01-delete.txt"
    failing_file = work_root / "02-fail.txt"
    first_file.write_text("delete", encoding="utf-8")
    failing_file.write_text("keep for retry", encoding="utf-8")
    real_unlink = experiment_support._unlink_entry_at

    def fail_after_first_file(
        parent_descriptor: int,
        name: str,
        expected_stat: os.stat_result,
    ) -> None:
        if name == failing_file.name:
            raise OSError(errno.EACCES, "injected cleanup failure", name)
        real_unlink(parent_descriptor, name, expected_stat)

    monkeypatch.setattr(
        experiment_support,
        "_unlink_entry_at",
        fail_after_first_file,
    )
    with pytest.raises(OSError, match="injected cleanup failure"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    marker = work_root / ".apkrun-cuttlefish-workspace"
    assert not first_file.exists()
    assert failing_file.read_text(encoding="utf-8") == "keep for retry"
    assert marker.is_file()

    monkeypatch.setattr(experiment_support, "_unlink_entry_at", real_unlink)
    experiment_support.discard_private_workspace(
        work_root,
        data_root,
        ownership_token,
    )
    assert not work_root.exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace removal fixture is Linux-only"
)
def test_workspace_removal_restores_marker_when_final_rmdir_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    marker = work_root / ".apkrun-cuttlefish-workspace"
    expected_marker = marker.read_bytes()
    real_remove_directory_entry = experiment_support._remove_directory_entry_at

    def fail_final_rmdir(
        parent_descriptor: int,
        name: str,
        expected_stat: os.stat_result,
    ) -> None:
        raise OSError(errno.EBUSY, "injected final rmdir failure", name)

    monkeypatch.setattr(
        experiment_support,
        "_remove_directory_entry_at",
        fail_final_rmdir,
    )
    with pytest.raises(OSError, match="injected final rmdir failure"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    assert marker.read_bytes() == expected_marker

    monkeypatch.setattr(
        experiment_support,
        "_remove_directory_entry_at",
        real_remove_directory_entry,
    )
    experiment_support.discard_private_workspace(
        work_root,
        data_root,
        ownership_token,
    )
    assert not work_root.exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="atomic quarantine rename is Linux-only"
)
@pytest.mark.parametrize("directory", [False, True])
def test_removal_refuses_replacement_at_quarantine_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    directory: bool,
) -> None:
    parent = tmp_path / "parent"
    parent.mkdir()
    target = parent / "target"
    displaced = tmp_path / "displaced"
    if directory:
        target.mkdir()
    else:
        target.write_text("original", encoding="utf-8")
    expected_stat = target.stat(follow_symlinks=False)
    parent_descriptor = experiment_support._open_directory_chain(parent)
    real_rename = experiment_support._renameat2_noreplace
    replaced = False

    def replace_at_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
    ) -> None:
        nonlocal replaced
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        if (
            not replaced
            and source_parent == parent
            and source_name == "target"
            and destination_name.startswith(".apkrun-quarantine-")
        ):
            target.rename(displaced)
            if directory:
                target.mkdir()
            else:
                target.write_text("replacement", encoding="utf-8")
            replaced = True
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
        )

    monkeypatch.setattr(
        experiment_support,
        "_renameat2_noreplace",
        replace_at_rename,
    )
    try:
        with pytest.raises(OSError, match="changed during safe removal"):
            if directory:
                experiment_support._remove_directory_entry_at(
                    parent_descriptor,
                    "target",
                    expected_stat,
                )
            else:
                experiment_support._unlink_entry_at(
                    parent_descriptor,
                    "target",
                    expected_stat,
                )
    finally:
        os.close(parent_descriptor)

    assert replaced
    assert displaced.exists()
    assert target.is_dir() if directory else target.read_text() == "replacement"


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
@pytest.mark.parametrize(
    "gpu_mode_slug",
    ("none", "guest-swiftshader"),
)
def test_publication_rejects_result_directory_without_nesting_capture(
    tmp_path: Path,
    gpu_mode_slug: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work" / (f"gpu-{gpu_mode_slug}-console-off.012345")
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    result_path = results_root / (
        f"gpu-{gpu_mode_slug}-console-off-20261001T000000Z-1234"
    )
    result_path.mkdir()
    _write_publication_experiment(
        capture_record,
        gpu_mode_slug,
        console_enabled=False,
    )

    with pytest.raises(FileExistsError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not list(result_path.iterdir())


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_omits_kernel_log_after_console_probe_was_sent(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    summary = {
        "schemaVersion": 4,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponseObserved": True,
        "bdinfoTimedOut": False,
        "relocationAddress": 0x17F600000,
        "relocationOffset": 0x8000,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 128,
        "escapeStrippedBytesObserved": 128,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=summary,
    )
    (capture_record / "MISSING.txt").write_text("", encoding="utf-8")
    (capture_record / "kernel.log").write_text(
        "U-Boot console probe\nethaddr = 02:00:00:00:00:01\n"
        "relocaddr = 0x17f600000\nreloc off = 0x8000\n",
        encoding="utf-8",
    )
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"

    experiment_support.publish_normalized_record(
        capture_record,
        work_root,
        data_root,
        result_path,
        ownership_token,
    )

    assert not (result_path / "kernel.log").exists()
    missing = (result_path / "MISSING.txt").read_text(encoding="utf-8")
    assert "kernel.log\tomitted from published paused-U-Boot probe" in missing
    published_text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in result_path.iterdir()
        if path.is_file()
    )
    assert "ethaddr" not in published_text


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_omits_kernel_log_after_memory_probe_was_sent(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    summary = _valid_memory_probe_summary()
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=summary,
    )
    (capture_record / "MISSING.txt").write_text("", encoding="utf-8")
    (capture_record / "kernel.log").write_text(
        "U-Boot memory probe\nword0=d50b7e20 word1=d53b0023\n",
        encoding="utf-8",
    )
    result_path = results_root / "gpu-none-console-on-20261002T000000Z-5678"

    experiment_support.publish_normalized_record(
        capture_record,
        work_root,
        data_root,
        result_path,
        ownership_token,
    )

    assert not (result_path / "kernel.log").exists()
    missing = (result_path / "MISSING.txt").read_text(encoding="utf-8")
    assert "kernel.log\tomitted from published paused-U-Boot probe" in missing
    published_text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in result_path.iterdir()
        if path.is_file()
    )
    assert "d50b7e20" not in published_text
    assert "d53b0023" not in published_text


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_omits_kernel_log_after_probe_preparation_was_sent(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    summary = _valid_memory_probe_summary()
    summary.update(
        memoryProbeVariablesCleared=False,
        memoryProbePreparationRejected=True,
        memoryProbeCommandAttempted=False,
        memoryProbeCommandSent=False,
        memoryProbeCommandEchoObserved=False,
        memoryProbeResponsePromptObserved=False,
        memoryProbeResponseObserved=False,
        memoryProbeResponseRejected=False,
        wordAtObservedPc=None,
        wordBeforeObservedPc=None,
    )
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=summary,
    )
    (capture_record / "MISSING.txt").write_text("", encoding="utf-8")
    (capture_record / "kernel.log").write_text(
        "APKRUN_PROBE_READY stale-secret-like-value\n",
        encoding="utf-8",
    )
    result_path = results_root / "gpu-none-console-on-20261002T000000Z-5679"

    experiment_support.publish_normalized_record(
        capture_record,
        work_root,
        data_root,
        result_path,
        ownership_token,
    )

    assert not (result_path / "kernel.log").exists()
    missing = (result_path / "MISSING.txt").read_text(encoding="utf-8")
    assert "kernel.log\tomitted from published paused-U-Boot probe" in missing
    published_text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in result_path.iterdir()
        if path.is_file()
    )
    assert "stale-secret-like-value" not in published_text


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_accepts_legacy_console_summary_without_bdinfo_fields(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    summary = {
        "schemaVersion": 3,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 64,
        "escapeStrippedBytesObserved": 64,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=summary,
    )
    (capture_record / "MISSING.txt").write_text("", encoding="utf-8")
    (capture_record / "kernel.log").write_text(
        "Starting kernel ...\n",
        encoding="utf-8",
    )
    result_path = results_root / "gpu-none-console-on-20261002T000000Z-1234"

    experiment_support.publish_normalized_record(
        capture_record,
        work_root,
        data_root,
        result_path,
        ownership_token,
    )

    assert (result_path / "kernel.log").read_text(encoding="utf-8") == (
        "Starting kernel ...\n"
    )
    assert (result_path / "MISSING.txt").read_text(encoding="utf-8") == ""


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_refuses_symlinked_kernel_log_after_bdinfo(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    summary = {
        "schemaVersion": 4,
        "consoleEndpointFound": True,
        "screenStarted": True,
        "uBootBannerObserved": True,
        "promptObserved": True,
        "bdinfoCommandSent": True,
        "bdinfoCommandEchoObserved": True,
        "bdinfoStartMarkerObserved": True,
        "bdinfoEndMarkerObserved": True,
        "bdinfoResponseObserved": True,
        "bdinfoTimedOut": False,
        "relocationAddress": 0x17F600000,
        "relocationOffset": 0x8000,
        "bootCommandSent": True,
        "kernelHandoffObserved": True,
        "outputBytesObserved": 128,
        "escapeStrippedBytesObserved": 128,
        "escapeSequenceIncomplete": False,
        "outputLimitBytes": 65_536,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": 0,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
        "exitCode": 0,
    }
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=summary,
    )
    (capture_record / "MISSING.txt").write_text("", encoding="utf-8")
    external_log = tmp_path / "external-kernel.log"
    external_log.write_text("ethaddr = 02:00:00:00:00:01\n", encoding="utf-8")
    (capture_record / "kernel.log").symlink_to(external_log)
    result_path = results_root / "gpu-none-console-on-20261002T000000Z-1235"

    with pytest.raises(ValueError, match="kernel.log is not a regular file"):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert (capture_record / "kernel.log").is_symlink()
    assert external_log.read_text(encoding="utf-8") == ("ethaddr = 02:00:00:00:00:01\n")
    assert (capture_record / "MISSING.txt").read_text(encoding="utf-8") == ""
    assert not result_path.exists()


def test_kernel_log_omission_does_not_record_success_when_unlink_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    capture_record = tmp_path / "capture"
    capture_record.mkdir()
    kernel_log = capture_record / "kernel.log"
    kernel_log.write_text("private console output\n", encoding="utf-8")
    missing = capture_record / "MISSING.txt"
    missing.write_text("", encoding="utf-8")
    directory_descriptor = os.open(
        capture_record,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )

    def fail_unlink(
        parent_descriptor: int,
        name: str,
        expected_stat: os.stat_result,
    ) -> None:
        raise OSError(errno.EPERM, "injected unlink failure")

    monkeypatch.setattr(experiment_support, "_unlink_entry_at", fail_unlink)
    try:
        with pytest.raises(OSError, match="injected unlink failure"):
            experiment_support._omit_paused_uboot_kernel_log(directory_descriptor)
    finally:
        os.close(directory_descriptor)

    assert kernel_log.read_text(encoding="utf-8") == "private console output\n"
    assert missing.read_text(encoding="utf-8") == ""


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
@pytest.mark.parametrize(
    ("field", "value", "error"),
    (
        ("bootTimeoutSeconds", 119, "invalid boot timeout metadata"),
        ("bootTimeoutSeconds", 601, "invalid boot timeout metadata"),
        ("bootTimeoutSeconds", True, "invalid boot timeout metadata"),
        ("runnerDeadlineSeconds", 899, "invalid runner deadline metadata"),
    ),
)
def test_publication_revalidates_timeout_metadata(
    tmp_path: Path,
    field: str,
    value: object,
    error: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-off.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    _write_publication_experiment(capture_record)
    experiment_path = capture_record / "experiment.json"
    experiment = json.loads(experiment_path.read_text(encoding="utf-8"))
    experiment[field] = value
    experiment_path.write_text(json.dumps(experiment), encoding="utf-8")
    result_path = results_root / "gpu-none-console-off-20261001T000000Z-1234"

    with pytest.raises(ValueError, match=error):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
@pytest.mark.parametrize(
    ("workspace_console", "result_console", "record_console", "error"),
    (
        ("off", "off", True, "diagnostic path console label differs"),
        ("off", "on", False, "workspace and result path mode labels differ"),
    ),
)
def test_publication_rejects_mismatched_console_labels(
    tmp_path: Path,
    workspace_console: str,
    result_console: str,
    record_console: bool,
    error: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work" / (f"gpu-none-console-{workspace_console}.012345")
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    _write_publication_experiment(
        capture_record,
        console_enabled=record_console,
    )
    result_path = results_root / (
        f"gpu-none-console-{result_console}-20261001T000000Z-1234"
    )

    with pytest.raises(ValueError, match=error):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
@pytest.mark.parametrize(
    ("bootloader_console", "error"),
    (
        (None, "summary must be an object"),
        ({"schemaVersion": 1}, "unexpected schema"),
        (
            {
                "schemaVersion": 3,
                "consoleEndpointFound": False,
                "screenStarted": False,
                "uBootBannerObserved": False,
                "promptObserved": False,
                "bootCommandSent": False,
                "kernelHandoffObserved": False,
                "outputBytesObserved": 0,
                "escapeStrippedBytesObserved": 0,
                "escapeSequenceIncomplete": False,
                "outputLimitBytes": 65_536,
                "outputTruncated": False,
                "timedOut": True,
                "handoffTimedOut": False,
                "screenExitCode": None,
                "signal": None,
                "cleanupComplete": True,
                "cleanupFailure": None,
                "cleanupErrorNumber": None,
                "exitCode": 42,
            },
            "inconsistent or incomplete",
        ),
    ),
)
def test_publication_revalidates_bootloader_console_evidence(
    tmp_path: Path,
    bootloader_console: dict[str, object] | None,
    error: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    _write_publication_experiment(
        capture_record,
        console_enabled=True,
        pause_in_bootloader=True,
        bootloader_console=bootloader_console,
    )
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"

    with pytest.raises(ValueError, match=error):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
@pytest.mark.parametrize(
    "json_name",
    ("experiment.json", "cuttlefish_config.json"),
)
@pytest.mark.parametrize("corruption", ("symlink", "oversized"))
def test_publication_rejects_unsafe_mode_json(
    tmp_path: Path,
    json_name: str,
    corruption: str,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    _write_publication_experiment(capture_record, console_enabled=True)
    json_path = capture_record / json_name
    if corruption == "symlink":
        target = capture_record / f"{json_name}.target"
        json_path.rename(target)
        json_path.symlink_to(target.name)
    else:
        json_path.write_bytes(
            b" " * (experiment_support.MAX_PUBLICATION_EXPERIMENT_BYTES + 1)
        )
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"

    if corruption == "symlink":
        with pytest.raises(OSError):
            experiment_support.publish_normalized_record(
                capture_record,
                work_root,
                data_root,
                result_path,
                ownership_token,
            )
    else:
        with pytest.raises(ValueError, match="bounded regular file"):
            experiment_support.publish_normalized_record(
                capture_record,
                work_root,
                data_root,
                result_path,
                ownership_token,
            )

    assert capture_record.is_dir()
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_rejects_symlinked_results_parent(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    external_results = tmp_path / "external-results"
    external_results.mkdir()
    results_root.rmdir()
    results_root.symlink_to(external_results, target_is_directory=True)
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"
    _write_publication_experiment(capture_record, console_enabled=True)

    with pytest.raises(OSError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not list(external_results.iterdir())


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_rechecks_source_inode_before_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n',
        encoding="utf-8",
    )
    _write_publication_experiment(capture_record, console_enabled=True)
    external_record = tmp_path / "external-record"
    external_record.mkdir()
    external_file = external_record / "host.json"
    external_file.write_text("preserve", encoding="utf-8")
    displaced_record = capture_record.parent / "displaced-record"
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"
    real_rename = experiment_support._rename_directory_no_replace

    def replace_source_then_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
        expected_source_stat: os.stat_result,
    ) -> None:
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        source_path = source_parent / source_name
        source_path.rename(displaced_record)
        source_path.symlink_to(external_record, target_is_directory=True)
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
            expected_source_stat,
        )

    monkeypatch.setattr(
        experiment_support,
        "_rename_directory_no_replace",
        replace_source_then_rename,
    )
    with pytest.raises(OSError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_symlink()
    assert (displaced_record / "host.json").is_file()
    assert external_file.read_text(encoding="utf-8") == "preserve"
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_refuses_source_replacement_at_quarantine_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n',
        encoding="utf-8",
    )
    _write_publication_experiment(capture_record, console_enabled=True)
    external_record = tmp_path / "external-record"
    external_record.mkdir()
    external_file = external_record / "host.json"
    external_file.write_text("preserve", encoding="utf-8")
    displaced_record = capture_record.parent / "displaced-record"
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"
    real_rename = experiment_support._renameat2_noreplace
    replaced = False

    def replace_at_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
    ) -> None:
        nonlocal replaced
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        if (
            not replaced
            and source_parent == capture_record.parent
            and source_name == capture_record.name
            and destination_name.startswith(".apkrun-quarantine-")
        ):
            capture_record.rename(displaced_record)
            capture_record.symlink_to(external_record, target_is_directory=True)
            replaced = True
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
        )

    monkeypatch.setattr(
        experiment_support,
        "_renameat2_noreplace",
        replace_at_rename,
    )
    with pytest.raises(OSError, match="changed during safe removal"):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert replaced
    assert capture_record.is_symlink()
    assert (displaced_record / "host.json").is_file()
    assert external_file.read_text(encoding="utf-8") == "preserve"
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="descriptor counts use /proc")
def test_publication_closes_descriptors_when_results_open_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none-console-on.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    _write_publication_experiment(capture_record, console_enabled=True)
    result_path = results_root / "gpu-none-console-on-20261001T000000Z-1234"
    real_open = experiment_support._open_child_directory
    results_open_count = 0

    def fail_second_results_open(parent_descriptor: int, name: str) -> int:
        nonlocal results_open_count
        if name == "results":
            results_open_count += 1
            if results_open_count % 2 == 0:
                raise OSError(errno.ELOOP, "injected results open failure")
        return real_open(parent_descriptor, name)

    monkeypatch.setattr(
        experiment_support,
        "_open_child_directory",
        fail_second_results_open,
    )
    descriptors_before = len(os.listdir("/proc/self/fd"))
    for _ in range(20):
        with pytest.raises(OSError, match="injected results open failure"):
            experiment_support.publish_normalized_record(
                capture_record,
                work_root,
                data_root,
                result_path,
                ownership_token,
            )
    descriptors_after = len(os.listdir("/proc/self/fd"))

    assert descriptors_after <= descriptors_before + 1
