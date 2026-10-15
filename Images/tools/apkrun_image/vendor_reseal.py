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
   for development only. It keeps the stock rollback index, and every other descriptor is kept.
   The blob is padded with zeros to the size of the stock file.

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


@cache
def _vendored_avb_api(avbtool: Path) -> dict[str, Any]:
    """Load the pinned avbtool signature verifier without invoking its CLI entry point."""
    return runpy.run_path(str(avbtool))


def verify_vbmeta_signature(avbtool: Path, image: Path) -> None:
    """Verify the vbmeta authentication block using the pinned avbtool implementation."""
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
    verify_vbmeta_signature(avbtool, stock_vbmeta)
    stock_info = _info(avbtool, stock_vbmeta)
    stock_top = parse_top(stock_info)
    stock_tree = vendor_tree(stock_info, "the stock vbmeta_a")
    if stock_top.get("Algorithm") != VBMETA_ALGORITHM:
        raise ResealError(f"the stock vbmeta_a is not signed with {VBMETA_ALGORITHM}.")
    if stock_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the stock vbmeta_a is not signed with the pinned AOSP AVB test key.")

    if signing_key.is_symlink() or not signing_key.is_file():
        raise ResealError(f"{signing_key}: the signing key must be a regular file.")
    public_key = scratch / "signing-key.avbpubkey"
    run_avbtool(
        avbtool,
        ["extract_public_key", "--key", str(signing_key), "--output", str(public_key)],
    )
    if hashlib.sha1(public_key.read_bytes()).hexdigest() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the signing key does not match the pinned AOSP AVB test key.")

    rollback = stock_top.get("Rollback Index")
    if rollback is None:
        raise ResealError("the stock vbmeta_a has no rollback index.")
    partition_size = stock_vbmeta.stat().st_size

    raw = scratch / "vbmeta-raw.bin"
    run_avbtool(
        avbtool,
        [
            "update_partition_descriptor",
            "--image",
            str(stock_vbmeta),
            "--partition_image",
            str(vendor),
            "--output",
            str(raw),
            "--algorithm",
            VBMETA_ALGORITHM,
            "--key",
            str(signing_key),
            "--rollback_index",
            rollback.split()[0],
        ],
    )
    blob = raw.read_bytes()
    if len(blob) > partition_size:
        raise ResealError("the refreshed vbmeta is larger than the stock partition.")
    padded = scratch / "vbmeta-padded.bin"
    padded.write_bytes(blob + bytes(partition_size - len(blob)))

    verify_vbmeta_signature(avbtool, padded)
    new_info = _info(avbtool, padded)
    new_top = parse_top(new_info)
    if new_top.get("Algorithm") != VBMETA_ALGORITHM:
        raise ResealError(f"the refreshed vbmeta is not signed with {VBMETA_ALGORITHM}.")
    if new_top.get("Public key (sha1)", "").lower() != VBMETA_PUBLIC_KEY_SHA1:
        raise ResealError("the refreshed vbmeta does not carry the pinned AOSP AVB test key.")
    for key in ("Rollback Index", "Rollback Index Location", "Flags", "Minimum libavb version"):
        if new_top.get(key) != stock_top.get(key):
            raise ResealError(f"the refreshed vbmeta changed its {key}.")
    vendor_expected = vendor_tree(_info(avbtool, vendor), "the resealed vendor_a")
    new_tree = vendor_tree(new_info, "the refreshed vbmeta_a")
    if new_tree != vendor_expected:
        raise ResealError("the refreshed vbmeta does not carry the descriptor of the new footer.")
    stock_others = [b for b in descriptor_blocks(stock_info) if not _is_vendor_block(b)]
    new_others = [b for b in descriptor_blocks(new_info) if not _is_vendor_block(b)]
    if stock_others != new_others:
        raise ResealError("the refreshed vbmeta changed a descriptor other than the vendor one.")
    shutil.move(str(padded), output)
    return {
        "rollbackIndex": int(rollback.split()[0]),
        "blobSize": len(blob),
        "signer": VBMETA_SIGNER,
        "publicKeySha1": VBMETA_PUBLIC_KEY_SHA1,
        "previousVendorDescriptor": stock_tree,
        "vendorDescriptor": new_tree,
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
        vbmeta = refresh_vbmeta(
            avbtool, stock_vbmeta, vendor_out, signing_key, vbmeta_out, scratch
        )
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
