#!/usr/bin/env python3
"""Collect bounded composite-disk configuration files from one Cuttlefish instance."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
from pathlib import Path

MAX_SPEC_FILES = 32
MAX_SPEC_FILE_BYTES = 256 * 1024
MAX_TOTAL_BYTES = 1024 * 1024
MAX_DIRECTORIES = 4096
MAX_DIRECTORY_DEPTH = 128
MAX_INVENTORY_ENTRIES = 100_000
SPEC_SUFFIX = "_composite_disk_config.txt"


class CollectionError(Exception):
    """A selected instance's composite-disk configs could not be safely collected."""


def _scandir(directory_fd: int) -> tuple[int, os.ScandirIterator[str]]:
    scan_fd = os.dup(directory_fd)
    try:
        iterator = os.scandir(scan_fd)
    except OSError:
        os.close(scan_fd)
        raise
    return scan_fd, iterator


def _read_regular_file(directory_fd: int, name: str) -> bytes:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOCTTY", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        raise CollectionError("composite-disk config could not be opened safely") from error

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise CollectionError("composite-disk config is not a regular file")
        if metadata.st_size > MAX_SPEC_FILE_BYTES:
            raise CollectionError("composite-disk config exceeds the per-file size limit")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            contents = stream.read(MAX_SPEC_FILE_BYTES + 1)
        if len(contents) > MAX_SPEC_FILE_BYTES:
            raise CollectionError("composite-disk config exceeds the per-file size limit")
        return contents
    except OSError as error:
        raise CollectionError("composite-disk config could not be read") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _directory_flags() -> int:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return flags


def _open_absolute_directory(path: Path, flags: int) -> int:
    if not path.is_absolute():
        raise CollectionError("private Cuttlefish HOME parent must be absolute")
    descriptor = os.open(path.anchor, flags)
    try:
        for component in path.parts[1:]:
            child_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child_descriptor
        return descriptor
    except OSError:
        os.close(descriptor)
        raise


def _open_selected_instance(trusted_home: Path, instance_runtime: Path) -> int:
    home_path = Path(os.path.abspath(trusted_home))
    instance_path = Path(os.path.abspath(instance_runtime))
    try:
        relative_instance = instance_path.relative_to(home_path)
    except ValueError as error:
        raise CollectionError("selected Cuttlefish instance is outside the private HOME") from error
    if not relative_instance.parts or any(
        component in {"", ".", ".."} for component in relative_instance.parts
    ):
        raise CollectionError("selected Cuttlefish instance path is invalid")

    flags = _directory_flags()
    try:
        canonical_parent = home_path.parent.resolve(strict=True)
        parent_fd = _open_absolute_directory(canonical_parent, flags)
        try:
            home_fd = os.open(home_path.name, flags, dir_fd=parent_fd)
        finally:
            os.close(parent_fd)
    except OSError as error:
        raise CollectionError("private Cuttlefish HOME is unavailable") from error

    instance_fd = -1
    try:
        if not stat.S_ISDIR(os.fstat(home_fd).st_mode):
            raise CollectionError("private Cuttlefish HOME is not a directory")
        instance_fd = os.dup(home_fd)
        for component in relative_instance.parts:
            child_fd = os.open(component, flags, dir_fd=instance_fd)
            os.close(instance_fd)
            instance_fd = child_fd
        if not stat.S_ISDIR(os.fstat(instance_fd).st_mode):
            raise CollectionError("selected Cuttlefish instance is not a directory")
        selected_fd = instance_fd
        instance_fd = -1
        return selected_fd
    except OSError as error:
        raise CollectionError(
            "selected instance could not be safely opened beneath the private HOME"
        ) from error
    finally:
        os.close(home_fd)
        if instance_fd >= 0:
            os.close(instance_fd)


