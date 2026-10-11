"""Build a development bundle whose super carries a replaced logical partition (#099).

The variant is the stock bundle with one logical partition of its `super` replaced. The stock
bundle is read and never changed:

1. The stock bundle is checked first: its manifest validates, every file matches its entry,
   `SHA256SUMS` matches, `manifest.sig` verifies with the signing key, and the super partition
   of `os.img` hashes to its entry. The stock super artifact of the Android image manifest must
   expand to the same bytes, so the variant is the stock super with one partition replaced.
2. `lp_write.replace_partition` writes the replaced super as a sparse image (IR-680).
3. The expanded super is spliced into a new copy of `os.img` at the partition's offset in the
   GPT. The other bytes of the disk and the other files are copied.
4. The copy is checked against the stock bytes. Every byte outside the replaced extents is
   equal, and the partition reads back as the replacement followed by zeros.
5. The file entries, the super partition hash, `SHA256SUMS`, and `manifest.sig` are made by the
   bundle module's own functions. The manifest is validated (runtime-image-manifest.md §5, §6).

The variant keeps the stock `imageVersion` and `kind`, because the schema has no field for a
variant and the rules fix `kind` to the origin (IR-700). Its top-level vbmeta is not signed
again (IR-650), and no partition changes size (IR-682). `manifest.sig` is made with the
developer image key, which Debug builds trust. The record next to the bundle names every
input and output, and it is outside the bundle, because the bundle lists its own files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, BinaryIO

from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from apkrun_image import lp
from apkrun_image.bundle import (
    BundleError,
    _checksums,
    _file_entry,
    _load_signing_key,
    _sha256,
    _staging,
)
from apkrun_image.disks import DisksError, _hash_range
from apkrun_image.extract import ExtractError, _open_artifact, _role_artifact
from apkrun_image.gpt import SECTOR_SIZE, GptError, read_gpt
from apkrun_image.lp import LpMetadataError
from apkrun_image.lp_write import LpWriteError, replace_partition
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _resolve_archive_root,
)
from apkrun_image.runtime_manifest import load_and_validate, validate
from apkrun_image.sign import SignatureError, key_id_of, render_signature, verify_signature
from apkrun_image.sparse import SparseImageError, expand_into, write_skipping_zeros
from apkrun_image.vendor_inject import OUTPUT_RECORD

SCHEMA_VERSION = 1
TASK = "#099"
SUPER_LABEL = "super"
BOOT_FILES = ("bootconfig", "cmdline", "kernel", "ramdisk")
MANIFEST_NAME = "manifest.json"
SIGNATURE_NAME = "manifest.sig"
CHECKSUMS_NAME = "SHA256SUMS"
BUNDLE_METADATA = frozenset({MANIFEST_NAME, SIGNATURE_NAME, CHECKSUMS_NAME})
RECORD_NAME = "variant.json"
RECORD_SUFFIX = ".variant.json"
COPY_SIZE = 4 * 1024 * 1024
COMPARE_SIZE = 8 * 1024 * 1024


class BundleVariantError(ValueError):
    """The variant cannot be built from these inputs, or the result differs from the stock."""


class _Window:
    """A seekable view of `size` bytes of `stream` that starts at `base`."""

    def __init__(self, stream: BinaryIO, base: int, size: int) -> None:
        self._stream = stream
        self._base = base
        self._size = size
        self._position = 0

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            target = offset
        elif whence == os.SEEK_CUR:
            target = self._position + offset
        elif whence == os.SEEK_END:
            target = self._size + offset
        else:
            raise ValueError(f"unsupported whence {whence}")
        if target < 0:
            raise ValueError("seek before the start of the window")
        self._position = target
        return target

    def tell(self) -> int:
        return self._position

    def read(self, size: int = -1) -> bytes:
        remaining = max(0, self._size - self._position)
        length = remaining if size < 0 else min(size, remaining)
        if length == 0:
            return b""
        self._stream.seek(self._base + self._position)
        data = self._stream.read(length)
        self._position += len(data)
        return data


def _super_record(manifest: Mapping[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return the disk and the partition record of the super partition."""
    for disk in manifest["disks"]:
        for partition in disk["partitions"]:
            if partition["label"] == SUPER_LABEL:
                return disk, partition
    raise BundleVariantError("the stock manifest has no super partition")


