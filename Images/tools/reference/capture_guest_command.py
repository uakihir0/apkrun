#!/usr/bin/env python3
"""Run one guest ADB command with a deadline and a bounded output file."""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from capture_cvd_start import (
    child_exit_observed_without_reaping,
    terminate_process_group,
)

READ_CHUNK_BYTES = 64 * 1024
EMPTY_SELECTOR_POLL_SECONDS = 0.05
TERMINATE_GRACE_SECONDS = 0.5
_received_signal: int | None = None


class OutputLimitExceeded(Exception):
    """The command produced more output than the configured limit."""


class CommandInterrupted(Exception):
    """The helper received a termination signal."""


def _record_signal(signum: int, _frame: object) -> None:
    global _received_signal
    _received_signal = signum


def _run(command: list[str], output: Path, timeout_seconds: float, max_bytes: int) -> int:
    if not command:
        raise ValueError("a command is required after --")
    if timeout_seconds <= 0 or max_bytes <= 0:
        raise ValueError("timeout and output limit must be positive")
    if os.path.lexists(output):
        raise ValueError("output path already exists")

    temporary_path: Path | None = None
    process: subprocess.Popen[bytes] | None = None
    selector: selectors.BaseSelector | None = None
    total_bytes = 0
    deadline = time.monotonic() + timeout_seconds
    environment = os.environ.copy()

    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as stream:
            temporary_path = Path(stream.name)
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                env=environment,
                start_new_session=True,
            )
            assert process.stdout is not None
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)

            while True:
                if _received_signal is not None:
                    raise CommandInterrupted
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return 124
                events = selector.select(min(remaining, 0.1))
                for key, _ in events:
                    remaining_bytes = max_bytes - total_bytes
                    chunk = os.read(
                        key.fd,
                        min(READ_CHUNK_BYTES, remaining_bytes + 1),
                    )
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if len(chunk) > remaining_bytes:
                        raise OutputLimitExceeded
                    stream.write(chunk)
                    total_bytes += len(chunk)

                if not selector.get_map():
                    if not child_exit_observed_without_reaping(process):
                        time.sleep(min(EMPTY_SELECTOR_POLL_SECONDS, remaining))
                        continue
                    terminate_process_group(
                        process,
                        term_grace_seconds=TERMINATE_GRACE_SECONDS,
                    )
                    if process.returncode != 0:
                        return 1
                    stream.flush()
                    os.fsync(stream.fileno())
                    os.replace(temporary_path, output)
                    temporary_path = None
                    return 0
        return 1
    except OutputLimitExceeded:
        return 125
    except CommandInterrupted:
        return 128 + (_received_signal or signal.SIGTERM)
    except OSError as error:
        print(f"could not capture guest command: {error}", file=sys.stderr)
        return 1
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            try:
                if process is not None and process.returncode is None:
                    terminate_process_group(
                        process,
                        term_grace_seconds=TERMINATE_GRACE_SECONDS,
                    )
            finally:
                try:
                    if process is not None and process.stdout is not None:
                        process.stdout.close()
                finally:
                    if temporary_path is not None:
                        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--max-bytes", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command

    signal.signal(signal.SIGINT, _record_signal)
    signal.signal(signal.SIGTERM, _record_signal)
    signal.signal(signal.SIGHUP, _record_signal)
    try:
        status = _run(command, args.output, args.timeout_seconds, args.max_bytes)
    except (OSError, RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2

    if status == 124:
        print("guest command exceeded its deadline", file=sys.stderr)
    elif status == 125:
        print(f"guest command output exceeded {args.max_bytes} bytes", file=sys.stderr)
    elif status >= 128:
        print("guest command was interrupted", file=sys.stderr)
    print(0 if status else _output_size(args.output))
    return status


def _output_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
