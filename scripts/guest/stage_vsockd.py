#!/usr/bin/env python3
"""Atomically stage the built apkrun_vsockd binary into the product prebuilt directory."""

import hashlib
import os
import pathlib
import stat
import sys


def fail(message):
    print(f"stage-vsockd: {message}", file=sys.stderr)
    return 1


def lstat_or_none(path, *, dir_fd=None):
    try:
        if dir_fd is None:
            return os.lstat(path)
        return os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_directory(path):
    metadata = lstat_or_none(path)
    if metadata is None or not stat.S_ISDIR(metadata.st_mode):
        raise OSError(f"expected a real directory: {path}")


def verify_product_directory(root):
    require_directory(root / "Guest")
    require_directory(root / "Guest" / "product")

    prebuilt = root / "Guest" / "product" / "prebuilt"
    metadata = lstat_or_none(prebuilt)
    if metadata is None:
        try:
            os.mkdir(prebuilt, 0o755)
        except FileExistsError:
            pass
        metadata = lstat_or_none(prebuilt)
    if metadata is None or not stat.S_ISDIR(metadata.st_mode):
        raise OSError(f"Guest/product/prebuilt must be a real directory: {prebuilt}")
    return prebuilt


def open_regular_source(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise OSError(f"source is not a regular file: {path}")
    return descriptor


def create_temporary(directory_fd):
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    for _ in range(16):
        name = f".apkrun_vsockd.{os.urandom(12).hex()}.tmp"
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            continue
        metadata = os.fstat(descriptor)
        return name, descriptor, (metadata.st_dev, metadata.st_ino)
    raise OSError("could not create an exclusive staging file")


def copy_and_hash(source_fd, destination_fd):
    source_hash = hashlib.sha256()
    while True:
        data = os.read(source_fd, 1024 * 1024)
        if not data:
            break
        source_hash.update(data)
        view = memoryview(data)
        while view:
            written = os.write(destination_fd, view)
            if written <= 0:
                raise OSError("short write while staging apkrun_vsockd")
            view = view[written:]

    os.lseek(destination_fd, 0, os.SEEK_SET)
    staged_hash = hashlib.sha256()
    while True:
        data = os.read(destination_fd, 1024 * 1024)
        if not data:
            break
        staged_hash.update(data)
    if source_hash.digest() != staged_hash.digest():
        raise OSError("staged binary checksum differs from the build output")


def stage(root, source):
    root_path = pathlib.Path(root)
    if root_path.is_symlink():
        raise OSError(f"repository root is symlinked: {root_path}")
    root_path = root_path.resolve(strict=True)
    prebuilt = verify_product_directory(root_path)
    destination_name = "apkrun_vsockd"

    source_path = pathlib.Path(source)
    if source_path.is_symlink():
        raise OSError(f"source is symlinked: {source_path}")
    source_fd = open_regular_source(source_path)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = None
    temporary_name = None
    temporary_identity = None
    temporary_fd = None
    try:
        directory_fd = os.open(prebuilt, directory_flags)
        destination_metadata = lstat_or_none(destination_name, dir_fd=directory_fd)
        if destination_metadata is not None and not stat.S_ISREG(destination_metadata.st_mode):
            raise OSError(f"refusing to replace a non-regular destination: {prebuilt / destination_name}")

        temporary_name, temporary_fd, temporary_identity = create_temporary(directory_fd)
        copy_and_hash(source_fd, temporary_fd)
        os.fchmod(temporary_fd, 0o755)
        os.fsync(temporary_fd)
        os.close(temporary_fd)
        temporary_fd = None

        staged_metadata = lstat_or_none(temporary_name, dir_fd=directory_fd)
        if staged_metadata is None or (staged_metadata.st_dev, staged_metadata.st_ino) != temporary_identity:
            raise OSError("staging path no longer refers to the file created by this invocation")
        if not stat.S_ISREG(staged_metadata.st_mode):
            raise OSError("staging path is no longer a regular file")

        # renameat replaces the destination entry itself, so a concurrent symlink swap is never followed.
        os.replace(
            temporary_name,
            destination_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        temporary_name = None
        os.fsync(directory_fd)

        final_metadata = lstat_or_none(destination_name, dir_fd=directory_fd)
        if final_metadata is None or not stat.S_ISREG(final_metadata.st_mode):
            raise OSError("staged destination is not a regular file")
        if stat.S_IMODE(final_metadata.st_mode) != 0o755:
            raise OSError("staged destination does not have mode 0755")
        return prebuilt / destination_name
    finally:
        os.close(source_fd)
        if temporary_fd is not None:
            os.close(temporary_fd)
        if directory_fd is not None and temporary_name is not None and temporary_identity is not None:
            temporary_metadata = lstat_or_none(temporary_name, dir_fd=directory_fd)
            if temporary_metadata is not None and (
                temporary_metadata.st_dev,
                temporary_metadata.st_ino,
            ) == temporary_identity:
                os.unlink(temporary_name, dir_fd=directory_fd)
        if directory_fd is not None:
            os.close(directory_fd)


def main(argv):
    if len(argv) != 3:
        print("usage: stage_vsockd.py REPOSITORY_ROOT BUILT_BINARY", file=sys.stderr)
        return 64
    try:
        destination = stage(argv[1], argv[2])
    except (OSError, ValueError) as error:
        return fail(str(error))
    print(f"stage-vsockd: wrote {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
