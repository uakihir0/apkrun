#!/usr/bin/env python3
"""Run Cuttlefish startup while retaining its live host logs."""

from __future__ import annotations

import argparse
import os
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path

LOG_NAMES = {"assemble_cvd.log", "kernel.log", "launcher.log"}
MAX_LOG_BYTES = 64 * 1024 * 1024
MAX_LOG_LISTING_BYTES = 1024 * 1024
LOG_POLL_SECONDS = 0.5
LOG_COMMAND_TIMEOUT_SECONDS = 0.5
CHILD_STOP_GRACE_SECONDS = 1.0
LOG_COMMAND_STOP_GRACE_SECONDS = 0.05
requested_signal: int | None = None


def parse_log_listing(listing: str) -> dict[str, Path]:
    """Return only the selected Cuttlefish log paths from `cvd logs` output."""
    paths: dict[str, Path] = {}
    for line in listing.splitlines():
        label, separator, filename = line.partition(" ")
        if not separator:
            continue
        name = Path(label).name
        path = Path(filename)
        if name in LOG_NAMES and path.is_absolute():
            paths[name] = path
    return paths


def snapshot_log(source: Path, destination: Path, home: Path) -> tuple[int, int] | None:
    """Atomically copy a bounded regular log file located under the private HOME."""
    try:
        if source.is_symlink() or not source.resolve(strict=True).is_relative_to(home):
            return None
        descriptor = os.open(
            source,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
        )
    except (OSError, ValueError):
        return None

    temporary_path: Path | None = None
    try:
        source_stat = os.fstat(descriptor)
        if not stat.S_ISREG(source_stat.st_mode):
            return None
        complete = True
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=destination.parent,
                prefix=f".{destination.name}.",
                delete=False,
            ) as output:
                temporary_path = Path(output.name)
                truncated = source_stat.st_size > MAX_LOG_BYTES
                marker = (
                    b"[APKRun snapshot truncated; showing the final part of the host log.]\n"
                    if truncated
                    else b""
                )
                copy_limit = max(0, MAX_LOG_BYTES - len(marker)) if truncated else MAX_LOG_BYTES
                start = max(0, source_stat.st_size - copy_limit)
                if marker:
                    output.write(marker[:MAX_LOG_BYTES])
                stream.seek(start)
                remaining = min(source_stat.st_size, copy_limit)
                while remaining:
                    chunk = stream.read(min(1024 * 1024, remaining))
                    if not chunk:
                        complete = False
                        break
                    output.write(chunk)
                    remaining -= len(chunk)
        if not complete:
            return None
        os.replace(temporary_path, destination)
        return source_stat.st_size, source_stat.st_mtime_ns
    except (OSError, ValueError):
        return None
    finally:
        os.close(descriptor)
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _snapshot_listed_log(
    line: str,
    home: Path,
    destination: Path,
    observed: dict[tuple[str, str], tuple[int, int]],
    pending_observed: dict[tuple[str, str], tuple[int, int]],
    pending_attempted: set[str],
) -> None:
    label, separator, filename = line.partition(" ")
    if not separator or "\x00" in filename:
        return
    name = Path(label).name
    source = Path(filename)
    if name not in LOG_NAMES or not source.is_absolute() or name in pending_attempted:
        return
    try:
        if source.is_symlink() or not source.resolve(strict=True).is_relative_to(home):
            return
        source_stat = source.stat(follow_symlinks=False)
        if not stat.S_ISREG(source_stat.st_mode):
            return
        marker = source_stat.st_size, source_stat.st_mtime_ns
    except (OSError, ValueError):
        return
    pending_attempted.add(name)
    key = name, str(source)
    if observed.get(key) == marker:
        return
    copied_marker = snapshot_log(source, destination / name, home)
    if copied_marker is not None:
        pending_observed[key] = copied_marker


def _terminate_log_command(process: subprocess.Popen[bytes]) -> None:
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        process.terminate()
    time.sleep(LOG_COMMAND_STOP_GRACE_SECONDS)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        if process.poll() is None:
            process.kill()
    process.wait()


