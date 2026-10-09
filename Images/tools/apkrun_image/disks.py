"""Build the raw GPT disks of a layout from an AndroidImageManifest (#011).

android-image.md §4.2-§4.5. Each disk is created at its full logical size
with `truncate`, so ranges that are never written stay holes. Partition
contents come from verified manifest artifacts (sparse ones are expanded in
place) or are left blank. `disks.json` records every disk and partition.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from collections.abc import Mapping, Sequence
from contextlib import AbstractContextManager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from apkrun_image.avb import ArtifactOpener
from apkrun_image.extract import (
    ExtractError,
    _open_artifact,
)
from apkrun_image.gpt import (
    ALIGNMENT,
    SECTOR_SIZE,
    GptError,
    GptPartition,
    disk_guid,
    partition_guid,
    write_gpt,
)
from apkrun_image.layout import Layout, LayoutDisk, LayoutError, check_sources, load_layout
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _repository_root,
    _resolve_archive_root,
    validate_manifest,
)
from apkrun_image.sparse import SparseImageError, expand_into, read_header, write_skipping_zeros

COPY_CHUNK_SIZE = 4 * 1024 * 1024
METADATA_FILE = "disks.json"
METADATA_SCHEMA_VERSION = 1


class DisksError(ValueError):
    """The disk plan cannot be built from the manifest and layout."""


class _HashingReader:
    """A forward-only reader that hashes every byte it returns."""

    def __init__(self, stream: BinaryIO) -> None:
        self._stream = stream
        self._position = 0
        self.digest = hashlib.sha256()

    def read(self, size: int = -1) -> bytes:
        data = self._stream.read(size)
        self.digest.update(data)
        self._position += len(data)
        return data

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence != os.SEEK_SET or offset != self._position:
            raise DisksError("sparse input must be read front to back.")
        return self._position

    def tell(self) -> int:
        return self._position

    @property
    def position(self) -> int:
        return self._position


@dataclass(frozen=True)
class _PlannedPartition:
    label: str
    source: str
    artifact: Mapping[str, Any] | None
    sparse: bool
    size: int
    first_lba: int


@dataclass(frozen=True)
class _PlannedDisk:
    disk: LayoutDisk
    size: int
    partitions: tuple[_PlannedPartition, ...]


def _align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def _default_image_version(document: Mapping[str, Any]) -> str:
    source = document.get("source")
    build = source.get("buildId") if isinstance(source, Mapping) else None
    return f"dev-cf{build}" if isinstance(build, str) and build else "dev"


def _artifact_by_partition(document: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list):
        raise DisksError("manifest artifacts must be an array.")
    by_partition: dict[str, Mapping[str, Any]] = {}
    for artifact in artifacts:
        if isinstance(artifact, Mapping) and isinstance(artifact.get("partition"), str):
            by_partition[str(artifact["partition"])] = artifact
    return by_partition


def _plan(
    document: Mapping[str, Any],
    layout: Layout,
    open_artifact: ArtifactOpener,
) -> tuple[_PlannedDisk, ...]:
    artifacts = _artifact_by_partition(document)
    blank_entries = document.get("blankPartitions")
    if not isinstance(blank_entries, list):
        raise DisksError("manifest blankPartitions must be an array.")
    check_sources(layout, list(artifacts.values()), blank_entries)
    blank_sizes = {
        entry["partition"]: entry["size"]
        for entry in blank_entries
        if isinstance(entry, Mapping) and isinstance(entry.get("size"), int)
    }

    planned_disks: list[_PlannedDisk] = []
    for disk in layout.disks:
        cursor = ALIGNMENT
        planned: list[_PlannedPartition] = []
        for partition in disk.partitions:
            artifact = None if partition.blank else artifacts.get(partition.source)
            sparse = artifact is not None and artifact.get("kind") == "sparse"
            if partition.size is not None:
                size = partition.size
            elif artifact is None:
                if partition.source not in blank_sizes:
                    raise DisksError(
                        f'layout partition "{partition.label}" is blank but has no size; '
                        "give it a size or name a blankPartitions entry."
                    )
                size = int(blank_sizes[partition.source])
            elif sparse:
                with open_artifact(artifact) as stream:
                    size = read_header(stream).logical_size
            else:
                size = int(artifact["size"])
            if size <= 0 or size % SECTOR_SIZE:
                raise DisksError(
                    f'layout partition "{partition.label}": size {size} is not a positive '
                    "multiple of 512."
                )
            planned.append(
                _PlannedPartition(
                    label=partition.label,
                    source=partition.source,
                    artifact=artifact,
                    sparse=sparse,
                    size=size,
                    first_lba=cursor // SECTOR_SIZE,
                )
            )
            cursor = _align_up(cursor + size, ALIGNMENT)
        planned_disks.append(
            _PlannedDisk(disk=disk, size=cursor + ALIGNMENT, partitions=tuple(planned))
        )
    return tuple(planned_disks)


def _hash_range(stream: BinaryIO, offset: int, size: int) -> str:
    digest = hashlib.sha256()
    stream.seek(offset)
    remaining = size
    while remaining:
        data = stream.read(min(remaining, COPY_CHUNK_SIZE))
        if not data:
            raise DisksError("output disk is shorter than its partition table.")
        digest.update(data)
        remaining -= len(data)
    return digest.hexdigest()


def _write_disk(
    planned: _PlannedDisk,
    path: Path,
    *,
    image_version: str,
    open_artifact: ArtifactOpener,
) -> dict[str, object]:
    role = planned.disk.role
    guid = disk_guid(image_version, role)
    partitions = [
        GptPartition(
            label=partition.label,
            first_lba=partition.first_lba,
            size=partition.size,
            unique_guid=partition_guid(image_version, role, partition.label),
        )
        for partition in planned.partitions
    ]
    records: list[dict[str, object]] = []
    with path.open("w+b") as out:
        out.truncate(planned.size)
        write_gpt(out, disk_size=planned.size, guid=guid, partitions=partitions)
        for partition, gpt_partition in zip(planned.partitions, partitions, strict=True):
            offset = partition.first_lba * SECTOR_SIZE
            artifact = partition.artifact
            if artifact is not None:
                with open_artifact(artifact) as stream:
                    reader = _HashingReader(stream)
                    if partition.sparse:
                        expand_into(reader, out, offset)  # type: ignore[arg-type]
                        while reader.read(COPY_CHUNK_SIZE):
                            pass
                    else:
                        position = offset
                        while data := reader.read(COPY_CHUNK_SIZE):
                            write_skipping_zeros(out, position, data)
                            position += len(data)
                    if reader.position != artifact.get("size"):
                        raise DisksError(f'"{partition.source}": artifact size changed.')
                    if reader.digest.hexdigest() != artifact.get("sha256"):
                        raise DisksError(f'"{partition.source}": artifact SHA-256 changed.')
            records.append(
                {
                    "label": partition.label,
                    "guid": str(gpt_partition.unique_guid),
                    "firstLBA": partition.first_lba,
                    "lastLBA": gpt_partition.last_lba,
                    "size": partition.size,
                    "source": partition.source,
                    "content": "blank" if artifact is None else str(artifact.get("kind")),
                    "sha256": _hash_range(out, offset, partition.size),
                }
            )
        out.flush()
        os.fsync(out.fileno())
    record: dict[str, object] = {
        "role": role,
        "file": planned.disk.file,
        "readOnly": planned.disk.read_only,
        "identifier": planned.disk.identifier,
        "sectorSize": SECTOR_SIZE,
        "logicalSize": planned.size,
        "diskGuid": str(guid),
        "partitions": records,
    }
    if planned.disk.userdata_strategy is not None:
        record["userdataStrategy"] = planned.disk.userdata_strategy
    return record


def build_disks(
    document: Mapping[str, Any],
    *,
    layout_path: Path,
    output_directory: Path,
    image_version: str | None = None,
    source: Path | None = None,
    inventory_path: Path | None = None,
) -> dict[str, object]:
    """Validate the inputs and write every layout disk plus `disks.json`."""
    failures = validate_manifest(
        document, include_files=True, source=source, inventory_path=inventory_path
    )
    if failures:
        raise DisksError(failures[0])
    device_family = document.get("deviceFamily")
    if not isinstance(device_family, str):
        raise DisksError("manifest deviceFamily is missing.")
    layout = load_layout(layout_path, device_family)
    version = image_version or _default_image_version(document)

    source_root = _resolve_archive_root(document, source=source)
    source_archives = document.get("source", {}).get("archives", [])
    if not isinstance(source_archives, list):
        raise DisksError("manifest source.archives must be an array.")
    archive_paths = _archive_paths(source_root, source_archives)

    def open_artifact(artifact: Mapping[str, Any]) -> AbstractContextManager[BinaryIO]:
        return _open_artifact(document, source_root, archive_paths, artifact)

    plan = _plan(document, layout, open_artifact)

    output_directory = output_directory.expanduser()
    if output_directory.is_symlink():
        raise DisksError(f"{output_directory}: output directory must not be a symlink.")
    if output_directory.exists() and not output_directory.is_dir():
        raise DisksError(f"{output_directory}: output path is not a directory.")
    output_directory.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".apkrun-disks-", dir=output_directory))
    try:
        disk_records = [
            _write_disk(
                planned,
                stage / planned.disk.file,
                image_version=version,
                open_artifact=open_artifact,
            )
            for planned in plan
        ]
        metadata: dict[str, object] = {
            "schemaVersion": METADATA_SCHEMA_VERSION,
            "imageVersion": version,
            "deviceFamily": device_family,
            "disks": disk_records,
        }
        (stage / METADATA_FILE).write_text(
            json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        (output_directory / METADATA_FILE).unlink(missing_ok=True)
        for planned in plan:
            os.replace(stage / planned.disk.file, output_directory / planned.disk.file)
        os.replace(stage / METADATA_FILE, output_directory / METADATA_FILE)
    finally:
        for leftover in stage.iterdir():
            leftover.unlink()
        stage.rmdir()
    return metadata


def build_parser() -> argparse.ArgumentParser:
    """Build the disks command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image disks",
        description="Build the raw GPT disks of a device layout from a manifest.",
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="source archive or directory")
    parser.add_argument("--inventory", type=Path, help="inventory.json for manifest checks")
    parser.add_argument(
        "--layout",
        type=Path,
        help="device layout; defaults to Images/tools/layouts/<deviceFamily>.json",
    )
    parser.add_argument(
        "--image-version",
        help="image version for the deterministic GUIDs; defaults to dev-cf<buildId>",
    )
    parser.add_argument("--out", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Build the disks and report actionable failures."""
    arguments = build_parser().parse_args(argv)
    try:
        document = _load_json(arguments.manifest, description="manifest")
        if not isinstance(document, dict):
            raise DisksError("manifest: top level must be an object.")
        device_family = document.get("deviceFamily")
        if not isinstance(device_family, str):
            raise DisksError("manifest deviceFamily is missing.")
        layout_path = arguments.layout
        if layout_path is None:
            layout_path = _repository_root() / "Images/tools/layouts" / f"{device_family}.json"
        build_disks(
            document,
            layout_path=layout_path,
            output_directory=arguments.out,
            image_version=arguments.image_version,
            source=arguments.source,
            inventory_path=arguments.inventory,
        )
    except (
        DisksError,
        ExtractError,
        GptError,
        LayoutError,
        ManifestError,
        SparseImageError,
        OSError,
    ) as error:
        print(f"apkrun_image disks: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
