#!/usr/bin/env python3
"""Validate isolated Cuttlefish GPU and console comparisons and record provenance."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fnmatch
import hashlib
import json
import os
import platform
import re
import secrets
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections.abc import Callable
from pathlib import Path
from typing import Any

BASELINE_RELATIVE = Path(
    "Images/reference/16373615/incomplete/default-20261001T120904-49816"
)
BASELINE_COMMIT = "64da28a551b0b33e258c8f37057b9a8a6d90846d"
MANIFEST_RELATIVE = Path("Images/manifests/16373615/android-image.json")
EXPERIMENT_RELATIVE = Path("Experiments/cuttlefish-boot-diagnosis")
TOOL_PATHS = (
    Path("Images/tools/reference/capture.sh"),
    Path("Images/tools/reference/capture_cvd_start.py"),
    Path("Images/tools/reference/compare_boot.py"),
    Path("Images/tools/reference/normalize.yaml"),
    Path("Images/tools/reference/guest-capture.txt"),
    MANIFEST_RELATIVE,
)
EXPERIMENT_TOOL_NAMES = (
    "capture-gpu-none.sh",
    "capture-lifecycle.sh",
    "capture_bounded.py",
    "capture_processes.py",
    "experiment_support.py",
    "run_capture.py",
    "summarize_logcat.py",
)
SYSTEMD_EXECUTABLE_PATHS = (
    Path("/usr/lib/systemd/systemd"),
    Path("/lib/systemd/systemd"),
)
HOST_FACT_FIELDS = (
    "hostKind",
    "os",
    "kernel",
    "architecture",
    "cpuCount",
    "nestedVirtualization",
)
VCS_PATTERN = re.compile(r"\bVCS:\s*([0-9a-f]{40})\b", re.IGNORECASE)
VERSION_PATTERN = re.compile(
    r"\bversion:\s*([0-9][0-9A-Za-z._-]*)\s*\|\s*VCS:\s*([0-9a-f]{40})\b",
    re.IGNORECASE,
)
LINUX_SUN_PATH_CAPACITY = 108
GPU_MODE_SLUGS = {
    "none": "none",
    "guest_swiftshader": "guest-swiftshader",
}
GPU_MODE_PATH_PATTERN = "none|guest-swiftshader"
CONSOLE_MODE_SLUGS = {
    True: "on",
    False: "off",
}
CONSOLE_MODE_PATH_PATTERN = "on|off"
MAX_PUBLICATION_EXPERIMENT_BYTES = 1_048_576


def _encoded_unix_socket_path_bytes(path: str | os.PathLike[str]) -> int:
    encoded_path = os.fsencode(path)
    if b"\0" in encoded_path:
        raise ValueError("Unix socket path contains a NUL byte")
    return len(encoded_path) + 1


def audit_unix_socket_paths(roots: list[Path]) -> dict[str, int | bool]:
    if not roots:
        raise ValueError("at least one Cuttlefish runtime path is required")
    socket_count = 0
    maximum_path_bytes = 0
    maximum_sun_path_bytes = 0
    canonical_roots: list[Path] = []
    canonical_root_stats: dict[Path, os.stat_result] = {}
    for requested_root in roots:
        if not requested_root.is_absolute() or requested_root.is_symlink():
            raise ValueError("Cuttlefish socket audit root is unsafe")
        try:
            root = requested_root.resolve(strict=True)
            root_stat = os.stat(root, follow_symlinks=False)
        except OSError as error:
            raise ValueError("Cuttlefish socket audit root is unavailable") from error
        if (
            not stat.S_ISDIR(root_stat.st_mode)
            or not root.is_dir()
            or root != requested_root
        ):
            raise ValueError("Cuttlefish socket audit root is not physically canonical")
        if root not in canonical_root_stats:
            canonical_roots.append(root)
            canonical_root_stats[root] = root_stat

    seen_socket_paths: set[bytes] = set()

    def record_socket_path(path: str | os.PathLike[str]) -> None:
        nonlocal socket_count, maximum_path_bytes, maximum_sun_path_bytes
        encoded_path = os.fsencode(path)
        if encoded_path in seen_socket_paths:
            return
        sun_path_bytes = _encoded_unix_socket_path_bytes(path)
        if sun_path_bytes > LINUX_SUN_PATH_CAPACITY:
            raise ValueError(
                "a Cuttlefish Unix socket path exceeds Linux sun_path "
                f"capacity ({sun_path_bytes} bytes including the "
                f"terminating NUL; limit {LINUX_SUN_PATH_CAPACITY})"
            )
        seen_socket_paths.add(encoded_path)
        socket_count += 1
        maximum_path_bytes = max(maximum_path_bytes, sun_path_bytes - 1)
        maximum_sun_path_bytes = max(maximum_sun_path_bytes, sun_path_bytes)

    def verify_skipped_symlink(
        entry_name: str,
        directory_descriptor: int,
        entry_stat: os.stat_result,
        initial_target_text: str,
        initial_target_stat: os.stat_result | None,
    ) -> None:
        def stat_symlink_target() -> os.stat_result | None:
            try:
                return os.stat(
                    entry_name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=True,
                )
            except FileNotFoundError:
                return None
            except OSError as error:
                raise ValueError(
                    "could not recheck a Cuttlefish symlink target"
                ) from error

        def target_matches(
            expected_stat: os.stat_result | None,
            observed_stat: os.stat_result | None,
        ) -> bool:
            if expected_stat is None:
                return observed_stat is None
            return (
                observed_stat is not None
                and _same_inode(expected_stat, observed_stat)
                and stat.S_IFMT(expected_stat.st_mode)
                == stat.S_IFMT(observed_stat.st_mode)
            )

        def verify_link_identity() -> None:
            try:
                link_stat = os.stat(
                    entry_name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                link_text = os.readlink(
                    entry_name,
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise ValueError("could not recheck a Cuttlefish symlink") from error
            if (
                not stat.S_ISLNK(link_stat.st_mode)
                or not _same_inode(entry_stat, link_stat)
                or link_text != initial_target_text
            ):
                raise ValueError("a Cuttlefish symlink changed during audit")

        verify_link_identity()
        current_target_stat = stat_symlink_target()
        if not target_matches(initial_target_stat, current_target_stat):
            raise ValueError("a Cuttlefish symlink target changed during audit")
        verify_link_identity()
        final_target_stat = stat_symlink_target()
        if not target_matches(current_target_stat, final_target_stat):
            raise ValueError("a Cuttlefish symlink target changed during final audit")

    def resolve_socket_target(
        entry_name: str,
        entry_path: Path,
        directory_descriptor: int,
        target_stat: os.stat_result,
        current_root: Path,
        current_root_descriptor: int,
    ) -> Path:
        try:
            target_text = os.readlink(
                entry_name,
                dir_fd=directory_descriptor,
            )
        except OSError as error:
            raise ValueError(
                "could not read a Cuttlefish socket symlink target"
            ) from error
        if os.path.isabs(target_text):
            target_path = Path(os.path.normpath(target_text))
        else:
            target_path = Path(
                os.path.normpath(os.path.join(entry_path.parent, target_text))
            )

        candidates: list[tuple[Path, Path]] = []
        for audit_root in canonical_roots:
            try:
                relative_target = target_path.relative_to(audit_root)
            except ValueError:
                continue
            if relative_target.parts:
                candidates.append((audit_root, relative_target))
        if not candidates:
            raise ValueError("a Cuttlefish socket symlink escapes its audit roots")
        target_root, relative_target = max(
            candidates,
            key=lambda candidate: len(candidate[0].parts),
        )
        if target_root == current_root:
            target_root_descriptor = os.dup(current_root_descriptor)
        else:
            try:
                target_root_descriptor = _open_directory_chain(target_root)
            except (OSError, ValueError) as error:
                raise ValueError(
                    "a Cuttlefish socket symlink target root changed during audit"
                ) from error
        try:
            target_root_stat = os.fstat(target_root_descriptor)
            if not _same_inode(
                canonical_root_stats[target_root],
                target_root_stat,
            ):
                raise ValueError(
                    "a Cuttlefish socket symlink target root changed during audit"
                )

            relative_parent = Path(*relative_target.parts[:-1])
            try:
                if relative_parent.parts:
                    target_parent_descriptor = _open_relative_directory(
                        target_root_descriptor,
                        relative_parent,
                    )
                else:
                    target_parent_descriptor = os.dup(target_root_descriptor)
            except (OSError, ValueError) as error:
                raise ValueError(
                    "a Cuttlefish socket symlink has unsafe target components"
                ) from error
            try:
                target_parent_stat = os.fstat(target_parent_descriptor)
                target_name = relative_target.parts[-1]
                try:
                    target_entry_stat = os.stat(
                        target_name,
                        dir_fd=target_parent_descriptor,
                        follow_symlinks=False,
                    )
                    current_link_stat = os.stat(
                        entry_name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise ValueError(
                        "could not verify a Cuttlefish socket symlink"
                    ) from error
                if (
                    not stat.S_ISSOCK(target_entry_stat.st_mode)
                    or not _same_inode(target_stat, target_entry_stat)
                    or not stat.S_ISLNK(current_link_stat.st_mode)
                ):
                    raise ValueError("a Cuttlefish socket symlink changed during audit")

            finally:
                os.close(target_parent_descriptor)

            try:
                verified_root_descriptor = _open_directory_chain(target_root)
            except (OSError, ValueError) as error:
                raise ValueError(
                    "a Cuttlefish socket symlink target root changed during audit"
                ) from error
            try:
                if not _same_inode(
                    target_root_stat,
                    os.fstat(verified_root_descriptor),
                ):
                    raise ValueError(
                        "a Cuttlefish socket symlink target root changed during audit"
                    )
                try:
                    if relative_parent.parts:
                        verified_parent_descriptor = _open_relative_directory(
                            verified_root_descriptor,
                            relative_parent,
                        )
                    else:
                        verified_parent_descriptor = os.dup(verified_root_descriptor)
                except (OSError, ValueError) as error:
                    raise ValueError(
                        "a Cuttlefish socket symlink target directory changed "
                        "during audit"
                    ) from error
                try:
                    verified_parent_stat = os.fstat(verified_parent_descriptor)
                    verified_target_stat = os.stat(
                        target_name,
                        dir_fd=verified_parent_descriptor,
                        follow_symlinks=False,
                    )
                    verified_link_stat = os.stat(
                        entry_name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                    verified_link_text = os.readlink(
                        entry_name,
                        dir_fd=directory_descriptor,
                    )
                    if (
                        not _same_inode(target_parent_stat, verified_parent_stat)
                        or not stat.S_ISSOCK(verified_target_stat.st_mode)
                        or not _same_inode(target_entry_stat, verified_target_stat)
                        or not _same_inode(current_link_stat, verified_link_stat)
                        or verified_link_text != target_text
                    ):
                        raise ValueError(
                            "a Cuttlefish socket symlink changed during audit"
                        )
                except OSError as error:
                    raise ValueError(
                        "could not recheck a Cuttlefish socket symlink"
                    ) from error
                finally:
                    os.close(verified_parent_descriptor)
            finally:
                os.close(verified_root_descriptor)
        finally:
            os.close(target_root_descriptor)
        return target_path

    for root in canonical_roots:
        try:
            root_descriptor = _open_directory_chain(root)
        except (OSError, ValueError) as error:
            raise ValueError(
                "could not open a Cuttlefish socket audit root safely"
            ) from error
        try:
            root_stat = os.fstat(root_descriptor)
            if not _same_inode(canonical_root_stats[root], root_stat):
                raise ValueError("a Cuttlefish socket audit root changed during audit")
            pending: list[tuple[Path, os.stat_result]] = [
                (Path(), root_stat),
            ]
            while pending:
                relative_directory, expected_directory_stat = pending.pop()
                try:
                    if relative_directory.parts:
                        directory_descriptor = _open_relative_directory(
                            root_descriptor,
                            relative_directory,
                        )
                    else:
                        directory_descriptor = os.dup(root_descriptor)
                except (OSError, ValueError) as error:
                    raise ValueError(
                        "a Cuttlefish runtime directory changed during audit"
                    ) from error
                try:
                    directory_stat = os.fstat(directory_descriptor)
                    if not stat.S_ISDIR(directory_stat.st_mode) or not _same_inode(
                        expected_directory_stat,
                        directory_stat,
                    ):
                        raise ValueError(
                            "a Cuttlefish runtime directory changed during audit"
                        )
                    directory_path = root / relative_directory
                    try:
                        with os.scandir(directory_descriptor) as entries:
                            entry_names = [entry.name for entry in entries]
                    except OSError as error:
                        raise ValueError(
                            "could not inspect Cuttlefish runtime sockets"
                        ) from error
                    for entry_name in entry_names:
                        entry_path = directory_path / entry_name
                        try:
                            entry_stat = os.stat(
                                entry_name,
                                dir_fd=directory_descriptor,
                                follow_symlinks=False,
                            )
                        except OSError as error:
                            raise ValueError(
                                "could not inspect Cuttlefish runtime sockets"
                            ) from error
                        if stat.S_ISLNK(entry_stat.st_mode):
                            try:
                                initial_target_text = os.readlink(
                                    entry_name,
                                    dir_fd=directory_descriptor,
                                )
                            except OSError as error:
                                raise ValueError(
                                    "could not read a Cuttlefish symlink target"
                                ) from error
                            try:
                                target_stat = os.stat(
                                    entry_name,
                                    dir_fd=directory_descriptor,
                                    follow_symlinks=True,
                                )
                            except FileNotFoundError:
                                verify_skipped_symlink(
                                    entry_name,
                                    directory_descriptor,
                                    entry_stat,
                                    initial_target_text,
                                    None,
                                )
                                continue
                            except OSError as error:
                                raise ValueError(
                                    "could not inspect Cuttlefish socket symlink "
                                    "targets"
                                ) from error
                            if stat.S_ISDIR(target_stat.st_mode):
                                raise ValueError(
                                    "a directory symlink was found beneath a "
                                    "Cuttlefish socket audit root"
                                )
                            if stat.S_ISSOCK(target_stat.st_mode):
                                target_path = resolve_socket_target(
                                    entry_name,
                                    entry_path,
                                    directory_descriptor,
                                    target_stat,
                                    root,
                                    root_descriptor,
                                )
                                current_link_stat = os.stat(
                                    entry_name,
                                    dir_fd=directory_descriptor,
                                    follow_symlinks=False,
                                )
                                if not stat.S_ISLNK(
                                    current_link_stat.st_mode
                                ) or not _same_inode(
                                    entry_stat,
                                    current_link_stat,
                                ):
                                    raise ValueError(
                                        "a Cuttlefish socket symlink changed "
                                        "during audit"
                                    )
                                record_socket_path(entry_path)
                                record_socket_path(target_path)
                            else:
                                verify_skipped_symlink(
                                    entry_name,
                                    directory_descriptor,
                                    entry_stat,
                                    initial_target_text,
                                    target_stat,
                                )
                            continue
                        if stat.S_ISDIR(entry_stat.st_mode):
                            try:
                                child_descriptor = _open_child_directory(
                                    directory_descriptor,
                                    entry_name,
                                )
                            except (OSError, ValueError) as error:
                                raise ValueError(
                                    "a Cuttlefish runtime directory changed "
                                    "during audit"
                                ) from error
                            try:
                                child_stat = os.fstat(child_descriptor)
                                current_child_stat = os.stat(
                                    entry_name,
                                    dir_fd=directory_descriptor,
                                    follow_symlinks=False,
                                )
                                if (
                                    not stat.S_ISDIR(child_stat.st_mode)
                                    or not _same_inode(entry_stat, child_stat)
                                    or not _same_inode(child_stat, current_child_stat)
                                ):
                                    raise ValueError(
                                        "a Cuttlefish runtime directory changed "
                                        "during audit"
                                    )
                                pending.append(
                                    (
                                        relative_directory / entry_name,
                                        child_stat,
                                    )
                                )
                            except OSError as error:
                                raise ValueError(
                                    "could not inspect Cuttlefish runtime sockets"
                                ) from error
                            finally:
                                os.close(child_descriptor)
                            continue
                        if stat.S_ISSOCK(entry_stat.st_mode):
                            try:
                                current_socket_stat = os.stat(
                                    entry_name,
                                    dir_fd=directory_descriptor,
                                    follow_symlinks=False,
                                )
                            except OSError as error:
                                raise ValueError(
                                    "could not recheck a Cuttlefish socket entry"
                                ) from error
                            if not stat.S_ISSOCK(
                                current_socket_stat.st_mode
                            ) or not _same_inode(entry_stat, current_socket_stat):
                                raise ValueError(
                                    "a Cuttlefish socket entry changed during audit"
                                )
                            record_socket_path(entry_path)

                    try:
                        if relative_directory.parts:
                            verified_directory = _open_relative_directory(
                                root_descriptor,
                                relative_directory,
                            )
                        else:
                            verified_directory = os.dup(root_descriptor)
                    except (OSError, ValueError) as error:
                        raise ValueError(
                            "a Cuttlefish runtime directory changed during audit"
                        ) from error
                    try:
                        verified_directory_stat = os.fstat(verified_directory)
                        if not _same_inode(directory_stat, verified_directory_stat):
                            raise ValueError(
                                "a Cuttlefish runtime directory changed during audit"
                            )
                    finally:
                        os.close(verified_directory)
                finally:
                    os.close(directory_descriptor)

            try:
                verified_root = _open_directory_chain(root)
            except (OSError, ValueError) as error:
                raise ValueError(
                    "a Cuttlefish socket audit root changed during audit"
                ) from error
            try:
                if not _same_inode(root_stat, os.fstat(verified_root)):
                    raise ValueError(
                        "a Cuttlefish socket audit root changed during audit"
                    )
            finally:
                os.close(verified_root)
        finally:
            os.close(root_descriptor)
    return {
        "capacityBytes": LINUX_SUN_PATH_CAPACITY,
        "terminatingNulBytes": 1,
        "socketCount": socket_count,
        "maxEncodedPathBytes": maximum_path_bytes,
        "maxSunPathBytesIncludingNul": maximum_sun_path_bytes,
    }


def _process_state_and_start_time(
    process_directory: Path,
) -> tuple[str, str, int] | None:
    try:
        contents = (process_directory / "stat").read_text(encoding="ascii")
    except FileNotFoundError as error:
        try:
            process_directory.stat()
        except FileNotFoundError:
            return None
        except OSError as verification_error:
            raise ValueError("could not verify a Cuttlefish process identity") from (
                verification_error
            )
        raise ValueError("could not verify a Cuttlefish process identity") from error
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("could not verify a Cuttlefish process identity") from error
    closing_parenthesis = contents.rfind(")")
    if closing_parenthesis < 0:
        raise ValueError("could not verify a Cuttlefish process identity")
    process_id = contents[:closing_parenthesis].split(maxsplit=1)[0]
    fields = contents[closing_parenthesis + 1 :].split()
    if (
        process_id != process_directory.name
        or len(fields) <= 19
        or not fields[1].isdigit()
        or not fields[19].isdigit()
    ):
        raise ValueError("could not verify a Cuttlefish process identity")
    return fields[0], fields[19], int(fields[1])


def _process_start_time(process_directory: Path) -> str:
    process_state = _process_state_and_start_time(process_directory)
    if process_state is None:
        raise ValueError("could not verify a Cuttlefish process identity")
    return process_state[1]


def _process_pidfd_has_exited(process_pidfd: int) -> bool:
    poller = select.poll()
    poller.register(
        process_pidfd,
        select.POLLIN | select.POLLHUP | select.POLLERR,
    )
    return bool(poller.poll(0))


def _process_root_uses_pidfds(process_root: Path) -> bool:
    return sys.platform == "linux" and process_root.resolve(strict=True) == Path(
        "/proc"
    ).resolve(strict=True)


def _process_is_gone_or_changed(
    process_directory: Path,
    expected_start_time: str | None,
    process_pidfd: int | None = None,
) -> bool:
    process_state = _process_state_and_start_time(process_directory)
    if process_state is None:
        if process_pidfd is None or _process_pidfd_has_exited(process_pidfd):
            return True
        raise ValueError("could not inspect a live Cuttlefish process through /proc")
    if process_pidfd is not None and _process_pidfd_has_exited(process_pidfd):
        if process_state[0] in {"Z", "X"}:
            return True
        raise ValueError("Cuttlefish PID was reused during audit")
    if process_state[0] in {"Z", "X"}:
        return True
    if expected_start_time is not None and process_state[1] != expected_start_time:
        raise ValueError("Cuttlefish process identity changed during audit")
    return False


def _open_process_pidfd_by_identity(
    process_id: int,
    expected_start_time: str,
) -> tuple[int, Callable[[int, int], None]]:
    if sys.platform != "linux":
        raise OSError(errno.ENOTSUP, "process identity signals require Linux pidfds")
    if process_id <= 0 or re.fullmatch(r"[0-9]+", expected_start_time) is None:
        raise ValueError("process identity is invalid")
    pidfd_open = getattr(os, "pidfd_open", None)
    pidfd_send_signal = getattr(signal, "pidfd_send_signal", None)
    if pidfd_open is None or pidfd_send_signal is None:
        raise OSError(errno.ENOTSUP, "Linux pidfd signaling is unavailable")

    process_descriptor = pidfd_open(process_id, 0)
    try:
        observed_start_time = _process_start_time(Path("/proc") / str(process_id))
        if observed_start_time != expected_start_time:
            raise ValueError(
                "process identity changed; refusing to signal the reused PID"
            )
    except BaseException:
        os.close(process_descriptor)
        raise
    return process_descriptor, pidfd_send_signal


def _write_pidfd_broker_record(
    path: Path,
    process_id: int,
    expected_start_time: str,
) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".pidfd-broker-",
        dir=path.parent,
    )
    try:
        try:
            os.fchmod(descriptor, 0o600)
            content = f"{process_id} {expected_start_time}\n".encode("ascii")
            offset = 0
            while offset < len(content):
                written = os.write(descriptor, content[offset:])
                if written <= 0:
                    raise OSError(errno.EIO, "could not write pidfd broker record")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.link(temporary_name, path, follow_symlinks=False)
    finally:
        os.unlink(temporary_name)


def run_process_signal_broker(
    process_id: int,
    expected_start_time: str,
    ready_path: Path,
    exited_path: Path,
    stopped_path: Path,
) -> None:
    process_descriptor, pidfd_send_signal = _open_process_pidfd_by_identity(
        process_id,
        expected_start_time,
    )
    try:
        _write_pidfd_broker_record(ready_path, process_id, expected_start_time)
        control_descriptor = sys.stdin.fileno()
        poller = select.poll()
        poller.register(
            process_descriptor, select.POLLIN | select.POLLHUP | select.POLLERR
        )
        poller.register(
            control_descriptor,
            select.POLLIN | select.POLLHUP | select.POLLERR,
        )
        pending = bytearray()
        process_events = select.POLLIN | select.POLLHUP | select.POLLERR
        while True:
            events = poller.poll()
            if any(
                descriptor == process_descriptor and event & process_events
                for descriptor, event in events
            ):
                _write_pidfd_broker_record(
                    exited_path,
                    process_id,
                    expected_start_time,
                )
                return
            for descriptor, event in events:
                if descriptor != control_descriptor:
                    continue
                if not event & (select.POLLIN | select.POLLHUP | select.POLLERR):
                    continue
                chunk = os.read(control_descriptor, 4096)
                if not chunk:
                    if pending:
                        raise ValueError("pidfd broker received an incomplete request")
                    poller.unregister(control_descriptor)
                    try:
                        pidfd_send_signal(process_descriptor, signal.SIGTERM)
                    except ProcessLookupError:
                        _write_pidfd_broker_record(
                            exited_path,
                            process_id,
                            expected_start_time,
                        )
                        return
                    term_deadline = time.monotonic() + 5
                    while time.monotonic() < term_deadline:
                        remaining_ms = max(
                            1,
                            int((term_deadline - time.monotonic()) * 1000),
                        )
                        if any(
                            descriptor == process_descriptor and event & process_events
                            for descriptor, event in poller.poll(remaining_ms)
                        ):
                            _write_pidfd_broker_record(
                                exited_path,
                                process_id,
                                expected_start_time,
                            )
                            return
                    try:
                        pidfd_send_signal(process_descriptor, signal.SIGKILL)
                    except ProcessLookupError:
                        _write_pidfd_broker_record(
                            exited_path,
                            process_id,
                            expected_start_time,
                        )
                        return
                    continue
                pending.extend(chunk)
                while b"\n" in pending:
                    raw_request, _, remaining = pending.partition(b"\n")
                    pending = bytearray(remaining)
                    request = raw_request.decode("ascii").strip()
                    if request == "QUIT":
                        return
                    signal_number = {
                        "TERM": signal.SIGTERM,
                        "INT": signal.SIGINT,
                        "HUP": signal.SIGHUP,
                        "CONT": signal.SIGCONT,
                        "KILL": signal.SIGKILL,
                    }.get(request)
                    if signal_number is None:
                        raise ValueError(
                            "pidfd broker received an invalid signal request"
                        )
                    try:
                        pidfd_send_signal(process_descriptor, signal_number)
                    except ProcessLookupError:
                        _write_pidfd_broker_record(
                            exited_path,
                            process_id,
                            expected_start_time,
                        )
                        return
    finally:
        try:
            _write_pidfd_broker_record(stopped_path, process_id, expected_start_time)
        except OSError:
            pass
        os.close(process_descriptor)


def _process_ancestor_start_times(
    process_root: Path,
    *,
    use_pidfds: bool = False,
) -> dict[int, str | None]:
    current_pid = os.getpid()
    ancestors: dict[int, str | None] = {current_pid: None}
    process_pidfds: dict[int, int] = {}
    pidfd_open = getattr(os, "pidfd_open", None)
    if use_pidfds and pidfd_open is None:
        raise ValueError("Linux pidfds are required to verify process ancestry")
    process_id = current_pid
    child_process_id: int | None = None
    child_start_time: str | None = None
    parent_ids: dict[int, int] = {}
    try:
        for _ in range(1024):
            process_directory = process_root / str(process_id)
            process_pidfd: int | None = None
            if use_pidfds:
                try:
                    process_pidfd = pidfd_open(process_id, 0)
                except ProcessLookupError as error:
                    raise ValueError(
                        "Linux process ancestry changed while being pinned"
                    ) from error
                except OSError as error:
                    raise ValueError("could not pin Linux process ancestry") from error
                process_pidfds[process_id] = process_pidfd
            process_state = _process_state_and_start_time(process_directory)
            if process_state is None:
                if process_id == current_pid and not use_pidfds:
                    return ancestors
                raise ValueError("could not verify Linux process ancestry")
            if process_state[0] in {"Z", "X"} or (
                process_pidfd is not None and _process_pidfd_has_exited(process_pidfd)
            ):
                raise ValueError("Linux process ancestry changed while being pinned")
            if child_process_id is not None:
                child_directory = process_root / str(child_process_id)
                child_state = _process_state_and_start_time(child_directory)
                child_pidfd = process_pidfds.get(child_process_id)
                if (
                    child_state is None
                    or child_state[0] in {"Z", "X"}
                    or child_state[1] != child_start_time
                    or child_state[2] != process_id
                    or (
                        child_pidfd is not None
                        and _process_pidfd_has_exited(child_pidfd)
                    )
                ):
                    raise ValueError(
                        "Linux process ancestry links changed during audit"
                    )
            ancestors[process_id] = process_state[1]
            parent_pid = process_state[2]
            if parent_pid <= 0 or parent_pid == process_id or parent_pid in ancestors:
                break
            parent_ids[process_id] = parent_pid
            child_process_id = process_id
            child_start_time = process_state[1]
            process_id = parent_pid
        else:
            raise ValueError("Linux process ancestry exceeds the safety limit")
        for ancestor_id, expected_start_time in ancestors.items():
            if expected_start_time is None:
                continue
            ancestor_state = _process_state_and_start_time(
                process_root / str(ancestor_id)
            )
            if (
                ancestor_state is None
                or ancestor_state[0] in {"Z", "X"}
                or ancestor_state[1] != expected_start_time
                or (
                    ancestor_id in parent_ids
                    and ancestor_state[2] != parent_ids[ancestor_id]
                )
            ):
                raise ValueError("Linux process ancestry changed during audit")
            ancestor_pidfd = process_pidfds.get(ancestor_id)
            if ancestor_pidfd is not None and _process_pidfd_has_exited(ancestor_pidfd):
                raise ValueError("Linux process ancestry changed during audit")
        return ancestors
    finally:
        for process_pidfd in process_pidfds.values():
            os.close(process_pidfd)


def _process_uid(process_directory: Path) -> int:
    try:
        status_text = (process_directory / "status").read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("could not verify a Cuttlefish process owner") from error
    for line in status_text.splitlines():
        if line.startswith("Uid:"):
            fields = line.split()
            if len(fields) >= 2 and fields[1].isdigit():
                return int(fields[1])
    raise ValueError("could not verify a Cuttlefish process owner")


def _host_package_process_names(host_dir: Path) -> set[str]:
    binary_directory = host_dir / "bin"
    try:
        entries = list(os.scandir(binary_directory))
    except OSError as error:
        raise ValueError("could not inventory the Cuttlefish host package") from error
    names: set[str] = set()
    for entry in entries:
        try:
            if entry.is_file(follow_symlinks=True):
                names.add(entry.name[:15])
        except OSError as error:
            raise ValueError(
                "could not inventory the Cuttlefish host package"
            ) from error
    if not names:
        raise ValueError("Cuttlefish host package contains no candidate processes")
    return names


def _process_environment(
    process_directory: Path,
) -> dict[bytes, bytes]:
    try:
        raw_environment = (process_directory / "environ").read_bytes()
    except FileNotFoundError:
        raise
    except PermissionError:
        raise
    except OSError as error:
        raise ValueError("could not verify a Cuttlefish process environment") from error
    environment: dict[bytes, bytes] = {}
    for entry in raw_environment.split(b"\0"):
        key, separator, value = entry.partition(b"=")
        if separator:
            environment[key] = value
    return environment


def _is_trusted_systemd_executable(executable: str) -> bool:
    executable_path = Path(executable.removesuffix(" (deleted)"))
    for candidate in SYSTEMD_EXECUTABLE_PATHS:
        try:
            candidate_resolved = candidate.resolve(strict=True)
            candidate_status = candidate_resolved.stat()
            if (
                stat.S_ISREG(candidate_status.st_mode)
                and candidate_status.st_uid == 0
                and not candidate_status.st_mode & 0o022
                and _has_trusted_system_directory_chain(candidate_resolved.parent)
                and _same_file_identity(executable_path, candidate_resolved)
            ):
                return True
        except OSError:
            continue
    return False


def _has_trusted_system_directory_chain(directory: Path) -> bool:
    current = directory
    while True:
        try:
            directory_status = current.stat()
        except OSError:
            return False
        if (
            not stat.S_ISDIR(directory_status.st_mode)
            or directory_status.st_uid != 0
            or directory_status.st_mode & 0o022
        ):
            return False
        parent = current.parent
        if parent == current:
            return True
        current = parent


def _same_file_identity(first: Path, second: Path) -> bool:
    try:
        first_status = first.stat()
        second_status = second.stat()
    except OSError:
        return False
    return (
        stat.S_ISREG(first_status.st_mode)
        and first_status.st_dev == second_status.st_dev
        and first_status.st_ino == second_status.st_ino
    )


def _is_systemd_session_pam(process_directory: Path, owner: int) -> bool:
    try:
        cgroup = (process_directory / "cgroup").read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("could not verify a protected process cgroup") from error
    expected = f"0::/user.slice/user-{owner}.slice/user@{owner}.service/init.scope"
    if cgroup != expected:
        return False
    try:
        command_line = (process_directory / "cmdline").read_bytes()
    except OSError as error:
        raise ValueError("could not verify the protected systemd process") from error
    arguments = [argument for argument in command_line.split(b"\0") if argument]
    if not arguments or arguments[0] != b"(sd-pam)":
        return False

    try:
        try:
            process_executable = os.readlink(process_directory / "exe")
        except PermissionError:
            process_executable = None
        stat_record = (process_directory / "stat").read_bytes()
        closing_parenthesis = stat_record.rfind(b")")
        if closing_parenthesis < 0:
            return False
        fields = stat_record[closing_parenthesis + 1 :].split()
        parent_pid = int(fields[1])
        parent_directory = process_directory.parent / str(parent_pid)
        parent_comm = (parent_directory / "comm").read_text(encoding="utf-8").strip()
        parent_cgroup = (
            (parent_directory / "cgroup").read_text(encoding="ascii").strip()
        )
        parent_arguments = [
            argument
            for argument in (parent_directory / "cmdline").read_bytes().split(b"\0")
            if argument
        ]
        parent_executable = os.readlink(parent_directory / "exe")
    except (IndexError, OSError, UnicodeDecodeError, ValueError) as error:
        raise ValueError(
            "could not verify the protected systemd session parent"
        ) from error

    if process_executable is not None and not _is_trusted_systemd_executable(
        process_executable
    ):
        return False
    expected_manager_arguments = (
        b"/usr/lib/systemd/systemd",
        b"/lib/systemd/systemd",
    )
    return not (
        parent_pid <= 0
        or parent_pid == os.getpid()
        or _process_uid(parent_directory) != owner
        or parent_comm != "systemd"
        or parent_cgroup != expected
        or len(parent_arguments) < 2
        or parent_arguments[0] not in expected_manager_arguments
        or parent_arguments[1] != b"--user"
        or not _is_trusted_systemd_executable(parent_executable)
    )


def _path_is_within_environment_root(value: bytes | None, root: Path) -> bool:
    if value is None:
        return False
    root_bytes = os.fsencode(root)
    return value == root_bytes or value.startswith(root_bytes + os.fsencode(os.sep))


def _process_references_path(
    process_directory: Path,
    root: Path,
    start_time: str,
    process_pidfd: int | None = None,
    *,
    allow_unreadable_cwd_or_descriptors: bool = False,
) -> bool:
    root_bytes = os.fsencode(root)
    references_path = False
    try:
        references_path = root_bytes in (process_directory / "cmdline").read_bytes()
    except PermissionError as error:
        raise ValueError(
            "could not verify a Cuttlefish process reference before HOME cleanup"
        ) from error
    try:
        current_directory = os.readlink(process_directory / "cwd").removesuffix(
            " (deleted)"
        )
        references_path = references_path or _path_is_within_environment_root(
            os.fsencode(current_directory),
            root,
        )
    except PermissionError as error:
        if not allow_unreadable_cwd_or_descriptors:
            raise ValueError(
                "could not verify a Cuttlefish process reference before HOME cleanup"
            ) from error
    try:
        descriptors = list((process_directory / "fd").iterdir())
    except FileNotFoundError as error:
        if _process_is_gone_or_changed(
            process_directory,
            start_time,
            process_pidfd,
        ):
            return references_path
        raise ValueError(
            "could not inspect descriptors of a live Cuttlefish process"
        ) from error
    except PermissionError as error:
        if not allow_unreadable_cwd_or_descriptors:
            raise ValueError(
                "could not verify a Cuttlefish process reference before HOME cleanup"
            ) from error
        descriptors = []
    except OSError as error:
        raise ValueError(
            "could not inspect Linux Cuttlefish process references"
        ) from error
    for descriptor in descriptors:
        try:
            target = os.readlink(descriptor).removesuffix(" (deleted)")
        except FileNotFoundError:
            if _process_is_gone_or_changed(
                process_directory,
                start_time,
                process_pidfd,
            ):
                continue
            # A live process can close an individual descriptor while /proc is
            # being scanned. Rechecking its identity makes that race safe.
            continue
        except PermissionError as error:
            if allow_unreadable_cwd_or_descriptors:
                continue
            raise ValueError(
                "could not verify a Cuttlefish process reference before HOME cleanup"
            ) from error
        references_path = references_path or _path_is_within_environment_root(
            os.fsencode(target),
            root,
        )
    return references_path


def _private_cvd_processes(
    host_dir: Path,
    home_root: Path,
    tmpdir_root: Path,
    process_root: Path,
) -> list[dict[str, Any]]:
    if not process_root.is_dir():
        raise ValueError("Linux process information is unavailable")
    for label, path in (("Cuttlefish host", host_dir), ("private HOME", home_root)):
        if not path.is_absolute() or path.is_symlink():
            raise ValueError(f"{label} path is unsafe")
    if not tmpdir_root.is_absolute() or tmpdir_root.is_symlink():
        raise ValueError("private TMPDIR path is unsafe")
    try:
        resolved_host_dir = host_dir.resolve(strict=True)
        resolved_home_root = home_root.resolve(strict=True)
        resolved_tmpdir_root = tmpdir_root.resolve(strict=True)
    except OSError as error:
        raise ValueError("Cuttlefish process-audit paths are unavailable") from error
    if (
        not resolved_host_dir.is_dir()
        or resolved_host_dir != host_dir
        or not resolved_home_root.is_dir()
        or resolved_home_root != home_root
        or not resolved_tmpdir_root.is_dir()
        or resolved_tmpdir_root != tmpdir_root
    ):
        raise ValueError("Cuttlefish process-audit paths are not canonical directories")

    processes: list[dict[str, Any]] = []
    current_pid = os.getpid()
    try:
        use_pidfds = _process_root_uses_pidfds(process_root)
    except OSError as error:
        raise ValueError("could not resolve Linux process information") from error
    pidfd_open = getattr(os, "pidfd_open", None)
    if use_pidfds and pidfd_open is None:
        raise ValueError("Linux pidfds are required for Cuttlefish process cleanup")
    try:
        ancestor_start_times = _process_ancestor_start_times(
            process_root,
            use_pidfds=use_pidfds,
        )
        host_process_names = _host_package_process_names(resolved_host_dir)
        process_entries = list(process_root.iterdir())
    except OSError as error:
        raise ValueError("could not inspect Linux Cuttlefish processes") from error
    for process_directory in process_entries:
        if not process_directory.name.isdigit():
            continue
        process_id = int(process_directory.name)
        process_pidfd: int | None = None
        start_time: str | None = None
        try:
            if process_id == current_pid:
                continue
            if use_pidfds:
                try:
                    process_pidfd = pidfd_open(process_id, 0)
                except ProcessLookupError:
                    if _process_is_gone_or_changed(
                        process_directory,
                        None,
                    ):
                        continue
                    raise ValueError("could not pin a Cuttlefish process identity")
            initial_process_state = _process_state_and_start_time(process_directory)
            if initial_process_state is None or initial_process_state[0] in {"Z", "X"}:
                if _process_is_gone_or_changed(
                    process_directory,
                    None,
                    process_pidfd,
                ):
                    continue
                raise ValueError("could not classify a pinned Cuttlefish process")
            start_time = initial_process_state[1]
            if _process_is_gone_or_changed(
                process_directory,
                start_time,
                process_pidfd,
            ):
                continue
            owner = _process_uid(process_directory)
            if owner != os.getuid():
                if _process_is_gone_or_changed(
                    process_directory,
                    start_time,
                    process_pidfd,
                ):
                    continue
                continue
            if ancestor_start_times.get(process_id) == start_time:
                current_ancestor_start_times = _process_ancestor_start_times(
                    process_root,
                    use_pidfds=use_pidfds,
                )
                if current_ancestor_start_times.get(process_id) == start_time:
                    if _process_is_gone_or_changed(
                        process_directory,
                        start_time,
                        process_pidfd,
                    ):
                        continue
                    continue
            comm = (process_directory / "comm").read_text(encoding="utf-8").strip()
            is_host_process = comm in host_process_names
            if _process_is_gone_or_changed(
                process_directory,
                start_time,
                process_pidfd,
            ):
                continue
            try:
                environment = _process_environment(process_directory)
            except PermissionError as error:
                if comm not in {"sd-pam", "(sd-pam)"} or not _is_systemd_session_pam(
                    process_directory,
                    owner,
                ):
                    raise ValueError(
                        "could not verify a Cuttlefish process environment for "
                        f"pid {process_id} ({comm})"
                    ) from error
                references_private_paths = _process_references_path(
                    process_directory,
                    resolved_home_root,
                    start_time,
                    process_pidfd,
                    allow_unreadable_cwd_or_descriptors=True,
                ) or _process_references_path(
                    process_directory,
                    resolved_tmpdir_root,
                    start_time,
                    process_pidfd,
                    allow_unreadable_cwd_or_descriptors=True,
                )
                if _process_is_gone_or_changed(
                    process_directory,
                    start_time,
                    process_pidfd,
                ):
                    continue
                if references_private_paths:
                    processes.append(
                        {
                            "pid": process_id,
                            "startTime": start_time,
                            "comm": comm,
                            "isCuttlefishHostBinary": is_host_process,
                        }
                    )
                continue
            matches_home = _path_is_within_environment_root(
                environment.get(b"HOME"),
                resolved_home_root,
            )
            matches_tmpdir = _path_is_within_environment_root(
                environment.get(b"TMPDIR"),
                resolved_tmpdir_root,
            )
            references_private_paths = _process_references_path(
                process_directory,
                resolved_home_root,
                start_time,
                process_pidfd,
            ) or _process_references_path(
                process_directory,
                resolved_tmpdir_root,
                start_time,
                process_pidfd,
            )
            if _process_is_gone_or_changed(
                process_directory,
                start_time,
                process_pidfd,
            ):
                continue
            if not (matches_home or matches_tmpdir or references_private_paths):
                continue
            processes.append(
                {
                    "pid": process_id,
                    "startTime": start_time,
                    "comm": comm,
                    "isCuttlefishHostBinary": is_host_process,
                }
            )
        except FileNotFoundError as error:
            if _process_is_gone_or_changed(
                process_directory,
                start_time,
                process_pidfd,
            ):
                continue
            raise ValueError(
                "a live Cuttlefish process has an unreadable entry during "
                "HOME verification"
            ) from error
        except PermissionError as error:
            raise ValueError(
                "could not verify a Cuttlefish process before HOME cleanup"
            ) from error
        except (OSError, UnicodeDecodeError) as error:
            raise ValueError("could not inspect Linux Cuttlefish processes") from error
        finally:
            if process_pidfd is not None:
                os.close(process_pidfd)
    try:
        final_ancestor_start_times = _process_ancestor_start_times(
            process_root,
            use_pidfds=use_pidfds,
        )
    except OSError as error:
        raise ValueError(
            "could not recheck Linux Cuttlefish process ancestry"
        ) from error
    if final_ancestor_start_times != ancestor_start_times:
        raise ValueError("Linux process ancestry changed during Cuttlefish audit")
    return processes


def require_no_private_cvd_processes(
    host_dir: Path,
    home_root: Path,
    tmpdir_root: Path,
    process_root: Path = Path("/proc"),
) -> int:
    processes = _private_cvd_processes(
        host_dir,
        home_root,
        tmpdir_root,
        process_root,
    )
    if processes:
        raise ValueError(
            "a Cuttlefish host process still references the private HOME or TMPDIR"
        )
    return 0


def _validated_unix_socket_metrics(path: Path) -> dict[str, int | bool]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Cuttlefish Unix socket audit record is unavailable")
    metrics = _read_json(path)
    capacity = metrics.get("capacityBytes")
    nul_bytes = metrics.get("terminatingNulBytes")
    socket_count = metrics.get("socketCount")
    path_bytes = metrics.get("maxEncodedPathBytes")
    sun_path_bytes = metrics.get("maxSunPathBytesIncludingNul")
    if (
        type(capacity) is not int
        or capacity != LINUX_SUN_PATH_CAPACITY
        or type(nul_bytes) is not int
        or nul_bytes != 1
        or type(socket_count) is not int
        or socket_count < 0
        or type(path_bytes) is not int
        or path_bytes < 0
        or type(sun_path_bytes) is not int
        or not 0 <= sun_path_bytes <= capacity
        or (socket_count == 0 and (path_bytes != 0 or sun_path_bytes != 0))
        or (
            socket_count > 0
            and (path_bytes + nul_bytes != sun_path_bytes or path_bytes == 0)
        )
    ):
        raise ValueError("Cuttlefish Unix socket audit record is invalid")
    return {
        "capacityBytes": capacity,
        "terminatingNulBytes": nul_bytes,
        "socketCount": socket_count,
        "maxEncodedPathBytes": path_bytes,
        "maxSunPathBytesIncludingNul": sun_path_bytes,
    }


def _read_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON file {path.name}") from error
    if not isinstance(document, dict):
        raise TypeError(f"JSON file {path.name} must contain an object")
    return document


def _read_bounded_json_at(directory_descriptor: int, name: str) -> dict[str, Any]:
    if name in {"", ".", ".."} or "/" in name:
        raise ValueError("JSON filename is unsafe")
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=directory_descriptor,
    )
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
            or before.st_size > MAX_PUBLICATION_EXPERIMENT_BYTES
        ):
            raise ValueError(f"JSON file {name} is not a bounded regular file")
        content = bytearray()
        while len(content) <= MAX_PUBLICATION_EXPERIMENT_BYTES:
            chunk = os.read(
                descriptor,
                min(
                    65_536,
                    MAX_PUBLICATION_EXPERIMENT_BYTES + 1 - len(content),
                ),
            )
            if not chunk:
                break
            content.extend(chunk)
        after = os.fstat(descriptor)
        if (
            len(content) > MAX_PUBLICATION_EXPERIMENT_BYTES
            or not _same_inode(before, after)
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or len(content) != after.st_size
        ):
            raise ValueError(f"JSON file {name} changed during bounded read")
    finally:
        os.close(descriptor)
    try:
        document = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON file {name}") from error
    if not isinstance(document, dict):
        raise TypeError(f"JSON file {name} must contain an object")
    return document


def _baseline_host_fingerprint(host: dict[str, Any]) -> dict[str, Any]:
    fingerprint = {field: host.get(field) for field in HOST_FACT_FIELDS}
    if (
        not all(
            isinstance(fingerprint[field], str)
            for field in HOST_FACT_FIELDS
            if field != "cpuCount"
        )
        or type(fingerprint["cpuCount"]) is not int
        or fingerprint["cpuCount"] < 1
    ):
        raise ValueError("committed baseline is missing valid reference-host details")
    if type(host.get("cvdInstanceNumber")) is not int:
        raise ValueError("committed baseline is missing its Cuttlefish instance number")
    fingerprint["cvdInstanceNumber"] = host["cvdInstanceNumber"]
    if fingerprint["cvdInstanceNumber"] != 1:
        raise ValueError("the pinned baseline must use Cuttlefish instance 1")
    return fingerprint


def _current_host_fingerprint() -> dict[str, Any]:
    try:
        kernel_result = subprocess.run(
            ["uname", "-srmo"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        cpu_count = os.sysconf("SC_NPROCESSORS_ONLN")
        os_name = platform.freedesktop_os_release().get("PRETTY_NAME", "Linux")
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise ValueError(
            "could not identify the current Cuttlefish reference host"
        ) from error
    if kernel_result.returncode != 0 or not kernel_result.stdout.strip():
        raise ValueError("could not identify the current Linux kernel")
    try:
        virtualization_result = subprocess.run(
            ["systemd-detect-virt", "--vm"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        virtualization = (
            virtualization_result.stdout.strip()
            if virtualization_result.returncode == 0
            else ""
        )
    except (OSError, subprocess.TimeoutExpired):
        virtualization = ""
    if virtualization in {"", "none"}:
        host_kind = "linux"
        nested_virtualization = "off"
    else:
        host_kind = f"linux-{virtualization}"
        kvm_device = Path("/dev/kvm")
        nested_virtualization = (
            "on"
            if kvm_device.is_char_device() and os.access(kvm_device, os.R_OK | os.W_OK)
            else "off"
        )
    if type(cpu_count) is not int or cpu_count < 1:
        raise ValueError("current reference-host CPU count is invalid")
    return {
        "hostKind": host_kind,
        "os": os_name,
        "kernel": kernel_result.stdout.strip(),
        "architecture": platform.machine(),
        "cpuCount": cpu_count,
        "nestedVirtualization": nested_virtualization,
    }


def _git(repo_root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(
            f"git {arguments[0]} failed while verifying capture provenance"
        )
    return result.stdout.strip()


def _git_blob_text(repo_root: Path, revision: str) -> str:
    result = subprocess.run(
        ["git", "show", revision],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError("git show failed while verifying the committed baseline")
    return result.stdout


def _git_blob_bytes(repo_root: Path, revision: str) -> bytes:
    result = subprocess.run(
        ["git", "show", revision],
        cwd=repo_root,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ValueError("git show failed while verifying committed tool bytes")
    return result.stdout


def _baseline_commit(repo_root: Path, baseline_record: Path) -> str:
    repo_root = repo_root.resolve()
    baseline_record = baseline_record.resolve()
    try:
        relative = baseline_record.relative_to(repo_root)
    except ValueError as error:
        raise ValueError("baseline record must be inside the repository") from error
    if relative != BASELINE_RELATIVE:
        raise ValueError("diagnosis must use the pinned canonical baseline record")
    if not re.fullmatch(r"[0-9a-f]{40}", BASELINE_COMMIT):
        raise ValueError("pinned baseline commit has an invalid format")
    commit = _git(
        repo_root,
        "rev-parse",
        "--verify",
        f"{BASELINE_COMMIT}^{{commit}}",
    )
    if commit != BASELINE_COMMIT:
        raise ValueError("pinned baseline commit is unavailable")
    return commit


def _verify_tool_revisions(
    repo_root: Path,
    baseline_record: Path,
) -> tuple[str, dict[str, str], str, dict[str, str]]:
    baseline_commit = _baseline_commit(repo_root, baseline_record)
    observed_commit = _git(repo_root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", observed_commit):
        raise ValueError("could not identify the committed capture tool revision")
    baseline_blobs: dict[str, str] = {}
    observed_blobs: dict[str, str] = {}
    for path in TOOL_PATHS:
        baseline_blob = _git(
            repo_root,
            "rev-parse",
            f"{baseline_commit}:{path.as_posix()}",
        )
        observed_blob = _git(
            repo_root,
            "rev-parse",
            f"{observed_commit}:{path.as_posix()}",
        )
        working_blob = _git(repo_root, "hash-object", "--", path.as_posix())
        if not re.fullmatch(r"[0-9a-f]{40}", baseline_blob):
            raise ValueError(f"baseline is missing tracked tool {path.as_posix()}")
        if not re.fullmatch(r"[0-9a-f]{40}", observed_blob):
            raise ValueError(
                f"current revision is missing tracked tool {path.as_posix()}"
            )
        if _git(repo_root, "status", "--porcelain", "--", path.as_posix()):
            raise ValueError(f"capture tool has uncommitted changes: {path.as_posix()}")
        if working_blob != observed_blob:
            raise ValueError(
                f"capture tool differs from committed HEAD: {path.as_posix()}"
            )
        baseline_blobs[path.as_posix()] = baseline_blob
        observed_blobs[path.as_posix()] = observed_blob
    return baseline_commit, baseline_blobs, observed_commit, observed_blobs


def verify_tool_copy(
    repo_root: Path,
    baseline_record: Path,
    host_identity: dict[str, Any],
    tool_copy_root: Path,
    canonical_capture_copy: Path,
    manifest_copy_root: Path,
    experiment_root: Path,
    patched_capture: Path,
) -> None:
    repo_root = repo_root.resolve()
    baseline_record = baseline_record.resolve()
    if baseline_record != repo_root / BASELINE_RELATIVE:
        raise ValueError("tool provenance must use the pinned canonical baseline")
    if host_identity.get("baselineRecord") != BASELINE_RELATIVE.as_posix():
        raise ValueError("tool provenance names an unexpected baseline record")

    baseline_commit = host_identity.get("baselineToolCommit")
    observed_commit = host_identity.get("observedToolCommit")
    if not isinstance(baseline_commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}", baseline_commit
    ):
        raise ValueError("baseline tool commit has an invalid format")
    if not isinstance(observed_commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}", observed_commit
    ):
        raise ValueError("observed tool commit has an invalid format")

    expected_paths = {path.as_posix() for path in TOOL_PATHS}
    provenance_maps: dict[str, dict[str, str]] = {}
    for field in ("baselineToolBlobs", "observedToolBlobs"):
        blob_map = host_identity.get(field)
        if not isinstance(blob_map, dict) or set(blob_map) != expected_paths:
            raise ValueError(
                f"{field} must contain exactly the canonical capture tool paths"
            )
        if not all(
            isinstance(blob, str) and re.fullmatch(r"[0-9a-f]{40}", blob)
            for blob in blob_map.values()
        ):
            raise ValueError(f"{field} contains an invalid Git blob ID")
        provenance_maps[field] = blob_map

    if baseline_commit != _baseline_commit(repo_root, baseline_record):
        raise ValueError("baseline tool commit differs from the pinned baseline")
    if observed_commit != _git(repo_root, "rev-parse", "HEAD"):
        raise ValueError(
            "observed tool commit differs from the current repository HEAD"
        )
    if tool_copy_root.is_symlink() or not tool_copy_root.is_dir():
        raise ValueError("private canonical tool copy must be a real directory")
    if canonical_capture_copy.is_symlink() or not canonical_capture_copy.is_file():
        raise ValueError("private unpatched capture script copy is missing or unsafe")
    if manifest_copy_root.is_symlink() or not manifest_copy_root.is_dir():
        raise ValueError("private manifest copy must be a real directory")

    for path in TOOL_PATHS:
        relative_path = path.as_posix()
        baseline_blob = _git(
            repo_root,
            "rev-parse",
            f"{baseline_commit}:{relative_path}",
        )
        observed_blob = _git(
            repo_root,
            "rev-parse",
            f"{observed_commit}:{relative_path}",
        )
        if provenance_maps["baselineToolBlobs"][relative_path] != baseline_blob:
            raise ValueError(
                f"baseline tool blob differs from committed provenance: {relative_path}"
            )
        if provenance_maps["observedToolBlobs"][relative_path] != observed_blob:
            raise ValueError(
                f"observed tool blob differs from committed provenance: {relative_path}"
            )

        if path == MANIFEST_RELATIVE:
            copied_path = manifest_copy_root / path.name
        elif path == TOOL_PATHS[0]:
            copied_path = canonical_capture_copy
        else:
            copied_path = tool_copy_root / path.name
        if copied_path.is_symlink() or not copied_path.is_file():
            raise ValueError(f"private canonical tool copy is missing: {path.name}")
        contents = copied_path.read_bytes()
        copied_blob = hashlib.sha1(
            f"blob {len(contents)}\0".encode("ascii") + contents
        ).hexdigest()
        if copied_blob != observed_blob:
            raise ValueError(
                f"private canonical tool copy differs from observed revision: "
                f"{path.name}"
            )

    experiment_sources = host_identity.get("experimentSources")
    expected_experiment_sources = {*EXPERIMENT_TOOL_NAMES, "patched-capture.sh"}
    if (
        not isinstance(experiment_sources, dict)
        or set(experiment_sources) != expected_experiment_sources
    ):
        raise ValueError(
            "experimentSources must contain exactly the copied experiment tools"
        )
    if not all(
        isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
        for digest in experiment_sources.values()
    ):
        raise ValueError("experimentSources contains an invalid SHA-256 digest")
    if experiment_root.is_symlink() or not experiment_root.is_dir():
        raise ValueError("private experiment tool copy must be a real directory")
    if patched_capture.is_symlink() or not patched_capture.is_file():
        raise ValueError("private patched capture copy is missing or unsafe")
    if patched_capture.resolve() != (tool_copy_root / TOOL_PATHS[0].name).resolve():
        raise ValueError("patched capture verification must target the runnable copy")

    for name in EXPERIMENT_TOOL_NAMES:
        copied_path = experiment_root / name
        if copied_path.is_symlink() or not copied_path.is_file():
            raise ValueError(f"private experiment tool copy is missing: {name}")
        relative_path = (EXPERIMENT_RELATIVE / name).as_posix()
        committed_blob = _git(
            repo_root,
            "rev-parse",
            f"{observed_commit}:{relative_path}",
        )
        if _git(repo_root, "status", "--porcelain", "--", relative_path):
            raise ValueError(f"experiment source has uncommitted changes: {name}")
        if _git(repo_root, "hash-object", "--", relative_path) != committed_blob:
            raise ValueError(f"experiment source differs from committed HEAD: {name}")
        committed_source = _git_blob_bytes(
            repo_root,
            f"{observed_commit}:{relative_path}",
        )
        committed_digest = hashlib.sha256(committed_source).hexdigest()
        if experiment_sources[name] != committed_digest:
            raise ValueError(
                f"experiment source digest differs from committed HEAD: {name}"
            )
        if copied_path.read_bytes() != committed_source:
            raise ValueError(
                f"private experiment tool copy differs from committed HEAD: {name}"
            )
    for name in ("capture_bounded.py", "capture_processes.py"):
        runtime_copy = tool_copy_root / name
        if runtime_copy.is_symlink() or not runtime_copy.is_file():
            raise ValueError(f"private runtime experiment tool copy is missing: {name}")
        runtime_digest = hashlib.sha256(runtime_copy.read_bytes()).hexdigest()
        if runtime_digest != experiment_sources[name]:
            raise ValueError(
                f"private runtime experiment tool copy differs from committed "
                f"source: {name}"
            )
    patched_digest = hashlib.sha256(patched_capture.read_bytes()).hexdigest()
    if patched_digest != experiment_sources["patched-capture.sh"]:
        raise ValueError("private patched capture copy differs from recorded source")


def _experiment_source_hashes(
    repo_root: Path,
    observed_commit: str,
    experiment_root: Path,
    patched_capture: Path,
) -> dict[str, str]:
    sources: dict[str, str] = {}
    for name in EXPERIMENT_TOOL_NAMES:
        copied_path = experiment_root / name
        if copied_path.is_symlink() or not copied_path.is_file():
            raise ValueError(f"experiment source is missing or unsafe: {name}")
        relative_path = (EXPERIMENT_RELATIVE / name).as_posix()
        committed_blob = _git(
            repo_root,
            "rev-parse",
            f"{observed_commit}:{relative_path}",
        )
        working_blob = _git(repo_root, "hash-object", "--", relative_path)
        if _git(repo_root, "status", "--porcelain", "--", relative_path):
            raise ValueError(f"experiment source has uncommitted changes: {name}")
        if working_blob != committed_blob:
            raise ValueError(f"experiment source differs from committed HEAD: {name}")
        committed_source = _git_blob_bytes(
            repo_root,
            f"{observed_commit}:{relative_path}",
        )
        if copied_path.read_bytes() != committed_source:
            raise ValueError(
                f"private experiment source differs from committed HEAD: {name}"
            )
        sources[name] = hashlib.sha256(committed_source).hexdigest()
    if patched_capture.is_symlink() or not patched_capture.is_file():
        raise ValueError("patched capture script is missing or unsafe")
    sources["patched-capture.sh"] = hashlib.sha256(
        patched_capture.read_bytes()
    ).hexdigest()
    return sources


def _capture_statuses(status_root: Path) -> dict[str, Any]:
    if status_root.is_symlink() or not status_root.is_dir():
        raise ValueError("capture status directory must be a real directory")
    status_files = sorted(status_root.glob("*.json"))
    if len(status_files) > 100:
        raise ValueError("too many bounded capture status records")
    files: dict[str, dict[str, int | bool | None]] = {}
    for path in status_files:
        if path.is_symlink() or not re.fullmatch(r"[A-Za-z0-9_.-]+", path.stem):
            raise ValueError("capture status file has an unsafe name")
        status = _read_json(path)
        bytes_written = status.get("bytesWritten")
        truncated = status.get("truncated")
        timed_out = status.get("timedOut")
        child_exit = status.get("childExitCode")
        signal_number = status.get("signal")
        cleanup_complete = status.get("cleanupComplete")
        if (
            type(bytes_written) is not int
            or bytes_written < 0
            or not isinstance(truncated, bool)
            or not isinstance(timed_out, bool)
            or (child_exit is not None and type(child_exit) is not int)
            or (signal_number is not None and type(signal_number) is not int)
            or not isinstance(cleanup_complete, bool)
        ):
            raise ValueError(f"capture status has invalid fields: {path.name}")
        if not cleanup_complete:
            raise ValueError(
                f"capture process group cleanup is incomplete: {path.name}"
            )
        files[path.stem] = {
            "bytesWritten": bytes_written,
            "truncated": truncated,
            "timedOut": timed_out,
            "childExitCode": child_exit,
            "signal": signal_number,
            "cleanupComplete": cleanup_complete,
        }
    aggregate_bytes = sum(record["bytesWritten"] for record in files.values())
    if aggregate_bytes > 64 * 1024 * 1024:
        raise ValueError("aggregate bounded capture output exceeds 64 MiB")
    return {
        "aggregateBytes": aggregate_bytes,
        "files": files,
        "truncatedFiles": sorted(
            name for name, record in files.items() if record["truncated"]
        ),
        "timedOutFiles": sorted(
            name for name, record in files.items() if record["timedOut"]
        ),
    }


def _logcat_paths(work_root: Path, adb_log_root: Path) -> tuple[Path, Path]:
    if not work_root.is_absolute() or work_root.is_symlink() or not work_root.is_dir():
        raise ValueError("private work root must be an existing non-symlink directory")
    if adb_log_root != work_root / "adb-live":
        raise ValueError(
            "ADB log root must be the private work root's adb-live directory"
        )
    return work_root / "Images/reference/16373615", adb_log_root


_DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)


def _open_directory_chain(path: Path) -> int:
    if (
        not path.is_absolute()
        or any(component in {".", ".."} for component in path.parts[1:])
        or not hasattr(os, "O_NOFOLLOW")
        or not hasattr(os, "O_DIRECTORY")
    ):
        raise ValueError("directory path cannot be opened without following links")
    descriptor = os.open("/", _DIRECTORY_OPEN_FLAGS)
    try:
        for component in path.parts[1:]:
            next_descriptor = os.open(
                component,
                _DIRECTORY_OPEN_FLAGS,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _is_safe_writable_parent(directory_stat: os.stat_result) -> bool:
    mode = directory_stat.st_mode
    group_can_mutate = bool(mode & stat.S_IWGRP and mode & stat.S_IXGRP)
    other_can_mutate = bool(mode & stat.S_IWOTH and mode & stat.S_IXOTH)
    if not group_can_mutate and not other_can_mutate:
        return True
    return bool(mode & stat.S_ISVTX and directory_stat.st_uid in {0, os.getuid()})


def _validate_data_root_path(data_root: Path) -> None:
    if any(unicodedata.category(character) == "Cc" for character in str(data_root)):
        raise ValueError("diagnostic data root path contains control characters")
    if (
        not data_root.is_absolute()
        or len(data_root.parts) < 2
        or any(component in {"", ".", ".."} for component in data_root.parts[1:])
    ):
        raise ValueError("diagnostic data root path is unsafe")


def _open_private_data_root(data_root: Path) -> int:
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise ValueError("diagnostic data root path is unsafe")
    _validate_data_root_path(data_root)
    descriptor = os.open("/", _DIRECTORY_OPEN_FLAGS)
    components = data_root.parts[1:]
    try:
        for index, component in enumerate(components):
            next_descriptor = os.open(
                component,
                _DIRECTORY_OPEN_FLAGS,
                dir_fd=descriptor,
            )
            component_stat = os.fstat(next_descriptor)
            if index == len(components) - 1:
                if component_stat.st_uid != os.getuid() or component_stat.st_mode & (
                    stat.S_IWGRP | stat.S_IWOTH
                ):
                    os.close(next_descriptor)
                    raise ValueError(
                        "diagnostic data root must be current-user-owned and not "
                        "writable by other users"
                    )
            elif not _is_safe_writable_parent(component_stat):
                os.close(next_descriptor)
                raise ValueError(
                    "diagnostic data root has a writable parent without safe "
                    "sticky-directory ownership"
                )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def prepare_private_data_root(data_root: Path) -> None:
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise ValueError("diagnostic data root path is unsafe")
    _validate_data_root_path(data_root)
    descriptor = os.open("/", _DIRECTORY_OPEN_FLAGS)
    components = data_root.parts[1:]
    try:
        for index, component in enumerate(components):
            try:
                next_descriptor = os.open(
                    component,
                    _DIRECTORY_OPEN_FLAGS,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
                next_descriptor = os.open(
                    component,
                    _DIRECTORY_OPEN_FLAGS,
                    dir_fd=descriptor,
                )
            component_stat = os.fstat(next_descriptor)
            if index == len(components) - 1:
                if component_stat.st_uid != os.getuid():
                    os.close(next_descriptor)
                    raise ValueError(
                        "diagnostic data root must be owned by the current user"
                    )
                os.fchmod(next_descriptor, 0o700)
            elif not _is_safe_writable_parent(component_stat):
                os.close(next_descriptor)
                raise ValueError(
                    "diagnostic data root has a writable parent without safe "
                    "sticky-directory ownership"
                )
            os.close(descriptor)
            descriptor = next_descriptor
        root_stat = os.fstat(descriptor)
        if root_stat.st_uid != os.getuid() or root_stat.st_mode & (
            stat.S_IWGRP | stat.S_IWOTH
        ):
            raise ValueError("diagnostic data root is not private to the current user")
        for child_name in ("work", "results"):
            try:
                os.mkdir(child_name, mode=0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child_descriptor = _open_child_directory(descriptor, child_name)
            try:
                child_stat = os.fstat(child_descriptor)
                if child_stat.st_uid != os.getuid():
                    raise ValueError(
                        f"diagnostic {child_name} directory must be current-user-owned"
                    )
                os.fchmod(child_descriptor, 0o700)
            finally:
                os.close(child_descriptor)
    finally:
        os.close(descriptor)


def _open_child_directory(parent_descriptor: int, name: str) -> int:
    if name in {"", ".", ".."} or "/" in name:
        raise ValueError("directory component is unsafe")
    return os.open(name, _DIRECTORY_OPEN_FLAGS, dir_fd=parent_descriptor)


def _verify_private_child_directory(
    parent_descriptor: int,
    name: str,
) -> int:
    descriptor = _open_child_directory(parent_descriptor, name)
    child_stat = os.fstat(descriptor)
    if child_stat.st_uid != os.getuid() or child_stat.st_mode & 0o077:
        os.close(descriptor)
        raise ValueError(
            f"diagnostic {name} directory must be private to the current user"
        )
    return descriptor


def _open_relative_directory(parent_descriptor: int, path: Path) -> int:
    if path.is_absolute() or not path.parts:
        raise ValueError("relative directory path is unsafe")
    descriptor = os.dup(parent_descriptor)
    try:
        for component in path.parts:
            next_descriptor = _open_child_directory(descriptor, component)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _open_optional_relative_directory(
    parent_descriptor: int,
    path: Path,
) -> int | None:
    try:
        return _open_relative_directory(parent_descriptor, path)
    except FileNotFoundError:
        return None


def _stat_entry_at(parent_descriptor: int, name: str) -> os.stat_result:
    return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)


def _same_inode(first: os.stat_result, second: os.stat_result) -> bool:
    return first.st_dev == second.st_dev and first.st_ino == second.st_ino


def _renameat2_noreplace(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
) -> None:
    if sys.platform != "linux":
        raise OSError(errno.ENOTSUP, "atomic no-replace rename requires Linux")
    renameat2 = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if renameat2 is None:
        raise OSError(errno.ENOTSUP, "renameat2 is unavailable")
    renameat2.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameat2.restype = ctypes.c_int
    result = renameat2(
        source_parent_descriptor,
        os.fsencode(source_name),
        destination_parent_descriptor,
        os.fsencode(destination_name),
        1,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(
            error_number,
            os.strerror(error_number),
            destination_name,
        )


def _restore_quarantined_entry(
    parent_descriptor: int,
    quarantine_name: str,
    original_name: str,
) -> None:
    try:
        _renameat2_noreplace(
            parent_descriptor,
            quarantine_name,
            parent_descriptor,
            original_name,
        )
    except OSError as error:
        raise OSError(
            errno.EBUSY,
            f"entry could not be restored; preserved as {quarantine_name}",
            original_name,
        ) from error


def _quarantine_entry_at(
    parent_descriptor: int,
    name: str,
    expected_stat: os.stat_result,
    *,
    require_directory: bool = False,
) -> str:
    for _ in range(8):
        quarantine_name = f".apkrun-quarantine-{secrets.token_hex(16)}"
        try:
            _renameat2_noreplace(
                parent_descriptor,
                name,
                parent_descriptor,
                quarantine_name,
            )
        except OSError as error:
            if error.errno == errno.EEXIST:
                continue
            raise

        try:
            moved_stat = _stat_entry_at(parent_descriptor, quarantine_name)
        except OSError:
            _restore_quarantined_entry(
                parent_descriptor,
                quarantine_name,
                name,
            )
            raise
        if _same_inode(moved_stat, expected_stat) and (
            not require_directory or stat.S_ISDIR(moved_stat.st_mode)
        ):
            return quarantine_name

        _restore_quarantined_entry(parent_descriptor, quarantine_name, name)
        message = (
            "directory changed during safe removal"
            if require_directory
            else "entry changed during safe removal"
        )
        raise OSError(errno.EBUSY, message, name)

    raise OSError(errno.EEXIST, "could not reserve a private quarantine name", name)


def _unlink_entry_at(
    parent_descriptor: int,
    name: str,
    expected_stat: os.stat_result,
) -> None:
    quarantine_name = _quarantine_entry_at(
        parent_descriptor,
        name,
        expected_stat,
    )
    try:
        os.unlink(quarantine_name, dir_fd=parent_descriptor)
    except OSError:
        _restore_quarantined_entry(parent_descriptor, quarantine_name, name)
        raise


def _remove_directory_entry_at(
    parent_descriptor: int,
    name: str,
    expected_stat: os.stat_result,
) -> None:
    quarantine_name = _quarantine_entry_at(
        parent_descriptor,
        name,
        expected_stat,
        require_directory=True,
    )
    try:
        os.rmdir(quarantine_name, dir_fd=parent_descriptor)
    except OSError:
        _restore_quarantined_entry(parent_descriptor, quarantine_name, name)
        raise


def _remove_directory_contents(
    directory_descriptor: int,
    preserved_names: frozenset[str] = frozenset(),
) -> None:
    with os.scandir(directory_descriptor) as entries:
        names = sorted(entry.name for entry in entries)
    for name in names:
        if name in preserved_names:
            continue
        try:
            entry_stat = _stat_entry_at(directory_descriptor, name)
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(entry_stat.st_mode):
            child_descriptor = _open_child_directory(directory_descriptor, name)
            try:
                child_stat = os.fstat(child_descriptor)
                if not _same_inode(child_stat, entry_stat):
                    raise OSError(
                        errno.EBUSY,
                        "directory changed during safe removal",
                        name,
                    )
                _remove_directory_contents(child_descriptor)
                _remove_directory_entry_at(directory_descriptor, name, child_stat)
            finally:
                os.close(child_descriptor)
        else:
            _unlink_entry_at(directory_descriptor, name, entry_stat)


def _workspace_marker_content(work_root: Path, ownership_token: str) -> bytes:
    if re.fullmatch(r"[a-f0-9]{64}", ownership_token) is None:
        raise ValueError("workspace ownership token is invalid")
    return (
        f"APKRun Cuttlefish boot diagnosis v1\n{ownership_token}\n{work_root}\n"
    ).encode()


def _verify_workspace_marker(
    work_descriptor: int,
    work_root: Path,
    ownership_token: str,
) -> None:
    expected = _workspace_marker_content(work_root, ownership_token)
    marker_descriptor = os.open(
        ".apkrun-cuttlefish-workspace",
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
        dir_fd=work_descriptor,
    )
    try:
        if not stat.S_ISREG(os.fstat(marker_descriptor).st_mode):
            raise ValueError("generated workspace ownership marker is unsafe")
        marker_content = os.read(marker_descriptor, len(expected) + 1)
    finally:
        os.close(marker_descriptor)
    if marker_content != expected:
        raise ValueError("generated workspace ownership marker is invalid")


def _write_all(descriptor: int, content: bytes) -> None:
    remaining = memoryview(content)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError(errno.EIO, "short write while restoring workspace marker")
        remaining = remaining[written:]


def _restore_workspace_marker(
    work_descriptor: int,
    work_root: Path,
    ownership_token: str,
    mode: int,
) -> None:
    marker_descriptor = os.open(
        ".apkrun-cuttlefish-workspace",
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | os.O_NOFOLLOW,
        mode,
        dir_fd=work_descriptor,
    )
    try:
        _write_all(
            marker_descriptor,
            _workspace_marker_content(work_root, ownership_token),
        )
        os.fsync(marker_descriptor)
    except BaseException:
        try:
            os.unlink(".apkrun-cuttlefish-workspace", dir_fd=work_descriptor)
        except OSError:
            pass
        raise
    finally:
        os.close(marker_descriptor)


def _remove_private_path(work_descriptor: int, relative_path: Path) -> None:
    if relative_path.is_absolute() or not relative_path.parts:
        raise ValueError("private removal path is unsafe")
    parent_descriptor = os.dup(work_descriptor)
    try:
        for component in relative_path.parts[:-1]:
            try:
                component_stat = _stat_entry_at(parent_descriptor, component)
            except FileNotFoundError:
                return
            if stat.S_ISLNK(component_stat.st_mode):
                _unlink_entry_at(parent_descriptor, component, component_stat)
                return
            if not stat.S_ISDIR(component_stat.st_mode):
                return
            next_descriptor = _open_child_directory(parent_descriptor, component)
            if not _same_inode(os.fstat(next_descriptor), component_stat):
                os.close(next_descriptor)
                raise OSError(
                    errno.EBUSY,
                    "directory changed during safe removal",
                    component,
                )
            os.close(parent_descriptor)
            parent_descriptor = next_descriptor
        name = relative_path.parts[-1]
        try:
            target_stat = _stat_entry_at(parent_descriptor, name)
        except FileNotFoundError:
            return
        if stat.S_ISDIR(target_stat.st_mode):
            target_descriptor = _open_child_directory(parent_descriptor, name)
            try:
                opened_stat = os.fstat(target_descriptor)
                if not _same_inode(opened_stat, target_stat):
                    raise OSError(
                        errno.EBUSY,
                        "directory changed during safe removal",
                        name,
                    )
                _remove_directory_contents(target_descriptor)
                _remove_directory_entry_at(
                    parent_descriptor,
                    name,
                    opened_stat,
                )
            finally:
                os.close(target_descriptor)
        else:
            _unlink_entry_at(parent_descriptor, name, target_stat)
    finally:
        os.close(parent_descriptor)


def _is_capture_logcat(name: str) -> bool:
    return name in {"logcat.txt.gz", ".logcat.raw"}


def _is_live_logcat(name: str) -> bool:
    return fnmatch.fnmatchcase(name, "logcat-*.txt") or fnmatch.fnmatchcase(
        name,
        ".logcat-*.txt",
    )


def _raise_walk_error(error: OSError) -> None:
    raise error


def _scrub_capture_logcat(root_descriptor: int, remove: bool) -> None:
    for _, directories, filenames, directory_descriptor in os.fwalk(
        ".",
        follow_symlinks=False,
        onerror=_raise_walk_error,
        dir_fd=root_descriptor,
    ):
        for name in directories:
            entry_stat = _stat_entry_at(directory_descriptor, name)
            if stat.S_ISLNK(entry_stat.st_mode):
                raise ValueError("capture output contains a symlink directory")
            if _is_capture_logcat(name):
                raise ValueError(f"matching logcat entry is not a regular file: {name}")
        for name in filenames:
            if not _is_capture_logcat(name):
                continue
            entry_stat = _stat_entry_at(directory_descriptor, name)
            if not (
                stat.S_ISREG(entry_stat.st_mode) or stat.S_ISLNK(entry_stat.st_mode)
            ):
                raise ValueError(f"matching logcat entry is not a regular file: {name}")
            if remove:
                _unlink_entry_at(directory_descriptor, name, entry_stat)
            else:
                raise ValueError("raw logcat remains in capture output")


def _scrub_live_logcat(root_descriptor: int, remove: bool) -> None:
    with os.scandir(root_descriptor) as entries:
        names = [entry.name for entry in entries]
    for name in names:
        entry_stat = _stat_entry_at(root_descriptor, name)
        if stat.S_ISLNK(entry_stat.st_mode) or stat.S_ISDIR(entry_stat.st_mode):
            raise ValueError("live ADB log output contains a nested or symlink entry")
        if not _is_live_logcat(name):
            continue
        if not stat.S_ISREG(entry_stat.st_mode):
            raise ValueError(f"matching logcat entry is not a regular file: {name}")
        if remove:
            _unlink_entry_at(root_descriptor, name, entry_stat)
        else:
            raise ValueError("raw live ADB logcat remains")


def _verify_scrub_root_unchanged(
    work_descriptor: int,
    relative_path: Path,
    original_descriptor: int | None,
) -> None:
    current_descriptor = _open_optional_relative_directory(
        work_descriptor,
        relative_path,
    )
    if original_descriptor is None:
        if current_descriptor is not None:
            os.close(current_descriptor)
            raise ValueError("logcat directory appeared during cleanup")
        return
    if current_descriptor is None:
        raise ValueError("logcat directory changed during cleanup")
    try:
        if not _same_inode(
            os.fstat(current_descriptor),
            os.fstat(original_descriptor),
        ):
            raise ValueError("logcat directory changed during cleanup")
    finally:
        os.close(current_descriptor)


def scrub_raw_logcat(
    work_root: Path,
    adb_log_root: Path,
    data_root: Path,
    ownership_token: str,
) -> None:
    _validate_generated_work_root(work_root, data_root, ownership_token)
    capture_root, adb_log_root = _logcat_paths(work_root, adb_log_root)
    work_descriptor = _open_directory_chain(work_root)
    roots: list[tuple[Path, int | None, Callable[[int, bool], None]]] = []
    try:
        _verify_workspace_marker(work_descriptor, work_root, ownership_token)
        capture_relative = capture_root.relative_to(work_root)
        adb_relative = adb_log_root.relative_to(work_root)
        capture_descriptor = _open_optional_relative_directory(
            work_descriptor,
            capture_relative,
        )
        roots.append((capture_relative, capture_descriptor, _scrub_capture_logcat))
        adb_descriptor = _open_optional_relative_directory(
            work_descriptor,
            adb_relative,
        )
        roots.append((adb_relative, adb_descriptor, _scrub_live_logcat))
        for _, descriptor, scrubber in roots:
            if descriptor is not None:
                scrubber(descriptor, True)
        for _, descriptor, scrubber in roots:
            if descriptor is not None:
                scrubber(descriptor, False)
        for relative_path, descriptor, _ in roots:
            _verify_scrub_root_unchanged(
                work_descriptor,
                relative_path,
                descriptor,
            )
    finally:
        for _, descriptor, _ in roots:
            if descriptor is not None:
                os.close(descriptor)
        os.close(work_descriptor)


def _validate_generated_work_root(
    work_root: Path,
    data_root: Path,
    ownership_token: str,
) -> None:
    if not data_root.is_absolute() or data_root.is_symlink() or not data_root.is_dir():
        raise ValueError(
            "diagnostic data root must be an existing non-symlink directory"
        )
    work_parent = data_root / "work"
    if (
        not work_root.is_absolute()
        or work_root.parent != work_parent
        or re.fullmatch(
            rf"gpu-(?:{GPU_MODE_PATH_PATTERN})"
            rf"(?:-console-(?:{CONSOLE_MODE_PATH_PATTERN}))?\.[A-Za-z0-9]+",
            work_root.name,
        )
        is None
    ):
        raise ValueError(
            "workspace is outside the generated Cuttlefish diagnostic work area"
        )
    if work_root.is_symlink() or (work_root.exists() and not work_root.is_dir()):
        raise ValueError("private work root must be a non-symlink directory")
    data_descriptor = _open_private_data_root(data_root)
    try:
        work_parent_descriptor = _verify_private_child_directory(
            data_descriptor,
            "work",
        )
        try:
            results_descriptor = _verify_private_child_directory(
                data_descriptor,
                "results",
            )
            os.close(results_descriptor)
            if not work_root.exists():
                _workspace_marker_content(work_root, ownership_token)
                return
            try:
                work_descriptor = _verify_private_child_directory(
                    work_parent_descriptor,
                    work_root.name,
                )
            except FileNotFoundError:
                return
            try:
                _verify_workspace_marker(
                    work_descriptor,
                    work_root,
                    ownership_token,
                )
            finally:
                os.close(work_descriptor)
        finally:
            os.close(work_parent_descriptor)
    finally:
        os.close(data_descriptor)


def discard_logcat_trees(
    work_root: Path,
    adb_log_root: Path,
    data_root: Path,
    ownership_token: str,
) -> None:
    _validate_generated_work_root(work_root, data_root, ownership_token)
    _logcat_paths(work_root, adb_log_root)
    work_descriptor = _open_directory_chain(work_root)
    try:
        _verify_workspace_marker(work_descriptor, work_root, ownership_token)
        _remove_private_path(work_descriptor, Path("Images/reference/16373615"))
        _remove_private_path(work_descriptor, Path("adb-live"))
    finally:
        os.close(work_descriptor)


def discard_private_workspace(
    work_root: Path,
    data_root: Path,
    ownership_token: str,
) -> None:
    _validate_generated_work_root(work_root, data_root, ownership_token)
    data_descriptor = _open_private_data_root(data_root)
    try:
        work_parent_descriptor = _verify_private_child_directory(
            data_descriptor,
            "work",
        )
        try:
            try:
                work_descriptor = _open_child_directory(
                    work_parent_descriptor,
                    work_root.name,
                )
            except FileNotFoundError:
                return
            try:
                _verify_workspace_marker(
                    work_descriptor,
                    work_root,
                    ownership_token,
                )
                workspace_stat = os.fstat(work_descriptor)
                marker_name = ".apkrun-cuttlefish-workspace"
                marker_stat = _stat_entry_at(work_descriptor, marker_name)
                if not stat.S_ISREG(marker_stat.st_mode):
                    raise ValueError("generated workspace ownership marker is unsafe")
                _remove_directory_contents(
                    work_descriptor,
                    frozenset({marker_name}),
                )
                _unlink_entry_at(work_descriptor, marker_name, marker_stat)
                try:
                    _remove_directory_entry_at(
                        work_parent_descriptor,
                        work_root.name,
                        workspace_stat,
                    )
                except OSError as removal_error:
                    path_still_matches = False
                    try:
                        if not _same_inode(os.fstat(work_descriptor), workspace_stat):
                            raise OSError(
                                errno.EBUSY,
                                "opened workspace changed before its ownership "
                                "marker could be restored",
                                str(work_root),
                            )
                        _restore_workspace_marker(
                            work_descriptor,
                            work_root,
                            ownership_token,
                            stat.S_IMODE(marker_stat.st_mode),
                        )
                        current_workspace_stat = _stat_entry_at(
                            work_parent_descriptor,
                            work_root.name,
                        )
                        path_still_matches = _same_inode(
                            current_workspace_stat,
                            workspace_stat,
                        )
                    except OSError as restore_error:
                        raise OSError(
                            errno.EBUSY,
                            "workspace removal failed and its ownership marker "
                            "could not be restored; manual cleanup is required",
                            str(work_root),
                        ) from restore_error
                    if not path_still_matches:
                        raise OSError(
                            errno.EBUSY,
                            "workspace directory changed during safe removal; "
                            "the marker was restored in the original directory "
                            "and manual cleanup is required",
                            str(work_root),
                        ) from removal_error
                    raise
            finally:
                os.close(work_descriptor)
        finally:
            os.close(work_parent_descriptor)
    finally:
        os.close(data_descriptor)


def _short_cvd_marker_content(
    root: Path,
    work_root: Path,
    ownership_token: str,
) -> bytes:
    if re.fullmatch(r"[a-f0-9]{64}", ownership_token) is None:
        raise ValueError("short Cuttlefish HOME ownership token is invalid")
    return (
        f"APKRun Cuttlefish short HOME v1\n{ownership_token}\n{work_root}\n{root}\n"
    ).encode()


def _restore_short_cvd_marker(
    root_descriptor: int,
    root: Path,
    work_root: Path,
    ownership_token: str,
) -> None:
    descriptor = os.open(
        ".apkrun-cvd-short-home",
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | os.O_NOFOLLOW,
        0o600,
        dir_fd=root_descriptor,
    )
    try:
        _write_all(
            descriptor,
            _short_cvd_marker_content(root, work_root, ownership_token),
        )
        os.fsync(descriptor)
    except BaseException:
        try:
            os.unlink(".apkrun-cvd-short-home", dir_fd=root_descriptor)
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def discard_short_cvd_home_root(
    root: Path,
    work_root: Path,
    data_root: Path,
    ownership_token: str,
    host_dir: Path,
    state_root: Path,
    socket_metrics_path: Path,
) -> None:
    _validate_generated_work_root(work_root, data_root, ownership_token)
    physical_tmp = Path(os.path.realpath("/tmp"))
    if (
        not root.is_absolute()
        or root.parent != physical_tmp
        or re.fullmatch(r"x\.[A-Za-z0-9]{6}", root.name) is None
        or root.is_symlink()
    ):
        raise ValueError("short Cuttlefish HOME root is outside physical /tmp")
    if not root.exists():
        return
    parent_descriptor = _open_directory_chain(physical_tmp)
    root_descriptor: int | None = None
    tmp_descriptor: int | None = None
    expected_marker = _short_cvd_marker_content(root, work_root, ownership_token)
    tmp_removed = False
    marker_removed = False
    try:
        root_stat = _stat_entry_at(parent_descriptor, root.name)
        if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.getuid():
            raise ValueError("short Cuttlefish HOME root is unsafe")
        root_descriptor = _open_child_directory(parent_descriptor, root.name)
        if not _same_inode(os.fstat(root_descriptor), root_stat):
            raise OSError(errno.EBUSY, "short Cuttlefish HOME root changed", str(root))
        if stat.S_IMODE(root_stat.st_mode) != 0o700:
            raise ValueError("short Cuttlefish HOME root is not private")

        marker_stat = _stat_entry_at(root_descriptor, ".apkrun-cvd-short-home")
        if (
            not stat.S_ISREG(marker_stat.st_mode)
            or marker_stat.st_uid != os.getuid()
            or stat.S_IMODE(marker_stat.st_mode) != 0o600
        ):
            raise ValueError("short Cuttlefish HOME marker is unsafe")
        marker_descriptor = os.open(
            ".apkrun-cvd-short-home",
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            dir_fd=root_descriptor,
        )
        try:
            if os.read(marker_descriptor, len(expected_marker) + 1) != expected_marker:
                raise ValueError("short Cuttlefish HOME marker does not match this run")
        finally:
            os.close(marker_descriptor)

        with os.scandir(root_descriptor) as entries:
            root_entries = {entry.name for entry in entries}
        if root_entries != {"t", ".apkrun-cvd-short-home"}:
            raise ValueError("short Cuttlefish HOME root has unexpected entries")
        tmp_stat = _stat_entry_at(root_descriptor, "t")
        if not stat.S_ISDIR(tmp_stat.st_mode) or tmp_stat.st_uid != os.getuid():
            raise ValueError("short Cuttlefish HOME temporary directory is unsafe")
        tmp_descriptor = _open_child_directory(root_descriptor, "t")
        if (
            not _same_inode(os.fstat(tmp_descriptor), tmp_stat)
            or stat.S_IMODE(tmp_stat.st_mode) != 0o700
        ):
            raise OSError(
                errno.EBUSY,
                "short Cuttlefish HOME temporary directory changed",
                str(root / "t"),
            )

        require_no_private_cvd_processes(host_dir, root / "t", root / "t")
        with os.scandir(tmp_descriptor) as entries:
            temporary_has_entries = next(entries, None) is not None
        if temporary_has_entries:
            _validated_unix_socket_metrics(socket_metrics_path)
        audit_unix_socket_paths([root / "t", state_root])
        require_no_private_cvd_processes(host_dir, root / "t", root / "t")
        _remove_directory_contents(tmp_descriptor)
        os.close(tmp_descriptor)
        tmp_descriptor = None
        _remove_directory_entry_at(root_descriptor, "t", tmp_stat)
        tmp_removed = True
        _unlink_entry_at(
            root_descriptor,
            ".apkrun-cvd-short-home",
            marker_stat,
        )
        marker_removed = True
        current_root_stat = _stat_entry_at(parent_descriptor, root.name)
        if not _same_inode(current_root_stat, root_stat):
            raise OSError(
                errno.EBUSY,
                "short Cuttlefish HOME root changed before removal",
                str(root),
            )
        os.rmdir(root.name, dir_fd=parent_descriptor)
    except BaseException:
        if root_descriptor is not None and (tmp_removed or marker_removed):
            try:
                if tmp_removed:
                    os.mkdir("t", mode=0o700, dir_fd=root_descriptor)
                if marker_removed:
                    _restore_short_cvd_marker(
                        root_descriptor,
                        root,
                        work_root,
                        ownership_token,
                    )
            except OSError as restore_error:
                raise OSError(
                    errno.EBUSY,
                    "short Cuttlefish HOME cleanup failed and its ownership "
                    "marker could not be restored",
                    str(root),
                ) from restore_error
        raise
    finally:
        if tmp_descriptor is not None:
            os.close(tmp_descriptor)
        if root_descriptor is not None:
            os.close(root_descriptor)
        os.close(parent_descriptor)


def _rename_directory_no_replace(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
    expected_source_stat: os.stat_result,
) -> None:
    source_descriptor = _open_child_directory(
        source_parent_descriptor,
        source_name,
    )
    try:
        pinned_source_stat = os.fstat(source_descriptor)
        if not _same_inode(pinned_source_stat, expected_source_stat):
            raise OSError(
                errno.EBUSY,
                "capture record changed before atomic publication",
                source_name,
            )
        quarantine_name = _quarantine_entry_at(
            source_parent_descriptor,
            source_name,
            pinned_source_stat,
            require_directory=True,
        )
        try:
            _renameat2_noreplace(
                source_parent_descriptor,
                quarantine_name,
                destination_parent_descriptor,
                destination_name,
            )
        except OSError:
            _restore_quarantined_entry(
                source_parent_descriptor,
                quarantine_name,
                source_name,
            )
            raise

        try:
            published_stat = _stat_entry_at(
                destination_parent_descriptor,
                destination_name,
            )
        except OSError:
            try:
                _renameat2_noreplace(
                    destination_parent_descriptor,
                    destination_name,
                    source_parent_descriptor,
                    source_name,
                )
            except OSError as error:
                raise OSError(
                    errno.EBUSY,
                    "capture record could not be rolled back after publication",
                    destination_name,
                ) from error
            raise
        if not _same_inode(published_stat, pinned_source_stat):
            try:
                _renameat2_noreplace(
                    destination_parent_descriptor,
                    destination_name,
                    source_parent_descriptor,
                    source_name,
                )
            except OSError as error:
                raise OSError(
                    errno.EBUSY,
                    "changed capture record could not be rolled back",
                    destination_name,
                ) from error
            raise OSError(
                errno.EBUSY,
                "capture record changed during atomic publication",
                source_name,
            )
    finally:
        os.close(source_descriptor)


def _verify_publication_mode_labels(
    work_root_name: str,
    result_name: str,
    experiment: dict[str, Any],
) -> None:
    mode_prefix = (
        rf"gpu-(?P<gpu>{GPU_MODE_PATH_PATTERN})"
        rf"(?:-console-(?P<console>{CONSOLE_MODE_PATH_PATTERN}))?"
    )
    work_match = re.fullmatch(rf"{mode_prefix}\.[A-Za-z0-9]+", work_root_name)
    result_match = re.fullmatch(
        rf"{mode_prefix}-[0-9]{{8}}T[0-9]{{6}}Z-[0-9]+",
        result_name,
    )
    if (
        work_match is None
        or result_match is None
        or work_match.group("console") is None
        or result_match.group("console") is None
    ):
        raise ValueError("diagnostic path does not identify its selected modes")
    if work_match.group("gpu") != result_match.group("gpu") or work_match.group(
        "console"
    ) != result_match.group("console"):
        raise ValueError("diagnostic workspace and result path mode labels differ")

    try:
        gpu_mode_slug = _gpu_mode_slug(experiment.get("gpuMode"))
    except ValueError as error:
        raise ValueError("published experiment has invalid GPU metadata") from error
    if (
        experiment.get("gpuModeSlug") != gpu_mode_slug
        or work_match.group("gpu") != gpu_mode_slug
    ):
        raise ValueError("diagnostic path GPU label differs from the capture")

    console_enabled = experiment.get("consoleEnabled")
    if type(console_enabled) is not bool:
        raise ValueError("published experiment is missing console metadata")
    console_mode_slug = _console_mode_slug(console_enabled)
    if experiment.get("consoleModeSlug") != console_mode_slug or (
        work_match.group("console") is not None
        and work_match.group("console") != console_mode_slug
    ):
        raise ValueError("diagnostic path console label differs from the capture")
    expected_experiment = (
        f"cuttlefish-gpu-{gpu_mode_slug}-console-{console_mode_slug}-boot-diagnosis"
    )
    if experiment.get("experiment") != expected_experiment:
        raise ValueError("published experiment name differs from its selected modes")


def publish_normalized_record(
    capture_record: Path,
    work_root: Path,
    data_root: Path,
    result_path: Path,
    ownership_token: str,
) -> None:
    _validate_generated_work_root(work_root, data_root, ownership_token)
    results_root = data_root / "results"
    if (
        result_path.parent != results_root
        or re.fullmatch(
            rf"gpu-(?:{GPU_MODE_PATH_PATTERN})"
            rf"(?:-console-(?:{CONSOLE_MODE_PATH_PATTERN}))?"
            rf"-[0-9]{{8}}T[0-9]{{6}}Z-[0-9]+",
            result_path.name,
        )
        is None
    ):
        raise ValueError("diagnostic result path is outside its results directory")
    try:
        record_relative = capture_record.relative_to(work_root)
    except ValueError as error:
        raise ValueError("capture record is outside the generated workspace") from error
    if not record_relative.parts or record_relative.is_absolute():
        raise ValueError("capture record path is invalid")
    data_descriptor = _open_private_data_root(data_root)
    try:
        work_parent_descriptor = _verify_private_child_directory(
            data_descriptor,
            "work",
        )
        try:
            results_descriptor = _verify_private_child_directory(
                data_descriptor,
                "results",
            )
            try:
                work_descriptor = _open_child_directory(
                    work_parent_descriptor,
                    work_root.name,
                )
                try:
                    _verify_workspace_marker(
                        work_descriptor,
                        work_root,
                        ownership_token,
                    )
                    capture_parent_descriptor = _open_relative_directory(
                        work_descriptor,
                        record_relative.parent,
                    )
                    try:
                        record_stat = os.stat(
                            record_relative.name,
                            dir_fd=capture_parent_descriptor,
                            follow_symlinks=False,
                        )
                        if not stat.S_ISDIR(record_stat.st_mode):
                            raise ValueError(
                                "normalized capture record is not a directory"
                            )
                        capture_descriptor = _open_child_directory(
                            capture_parent_descriptor,
                            record_relative.name,
                        )
                        try:
                            if not _same_inode(
                                os.fstat(capture_descriptor),
                                record_stat,
                            ):
                                raise OSError(
                                    errno.EBUSY,
                                    "capture record changed while reading metadata",
                                    record_relative.name,
                                )
                            experiment = _read_bounded_json_at(
                                capture_descriptor,
                                "experiment.json",
                            )
                            _verify_publication_mode_labels(
                                work_root.name,
                                result_path.name,
                                experiment,
                            )
                            captured_config = _read_bounded_json_at(
                                capture_descriptor,
                                "cuttlefish_config.json",
                            )
                            _verify_gpu_configuration(
                                _single_instance(captured_config),
                                experiment["gpuMode"],
                                experiment["consoleEnabled"],
                            )
                        finally:
                            os.close(capture_descriptor)
                        _rename_directory_no_replace(
                            capture_parent_descriptor,
                            record_relative.name,
                            results_descriptor,
                            result_path.name,
                            record_stat,
                        )
                    finally:
                        os.close(capture_parent_descriptor)
                finally:
                    os.close(work_descriptor)
            finally:
                os.close(results_descriptor)
        finally:
            os.close(work_parent_descriptor)
    finally:
        os.close(data_descriptor)


def _gpu_configuration(record: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    host = _read_json(record / "host.json")
    config = _read_json(record / "cuttlefish_config.json")
    return host, _single_instance(config)


def _single_instance(config: dict[str, Any]) -> dict[str, Any]:
    instances = config.get("instances")
    if not isinstance(instances, dict) or len(instances) != 1:
        raise ValueError("capture must contain exactly one Cuttlefish Android instance")
    instance = next(iter(instances.values()))
    if not isinstance(instance, dict):
        raise TypeError("Cuttlefish instance configuration must be an object")
    return instance


def _gpu_mode_slug(gpu_mode: str) -> str:
    try:
        return GPU_MODE_SLUGS[gpu_mode]
    except (KeyError, TypeError) as error:
        choices = ", ".join(GPU_MODE_SLUGS)
        raise ValueError(f"GPU mode must be one of: {choices}") from error


def _console_mode_slug(console_enabled: bool) -> str:
    if type(console_enabled) is not bool:
        raise ValueError("console-enabled selection must be a boolean")
    return CONSOLE_MODE_SLUGS[console_enabled]


def _verify_gpu_configuration(
    instance: dict[str, Any],
    gpu_mode: str,
    console_enabled: bool = True,
) -> None:
    _gpu_mode_slug(gpu_mode)
    _console_mode_slug(console_enabled)
    expected = {
        "gpu_mode": gpu_mode,
        "enable_gpu_vhost_user": False,
        "cpus": 4,
        "memory_mb": 4096,
        "console": console_enabled,
    }
    for key, value in expected.items():
        observed_value = instance.get(key)
        if type(observed_value) is type(value) and observed_value == value:
            continue
        if type(observed_value) in (str, int, float, bool) or observed_value is None:
            value_summary = repr(observed_value)
        else:
            value_summary = f"<{type(observed_value).__name__}>"
        raise ValueError(
            f"captured Cuttlefish configuration has unexpected {key}: {value_summary}"
        )


def validate_baseline_configuration(baseline_record: Path) -> dict[str, Any]:
    host, instance = _gpu_configuration(baseline_record)
    if host.get("buildId") != "16373615" or host.get("profile") != "default":
        raise ValueError("baseline must be the pinned build 16373615 default capture")
    _baseline_host_fingerprint(host)
    expected = {
        "gpu_mode": "guest_swiftshader",
        "cpus": 4,
        "memory_mb": 4096,
    }
    for key, value in expected.items():
        if instance.get(key) != value:
            raise ValueError(f"baseline configuration has unexpected {key}")
    return host


def parse_fleet_report(report: str) -> dict[str, str]:
    banner = VERSION_PATTERN.search(report)
    if banner is None:
        raise ValueError(
            "Cuttlefish fleet output did not include a version and VCS banner"
        )
    opening = report.find("{")
    if opening < 0:
        raise ValueError("Cuttlefish fleet output did not include its group list")
    try:
        payload = report[opening:]
        fleet, end = json.JSONDecoder().raw_decode(payload)
    except json.JSONDecodeError as error:
        raise ValueError("Cuttlefish fleet output contained invalid JSON") from error
    if payload[end:].strip():
        raise ValueError(
            "Cuttlefish fleet output contained unexpected trailing content"
        )
    groups = fleet.get("groups") if isinstance(fleet, dict) else None
    if groups != []:
        raise ValueError("Cuttlefish fleet must be empty before the experiment")
    return {
        "packageVersion": banner.group(1),
        "vcsRevision": banner.group(2).lower(),
    }


def _committed_baseline(
    repo_root: Path,
    baseline_record: Path,
    commit: str,
) -> tuple[dict[str, Any], dict[str, Any], str]:
    relative_record = baseline_record.relative_to(repo_root)
    contents: dict[str, str] = {}
    for filename in ("host.json", "cuttlefish_config.json", "cvd-create-console.log"):
        relative = (relative_record / filename).as_posix()
        committed = _git_blob_text(repo_root, f"{commit}:{relative}")
        try:
            working = (baseline_record / filename).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise ValueError(f"baseline file is unavailable: {filename}") from error
        if working != committed:
            raise ValueError(
                f"baseline file differs from its committed revision: {filename}"
            )
        contents[filename] = committed
    try:
        host = json.loads(contents["host.json"])
        config = json.loads(contents["cuttlefish_config.json"])
    except json.JSONDecodeError as error:
        raise ValueError("committed baseline contains invalid JSON") from error
    if not isinstance(host, dict) or not isinstance(config, dict):
        raise TypeError("committed baseline JSON files must contain objects")
    instance = _single_instance(config)
    if host.get("buildId") != "16373615" or host.get("profile") != "default":
        raise ValueError("baseline must be the pinned build 16373615 default capture")
    expected = {"gpu_mode": "guest_swiftshader", "cpus": 4, "memory_mb": 4096}
    for key, value in expected.items():
        if instance.get(key) != value:
            raise ValueError(f"baseline configuration has unexpected {key}")
    return host, instance, contents["cvd-create-console.log"]


def patch_capture_script(
    path: Path,
    gpu_mode: str = "none",
    console_enabled: bool = True,
) -> None:
    _gpu_mode_slug(gpu_mode)
    _console_mode_slug(console_enabled)
    console_argument = str(console_enabled).lower()
    if path.is_symlink() or not path.is_file():
        raise ValueError("private capture script must be a regular file")
    source = path.read_text(encoding="utf-8")
    replacements = (
        ("#!/bin/sh\n", "#!/usr/bin/env bash\n"),
        ("set -eu\n", "set -euo pipefail\n"),
        (
            'script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)\n',
            (
                'if [ -n "${APKRUN_CAPTURE_SCRIPT_DIR:-}" ]; then\n'
                "  script_dir=$APKRUN_CAPTURE_SCRIPT_DIR\n"
                "else\n"
                '  script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)\n'
                "fi\n"
            ),
        ),
        (
            (
                '  if [ "$started" -eq 1 ]; then\n'
                "    if remove_cvd_group_bounded >/dev/null 2>&1; then\n"
                "      started=0\n"
                '      if rm -rf "$cvd_home"; then\n'
                "        cvd_home=\n"
                "        preserve_cvd_home=0\n"
                "      else\n"
                "        preserve_cvd_home=1\n"
                "      fi\n"
                "    else\n"
                "      preserve_cvd_home=1\n"
                "    fi\n"
                "  fi"
            ),
            (
                '  if [ "$started" -eq 1 ]; then\n'
                "    if remove_cvd_group_bounded >/dev/null 2>&1; then\n"
                "      started=0\n"
                "      preserve_cvd_home=0\n"
                "    else\n"
                "      preserve_cvd_home=1\n"
                "    fi\n"
                "  fi"
            ),
        ),
        (
            (
                '  if [ -n "$cvd_home" ] && [ -d "$cvd_home" ]; then\n'
                '    if [ "$preserve_cvd_home" -eq 1 ]; then\n'
                "      printf 'Cuttlefish HOME retained for inspection or cleanup: %s\\n' \"$cvd_home\" >&2\n"
                '    elif rm -rf "$cvd_home"; then\n'
                "      cvd_home=\n"
                "    else\n"
                "      printf 'could not remove temporary Cuttlefish HOME: %s\\n' \"$cvd_home\" >&2\n"
                "    fi\n"
                "  fi"
            ),
            (
                '  if [ -n "$cvd_home" ] && [ -d "$cvd_home" ]; then\n'
                '    if [ "$preserve_cvd_home" -eq 0 ]; then\n'
                '      if [ -z "${APKRUN_EXPERIMENT_TOOLS:-}" ] \\\n'
                '        || [ -z "${APKRUN_CVD_HOME_TMPDIR:-}" ] \\\n'
                '        || [ -z "${APKRUN_CVD_STATE_DIR:-}" ] \\\n'
                '        || [ -z "${APKRUN_EXPERIMENT_SOCKET_METRICS:-}" ]; then\n'
                "        preserve_cvd_home=1\n"
                "        exit_status=1\n"
                "        printf 'Cuttlefish HOME retained because cleanup verification is not configured.\\n' >&2\n"
                '      elif ! python3 "$APKRUN_EXPERIMENT_TOOLS/experiment_support.py" \\\n'
                '        check-cvd-processes --host-dir "$CVD_HOST_DIR" \\\n'
                '        --home-root "$cvd_home" --tmpdir-root "$APKRUN_CVD_HOME_TMPDIR"; then\n'
                "        preserve_cvd_home=1\n"
                "        exit_status=1\n"
                "        printf 'Cuttlefish HOME retained because a host process may still use it.\\n' >&2\n"
                '      elif ! python3 "$APKRUN_EXPERIMENT_TOOLS/experiment_support.py" \\\n'
                '        audit-unix-sockets --root "$APKRUN_CVD_HOME_TMPDIR" \\\n'
                '        --root "$APKRUN_CVD_STATE_DIR" \\\n'
                '        --output "$APKRUN_EXPERIMENT_SOCKET_METRICS"; then\n'
                "        preserve_cvd_home=1\n"
                "        exit_status=1\n"
                "        printf 'Cuttlefish HOME retained because socket paths could not be verified.\\n' >&2\n"
                '      elif ! python3 "$APKRUN_EXPERIMENT_TOOLS/experiment_support.py" \\\n'
                '        check-cvd-processes --host-dir "$CVD_HOST_DIR" \\\n'
                '        --home-root "$cvd_home" --tmpdir-root "$APKRUN_CVD_HOME_TMPDIR"; then\n'
                "        preserve_cvd_home=1\n"
                "        exit_status=1\n"
                "        printf 'Cuttlefish HOME retained because a host process appeared during cleanup verification.\\n' >&2\n"
                '      elif rm -rf "$cvd_home"; then\n'
                "        cvd_home=\n"
                "      else\n"
                "        preserve_cvd_home=1\n"
                "        exit_status=1\n"
                "        printf 'could not remove temporary Cuttlefish HOME: %s\\n' \"$cvd_home\" >&2\n"
                "      fi\n"
                "    fi\n"
                '    if [ -n "$cvd_home" ] && [ "$preserve_cvd_home" -eq 1 ]; then\n'
                "      printf 'Cuttlefish HOME retained for inspection or cleanup: %s\\n' \"$cvd_home\" >&2\n"
                "    fi\n"
                "  fi"
            ),
        ),
        (
            'PATH="$CVD_HOST_DIR/bin:$PATH"',
            'PATH="$APKRUN_DIAGNOSTIC_ADB_SHIM_DIR:$CVD_HOST_DIR/bin:$PATH"',
        ),
        (
            'cvd_home=$(mktemp -d "${TMPDIR:-/tmp}/apkrun-cvd-home.${profile}.XXXXXX")',
            'cvd_home=$(mktemp -d "${APKRUN_CVD_HOME_TMPDIR:-${TMPDIR:-/tmp}}/h.XXXXXX")',
        ),
        (
            "launch_profile() {",
            f"""start_cvd_group_with_gpu_mode() {{
  run_cvd_command_with_live_logs cvd "--group_name=$cvd_group_name" \\
    start --gpu_mode={gpu_mode} --gpu_vhost_user_mode=off --console={console_argument}
}}

