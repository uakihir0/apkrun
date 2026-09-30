#!/usr/bin/env python3
"""Resolve and validate the Linux guest test artifact directory."""

from __future__ import annotations

import os
import pwd
import stat
import sys
from pathlib import Path


def is_within(path: str, directory: str) -> bool:
    """Compare normalized absolute paths without touching the filesystem."""
    candidate = os.path.normpath(path).casefold()
    root = os.path.normpath(directory).casefold()
    return candidate == root or candidate.startswith(root.rstrip(os.sep) + os.sep)


def _reject_protected_path(path: Path, protected_directories: tuple[Path, ...]) -> None:
    """Reject a lexical path before statting a protected directory."""
    for protected_directory in protected_directories:
        if is_within(os.fspath(path), os.fspath(protected_directory)):
            raise ValueError(
                "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                "file-access approval prompts."
            )


def _resolve_without_entering_protected(
    directory: Path,
    protected_directories: tuple[Path, ...],
) -> Path:
    """Resolve aliases one component at a time without following into Documents."""
    directory = Path(os.path.normpath(os.fspath(directory)))
    pending = list(directory.parts[1:])
    resolved = Path(directory.anchor)
    followed_links = 0

    while pending:
        component = pending.pop(0)
        if component in {"", "."}:
            continue
        if component == "..":
            resolved = resolved.parent
            _reject_protected_path(resolved, protected_directories)
            continue

        candidate = resolved / component
        _reject_protected_path(candidate, protected_directories)
        try:
            item_stat = candidate.lstat()
        except FileNotFoundError:
            resolved = candidate
            for remaining in pending:
                if remaining in {"", "."}:
                    continue
                resolved = (
                    resolved.parent if remaining == ".." else resolved / remaining
                )
                _reject_protected_path(resolved, protected_directories)
            return Path(os.path.normpath(os.fspath(resolved)))
        except OSError as error:
            raise ValueError(
                "Could not resolve APKRUN_TEST_LINUX_DIR safely."
            ) from error

        if stat.S_ISLNK(item_stat.st_mode):
            followed_links += 1
            if followed_links > 40:
                raise ValueError("Could not resolve APKRUN_TEST_LINUX_DIR safely.")
            try:
                target = Path(os.readlink(candidate))
            except OSError as error:
                raise ValueError(
                    "Could not resolve APKRUN_TEST_LINUX_DIR safely."
                ) from error
            target_path = (
                os.fspath(target)
                if target.is_absolute()
                else os.path.join(os.fspath(resolved), os.fspath(target))
            )
            normalized_target = Path(os.path.normpath(target_path))
            resolved = Path(normalized_target.anchor)
            pending = list(normalized_target.parts[1:]) + pending
            continue

        resolved = candidate

    return Path(os.path.normpath(os.fspath(resolved)))


def validate_directory(value: str, *, home: Path | None = None) -> Path:
    """Require an absolute path outside both configured and account Documents."""
    directory = Path(value).expanduser()
    if not directory.is_absolute():
        raise ValueError("APKRUN_TEST_LINUX_DIR must be an absolute path.")

    if home is None:
        try:
            account_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        except (KeyError, OSError) as error:
            raise ValueError(
                "Could not determine the current account home directory."
            ) from error
        protected_homes = {account_home, Path.home()}
    else:
        protected_homes = {home}
    protected_directories: set[Path] = set()
    for protected_home in protected_homes:
        lexical_home = Path(os.path.abspath(os.fspath(protected_home)))
        protected_directories.add(lexical_home / "Documents")
        resolved_home = _resolve_without_entering_protected(lexical_home, ())
        protected_directories.add(resolved_home / "Documents")
    protected_roots = tuple(protected_directories)

    # Check the direct path first, then resolve external symlink aliases while
    # stopping before any filesystem lookup inside a protected directory.
    _reject_protected_path(directory, protected_roots)
    return _resolve_without_entering_protected(directory, protected_roots)


def main(arguments: list[str]) -> int:
    """Print the canonical directory or an actionable validation error."""
    if len(arguments) != 1:
        print("usage: validate-test-linux-dir.py <absolute-path>", file=sys.stderr)
        return 64
    try:
        directory = validate_directory(arguments[0])
    except ValueError as error:
        print(f"test-linux-artifacts: {error}", file=sys.stderr)
        return 64
    print(directory)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