def _verify_stock(bundle: Path, public_key: bytes) -> tuple[bytes, dict[str, Any]]:
    """Check the stock bundle against its manifest, its checksums, and its signature."""
    # Symbolic links are refused before anything is read, so a link cannot make the hashing
    # read a device or leave the bundle.
    for path in bundle.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise BundleVariantError(
                f"the stock bundle holds {path.relative_to(bundle).as_posix()}, which is not a "
                "regular file or directory"
            )
    manifest_bytes = (bundle / MANIFEST_NAME).read_bytes()
    violations = load_and_validate(manifest_bytes)
    if violations:
        first = violations[0]
        raise BundleVariantError(
            f"the stock manifest fails {first.rule} at {first.path}: {first.reason}"
        )
    manifest: dict[str, Any] = json.loads(manifest_bytes)
    files = manifest["files"]
    for entry in files:
        if _file_entry(bundle, entry["path"]) != entry:
            raise BundleVariantError(
                f"the stock bundle's {entry['path']} does not match its manifest entry"
            )
    listed = {entry["path"] for entry in files} | BUNDLE_METADATA
    present = {path.relative_to(bundle).as_posix() for path in bundle.rglob("*") if path.is_file()}
    if present != listed:
        raise BundleVariantError(
            f"the stock bundle holds {sorted(present - listed)} outside its manifest and lacks "
            f"{sorted(listed - present)}"
        )
    try:
        checksums = (bundle / CHECKSUMS_NAME).read_text(encoding="ascii")
    except UnicodeDecodeError:
        raise BundleVariantError("the stock bundle's SHA256SUMS is not ASCII") from None
    if checksums != _checksums(files):
        raise BundleVariantError("the stock bundle's SHA256SUMS does not match its manifest")
    try:
        verify_signature(
            manifest_bytes,
            (bundle / SIGNATURE_NAME).read_bytes(),
            {key_id_of(public_key): public_key},
        )
    except SignatureError as error:
        raise BundleVariantError(
            f"the stock manifest.sig does not verify with the signing key: {error}"
        ) from None
    return manifest_bytes, manifest


def _super_location(
    stock_disk: Path, disk: Mapping[str, Any], record: Mapping[str, Any]
) -> tuple[int, int]:
    """Return the byte offset and size of the super partition, as the GPT gives them."""
    with stock_disk.open("rb") as stream:
        table = read_gpt(stream, disk["logicalSize"])
    entry = next((item for item in table.partitions if item.label == SUPER_LABEL), None)
    if entry is None:
        raise BundleVariantError("the stock disk has no super partition in its GPT")
    if entry.first_lba != record["firstLBA"] or entry.size != record["size"]:
        raise BundleVariantError("the super partition in the GPT differs from the manifest")
    return entry.first_lba * SECTOR_SIZE, entry.size


def _expanded_sha256(sparse: Path, size: int, scratch: Path) -> str:
    """Return the SHA-256 of the sparse image expanded to `size` bytes."""
    with sparse.open("rb") as stream, scratch.open("w+b") as out:
        out.truncate(size)
        header = expand_into(stream, out, 0)
        if header.logical_size != size:
            raise BundleVariantError(
                f"{sparse} expands to {header.logical_size} bytes, not the partition's {size}"
            )
        digest = _hash_range(out, 0, size)
    scratch.unlink()
    return digest


def _copy_range(source: BinaryIO, out: BinaryIO, start: int, end: int) -> None:
    """Copy `source` into `out` between two offsets, leaving all-zero blocks as holes."""
    offset = start
    while offset < end:
        length = min(COPY_SIZE, end - offset)
        source.seek(offset)
        data = source.read(length)
        if len(data) != length:
            raise BundleVariantError(f"the stock disk ends before offset {offset + length}")
        write_skipping_zeros(out, offset, data)
        offset += length


