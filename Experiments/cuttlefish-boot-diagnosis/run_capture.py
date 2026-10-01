#!/usr/bin/env python3
"""Run the reference capture with a hard deadline and process-group cleanup."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

child: subprocess.Popen[bytes] | None = None
requested_signal: int | None = None


def _handle_signal(signum: int, _frame: object) -> None:
    global requested_signal
    requested_signal = signum
    if child is not None:
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass


def _group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _stop_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float,
) -> tuple[int | None, bool]:
    started = time.monotonic()
    post_kill_budget = min(1.0, grace_seconds / 2)
    terminate_budget = max(0, grace_seconds - post_kill_budget)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        pass
    try:
        process.wait(timeout=terminate_budget)
    except subprocess.TimeoutExpired:
        pass
    if _group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            pass
    deadline = started + grace_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None and not _group_exists(process.pid):
            return process.returncode, True
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    complete = process.poll() is not None and not _group_exists(process.pid)
    return process.returncode, complete


def _write_status(path: Path, status: dict[str, int | bool | None]) -> None:
    if path.is_symlink():
        raise ValueError("capture status path must not be a symlink")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            json.dump(status, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def supervise(
    command: list[str],
    timeout_seconds: float,
    cleanup_grace_seconds: float,
) -> dict[str, int | bool | None]:
    global child, requested_signal
    requested_signal = None
    if not command:
        raise ValueError("a capture command is required after --")
    if timeout_seconds <= 0 or cleanup_grace_seconds <= 0:
        raise ValueError("capture and cleanup deadlines must be positive")

    child = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + timeout_seconds
    timed_out = False
    cleanup_complete = True
    try:
        while child.poll() is None:
            if requested_signal is not None:
                _, cleanup_complete = _stop_group(child, cleanup_grace_seconds)
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                _, cleanup_complete = _stop_group(child, cleanup_grace_seconds)
                break
            try:
                child.wait(timeout=min(0.2, remaining))
            except subprocess.TimeoutExpired:
                continue
        if child.poll() is None or _group_exists(child.pid):
            _, cleanup_complete = _stop_group(child, cleanup_grace_seconds)
        child_exit = child.returncode
        return {
            "schemaVersion": 1,
            "childExitCode": child_exit,
            "timedOut": timed_out,
            "signal": requested_signal,
            "cleanupComplete": cleanup_complete and child_exit is not None,
        }
    finally:
        child = None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--cleanup-grace-seconds", type=float, default=140)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, _handle_signal)
    try:
        status = supervise(
            command,
            arguments.timeout_seconds,
            arguments.cleanup_grace_seconds,
        )
        _write_status(arguments.status, status)
    except (OSError, ValueError) as error:
        parser.exit(1, f"run_capture: {error}\n")
    if status["timedOut"]:
        return 124
    if status["signal"] is not None:
        return 128 + int(status["signal"])
    child_exit = status["childExitCode"]
    if child_exit is None:
        return 1
    return int(child_exit) if int(child_exit) >= 0 else 128 + abs(int(child_exit))


if __name__ == "__main__":
    raise SystemExit(main())
