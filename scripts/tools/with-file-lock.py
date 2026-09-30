#!/usr/bin/env python3
"""Exec a command while holding an exclusive lock on a file."""

import fcntl
import os
import sys


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: with-file-lock.py <lock-file> <command> [args...]")

    lock_path, command, *arguments = sys.argv[1:]
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    os.fchmod(descriptor, 0o600)
    os.set_inheritable(descriptor, True)
    fcntl.flock(descriptor, fcntl.LOCK_EX)

    environment = os.environ.copy()
    environment["APKRUN_TEST_LINUX_LOCK_HELD"] = "1"
    os.execvpe(command, [command, *arguments], environment)


if __name__ == "__main__":
    main()
