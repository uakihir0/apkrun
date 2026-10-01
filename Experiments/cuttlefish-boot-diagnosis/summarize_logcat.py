#!/usr/bin/env python3
"""Write a content-free summary of private, bounded Cuttlefish logcat samples."""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import stat
import tempfile
import zlib
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import BinaryIO

MAX_COMPRESSED_BYTES = 64 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
MAX_STATUS_BYTES = 64 * 1024
READ_CHUNK_BYTES = 64 * 1024

PATTERNS = {
    "systemServerLines": re.compile(
        rb"\b(?:SystemServer|system_server)\b", re.IGNORECASE
    ),
    "systemServerFatalLines": re.compile(
        rb"FATAL EXCEPTION IN SYSTEM PROCESS|Watchdog.*system_server", re.IGNORECASE
    ),
    "activityManagerLines": re.compile(rb"\bActivity(?:Task)?Manager\b", re.IGNORECASE),
    "activityServiceLookupFailures": re.compile(
        rb"Could not find ['\"]aidl/activity['\"]|activity.*could not be found",
        re.IGNORECASE,
    ),
    "surfaceFlingerLines": re.compile(rb"\bSurfaceFlinger\b", re.IGNORECASE),
    "graphicsFailureLines": re.compile(
        rb"\b(?:EGL|composer|virtio[_-]gpu)\b.*\b(?:error|fail(?:ed|ure)?|fatal)\b",
        re.IGNORECASE,
    ),
    "bootCompletedLines": re.compile(
        rb"\bBOOT_COMPLETED\b|sys\.boot_completed", re.IGNORECASE
    ),
}


@contextmanager
def _open_stream(path: Path) -> Iterator[BinaryIO]:
    if path.is_symlink():
        raise ValueError(f"logcat input must not be a symlink: {path.name}")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
        )
    except OSError as error:
        raise ValueError(f"cannot open logcat input: {path.name}") from error

    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"logcat input must be a regular file: {path.name}")
        if info.st_size > MAX_COMPRESSED_BYTES:
            raise ValueError(
                f"compressed logcat input exceeds the size limit: {path.name}"
            )
        raw = os.fdopen(descriptor, "rb", closefd=True)
        descriptor = -1
        stream: BinaryIO
        if path.suffix == ".gz":
            stream = gzip.GzipFile(fileobj=raw, mode="rb")
        else:
            stream = raw
        try:
            yield stream
        finally:
            stream.close()
            if stream is not raw:
                raw.close()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _capture_status(path: Path) -> dict[str, int | bool | None]:
    if path.is_symlink():
        raise ValueError(f"logcat status must not be a symlink: {path.name}")
    try:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_STATUS_BYTES:
            raise ValueError(
                f"logcat status has an invalid file type or size: {path.name}"
            )
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read logcat status: {path.name}") from error
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise ValueError(f"logcat status has an unsupported schema: {path.name}")
    bytes_written = document.get("bytesWritten")
    truncated = document.get("truncated")
    timed_out = document.get("timedOut")
    child_exit = document.get("childExitCode")
    signal_number = document.get("signal")
    cleanup_complete = document.get("cleanupComplete")
    if (
        type(bytes_written) is not int
        or bytes_written < 0
        or bytes_written > 1024 * 1024
        or not isinstance(truncated, bool)
        or not isinstance(timed_out, bool)
        or not isinstance(cleanup_complete, bool)
        or (child_exit is not None and type(child_exit) is not int)
        or (signal_number is not None and type(signal_number) is not int)
    ):
        raise ValueError(f"logcat status has invalid fields: {path.name}")
    return {
        "bytesWritten": bytes_written,
        "truncated": truncated,
        "timedOut": timed_out,
        "cleanupComplete": cleanup_complete,
        "childExitCode": child_exit,
        "signal": signal_number,
    }


