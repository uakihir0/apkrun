"""Reseal the injected vendor partition and refresh its descriptor in the stock vbmeta (#099).

The inputs are the `vendor_a.img` that `inject-vendor` writes, the stock `vendor_a` and the stock
top-level `vbmeta_a` (both read from the stock bundle). The tool writes two images and a record of
both, with the vendored avbtool (IR-624):

1. `vendor_a.img`: the injected EROFS image, up to the original image size that its footer records,
   with a fresh hashtree footer. The data and hash block sizes, the hash algorithm, the salt, and
   the partition name are the stock footer's. The footer is `NONE`, and no FEC is made, because the
   `fec` tool is not pinned (IR-740). The size is the size of the stock partition in `super`.
2. `vbmeta_a.img`: the stock top-level vbmeta with its vendor hashtree descriptor replaced by the
   descriptor of the new footer (`avbtool update_partition_descriptor`). The vbmeta is signed with
   the pinned AOSP AVB test key that already matches the stock public key (IR-1321). This output is
   for development only. It keeps the stock header, rollback settings, every other serialized
   descriptor, the release string, and the public-key metadata. The blob is padded with zeros to
   the size of the stock file.

Both images are checked with `info_image`, and the new footer is checked with `verify_image`. The
outputs are moved into the output directory only after every check passes. The tool never boots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import runpy
import shutil
import struct
import sys
import tempfile
from collections.abc import Sequence
from functools import cache
from pathlib import Path
from typing import Any

from apkrun_image.avb import AvbError, _read_vbmeta
from apkrun_image.erofs import load_component, sha256_file
from apkrun_image.manifest import _repository_root
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    OUTPUT_IMAGE,
    VERITY_PARTITION,
    _ensure_output,
    run_avbtool,
    verify_avbtool,
)
from apkrun_image.vendor_inject import (
    PARTITION as LOGICAL_PARTITION,
)

TASK = "#099"
SCHEMA_VERSION = 2
PARTITION = VERITY_PARTITION
ALGORITHM = "NONE"
VBMETA_ALGORITHM = "SHA256_RSA4096"
VBMETA_PUBLIC_KEY_SHA1 = "2597c218aae470a130f61162feaae70afd97f011"
VBMETA_SIGNER = "aosp-avb-testkey-rsa4096"
OUTPUT_VBMETA = "vbmeta_a.img"
OUTPUT_RECORD = "reseal.json"
COPY_CHUNK = 64 * 1024 * 1024
DESCRIPTOR_FIELDS = (
    "partition",
    "imageSize",
    "treeOffset",
    "treeSize",
    "dataBlockSize",
    "hashBlockSize",
    "fecRoots",
    "fecOffset",
    "fecSize",
    "hashAlgorithm",
    "salt",
    "rootDigest",
)
_TEXT_KEYS = {
    "Partition Name": "partition",
    "Hash Algorithm": "hashAlgorithm",
    "Salt": "salt",
    "Root Digest": "rootDigest",
}
_INTEGER_KEYS = {
    "Image Size": "imageSize",
    "Tree Offset": "treeOffset",
    "Tree Size": "treeSize",
    "Data Block Size": "dataBlockSize",
    "Hash Block Size": "hashBlockSize",
    "FEC num roots": "fecRoots",
    "FEC offset": "fecOffset",
    "FEC size": "fecSize",
}


class ResealError(ValueError):
    """An input that the reseal does not accept, or a result that it cannot check."""


def parse_top(info_text: str) -> dict[str, str]:
    """Return the `key: value` lines that come before the descriptors of `info_image`."""
    top: dict[str, str] = {}
    for raw in info_text.split("Descriptors:", 1)[0].splitlines():
        key, separator, value = raw.strip().partition(":")
        if separator and key:
            top[key] = value.strip()
    return top


def parse_hashtrees(info_text: str) -> dict[str, dict[str, Any]]:
    """Return every hashtree descriptor of `info_image`, keyed by partition name.

    Each descriptor carries the fields of `DESCRIPTOR_FIELDS`. A descriptor that lacks one of them
    is returned without it, so the caller decides what to refuse.
    """
    found: dict[str, dict[str, Any]] = {}
    current: dict[str, Any] | None = None
    for raw in info_text.splitlines():
        line = raw.strip()
        if line.endswith("descriptor:") or line.startswith("Prop:"):
            current = {} if line == "Hashtree descriptor:" else None
            continue
        if current is None or ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if key in _INTEGER_KEYS:
            current[_INTEGER_KEYS[key]] = int(value.split()[0])
        elif key in _TEXT_KEYS:
            current[_TEXT_KEYS[key]] = value
            if key == "Partition Name":
                found[value] = current
    return found


def descriptor_blocks(info_text: str) -> list[tuple[str, tuple[str, ...]]]:
    """Split the descriptor section of `info_image` into (header, body) blocks, in order."""
    if "Descriptors:" not in info_text:
        return []
    blocks: list[tuple[str, tuple[str, ...]]] = []
    for raw in info_text.split("Descriptors:", 1)[1].splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.endswith("descriptor:") or line.startswith("Prop:"):
            blocks.append((line, ()))
        elif blocks:
            header, body = blocks[-1]
            blocks[-1] = (header, (*body, line))
    return blocks


def _is_vendor_block(block: tuple[str, tuple[str, ...]]) -> bool:
    header, body = block
    if header != "Hashtree descriptor:":
        return False
    names = [line.partition(":")[2].strip() for line in body if line.startswith("Partition Name:")]
    return names == [PARTITION]


def vendor_tree(info_text: str, what: str) -> dict[str, Any]:
    """Return the complete vendor hashtree descriptor of an image, or refuse it."""
    tree = parse_hashtrees(info_text).get(PARTITION)
    if tree is None or any(field not in tree for field in DESCRIPTOR_FIELDS):
        raise ResealError(f"{what} has no complete {PARTITION} hashtree descriptor.")
    if tree["dataBlockSize"] != tree["hashBlockSize"]:
        raise ResealError(f"{what} has data and hash block sizes that differ.")
    return {field: tree[field] for field in DESCRIPTOR_FIELDS}


def _original_size(info_text: str, what: str) -> int:
    value = parse_top(info_text).get("Original image size")
    if value is None:
        raise ResealError(f"{what} has no footer.")
    return int(value.split()[0])


def _info(avbtool: Path, image: Path) -> str:
    return run_avbtool(avbtool, ["info_image", "--image", str(image)])


def _raw_vbmeta_descriptors(
    image: Path,
) -> tuple[bytes, list[tuple[int, str | None, bytes]]]:
    """Return a bounded vbmeta header and its exact ordered descriptor bytes."""
    try:
        with image.open("rb") as stream:
            header, vbmeta_offset = _read_vbmeta(
                stream,
                artifact_size=image.stat().st_size,
                artifact_name=str(image),
            )
            stream.seek(vbmeta_offset)
            header_bytes = stream.read(256)
            if len(header_bytes) != 256:
                raise ResealError(f"{image} has a truncated vbmeta header.")
            descriptor_offset = (
                vbmeta_offset + 256 + header.authentication_size + header.descriptors_offset
            )
            stream.seek(descriptor_offset)
            table = stream.read(header.descriptors_size)
    except (AvbError, OSError, struct.error) as error:
        raise ResealError(f"{image} has invalid vbmeta descriptors: {error}") from None
    if len(table) != header.descriptors_size:
        raise ResealError(f"{image} has a truncated vbmeta descriptor table.")

    descriptors: list[tuple[int, str | None, bytes]] = []
    offset = 0
    while offset < len(table):
        if len(table) - offset < 16:
            raise ResealError(f"{image} has a truncated AVB descriptor header.")
        tag, following_size = struct.unpack_from(">QQ", table, offset)
        end = offset + 16 + following_size
        if following_size % 8 or end > len(table):
            raise ResealError(f"{image} has an invalid AVB descriptor size.")
        encoded = table[offset:end]
        partition_name: str | None = None
        if tag == 1:
            # AvbHashtreeDescriptor has a 180-byte fixed part including its generic header.
            if len(encoded) < 180:
                raise ResealError(f"{image} has a truncated hashtree descriptor.")
            name_size = struct.unpack_from(">I", encoded, 104)[0]
            salt_size, root_digest_size = struct.unpack_from(">II", encoded, 108)
            used_size = 180 + name_size + salt_size + root_digest_size
            if (used_size + 7) & ~7 != len(encoded) or any(encoded[used_size:]):
                raise ResealError(f"{image} has an invalid hashtree partition name.")
            try:
                partition_name = encoded[180 : 180 + name_size].decode("utf-8")
            except UnicodeDecodeError:
                raise ResealError(f"{image} has a non-UTF-8 hashtree partition name.") from None
            if not partition_name or "/" in partition_name or "\\" in partition_name:
                raise ResealError(f"{image} has an invalid hashtree partition name.")
        descriptors.append((tag, partition_name, encoded))
        offset = end
    return header_bytes, descriptors


def _partition_tree(info_text: str, partition_name: str, what: str) -> dict[str, Any]:
    """Return one complete hashtree descriptor for `partition_name`, or refuse it."""
    tree = parse_hashtrees(info_text).get(partition_name)
    if tree is None or any(field not in tree for field in DESCRIPTOR_FIELDS):
        raise ResealError(f"{what} has no complete {partition_name} hashtree descriptor.")
    return {field: tree[field] for field in DESCRIPTOR_FIELDS}


@cache
def _vendored_avb_api(avbtool: Path) -> dict[str, Any]:
    """Load the pinned avbtool signature verifier without invoking its CLI entry point."""
    return runpy.run_path(str(avbtool))


def verify_vbmeta_signature(avbtool: Path, image: Path) -> bytes:
    """Verify vbmeta and return its bounded public-key metadata bytes."""
    try:
        with image.open("rb") as stream:
            header, offset = _read_vbmeta(
                stream,
                artifact_size=image.stat().st_size,
                artifact_name=str(image),
            )
            stream.seek(offset)
            blob = stream.read(header.blob_size)
    except (AvbError, OSError) as error:
        raise ResealError(
            f"{image}: could not read vbmeta for signature verification: {error}"
        ) from None
    if len(blob) != header.blob_size:
        raise ResealError(f"{image}: vbmeta is truncated before its signature can be verified.")

    tool = _vendored_avb_api(avbtool)
    avbtool_error = tool["AvbError"]
    try:
        avb_header = tool["AvbVBMetaHeader"](blob[:256])
    except (avbtool_error, OSError, ValueError, struct.error) as error:
        raise ResealError(f"{image}: invalid vbmeta header: {error}") from None
    if avb_header.algorithm_type == 0:
        raise ResealError(f"{image}: unsigned vbmeta is not accepted.")
    try:
        verified = tool["verify_vbmeta_signature"](avb_header, blob)
    except (avbtool_error, OSError, ValueError, struct.error) as error:
        raise ResealError(f"{image}: could not verify the vbmeta signature: {error}") from None
    if not verified:
        raise ResealError(f"{image}: vbmeta signature does not verify.")
    metadata_size = avb_header.public_key_metadata_size
    metadata_offset = avb_header.public_key_metadata_offset
    auxiliary_size = avb_header.auxiliary_data_block_size
    if metadata_size == 0:
        return b""
    if metadata_offset > auxiliary_size or metadata_size > auxiliary_size - metadata_offset:
        raise ResealError(f"{image}: public-key metadata extends past the auxiliary data block.")
    auxiliary_offset = 256 + avb_header.authentication_data_block_size
    metadata_start = auxiliary_offset + metadata_offset
    metadata = blob[metadata_start : metadata_start + metadata_size]
    if len(metadata) != metadata_size:
        raise ResealError(f"{image}: public-key metadata is truncated.")
    return metadata


def vbmeta_release_string(avbtool: Path, image: Path) -> str:
    """Return the release string from a bounded vbmeta header."""
    try:
        with image.open("rb") as stream:
            _header, offset = _read_vbmeta(
                stream,
                artifact_size=image.stat().st_size,
                artifact_name=str(image),
            )
            stream.seek(offset)
            header_bytes = stream.read(256)
    except (AvbError, OSError) as error:
        raise ResealError(f"{image}: could not read the vbmeta header: {error}") from None
    if len(header_bytes) != 256:
        raise ResealError(f"{image}: the vbmeta header is truncated.")
    tool = _vendored_avb_api(avbtool)
    try:
        return tool["AvbVBMetaHeader"](header_bytes).release_string
    except (tool["AvbError"], OSError, ValueError, struct.error) as error:
        raise ResealError(f"{image}: invalid vbmeta header: {error}") from None


def _copy_prefix(source: Path, destination: Path, size: int) -> None:
    with source.open("rb") as reader, destination.open("wb") as writer:
        remaining = size
        while remaining:
            chunk = reader.read(min(COPY_CHUNK, remaining))
            if not chunk:
                raise ResealError(f"{source} is shorter than its footer's original size.")
            writer.write(chunk)
            remaining -= len(chunk)


def reseal_vendor(
    avbtool: Path, injected: Path, stock: Path, output: Path, scratch: Path
) -> dict[str, Any]:
    """Write the resealed vendor image to `output` and return what was checked on it."""
    stock_info = _info(avbtool, stock)
    if parse_top(stock_info).get("Algorithm") != ALGORITHM:
        raise ResealError("the stock vendor footer is not NONE, and this tool has no signing key.")
    stock_tree = vendor_tree(stock_info, "the stock vendor_a")
    if stock_tree["imageSize"] != _original_size(stock_info, "the stock vendor_a"):
        raise ResealError("the stock hashtree does not cover the original image size.")

    injected_info = _info(avbtool, injected)
    injected_tree = vendor_tree(injected_info, "the injected vendor_a")
    partition_size = stock.stat().st_size
    if injected.stat().st_size != partition_size:
        raise ResealError("the injected vendor_a is not the size of the stock partition.")
    if injected_tree["dataBlockSize"] != stock_tree["dataBlockSize"]:
        raise ResealError("the injected vendor_a has another block size than the stock.")
    fs_size = _original_size(injected_info, "the injected vendor_a")
    if injected_tree["imageSize"] != fs_size:
        raise ResealError("the injected hashtree does not cover the original image size.")

    work = scratch / "vendor-erofs.raw"
    _copy_prefix(injected, work, fs_size)
    run_avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image",
            str(work),
            "--partition_size",
            str(partition_size),
            "--partition_name",
            PARTITION,
            "--salt",
            stock_tree["salt"],
            "--hash_algorithm",
            stock_tree["hashAlgorithm"],
            "--block_size",
            str(stock_tree["dataBlockSize"]),
            "--algorithm",
            ALGORITHM,
            "--do_not_generate_fec",
        ],
    )
    # avbtool looks for <partition name><extension of --image> in the directory of --image.
    verify_dir = scratch / "verify-vendor"
    verify_dir.mkdir()
    link = verify_dir / f"{PARTITION}.part"
    link.symlink_to(work)
    verified = run_avbtool(avbtool, ["verify_image", "--image", str(link)])
    if f"Successfully verified {stock_tree['hashAlgorithm']} hashtree" not in verified:
        raise ResealError("avbtool did not verify the new hashtree of the vendor partition.")
    if work.stat().st_size != partition_size:
        raise ResealError("the resealed vendor_a is not the size of the stock partition.")
    sealed_tree = vendor_tree(_info(avbtool, work), "the resealed vendor_a")
    if sealed_tree["fecRoots"] != 0 or sealed_tree["imageSize"] != fs_size:
        raise ResealError("the resealed vendor_a does not have a footer without FEC.")
    shutil.move(str(work), output)
    return {
        "originalImageSize": fs_size,
        "tree": sealed_tree,
        "identicalToInjected": sha256_file(output) == sha256_file(injected),
    }


def refresh_vbmeta(
    avbtool: Path,
    stock_vbmeta: Path,
    vendor: Path,
    signing_key: Path,
    output: Path,
    scratch: Path,
) -> dict[str, Any]:
    """Write signed stock vbmeta with the descriptor of `vendor` to `output`; return the record."""
    stock_vendor_descriptor = vendor_tree(_info(avbtool, stock_vbmeta), "the stock vbmeta_a")
    new_vendor_descriptor = vendor_tree(_info(avbtool, vendor), "the resealed vendor_a")
    record = refresh_vbmeta_partition(
        avbtool,
        stock_vbmeta,
        vendor,
        PARTITION,
        signing_key,
        output,
        scratch,
    )
    if (
        record["previousDescriptor"] != stock_vendor_descriptor
        or record["descriptor"] != new_vendor_descriptor
    ):
        raise ResealError(
            "the refreshed vbmeta does not preserve the validated vendor descriptors."
        )
    return {
        "rollbackIndex": record["rollbackIndex"],
        "blobSize": record["blobSize"],
        "signer": record["signer"],
        "publicKeySha1": record["publicKeySha1"],
        "previousVendorDescriptor": record["previousDescriptor"],
        "vendorDescriptor": record["descriptor"],
    }


def refresh_vbmeta_partition(
    avbtool: Path,
    stock_vbmeta: Path,
    partition_image: Path,
    partition_name: str,
    signing_key: Path,
    output: Path,
    scratch: Path,
) -> dict[str, Any]:
    """Replace exactly one named hashtree descriptor and write padded, signed vbmeta."""
    if (
        not partition_name
        or "/" in partition_name
        or "\\" in partition_name
        or "\0" in partition_name
    ):
        raise ResealError("the partition name must be a non-empty AVB partition name.")
    if output.exists() or output.is_symlink():
        raise ResealError(f"{output}: the output must not already exist.")

    public_key_metadata = verify_vbmeta_signature(avbtool, stock_vbmeta)
    stock_info = _info(avbtool, stock_vbmeta)
    stock_top = parse_top(stock_info)
    stock_tree = _partition_tree(stock_info, partition_name, "the stock vbmeta_a")
    if stock_top.get("Algorithm") != VBMETA_ALGORITHM:
        raise ResealError(f"the stock vbmeta_a is not signed with {VBMETA_ALGORITHM}.")
    if stock_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the stock vbmeta_a is not signed with the pinned AOSP AVB test key.")

    if signing_key.is_symlink() or not signing_key.is_file():
        raise ResealError(f"{signing_key}: the signing key must be a regular file.")
    public_key = scratch / f"{partition_name}-signing-key.avbpubkey"
    run_avbtool(
        avbtool,
        ["extract_public_key", "--key", str(signing_key), "--output", str(public_key)],
    )
    if hashlib.sha1(public_key.read_bytes()).hexdigest() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the signing key does not match the pinned AOSP AVB test key.")

    rollback = stock_top.get("Rollback Index")
    if rollback is None:
        raise ResealError("the stock vbmeta_a has no rollback index.")
    release_string = vbmeta_release_string(avbtool, stock_vbmeta)
    partition_size = stock_vbmeta.stat().st_size

    partition_info = _info(avbtool, partition_image)
    original_size = _original_size(partition_info, f"the {partition_name} image")
    partition_tree = _partition_tree(partition_info, partition_name, f"the {partition_name} image")
    if partition_tree["imageSize"] != original_size:
        raise ResealError(f"the {partition_name} hashtree does not cover the original image size.")
    _partition_header, image_descriptors = _raw_vbmeta_descriptors(partition_image)
    target_image_descriptors = [
        encoded for tag, name, encoded in image_descriptors if tag == 1 and name == partition_name
    ]
    if len(target_image_descriptors) != 1:
        raise ResealError(
            f"the {partition_name} image must have exactly one matching hashtree descriptor."
        )
    with tempfile.TemporaryDirectory(
        prefix=f"verify-{partition_name}-", dir=scratch
    ) as verify_name:
        verify_image = Path(verify_name) / f"{partition_name}.part"
        verify_image.symlink_to(partition_image.resolve())
        try:
            verified_footer = run_avbtool(avbtool, ["verify_image", "--image", str(verify_image)])
        except ValueError as error:
            raise ResealError(
                f"avbtool could not verify the hashtree footer of the {partition_name} partition: "
                f"{error}"
            ) from None
    verified_footer_lower = verified_footer.lower()
    if (
        "successfully verified" not in verified_footer_lower
        or "hashtree" not in verified_footer_lower
    ):
        raise ResealError(
            f"avbtool did not verify the new hashtree footer of the {partition_name} partition."
        )

    stock_header, stock_descriptors = _raw_vbmeta_descriptors(stock_vbmeta)
    stock_target_descriptors = [
        (index, encoded)
        for index, (tag, name, encoded) in enumerate(stock_descriptors)
        if tag == 1 and name == partition_name
    ]
    if len(stock_target_descriptors) != 1:
        raise ResealError(
            f"the stock vbmeta_a must have exactly one {partition_name} hashtree descriptor."
        )
    target_index, _old_target_descriptor = stock_target_descriptors[0]

    raw = scratch / f"{partition_name}-vbmeta-raw.bin"
    update_args = [
        "update_partition_descriptor",
        "--image",
        str(stock_vbmeta),
        "--partition_image",
        str(partition_image),
        "--output",
        str(raw),
        "--algorithm",
        VBMETA_ALGORITHM,
        "--key",
        str(signing_key),
        "--rollback_index",
        rollback.split()[0],
        "--internal_release_string",
        release_string,
    ]
    metadata_path: Path | None = None
    try:
        if public_key_metadata:
            with tempfile.NamedTemporaryFile(dir=scratch, delete=False) as metadata_file:
                metadata_path = Path(metadata_file.name)
                metadata_file.write(public_key_metadata)
            update_args.extend(["--public_key_metadata", str(metadata_path)])
        run_avbtool(avbtool, update_args)
    finally:
        if metadata_path is not None:
            metadata_path.unlink(missing_ok=True)
    blob = raw.read_bytes()
    if len(blob) > partition_size:
        raise ResealError("the refreshed vbmeta is larger than the stock partition.")

    padded = scratch / f"{partition_name}-vbmeta-padded.bin"
    padded.write_bytes(blob + bytes(partition_size - len(blob)))
    refreshed_metadata = verify_vbmeta_signature(avbtool, padded)
    if refreshed_metadata != public_key_metadata:
        raise ResealError("the refreshed vbmeta changed the public-key metadata.")
    new_info = _info(avbtool, padded)
    new_top = parse_top(new_info)
    if new_top.get("Algorithm") != VBMETA_ALGORITHM:
        raise ResealError(f"the refreshed vbmeta is not signed with {VBMETA_ALGORITHM}.")
    if new_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the refreshed vbmeta does not carry the pinned AOSP AVB test key.")
    for key in ("Rollback Index", "Rollback Index Location", "Flags", "Minimum libavb version"):
        if new_top.get(key) != stock_top.get(key):
            raise ResealError(f"the refreshed vbmeta changed its {key}.")
    new_header, new_descriptors = _raw_vbmeta_descriptors(padded)
    if new_header != stock_header:
        raise ResealError("the refreshed vbmeta changed the stock vbmeta header.")
    target_descriptors = [
        (index, encoded)
        for index, (tag, name, encoded) in enumerate(new_descriptors)
        if tag == 1 and name == partition_name
    ]
    if len(target_descriptors) != 1:
        raise ResealError(
            f"the refreshed vbmeta must have exactly one {partition_name} hashtree descriptor."
        )
    new_target_index, new_target_descriptor = target_descriptors[0]
    if new_target_index != target_index:
        raise ResealError("the refreshed vbmeta moved the target hashtree descriptor.")
    if new_target_descriptor != target_image_descriptors[0]:
        raise ResealError(
            "the refreshed vbmeta does not carry the descriptor of the new "
            f"{partition_name} footer."
        )
    if len(new_descriptors) != len(stock_descriptors):
        raise ResealError("the refreshed vbmeta changed the descriptor count.")
    for index, (old, new) in enumerate(zip(stock_descriptors, new_descriptors, strict=True)):
        if index == target_index:
            continue
        if old != new:
            raise ResealError("the refreshed vbmeta changed a descriptor other than the target.")

    new_tree = _partition_tree(new_info, partition_name, "the refreshed vbmeta_a")
    if new_tree != partition_tree:
        raise ResealError(
            "the refreshed vbmeta does not carry the descriptor of the new "
            f"{partition_name} footer."
        )
    if padded.stat().st_size != partition_size:
        raise ResealError("the refreshed vbmeta is not padded to the stock partition size.")
    shutil.move(str(padded), output)
    return {
        "rollbackIndex": int(rollback.split()[0]),
        "blobSize": len(blob),
        "signer": VBMETA_SIGNER,
        "publicKeySha1": VBMETA_PUBLIC_KEY_SHA1,
        "partitionName": partition_name,
        "previousDescriptor": stock_tree,
        "descriptor": new_tree,
    }


def reseal(
    *,
    injected: Path,
    stock_vendor: Path,
    stock_vbmeta: Path,
    signing_key: Path,
    output_directory: Path,
    repository: Path | None = None,
) -> dict[str, Any]:
    """Write `vendor_a.img`, `vbmeta_a.img`, and `reseal.json` to a new output directory."""
    root = _repository_root() if repository is None else repository
    avbtool = verify_avbtool(root, load_component(AVBTOOL_COMPONENT))
    stock_footer_root = vendor_tree(_info(avbtool, stock_vendor), "the stock vendor_a")[
        "rootDigest"
    ]
    if (
        vendor_tree(_info(avbtool, stock_vbmeta), "the stock vbmeta_a")["rootDigest"]
        != stock_footer_root
    ):
        raise ResealError("the stock vendor footer and the stock vbmeta_a disagree on the root.")
    injected_tree = vendor_tree(_info(avbtool, injected), "the injected vendor_a")

    with tempfile.TemporaryDirectory(prefix="apkrun-099-reseal-") as name:
        scratch = Path(name)
        vendor_out = scratch / OUTPUT_IMAGE
        vbmeta_out = scratch / OUTPUT_VBMETA
        vendor = reseal_vendor(avbtool, injected, stock_vendor, vendor_out, scratch)
        vbmeta = refresh_vbmeta(avbtool, stock_vbmeta, vendor_out, signing_key, vbmeta_out, scratch)
        record: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "task": TASK,
            "partition": {
                "name": LOGICAL_PARTITION,
                "verityName": PARTITION,
                "size": stock_vendor.stat().st_size,
            },
            "injected": {
                "sha256": sha256_file(injected),
                "size": injected.stat().st_size,
                "originalImageSize": vendor["originalImageSize"],
                "rootDigest": injected_tree["rootDigest"],
            },
            "stock": {
                "vendorSha256": sha256_file(stock_vendor),
                "vendorRootDigest": stock_footer_root,
                "vbmetaSha256": sha256_file(stock_vbmeta),
                "vbmetaSize": stock_vbmeta.stat().st_size,
            },
            "vendor": {
                "file": OUTPUT_IMAGE,
                "sha256": sha256_file(vendor_out),
                "size": vendor_out.stat().st_size,
                "originalImageSize": vendor["originalImageSize"],
                "descriptor": vendor["tree"],
                "identicalToInjected": vendor["identicalToInjected"],
            },
            "vbmeta": {
                "file": OUTPUT_VBMETA,
                "sha256": sha256_file(vbmeta_out),
                "size": vbmeta_out.stat().st_size,
                "algorithm": VBMETA_ALGORITHM,
                **vbmeta,
            },
            "decisions": {
                "fec": "not generated, because the fec tool is not pinned (IR-740)",
                "topLevelSignature": (
                    f"{VBMETA_ALGORITHM} with {VBMETA_SIGNER}; development image only (IR-1321)"
                ),
                "rollbackIndex": "kept from the stock vbmeta_a (IR-743)",
            },
            "verifiedByAvbtool": True,
        }
        # The directory is made only now, after every check, and a failure while the files are moved
        # removes the files that were moved, so a refused run leaves no partial output.
        existed = output_directory.expanduser().exists()
        directory = _ensure_output(output_directory, root)
        moved: list[Path] = []
        try:
            for file_name, source in ((OUTPUT_IMAGE, vendor_out), (OUTPUT_VBMETA, vbmeta_out)):
                target = directory / file_name
                if target.exists() or target.is_symlink():
                    raise ResealError(f"{target}: the output already exists")
                shutil.move(str(source), target)
                moved.append(target)
            (directory / OUTPUT_RECORD).write_text(
                json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            moved.append(directory / OUTPUT_RECORD)
        except BaseException:
            for target in moved:
                target.unlink(missing_ok=True)
            if not existed:
                directory.rmdir()
            raise
    return record


def build_parser() -> argparse.ArgumentParser:
    """Build the command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image vendor-reseal",
        description="Reseal the injected vendor_a and refresh the vendor descriptor of vbmeta_a.",
    )
    parser.add_argument(
        "--injected", type=Path, required=True, help="the vendor_a.img of inject-vendor"
    )
    parser.add_argument("--stock-vendor", type=Path, required=True, help="the stock vendor_a")
    parser.add_argument("--stock-vbmeta", type=Path, required=True, help="the stock vbmeta_a")
    parser.add_argument(
        "--key",
        type=Path,
        required=True,
        help="the pinned AOSP AVB test key; output is for development only",
    )
    parser.add_argument(
        "--out", type=Path, required=True, help="a new or empty directory outside the repository"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Reseal the vendor partition and print a summary."""
    arguments = build_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        record = reseal(
            injected=arguments.injected,
            stock_vendor=arguments.stock_vendor,
            stock_vbmeta=arguments.stock_vbmeta,
            signing_key=arguments.key,
            output_directory=arguments.out,
        )
    except (ValueError, OSError) as error:
        # ResealError and InjectError are ValueErrors; the rest is I/O.
        print(f"vendor-reseal: {error}", file=sys.stderr)
        return 1
    print(f"vendor-reseal: wrote {record['vendor']['file']} ({record['vendor']['size']} bytes)")
    print(f"vendor-reseal: wrote {record['vbmeta']['file']} ({record['vbmeta']['size']} bytes)")
    return 0
