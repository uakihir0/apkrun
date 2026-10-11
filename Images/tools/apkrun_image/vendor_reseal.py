"""Reseal the injected vendor partition with a fresh hashtree footer (#099, step 2).

The injected `vendor_a` that `inject-vendor` writes has a footer of its own. The tool takes the
injected image up to the original image size that the footer records (the EROFS image), and it
appends a fresh hashtree footer with the vendored avbtool (IR-624). The data and hash block sizes,
the hash algorithm, the salt, and the partition name are the stock footer's, and the footer is
`NONE`. No FEC is made, because the `fec` tool is not pinned (IR-740). The size of the partition is
the size of the stock partition in `super`, so the super metadata does not change.

The new image is checked with `info_image` and `verify_image`. It is written only after the checks
pass, and the tool never boots anything.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from apkrun_image.erofs import sha256_file
from apkrun_image.vendor_inject import VERITY_PARTITION, run_avbtool

PARTITION = VERITY_PARTITION
ALGORITHM = "NONE"
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


def _vendor_tree(info_text: str, what: str) -> dict[str, Any]:
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
    stock_tree = _vendor_tree(stock_info, "the stock vendor_a")
    if stock_tree["imageSize"] != _original_size(stock_info, "the stock vendor_a"):
        raise ResealError("the stock hashtree does not cover the original image size.")

    injected_info = _info(avbtool, injected)
    injected_tree = _vendor_tree(injected_info, "the injected vendor_a")
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
    sealed_tree = _vendor_tree(_info(avbtool, work), "the resealed vendor_a")
    if sealed_tree["fecRoots"] != 0 or sealed_tree["imageSize"] != fs_size:
        raise ResealError("the resealed vendor_a does not have a footer without FEC.")
    shutil.move(str(work), output)
    return {
        "originalImageSize": fs_size,
        "tree": sealed_tree,
        "identicalToInjected": sha256_file(output) == sha256_file(injected),
    }