def _splice(stock_disk: Path, sparse: Path, destination: Path, offset: int, size: int) -> None:
    """Write a copy of the stock disk whose super range holds the expanded `sparse` image."""
    total = stock_disk.stat().st_size
    with stock_disk.open("rb") as source, destination.open("w+b") as out:
        out.truncate(total)
        _copy_range(source, out, 0, offset)
        _copy_range(source, out, offset + size, total)
        with sparse.open("rb") as stream:
            header = expand_into(stream, out, offset)
        if header.logical_size != size:
            raise BundleVariantError(
                f"the replaced super expands to {header.logical_size} bytes, not {size}"
            )
        out.flush()
        os.fsync(out.fileno())


def _same_outside(
    first: BinaryIO, second: BinaryIO, size: int, excluded: Sequence[tuple[int, int]]
) -> None:
    """Raise if two streams of `size` bytes differ anywhere outside the excluded ranges."""
    position = 0
    for start, length in sorted(excluded) + [(size, 0)]:
        offset = position
        while offset < start:
            chunk = min(COMPARE_SIZE, start - offset)
            first.seek(offset)
            before = first.read(chunk)
            second.seek(offset)
            after = second.read(chunk)
            if before != after or len(before) != chunk:
                raise BundleVariantError(
                    f"the variant differs from the stock bundle at byte {offset}"
                )
            offset += chunk
        position = max(position, start + length)


def _verify_variant(
    stock_disk: Path,
    variant_disk: Path,
    offset: int,
    size: int,
    partition: str,
    replacement: Path,
) -> None:
    """Check the variant disk against the stock disk and the replacement, byte for byte."""
    with stock_disk.open("rb") as stock, variant_disk.open("rb") as variant:
        stock_super = _Window(stock, offset, size)
        variant_super = _Window(variant, offset, size)
        metadata = lp.read_dynamic_partitions(stock_super, sparse=False)  # type: ignore[arg-type]
        if metadata is None:
            raise BundleVariantError("the stock super has no liblp metadata")
        if lp.read_dynamic_partitions(variant_super, sparse=False) != metadata:  # type: ignore[arg-type]
            raise BundleVariantError("the variant super's partition table differs from the stock")
        target = next(
            (item for item in metadata.logical_partitions if item.name == partition), None
        )
        if target is None:
            raise BundleVariantError(f"{partition}: the super has no such logical partition")
        excluded = [
            (offset + extent.target_data * SECTOR_SIZE, extent.size) for extent in target.extents
        ]
        _same_outside(stock, variant, stock_disk.stat().st_size, excluded)

        image_size = replacement.stat().st_size
        with replacement.open("rb") as image:
            for start in range(0, target.size, COMPARE_SIZE):
                length = min(COMPARE_SIZE, target.size - start)
                present = max(0, min(length, image_size - start))
                image.seek(start)
                expected = image.read(present) + bytes(length - present)
                actual = lp.read_partition_range(
                    variant_super,  # type: ignore[arg-type]
                    target,
                    start,
                    length,
                    sparse=False,
                )
                if actual != expected:
                    raise BundleVariantError(
                        f"{partition} does not read back the replacement at offset {start}"
                    )


def _read_inject_output(directory: Path, partition: str, build_id: str) -> Path:
    """Return the replacement that inject-vendor wrote for this build (its record is checked)."""
    record_path = directory / OUTPUT_RECORD
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BundleVariantError(f"{record_path} is not an inject-vendor record: {error}") from None
    partition_record = record.get("partition") if isinstance(record, dict) else None
    if not isinstance(partition_record, dict) or partition_record.get("name") != partition:
        raise BundleVariantError(f"{record_path} does not record the partition {partition}")
    if record.get("buildId") != build_id:
        raise BundleVariantError(
            f"{record_path} was made for build {record.get('buildId')}, not build {build_id}"
        )
    output = record.get("output")
    name = output.get("file") if isinstance(output, dict) else None
    recorded = output.get("sha256") if isinstance(output, dict) else None
    if not isinstance(name, str) or Path(name).name != name or not isinstance(recorded, str):
        raise BundleVariantError(f"{record_path} does not name its output file and SHA-256")
    path = directory / name
    if not path.is_file():
        raise BundleVariantError(f"{path} is missing")
    if _sha256(path) != recorded:
        raise BundleVariantError(f"{path} does not match the SHA-256 in {record_path}")
    return path