launch_profile() {{""",
        ),
        (
            ('capture_adb() {\n  HOME="$cvd_home" APKRUN_CAPTURE_PID=$$ adb "$@"\n}\n'),
            (
                "capture_adb() {\n"
                '  HOME="$cvd_home" APKRUN_CAPTURE_PID=$$ adb "$@"\n'
                "}\n"
                "\n"
                "record_adb_helper_cleanup() {\n"
                "  local status_path=$1\n"
                '  local marker="$APKRUN_EXPERIMENT_STATUS_ROOT/adb-helper-cleanup-incomplete.json"\n'
                '  if [ -f "$status_path" ] && [ ! -L "$status_path" ] \\\n'
                '    && grep -Fq \'"cleanupComplete": true\' "$status_path"; then\n'
                "    return 0\n"
                "  fi\n"
                '  printf \'%s\\n\' \'{"schemaVersion":1,"bytesWritten":0,"truncated":false,"timedOut":false,"childExitCode":null,"signal":null,"cleanupComplete":false}\' \\\n'
                '    > "$marker" || return 1\n'
                "  return 1\n"
                "}\n"
                "\n"
                "capture_adb_value() {\n"
                "  local maximum_bytes=$1 command_timeout=$2\n"
                "  shift 2\n"
                '  local token="${BASHPID:-$$}-$RANDOM"\n'
                '  local output_path="$TMPDIR/.apkrun-adb-$token"\n'
                '  local status_path="$TMPDIR/.apkrun-adb-$token.json"\n'
                "  local command_status=0 command_now command_remaining\n"
                "  command_now=$(date +%s)\n"
                "  command_remaining=$((boot_timeout_deadline - command_now))\n"
                '  if [ "$command_remaining" -le 0 ]; then\n'
                "    boot_deadline_expired=1\n"
                "    return 124\n"
                "  fi\n"
                '  if [ "$command_timeout" -gt "$command_remaining" ]; then\n'
                "    command_timeout=$command_remaining\n"
                "  fi\n"
                '  if python3 "$script_dir/capture_bounded.py" \\\n'
                '    --timeout-seconds "$command_timeout" --max-bytes "$maximum_bytes" \\\n'
                '    --fail-on-truncate --output "$output_path" --status "$status_path" -- \\\n'
                '    env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb "$@"; then\n'
                '    if cat "$output_path"; then\n'
                "      :\n"
                "    else\n"
                "      command_status=$?\n"
                "    fi\n"
                "  else\n"
                "    command_status=$?\n"
                "  fi\n"
                '  if ! record_adb_helper_cleanup "$status_path"; then\n'
                "    command_status=1\n"
                "  fi\n"
                '  rm -f "$output_path" "$status_path"\n'
                '  return "$command_status"\n'
                "}\n"
            ),
        ),
        (
            (
                "adb_preflight_timeout_seconds=10\n"
                "if adb_device_list=$(timeout --kill-after=2s "
                '"$adb_preflight_timeout_seconds" adb devices); then\n'
                "  :\n"
                "else\n"
                "  printf 'ADB did not respond during the %s-second preflight; check the ADB server and retry.\\n' \\\n"
                '    "$adb_preflight_timeout_seconds" >&2\n'
                "  exit 1\n"
                "fi"
            ),
            (
                "adb_preflight_timeout_seconds=10\n"
                'adb_preflight_token="${BASHPID:-$$}-$RANDOM"\n'
                'adb_preflight_output="$TMPDIR/.apkrun-adb-preflight-$adb_preflight_token"\n'
                'adb_preflight_status="$adb_preflight_output.json"\n'
                "adb_preflight_status_code=0\n"
                'if python3 "$script_dir/capture_bounded.py" \\\n'
                '  --timeout-seconds "$adb_preflight_timeout_seconds" --max-bytes 4096 \\\n'
                '  --fail-on-truncate --output "$adb_preflight_output" \\\n'
                '  --status "$adb_preflight_status" -- \\\n'
                '  env "APKRUN_CAPTURE_PID=$$" adb devices; then\n'
                '  if adb_device_list=$(cat "$adb_preflight_output"); then\n'
                "    :\n"
                "  else\n"
                "    adb_preflight_status_code=$?\n"
                "  fi\n"
                "else\n"
                "  adb_preflight_status_code=$?\n"
                "fi\n"
                'if [ ! -f "$adb_preflight_status" ] || [ -L "$adb_preflight_status" ] \\\n'
                '  || ! grep -Fq \'"cleanupComplete": true\' "$adb_preflight_status"; then\n'
                '  printf \'%s\\n\' \'{"schemaVersion":1,"bytesWritten":0,"truncated":false,"timedOut":false,"childExitCode":null,"signal":null,"cleanupComplete":false}\' \\\n'
                '    > "$APKRUN_EXPERIMENT_STATUS_ROOT/adb-helper-cleanup-incomplete.json" \\\n'
                "    || adb_preflight_status_code=1\n"
                "fi\n"
                'rm -f "$adb_preflight_output" "$adb_preflight_status"\n'
                'if [ "$adb_preflight_status_code" -ne 0 ]; then\n'
                "  printf 'ADB did not respond during the %s-second preflight; check the ADB server and retry.\\n' \\\n"
                '    "$adb_preflight_timeout_seconds" >&2\n'
                "  exit 1\n"
                "fi"
            ),
        ),
        (
            (
                "default)\n"
                "      create_cvd_group_with_common_options --cpus 4 --memory_mb 4096\n"
                "      ;;"
            ),
            (
                "default)\n"
                f"      create_cvd_group_with_common_options --gpu_mode={gpu_mode} "
                f"--gpu_vhost_user_mode=off --console={console_argument} "
                "--cpus 4 --memory_mb 4096\n"
                "      ;;"
            ),
        ),
        (
            (
                '          if capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \\\n'
                '            > "$raw_log" 2>/dev/null; then'
            ),
            (
                '          if python3 "$script_dir/capture_bounded.py" \\\n'
                "            --timeout-seconds 30 --max-bytes 8388608 \\\n"
                '            --output "$raw_log" \\\n'
                '            --status "$APKRUN_EXPERIMENT_STATUS_ROOT/guest-logcat.json" -- \\\n'
                '            env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb \\\n'
                '              -s "$adb_serial" exec-out sh -c "$guest_command"; then'
            ),
        ),
        (
            (
                '        elif ! capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \\\n'
                '          > "$stage/$output_file" 2>/dev/null; then'
            ),
            (
                '        elif ! python3 "$script_dir/capture_bounded.py" \\\n'
                "          --timeout-seconds 30 --max-bytes 1048576 \\\n"
                '          --output "$stage/$output_file" \\\n'
                '          --status "$APKRUN_EXPERIMENT_STATUS_ROOT/guest-${output_file}.json" -- \\\n'
                '          env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb \\\n'
                '            -s "$adb_serial" exec-out sh -c "$guest_command"; then'
            ),
        ),
        (
            (
                'if ! launch_profile > "$stage/cvd-create-console.log" 2>&1 \\\n'
                '  || ! run_cvd_command_with_live_logs cvd "--group_name=$cvd_group_name" start \\\n'
                '    >> "$stage/cvd-create-console.log" 2>&1; then'
            ),
            (
                ': > "$stage/cvd-create-console.log"\n'
                "cvd_command_failed=0\n"
                'if ! launch_profile 2>&1 | python3 "$script_dir/capture_bounded.py" \\\n'
                '  --stdin --drain-after-limit --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
                '  --status "$APKRUN_EXPERIMENT_STATUS_ROOT/cvd-create.json" --append; then\n'
                "  cvd_command_failed=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -eq 0 ] \\\n'
                "  && ! start_cvd_group_with_gpu_mode 2>&1 \\\n"
                '    | python3 "$script_dir/capture_bounded.py" \\\n'
                '      --stdin --drain-after-limit --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
                '      --status "$APKRUN_EXPERIMENT_STATUS_ROOT/cvd-start.json" --append; then\n'
                "  cvd_command_failed=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -ne 0 ]; then'
            ),
        ),
        (
            (
                '  HOME="$cvd_home" timeout --kill-after=2s 10 \\\n'
                '    adb disconnect "127.0.0.1:$adb_port" >/dev/null 2>&1 || true\n'
            ),
            (
                '  capture_adb_value 4096 10 adb disconnect "127.0.0.1:$adb_port" \\\n'
                "    >/dev/null 2>&1 || true\n"
            ),
        ),
        (
            (
                '    run_with_boot_deadline adb connect "127.0.0.1:$adb_port" \\\n'
                "      >/dev/null 2>&1 || true"
            ),
            (
                '    capture_adb_value 4096 10 adb connect "127.0.0.1:$adb_port" \\\n'
                "      >/dev/null 2>&1 || true"
            ),
        ),
        (
            "if adb_devices=$(run_with_boot_deadline adb devices 2>/dev/null); then",
            "if adb_devices=$(capture_adb_value 4096 10 adb devices 2>/dev/null); then",
        ),
        (
            (
                'if boot_state=$(run_with_boot_deadline adb -s "$adb_serial" \\\n'
                "        shell getprop sys.boot_completed 2>/dev/null); then"
            ),
            (
                'if boot_state=$(capture_adb_value 256 10 adb -s "$adb_serial" \\\n'
                "        shell getprop sys.boot_completed 2>/dev/null); then"
            ),
        ),
        (
            (
                '    if ! run_with_boot_deadline adb -s "$adb_serial" wait-for-device \\\n'
                "      >/dev/null 2>&1; then"
            ),
            (
                '    if ! capture_adb_value 4096 10 adb -s "$adb_serial" wait-for-device \\\n'
                "      >/dev/null 2>&1; then"
            ),
        ),
        (
            (
                'if [ "$cvd_command_failed" -ne 0 ]; then\n'
                '  if [ "$boot_deadline_expired" -eq 1 ]; then'
            ),
            (
                'if [ "$cvd_command_failed" -ne 0 ] \\\n'
                '  && [ "$(date +%s)" -ge "$boot_timeout_deadline" ]; then\n'
                "  boot_deadline_expired=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -ne 0 ]; then\n'
                '  if [ "$boot_deadline_expired" -eq 1 ]; then'
            ),
        ),
    )
    for old, new in replacements:
        if source.count(old) != 1:
            raise ValueError(
                "private capture script no longer matches the reviewed baseline"
            )
        source = source.replace(old, new)
    path.write_text(source, encoding="utf-8")


def verify_host(
    repo_root: Path,
    baseline_record: Path,
    fleet_report_path: Path,
    experiment_root: Path,
    patched_capture: Path,
    gpu_mode: str = "none",
    console_enabled: bool = True,
) -> dict[str, Any]:
    gpu_mode_slug = _gpu_mode_slug(gpu_mode)
    console_mode_slug = _console_mode_slug(console_enabled)
    repo_root = repo_root.resolve()
    baseline_record = baseline_record.resolve()
    if baseline_record != repo_root / BASELINE_RELATIVE:
        raise ValueError("diagnosis must use the pinned canonical baseline record")
    commit = _baseline_commit(repo_root, baseline_record)
    baseline, _, baseline_console = _committed_baseline(
        repo_root,
        baseline_record,
        commit,
    )
    revision = VCS_PATTERN.search(baseline_console)
    version = baseline.get("cvdPackageVersion")
    if not isinstance(version, str) or revision is None:
        raise ValueError("committed baseline does not identify Cuttlefish")
    baseline_host = _baseline_host_fingerprint(baseline)
    observed_host = _current_host_fingerprint()
    if observed_host != {key: baseline_host[key] for key in HOST_FACT_FIELDS}:
        raise ValueError(
            "current Linux host differs from the pinned baseline host conditions"
        )
    observed_host["cvdInstanceNumber"] = baseline_host["cvdInstanceNumber"]
    expected_identity = {
        "packageVersion": version,
        "vcsRevision": revision.group(1).lower(),
    }
    try:
        report = fleet_report_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("cannot read the private Cuttlefish fleet report") from error
    observed_identity = parse_fleet_report(report)
    if observed_identity != expected_identity:
        raise ValueError(
            "installed Cuttlefish version or VCS revision differs from baseline"
        )
    (
        baseline_tool_commit,
        baseline_tool_blobs,
        observed_tool_commit,
        observed_tool_blobs,
    ) = _verify_tool_revisions(repo_root, baseline_record)
    experiment_sources = _experiment_source_hashes(
        repo_root,
        observed_tool_commit,
        experiment_root,
        patched_capture,
    )
    return {
        "schemaVersion": 1,
        "baselineRecord": BASELINE_RELATIVE.as_posix(),
        "baselineCvd": expected_identity,
        "observedCvd": observed_identity,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": baseline_tool_commit,
        "baselineToolBlobs": baseline_tool_blobs,
        "observedToolCommit": observed_tool_commit,
        "observedToolBlobs": observed_tool_blobs,
        "experimentSources": experiment_sources,
        "baselineGpuMode": "guest_swiftshader",
        "gpuMode": gpu_mode,
        "gpuModeSlug": gpu_mode_slug,
        "consoleEnabled": console_enabled,
        "consoleModeSlug": console_mode_slug,
        "cpuCount": 4,
        "memoryMb": 4096,
        "buildId": baseline["buildId"],
    }


def build_experiment_record(
    capture_record: Path,
    repo_root: Path,
    baseline_record: Path,
    tool_copy_root: Path,
    canonical_capture_copy: Path,
    manifest_copy_root: Path,
    experiment_root: Path,
    patched_capture: Path,
    host_identity_path: Path,
    logcat_summary_path: Path,
    adb_state_path: Path,
    capture_exit_code: int,
    adb_endpoint: str,
    capture_status_root: Path,
    capture_run_status_path: Path,
    socket_metrics_path: Path,
    fleet_socket_metrics_path: Path,
    gpu_mode: str = "none",
    console_enabled: bool = True,
) -> dict[str, Any]:
    gpu_mode_slug = _gpu_mode_slug(gpu_mode)
    console_mode_slug = _console_mode_slug(console_enabled)
    host, instance = _gpu_configuration(capture_record)
    _verify_gpu_configuration(instance, gpu_mode, console_enabled)
    host_identity = _read_json(host_identity_path)
    if (
        host_identity.get("gpuMode", "none") != gpu_mode
        or host_identity.get("gpuModeSlug", gpu_mode_slug) != gpu_mode_slug
        or host_identity.get("consoleEnabled") is not console_enabled
        or host_identity.get("consoleModeSlug") != console_mode_slug
    ):
        raise ValueError(
            "capture GPU or console mode differs from the verified selection"
        )
    verify_tool_copy(
        repo_root,
        baseline_record,
        host_identity,
        tool_copy_root,
        canonical_capture_copy,
        manifest_copy_root,
        experiment_root,
        patched_capture,
    )
    logcat_summary = _read_json(logcat_summary_path)
    capture_run_status = _read_json(capture_run_status_path)
    baseline_cvd = host_identity.get("baselineCvd")
    observed_cvd = host_identity.get("observedCvd")
    baseline_host = host_identity.get("baselineHost")
    observed_host = host_identity.get("observedHost")
    if not isinstance(baseline_cvd, dict):
        raise TypeError("verified baseline Cuttlefish identity is missing")
    if not isinstance(observed_cvd, dict):
        raise TypeError("verified Cuttlefish host identity is missing")
    if observed_cvd != baseline_cvd:
        raise ValueError(
            "observed Cuttlefish identity differs from the pinned baseline"
        )
    if not isinstance(baseline_host, dict) or not isinstance(observed_host, dict):
        raise TypeError("verified baseline host conditions are missing")
    if baseline_host != observed_host:
        raise ValueError("verified reference host differs from the pinned baseline")
    captured_host = {
        field: host.get(field) for field in (*HOST_FACT_FIELDS, "cvdInstanceNumber")
    }
    if captured_host != observed_host:
        raise ValueError("captured reference host differs from the verified host")
    if (
        capture_run_status.get("timedOut") is not False
        or capture_run_status.get("signal") is not None
        or capture_run_status.get("childExitCode") != capture_exit_code
        or capture_run_status.get("cleanupComplete") is not True
    ):
        raise ValueError("capture runner did not finish within its verified deadline")
    console_path = capture_record / "cvd-create-console.log"
    try:
        console_text = console_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("capture Cuttlefish console log is unavailable") from error
    capture_banner = VERSION_PATTERN.search(console_text)
    if (
        capture_banner is None
        or {
            "packageVersion": capture_banner.group(1),
            "vcsRevision": capture_banner.group(2).lower(),
        }
        != observed_cvd
    ):
        raise ValueError("capture Cuttlefish identity differs from preflight")
    if host.get("buildId") != host_identity.get("buildId"):
        raise ValueError("captured Android build differs from the verified baseline")
    if host.get("profile") != "default":
        raise ValueError("diagnostic capture did not use the default capture profile")
    if host.get("cvdPackageVersion") != baseline_cvd.get("packageVersion"):
        raise ValueError("capture metadata records an unexpected Cuttlefish version")
    if not re.fullmatch(r"127\.0\.0\.1:[0-9]{1,5}", adb_endpoint):
        raise ValueError("ADB endpoint must be a loopback address and TCP port")
    if adb_state_path.is_symlink() or not adb_state_path.is_file():
        raise ValueError("ADB state record must be a regular file")
    state_sample_count = sum(
        1 for line in adb_state_path.read_text(encoding="utf-8").splitlines() if line
    )
    if not all(isinstance(value, (int, bool)) for value in logcat_summary.values()):
        raise ValueError("logcat summary contains unexpected non-numeric data")
    bounded_capture = _capture_statuses(capture_status_root)
    socket_metrics = {
        "capture": _validated_unix_socket_metrics(socket_metrics_path),
        "fleet": _validated_unix_socket_metrics(fleet_socket_metrics_path),
    }
    guest_logcat = bounded_capture["files"].get(
        "guest-logcat",
        {
            "bytesWritten": 0,
            "truncated": False,
            "timedOut": False,
            "childExitCode": None,
            "signal": None,
            "cleanupComplete": True,
        },
    )
    guest_logcat["captured"] = "guest-logcat" in bounded_capture["files"]
    return {
        "schemaVersion": 1,
        "experiment": (
            f"cuttlefish-gpu-{gpu_mode_slug}-console-{console_mode_slug}-boot-diagnosis"
        ),
        "gpuModeSlug": gpu_mode_slug,
        "consoleModeSlug": console_mode_slug,
        "baselineRecord": host_identity["baselineRecord"],
        "buildId": host_identity["buildId"],
        "baselineCvd": baseline_cvd,
        "observedCvd": observed_cvd,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": host_identity["baselineToolCommit"],
        "baselineToolBlobs": host_identity["baselineToolBlobs"],
        "observedToolCommit": host_identity["observedToolCommit"],
        "observedToolBlobs": host_identity["observedToolBlobs"],
        "experimentSources": host_identity["experimentSources"],
        "captureExitCode": capture_exit_code,
        "captureRun": capture_run_status,
        "bootTimeoutSeconds": 600,
        "runnerDeadlineSeconds": 900,
        "gpuMode": gpu_mode,
        "consoleEnabled": console_enabled,
        "cpuCount": 4,
        "memoryMb": 4096,
        "adbEndpoint": adb_endpoint,
        "adbServerTransport": "localfilesystem",
        "adbStateSampleCount": state_sample_count,
        "logcat": logcat_summary,
        "boundedCapture": bounded_capture,
        "unixSocketPaths": socket_metrics,
        "guestLogcatCapture": guest_logcat,
        "rawLogcatRetained": False,
    }


def _atomic_json(path: Path, document: dict[str, Any]) -> None:
    if path.is_symlink():
        raise ValueError("JSON destination must not be a symlink")
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
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare-data-root")
    prepare_parser.add_argument("--data-root", type=Path, required=True)
    prepare_parser.add_argument("--print-canonical", action="store_true")

    host_parser = subparsers.add_parser("verify-host")
    host_parser.add_argument("--repo-root", type=Path, required=True)
    host_parser.add_argument("--baseline-record", type=Path, required=True)
    host_parser.add_argument("--fleet-report", type=Path, required=True)
    host_parser.add_argument("--experiment-root", type=Path, required=True)
    host_parser.add_argument("--patched-capture", type=Path, required=True)
    host_parser.add_argument(
        "--gpu-mode",
        choices=tuple(GPU_MODE_SLUGS),
        default="none",
    )
    host_parser.add_argument(
        "--console-enabled",
        choices=("true", "false"),
        default="true",
    )
    host_parser.add_argument("--output", type=Path, required=True)

    tool_copy_parser = subparsers.add_parser("verify-tool-copy")
    tool_copy_parser.add_argument("--repo-root", type=Path, required=True)
    tool_copy_parser.add_argument("--baseline-record", type=Path, required=True)
    tool_copy_parser.add_argument("--host-identity", type=Path, required=True)
    tool_copy_parser.add_argument("--tool-copy-root", type=Path, required=True)
    tool_copy_parser.add_argument("--canonical-capture-copy", type=Path, required=True)
    tool_copy_parser.add_argument("--manifest-copy-root", type=Path, required=True)
    tool_copy_parser.add_argument("--experiment-root", type=Path, required=True)
    tool_copy_parser.add_argument("--patched-capture", type=Path, required=True)

    patch_parser = subparsers.add_parser("patch-capture")
    patch_parser.add_argument("--path", type=Path, required=True)
    patch_parser.add_argument(
        "--gpu-mode",
        choices=tuple(GPU_MODE_SLUGS),
        default="none",
    )
    patch_parser.add_argument(
        "--console-enabled",
        choices=("true", "false"),
        default="true",
    )

    socket_parser = subparsers.add_parser("audit-unix-sockets")
    socket_parser.add_argument("--root", type=Path, action="append", required=True)
    socket_parser.add_argument("--output", type=Path, required=True)

    process_parser = subparsers.add_parser("check-cvd-processes")
    process_parser.add_argument("--host-dir", type=Path, required=True)
    process_parser.add_argument("--home-root", type=Path, required=True)
    process_parser.add_argument("--tmpdir-root", type=Path, required=True)
    process_parser.add_argument("--process-root", type=Path, default=Path("/proc"))

    process_start_parser = subparsers.add_parser("process-start-time")
    process_start_parser.add_argument("--pid", type=int, required=True)

    signal_broker_parser = subparsers.add_parser("signal-process-broker")
    signal_broker_parser.add_argument("--pid", type=int, required=True)
    signal_broker_parser.add_argument("--start-time", required=True)
    signal_broker_parser.add_argument("--ready-file", type=Path, required=True)
    signal_broker_parser.add_argument("--exited-file", type=Path, required=True)
    signal_broker_parser.add_argument("--stopped-file", type=Path, required=True)

    short_root_parser = subparsers.add_parser("discard-short-cvd-root")
    short_root_parser.add_argument("--root", type=Path, required=True)
    short_root_parser.add_argument("--work-root", type=Path, required=True)
    short_root_parser.add_argument("--data-root", type=Path, required=True)
    short_root_parser.add_argument("--ownership-token", required=True)
    short_root_parser.add_argument("--host-dir", type=Path, required=True)
    short_root_parser.add_argument("--state-root", type=Path, required=True)
    short_root_parser.add_argument("--socket-metrics", type=Path, required=True)

    scrub_parser = subparsers.add_parser("scrub-logcat")
    scrub_parser.add_argument("--work-root", type=Path, required=True)
    scrub_parser.add_argument("--adb-log-root", type=Path, required=True)
    scrub_parser.add_argument("--data-root", type=Path, required=True)
    scrub_parser.add_argument("--ownership-token", required=True)

    discard_parser = subparsers.add_parser("discard-logcat-trees")
    discard_parser.add_argument("--work-root", type=Path, required=True)
    discard_parser.add_argument("--adb-log-root", type=Path, required=True)
    discard_parser.add_argument("--data-root", type=Path, required=True)
    discard_parser.add_argument("--ownership-token", required=True)

    workspace_parser = subparsers.add_parser("discard-workspace")
    workspace_parser.add_argument("--work-root", type=Path, required=True)
    workspace_parser.add_argument("--data-root", type=Path, required=True)
    workspace_parser.add_argument("--ownership-token", required=True)

    publish_parser = subparsers.add_parser("publish-record")
    publish_parser.add_argument("--capture-record", type=Path, required=True)
    publish_parser.add_argument("--work-root", type=Path, required=True)
    publish_parser.add_argument("--data-root", type=Path, required=True)
    publish_parser.add_argument("--result-path", type=Path, required=True)
    publish_parser.add_argument("--ownership-token", required=True)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--capture-record", type=Path, required=True)
    record_parser.add_argument("--repo-root", type=Path, required=True)
    record_parser.add_argument("--baseline-record", type=Path, required=True)
    record_parser.add_argument("--tool-copy-root", type=Path, required=True)
    record_parser.add_argument("--canonical-capture-copy", type=Path, required=True)
    record_parser.add_argument("--manifest-copy-root", type=Path, required=True)
    record_parser.add_argument("--experiment-root", type=Path, required=True)
    record_parser.add_argument("--patched-capture", type=Path, required=True)
    record_parser.add_argument("--host-identity", type=Path, required=True)
    record_parser.add_argument("--logcat-summary", type=Path, required=True)
    record_parser.add_argument("--adb-state", type=Path, required=True)
    record_parser.add_argument("--capture-exit-code", type=int, required=True)
    record_parser.add_argument("--adb-endpoint", required=True)
    record_parser.add_argument("--capture-status-root", type=Path, required=True)
    record_parser.add_argument("--capture-run-status", type=Path, required=True)
    record_parser.add_argument("--socket-metrics", type=Path, required=True)
    record_parser.add_argument("--fleet-socket-metrics", type=Path, required=True)
    record_parser.add_argument(
        "--gpu-mode",
        choices=tuple(GPU_MODE_SLUGS),
        default="none",
    )
    record_parser.add_argument(
        "--console-enabled",
        choices=("true", "false"),
        default="true",
    )
    record_parser.add_argument("--output", type=Path, required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "prepare-data-root":
            prepare_private_data_root(arguments.data_root)
            if arguments.print_canonical:
                print(arguments.data_root.resolve(strict=True))
            return 0
        if arguments.command == "patch-capture":
            patch_capture_script(
                arguments.path,
                arguments.gpu_mode,
                arguments.console_enabled == "true",
            )
            return 0
        if arguments.command == "audit-unix-sockets":
            metrics = audit_unix_socket_paths(arguments.root)
            _atomic_json(arguments.output, metrics)
            return 0
        if arguments.command == "check-cvd-processes":
            require_no_private_cvd_processes(
                arguments.host_dir,
                arguments.home_root,
                arguments.tmpdir_root,
                arguments.process_root,
            )
            return 0
        if arguments.command == "process-start-time":
            print(_process_start_time(Path("/proc") / str(arguments.pid)))
            return 0
        if arguments.command == "signal-process-broker":
            run_process_signal_broker(
                arguments.pid,
                arguments.start_time,
                arguments.ready_file,
                arguments.exited_file,
                arguments.stopped_file,
            )
            return 0
        if arguments.command == "discard-short-cvd-root":
            discard_short_cvd_home_root(
                arguments.root,
                arguments.work_root,
                arguments.data_root,
                arguments.ownership_token,
                arguments.host_dir,
                arguments.state_root,
                arguments.socket_metrics,
            )
            return 0
        if arguments.command == "scrub-logcat":
            scrub_raw_logcat(
                arguments.work_root,
                arguments.adb_log_root,
                arguments.data_root,
                arguments.ownership_token,
            )
            return 0
        if arguments.command == "discard-logcat-trees":
            discard_logcat_trees(
                arguments.work_root,
                arguments.adb_log_root,
                arguments.data_root,
                arguments.ownership_token,
            )
            return 0
        if arguments.command == "discard-workspace":
            discard_private_workspace(
                arguments.work_root,
                arguments.data_root,
                arguments.ownership_token,
            )
            return 0
        if arguments.command == "publish-record":
            publish_normalized_record(
                arguments.capture_record,
                arguments.work_root,
                arguments.data_root,
                arguments.result_path,
                arguments.ownership_token,
            )
            return 0
        if arguments.command == "verify-host":
            document = verify_host(
                arguments.repo_root.resolve(),
                arguments.baseline_record,
                arguments.fleet_report,
                arguments.experiment_root,
                arguments.patched_capture,
                arguments.gpu_mode,
                arguments.console_enabled == "true",
            )
        elif arguments.command == "verify-tool-copy":
            verify_tool_copy(
                arguments.repo_root,
                arguments.baseline_record,
                _read_json(arguments.host_identity),
                arguments.tool_copy_root,
                arguments.canonical_capture_copy,
                arguments.manifest_copy_root,
                arguments.experiment_root,
                arguments.patched_capture,
            )
            return 0
        else:
            document = build_experiment_record(
                arguments.capture_record,
                arguments.repo_root,
                arguments.baseline_record,
                arguments.tool_copy_root,
                arguments.canonical_capture_copy,
                arguments.manifest_copy_root,
                arguments.experiment_root,
                arguments.patched_capture,
                arguments.host_identity,
                arguments.logcat_summary,
                arguments.adb_state,
                arguments.capture_exit_code,
                arguments.adb_endpoint,
                arguments.capture_status_root,
                arguments.capture_run_status,
                arguments.socket_metrics,
                arguments.fleet_socket_metrics,
                arguments.gpu_mode,
                arguments.console_enabled == "true",
            )
        _atomic_json(arguments.output, document)
    except (OSError, TypeError, ValueError, KeyError) as error:
        parser.exit(1, f"experiment_support: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
