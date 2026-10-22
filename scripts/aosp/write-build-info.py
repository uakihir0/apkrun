#!/usr/bin/env python3
"""Write verified metadata for one APKRun AOSP product archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

COMMIT_SHA = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
BUILD_NUMBER = re.compile(r"ar[0-9]{6}\Z")
IMAGE_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
BRANCH = "aosp-android-latest-release"


class BuildInfoError(ValueError):
    """A supplied value or input file cannot describe a valid AOSP build."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _guest_version_code(metadata_path: Path) -> int:
    try:
        metadata_stat = metadata_path.lstat()
        if not stat.S_ISREG(metadata_stat.st_mode):
            raise BuildInfoError("Guest Agent metadata must be a regular file, not a symlink")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except BuildInfoError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BuildInfoError(f"could not read Guest Agent metadata {metadata_path}: {error}") from error
    if not isinstance(metadata, dict) or metadata.get("packageName") != "io.apkrun.guest":
        raise BuildInfoError("Guest Agent metadata packageName must be io.apkrun.guest")
    version_code = metadata.get("versionCode")
    if (
        isinstance(version_code, bool)
        or not isinstance(version_code, int)
        or not 1 <= version_code <= 9_223_372_036_854_775_807
    ):
        raise BuildInfoError("Guest Agent metadata versionCode must be a positive signed 64-bit integer")
    return version_code


def write_build_info(
    *,
    archive: Path,
    guest_metadata: Path,
    output: Path,
    revision: str,
    variant: str,
    build_number: str,
    pinned_manifest_sha256: str,
    builder_image_digest: str,
    guest_apk_sha256: str,
) -> None:
    """Record input identity and a hash of the exact copied archive."""
    if not COMMIT_SHA.fullmatch(revision):
        raise BuildInfoError("revision must be a full lowercase 40-character commit SHA")
    if variant not in {"userdebug", "user"}:
        raise BuildInfoError("variant must be userdebug or user")
    if not BUILD_NUMBER.fullmatch(build_number):
        raise BuildInfoError("build number must match ar followed by six decimal digits")
    if not SHA256.fullmatch(pinned_manifest_sha256):
        raise BuildInfoError("pinned manifest SHA-256 must be 64 lowercase hex characters")
    if not IMAGE_DIGEST.fullmatch(builder_image_digest):
        raise BuildInfoError("builder image digest must be sha256: followed by 64 lowercase hex characters")
    if not SHA256.fullmatch(guest_apk_sha256):
        raise BuildInfoError("Guest Agent APK SHA-256 must be 64 lowercase hex characters")
    if archive.name != f"apkrun_arm64-img-{build_number}.zip":
        raise BuildInfoError("archive filename does not match the AOSP build number")
    try:
        archive_stat = archive.lstat()
    except OSError as error:
        raise BuildInfoError(f"could not inspect archive {archive}: {error}") from error
    if not stat.S_ISREG(archive_stat.st_mode) or archive_stat.st_size < 1:
        raise BuildInfoError("archive must be a non-empty regular file, not a symlink")
    if output.is_symlink():
        raise BuildInfoError(f"output must not be a symbolic link: {output}")
    guest_version_code = _guest_version_code(guest_metadata)

    document = {
        "schemaVersion": 1,
        "buildNumber": build_number,
        "revision": revision,
        "variant": variant,
        "branch": BRANCH,
        "target": f"apkrun_arm64-trunk_staging-{variant}",
        "pinnedManifestSha256": pinned_manifest_sha256,
        "builderImageDigest": builder_image_digest,
        "apkSha256": {"guest": guest_apk_sha256},
        "agents": {"guest": {"versionCode": guest_version_code}},
        "archive": {
            "name": archive.name,
            "size": archive_stat.st_size,
            "sha256": _sha256(archive),
        },
    }

    temporary: Path | None = None
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            suffix=".partial",
            delete=False,
        ) as destination:
            temporary = Path(destination.name)
            json.dump(document, destination, indent=2, sort_keys=True)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
    except OSError as error:
        raise BuildInfoError(f"could not safely write build metadata {output}: {error}") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--guest-metadata", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--pinned-manifest-sha256", required=True)
    parser.add_argument("--builder-image-digest", required=True)
    parser.add_argument("--guest-apk-sha256", required=True)
    arguments = parser.parse_args()
    try:
        write_build_info(
            archive=arguments.archive,
            guest_metadata=arguments.guest_metadata,
            output=arguments.out,
            revision=arguments.revision,
            variant=arguments.variant,
            build_number=arguments.build_number,
            pinned_manifest_sha256=arguments.pinned_manifest_sha256,
            builder_image_digest=arguments.builder_image_digest,
            guest_apk_sha256=arguments.guest_apk_sha256,
        )
    except (BuildInfoError, OSError) as error:
        print(f"write-build-info: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