def build_variant(
    *,
    stock_bundle: Path,
    stock_super: Path,
    partition: str,
    replacement: Path,
    output: Path,
    sign_key: Path,
) -> dict[str, Any]:
    """Write the variant bundle `output` and its record beside it, and return the record.

    `stock_super` is the sparse super artifact that the stock bundle was built from. Nothing is
    written when a check fails, and an existing `output` or record is never replaced.
    """
    key = _load_signing_key(sign_key)
    public_key = key.public_key().public_bytes(encoding=Encoding.Raw, format=PublicFormat.Raw)
    output = output.expanduser()
    record_path = output.with_name(output.name + RECORD_SUFFIX)
    for path in (output, record_path):
        if path.exists() or path.is_symlink():
            raise BundleVariantError(f"{path}: the output already exists")
    if not replacement.is_file():
        raise BundleVariantError(f"{replacement} is not a file")

    manifest_bytes, manifest = _verify_stock(stock_bundle, public_key)
    disk, record = _super_record(manifest)
    disk_path = str(disk["path"])
    stock_disk = stock_bundle / disk_path
    super_offset, super_size = _super_location(stock_disk, disk, record)
    with stock_disk.open("rb") as stream:
        if _hash_range(stream, super_offset, super_size) != record["sha256"]:
            raise BundleVariantError(
                f"the super partition of {stock_disk} differs from its manifest entry"
            )

    with _staging(output) as stage:
        work = stage / "work"
        work.mkdir()
        expanded = _expanded_sha256(stock_super, super_size, work / "stock-super.raw")
        if expanded != record["sha256"]:
            raise BundleVariantError(
                f"{stock_super} does not expand to the super partition of {stock_bundle}"
            )

        variant_sparse = work / "variant-super.sparse"
        result = replace_partition(stock_super, partition, replacement, variant_sparse)

        bundle = stage / "bundle"
        for entry in manifest["files"]:
            target = bundle / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if entry["path"] == disk_path:
                _splice(stock_disk, variant_sparse, target, super_offset, super_size)
            else:
                shutil.copyfile(stock_bundle / entry["path"], target)
        variant_disk = bundle / disk_path
        _verify_variant(stock_disk, variant_disk, super_offset, super_size, partition, replacement)
        with variant_disk.open("rb") as stream:
            super_sha = _hash_range(stream, super_offset, super_size)

        files = [_file_entry(bundle, entry["path"]) for entry in manifest["files"]]
        by_path = {entry["path"]: entry for entry in files}
        variant_manifest: dict[str, Any] = json.loads(manifest_bytes)
        _super_record(variant_manifest)[1]["sha256"] = super_sha
        for name in BOOT_FILES:
            variant_manifest["boot"][name] = by_path[variant_manifest["boot"][name]["path"]]
        variant_manifest["files"] = files
        violations = validate(variant_manifest)
        if violations:
            first = violations[0]
            raise BundleVariantError(
                f"the variant manifest fails {first.rule} at {first.path}: {first.reason}"
            )
        new_bytes = (json.dumps(variant_manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        (bundle / MANIFEST_NAME).write_bytes(new_bytes)
        (bundle / CHECKSUMS_NAME).write_text(_checksums(files), encoding="ascii")
        signature = render_signature(new_bytes, key)
        (bundle / SIGNATURE_NAME).write_bytes(signature)
        verify_signature(new_bytes, signature, {key_id_of(public_key): public_key})

        record_out: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "task": TASK,
            "imageVersion": variant_manifest["imageVersion"],
            "kind": variant_manifest["kind"],
            "stockManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            "variantManifestSHA256": hashlib.sha256(new_bytes).hexdigest(),
            "signingKeyID": key_id_of(public_key),
            "partition": {
                "name": partition,
                "size": result.partition_size,
                "stockSuperSHA256": record["sha256"],
                "variantSuperSHA256": super_sha,
            },
            "replacement": {
                "sha256": _sha256(replacement),
                "size": replacement.stat().st_size,
            },
            "writer": {
                "imageSize": result.image_size,
                "physicalRanges": result.physical_ranges,
                "outputChunks": result.output_chunks,
                "metadataCopiesChecked": result.metadata_copies_checked,
                "partitionsCompared": result.partitions_compared,
            },
            "variantDiskSHA256": by_path[disk_path]["sha256"],
            "decisions": {
                "topLevelVbmeta": "not signed again (IR-650)",
                "partitionSize": "unchanged, the writer does not grow a partition (IR-682)",
                "identity": "stock imageVersion and kind kept (IR-700)",
                "manifestSignature": "developer image key, trusted by Debug builds",
            },
        }
        (stage / RECORD_NAME).write_text(
            json.dumps(record_out, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        # The record is linked first, because a link fails on an existing name. The bundle is
        # then renamed into place, and if that fails the record is removed again.
        try:
            os.link(stage / RECORD_NAME, record_path)
        except FileExistsError:
            raise BundleVariantError(f"{record_path}: the output already exists") from None
        try:
            if output.exists() or output.is_symlink():
                raise BundleVariantError(f"{output}: the output already exists")
            os.replace(bundle, output)
        except BaseException:
            record_path.unlink(missing_ok=True)
            raise
    return record_out


def build_parser() -> argparse.ArgumentParser:
    """Build the bundle-variant command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image bundle-variant",
        description="Build a development bundle whose super carries a replaced partition (#099).",
    )
    parser.add_argument("--bundle", required=True, type=Path, help="the stock bundle to copy")
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="the Android image manifest that the stock bundle was built from",
    )
    parser.add_argument("--source", type=Path, help="source archive or directory")
    parser.add_argument(
        "--inject-output",
        required=True,
        type=Path,
        help="the output directory of inject-vendor (the replacement and inject.json)",
    )
    parser.add_argument("--partition", default="vendor_a", help="logical partition to replace")
    parser.add_argument(
        "--sign-key",
        required=True,
        type=Path,
        help="Ed25519 private key of the stock bundle (python3 -m apkrun_image keygen)",
    )
    parser.add_argument("--out", required=True, type=Path, help="new bundle directory")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Build the variant and report actionable failures."""
    arguments = build_parser().parse_args(argv)
    try:
        document = _load_json(arguments.manifest, description="manifest")
        if not isinstance(document, dict):
            raise BundleVariantError("manifest: top level must be an object.")
        source = document.get("source")
        build_id = source.get("buildId") if isinstance(source, dict) else None
        if not isinstance(build_id, str):
            raise BundleVariantError("manifest source.buildId is missing.")
        replacement = _read_inject_output(arguments.inject_output, arguments.partition, build_id)
        root = _resolve_archive_root(document, source=arguments.source)
        archives = _archive_paths(root, document["source"]["archives"])
        artifact = _role_artifact(document, "super")
        output = arguments.out.expanduser()
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".apkrun-bundle-variant-", dir=output.parent
        ) as scratch:
            stock_super = Path(scratch) / "stock-super.sparse"
            with (
                _open_artifact(document, root, archives, artifact) as source,
                stock_super.open("wb") as target,
            ):
                shutil.copyfileobj(source, target, COPY_SIZE)
            build_variant(
                stock_bundle=arguments.bundle,
                stock_super=stock_super,
                partition=arguments.partition,
                replacement=replacement,
                output=output,
                sign_key=arguments.sign_key,
            )
    except (
        BundleError,
        BundleVariantError,
        DisksError,
        ExtractError,
        GptError,
        LpMetadataError,
        LpWriteError,
        ManifestError,
        SignatureError,
        SparseImageError,
        OSError,
    ) as error:
        print(f"apkrun_image bundle-variant: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
