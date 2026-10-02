#!/usr/bin/env python3
"""Continue a paused Cuttlefish boot through its private Screen console."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import stat
import struct
import sys
import tempfile
import termios
import time
import tty
from pathlib import Path
from types import FrameType
from typing import Any

MAX_TIMEOUT_SECONDS = 600
MAX_OUTPUT_BYTES = 65_536
DEFAULT_HANDOFF_TIMEOUT_SECONDS = 10
POLL_INTERVAL_SECONDS = 0.1
CHILD_STOP_GRACE_SECONDS = 2
CHILD_DESCENDANT_GRACE_SECONDS = 0.5
U_BOOT_BANNER = re.compile(r"(?m)^[ \t]*U-Boot(?:[ \t]+SPL)?[ \t]+v?\d{4}\.\d{2}\b.*$")
UBOOT_PROMPT = re.compile(r"(?:^|\n)\s*=>\s*$")
KERNEL_HANDOFF = re.compile(r"Starting kernel|Booting Linux on physical CPU")
requested_signal: int | None = None


def _is_utf8_continuation(data: bytes, index: int) -> bool:
    if not 0x80 <= data[index] <= 0xBF:
        return False
    for distance in range(1, min(index, 3) + 1):
        start = index - distance
        lead = data[start]
        if 0xC2 <= lead <= 0xDF:
            sequence_length = 2
            first_continuation_min = 0x80
            first_continuation_max = 0xBF
        elif 0xE0 <= lead <= 0xEF:
            sequence_length = 3
            first_continuation_min = 0xA0 if lead == 0xE0 else 0x80
            first_continuation_max = 0x9F if lead == 0xED else 0xBF
        elif 0xF0 <= lead <= 0xF4:
            sequence_length = 4
            first_continuation_min = 0x90 if lead == 0xF0 else 0x80
            first_continuation_max = 0x8F if lead == 0xF4 else 0xBF
        else:
            continue
        if distance >= sequence_length:
            continue
        prefix = data[start + 1 : index + 1]
        if not all(0x80 <= byte <= 0xBF for byte in prefix):
            continue
        if not first_continuation_min <= prefix[0] <= first_continuation_max:
            continue
        end = start + sequence_length
        if end > len(data):
            return True
        try:
            decoded = data[start:end].decode("utf-8")
        except UnicodeDecodeError:
            continue
        if len(decoded) == 1:
            return True
    return False


def _skip_control_string(
    data: bytes,
    index: int,
    *,
    bell_terminates: bool,
) -> int:
    while index < len(data):
        if (
            data[index] == 0x9C
            and not _is_utf8_continuation(data, index)
            or bell_terminates
            and data[index] == 0x07
        ):
            return index + 1
        if data[index] == 0x1B:
            if index + 1 >= len(data):
                return len(data)
            if data[index + 1] == ord("\\"):
                return index + 2
            index += 1
            continue
        index += 1
    return index


def _strip_ansi_escape_sequences(data: bytes) -> bytes:
    result = bytearray()
    index = 0
    while index < len(data):
        if data[index] == 0x9B and not _is_utf8_continuation(data, index):
            index += 1
            while index < len(data) and not 0x40 <= data[index] <= 0x7E:
                index += 1
            if index < len(data):
                index += 1
            continue

        if data[index] == 0x9D and not _is_utf8_continuation(data, index):
            index = _skip_control_string(data, index + 1, bell_terminates=True)
            continue

        if data[index] in (0x90, 0x98, 0x9E, 0x9F) and not _is_utf8_continuation(
            data, index
        ):
            index = _skip_control_string(data, index + 1, bell_terminates=False)
            continue

        if data[index] != 0x1B:
            result.append(data[index])
            index += 1
            continue
        if index + 1 >= len(data):
            break

        introducer = data[index + 1]
        if introducer == ord("["):
            index += 2
            while index < len(data) and not 0x40 <= data[index] <= 0x7E:
                index += 1
            if index < len(data):
                index += 1
            continue

        if introducer == ord("]"):
            index = _skip_control_string(data, index + 2, bell_terminates=True)
            continue

        if introducer in (ord("P"), ord("X"), ord("^"), ord("_")):
            index = _skip_control_string(data, index + 2, bell_terminates=False)
            continue

        index += 1
        while index < len(data) and 0x20 <= data[index] <= 0x2F:
            index += 1
        if index < len(data) and 0x30 <= data[index] <= 0x7E:
            index += 1
    return bytes(result)


def _signal_handler(signum: int, _frame: FrameType | None) -> None:
    global requested_signal
    requested_signal = signum


def _private_directory(path: Path, description: str) -> Path:
    if not path.is_absolute() or path.is_symlink():
        raise ValueError(f"{description} must be an absolute real directory")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.stat(follow_symlinks=False)
    except OSError as error:
        raise ValueError(f"{description} is unavailable") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o077
    ):
        raise ValueError(f"{description} must be private to the current user")
    return resolved


def _private_result_path(path: Path) -> Path:
    if not path.is_absolute() or path.is_symlink() or path.exists():
        raise ValueError("result path must be unused and absolute")
    parent = _private_directory(path.parent, "result directory")
    if path.name != "bootloader-console-summary.json":
        raise ValueError("result path must use the expected summary name")
    return parent / path.name


def _is_current_user_devpts_character_device(
    path: Path,
    metadata: os.stat_result,
) -> bool:
    devpts_root = Path("/dev/pts")
    if (
        path.parent != devpts_root
        or not path.name.isascii()
        or not path.name.isdecimal()
        or not stat.S_ISCHR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
    ):
        return False
    try:
        root_metadata = devpts_root.stat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(root_metadata.st_mode)
        and root_metadata.st_uid == 0
        and not root_metadata.st_mode & 0o022
    )


def _console_endpoint(home: Path) -> Path | None:
    runtime_directory = home / "cuttlefish_runtime"
    endpoint = runtime_directory / "console"
    for path, is_directory in (
        (runtime_directory, True),
        (endpoint, False),
    ):
        description = "runtime directory" if is_directory else "console endpoint"
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            return None
        except OSError as error:
            raise ValueError(
                f"private Cuttlefish {description} is unavailable"
            ) from error
        if metadata.st_uid != os.getuid():
            raise ValueError(
                f"private Cuttlefish {description} has an unexpected owner"
            )
        if stat.S_ISLNK(metadata.st_mode):
            try:
                target = path.resolve(strict=True)
                target_metadata = target.stat()
            except OSError as error:
                raise ValueError(
                    f"private Cuttlefish {description} symlink target is unavailable"
                ) from error
            target_type = next(
                (
                    name
                    for name, matches in (
                        ("directory", stat.S_ISDIR(target_metadata.st_mode)),
                        ("socket", stat.S_ISSOCK(target_metadata.st_mode)),
                        ("fifo", stat.S_ISFIFO(target_metadata.st_mode)),
                        ("character-device", stat.S_ISCHR(target_metadata.st_mode)),
                        ("regular-file", stat.S_ISREG(target_metadata.st_mode)),
                        ("block-device", stat.S_ISBLK(target_metadata.st_mode)),
                    )
                    if matches
                ),
                "other",
            )
            target_location = (
                "within-home"
                if target == home or target.is_relative_to(home)
                else "outside-home"
            )
            if target_metadata.st_uid != os.getuid():
                raise ValueError(
                    f"private Cuttlefish {description} symlink target has an "
                    "unexpected owner"
                )
            if target_location != "within-home" and not (
                not is_directory
                and _is_current_user_devpts_character_device(
                    target,
                    target_metadata,
                )
            ):
                raise ValueError(
                    f"private Cuttlefish {description} symlink resolves outside "
                    f"its HOME ({target_type})"
                )
            metadata = target_metadata
        if is_directory and not stat.S_ISDIR(metadata.st_mode):
            raise ValueError("private Cuttlefish runtime path is not a directory")
        if not is_directory and stat.S_ISDIR(metadata.st_mode):
            raise ValueError("private Cuttlefish console endpoint is a directory")
        if is_directory:
            runtime_directory = path.resolve(strict=True)
        else:
            endpoint = path.resolve(strict=True)
    if not endpoint.is_relative_to(home):
        try:
            endpoint_metadata = endpoint.stat()
        except OSError as error:
            raise ValueError(
                "private Cuttlefish console endpoint is unavailable"
            ) from error
        if not _is_current_user_devpts_character_device(
            endpoint,
            endpoint_metadata,
        ):
            raise ValueError("private Cuttlefish console endpoint escaped its HOME")
    return endpoint


def _write_result(path: Path, document: dict[str, Any]) -> None:
    encoded = (json.dumps(document, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        stream = os.fdopen(descriptor, "wb")
        descriptor = -1
        with stream:
            stream.write(encoded)
            stream.flush()
        os.link(temporary_path, path, follow_symlinks=False)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass


def _child_exit_code(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    return 1


def _try_observe_child_exit(pid: int) -> tuple[bool, int | None]:
    try:
        child = os.waitid(
            os.P_PID,
            pid,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except (AttributeError, ChildProcessError, OSError, TypeError):
        return False, None
    if child is None or child.si_pid == 0:
        return False, None
    if child.si_code == os.CLD_EXITED:
        return True, child.si_status
    return True, -child.si_status


def _try_reap(pid: int) -> tuple[bool, int | None]:
    try:
        waited, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return False, None
    if waited == 0:
        return False, None
    return True, _child_exit_code(status)


def _process_group_exists(process_group: int) -> bool | None:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return None
    except OSError:
        return None
    return True


def _live_linux_group_descendants(process_group: int, leader_pid: int) -> bool | None:
    if sys.platform != "linux":
        return None
    try:
        entries = list(Path("/proc").iterdir())
    except OSError:
        return None
    for entry in entries:
        if not entry.name.isdigit() or int(entry.name) == leader_pid:
            continue
        try:
            fields = (
                (entry / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()
            )
        except FileNotFoundError:
            continue
        except (IndexError, OSError, UnicodeDecodeError):
            continue
        try:
            process_state = fields[0]
            observed_group = int(fields[2])
        except (IndexError, ValueError):
            return None
        if observed_group == process_group and process_state not in {"Z", "X"}:
            return True
    return False


def _stop_screen(
    pid: int,
    master_fd: int,
) -> tuple[int | None, bool, str | None, int | None]:
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except OSError as error:
        return None, False, "term-signal-failed", error.errno

    use_waitid = callable(getattr(os, "waitid", None))
    deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
    observed_exit_code: int | None = None
    leader_exited = False
    while time.monotonic() < deadline:
        if use_waitid:
            leader_exited, observed_exit_code = _try_observe_child_exit(pid)
            if leader_exited:
                break
        else:
            group_exists = _process_group_exists(pid)
            if group_exists is False:
                reaped, observed_exit_code = _try_reap(pid)
                if reaped:
                    return observed_exit_code, True, None, None
        try:
            select.select([master_fd], [], [], POLL_INTERVAL_SECONDS)
            os.read(master_fd, 4096)
        except (OSError, ValueError):
            time.sleep(POLL_INTERVAL_SECONDS)

    if leader_exited:
        time.sleep(CHILD_DESCENDANT_GRACE_SECONDS)
        live_descendants = _live_linux_group_descendants(pid, pid)
        if live_descendants is False:
            reaped, observed_exit_code = _try_reap(pid)
            if reaped:
                return observed_exit_code, True, None, None
            return None, False, "child-not-reaped", None
    elif not use_waitid and _process_group_exists(pid) is False:
        deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
        while time.monotonic() < deadline:
            reaped, observed_exit_code = _try_reap(pid)
            if reaped:
                return observed_exit_code, True, None, None
            time.sleep(POLL_INTERVAL_SECONDS)
        return None, False, "child-not-reaped", None

    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as error:
        deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
        while time.monotonic() < deadline:
            reaped, observed_exit_code = _try_reap(pid)
            if reaped:
                return (
                    observed_exit_code,
                    False,
                    "kill-signal-failed",
                    error.errno,
                )
            time.sleep(POLL_INTERVAL_SECONDS)
        return None, False, "kill-signal-failed", error.errno

    deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        reaped, observed_exit_code = _try_reap(pid)
        if reaped:
            break
        time.sleep(POLL_INTERVAL_SECONDS)
    else:
        return None, False, "child-not-reaped", None

    if sys.platform == "linux":
        deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
        while time.monotonic() < deadline:
            live_descendants = _live_linux_group_descendants(pid, pid)
            if live_descendants is False:
                return observed_exit_code, True, None, None
            if live_descendants is None:
                return observed_exit_code, False, "process-group-unverified", None
            time.sleep(POLL_INTERVAL_SECONDS)
        return observed_exit_code, False, "process-group-remains", None
    deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        group_exists = _process_group_exists(pid)
        if group_exists is False:
            return observed_exit_code, True, None, None
        if group_exists is None:
            return observed_exit_code, False, "process-group-unverified", None
        time.sleep(POLL_INTERVAL_SECONDS)
    return observed_exit_code, False, "process-group-remains", None


def _start_screen(
    screen_program: Path,
    endpoint: Path,
    home: Path,
) -> tuple[int, int]:
    master_fd, slave_fd = pty.openpty()
    ready_read_fd, ready_write_fd = os.pipe()
    try:
        tty.setraw(slave_fd)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.set_blocking(master_fd, False)
        pid = os.fork()
    except OSError:
        for descriptor in (master_fd, slave_fd, ready_read_fd, ready_write_fd):
            os.close(descriptor)
        raise

    if pid == 0:
        os.close(ready_read_fd)
        try:
            os.setsid()
            fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
            for descriptor in (0, 1, 2):
                os.dup2(slave_fd, descriptor)
            if slave_fd > 2:
                os.close(slave_fd)
            os.close(master_fd)
            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(home),
                    "TERM": "xterm",
                    "LC_ALL": "C",
                }
            )
            os.write(ready_write_fd, b"R")
            os.close(ready_write_fd)
            os.execve(
                str(screen_program),
                [str(screen_program), "-c", "/dev/null", str(endpoint)],
                environment,
            )
        except OSError:
            try:
                os.write(ready_write_fd, b"E")
            except OSError:
                pass
            os._exit(127)

    os.close(slave_fd)
    os.close(ready_write_fd)
    ready, _, _ = select.select(
        [ready_read_fd],
        [],
        [],
        CHILD_STOP_GRACE_SECONDS,
    )
    ready_status = os.read(ready_read_fd, 1) if ready else b""
    os.close(ready_read_fd)
    if ready_status != b"R":
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
        while time.monotonic() < deadline:
            reaped, _ = _try_reap(pid)
            if reaped:
                os.close(master_fd)
                raise OSError("Screen did not establish its private terminal")
            time.sleep(POLL_INTERVAL_SECONDS)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + CHILD_STOP_GRACE_SECONDS
        while time.monotonic() < deadline:
            reaped, _ = _try_reap(pid)
            if reaped:
                os.close(master_fd)
                raise OSError("Screen did not establish its private terminal")
            time.sleep(POLL_INTERVAL_SECONDS)
        os.close(master_fd)
        raise OSError("Screen setup process could not be reaped")
    return pid, master_fd


def _read_available(master_fd: int, remaining_bytes: int) -> bytes:
    if remaining_bytes <= 0:
        return b""
    try:
        readable, _, _ = select.select([master_fd], [], [], POLL_INTERVAL_SECONDS)
    except (OSError, ValueError):
        return b""
    if not readable:
        return b""
    try:
        return os.read(master_fd, min(4096, remaining_bytes))
    except (BlockingIOError, OSError):
        return b""


def _send_boot(master_fd: int) -> bool:
    pending = memoryview(b"boot\r")
    while pending:
        try:
            written = os.write(master_fd, pending)
        except (BlockingIOError, OSError):
            return False
        if written <= 0:
            return False
        pending = pending[written:]
    return True


def _send_boot_if_not_cancelled(master_fd: int) -> bool:
    blocked_signals = {signal.SIGTERM, signal.SIGINT}
    if requested_signal is not None:
        return False
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
    try:
        if requested_signal is not None or signal.sigpending() & blocked_signals:
            return False
        return _send_boot(master_fd)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def drive_console(
    home_path: Path,
    result_path: Path,
    *,
    timeout_seconds: int,
    handoff_timeout_seconds: int,
    max_output_bytes: int,
    screen_program_path: Path,
) -> tuple[dict[str, Any], int]:
    if sys.platform != "linux":
        raise ValueError("the Cuttlefish console probe requires a Linux host")
    home = _private_directory(home_path, "Cuttlefish HOME")
    result = _private_result_path(result_path)
    if (
        type(timeout_seconds) is not int
        or not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS
    ):
        raise ValueError("console timeout is outside the supported range")
    if (
        type(handoff_timeout_seconds) is not int
        or not 1 <= handoff_timeout_seconds <= timeout_seconds
    ):
        raise ValueError("kernel-handoff timeout is outside the supported range")
    if (
        type(max_output_bytes) is not int
        or not 1 <= max_output_bytes <= MAX_OUTPUT_BYTES
    ):
        raise ValueError("console output limit is outside the supported range")
    screen_program = screen_program_path.resolve(strict=True)
    metadata = screen_program.stat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(screen_program, os.X_OK):
        raise ValueError("Screen executable must be a regular executable file")

    result_document: dict[str, Any] = {
        "schemaVersion": 2,
        "consoleEndpointFound": False,
        "screenStarted": False,
        "uBootBannerObserved": False,
        "promptObserved": False,
        "bootCommandSent": False,
        "kernelHandoffObserved": False,
        "outputBytesObserved": 0,
        "outputLimitBytes": max_output_bytes,
        "outputTruncated": False,
        "timedOut": False,
        "handoffTimedOut": False,
        "screenExitCode": None,
        "signal": None,
        "cleanupComplete": True,
        "cleanupFailure": None,
        "cleanupErrorNumber": None,
    }
    child_pid: int | None = None
    master_fd: int | None = None
    status = 1
    output = bytearray()
    handoff_output_offset: int | None = None
    deadline = time.monotonic() + timeout_seconds

    try:
        endpoint: Path | None = None
        while time.monotonic() < deadline and requested_signal is None:
            endpoint = _console_endpoint(home)
            if endpoint is not None:
                break
            time.sleep(POLL_INTERVAL_SECONDS)
        if requested_signal is not None:
            result_document["signal"] = requested_signal
            status = 128 + requested_signal
        elif endpoint is None:
            result_document["timedOut"] = True
        else:
            result_document["consoleEndpointFound"] = True
            child_pid, master_fd = _start_screen(screen_program, endpoint, home)
            result_document["screenStarted"] = True
            handoff_deadline: float | None = None
            while time.monotonic() < deadline:
                if requested_signal is not None:
                    result_document["signal"] = requested_signal
                    status = 128 + requested_signal
                    break

                remaining = max_output_bytes - len(output)
                chunk = _read_available(master_fd, remaining)
                if chunk:
                    output.extend(chunk)
                    result_document["outputBytesObserved"] = len(output)
                    decoded = _strip_ansi_escape_sequences(bytes(output)).decode(
                        "utf-8",
                        errors="replace",
                    )
                    normalized = decoded.replace("\r\n", "\n").replace("\r", "\n")
                    if U_BOOT_BANNER.search(normalized):
                        result_document["uBootBannerObserved"] = True
                    if not result_document["bootCommandSent"] and UBOOT_PROMPT.search(
                        normalized
                    ):
                        result_document["promptObserved"] = True
                        if requested_signal is not None:
                            result_document["signal"] = requested_signal
                            status = 128 + requested_signal
                            break
                        if not _send_boot_if_not_cancelled(master_fd):
                            break
                        result_document["bootCommandSent"] = True
                        handoff_output_offset = len(output)
                        handoff_deadline = min(
                            deadline,
                            time.monotonic() + handoff_timeout_seconds,
                        )
                    handoff_output = (
                        bytes(output[handoff_output_offset:])
                        if handoff_output_offset is not None
                        else b""
                    )
                    handoff_text = _strip_ansi_escape_sequences(handoff_output).decode(
                        "utf-8",
                        errors="replace",
                    )
                    handoff_text = handoff_text.replace("\r\n", "\n").replace(
                        "\r",
                        "\n",
                    )
                    if result_document["bootCommandSent"] and KERNEL_HANDOFF.search(
                        handoff_text
                    ):
                        result_document["kernelHandoffObserved"] = True
                        status = 0
                        break
                elif len(output) >= max_output_bytes:
                    result_document["outputTruncated"] = True
                    break

                child_exited, child_exit = _try_observe_child_exit(child_pid)
                if child_exited:
                    result_document["screenExitCode"] = child_exit
                    break

                if (
                    result_document["bootCommandSent"]
                    and handoff_deadline is not None
                    and time.monotonic() >= handoff_deadline
                ):
                    result_document["handoffTimedOut"] = True
                    break

            if (
                time.monotonic() >= deadline
                and not result_document["kernelHandoffObserved"]
            ):
                result_document["timedOut"] = True
            if len(output) >= max_output_bytes:
                result_document["outputTruncated"] = True
            if requested_signal is not None:
                result_document["signal"] = requested_signal
                status = 128 + requested_signal
    except (OSError, ValueError) as error:
        detail = (
            error.strerror or type(error).__name__
            if isinstance(error, OSError) and error.filename is not None
            else str(error)
        )
        print(f"drive_cuttlefish_console: {detail}", file=sys.stderr)
        status = 1
    finally:
        if child_pid is not None and master_fd is not None:
            (
                exit_code,
                cleanup_complete,
                cleanup_failure,
                cleanup_error_number,
            ) = _stop_screen(
                child_pid,
                master_fd,
            )
            result_document["screenExitCode"] = exit_code
            result_document["cleanupComplete"] = cleanup_complete
            result_document["cleanupFailure"] = cleanup_failure
            result_document["cleanupErrorNumber"] = cleanup_error_number
        if master_fd is not None:
            try:
                os.close(master_fd)
            except OSError:
                result_document["cleanupComplete"] = False
        if requested_signal is not None:
            result_document["signal"] = requested_signal
            status = 128 + requested_signal
        if not result_document["cleanupComplete"]:
            status = 1
        result_document["exitCode"] = status
        try:
            _write_result(result, result_document)
        except (OSError, ValueError):
            result_document["cleanupComplete"] = False
            status = 1

    return result_document, status


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument(
        "--handoff-timeout-seconds",
        type=int,
        default=DEFAULT_HANDOFF_TIMEOUT_SECONDS,
    )
    parser.add_argument("--max-output-bytes", type=int, default=MAX_OUTPUT_BYTES)
    parser.add_argument("--screen-program", type=Path)
    return parser.parse_args()


def main() -> int:
    global requested_signal
    requested_signal = None
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
    arguments = _parse_arguments()
    screen_program = arguments.screen_program
    if screen_program is None:
        found = shutil.which("screen")
        if found is None:
            print(
                "drive_cuttlefish_console: Screen executable is unavailable",
                file=sys.stderr,
            )
            return 1
        screen_program = Path(found)
    try:
        _, status = drive_console(
            arguments.home,
            arguments.result,
            timeout_seconds=arguments.timeout_seconds,
            handoff_timeout_seconds=arguments.handoff_timeout_seconds,
            max_output_bytes=arguments.max_output_bytes,
            screen_program_path=screen_program,
        )
        return status
    except (OSError, ValueError) as error:
        print(f"drive_cuttlefish_console: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
