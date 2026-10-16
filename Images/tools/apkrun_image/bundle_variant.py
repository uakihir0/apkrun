"""Build a development bundle whose super carries a replaced logical partition (#099).

The variant is the stock bundle with one logical partition of its `super` replaced and, when a
reseal output is given, the GPT partition `vbmeta_a` replaced by the refreshed vbmeta signed with
the stock-matching AOSP test key (IR-1321).
The stock bundle is read and never changed:

1. The stock bundle is checked first: its manifest validates, every file matches its entry,
   `SHA256SUMS` matches, `manifest.sig` verifies with the signing key, and the super partition
   of `os.img` hashes to its entry. The stock super artifact of the Android image manifest must
   expand to the same bytes, so the variant is the stock super with one partition replaced.
2. `lp_write.replace_partition` writes the replaced super as a sparse image (IR-680).
3. The expanded super is spliced into a new copy of `os.img` at the partition's offset in the
   GPT. The other bytes of the disk and the other files are copied.
4. The copy is checked against the stock bytes. Every byte outside the replaced extents is
   equal, and the partition reads back as the replacement followed by zeros.
5. The refreshed vbmeta is checked against the verified stock disk range: its signature, key,
   rollback settings, every non-vendor descriptor, and public-key metadata must match the stock
   vbmeta except for the replaced vendor descriptor.
6. The file entries, the super partition hash, `SHA256SUMS`, and `manifest.sig` are made by the
   bundle module's own functions. The manifest is validated (runtime-image-manifest.md §5, §6).

The caller supplies a distinct short image version. The builder combines it with the unchanged
source build identity to give the variant its own `imageVersion`, while preserving the stock
`kind` and signed provenance (IR-1322). Its top-level vbmeta is signed with the stock-matching AOSP
test key (IR-1321) when it is refreshed, and remains the stock vbmeta otherwise (IR-650). The AOSP
key is accepted only for `kind: stock` development bundles. No partition changes size (IR-682).
`manifest.sig` is made with the developer image key, which Debug builds trust. The record next to
the bundle names every input and output, and it is outside the bundle, because the bundle lists
its own files.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from collections.abc import Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from apkrun_image import lp, vendor_reseal
from apkrun_image.avb import (
    VBMETA_HEADER_SIZE,
    AvbError,
    HashUpdater,
    _chain_partitions,
    _read_vbmeta,
    calculate_vbmeta_bootconfig,
)
from apkrun_image.bundle import (
    SHORT_VERSION_PATTERN,
    BundleError,
    _checksums,
    _file_entry,
    _load_signing_key,
    _sha256,
    _staging,
)
from apkrun_image.disks import DisksError, _hash_range
from apkrun_image.erofs import load_component
from apkrun_image.extract import ExtractError, _open_artifact, _role_artifact
from apkrun_image.gpt import SECTOR_SIZE, GptError, read_gpt
from apkrun_image.lp import LpMetadataError
from apkrun_image.lp_write import LpWriteError, replace_partition
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _repository_root,
    _resolve_archive_root,
)
from apkrun_image.runtime_manifest import load_and_validate, validate
from apkrun_image.sign import SignatureError, key_id_of, render_signature, verify_signature
from apkrun_image.sparse import SparseImageError, expand_into, write_skipping_zeros
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    OUTPUT_RECORD,
    run_avbtool,
    verify_avbtool,
)

SCHEMA_VERSION = 3
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
VBMETA_LABEL = "vbmeta_a"
BOOTCONFIG_DIGEST = "androidboot.vbmeta.digest"
BOOTCONFIG_SIZE = "androidboot.vbmeta.size"


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


def _copy_range(
    source: BinaryIO,
    out: BinaryIO,
    start: int,
    end: int,
    *,
    source_digest: HashUpdater | None = None,
) -> None:
    """Copy `source` between two offsets and optionally hash the exact source bytes."""
    offset = start
    while offset < end:
        length = min(COPY_SIZE, end - offset)
        source.seek(offset)
        data = source.read(length)
        if len(data) != length:
            raise BundleVariantError(f"the stock disk ends before offset {offset + length}")
        if source_digest is not None:
            source_digest.update(data)
        write_skipping_zeros(out, offset, data)
        offset += length


def _hash_source_range(
    source: BinaryIO,
    digest: HashUpdater,
    start: int,
    end: int,
    *,
    range_digest: HashUpdater | None = None,
) -> None:
    """Hash a source range without copying it to the output."""
    offset = start
    while offset < end:
        length = min(COPY_SIZE, end - offset)
        source.seek(offset)
        data = source.read(length)
        if len(data) != length:
            raise BundleVariantError(f"the stock disk ends before offset {offset + length}")
        digest.update(data)
        if range_digest is not None:
            range_digest.update(data)
        offset += length


def _splice(
    stock_disk: Path,
    sparse: Path,
    destination: Path,
    offset: int,
    size: int,
    *,
    expected_disk_sha256: str,
    expected_super_sha256: str,
) -> None:
    """Write the replacement super and verify the exact stock bytes read during the copy."""
    total = stock_disk.stat().st_size
    disk_digest = hashlib.sha256()
    super_digest = hashlib.sha256()
    with stock_disk.open("rb") as source, destination.open("w+b") as out:
        out.truncate(total)
        _copy_range(source, out, 0, offset, source_digest=disk_digest)
        _hash_source_range(source, disk_digest, offset, offset + size, range_digest=super_digest)
        _copy_range(source, out, offset + size, total, source_digest=disk_digest)
        with sparse.open("rb") as stream:
            header = expand_into(stream, out, offset)
        if header.logical_size != size:
            raise BundleVariantError(
                f"the replaced super expands to {header.logical_size} bytes, not {size}"
            )
        if disk_digest.hexdigest() != expected_disk_sha256:
            raise BundleVariantError(f"{stock_disk} changed after its stock manifest was checked")
        if super_digest.hexdigest() != expected_super_sha256:
            raise BundleVariantError(
                f"the super partition of {stock_disk} changed after its manifest was checked"
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
    extra: Sequence[tuple[int, bytes]] = (),
    expected_replacement_sha256: str | None = None,
) -> None:
    """Check the variant disk against the stock disk and the replacement, byte for byte.

    `extra` lists the other ranges that the variant replaces (the refreshed `vbmeta_a`), and each
    must read back as its bytes. Every other byte of the disk must equal the stock disk (IR-746).
    """
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
        excluded += [(start, len(data)) for start, data in extra]
        _same_outside(stock, variant, stock_disk.stat().st_size, excluded)
        for start, data in extra:
            variant.seek(start)
            if variant.read(len(data)) != data:
                raise BundleVariantError(f"the variant disk does not hold the bytes at {start}")

        image_size = replacement.stat().st_size
        embedded_digest = hashlib.sha256() if expected_replacement_sha256 is not None else None
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
                if embedded_digest is not None:
                    embedded_digest.update(actual)
        if (
            embedded_digest is not None
            and embedded_digest.hexdigest() != expected_replacement_sha256
        ):
            raise BundleVariantError(
                f"the embedded {partition} differs from its checked AVB snapshot"
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


@dataclass(frozen=True)
class _Refresh:
    """The checked injection, resealed vendor, refreshed vbmeta, and input records."""

    injected: Path
    vendor: Path
    vbmeta: Path
    record: dict[str, Any]
    inject_record_sha256: str
    record_sha256: str
    record_path: Path


def _load_record_snapshot(path: Path) -> tuple[dict[str, Any], str]:
    try:
        data = path.read_bytes()
        record = json.loads(data.decode("utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise BundleVariantError(f"{path} is not a JSON record: {error}") from None
    if not isinstance(record, dict):
        raise BundleVariantError(f"{path} is not a JSON object")
    return record, hashlib.sha256(data).hexdigest()


def _load_record(path: Path) -> dict[str, Any]:
    return _load_record_snapshot(path)[0]


def _refresh_record_hashes(refresh: _Refresh) -> dict[str, str]:
    """Return the hashes captured while the input records were validated."""
    return {
        "injectRecordSHA256": refresh.inject_record_sha256,
        "resealRecordSHA256": refresh.record_sha256,
    }


def _builder_provenance(repository_root: Path | None = None) -> dict[str, Any]:
    """Identify the committed and local Images/tools source used to write a variant."""
    repository = repository_root or Path(__file__).resolve().parents[3]

    def git(*arguments: str) -> bytes:
        try:
            return subprocess.run(
                ["git", "-C", str(repository), *arguments],
                check=True,
                capture_output=True,
            ).stdout
        except subprocess.CalledProcessError as error:
            detail = (
                error.stderr.decode("utf-8", errors="replace").strip()
                if error.stderr
                else str(error)
            )
            raise BundleVariantError(
                f"cannot record Images/tools builder provenance: {detail}"
            ) from None
        except OSError as error:
            raise BundleVariantError(
                f"cannot record Images/tools builder provenance: {error}"
            ) from None

    revision = git("rev-parse", "HEAD").decode("ascii", errors="strict").strip()
    tracked_diff = git("diff", "--binary", "--no-ext-diff", "HEAD", "--", "Images/tools")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--", "Images/tools").split(
        b"\0"
    )

    digest = hashlib.sha256()
    digest.update(b"APKRun Images/tools builder source v1\0")
    digest.update(revision.encode("ascii"))
    digest.update(b"\0")
    digest.update(tracked_diff)
    for relative in sorted(value for value in untracked if value):
        path = repository / os.fsdecode(relative)
        if path.is_symlink() or not path.is_file():
            raise BundleVariantError(f"cannot record Images/tools builder source file: {path}")
        try:
            content = path.read_bytes()
        except OSError as error:
            raise BundleVariantError(
                f"cannot read Images/tools builder source file {path}: {error}"
            ) from None
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)

    return {
        "repository": "Images/tools",
        "gitRevision": revision,
        "sourceSHA256": digest.hexdigest(),
        "workingTreeClean": not tracked_diff and not any(untracked),
    }


def _section(document: Mapping[str, Any], key: str, path: Path) -> dict[str, Any]:
    """Return the object under `key` of a record, and refuse the record when it is not one."""
    value = document.get(key)
    if not isinstance(value, dict):
        raise BundleVariantError(f"{path} has no {key} object")
    return value


def _text(value: object) -> str | None:
    """Return `value` when it is a non-empty string, so two missing fields never compare equal."""
    return value if isinstance(value, str) and value else None


def _read_reseal_output(
    directory: Path,
    *,
    inject_directory: Path,
    partition: str,
    build_id: str,
    injected_image: Path | None = None,
) -> _Refresh:
    """Return the resealed vendor and the refreshed vbmeta of `vendor-reseal` for this inject.

    The record must name the injected image (by its SHA-256, as inject.json records it) and the
    stock vendor, and each file must match its recorded SHA-256. The descriptor in the refreshed
    vbmeta must be the one of the resealed vendor image, read with the vendored avbtool (IR-746).
    """
    record_path = directory / vendor_reseal.OUTPUT_RECORD
    record, record_sha256 = _load_record_snapshot(record_path)
    if record.get("task") != TASK or record.get("schemaVersion") != vendor_reseal.SCHEMA_VERSION:
        raise BundleVariantError(f"{record_path} is not a #099 vendor-reseal record")
    if _section(record, "partition", record_path).get("name") != partition:
        raise BundleVariantError(f"{record_path} does not record the partition {partition}")
    inject_path = inject_directory / OUTPUT_RECORD
    inject_record, inject_record_sha256 = _load_record_snapshot(inject_path)
    if inject_record.get("buildId") != build_id:
        raise BundleVariantError(f"{inject_directory} was not made for build {build_id}")
    if injected_image is None:
        injected_image = _read_inject_output(inject_directory, partition, build_id)
    injected = _section(record, "injected", record_path)
    stock = _section(record, "stock", record_path)
    inject_output = _section(inject_record, "output", inject_path)
    inject_stock = _section(inject_record, "stock", inject_path)
    if _text(injected.get("sha256")) is None or (
        injected.get("sha256") != inject_output.get("sha256")
    ):
        raise BundleVariantError(f"{record_path} was not made from this inject-vendor output")
    if _text(inject_output.get("sha256")) is None or (
        _sha256(injected_image) != inject_output["sha256"]
    ):
        raise BundleVariantError(f"{inject_path} no longer matches its checked injection output")
    if _text(stock.get("vendorSha256")) is None or (
        stock.get("vendorSha256") != inject_stock.get("sha256")
    ):
        raise BundleVariantError(f"{record_path} names another stock vendor_a")

    files: dict[str, Path] = {}
    entries: dict[str, dict[str, Any]] = {}
    for role, file_name in (
        ("vendor", vendor_reseal.OUTPUT_IMAGE),
        ("vbmeta", vendor_reseal.OUTPUT_VBMETA),
    ):
        entry = _section(record, role, record_path)
        if entry.get("file") != file_name:
            raise BundleVariantError(f"{record_path} does not name its {role} file {file_name}")
        path = directory / file_name
        if not path.is_file():
            raise BundleVariantError(f"{path} is missing")
        if _text(entry.get("sha256")) is None or _sha256(path) != entry["sha256"]:
            raise BundleVariantError(f"{path} does not match the SHA-256 in {record_path}")
        files[role] = path
        entries[role] = entry
    if entries["vbmeta"].get("algorithm") != vendor_reseal.VBMETA_ALGORITHM:
        raise BundleVariantError(
            f"{record_path} does not name a vbmeta signed with {vendor_reseal.VBMETA_ALGORITHM}"
        )
    if (
        entries["vbmeta"].get("signer") != vendor_reseal.VBMETA_SIGNER
        or entries["vbmeta"].get("publicKeySha1") != vendor_reseal.VBMETA_PUBLIC_KEY_SHA1
    ):
        raise BundleVariantError(
            f"{record_path} does not record the pinned AOSP AVB development signing key"
        )
    avbtool = verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))
    try:
        vendor_reseal.verify_vbmeta_signature(avbtool, files["vbmeta"])
    except (ValueError, OSError) as error:
        raise BundleVariantError(
            f"{files['vbmeta']}: signature verification failed: {error}"
        ) from None
    try:
        vendor_descriptor = vendor_reseal.vendor_tree(
            run_avbtool(avbtool, ["info_image", "--image", str(files["vendor"])]),
            "the resealed vendor_a",
        )
        vbmeta_info = run_avbtool(avbtool, ["info_image", "--image", str(files["vbmeta"])])
        vbmeta_descriptor = vendor_reseal.vendor_tree(vbmeta_info, "the refreshed vbmeta_a")
        vbmeta_top = vendor_reseal.parse_top(vbmeta_info)
    except (ValueError, OSError) as error:
        raise BundleVariantError(f"{record_path}: the descriptors do not read: {error}") from None
    if (
        vbmeta_top.get("Algorithm") != vendor_reseal.VBMETA_ALGORITHM
        or vbmeta_top.get("Public key (sha1)", "").lower() != vendor_reseal.VBMETA_PUBLIC_KEY_SHA1
    ):
        raise BundleVariantError(
            f"{files['vbmeta']} is not signed with the pinned AOSP AVB development key"
        )
    if vbmeta_descriptor != vendor_descriptor:
        raise BundleVariantError(
            "the refreshed vbmeta_a does not carry the descriptor of the resealed vendor_a"
        )
    if entries["vendor"].get("descriptor") != vendor_descriptor:
        raise BundleVariantError(f"{record_path} does not describe its vendor_a")
    if entries["vbmeta"].get("vendorDescriptor") != vendor_descriptor:
        raise BundleVariantError(
            f"{record_path} does not describe the vendor descriptor of its vbmeta_a"
        )
    return _Refresh(
        injected=injected_image,
        vendor=files["vendor"],
        vbmeta=files["vbmeta"],
        record=record,
        inject_record_sha256=inject_record_sha256,
        record_sha256=record_sha256,
        record_path=record_path,
    )


def _gpt_partitions(stock_disk: Path, logical_size: int) -> dict[str, tuple[int, int]]:
    """Return the byte offset and size of every GPT partition of a disk, by label."""
    with stock_disk.open("rb") as stream:
        table = read_gpt(stream, logical_size)
    return {item.label: (item.first_lba * SECTOR_SIZE, item.size) for item in table.partitions}


def _bootconfig_values(
    stream: BinaryIO, layout: Mapping[str, tuple[int, int]], vbmeta: bytes
) -> dict[str, str]:
    """Return the digest and size of the vbmeta chain, as calculate_vbmeta_bootconfig gives them.

    `vbmeta` is the top-level vbmeta partition. Its chained partitions are read from `stream` at
    the offsets of `layout`, in the order of the top-level descriptors. The digest and the size
    are the ones of avb.py, so the variant and the Android manifest agree (IR-747).
    """
    try:
        header, _offset = _read_vbmeta(
            io.BytesIO(vbmeta), artifact_size=len(vbmeta), artifact_name=VBMETA_LABEL
        )
        chained = _chain_partitions(
            io.BytesIO(vbmeta), header=header, vbmeta_offset=0, artifact_name=VBMETA_LABEL
        )
    except AvbError as error:
        raise BundleVariantError(f"the top-level vbmeta does not read: {error}") from None
    artifacts: list[dict[str, Any]] = [
        {
            "id": "vbmeta",
            "partition": "vbmeta",
            "kind": "vbmeta",
            "file": VBMETA_LABEL,
            "size": len(vbmeta),
        }
    ]
    role_ids = ["vbmeta"]
    for name in chained:
        label = f"{name}_a"
        if label not in layout:
            raise BundleVariantError(f"the disk has no {label}, which the vbmeta chains")
        # A chained vbmeta_* partition is a raw vbmeta; the others carry a footer (IR-747).
        kind = "vbmeta" if name.startswith("vbmeta") else "image"
        artifacts.append(
            {
                "id": name,
                "partition": name,
                "kind": kind,
                "file": label,
                "size": layout[label][1],
            }
        )
        if kind == "vbmeta":
            role_ids.append(name)
    document = {"roles": {"vbmeta": role_ids}, "artifacts": artifacts}

    @contextmanager
    def open_artifact(artifact: Mapping[str, Any]) -> Iterator[BinaryIO]:
        if artifact["partition"] == "vbmeta":
            yield io.BytesIO(vbmeta)
            return
        base, size = layout[f"{artifact['partition']}_a"]
        yield _Window(stream, base, size)

    try:
        values = calculate_vbmeta_bootconfig(document, open_artifact)
    except AvbError as error:
        raise BundleVariantError(f"the vbmeta chain does not read: {error}") from None
    return {
        BOOTCONFIG_DIGEST: values[BOOTCONFIG_DIGEST],
        BOOTCONFIG_SIZE: values[BOOTCONFIG_SIZE],
    }


def _bootconfig_line(key: str) -> re.Pattern[str]:
    """Match the quoted value of `key` on its own line; the newline is never part of the match."""
    return re.compile(rf'^({re.escape(key)} = ")([^"\n]*)(")([ \t]*)$', re.MULTILINE)


def _read_bootconfig_values(text: str, keys: Sequence[str]) -> dict[str, str]:
    """Return the quoted value of each key, which must appear on exactly one line."""
    values: dict[str, str] = {}
    for key in keys:
        found = _bootconfig_line(key).findall(text)
        if len(found) != 1:
            raise BundleVariantError(f"the bootconfig has {len(found)} lines for {key}, not one")
        values[key] = found[0][1]
    return values


def _with_bootconfig_values(text: str, values: Mapping[str, str]) -> str:
    """Return the bootconfig text with the quoted value of each key replaced, and nothing else."""
    for key, value in values.items():
        text, count = _bootconfig_line(key).subn(
            lambda match, value=value: f"{match.group(1)}{value}{match.group(3)}{match.group(4)}",
            text,
        )
        if count != 1:
            raise BundleVariantError(f"the bootconfig has {count} lines for {key}, not one")
    return text


def _read_text(path: Path) -> str:
    """Read a bootconfig file as UTF-8, and refuse it when it does not read."""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise BundleVariantError(f"{path} does not read as UTF-8 text: {error}") from None


def _read_range(stream: BinaryIO, offset: int, size: int) -> bytes:
    """Read exactly `size` bytes at `offset` of a disk."""
    stream.seek(offset)
    data = stream.read(size)
    if len(data) != size:
        raise BundleVariantError(f"the disk ends inside the range at {offset}")
    return data


def _raw_vbmeta_descriptors(
    image: Path,
) -> tuple[bytes, list[tuple[int, str | None, bytes]], int, int]:
    """Return the exact header and bounded descriptors from raw or footer-backed vbmeta."""
    try:
        with image.open("rb") as stream:
            header, vbmeta_offset = _read_vbmeta(
                stream,
                artifact_size=image.stat().st_size,
                artifact_name=str(image),
            )
            stream.seek(vbmeta_offset)
            header_bytes = stream.read(VBMETA_HEADER_SIZE)
            if len(header_bytes) != VBMETA_HEADER_SIZE:
                raise BundleVariantError(f"{image} has a truncated vbmeta header")
            descriptor_offset = (
                vbmeta_offset
                + VBMETA_HEADER_SIZE
                + header.authentication_size
                + header.descriptors_offset
            )
            stream.seek(descriptor_offset)
            table = stream.read(header.descriptors_size)
    except (AvbError, OSError, struct.error) as error:
        raise BundleVariantError(f"{image} has invalid vbmeta descriptors: {error}") from None
    if len(table) != header.descriptors_size:
        raise BundleVariantError(f"{image} has a truncated vbmeta descriptor table")

    descriptors: list[tuple[int, str | None, bytes]] = []
    offset = 0
    while offset < len(table):
        if len(table) - offset < 16:
            raise BundleVariantError(f"{image} has a truncated AVB descriptor header")
        tag, following_size = struct.unpack_from(">QQ", table, offset)
        end = offset + 16 + following_size
        if following_size % 8 or end > len(table):
            raise BundleVariantError(f"{image} has an invalid AVB descriptor size")
        encoded = table[offset:end]
        partition_name: str | None = None
        if tag == 1:
            # AvbHashtreeDescriptor: the fixed structure is 180 bytes including
            # its generic descriptor header; the partition name follows it.
            if len(encoded) < 180:
                raise BundleVariantError(f"{image} has a truncated hashtree descriptor")
            name_size = struct.unpack_from(">I", encoded, 104)[0]
            if name_size > len(encoded) - 180:
                raise BundleVariantError(f"{image} has an invalid hashtree partition name")
            try:
                partition_name = encoded[180 : 180 + name_size].decode("utf-8")
            except UnicodeDecodeError:
                raise BundleVariantError(
                    f"{image} has a non-UTF-8 hashtree partition name"
                ) from None
        descriptors.append((tag, partition_name, encoded))
        offset = end
    return header_bytes, descriptors, vbmeta_offset, header.blob_size


def _verify_refreshed_vbmeta_matches_stock(
    avbtool: Path,
    stock_vbmeta: Path,
    refreshed_vbmeta: Path,
    refreshed_vendor: Path,
    injected_vendor: Path,
) -> None:
    """Verify staged AVB data and require vbmeta to differ only in its vendor descriptor."""
    try:
        stock_metadata = vendor_reseal.verify_vbmeta_signature(avbtool, stock_vbmeta)
        refreshed_metadata = vendor_reseal.verify_vbmeta_signature(avbtool, refreshed_vbmeta)
        stock_info = run_avbtool(avbtool, ["info_image", "--image", str(stock_vbmeta)])
        refreshed_info = run_avbtool(avbtool, ["info_image", "--image", str(refreshed_vbmeta)])
        stock_top = vendor_reseal.parse_top(stock_info)
        refreshed_top = vendor_reseal.parse_top(refreshed_info)
        stock_header, stock_descriptors, _stock_offset, _stock_blob_size = _raw_vbmeta_descriptors(
            stock_vbmeta
        )
        (
            refreshed_header,
            refreshed_descriptors,
            refreshed_offset,
            refreshed_blob_size,
        ) = _raw_vbmeta_descriptors(refreshed_vbmeta)
        _vendor_header, vendor_descriptors, _vendor_offset, _vendor_blob_size = (
            _raw_vbmeta_descriptors(refreshed_vendor)
        )
        _injected_header, injected_descriptors, _injected_offset, _injected_blob_size = (
            _raw_vbmeta_descriptors(injected_vendor)
        )
        refreshed_vendor_descriptors = [
            descriptor
            for tag, name, descriptor in refreshed_descriptors
            if tag == 1 and name == vendor_reseal.PARTITION
        ]
        image_vendor_descriptors = [
            descriptor
            for tag, name, descriptor in vendor_descriptors
            if tag == 1 and name == vendor_reseal.PARTITION
        ]
        injected_vendor_descriptors = [
            descriptor
            for tag, name, descriptor in injected_descriptors
            if tag == 1 and name == vendor_reseal.PARTITION
        ]
        if (
            len(refreshed_vendor_descriptors) != 1
            or len(image_vendor_descriptors) != 1
            or len(injected_vendor_descriptors) != 1
        ):
            raise BundleVariantError(
                "the refreshed vbmeta, resealed vendor, and checked inject output must each "
                "carry exactly one vendor descriptor"
            )
        if refreshed_vendor_descriptors != image_vendor_descriptors:
            raise BundleVariantError(
                f"the refreshed {VBMETA_LABEL} does not carry the exact descriptor "
                "of its resealed vendor_a"
            )
        if image_vendor_descriptors != injected_vendor_descriptors:
            raise BundleVariantError(
                "the resealed vendor_a does not carry the exact descriptor of the checked "
                "inject-vendor output"
            )
        refreshed_vendor_tree, refreshed_original_size = _verify_vendor_hashtree(
            avbtool, refreshed_vendor
        )
        _injected_vendor_tree, injected_original_size = _verify_vendor_hashtree(
            avbtool, injected_vendor
        )
    except BundleVariantError:
        raise
    except (ValueError, OSError) as error:
        raise BundleVariantError(
            f"stock or refreshed {VBMETA_LABEL} failed AVB verification: {error}"
        ) from None

    if (
        stock_top.get("Algorithm") != vendor_reseal.VBMETA_ALGORITHM
        or stock_top.get("Public key (sha1)", "").lower() != vendor_reseal.VBMETA_PUBLIC_KEY_SHA1
    ):
        raise BundleVariantError(
            f"stock {VBMETA_LABEL} is not signed with the pinned AOSP AVB development key"
        )
    if (
        refreshed_top.get("Algorithm") != vendor_reseal.VBMETA_ALGORITHM
        or refreshed_top.get("Public key (sha1)", "").lower()
        != vendor_reseal.VBMETA_PUBLIC_KEY_SHA1
    ):
        raise BundleVariantError(
            f"refreshed {VBMETA_LABEL} is not signed with the pinned AOSP AVB development key"
        )
    if refreshed_header != stock_header:
        raise BundleVariantError(f"the refreshed {VBMETA_LABEL} changed stock AVB header fields")
    if refreshed_metadata != stock_metadata:
        raise BundleVariantError(f"the refreshed {VBMETA_LABEL} changed stock public-key metadata")
    if refreshed_offset != 0:
        raise BundleVariantError(f"the refreshed {VBMETA_LABEL} is not a raw vbmeta partition")
    if _has_nonzero_bytes(refreshed_vbmeta, refreshed_blob_size):
        raise BundleVariantError(
            f"the refreshed {VBMETA_LABEL} has nonzero bytes after its vbmeta blob"
        )

    stock_vendor_indexes = [
        index
        for index, (tag, name, _descriptor) in enumerate(stock_descriptors)
        if tag == 1 and name == vendor_reseal.PARTITION
    ]
    refreshed_vendor_indexes = [
        index
        for index, (tag, name, _descriptor) in enumerate(refreshed_descriptors)
        if tag == 1 and name == vendor_reseal.PARTITION
    ]
    stock_vendor = [
        descriptor
        for tag, name, descriptor in stock_descriptors
        if tag == 1 and name == vendor_reseal.PARTITION
    ]
    if len(stock_vendor) != 1 or len(refreshed_vendor_descriptors) != 1:
        raise BundleVariantError(
            "stock and refreshed vbmeta images must carry exactly one vendor descriptor"
        )
    if stock_vendor_indexes != refreshed_vendor_indexes:
        raise BundleVariantError(f"the refreshed {VBMETA_LABEL} moved the vendor descriptor")
    if refreshed_original_size != injected_original_size:
        raise BundleVariantError(
            "the resealed and injected vendor images have different original image sizes"
        )
    if not _same_file_prefix(refreshed_vendor, injected_vendor, refreshed_original_size):
        raise BundleVariantError(
            "the resealed vendor data differs from the checked inject-vendor output"
        )
    stock_others = [
        descriptor
        for descriptor in stock_descriptors
        if not (descriptor[0] == 1 and descriptor[1] == vendor_reseal.PARTITION)
    ]
    refreshed_others = [
        descriptor
        for descriptor in refreshed_descriptors
        if not (descriptor[0] == 1 and descriptor[1] == vendor_reseal.PARTITION)
    ]
    if stock_others != refreshed_others:
        raise BundleVariantError(
            f"the refreshed {VBMETA_LABEL} changed a descriptor other than the vendor one"
        )


def _has_nonzero_bytes(image: Path, offset: int) -> bool:
    """Return whether the bytes after `offset` in an image contain anything but zero padding."""
    with image.open("rb") as stream:
        stream.seek(offset)
        while chunk := stream.read(COPY_SIZE):
            if any(chunk):
                return True
    return False


def _verify_vendor_hashtree(avbtool: Path, image: Path) -> tuple[dict[str, Any], int]:
    """Verify the footer and hashtree of one vendor image using the vendored avbtool."""
    info = run_avbtool(avbtool, ["info_image", "--image", str(image)])
    top = vendor_reseal.parse_top(info)
    tree = vendor_reseal.vendor_tree(info, f"{image}")
    if top.get("Algorithm") != vendor_reseal.ALGORITHM:
        raise BundleVariantError(f"{image} does not use the expected unsigned vendor footer")
    original_size = vendor_reseal._original_size(info, str(image))
    if original_size < 0 or original_size > image.stat().st_size:
        raise BundleVariantError(f"{image} has an invalid original image size")
    if tree["imageSize"] != original_size:
        raise BundleVariantError(f"{image} has a hashtree for another original image size")
    if tree["fecRoots"] != 0:
        raise BundleVariantError(f"{image} has unexpected FEC data")

    try:
        with tempfile.TemporaryDirectory(
            prefix=".apkrun-verify-vendor-", dir=image.parent
        ) as temporary:
            link = Path(temporary) / f"{vendor_reseal.PARTITION}.part"
            link.symlink_to(image.resolve())
            verified = run_avbtool(avbtool, ["verify_image", "--image", str(link)])
    except (OSError, ValueError) as error:
        raise BundleVariantError(f"{image}: AVB hashtree verification failed: {error}") from None
    success = f"Successfully verified {tree['hashAlgorithm']} hashtree of "
    if success not in verified:
        raise BundleVariantError(f"{image}: avbtool did not verify its hashtree")
    return tree, original_size


def _same_file_prefix(first: Path, second: Path, size: int) -> bool:
    """Return whether two files have identical bytes in their first `size` bytes."""
    if size < 0 or first.stat().st_size < size or second.stat().st_size < size:
        return False
    with first.open("rb") as first_stream, second.open("rb") as second_stream:
        remaining = size
        while remaining:
            length = min(COPY_SIZE, remaining)
            if first_stream.read(length) != second_stream.read(length):
                return False
            remaining -= length
    return True


def _write_range(path: Path, offset: int, data: bytes) -> None:
    """Write `data` into an existing file at `offset`, and flush it to the disk."""
    with path.open("r+b") as handle:
        handle.seek(offset)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def _disk_partition(manifest: Mapping[str, Any], label: str) -> dict[str, Any]:
    """Return the manifest record of the GPT partition `label` of the OS disk."""
    for disk in manifest["disks"]:
        for partition in disk["partitions"]:
            if partition["label"] == label:
                return partition
    raise BundleVariantError(f"the stock manifest has no {label} partition")


def build_variant(
    *,
    stock_bundle: Path,
    stock_super: Path,
    partition: str,
    replacement: Path,
    image_version: str,
    output: Path,
    sign_key: Path,
    refresh: _Refresh | None = None,
) -> dict[str, Any]:
    """Write the variant bundle `output` and its record beside it, and return the record.

    `stock_super` is the sparse super artifact that the stock bundle was built from. With `refresh`
    the variant also replaces `vbmeta_a` with the refreshed top-level vbmeta, and it recomputes the
    bootconfig's vbmeta values (IR-746, IR-747). Without it the vbmeta is the stock one, so the
    replaced vendor partition does not verify (IR-650). `image_version` is the short `YYYY.MM.N`
    sequence used to make a distinct full identity while retaining source provenance (IR-1322).
    Nothing is written when a check fails, and an existing `output` or record is never replaced.
    """
    if not SHORT_VERSION_PATTERN.fullmatch(image_version):
        raise BundleVariantError("--image-version must be the short form YYYY.MM.N")
    key = _load_signing_key(sign_key)
    public_key = key.public_key().public_bytes(encoding=Encoding.Raw, format=PublicFormat.Raw)
    output = output.expanduser()
    record_path = output.with_name(output.name + RECORD_SUFFIX)
    for path in (output, record_path):
        if path.exists() or path.is_symlink():
            raise BundleVariantError(f"{path}: the output already exists")
    if not replacement.is_file():
        raise BundleVariantError(f"{replacement} is not a file")
    builder = _builder_provenance()

    manifest_bytes, manifest = _verify_stock(stock_bundle, public_key)
    variant_manifest: dict[str, Any] = json.loads(manifest_bytes)
    source = variant_manifest["provenance"]["source"]
    base = f"cf{source['buildId']}" if source["origin"] == "ci.android.com" else source["buildId"]
    variant_manifest["imageVersion"] = f"{image_version}-{base}-arm64"
    if variant_manifest["imageVersion"] == manifest["imageVersion"]:
        raise BundleVariantError(
            "--image-version must produce an imageVersion distinct from the stock bundle"
        )
    identity_violations = validate(variant_manifest)
    if identity_violations:
        first = identity_violations[0]
        raise BundleVariantError(
            f"the variant identity fails {first.rule} at {first.path}: {first.reason}"
        )
    if refresh is not None and manifest.get("kind") != "stock":
        raise BundleVariantError(
            "the AOSP AVB test key can refresh vbmeta only in a kind: stock development bundle"
        )
    disk, record = _super_record(manifest)
    disk_path = str(disk["path"])
    stock_disk = stock_bundle / disk_path
    super_offset, super_size = _super_location(stock_disk, disk, record)
    layout = _gpt_partitions(stock_disk, disk["logicalSize"])
    bootconfig_path = str(manifest["boot"]["bootconfig"]["path"])
    vbmeta_offset = vbmeta_size = 0
    vbmeta_bytes: bytes | None = None
    stock_vbmeta_bytes: bytes | None = None
    expected_replacement_sha256: str | None = None
    if refresh is not None:
        if VBMETA_LABEL not in layout:
            raise BundleVariantError(f"the stock disk has no {VBMETA_LABEL} partition")
        vbmeta_offset, vbmeta_size = layout[VBMETA_LABEL]
        vbmeta_bytes = refresh.vbmeta.read_bytes()
        if len(vbmeta_bytes) != vbmeta_size:
            raise BundleVariantError(
                f"{refresh.vbmeta} is {len(vbmeta_bytes)} bytes, not the {vbmeta_size} of "
                f"{VBMETA_LABEL}"
            )
        stock_vbmeta_sha = _disk_partition(manifest, VBMETA_LABEL)["sha256"]
        with stock_disk.open("rb") as stream:
            stock_vbmeta_bytes = _read_range(stream, vbmeta_offset, vbmeta_size)
            if hashlib.sha256(stock_vbmeta_bytes).hexdigest() != stock_vbmeta_sha:
                raise BundleVariantError(
                    f"{VBMETA_LABEL} of {stock_disk} differs from the manifest"
                )
            stock_values = _bootconfig_values(stream, layout, stock_vbmeta_bytes)
        if refresh.record["stock"].get("vbmetaSha256") != stock_vbmeta_sha:
            raise BundleVariantError("the reseal record names another stock vbmeta_a")
        stock_text = _read_text(stock_bundle / bootconfig_path)
        if _read_bootconfig_values(stock_text, tuple(stock_values)) != stock_values:
            raise BundleVariantError(
                "the stock bootconfig does not carry the digest and size of the stock vbmeta chain"
            )

    with _staging(output) as stage:
        work = stage / "work"
        work.mkdir()
        replacement_snapshot = replacement
        if refresh is not None:
            if stock_vbmeta_bytes is None or vbmeta_bytes is None:
                raise BundleVariantError("the stock or refreshed vbmeta bytes are missing")
            stock_vbmeta_path = work / "stock-vbmeta_a.img"
            refreshed_vbmeta_path = work / "refreshed-vbmeta_a.img"
            replacement_snapshot = work / "resealed-vendor_a.img"
            injected_snapshot = work / "injected-vendor_a.img"
            shutil.copyfile(replacement, replacement_snapshot)
            shutil.copyfile(refresh.injected, injected_snapshot)
            stock_vbmeta_path.write_bytes(stock_vbmeta_bytes)
            refreshed_vbmeta_path.write_bytes(vbmeta_bytes)
            vendor_record = _section(refresh.record, "vendor", refresh.record_path)
            injected_record = _section(refresh.record, "injected", refresh.record_path)
            vbmeta_record = _section(refresh.record, "vbmeta", refresh.record_path)
            if (
                _text(vendor_record.get("sha256")) is None
                or _sha256(replacement_snapshot) != vendor_record["sha256"]
            ):
                raise BundleVariantError(
                    "the replacement vendor_a changed after its reseal record was checked"
                )
            expected_replacement_sha256 = str(vendor_record["sha256"])
            if (
                _text(injected_record.get("sha256")) is None
                or _sha256(injected_snapshot) != injected_record["sha256"]
            ):
                raise BundleVariantError(
                    "the injected vendor_a changed after its inject record was checked"
                )
            if (
                _text(vbmeta_record.get("sha256")) is None
                or _sha256(refreshed_vbmeta_path) != vbmeta_record["sha256"]
            ):
                raise BundleVariantError(
                    "the refreshed vbmeta_a changed after its reseal record was checked"
                )
            avbtool = verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))
            _verify_refreshed_vbmeta_matches_stock(
                avbtool,
                stock_vbmeta_path,
                refreshed_vbmeta_path,
                replacement_snapshot,
                injected_snapshot,
            )
        expanded = _expanded_sha256(stock_super, super_size, work / "stock-super.raw")
        if expanded != record["sha256"]:
            raise BundleVariantError(
                f"{stock_super} does not expand to the super partition of {stock_bundle}"
            )

        variant_sparse = work / "variant-super.sparse"
        result = replace_partition(stock_super, partition, replacement_snapshot, variant_sparse)
        if refresh is not None and replacement_snapshot.stat().st_size != result.partition_size:
            raise BundleVariantError(
                f"{replacement} is not the size of {partition}, so its footer would not end "
                "the partition"
            )

        bundle = stage / "bundle"
        for entry in manifest["files"]:
            target = bundle / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if entry["path"] == disk_path:
                _splice(
                    stock_disk,
                    variant_sparse,
                    target,
                    super_offset,
                    super_size,
                    expected_disk_sha256=entry["sha256"],
                    expected_super_sha256=record["sha256"],
                )
                if vbmeta_bytes is not None:
                    _write_range(target, vbmeta_offset, vbmeta_bytes)
            else:
                shutil.copyfile(stock_bundle / entry["path"], target)
                if _file_entry(bundle, entry["path"]) != entry:
                    raise BundleVariantError(
                        f"the stock bundle's {entry['path']} changed after its manifest was checked"
                    )
        variant_disk = bundle / disk_path
        extra = [(vbmeta_offset, vbmeta_bytes)] if vbmeta_bytes is not None else []
        _verify_variant(
            stock_disk,
            variant_disk,
            super_offset,
            super_size,
            partition,
            replacement_snapshot,
            extra=extra,
            expected_replacement_sha256=expected_replacement_sha256,
        )
        with variant_disk.open("rb") as stream:
            super_sha = _hash_range(stream, super_offset, super_size)
            vbmeta_sha = None
            values: dict[str, str] = {}
            if vbmeta_bytes is not None:
                vbmeta_sha = _hash_range(stream, vbmeta_offset, vbmeta_size)
                values = _bootconfig_values(stream, layout, vbmeta_bytes)
        if vbmeta_bytes is not None:
            text = _read_text(bundle / bootconfig_path)
            (bundle / bootconfig_path).write_text(
                _with_bootconfig_values(text, values), encoding="utf-8"
            )

        files = [_file_entry(bundle, entry["path"]) for entry in manifest["files"]]
        by_path = {entry["path"]: entry for entry in files}
        _super_record(variant_manifest)[1]["sha256"] = super_sha
        if vbmeta_sha is not None:
            _disk_partition(variant_manifest, VBMETA_LABEL)["sha256"] = vbmeta_sha
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

        top_level_decision = (
            f"replaced by {vendor_reseal.VBMETA_ALGORITHM} signed with "
            f"{vendor_reseal.VBMETA_SIGNER}; development-only (IR-1321)"
            if refresh is not None
            else "not signed again (IR-650)"
        )
        record_out: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "task": TASK,
            "imageVersion": variant_manifest["imageVersion"],
            "kind": variant_manifest["kind"],
            "builder": builder,
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
                "sha256": _sha256(replacement_snapshot),
                "size": replacement_snapshot.stat().st_size,
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
                "topLevelVbmeta": top_level_decision,
                "partitionSize": "unchanged, the writer does not grow a partition (IR-682)",
                "identity": (
                    f"short version {image_version}; source build identity, stock kind, and "
                    "provenance kept (IR-1322)"
                ),
                "manifestSignature": "developer image key, trusted by Debug builds",
            },
        }
        if refresh is not None and vbmeta_sha is not None:
            record_out["vbmeta"] = {
                "partition": VBMETA_LABEL,
                "stockSHA256": _disk_partition(manifest, VBMETA_LABEL)["sha256"],
                "variantSHA256": vbmeta_sha,
                "size": vbmeta_size,
                "algorithm": vendor_reseal.VBMETA_ALGORITHM,
                "signer": vendor_reseal.VBMETA_SIGNER,
                "publicKeySha1": vendor_reseal.VBMETA_PUBLIC_KEY_SHA1,
                "rollbackIndex": refresh.record["vbmeta"]["rollbackIndex"],
                **_refresh_record_hashes(refresh),
            }
            record_out["bootconfig"] = {
                "path": bootconfig_path,
                "stockDigest": stock_values[BOOTCONFIG_DIGEST],
                "stockSize": stock_values[BOOTCONFIG_SIZE],
                "variantDigest": values[BOOTCONFIG_DIGEST],
                "variantSize": values[BOOTCONFIG_SIZE],
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
    parser.add_argument(
        "--reseal-output",
        type=Path,
        help="the output directory of vendor-reseal (the resealed vendor and vbmeta_a)",
    )
    parser.add_argument("--partition", default="vendor_a", help="logical partition to replace")
    parser.add_argument(
        "--image-version",
        required=True,
        help="short YYYY.MM.N version for a distinct variant identity",
    )
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
        # The injected image is checked against its record. The vendor is the reseal (IR-746).
        injected_image = _read_inject_output(arguments.inject_output, arguments.partition, build_id)
        if arguments.reseal_output is None:
            raise BundleVariantError(
                "--reseal-output is required: the variant must carry the refreshed vbmeta_a "
                "that vendor-reseal makes (IR-746)"
            )
        refresh = _read_reseal_output(
            arguments.reseal_output,
            inject_directory=arguments.inject_output,
            partition=arguments.partition,
            build_id=build_id,
            injected_image=injected_image,
        )
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
                replacement=refresh.vendor,
                image_version=arguments.image_version,
                output=output,
                sign_key=arguments.sign_key,
                refresh=refresh,
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
