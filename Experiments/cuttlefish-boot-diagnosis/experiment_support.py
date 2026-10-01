#!/usr/bin/env python3
"""Validate the isolated Cuttlefish GPU-mode comparison and record provenance."""

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
import stat
import subprocess
import sys
import tempfile
import unicodedata
from collections.abc import Callable
from pathlib import Path
from typing import Any

BASELINE_RELATIVE = Path(
    "Images/reference/16373615/incomplete/default-20261001T120904-49816"
)
TOOL_PATHS = (
    Path("Images/tools/reference/capture.sh"),
    Path("Images/tools/reference/capture_cvd_start.py"),
    Path("Images/tools/reference/compare_boot.py"),
    Path("Images/tools/reference/normalize.yaml"),
    Path("Images/tools/reference/guest-capture.txt"),
    Path("Images/manifests/16373615/android-image.json"),
)
EXPERIMENT_TOOL_NAMES = (
    "capture-gpu-none.sh",
    "capture-lifecycle.sh",
    "capture_bounded.py",
    "experiment_support.py",
    "run_capture.py",
    "summarize_logcat.py",
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


def _read_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON file {path.name}") from error
    if not isinstance(document, dict):
        raise TypeError(f"JSON file {path.name} must contain an object")
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


def _baseline_commit(repo_root: Path, baseline_record: Path) -> str:
    baseline_host = baseline_record / "host.json"
    try:
        relative = baseline_host.relative_to(repo_root)
    except ValueError as error:
        raise ValueError("baseline record must be inside the repository") from error
    commit = _git(
        repo_root,
        "log",
        "-1",
        "--format=%H",
        "--",
        relative.as_posix(),
    )
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("could not identify the committed baseline record revision")
    return commit


def _verify_tool_revisions(
    repo_root: Path,
    baseline_record: Path,
) -> tuple[str, dict[str, str]]:
    commit = _baseline_commit(repo_root, baseline_record)
    blobs: dict[str, str] = {}
    for path in TOOL_PATHS:
        baseline_blob = _git(repo_root, "rev-parse", f"{commit}:{path.as_posix()}")
        current_blob = _git(repo_root, "hash-object", "--", path.as_posix())
        if not re.fullmatch(r"[0-9a-f]{40}", baseline_blob):
            raise ValueError(f"baseline is missing tracked tool {path.as_posix()}")
        if current_blob != baseline_blob:
            raise ValueError(
                f"capture tool differs from the baseline revision: {path.as_posix()}"
            )
        blobs[path.as_posix()] = current_blob
    return commit, blobs


def _experiment_source_hashes(
    experiment_root: Path,
    patched_capture: Path,
) -> dict[str, str]:
    sources: dict[str, str] = {}
    for name in EXPERIMENT_TOOL_NAMES:
        path = experiment_root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"experiment source is missing or unsafe: {name}")
        sources[name] = hashlib.sha256(path.read_bytes()).hexdigest()
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
        or re.fullmatch(r"gpu-none\.[A-Za-z0-9]+", work_root.name) is None
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
        or re.fullmatch(r"gpu-none-[0-9]{8}T[0-9]{6}Z-[0-9]+", result_path.name) is None
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


