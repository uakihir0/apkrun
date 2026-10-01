#!/usr/bin/env python3
"""Copy subprocess or stdin output to a file with a strict byte and time limit."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import capture_processes

READ_CHUNK_BYTES = 64 * 1024
STOP_GRACE_SECONDS = 1.0
POST_KILL_GRACE_SECONDS = 1.0
child: subprocess.Popen[bytes] | None = None
requested_signal: int | None = None


def _handle_signal(signum: int, _frame: object) -> None:
    global requested_signal
    requested_signal = signum


def _group_exists(group_id: int) -> bool:
    return capture_processes.process_group_has_live_members(group_id)


def _stop_child(process: subprocess.Popen[bytes]) -> bool:
    if process.returncode is not None:
        return False
    signal_failed = False
    try:
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGTERM,
        )
    except OSError:
        signal_failed = True
    terminate_deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < terminate_deadline:
        try:
            capture_processes.signal_adopted_descendants(
                process.pid,
                signal.SIGTERM,
            )
        except OSError:
            signal_failed = True
        root_exited = capture_processes.child_exit_observed_without_reaping(process)
        group_remains = _group_exists(process.pid)
        try:
            descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
        except OSError:
            signal_failed = True
            descendants_remain = True
        if root_exited and not group_remains and not descendants_remain:
            try:
                process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                return False
            return not signal_failed
        time.sleep(min(0.05, max(0, terminate_deadline - time.monotonic())))
    try:
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGKILL,
        )
    except OSError:
        signal_failed = True
    try:
        capture_processes.signal_adopted_descendants(
            process.pid,
            signal.SIGKILL,
        )
    except OSError:
        signal_failed = True
    deadline = time.monotonic() + POST_KILL_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            capture_processes.signal_adopted_descendants(
                process.pid,
                signal.SIGKILL,
            )
        except OSError:
            signal_failed = True
        root_exited = capture_processes.child_exit_observed_without_reaping(process)
        group_remains = _group_exists(process.pid)
        try:
            descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
        except OSError:
            signal_failed = True
            descendants_remain = True
        if root_exited and not group_remains and not descendants_remain:
            try:
                process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                return False
            return not signal_failed
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    root_exited = capture_processes.child_exit_observed_without_reaping(process)
    group_remains = _group_exists(process.pid)
    try:
        descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
    except OSError:
        signal_failed = True
        descendants_remain = True
    try:
        process.wait(timeout=0)
    except subprocess.TimeoutExpired:
        return False
    return (
        root_exited
        and not group_remains
        and not descendants_remain
        and not signal_failed
    )


def _finish_exited_child_group(process: subprocess.Popen[bytes]) -> bool:
    if process.returncode is not None:
        return False
    signal_failed = False
    try:
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGKILL,
        )
    except OSError:
        signal_failed = True
    try:
        capture_processes.signal_adopted_descendants(
            process.pid,
            signal.SIGKILL,
        )
    except OSError:
        signal_failed = True
    deadline = time.monotonic() + POST_KILL_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            capture_processes.signal_adopted_descendants(
                process.pid,
                signal.SIGKILL,
            )
        except OSError:
            signal_failed = True
        root_exited = capture_processes.child_exit_observed_without_reaping(process)
        group_remains = _group_exists(process.pid)
        try:
            descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
        except OSError:
            signal_failed = True
            descendants_remain = True
        if root_exited and not group_remains and not descendants_remain:
            try:
                process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                return False
            return not signal_failed
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    root_exited = capture_processes.child_exit_observed_without_reaping(process)
    group_remains = _group_exists(process.pid)
    try:
        descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
    except OSError:
        signal_failed = True
        descendants_remain = True
    try:
        process.wait(timeout=0)
    except subprocess.TimeoutExpired:
        return False
    return (
        root_exited
        and not group_remains
        and not descendants_remain
        and not signal_failed
    )


def _write_status(path: Path, status: dict[str, int | bool | None]) -> None:
    if path.is_symlink():
        raise ValueError("status destination must not be a symlink")
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


def _open_output(path: Path, *, append: bool) -> int:
    if path.is_symlink():
        raise ValueError("output must not be a symlink")
    if not append and path.exists():
        raise ValueError("output must be a new, non-symlink file")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    if append:
        flags |= os.O_APPEND
    else:
        flags |= os.O_EXCL
    return os.open(path, flags, 0o600)


def _capture_stdin(
    output: Path,
    status_path: Path,
    maximum_bytes: int,
    *,
    append: bool,
    drain_after_limit: bool = False,
) -> tuple[int, dict[str, int | bool | None]]:
    if maximum_bytes < 1:
        raise ValueError("maximum byte count must be positive")
    descriptor = _open_output(output, append=append)
    written = 0
    truncated = False
    input_eof = False
    selector: selectors.BaseSelector | None = None
    try:
        with os.fdopen(descriptor, "ab" if append else "wb") as destination:
            input_descriptor = sys.stdin.buffer.fileno()
            os.set_blocking(input_descriptor, False)
            selector = selectors.DefaultSelector()
            selector.register(input_descriptor, selectors.EVENT_READ)
            while True:
                if requested_signal is not None:
                    break
                events = selector.select(0.2)
                if not events:
                    continue
                read_limit = (
                    READ_CHUNK_BYTES
                    if drain_after_limit and truncated
                    else min(READ_CHUNK_BYTES, maximum_bytes - written + 1)
                )
                chunk = os.read(
                    input_descriptor,
                    read_limit,
                )
                if not chunk:
                    input_eof = True
                    break
                allowed = max(0, maximum_bytes - written)
                if allowed:
                    destination.write(chunk[:allowed])
                    written += min(len(chunk), allowed)
                if len(chunk) > allowed:
                    truncated = True
                    if not drain_after_limit:
                        break
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    finally:
        if selector is not None:
            selector.close()
    status: dict[str, int | bool | None] = {
        "schemaVersion": 1,
        "bytesWritten": written,
        "truncated": truncated,
        "childExitCode": None,
        "timedOut": False,
        "signal": requested_signal,
        "cleanupComplete": input_eof,
    }
    _write_status(status_path, status)
    if requested_signal is not None:
        return 128 + requested_signal, status
    return (75 if truncated else 0), status


def capture(
    command: list[str],
    output: Path,
    status_path: Path,
    maximum_bytes: int,
    timeout_seconds: float = 30,
    *,
    append: bool = False,
    fail_on_truncate: bool = False,
    merge_stderr: bool = False,
) -> tuple[int, dict[str, int | bool | None]]:
    global child, requested_signal
    requested_signal = None
    if not command:
        raise ValueError("a command is required after --")
    if maximum_bytes < 1:
        raise ValueError("maximum byte count must be positive")
    if timeout_seconds <= 0:
        raise ValueError("timeout must be positive")

    capture_processes.enable_child_subreaper()
    descriptor = _open_output(output, append=append)
    written = 0
    truncated = False
    timed_out = False
    child_exit: int | None = None
    selector: selectors.BaseSelector | None = None
    cleanup_complete = True
    try:
        with os.fdopen(descriptor, "ab" if append else "wb") as destination:
            child = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
                start_new_session=True,
            )
            assert child.stdout is not None
            os.set_blocking(child.stdout.fileno(), False)
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + timeout_seconds
            while True:
                if requested_signal is not None:
                    cleanup_complete = _stop_child(child)
                    child_exit = child.returncode
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    cleanup_complete = _stop_child(child)
                    child_exit = child.returncode
                    break
                events = selector.select(min(remaining, 0.2))
                if not events:
                    if capture_processes.child_exit_observed_without_reaping(child):
                        cleanup_complete = _finish_exited_child_group(child)
                        child_exit = child.returncode
                        break
                    continue
                chunk = os.read(
                    child.stdout.fileno(),
                    min(READ_CHUNK_BYTES, maximum_bytes - written + 1),
                )
                if not chunk:
                    break
                allowed = max(0, maximum_bytes - written)
                if allowed:
                    destination.write(chunk[:allowed])
                    written += min(len(chunk), allowed)
                if len(chunk) > allowed:
                    truncated = True
                    cleanup_complete = _stop_child(child)
                    child_exit = child.returncode
                    break
            if child_exit is None and child.returncode is None:
                while time.monotonic() < deadline:
                    if capture_processes.child_exit_observed_without_reaping(child):
                        break
                    if requested_signal is not None:
                        cleanup_complete = _stop_child(child)
                        child_exit = child.returncode
                        break
                    time.sleep(0.02)
                if child_exit is None and child.returncode is None:
                    if not capture_processes.child_exit_observed_without_reaping(child):
                        timed_out = True
                        cleanup_complete = _stop_child(child)
                    else:
                        cleanup_complete = _finish_exited_child_group(child)
                    child_exit = child.returncode
    except BaseException:
        if child is not None:
            _stop_child(child)
        output.unlink(missing_ok=True)
        raise
    finally:
        if selector is not None:
            selector.close()
        if child is not None and child.stdout is not None:
            child.stdout.close()
        child = None

    status: dict[str, int | bool | None] = {
        "schemaVersion": 1,
        "bytesWritten": written,
        "truncated": truncated,
        "childExitCode": child_exit,
        "timedOut": timed_out,
        "signal": requested_signal,
        "cleanupComplete": cleanup_complete and child_exit is not None,
    }
    _write_status(status_path, status)
    if requested_signal is not None:
        return 128 + requested_signal, status
    if timed_out:
        return 124, status
    if not status["cleanupComplete"]:
        return 1, status
    if truncated:
        return 75 if fail_on_truncate else 0, status
    if child_exit is None:
        return 1, status
    return child_exit if child_exit >= 0 else 128 + abs(child_exit), status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-bytes", type=int, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=30)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--append", action="store_true")
    parser.add_argument("--stdin", action="store_true")
    parser.add_argument("--drain-after-limit", action="store_true")
    parser.add_argument("--fail-on-truncate", action="store_true")
    parser.add_argument("--merge-stderr", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, _handle_signal)
    try:
        if arguments.stdin:
            if (
                command
                or arguments.timeout_seconds != 30
                or arguments.fail_on_truncate
                or arguments.merge_stderr
            ):
                parser.error(
                    "--stdin cannot be combined with a command, timeout, or "
                    "--fail-on-truncate or --merge-stderr"
                )
            exit_code, _ = _capture_stdin(
                arguments.output,
                arguments.status,
                arguments.max_bytes,
                append=arguments.append,
                drain_after_limit=arguments.drain_after_limit,
            )
        else:
            if arguments.append or arguments.drain_after_limit:
                parser.error(
                    "--append and --drain-after-limit are only valid with --stdin"
                )
            exit_code, _ = capture(
                command,
                arguments.output,
                arguments.status,
                arguments.max_bytes,
                arguments.timeout_seconds,
                fail_on_truncate=arguments.fail_on_truncate,
                merge_stderr=arguments.merge_stderr,
            )
    except (OSError, ValueError) as error:
        parser.exit(1, f"capture_bounded: {error}\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
