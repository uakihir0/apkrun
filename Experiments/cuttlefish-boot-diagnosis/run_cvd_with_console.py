#!/usr/bin/env python3
"""Run Cuttlefish startup and a paused-bootloader console probe together."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from types import FrameType
from typing import BinaryIO

MAX_TIMEOUT_SECONDS = 600
POLL_INTERVAL_SECONDS = 0.05
# The console helper can use up to five seconds to stop and verify Screen.
PROCESS_STOP_TIMEOUT_SECONDS = 8
requested_signal: int | None = None


def _signal_handler(signum: int, _frame: FrameType | None) -> None:
    global requested_signal
    requested_signal = signum


def _require_regular_file(path: Path, description: str) -> Path:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError(f"{description} must be an absolute regular file")
    return path.resolve(strict=True)


def _require_private_directory(path: Path, description: str) -> Path:
    if not path.is_absolute() or path.is_symlink():
        raise ValueError(f"{description} must be an absolute real directory")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"{description} is unavailable") from error
    if not path.is_dir() or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise ValueError(f"{description} must be private to the current user")
    return resolved


def _stop_children(
    processes: list[subprocess.Popen[bytes]],
    terminate_process_group: Callable[[subprocess.Popen[bytes]], None],
    cvd_process: subprocess.Popen[bytes] | None,
) -> bool:
    active = [process for process in processes if process.poll() is None]
    if not active:
        return True
    cleanup_complete = True
    for process in active:
        try:
            process.send_signal(signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError:
            cleanup_complete = False

    deadline = time.monotonic() + PROCESS_STOP_TIMEOUT_SECONDS
    while active and time.monotonic() < deadline:
        active = [process for process in active if process.poll() is None]
        if cvd_process is not None and cvd_process in active:
            _forward_cvd_output(cvd_process, sys.stdout.buffer)
        if active:
            time.sleep(POLL_INTERVAL_SECONDS)

    for process in active:
        if process.poll() is None:
            try:
                terminate_process_group(process)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                cleanup_complete = False
    return cleanup_complete and all(process.poll() is not None for process in processes)


def _forward_cvd_output(
    process: subprocess.Popen[bytes],
    output_stream: BinaryIO,
) -> bool:
    if process.stdout is None:
        return False
    try:
        chunk = os.read(process.stdout.fileno(), 65_536)
    except BlockingIOError:
        return False
    if not chunk:
        return False
    output_stream.write(chunk)
    output_stream.flush()
    return True


def run_start_with_console(arguments: argparse.Namespace) -> int:
    global requested_signal

    if type(arguments.timeout_seconds) is not int or not (
        1 <= arguments.timeout_seconds <= MAX_TIMEOUT_SECONDS
    ):
        raise ValueError("startup timeout is outside the supported range")
    if type(arguments.handoff_timeout_seconds) is not int or not (
        1 <= arguments.handoff_timeout_seconds <= arguments.timeout_seconds
    ):
        raise ValueError("kernel-handoff timeout is outside the supported range")
    home = _require_private_directory(arguments.home, "Cuttlefish HOME")
    stage = _require_private_directory(arguments.stage, "capture stage")
    summary_root = _require_private_directory(
        arguments.summary_root,
        "summary workspace",
    )
    cvd_start_helper = _require_regular_file(
        arguments.cvd_start_helper,
        "Cuttlefish start helper",
    )
    console_helper = _require_regular_file(
        arguments.console_helper,
        "bootloader console helper",
    )
    if (
        not arguments.console_summary.is_absolute()
        or arguments.console_summary.parent.resolve(strict=True) != summary_root
        or arguments.console_summary.exists()
        or arguments.console_summary.is_symlink()
        or arguments.console_summary.name != "bootloader-console-summary.json"
    ):
        raise ValueError("console summary must be a new file in the summary workspace")
    if not arguments.group_name.startswith("apkrun_"):
        raise ValueError("Cuttlefish group name is outside the private namespace")
    if arguments.gpu_mode not in {"none", "guest_swiftshader"}:
        raise ValueError("GPU mode is unsupported")
    if arguments.console_enabled != "true":
        raise ValueError(
            "bootloader pause requires the Cuttlefish console to be enabled"
        )

    tool_directory = cvd_start_helper.parent
    sys.path.insert(0, str(tool_directory))
    try:
        import capture_cvd_start
    except ImportError as error:
        raise ValueError("verified Cuttlefish start helper is unavailable") from error

    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["TMPDIR"] = str(home)
    cvd_command = [
        sys.executable,
        str(cvd_start_helper),
        "--home",
        str(home),
        "--stage",
        str(stage),
        "--timeout-seconds",
        str(arguments.timeout_seconds),
        "--",
        "cvd",
        f"--group_name={arguments.group_name}",
        "start",
        f"--gpu_mode={arguments.gpu_mode}",
        "--gpu_vhost_user_mode=off",
        f"--console={str(arguments.console_enabled).lower()}",
        "--pause_in_bootloader=BOOTLOADER",
    ]
    console_command = [
        sys.executable,
        str(console_helper),
        "--home",
        str(home),
        "--result",
        str(arguments.console_summary),
        "--timeout-seconds",
        str(arguments.timeout_seconds),
        "--handoff-timeout-seconds",
        str(arguments.handoff_timeout_seconds),
    ]

    if requested_signal is not None:
        return 128 + requested_signal

    cvd_process: subprocess.Popen[bytes] | None = None
    console_process: subprocess.Popen[bytes] | None = None
    cvd_status: int | None = None
    console_status: int | None = None
    status = 1
    cleanup_complete = True
    deadline = time.monotonic() + arguments.timeout_seconds
    try:
        console_process = subprocess.Popen(
            console_command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=sys.stderr,
            start_new_session=True,
        )
        cancellation_signals = {signal.SIGINT, signal.SIGTERM}
        previous_signal_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK,
            cancellation_signals,
        )
        try:
            pending_cancellation = cancellation_signals.intersection(
                signal.sigpending()
            )
            if requested_signal is None and pending_cancellation:
                requested_signal = min(pending_cancellation)
            console_status = console_process.poll()
            if requested_signal is not None:
                status = 128 + requested_signal
            elif console_status is not None:
                status = console_status if console_status != 0 else 1
            else:
                cvd_process = subprocess.Popen(
                    cvd_command,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    # The parent masks signals across spawn; children must not
                    # inherit that mask or cleanup signals would stay pending.
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_SETMASK,
                        previous_signal_mask,
                    ),
                )
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

        if cvd_process is not None:
            assert cvd_process.stdout is not None
            os.set_blocking(cvd_process.stdout.fileno(), False)

            while True:
                if requested_signal is not None:
                    status = 128 + requested_signal
                    break

                if cvd_status is None:
                    cvd_status = cvd_process.poll()
                if console_status is None:
                    console_status = console_process.poll()

                _forward_cvd_output(cvd_process, sys.stdout.buffer)

                if cvd_status not in (None, 0):
                    status = cvd_status
                    break
                if console_status not in (None, 0):
                    status = console_status
                    break
                if time.monotonic() >= deadline:
                    status = 124
                    break
                if cvd_status == 0 and console_status == 0:
                    status = 0
                    break
                time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        children = [
            process for process in (console_process, cvd_process) if process is not None
        ]
        if children and not _stop_children(
            children,
            capture_cvd_start._terminate_child,
            cvd_process,
        ):
            cleanup_complete = False
        if cvd_process is not None:
            if cvd_process.stdout is not None:
                try:
                    cvd_process.stdout.close()
                except OSError:
                    cleanup_complete = False
            if cvd_process.returncode is not None:
                cvd_status = cvd_process.returncode
        if console_process is not None and console_process.returncode is not None:
            console_status = console_process.returncode

    if not cleanup_complete:
        return 1
    if requested_signal is not None:
        return 128 + requested_signal
    if status == 0 and (cvd_status != 0 or console_status != 0):
        return 1
    return status


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--summary-root", type=Path, required=True)
    parser.add_argument("--cvd-start-helper", type=Path, required=True)
    parser.add_argument("--console-helper", type=Path, required=True)
    parser.add_argument("--console-summary", type=Path, required=True)
    parser.add_argument("--group-name", required=True)
    parser.add_argument(
        "--gpu-mode",
        choices=("none", "guest_swiftshader"),
        required=True,
    )
    parser.add_argument("--console-enabled", choices=("true", "false"), required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--handoff-timeout-seconds", type=int, default=10)
    return parser.parse_args()


def main() -> int:
    global requested_signal
    requested_signal = None
    cancellation_signals = {signal.SIGINT, signal.SIGTERM}
    for number in cancellation_signals:
        signal.signal(number, _signal_handler)
    original_signal_mask = signal.pthread_sigmask(
        signal.SIG_BLOCK,
        cancellation_signals,
    )
    try:
        pending_cancellation = cancellation_signals.intersection(signal.sigpending())
        if requested_signal is None and pending_cancellation:
            requested_signal = min(pending_cancellation)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, cancellation_signals)
        try:
            return run_start_with_console(_parse_arguments())
        except (OSError, TypeError, ValueError) as error:
            print(f"run_cvd_with_console: {error}", file=sys.stderr)
            return 1
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, original_signal_mask)


if __name__ == "__main__":
    raise SystemExit(main())