def summarize(
    snapshot_directory: Path,
    capture_logcat: Path | None = None,
) -> dict[str, int | bool]:
    if snapshot_directory.is_symlink() or not snapshot_directory.is_dir():
        raise ValueError("logcat snapshot directory must be a real directory")
    inputs = sorted(snapshot_directory.glob("logcat-*.txt"))
    status_inputs = sorted(snapshot_directory.glob("logcat-*.json"))
    if capture_logcat is not None:
        if capture_logcat.is_symlink():
            raise ValueError("capture logcat input must not be a symlink")
        if capture_logcat.exists():
            inputs.append(capture_logcat)
    if len(inputs) > 100 or len(status_inputs) > 100:
        raise ValueError("too many logcat inputs")

    totals: dict[str, int | bool] = {
        "schemaVersion": 1,
        "snapshotCount": len(inputs)
        - int(capture_logcat is not None and capture_logcat in inputs),
        "captureLogcatPresent": bool(
            capture_logcat is not None and capture_logcat in inputs
        ),
        "liveLogcatSampleCount": len(status_inputs),
        "liveLogcatBytes": 0,
        "liveLogcatTruncatedSampleCount": 0,
        "liveLogcatTimedOutSampleCount": 0,
        "liveLogcatCleanupIncompleteSampleCount": 0,
        "liveLogcatFailedSampleCount": 0,
        "lineCount": 0,
        "uncompressedBytes": 0,
        **{name: 0 for name in PATTERNS},
    }
    for path in status_inputs:
        if not re.fullmatch(r"logcat-[0-9]{3}\.json", path.name):
            raise ValueError(f"logcat status has an unsafe name: {path.name}")
        status = _capture_status(path)
        totals["liveLogcatBytes"] += int(status["bytesWritten"])
        totals["liveLogcatTruncatedSampleCount"] += int(bool(status["truncated"]))
        totals["liveLogcatTimedOutSampleCount"] += int(bool(status["timedOut"]))
        totals["liveLogcatCleanupIncompleteSampleCount"] += int(
            not bool(status["cleanupComplete"])
        )
        child_exit = status["childExitCode"]
        failed = (
            bool(status["timedOut"])
            or not bool(status["cleanupComplete"])
            or status["signal"] is not None
            or (
                child_exit is not None
                and child_exit != 0
                and not bool(status["truncated"])
            )
        )
        totals["liveLogcatFailedSampleCount"] += int(failed)
    if totals["liveLogcatBytes"] > 40 * 1024 * 1024:
        raise ValueError("live logcat capture status exceeds its aggregate byte limit")
    for path in inputs:
        partial_line = bytearray()
        with _open_stream(path) as stream:
            while True:
                remaining = MAX_UNCOMPRESSED_BYTES - totals["uncompressedBytes"]
                chunk = stream.read(min(READ_CHUNK_BYTES, remaining + 1))
                if not chunk:
                    break
                totals["uncompressedBytes"] += len(chunk)
                if totals["uncompressedBytes"] > MAX_UNCOMPRESSED_BYTES:
                    raise ValueError(
                        "decompressed logcat input exceeds the aggregate size limit"
                    )
                start = 0
                while start < len(chunk):
                    end = chunk.find(b"\n", start)
                    if end < 0:
                        partial_line.extend(chunk[start:])
                        if len(partial_line) > MAX_LINE_BYTES:
                            raise ValueError(
                                "logcat line exceeds the per-line size limit"
                            )
                        break
                    partial_line.extend(chunk[start : end + 1])
                    if len(partial_line) > MAX_LINE_BYTES:
                        raise ValueError("logcat line exceeds the per-line size limit")
                    totals["lineCount"] += 1
                    for name, pattern in PATTERNS.items():
                        if pattern.search(partial_line):
                            totals[name] += 1
                    partial_line.clear()
                    start = end + 1
            if partial_line:
                totals["lineCount"] += 1
                for name, pattern in PATTERNS.items():
                    if pattern.search(partial_line):
                        totals[name] += 1
    return totals


def write_summary(summary: dict[str, int | bool], destination: Path) -> None:
    if destination.is_symlink():
        raise ValueError("summary destination must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            json.dump(summary, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshots", type=Path, required=True)
    parser.add_argument("--capture-logcat", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        summary = summarize(arguments.snapshots, arguments.capture_logcat)
        write_summary(summary, arguments.output)
    except (gzip.BadGzipFile, zlib.error):
        parser.exit(1, "summarize_logcat: invalid compressed logcat input\n")
    except (OSError, ValueError, EOFError) as error:
        parser.exit(1, f"summarize_logcat: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
