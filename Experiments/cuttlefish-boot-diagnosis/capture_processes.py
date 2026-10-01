"""Safely stop supervised process groups and orphaned Linux descendants."""

from __future__ import annotations

import ctypes
import errno
import os
import subprocess
import sys
from pathlib import Path

_DARWIN_SIGINFO_PID_OFFSET = 12
_LINUX_PR_SET_CHILD_SUBREAPER = 36


def enable_child_subreaper() -> bool:
    """Adopt orphaned Linux descendants so the supervisor can clean them up."""
    if sys.platform != "linux":
        return False

    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, "prctl", None)
    if prctl is None:
        raise RuntimeError("Linux child subreaper support is unavailable")
    prctl.argtypes = (
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    )
    prctl.restype = ctypes.c_int
    if prctl(_LINUX_PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return True


def _direct_child_process_ids() -> list[int]:
    children_path = Path("/proc/self/task") / str(os.getpid()) / "children"
    try:
        contents = children_path.read_text(encoding="ascii")
    except OSError as error:
        raise RuntimeError("could not inspect adopted Linux descendants") from error
    try:
        return [int(value) for value in contents.split()]
    except ValueError as error:
        raise RuntimeError("Linux adopted-descendant list is malformed") from error


def signal_adopted_descendants(
    supervised_pid: int,
    signum: int,
) -> bool:
    """Signal adopted descendants while their unreaped child PIDs stay reserved."""
    if sys.platform != "linux":
        return False

    descendant_pids = [
        process_id
        for process_id in _direct_child_process_ids()
        if process_id != supervised_pid
    ]
    signal_error: OSError | None = None
    for process_id in descendant_pids:
        try:
            os.kill(process_id, signum)
        except ProcessLookupError:
            # The PID remains reserved until this supervisor reaps the child.
            continue
        except OSError as error:
            if signal_error is None:
                signal_error = error
    if signal_error is not None:
        raise signal_error
    return bool(descendant_pids)


def reap_adopted_descendants(supervised_pid: int) -> bool:
    """Reap adopted descendants and report whether any remain alive."""
    if sys.platform != "linux":
        return False

    for process_id in _direct_child_process_ids():
        if process_id == supervised_pid:
            continue
        try:
            os.waitpid(process_id, os.WNOHANG)
        except ChildProcessError:
            continue
    return any(
        process_id != supervised_pid for process_id in _direct_child_process_ids()
    )


def child_exit_observed_without_reaping(
    process: subprocess.Popen[bytes],
) -> bool:
    """Observe child exit while keeping its PID reserved for safe group signals."""
    if process.returncode is not None:
        return True

    options = os.WEXITED | os.WNOHANG | os.WNOWAIT
    if hasattr(os, "waitid"):
        result = os.waitid(os.P_PID, process.pid, options)
        return result is not None and result.si_pid == process.pid

    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        waitid = getattr(libc, "waitid", None)
        if waitid is None:
            raise RuntimeError("waitid is unavailable for safe process cleanup")
        waitid.argtypes = (
            ctypes.c_int,
            ctypes.c_uint,
            ctypes.c_void_p,
            ctypes.c_int,
        )
        waitid.restype = ctypes.c_int
        information = ctypes.create_string_buffer(128)
        while True:
            result = waitid(
                os.P_PID,
                process.pid,
                ctypes.cast(information, ctypes.c_void_p),
                options,
            )
            if result == 0:
                break
            error_number = ctypes.get_errno()
            if error_number == errno.EINTR:
                continue
            raise OSError(error_number, os.strerror(error_number))
        process_id = ctypes.c_int.from_buffer(
            information,
            _DARWIN_SIGINFO_PID_OFFSET,
        ).value
        return process_id == process.pid

    raise RuntimeError("waitid is unavailable for safe process cleanup")


def signal_process_group_while_child_is_pinned(
    process: subprocess.Popen[bytes],
    signum: int,
) -> bool:
    """Signal the child's group only while its unreaped PID prevents reuse."""
    if process.returncode is not None:
        raise RuntimeError(
            "refusing to signal a process group after reaping its leader"
        )
    if child_exit_observed_without_reaping(
        process
    ) and not process_group_has_live_members(
        process.pid,
        excluding_pid=process.pid,
    ):
        return False
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        return False
    except PermissionError:
        if child_exit_observed_without_reaping(process) and not (
            process_group_has_live_members(
                process.pid,
                excluding_pid=process.pid,
            )
        ):
            return False
        raise
    return True


def process_group_has_live_members(
    group_id: int,
    *,
    excluding_pid: int | None = None,
) -> bool:
    """Check for live members without treating zombies as active work."""
    if sys.platform == "linux":
        process_root = Path("/proc")
        try:
            entries = list(process_root.iterdir())
        except OSError as error:
            raise RuntimeError("could not inspect Linux process groups") from error
        for entry in entries:
            if not entry.name.isdigit():
                continue
            process_id = int(entry.name)
            if process_id == excluding_pid:
                continue
            try:
                stat_record = (entry / "stat").read_bytes()
            except FileNotFoundError:
                continue
            except OSError as error:
                raise RuntimeError("could not inspect Linux process groups") from error
            closing_parenthesis = stat_record.rfind(b")")
            if closing_parenthesis < 0:
                raise RuntimeError("Linux process stat record is malformed")
            fields = stat_record[closing_parenthesis + 1 :].split()
            if len(fields) < 3:
                raise RuntimeError("Linux process stat record is incomplete")
            try:
                state = fields[0].decode("ascii")
                process_group = int(fields[2])
            except (UnicodeDecodeError, ValueError) as error:
                raise RuntimeError("Linux process stat record is invalid") from error
            if process_group == group_id and state not in {"Z", "X"}:
                return True
        return False

    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["ps", "-o", "pid=,pgid=,stat=", "-g", str(group_id)],
                capture_output=True,
                check=False,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError("could not inspect macOS process groups") from error
        if result.returncode not in {0, 1}:
            raise RuntimeError("could not inspect macOS process groups")
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) < 3:
                continue
            try:
                process_id, process_group = int(fields[0]), int(fields[1])
            except ValueError as error:
                raise RuntimeError("macOS process listing is malformed") from error
            state = fields[2]
            if (
                process_group == group_id
                and process_id != excluding_pid
                and not state.startswith(("Z", "X"))
            ):
                return True
        return False

    raise RuntimeError("process-group inspection is unsupported on this platform")
