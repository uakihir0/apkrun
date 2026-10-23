"""AVB helpers for composing the development image (#36)."""

from __future__ import annotations

import collections
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from apkrun_image.vendor_reseal import (
    VBMETA_ALGORITHM,
    VBMETA_PUBLIC_KEY_SHA1,
    _info,
    _raw_vbmeta_descriptors,
    parse_top,
    refresh_vbmeta_partition,
    vbmeta_release_string,
    verify_vbmeta_signature,
)

BLOCK_SIZE = 4096
PARTITION_NAME = "system_ext"
HASH_ALGORITHM = "blake2b-256"
FEC_ROOTS = 2


class ComposeAvbError(ValueError):
    """The source AVB metadata or a composed AVB artifact is invalid."""


def _avbtool(avbtool: Path, args: list[str], *, fec: Path | None = None) -> str:
    """Run the pinned avbtool, exposing only the selected FEC binary on PATH."""
    if avbtool.is_symlink() or not avbtool.is_file():
        raise ComposeAvbError(f"{avbtool}: the pinned avbtool is missing or symlinked.")
    environment = os.environ.copy()
    if fec is not None:
        if fec.is_symlink() or not fec.is_file() or not os.access(fec, os.X_OK):
            raise ComposeAvbError(f"{fec}: the pinned FEC tool is missing or not executable.")
        environment["PATH"] = str(fec.parent) + os.pathsep + environment.get("PATH", "")
    try:
        result = subprocess.run(
            [sys.executable, "-I", str(avbtool), *args],
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )
    except OSError as error:
        raise ComposeAvbError(f"could not run avbtool {args[0]}: {error}") from None
    if result.returncode:
        tail = result.stderr.strip().splitlines()[-2:]
        detail = " | ".join(tail) or f"exit {result.returncode}"
        raise ComposeAvbError(
            f"avbtool {args[0]} failed: {detail}. "
            "Build or verify the pinned FEC tool with scripts/build-fec-tool.sh."
        )
    return result.stdout


def _descriptor(avbtool: Path, image: Path, partition: str) -> dict[str, Any]:
    """Read a complete hashtree descriptor from a partition image."""
    try:
        from apkrun_image.vendor_reseal import _partition_tree

        return _partition_tree(_info(avbtool, image), partition, f"{image}")
    except (ValueError, OSError) as error:
        raise ComposeAvbError(f"{image}: cannot read its {partition} hashtree: {error}") from None


def _output_parent(output: Path, description: str) -> Path:
    """Refuse an occupied destination and require an existing non-symlink parent."""
    if output.exists() or output.is_symlink():
        raise ComposeAvbError(f"{output}: {description} must not already exist.")
    parent = output.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ComposeAvbError(f"{parent}: {description} parent must be an existing directory.")
    return parent


def _publish_new_file(staged: Path, output: Path) -> None:
    """Publish a verified file atomically without replacing a concurrent destination."""
    if staged.is_symlink() or not staged.is_file():
        raise ComposeAvbError(f"{staged}: the staged output is missing or symlinked.")
    try:
        os.link(staged, output)
    except FileExistsError:
        raise ComposeAvbError(f"{output}: the output appeared during composition.") from None
    except OSError as error:
        raise ComposeAvbError(f"{output}: could not publish the verified output: {error}") from None


def stock_system_ext_descriptor(avbtool: Path, image: Path) -> dict[str, Any]:
    """Validate the stock EROFS footer and return its sealing parameters."""
    descriptor = _descriptor(avbtool, image, PARTITION_NAME)
    if descriptor["hashAlgorithm"] != HASH_ALGORITHM:
        raise ComposeAvbError(
            f"stock system_ext uses {descriptor['hashAlgorithm']!r}, not {HASH_ALGORITHM!r}."
        )
    if descriptor["dataBlockSize"] != BLOCK_SIZE or descriptor["hashBlockSize"] != BLOCK_SIZE:
        raise ComposeAvbError("stock system_ext does not use 4096-byte AVB data and hash blocks.")
    if descriptor["fecRoots"] != FEC_ROOTS:
        raise ComposeAvbError(f"stock system_ext does not use {FEC_ROOTS} FEC roots.")
    return descriptor


