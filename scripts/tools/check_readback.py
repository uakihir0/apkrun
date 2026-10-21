#!/usr/bin/env python3
"""Fail when product code reads pixel data back on the host (graphics.md §7, AGENTS.md §6.4).

    python3 -I scripts/tools/check_readback.py --root REPOSITORY

The normal frame path has no host readback, so the `hostReadbacks` counter has nothing to count. This check keeps it
that way. It scans the product sources (`Packages/*/Sources/`, `Apps/`, `CLI/`, `Daemon/`) for calls that read pixels
or GPU resources into CPU memory. A call is allowed only

- inside an `#if` block whose condition names `APKRUN_TEST_READBACK` (the TestReadback trait), or
- where ALLOWED below permits it: the guest-requested `TRANSFER_FROM_HOST_3D` path, which `guestReadbacks` counts.

A new host-side read needs a design change first. If it is accepted, it increments `hostReadbacks` and gets an
ALLOWED entry with its reason.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h"}
READBACK_CALL = re.compile(
    r"\b(gb_transfer_read|transfer_read_iov|IOSurfaceLock|glReadPixels|CVPixelBufferLockBaseAddress)\s*\("
    # A method call on a value; a leading-dot enum case such as `.transferRead(transfer, …)` is not a call.
    r"|\b[A-Za-z_][A-Za-z0-9_]*[?!]?\.(transferRead|getBytes)\s*\("
)
TEST_FLAG = "APKRUN_TEST_READBACK"

# Calls allowed outside test-only blocks: path -> (number of calls, reason).
ALLOWED: dict[str, tuple[int, str]] = {
    "Packages/GraphicsCore/Sources/GraphicsBridge/GraphicsBridge.m": (
        2,
        "gb_transfer_read and its virglrenderer call: the read entry for guest TRANSFER_FROM_HOST_3D",
    ),
    "Packages/GraphicsCore/Sources/GraphicsBridge/include/GraphicsBridge.h": (1, "the gb_transfer_read declaration"),
    "Packages/GraphicsCore/Sources/GraphicsCore/Renderer/VirGLRenderer.swift": (
        1,
        "VirGLRenderer.transferRead, which only the guest TRANSFER_FROM_HOST_3D path calls",
    ),
    "Packages/GraphicsCore/Sources/GraphicsCore/Renderer/VirGLRecording.swift": (
        2,
        "the recording wrapper and the replay of a recorded guest TRANSFER_FROM_HOST_3D",
    ),
    "Packages/GraphicsCore/Sources/GraphicsCore/VirtioGPU/GuestGPUSession.swift": (
        1,
        "GuestGPUSession.readBack: TRANSFER_FROM_HOST_3D from the guest, counted in guestReadbacks",
    ),
}


def product_sources(root: Path) -> list[PurePosixPath]:
    output = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
    ).stdout
    result = []
    for item in output.split(b"\0"):
        if not item:
            continue
        path = PurePosixPath(item.decode())
        parts = path.parts
        if path.suffix not in SOURCE_SUFFIXES or "Tests" in parts or "UITests" in parts:
            continue
        in_package_sources = len(parts) > 2 and parts[0] == "Packages" and parts[2] == "Sources"
        if in_package_sources or parts[0] in {"Apps", "CLI", "Daemon"}:
            result.append(path)
    return result


def strip_comment(line: str, in_block: bool) -> tuple[str, bool]:
    """The code part of a line, and whether a /* */ comment is still open after it."""
    code = []
    index = 0
    while index < len(line):
        if in_block:
            end = line.find("*/", index)
            if end < 0:
                return "".join(code), True
            index = end + 2
            in_block = False
        elif line.startswith("//", index):
            break
        elif line.startswith("/*", index):
            in_block = True
            index += 2
        else:
            code.append(line[index])
            index += 1
    return "".join(code), in_block


def readback_calls(text: str) -> list[tuple[int, str]]:
    """The readback calls of a source file outside test-only #if blocks, as (line number, call)."""
    found: list[tuple[int, str]] = []
    # One frame per open #if: whether the active branch is test-only.
    frames: list[bool] = []
    in_block = False
    for number, raw in enumerate(text.splitlines(), 1):
        code, in_block = strip_comment(raw, in_block)
        directive = code.strip()
        if directive.startswith(("#if", "#ifdef", "#ifndef")):
            condition = directive.split(None, 1)[1] if " " in directive else ""
            negated = directive.startswith("#ifndef") or f"!{TEST_FLAG}" in condition.replace(" ", "")
            frames.append(TEST_FLAG in condition and not negated)
            continue
        if directive.startswith(("#elseif", "#elif", "#else")):
            if frames:
                frames[-1] = False
            continue
        if directive.startswith("#endif"):
            if frames:
                frames.pop()
            continue
        if any(frames):
            continue
        for match in READBACK_CALL.finditer(code):
            found.append((number, match.group(0).rstrip("( ")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    root = parser.parse_args().root.resolve()

    failures = []
    for path in product_sources(root):
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        calls = readback_calls(text)
        allowed, _reason = ALLOWED.get(path.as_posix(), (0, ""))
        if len(calls) > allowed:
            for number, call in calls:
                failures.append(f"{path}:{number}: host readback call `{call}` outside `#if {TEST_FLAG}`")
            failures.append(f"{path}: {len(calls)} readback call(s), {allowed} allowed (graphics.md §7)")
    for failure in failures:
        print(failure)
    if failures:
        print("check-readback: the normal frame path must not read pixels back on the host", file=sys.stderr)
        return 1
    print("check-readback: no host readback outside the test-only builds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
