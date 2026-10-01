#!/usr/bin/env python3
"""Run the reference capture with a hard deadline and process-group cleanup."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import tempfile
import time
from collections.abc import Callable
from pathlib import Path

import capture_processes

child: subprocess.Popen[bytes] | None = None
requested_signal: int | None = None
finalizing = False
final_status_path: Path | None = None


def _read_regular_file(path: Path, maximum_bytes: int, description: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"{description} must be a regular file")
        content = bytearray()
        while chunk := os.read(
            descriptor,
            min(64 * 1024, maximum_bytes + 1 - len(content)),
        ):
            content.extend(chunk)
            if len(content) > maximum_bytes:
                raise ValueError(f"{description} exceeds the size limit")
        return bytes(content)
    finally:
        os.close(descriptor)


def _open_verified_script_snapshot(script_path: Path, expected_sha256: str) -> int:
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise ValueError("verified capture script SHA-256 is invalid")
    if (
        not hasattr(os, "memfd_create")
        or not hasattr(fcntl, "F_ADD_SEALS")
        or not hasattr(fcntl, "F_GET_SEALS")
        or not hasattr(fcntl, "F_SEAL_SEAL")
        or not hasattr(fcntl, "F_SEAL_SHRINK")
        or not hasattr(fcntl, "F_SEAL_GROW")
        or not hasattr(fcntl, "F_SEAL_WRITE")
    ):
        raise OSError("sealed in-memory capture scripts are unavailable")

    source = _read_regular_file(
        script_path,
        8 * 1024 * 1024,
        "verified capture script",
    )
    if hashlib.sha256(source).hexdigest() != expected_sha256:
        raise ValueError("capture script differs from its verified SHA-256")

    descriptor = os.memfd_create("apkrun-capture-script", os.MFD_ALLOW_SEALING)
    try:
        offset = 0
        while offset < len(source):
            written = os.write(descriptor, source[offset:])
            if written <= 0:
                raise OSError("could not write the capture script snapshot")
            offset += written
        os.lseek(descriptor, 0, os.SEEK_SET)
        required_seals = (
            fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_WRITE
        )
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, required_seals)
        actual_seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        if actual_seals & required_seals != required_seals:
            raise OSError("capture script snapshot could not be sealed")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _verified_capture_sha256(host_identity_path: Path) -> str:
    try:
        identity_bytes = _read_regular_file(
            host_identity_path,
            1024 * 1024,
            "verified capture host identity",
        )
        host_identity = json.loads(identity_bytes)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("verified capture host identity is unreadable") from error
    if not isinstance(host_identity, dict):
        raise TypeError("verified capture host identity must be a JSON object")
    experiment_sources = host_identity.get("experimentSources")
    if not isinstance(experiment_sources, dict):
        raise TypeError("verified capture source map is missing")
    digest = experiment_sources.get("patched-capture.sh")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("verified capture source digest is invalid")
    return digest


def _handle_signal(signum: int, _frame: object) -> None:
    global requested_signal
    if finalizing:
        marker_created = False
        status_invalidated = False
        if final_status_path is not None:
            marker_path = final_status_path.with_name(
                f"{final_status_path.name}.interrupted"
            )
            try:
                descriptor = os.open(
                    marker_path,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                )
            except FileExistsError:
                marker_created = True
            except OSError:
                pass
            else:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                marker_created = True
            try:
                final_status_path.unlink(missing_ok=True)
                status_invalidated = True
            except OSError:
                pass
        if marker_created and status_invalidated:
            raise SystemExit(128 + signum)
        raise SystemExit(125)
    requested_signal = signum


def _group_exists(group_id: int) -> bool:
    return capture_processes.process_group_has_live_members(group_id)


def _stop_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float,
    drain_output: Callable[[float], None] | None = None,
) -> tuple[int | None, bool]:
    started = time.monotonic()
    terminate_budget = max(0, grace_seconds - min(1.0, grace_seconds / 2))
    if process.returncode is not None:
        return process.returncode, False
    signal_failed = False
    try:
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGTERM,
        )
    except OSError:
        signal_failed = True
    terminate_deadline = started + terminate_budget
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
                child_exit = process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                return process.returncode, False
            return child_exit, not signal_failed
        remaining = terminate_deadline - time.monotonic()
        if drain_output is not None:
            drain_output(min(0.2, max(0, remaining)))
        else:
            time.sleep(min(0.05, max(0, remaining)))
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
    deadline = started + grace_seconds
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
                child_exit = process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                return process.returncode, False
            return child_exit, not signal_failed
        remaining = deadline - time.monotonic()
        if drain_output is not None:
            drain_output(min(0.05, max(0, remaining)))
        else:
            time.sleep(min(0.05, max(0, remaining)))
    root_exited = capture_processes.child_exit_observed_without_reaping(process)
    group_remains = _group_exists(process.pid)
    try:
        descendants_remain = capture_processes.reap_adopted_descendants(process.pid)
    except OSError:
        signal_failed = True
        descendants_remain = True
    complete = root_exited and not group_remains and not descendants_remain
    try:
        child_exit = process.wait(timeout=0)
    except subprocess.TimeoutExpired:
        child_exit = process.returncode
        complete = False
    return child_exit, complete and not signal_failed


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


def _open_output(path: Path) -> int:
    if path.is_symlink() or path.exists():
        raise ValueError("capture output must be a new, non-symlink file")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags, 0o600)


def supervise(
    command: list[str],
    timeout_seconds: float,
    cleanup_grace_seconds: float,
    *,
    output_log: Path | None = None,
    output_status: Path | None = None,
    maximum_output_bytes: int = 1_048_576,
    pass_fds: tuple[int, ...] = (),
) -> dict[str, int | bool | None]:
    global child
    if not command:
        raise ValueError("a capture command is required after --")
    if timeout_seconds <= 0 or cleanup_grace_seconds <= 0:
        raise ValueError("capture and cleanup deadlines must be positive")
    if maximum_output_bytes < 1:
        raise ValueError("maximum output byte count must be positive")
    if (output_log is None) != (output_status is None):
        raise ValueError(
            "capture output log and status paths must be provided together"
        )
    if output_log is not None and output_status is not None:
        if output_log.resolve() == output_status.resolve():
            raise ValueError("capture output log and status paths must be distinct")
        if output_status.is_symlink() or output_status.exists():
            raise ValueError("capture output status must be a new, non-symlink file")

    output_descriptor: int | None = None
    output_selector: selectors.BaseSelector | None = None
    output_eof = output_log is None
    output_bytes_written = 0
    output_truncated = False
    output_write_failed = False
    child_exit: int | None = None
    timed_out = False
    cleanup_complete = True

    def drain_output(wait_seconds: float) -> None:
        nonlocal output_bytes_written
        nonlocal output_eof
        nonlocal output_truncated
        nonlocal output_write_failed
        if output_selector is None or output_eof:
            return
        for key, _ in output_selector.select(wait_seconds):
            try:
                chunk = os.read(key.fileobj.fileno(), 64 * 1024)
            except OSError:
                output_write_failed = True
                chunk = b""
            if not chunk:
                output_selector.unregister(key.fileobj)
                output_eof = True
                continue
            allowed = max(0, maximum_output_bytes - output_bytes_written)
            if allowed:
                payload = chunk[:allowed]
                offset = 0
                while offset < len(payload) and not output_write_failed:
                    try:
                        written = os.write(output_descriptor, payload[offset:])
                    except OSError:
                        output_write_failed = True
                        break
                    if written <= 0:
                        output_write_failed = True
                        break
                    offset += written
                    output_bytes_written += written
            if len(chunk) > allowed:
                output_truncated = True

    try:
        if output_log is not None:
            output_descriptor = _open_output(output_log)
        capture_processes.enable_child_subreaper()
        child = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if output_log is not None else subprocess.DEVNULL,
            stderr=subprocess.STDOUT if output_log is not None else subprocess.DEVNULL,
            start_new_session=True,
            pass_fds=pass_fds,
        )
        if child.stdout is not None:
            os.set_blocking(child.stdout.fileno(), False)
            output_selector = selectors.DefaultSelector()
            output_selector.register(child.stdout, selectors.EVENT_READ)
            output_eof = False

        deadline = time.monotonic() + timeout_seconds
        stop_attempted = False
        while not capture_processes.child_exit_observed_without_reaping(child):
            if requested_signal is not None:
                _, cleanup_complete = _stop_group(
                    child,
                    cleanup_grace_seconds,
                    drain_output,
                )
                stop_attempted = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                _, cleanup_complete = _stop_group(
                    child,
                    cleanup_grace_seconds,
                    drain_output,
                )
                stop_attempted = True
                break
            if output_selector is None or output_eof:
                time.sleep(min(0.05, remaining))
                continue
            drain_output(min(0.2, remaining))

        if not stop_attempted and child.returncode is None:
            _, cleanup_complete = _stop_group(
                child,
                cleanup_grace_seconds,
                drain_output,
            )
            stop_attempted = True
            child_exit = child.returncode
        else:
            child_exit = child.returncode

        if output_selector is not None and not output_eof:
            drain_deadline = time.monotonic() + 1.0
            while not output_eof and time.monotonic() < drain_deadline:
                drain_output(min(0.2, max(0, drain_deadline - time.monotonic())))
            if not output_eof:
                cleanup_complete = False
        cleanup_complete = cleanup_complete and not output_write_failed

        if output_status is not None:
            _write_status(
                output_status,
                {
                    "schemaVersion": 1,
                    "bytesWritten": output_bytes_written,
                    "truncated": output_truncated,
                    "timedOut": timed_out,
                    "childExitCode": child_exit,
                    "signal": requested_signal,
                    "cleanupComplete": cleanup_complete and output_eof,
                },
            )
        return {
            "schemaVersion": 1,
            "childExitCode": child_exit,
            "timedOut": timed_out,
            "signal": requested_signal,
            "cleanupComplete": cleanup_complete and child_exit is not None,
        }
    except BaseException:
        if child is not None:
            try:
                _, cleanup_complete = _stop_group(
                    child,
                    cleanup_grace_seconds,
                    drain_output,
                )
                child_exit = child.returncode
            except BaseException:  # noqa: BLE001
                # Keep cleanup failures from masking the original supervisor error.
                cleanup_complete = False
                child_exit = child.poll()
        if output_status is not None:
            try:
                _write_status(
                    output_status,
                    {
                        "schemaVersion": 1,
                        "bytesWritten": output_bytes_written,
                        "truncated": output_truncated,
                        "timedOut": timed_out,
                        "childExitCode": child_exit,
                        "signal": requested_signal,
                        "cleanupComplete": False,
                    },
                )
            except (OSError, ValueError):
                pass
        raise
    finally:
        if output_selector is not None:
            output_selector.close()
        if child is not None and child.stdout is not None:
            child.stdout.close()
        child = None
        if output_descriptor is not None:
            os.close(output_descriptor)


def main() -> int:
    global final_status_path, finalizing, requested_signal
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--cleanup-grace-seconds", type=float, default=140)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--output-log", type=Path)
    parser.add_argument("--output-status", type=Path)
    parser.add_argument("--max-output-bytes", type=int, default=1_048_576)
    parser.add_argument("--verified-script", type=Path)
    parser.add_argument("--host-identity", type=Path)
    parser.add_argument("--script-argument", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    script_descriptor: int | None = None
    pass_fds: tuple[int, ...] = ()
    if arguments.verified_script is not None:
        if command or arguments.host_identity is None:
            parser.error(
                "--verified-script requires --host-identity and cannot "
                "be combined with a command"
            )
        try:
            script_descriptor = _open_verified_script_snapshot(
                arguments.verified_script,
                _verified_capture_sha256(arguments.host_identity),
            )
        except (OSError, TypeError, ValueError) as error:
            parser.exit(1, f"run_capture: {error}\n")
        command = [
            "/bin/bash",
            f"/proc/self/fd/{script_descriptor}",
            *arguments.script_argument,
        ]
        pass_fds = (script_descriptor,)
    elif arguments.host_identity is not None or arguments.script_argument:
        parser.error("--host-identity and --script-argument require --verified-script")
    requested_signal = None
    finalizing = False
    final_status_path = arguments.status
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, _handle_signal)
    try:
        status = supervise(
            command,
            arguments.timeout_seconds,
            arguments.cleanup_grace_seconds,
            output_log=arguments.output_log,
            output_status=arguments.output_status,
            maximum_output_bytes=arguments.max_output_bytes,
            pass_fds=pass_fds,
        )
        finalizing = True
        if requested_signal is not None:
            status["signal"] = requested_signal
        _write_status(arguments.status, status)
    except (OSError, TypeError, ValueError) as error:
        parser.exit(1, f"run_capture: {error}\n")
    finally:
        if script_descriptor is not None:
            os.close(script_descriptor)
    if status["timedOut"]:
        return 124
    if status["signal"] is not None:
        return 128 + int(status["signal"])
    if status["childExitCode"] is None or status["cleanupComplete"] is not True:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