def patch_capture_script(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError("private capture script must be a regular file")
    source = path.read_text(encoding="utf-8")
    replacements = (
        ("#!/bin/sh\n", "#!/usr/bin/env bash\n"),
        ("set -eu\n", "set -euo pipefail\n"),
        (
            'PATH="$CVD_HOST_DIR/bin:$PATH"',
            'PATH="$APKRUN_DIAGNOSTIC_ADB_SHIM_DIR:$CVD_HOST_DIR/bin:$PATH"',
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
                "      create_cvd_group_with_common_options --gpu_mode=none --cpus 4 --memory_mb 4096\n"
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
                '  --stdin --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
                '  --status "$APKRUN_EXPERIMENT_STATUS_ROOT/cvd-create.json" --append; then\n'
                "  cvd_command_failed=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -eq 0 ] \\\n'
                '  && ! run_cvd_command_with_live_logs cvd "--group_name=$cvd_group_name" \\\n'
                "    start --gpu_mode=none 2>&1 \\\n"
                '    | python3 "$script_dir/capture_bounded.py" \\\n'
                '      --stdin --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
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
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    baseline_record = baseline_record.resolve()
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
    _, blobs = _verify_tool_revisions(repo_root, baseline_record)
    experiment_sources = _experiment_source_hashes(experiment_root, patched_capture)
    return {
        "schemaVersion": 1,
        "baselineRecord": BASELINE_RELATIVE.as_posix(),
        "baselineCvd": expected_identity,
        "observedCvd": observed_identity,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": commit,
        "toolBlobs": blobs,
        "experimentSources": experiment_sources,
        "baselineGpuMode": "guest_swiftshader",
        "gpuMode": "none",
        "cpuCount": 4,
        "memoryMb": 4096,
        "buildId": baseline["buildId"],
    }


def build_experiment_record(
    capture_record: Path,
    host_identity_path: Path,
    logcat_summary_path: Path,
    adb_state_path: Path,
    capture_exit_code: int,
    adb_endpoint: str,
    capture_status_root: Path,
    capture_run_status_path: Path,
) -> dict[str, Any]:
    host, instance = _gpu_configuration(capture_record)
    host_identity = _read_json(host_identity_path)
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
    expected = {"gpu_mode": "none", "cpus": 4, "memory_mb": 4096}
    for key, value in expected.items():
        observed_value = instance.get(key)
        if observed_value != value:
            if (
                type(observed_value) in (str, int, float, bool)
                or observed_value is None
            ):
                value_summary = repr(observed_value)
            else:
                value_summary = f"<{type(observed_value).__name__}>"
            raise ValueError(
                "captured Cuttlefish configuration has unexpected "
                f"{key}: {value_summary}"
            )
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
        "experiment": "cuttlefish-gpu-none-boot-diagnosis",
        "baselineRecord": host_identity["baselineRecord"],
        "buildId": host_identity["buildId"],
        "baselineCvd": baseline_cvd,
        "observedCvd": observed_cvd,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": host_identity["baselineToolCommit"],
        "toolBlobs": host_identity["toolBlobs"],
        "experimentSources": host_identity["experimentSources"],
        "captureExitCode": capture_exit_code,
        "captureRun": capture_run_status,
        "bootTimeoutSeconds": 600,
        "runnerDeadlineSeconds": 900,
        "gpuMode": "none",
        "cpuCount": 4,
        "memoryMb": 4096,
        "adbEndpoint": adb_endpoint,
        "adbServerTransport": "localfilesystem",
        "adbStateSampleCount": state_sample_count,
        "logcat": logcat_summary,
        "boundedCapture": bounded_capture,
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
    host_parser.add_argument("--output", type=Path, required=True)

    patch_parser = subparsers.add_parser("patch-capture")
    patch_parser.add_argument("--path", type=Path, required=True)

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
    record_parser.add_argument("--host-identity", type=Path, required=True)
    record_parser.add_argument("--logcat-summary", type=Path, required=True)
    record_parser.add_argument("--adb-state", type=Path, required=True)
    record_parser.add_argument("--capture-exit-code", type=int, required=True)
    record_parser.add_argument("--adb-endpoint", required=True)
    record_parser.add_argument("--capture-status-root", type=Path, required=True)
    record_parser.add_argument("--capture-run-status", type=Path, required=True)
    record_parser.add_argument("--output", type=Path, required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "prepare-data-root":
            prepare_private_data_root(arguments.data_root)
            if arguments.print_canonical:
                print(arguments.data_root.resolve(strict=True))
            return 0
        if arguments.command == "patch-capture":
            patch_capture_script(arguments.path)
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
            )
        else:
            document = build_experiment_record(
                arguments.capture_record,
                arguments.host_identity,
                arguments.logcat_summary,
                arguments.adb_state,
                arguments.capture_exit_code,
                arguments.adb_endpoint,
                arguments.capture_status_root,
                arguments.capture_run_status,
            )
        _atomic_json(arguments.output, document)
    except (OSError, TypeError, ValueError, KeyError) as error:
        parser.exit(1, f"experiment_support: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
