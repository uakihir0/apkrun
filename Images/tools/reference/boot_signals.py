#!/usr/bin/env python3
"""Summarize boot-signal strings and their guest-uptime timing in capture records.

The tool reads only the named capture directories and writes one JSON document
to stdout. The output holds record names, marker names, counts, and guest
uptimes. It never prints raw log lines, host paths, serial numbers, or
addresses. Results from incomplete diagnostic records are not reference
profiles.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import statistics
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MAX_FILE_BYTES = 64 * 1024 * 1024
KERNEL_LOG = "kernel.log"
HOST_LOGS = ("cvd-create-console.log", "launcher.log")
HOST_JSON = "host.json"
PROFILE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")

# Substring markers in kernel.log. "Starting kernel ..." is U-Boot output and
# carries no kernel timestamp; the others are printed by the Linux kernel or init.
KERNEL_MARKERS: dict[str, str] = {
    "uBootStartingKernel": "Starting kernel ...",
    "linuxBooting": "Booting Linux on physical CPU",
    "initFirstStage": "init: init first stage started!",
    "zygoteServiceStart": "init: starting service 'zygote'",
}
UPTIME_RE = re.compile(r"^\[\s*(\d+\.\d+)\]\[\s*T\d+\]")
FIELD_RE = re.compile(r"[a-z_]+=[A-Za-z0-9_.-]+")
# A host boot-state line ends with the bare token, for example
# "boot_state_machine.cc:211] VIRTUAL_DEVICE_BOOT_FAILED". Prose that merely
# mentions the token does not end the line and is not counted.
HOST_BOOT_TOKEN_RE = re.compile(r"(?:^|\s)(VIRTUAL_DEVICE_BOOT_(?:STARTED|COMPLETED|FAILED))\s*$")


def _read_regular(path: Path) -> bytes | None:
    """Return the bounded contents of a regular file, or None when it is absent."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ValueError(f"{path.name} cannot be opened without following links") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"{path.name} is not a regular file")
        if info.st_size > MAX_FILE_BYTES:
            raise ValueError(f"{path.name} exceeds {MAX_FILE_BYTES} bytes")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError(f"{path.name} exceeds {MAX_FILE_BYTES} bytes")
    return data


def _read_lines(record: Path, name: str) -> list[str] | None:
    data = _read_regular(record / name)
    if data is None:
        return None
    return data.decode("utf-8", errors="replace").splitlines()


def _host_profile(record: Path) -> dict[str, Any]:
    data = _read_regular(record / HOST_JSON)
    if data is None:
        return {"profile": None, "selectedGpuMode": None, "schemaVersion": None}
    try:
        document = json.loads(data)
    except json.JSONDecodeError as error:
        raise ValueError(f"{HOST_JSON} is not valid JSON") from error
    if not isinstance(document, dict):
        raise ValueError(f"{HOST_JSON} must contain a JSON object")

    def _label(key: str) -> str | None:
        value = document.get(key)
        if isinstance(value, str) and PROFILE_RE.fullmatch(value):
            return value
        return None

    schema = document.get("schemaVersion")
    return {
        "profile": _label("profile"),
        "selectedGpuMode": _label("selectedGpuMode"),
        "schemaVersion": schema if isinstance(schema, int) else None,
    }


def _kernel_summary(lines: list[str]) -> dict[str, Any]:
    markers: dict[str, dict[str, Any]] = {
        name: {"count": 0, "firstLine": None, "firstUptimeSeconds": None} for name in KERNEL_MARKERS
    }
    virtual: dict[str, dict[str, Any]] = {}
    last_uptime: float | None = None
    for index, line in enumerate(lines, start=1):
        prefix = UPTIME_RE.match(line)
        uptime = float(prefix.group(1)) if prefix else None
        if uptime is not None:
            last_uptime = uptime
        for name, needle in KERNEL_MARKERS.items():
            if needle not in line:
                continue
            entry = markers[name]
            entry["count"] += 1
            if entry["firstLine"] is None:
                entry["firstLine"] = index
                entry["firstUptimeSeconds"] = uptime
        if prefix is None:
            continue
        message = line[prefix.end() :].lstrip()
        if not message.startswith("VIRTUAL_DEVICE_"):
            continue
        words = message.split()
        token, fields = words[0], words[1:]
        if not re.fullmatch(r"VIRTUAL_DEVICE_[A-Z0-9_]+", token):
            continue
        if not all(FIELD_RE.fullmatch(field) for field in fields):
            continue
        entry = virtual.setdefault(token, {"count": 0, "firstUptimeSeconds": uptime, "shapes": {}})
        entry["count"] += 1
        shape = " ".join([token, *fields])
        entry["shapes"][shape] = entry["shapes"].get(shape, 0) + 1
    return {
        "lineCount": len(lines),
        "lastUptimeSeconds": last_uptime,
        "markers": markers,
        "virtualDevice": dict(sorted(virtual.items())),
    }