def collect_specs(trusted_home: Path, instance_runtime: Path) -> dict[str, str]:
    try:
        root_fd = _open_selected_instance(trusted_home, instance_runtime)
    except CollectionError:
        raise
    except OSError as error:
        raise CollectionError("selected Cuttlefish instance runtime is unavailable") from error
    try:
        root_metadata = os.fstat(root_fd)
    except OSError as error:
        os.close(root_fd)
        raise CollectionError("selected Cuttlefish instance runtime is unavailable") from error
    if not stat.S_ISDIR(root_metadata.st_mode):
        os.close(root_fd)
        raise CollectionError("selected Cuttlefish instance runtime is not a directory")

    # Keep the scandir descriptor open while DirEntry.stat may still use it.
    frames: list[tuple[int, int, str, os.ScandirIterator[str]]] = []
    files: dict[str, str] = {}
    total_bytes = 0
    inventory_entries = 0
    directory_count = 1
    try:
        scan_fd, entries = _scandir(root_fd)
        frames.append((root_fd, scan_fd, "", entries))
        root_fd = -1
        while frames:
            directory_fd, scan_fd, relative_directory, entries = frames[-1]
            try:
                entry = next(entries)
            except StopIteration:
                entries.close()
                os.close(scan_fd)
                os.close(directory_fd)
                frames.pop()
                continue
            except OSError as error:
                raise CollectionError(
                    "selected Cuttlefish instance runtime could not be inventoried"
                ) from error

            inventory_entries += 1
            if inventory_entries > MAX_INVENTORY_ENTRIES:
                raise CollectionError(
                    "selected Cuttlefish instance runtime exceeds the entry limit"
                )
            name = entry.name
            relative_name = f"{relative_directory}/{name}" if relative_directory else name
            is_config = name.endswith(SPEC_SUFFIX)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise CollectionError(
                    "selected Cuttlefish instance runtime changed during inventory"
                ) from error

            if stat.S_ISLNK(metadata.st_mode):
                if is_config:
                    raise CollectionError("composite-disk config path is a symlink")
                continue

            if stat.S_ISDIR(metadata.st_mode):
                if is_config:
                    raise CollectionError("composite-disk config path is not a regular file")
                directory_count += 1
                if directory_count > MAX_DIRECTORIES:
                    raise CollectionError(
                        "selected Cuttlefish instance runtime exceeds the directory limit"
                    )
                if len(frames) - 1 >= MAX_DIRECTORY_DEPTH:
                    raise CollectionError(
                        "selected Cuttlefish instance runtime exceeds the depth limit"
                    )
                child_fd = -1
                try:
                    child_fd = os.open(name, _directory_flags(), dir_fd=directory_fd)
                    if not stat.S_ISDIR(os.fstat(child_fd).st_mode):
                        raise CollectionError(
                            "selected Cuttlefish instance runtime changed during inventory"
                        )
                    child_scan_fd, child_entries = _scandir(child_fd)
                except (CollectionError, OSError) as error:
                    if child_fd >= 0:
                        os.close(child_fd)
                    if isinstance(error, CollectionError):
                        raise
                    raise CollectionError(
                        "selected Cuttlefish instance runtime changed during inventory"
                    ) from error
                frames.append((child_fd, child_scan_fd, relative_name, child_entries))
                continue

            if not is_config:
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise CollectionError("composite-disk config is not a regular file")
            if len(files) >= MAX_SPEC_FILES:
                raise CollectionError(
                    "selected Cuttlefish instance runtime exceeds the config limit"
                )
            try:
                relative_name.encode("utf-8")
            except UnicodeEncodeError as error:
                raise CollectionError("composite-disk config path is not valid UTF-8") from error

            contents = _read_regular_file(directory_fd, name)
            total_bytes += len(contents)
            if total_bytes > MAX_TOTAL_BYTES:
                raise CollectionError("composite-disk configs exceed the total size limit")
            if not contents.strip():
                raise CollectionError("composite-disk config is empty")
            try:
                files[relative_name] = contents.decode("utf-8")
            except UnicodeDecodeError as error:
                raise CollectionError("composite-disk config is not valid UTF-8") from error
    except OSError as error:
        raise CollectionError(
            "selected Cuttlefish instance runtime could not be inventoried"
        ) from error
    finally:
        if root_fd >= 0:
            os.close(root_fd)
        for directory_fd, scan_fd, _, entries in reversed(frames):
            entries.close()
            os.close(scan_fd)
            os.close(directory_fd)

    if not files:
        raise CollectionError("no composite-disk config files found in selected instance runtime")
    return files


def write_capture(trusted_home: Path, instance_runtime: Path, destination: Path) -> None:
    files = collect_specs(trusted_home, instance_runtime)
    payload = json.dumps({"files": files}, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        dir=destination.parent,
    )
    temporary = Path(temporary_name)
    try:
        stream = os.fdopen(descriptor, "w", encoding="utf-8", newline="\n")
        descriptor = -1
        with stream:
            stream.write(payload)
        os.replace(temporary, destination)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: collect_composite_specs.py PRIVATE_HOME INSTANCE_RUNTIME OUTPUT_JSON",
            file=sys.stderr,
        )
        return 2
    try:
        write_capture(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
    except (CollectionError, OSError) as error:
        print(f"cannot collect composite-disk configs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
