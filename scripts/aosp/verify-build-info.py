#!/usr/bin/env python3
"""Verify one APKRun AOSP archive against its build-info.json sidecar."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
from pathlib import Path
from typing import Any

SHA256 = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_SHA = re.compile(r"[0-9a-f]{40}\Z")
BUILD_NUMBER = re.compile(r"ar[0-9]{6}\Z")
IMAGE_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
BRANCH = "aosp-android-latest-release"
MAX_TEXT_SIZE = 1024 * 1024
MAX_ARCHIVE_SIZE = 16 * 1024 * 1024 * 1024


class BuildInfoError(ValueError):
    """The archive or sidecar does not match the requested build."""


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BuildInfoError(f"build-info.json contains duplicate key {key!r}")
        result[key] = value
    return result


def _require_keys(value: Any, expected: set[str], description: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise BuildInfoError(f"build-info.json {description} has missing or unknown fields")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_build_info(
    *,
    archive: Path,
    build_info: Path,
    revision: str,
    variant: str,
    build_number: str,
) -> dict[str, Any]:
    if not COMMIT_SHA.fullmatch(revision):
        raise BuildInfoError("revision must be a full lowercase 40-character commit SHA")
    if variant not in {"userdebug", "user"}:
        raise BuildInfoError("variant must be userdebug or user")
    if not BUILD_NUMBER.fullmatch(build_number):
        raise BuildInfoError("build number must match ar followed by six decimal digits")
    try:
        info_stat = build_info.lstat()
        if not stat.S_ISREG(info_stat.st_mode):
            raise BuildInfoError("build-info.json must be a regular file, not a symlink")
        if info_stat.st_size > MAX_TEXT_SIZE:
            raise BuildInfoError("build-info.json exceeds the 1 MiB size limit")
        info = json.loads(
            build_info.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except BuildInfoError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise BuildInfoError(f"could not read build-info.json {build_info}: {error}") from error
    info = _require_keys(
        info,
        {
            "schemaVersion",
            "buildNumber",
            "revision",
            "variant",
            "branch",
            "target",
            "pinnedManifestSha256",
            "builderImageDigest",
            "apkSha256",
            "agents",
            "archive",
        },
        "top level",
    )
    if isinstance(info.get("schemaVersion"), bool) or info.get("schemaVersion") != 1:
        raise BuildInfoError("build-info.json schemaVersion must be 1")
    expected = {
        "buildNumber": build_number,
        "revision": revision,
        "variant": variant,
        "branch": BRANCH,
        "target": f"apkrun_arm64-trunk_staging-{variant}",
    }
    for field, value in expected.items():
        if info.get(field) != value:
            raise BuildInfoError(f"build-info.json {field} does not match the requested build")
    if not SHA256.fullmatch(str(info.get("pinnedManifestSha256", ""))):
        raise BuildInfoError("build-info.json pinnedManifestSha256 is invalid")
    if not IMAGE_DIGEST.fullmatch(str(info.get("builderImageDigest", ""))):
        raise BuildInfoError("build-info.json builderImageDigest is invalid")

    apk_sha256 = _require_keys(info.get("apkSha256"), {"guest"}, "apkSha256")
    agents = _require_keys(info.get("agents"), {"guest"}, "agents")
    guest_agent = _require_keys(agents.get("guest"), {"versionCode"}, "agents.guest")
    if not SHA256.fullmatch(str(apk_sha256.get("guest", ""))):
        raise BuildInfoError("build-info.json must record a valid Guest Agent hash")
    version_code = guest_agent.get("versionCode")
    if (
        isinstance(version_code, bool)
        or not isinstance(version_code, int)
        or not 1 <= version_code <= 9_223_372_036_854_775_807
    ):
        raise BuildInfoError("build-info.json Guest Agent versionCode is invalid")

    archive_name = f"apkrun_arm64-img-{build_number}.zip"
    try:
        archive_stat = archive.lstat()
    except OSError as error:
        raise BuildInfoError(f"could not inspect archive {archive}: {error}") from error
    if not stat.S_ISREG(archive_stat.st_mode) or archive_stat.st_size < 1:
        raise BuildInfoError("archive must be a non-empty regular file, not a symlink")
    archive_info = _require_keys(
        info.get("archive"),
        {"name", "size", "sha256"},
        "archive",
    )
    if archive_info.get("name") != archive_name:
        raise BuildInfoError("build-info.json archive name does not match the AOSP build number")
    archive_size = archive_info.get("size")
    if (
        isinstance(archive_size, bool)
        or not isinstance(archive_size, int)
        or not 1 <= archive_size <= MAX_ARCHIVE_SIZE
        or archive_size != archive_stat.st_size
    ):
        raise BuildInfoError("archive size does not match build-info.json")
    expected_sha256 = archive_info.get("sha256")
    if not isinstance(expected_sha256, str) or not SHA256.fullmatch(expected_sha256):
        raise BuildInfoError("build-info.json archive SHA-256 is invalid")
    if _sha256(archive) != expected_sha256:
        raise BuildInfoError("archive SHA-256 does not match build-info.json")
    return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--build-info", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--build-number", required=True)
    arguments = parser.parse_args()
    try:
        verify_build_info(
            archive=arguments.archive,
            build_info=arguments.build_info,
            revision=arguments.revision,
            variant=arguments.variant,
            build_number=arguments.build_number,
        )
    except (BuildInfoError, OSError) as error:
        print(f"verify-build-info: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