def _host_summary(record: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name in HOST_LOGS:
        lines = _read_lines(record, name)
        if lines is None:
            result[name] = None
            continue
        counts: dict[str, int] = {}
        for line in lines:
            match = HOST_BOOT_TOKEN_RE.search(line)
            if match:
                token = match.group(1)
                counts[token] = counts.get(token, 0) + 1
        result[name] = dict(sorted(counts.items()))
    return result


def summarize_record(record: Path) -> dict[str, Any]:
    """Summarize one capture directory without following links."""
    info = os.lstat(record)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"{record.name} is not a plain directory")
    host = _host_profile(record)
    kernel_lines = _read_lines(record, KERNEL_LOG)
    return {
        "record": record.name,
        **host,
        "kernelLog": None if kernel_lines is None else _kernel_summary(kernel_lines),
        "hostBootTokens": _host_summary(record),
    }


def _stats(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "medianSeconds": round(statistics.median(values), 3),
        "minSeconds": round(min(values), 3),
        "maxSeconds": round(max(values), 3),
    }


def _summarize_groups(records: list[dict[str, Any]]) -> dict[str, Any]:
    groups: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        key = f"{record['profile'] or 'unknown'}/{record['selectedGpuMode'] or 'unknown'}"
        groups.setdefault(key, []).append(record)
    summary: dict[str, Any] = {}
    for key, members in sorted(groups.items()):
        logged = [m["kernelLog"] for m in members if m["kernelLog"] is not None]
        entry: dict[str, Any] = {"records": len(members)}
        for name in KERNEL_MARKERS:
            if name == "uBootStartingKernel":
                # U-Boot output has no kernel timestamp, so it has no uptime to summarize.
                continue
            values = [
                k["markers"][name]["firstUptimeSeconds"]
                for k in logged
                if k["markers"][name]["firstUptimeSeconds"] is not None
            ]
            entry[name] = _stats(values)
        entry["virtualDeviceDisplayPowerFirstUptime"] = _stats(
            [
                k["virtualDevice"]["VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED"][
                    "firstUptimeSeconds"
                ]
                for k in logged
                if "VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED" in k["virtualDevice"]
            ]
        )
        summary[key] = entry
    return summary


def build_document(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Assemble the JSON document for a set of summarized records."""
    completed = 0
    failed = 0
    for record in records:
        kernel_completed = bool(
            record["kernelLog"]
            and "VIRTUAL_DEVICE_BOOT_COMPLETED" in record["kernelLog"]["virtualDevice"]
        )
        host = record["hostBootTokens"]
        host_completed = any(
            value and value.get("VIRTUAL_DEVICE_BOOT_COMPLETED") for value in host.values()
        )
        completed += int(kernel_completed or host_completed)
        failed += int(
            any(value and value.get("VIRTUAL_DEVICE_BOOT_FAILED") for value in host.values())
        )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "scope": "incomplete diagnostic capture records; not reference profiles",
        "recordCount": len(records),
        "recordsWithBootCompleted": completed,
        "recordsWithBootFailed": failed,
        "summaryByProfileAndSelectedGpuMode": _summarize_groups(records),
        "records": records,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("records", nargs="+", type=Path, help="capture record directories")
    args = parser.parse_args(argv)
    summaries: list[dict[str, Any]] = []
    for record in args.records:
        try:
            summaries.append(summarize_record(record))
        except (OSError, ValueError) as error:
            print(f"boot_signals: {record.name}: {error}", file=sys.stderr)
            return 1
    json.dump(build_document(summaries), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