def maximum_filesystem_size(
    avbtool: Path,
    filesystem: Path,
    *,
    partition_size: int,
    salt: str,
    fec: Path,
) -> int:
    """Ask the pinned AVB implementation how much EROFS fits with the stock FEC parameters."""
    if partition_size <= 0 or partition_size % BLOCK_SIZE:
        raise ComposeAvbError("system_ext partition size must be a positive 4096-byte multiple.")
    output = _avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image",
            str(filesystem),
            "--partition_size",
            str(partition_size),
            "--partition_name",
            PARTITION_NAME,
            "--salt",
            salt,
            "--hash_algorithm",
            HASH_ALGORITHM,
            "--block_size",
            str(BLOCK_SIZE),
            "--fec_num_roots",
            str(FEC_ROOTS),
            "--algorithm",
            "NONE",
            "--calc_max_image_size",
        ],
        fec=fec,
    )
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines or not lines[-1].isdigit():
        raise ComposeAvbError("avbtool did not return a maximum system_ext filesystem size.")
    return int(lines[-1])


def minimum_partition_size(
    avbtool: Path,
    filesystem: Path,
    *,
    current_size: int,
    maximum_size: int,
    salt: str,
    fec: Path,
) -> int:
    """Find the smallest aligned partition size that can contain the rebuilt EROFS and FEC."""
    if current_size <= 0 or maximum_size < current_size:
        raise ComposeAvbError("the system_ext partition size range is invalid.")
    if current_size % BLOCK_SIZE or maximum_size % BLOCK_SIZE:
        raise ComposeAvbError("system_ext partition bounds must be 4096-byte multiples.")
    filesystem_size = filesystem.stat().st_size
    if filesystem_size == 0 or filesystem_size % BLOCK_SIZE:
        raise ComposeAvbError("the rebuilt system_ext EROFS size is invalid.")

    def fits(size: int) -> bool:
        return (
            maximum_filesystem_size(
                avbtool,
                filesystem,
                partition_size=size,
                salt=salt,
                fec=fec,
            )
            >= filesystem_size
        )

    if fits(current_size):
        return current_size
    if not fits(maximum_size):
        raise ComposeAvbError(
            f"the rebuilt system_ext EROFS ({filesystem_size} bytes) cannot fit with its "
            f"hashtree and FEC inside the {maximum_size}-byte super device."
        )

    lower = current_size
    upper = maximum_size
    while upper - lower > BLOCK_SIZE:
        middle = ((lower + upper) // (2 * BLOCK_SIZE)) * BLOCK_SIZE
        if middle <= lower:
            middle = lower + BLOCK_SIZE
        if fits(middle):
            upper = middle
        else:
            lower = middle
    return upper


def minimum_partition_size_for_descriptor(
    avbtool: Path,
    filesystem: Path,
    *,
    partition_name: str,
    current_size: int,
    maximum_size: int,
    descriptor: dict[str, Any],
    fec: Path | None = None,
) -> int:
    """Find the smallest aligned partition size that fits with a source hashtree format."""
    block_size = descriptor.get("dataBlockSize")
    if (
        not isinstance(partition_name, str)
        or not partition_name
        or "/" in partition_name
        or "\\" in partition_name
        or not isinstance(block_size, int)
        or isinstance(block_size, bool)
        or block_size < BLOCK_SIZE
        or block_size & (block_size - 1)
        or descriptor.get("hashBlockSize") != block_size
        or not isinstance(descriptor.get("hashAlgorithm"), str)
        or not isinstance(descriptor.get("salt"), str)
    ):
        raise ComposeAvbError(f"{partition_name}: the stock hashtree parameters are invalid.")
    roots = descriptor.get("fecRoots")
    if not isinstance(roots, int) or isinstance(roots, bool) or roots < 0:
        raise ComposeAvbError(f"{partition_name}: the stock FEC root count is invalid.")
    if roots and fec is None:
        raise ComposeAvbError(f"{partition_name}: the stock hashtree requires the pinned FEC tool.")
    alignment = max(block_size, BLOCK_SIZE)
    if (
        current_size <= 0
        or maximum_size < current_size
        or current_size % alignment
        or maximum_size % alignment
    ):
        raise ComposeAvbError(f"{partition_name}: the AVB partition size range is invalid.")
    filesystem_size = filesystem.stat().st_size
    if filesystem_size == 0 or filesystem_size % block_size:
        raise ComposeAvbError(f"{partition_name}: the rebuilt filesystem size is invalid.")

    def fits(size: int) -> bool:
        arguments = [
            "add_hashtree_footer",
            "--image",
            str(filesystem),
            "--partition_size",
            str(size),
            "--partition_name",
            partition_name,
            "--salt",
            str(descriptor["salt"]),
            "--hash_algorithm",
            str(descriptor["hashAlgorithm"]),
            "--block_size",
            str(block_size),
        ]
        if roots:
            arguments.extend(["--fec_num_roots", str(roots)])
        arguments.extend(["--algorithm", "NONE", "--calc_max_image_size"])
        output = _avbtool(avbtool, arguments, fec=fec if roots else None)
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        if not lines or not lines[-1].isdigit():
            raise ComposeAvbError(
                f"avbtool did not return a maximum {partition_name} filesystem size."
            )
        return int(lines[-1]) >= filesystem_size

    if fits(current_size):
        return current_size
    if not fits(maximum_size):
        raise ComposeAvbError(
            f"the rebuilt {partition_name} filesystem ({filesystem_size} bytes) cannot fit "
            f"inside the {maximum_size}-byte super allocation."
        )
    lower = current_size
    upper = maximum_size
    while upper - lower > alignment:
        middle = ((lower + upper) // (2 * alignment)) * alignment
        if middle <= lower:
            middle = lower + alignment
        if fits(middle):
            upper = middle
        else:
            lower = middle
    return upper


def seal_partition(
    avbtool: Path,
    filesystem: Path,
    output: Path,
    *,
    partition_name: str,
    partition_size: int,
    stock_descriptor: dict[str, Any],
    fec: Path | None = None,
) -> dict[str, Any]:
    """Seal a rebuilt filesystem while retaining its source partition's AVB parameters."""
    output_parent = _output_parent(output, "the sealed output")
    block_size = stock_descriptor.get("dataBlockSize")
    roots = stock_descriptor.get("fecRoots")
    if (
        not isinstance(block_size, int)
        or isinstance(block_size, bool)
        or block_size <= 0
        or stock_descriptor.get("hashBlockSize") != block_size
        or not isinstance(roots, int)
        or isinstance(roots, bool)
        or roots < 0
        or partition_size <= 0
        or partition_size % block_size
    ):
        raise ComposeAvbError(f"{partition_name}: the stock AVB parameters are invalid.")
    if roots and fec is None:
        raise ComposeAvbError(f"{partition_name}: the stock hashtree requires the pinned FEC tool.")

    with tempfile.TemporaryDirectory(
        prefix=f".apkrun-{partition_name}-", dir=output_parent
    ) as name:
        staging = Path(name)
        staged_image = staging / f"{partition_name}.img"
        shutil.copyfile(filesystem, staged_image)
        arguments = [
            "add_hashtree_footer",
            "--image",
            str(staged_image),
            "--partition_size",
            str(partition_size),
            "--partition_name",
            partition_name,
            "--salt",
            str(stock_descriptor["salt"]),
            "--hash_algorithm",
            str(stock_descriptor["hashAlgorithm"]),
            "--block_size",
            str(block_size),
        ]
        if roots:
            arguments.extend(["--fec_num_roots", str(roots)])
        arguments.extend(["--algorithm", "NONE"])
        _avbtool(avbtool, arguments, fec=fec if roots else None)
        if staged_image.stat().st_size != partition_size:
            raise ComposeAvbError(f"the sealed {partition_name} does not match its partition size.")

        descriptor = _descriptor(avbtool, staged_image, partition_name)
        for key in (
            "partition",
            "dataBlockSize",
            "hashBlockSize",
            "fecRoots",
            "hashAlgorithm",
            "salt",
        ):
            if descriptor[key] != stock_descriptor[key]:
                raise ComposeAvbError(f"the sealed {partition_name} changed its stock {key}.")
        if descriptor["imageSize"] != filesystem.stat().st_size:
            raise ComposeAvbError(f"the {partition_name} hashtree does not cover the filesystem.")
        link = staging / f"{partition_name}.part"
        link.symlink_to(staged_image.resolve())
        verified = _avbtool(
            avbtool, ["verify_image", "--image", str(link)], fec=fec if roots else None
        )
        if "successfully verified" not in verified.lower() or "hashtree" not in verified.lower():
            raise ComposeAvbError(f"avbtool did not verify the {partition_name} hashtree.")
        _publish_new_file(staged_image, output)
    return descriptor


def seal_system_ext(
    avbtool: Path,
    filesystem: Path,
    output: Path,
    *,
    partition_size: int,
    stock_descriptor: dict[str, Any],
    fec: Path,
) -> dict[str, Any]:
    """Seal the rebuilt EROFS with stock parameters, a fresh hashtree, and FEC."""
    output_parent = _output_parent(output, "the sealed output")
    if partition_size <= 0 or partition_size % BLOCK_SIZE:
        raise ComposeAvbError("system_ext partition size must be a positive 4096-byte multiple.")
    if filesystem.stat().st_size > maximum_filesystem_size(
        avbtool,
        filesystem,
        partition_size=partition_size,
        salt=str(stock_descriptor["salt"]),
        fec=fec,
    ):
        raise ComposeAvbError("the rebuilt system_ext filesystem does not fit its AVB partition.")

    with tempfile.TemporaryDirectory(prefix=".apkrun-system-ext-", dir=output_parent) as name:
        staging = Path(name)
        staged_image = staging / "system_ext.img"
        shutil.copyfile(filesystem, staged_image)
        _avbtool(
            avbtool,
            [
                "add_hashtree_footer",
                "--image",
                str(staged_image),
                "--partition_size",
                str(partition_size),
                "--partition_name",
                PARTITION_NAME,
                "--salt",
                str(stock_descriptor["salt"]),
                "--hash_algorithm",
                HASH_ALGORITHM,
                "--block_size",
                str(BLOCK_SIZE),
                "--fec_num_roots",
                str(FEC_ROOTS),
                "--algorithm",
                "NONE",
            ],
            fec=fec,
        )
        if staged_image.stat().st_size != partition_size:
            raise ComposeAvbError("the sealed system_ext does not match its super metadata size.")

        descriptor = _descriptor(avbtool, staged_image, PARTITION_NAME)
        for key in (
            "partition",
            "dataBlockSize",
            "hashBlockSize",
            "fecRoots",
            "hashAlgorithm",
            "salt",
        ):
            if descriptor[key] != stock_descriptor[key]:
                raise ComposeAvbError(f"the sealed system_ext changed its stock {key}.")
        if descriptor["imageSize"] != filesystem.stat().st_size:
            raise ComposeAvbError(
                "the system_ext hashtree does not cover exactly the rebuilt EROFS."
            )

        link = staging / "system_ext.part"
        try:
            link.symlink_to(staged_image.resolve())
            verified = _avbtool(avbtool, ["verify_image", "--image", str(link)], fec=fec)
        except OSError as error:
            raise ComposeAvbError(f"could not verify the system_ext hashtree: {error}") from None
        if "successfully verified" not in verified.lower() or "hashtree" not in verified.lower():
            raise ComposeAvbError("avbtool did not verify the system_ext hashtree.")
        _publish_new_file(staged_image, output)
    return descriptor


def refresh_system_ext_vbmeta(
    avbtool: Path,
    stock_vbmeta_system: Path,
    sealed_system_ext: Path,
    signing_key: Path,
    output: Path,
) -> dict[str, Any]:
    """Replace only the system_ext descriptor in vbmeta_system and re-sign it."""
    output_parent = _output_parent(output, "the refreshed vbmeta")
    try:
        with tempfile.TemporaryDirectory(
            prefix=".apkrun-vbmeta-system-", dir=output_parent
        ) as name:
            staging = Path(name)
            staged_vbmeta = staging / "vbmeta_system.img"
            result = refresh_vbmeta_partition(
                avbtool,
                stock_vbmeta_system,
                sealed_system_ext,
                PARTITION_NAME,
                signing_key,
                staged_vbmeta,
                staging,
            )
            _publish_new_file(staged_vbmeta, output)
            return result
    except (ValueError, OSError) as error:
        raise ComposeAvbError(f"could not refresh vbmeta_system_a: {error}") from None


def resign_top_vbmeta(
    avbtool: Path,
    stock_vbmeta: Path,
    signing_key: Path,
    output: Path,
) -> dict[str, Any]:
    """Re-sign top-level vbmeta while preserving its exact descriptor set and policy."""
    output_parent = _output_parent(output, "the top-level vbmeta output")
    stock_info = _info(avbtool, stock_vbmeta)
    stock_top = parse_top(stock_info)
    if stock_top.get("Algorithm") != VBMETA_ALGORITHM:
        raise ComposeAvbError(f"the stock vbmeta is not signed with {VBMETA_ALGORITHM}.")
    if stock_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
        raise ComposeAvbError("the stock vbmeta is not signed with the pinned AOSP AVB test key.")
    try:
        public_key_metadata = verify_vbmeta_signature(avbtool, stock_vbmeta)
        stock_header, stock_descriptors = _raw_vbmeta_descriptors(stock_vbmeta)
    except (ValueError, OSError) as error:
        raise ComposeAvbError(f"the stock vbmeta is invalid: {error}") from None

    required = (
        "Rollback Index",
        "Rollback Index Location",
        "Flags",
        "Release String",
    )
    if any(key not in stock_top for key in required):
        raise ComposeAvbError("the stock vbmeta lacks required signing metadata.")
    rollback_index = stock_top["Rollback Index"].split()[0]
    rollback_location = stock_top["Rollback Index Location"].split()[0]
    flags = stock_top["Flags"].split()[0]
    release = vbmeta_release_string(avbtool, stock_vbmeta)
    try:
        with tempfile.TemporaryDirectory(prefix=".apkrun-vbmeta-", dir=output_parent) as name:
            staging = Path(name)
            raw = staging / "composed-vbmeta.raw"
            metadata_path = staging / "composed-vbmeta.pkmd"
            args = [
                "make_vbmeta_image",
                "--output",
                str(raw),
                "--algorithm",
                VBMETA_ALGORITHM,
                "--key",
                str(signing_key),
                "--rollback_index",
                rollback_index,
                "--rollback_index_location",
                rollback_location,
                "--flags",
                flags,
                "--internal_release_string",
                release,
                "--include_descriptors_from_image",
                str(stock_vbmeta),
            ]
            if public_key_metadata:
                metadata_path.write_bytes(public_key_metadata)
                args.extend(["--public_key_metadata", str(metadata_path)])
            _avbtool(avbtool, args)
            blob = raw.read_bytes()
            if len(blob) > stock_vbmeta.stat().st_size:
                raise ComposeAvbError("the re-signed top-level vbmeta exceeds its stock partition.")
            staged_output = staging / "vbmeta-a-composed.img"
            staged_output.write_bytes(blob + bytes(stock_vbmeta.stat().st_size - len(blob)))
            new_info = _info(avbtool, staged_output)
            new_top = parse_top(new_info)
            new_header, new_descriptors = _raw_vbmeta_descriptors(staged_output)
            new_public_key_metadata = verify_vbmeta_signature(avbtool, staged_output)
            if new_public_key_metadata != public_key_metadata:
                raise ComposeAvbError("the re-signed top-level vbmeta changed public-key metadata.")
            if new_top.get("Algorithm") != VBMETA_ALGORITHM:
                raise ComposeAvbError("the re-signed top-level vbmeta has a different algorithm.")
            if new_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
                raise ComposeAvbError("the re-signed top-level vbmeta uses a different public key.")
            for key in required:
                if new_top.get(key) != stock_top.get(key):
                    raise ComposeAvbError(f"the re-signed top-level vbmeta changed its {key}.")
            if new_header != stock_header:
                raise ComposeAvbError(
                    "the re-signed top-level vbmeta changed its descriptor table header."
                )
            if collections.Counter(item[2] for item in new_descriptors) != collections.Counter(
                item[2] for item in stock_descriptors
            ):
                raise ComposeAvbError("the re-signed top-level vbmeta changed its descriptor set.")
            if staged_output.stat().st_size != stock_vbmeta.stat().st_size:
                raise ComposeAvbError("the re-signed top-level vbmeta changed its partition size.")
            _publish_new_file(staged_output, output)
            return {
                "rollbackIndex": int(rollback_index),
                "descriptorCount": len(new_descriptors),
                "signer": "aosp-avb-testkey-rsa4096",
                "publicKeySha1": VBMETA_PUBLIC_KEY_SHA1,
            }
    except ComposeAvbError:
        raise
    except (OSError, ValueError) as error:
        raise ComposeAvbError(f"could not re-sign top-level vbmeta: {error}") from None