def collect_logs(
    cvd: str,
    home: Path,
    snapshot_directory: Path,
    observed: dict[tuple[str, str], tuple[int, int]],
    timeout_seconds: float = LOG_COMMAND_TIMEOUT_SECONDS,
) -> None:
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    try:
        poll_directory = Path(tempfile.mkdtemp(prefix=".poll-", dir=snapshot_directory))
    except OSError:
        return

    process: subprocess.Popen[bytes] | None = None
    selector: selectors.BaseSelector | None = None
    pending_observed: dict[tuple[str, str], tuple[int, int]] = {}
    pending_attempted: set[str] = set()
    completed = False
    listing_valid = True
    stream_open = True
    pending = bytearray()
    listing_size = 0
    deadline = time.monotonic() + timeout_seconds
    status_path = poll_directory / ".listing-status"

    try:
        command = shlex.join([cvd, "logs", "--nopretty"])
        supervisor_script = (
            f"{command}\n"
            "listing_status=$?\n"
            f"printf '%s\\n' \"$listing_status\" > {shlex.quote(str(status_path))}\n"
            "exec 1>&-\n"
            "while :; do sleep 1; done\n"
        )
        process = subprocess.Popen(
            ["/bin/sh", "-c", supervisor_script],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        while True:
            if not stream_open:
                try:
                    listing_status = int(status_path.read_text(encoding="ascii").strip())
                except (OSError, UnicodeDecodeError, ValueError):
                    listing_valid = False
                else:
                    completed = listing_status == 0 and listing_valid
                break

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if not selector.select(remaining):
                continue

            chunk = os.read(process.stdout.fileno(), 64 * 1024)
            if not chunk:
                selector.unregister(process.stdout)
                stream_open = False
                if pending and listing_valid:
                    try:
                        line = pending.decode("utf-8").rstrip("\r")
                    except UnicodeDecodeError:
                        listing_valid = False
                    else:
                        _snapshot_listed_log(
                            line,
                            home,
                            poll_directory,
                            observed,
                            pending_observed,
                            pending_attempted,
                        )
                continue

            listing_size += len(chunk)
            if listing_size > MAX_LOG_LISTING_BYTES:
                listing_valid = False
                break
            pending.extend(chunk)
            while listing_valid:
                newline = pending.find(b"\n")
                if newline < 0:
                    break
                raw_line = bytes(pending[:newline])
                del pending[: newline + 1]
                try:
                    line = raw_line.decode("utf-8").rstrip("\r")
                except UnicodeDecodeError:
                    listing_valid = False
                    break
                _snapshot_listed_log(
                    line,
                    home,
                    poll_directory,
                    observed,
                    pending_observed,
                    pending_attempted,
                )
    except (OSError, ValueError):
        listing_valid = False
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            _terminate_log_command(process)
            if process.stdout is not None:
                process.stdout.close()
            if process.poll() is None:
                process.wait()

        for name in LOG_NAMES:
            snapshot = poll_directory / name
            if not snapshot.is_file() or snapshot.is_symlink():
                continue
            try:
                os.replace(snapshot, snapshot_directory / name)
            except OSError:
                continue
            if completed:
                observed.update(
                    {key: marker for key, marker in pending_observed.items() if key[0] == name}
                )
        shutil.rmtree(poll_directory, ignore_errors=True)


def promote_snapshots(snapshot_directory: Path, destination: Path) -> None:
    for name in LOG_NAMES:
        snapshot = snapshot_directory / name
        if snapshot.is_file() and not snapshot.is_symlink():
            os.replace(snapshot, destination / name)
    shutil.rmtree(snapshot_directory, ignore_errors=True)


def _handle_signal(number: int, _frame: object) -> None:
    global requested_signal
    requested_signal = number


def _group_has_live_members(group_id: int) -> bool:
    """Check whether a process group still has a non-zombie member."""
    result = subprocess.run(
        ["ps", "-Ao", "pgid=,stat="],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise OSError("could not inspect the Cuttlefish process group after SIGKILL was denied")
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) == group_id:
            if not fields[1].lstrip().startswith("Z"):
                return True
    return False


def _terminate_child(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    time.sleep(CHILD_STOP_GRACE_SECONDS)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except PermissionError:
        if _group_has_live_members(process.pid):
            raise
    except ProcessLookupError:
        pass
    process.wait()


def run(args: argparse.Namespace) -> int:
    home = Path(args.home).resolve(strict=True)
    destination = Path(args.stage).resolve(strict=True)
    if args.snapshot_source is not None:
        if args.snapshot_name not in LOG_NAMES:
            raise ValueError("a selected Cuttlefish log name is required for snapshot mode")
        marker = snapshot_log(
            Path(args.snapshot_source),
            destination / args.snapshot_name,
            home,
        )
        return 0 if marker is not None else 1

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("a Cuttlefish start command is required after --")

    snapshot_directory = destination / ".live-cvd-logs"
    snapshot_directory.mkdir(mode=0o700)
    cvd = shutil.which("cvd")
    if cvd is None:
        raise FileNotFoundError("cvd was not found on PATH")

    environment = os.environ.copy()
    environment["HOME"] = str(home)
    observed: dict[tuple[str, str], tuple[int, int]] = {}
    deadline = time.monotonic() + args.timeout_seconds
    next_poll = 0.0
    process: subprocess.Popen[bytes] | None = None
    timed_out = False
    terminated = False
    termination_started = False

    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, _handle_signal)

    try:
        process = subprocess.Popen(command, env=environment, start_new_session=True)
        while process.poll() is None:
            now = time.monotonic()
            if requested_signal is not None:
                termination_started = True
                try:
                    collect_logs(cvd, home, snapshot_directory, observed, timeout_seconds=0.2)
                finally:
                    _terminate_child(process)
                terminated = True
                break
            if now >= deadline:
                timed_out = True
                termination_started = True
                try:
                    collect_logs(cvd, home, snapshot_directory, observed, timeout_seconds=0.2)
                finally:
                    _terminate_child(process)
                terminated = True
                break
            if now >= next_poll:
                poll_started = now
                collect_logs(cvd, home, snapshot_directory, observed)
                next_poll = poll_started + LOG_POLL_SECONDS
            wait_until = min(deadline, next_poll)
            wait_seconds = wait_until - time.monotonic()
            if wait_seconds > 0:
                try:
                    process.wait(timeout=min(0.25, wait_seconds))
                except subprocess.TimeoutExpired:
                    pass
        if not terminated:
            collect_logs(cvd, home, snapshot_directory, observed)
        return_code = process.returncode
        if return_code is None:
            return_code = process.wait()
    except BaseException:
        try:
            if process is not None and process.returncode is None and not termination_started:
                termination_started = True
                try:
                    collect_logs(cvd, home, snapshot_directory, observed, timeout_seconds=0.2)
                finally:
                    _terminate_child(process)
        finally:
            promote_snapshots(snapshot_directory, destination)
        raise

    promote_snapshots(snapshot_directory, destination)
    if requested_signal is not None:
        return 128 + requested_signal
    if timed_out:
        return 124
    if return_code in {124, 137}:
        # Reserve timeout(1)'s conventional statuses for this helper's own deadline.
        return 1
    return return_code


def parse_args(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--timeout-seconds", type=float)
    parser.add_argument("--snapshot-source")
    parser.add_argument("--snapshot-name", choices=sorted(LOG_NAMES))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(arguments)
    if args.snapshot_source is not None:
        if args.snapshot_name is None or args.timeout_seconds is not None or args.command:
            parser.error(
                "snapshot mode needs --snapshot-name and cannot include a timeout or command"
            )
        return args
    if args.snapshot_name is not None:
        parser.error("--snapshot-name requires --snapshot-source")
    if args.timeout_seconds is None:
        parser.error("run mode requires --timeout-seconds")
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    return args


def main() -> int:
    try:
        return run(parse_args())
    except (FileNotFoundError, OSError, ValueError) as error:
        print(f"capture_cvd_start: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
