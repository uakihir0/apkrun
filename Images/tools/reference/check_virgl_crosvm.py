#!/usr/bin/env python3
"""Preflight and verify the crosvm ELF used by a target Virgl capture."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from elf_identity import identify

KNOWN_VIRGL_INCOMPATIBLE_BUILD_IDS = frozenset({"d724bf54f045b0ec7dbe14049b0fed9a16e52a23"})


def _public_identity(path: Path) -> dict[str, Any]:
    identity = identify(path)
    return {
        "status": identity.get("status"),
        "sha256": identity.get("sha256"),
        "elfBuildId": identity.get("elfBuildId"),
    }


def _identity_error(label: str, identity: dict[str, Any]) -> str | None:
    if identity.get("status") != "identified":
        return (
            f"Cannot verify the {label} for target drm_virgl "
            f"(ELF identity status: {identity.get('status', 'unknown')}). "
            "Use an executable with a GNU Build ID."
        )
    if not identity.get("sha256") or not identity.get("elfBuildId"):
        return f"Cannot verify the {label} for target drm_virgl (missing ELF identity)."
    return None


def _preflight(launch_command: Path, expected_executable: Path) -> int:
    launch_identity = _public_identity(launch_command)
    expected_identity = _public_identity(expected_executable)
    error = _identity_error("expected crosvm executable", expected_identity)
    if error is not None:
        print(error, file=sys.stderr)
        return 1

    for label, identity in (
        ("launch command", launch_identity),
        ("expected crosvm executable", expected_identity),
    ):
        build_id = identity.get("elfBuildId")
        if build_id in KNOWN_VIRGL_INCOMPATIBLE_BUILD_IDS:
            print(
                f"Refusing target drm_virgl: {label} Build ID "
                f"{build_id} is known to omit the rutabaga virgl_renderer feature "
                "in Cuttlefish 1.57.0. Use a crosvm build with that feature enabled, "
                "or select the source-configured guest_swiftshader fallback.",
                file=sys.stderr,
            )
            return 1

    print(
        "Virgl preflight warning: expected crosvm Build ID "
        f"{build_id} has no recorded Virgl certification. This capture will be "
        "diagnostic-only unless the build is reviewed and certified.",
        file=sys.stderr,
    )
    print(
        json.dumps(
            {
                "launchCommand": launch_identity,
                "expectedCrosvmExecutable": expected_identity,
                "virglSupport": "uncertified",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _verify(path: Path, expected_sha256: str, *, running: bool) -> int:
    identity = _public_identity(path)
    label = "running crosvm process" if running else "expected crosvm executable"
    error = _identity_error(label, identity)
    verified = error is None and identity.get("sha256") == expected_sha256
    result = {
        "status": "verified" if verified else "mismatch",
        "identity": identity,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    if verified:
        return 0
    if error is not None:
        print(error, file=sys.stderr)
    else:
        print(
            "crosvm executable identity changed after Virgl preflight or does not "
            "match the running process.",
            file=sys.stderr,
        )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--expected-executable", type=Path)
    mode.add_argument("--verify-executable", type=Path)
    mode.add_argument("--running-executable", type=Path)
    parser.add_argument("--launch-command", type=Path)
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()

    if args.expected_executable is not None:
        if args.launch_command is None or args.expected_sha256 is not None:
            parser.error("preflight needs --launch-command and does not accept --expected-sha256")
        return _preflight(args.launch_command, args.expected_executable)

    if args.launch_command is not None or args.expected_sha256 is None:
        parser.error("identity verification needs --expected-sha256 only")
    if len(args.expected_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in args.expected_sha256
    ):
        parser.error("--expected-sha256 must be a lowercase SHA-256 digest")
    if args.verify_executable is not None:
        return _verify(args.verify_executable, args.expected_sha256, running=False)
    return _verify(args.running_executable, args.expected_sha256, running=True)


if __name__ == "__main__":
    raise SystemExit(main())
