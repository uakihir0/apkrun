"""Generate and validate build-time Android image manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import zipfile
from collections import Counter
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO

from jsonschema import Draft202012Validator

from apkrun_image.inventory import (
    InventoryError,
    _parse_filesystem_at,
)
from apkrun_image.inventory import (
    inventory as create_inventory,
)
from apkrun_image.lp import (
    LpMetadataError,
    read_dynamic_partitions,
    read_partition_ranges,
)
from apkrun_image.sparse import SparseImageError

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schemas/android-image-manifest.schema.json"
SDK_BY_RELEASE = {"13": 33, "14": 34, "15": 35, "16": 36, "17": 37}
BLANK_PARTITIONS = [
    {"partition": "misc", "size": 1024 * 1024},
    {"partition": "metadata", "size": 64 * 1024 * 1024},
    {"partition": "frp", "size": 1024 * 1024},
]
ROLE_KINDS = {
    "kernel": ("bootImage", "boot"),
    "genericRamdisk": ("bootImage", "init_boot"),
    "vendorBoot": ("vendorBootImage", "vendor_boot"),
    "super": ("dynamicPartitions", "super"),
    "userdataTemplate": ("filesystem", "userdata"),
}


class ManifestError(ValueError):
    """An invalid manifest or source image set."""


def _repository_root() -> Path:
    """Return the root of this checkout."""
    return Path(__file__).resolve().parents[3]


def _load_json(path: Path, *, description: str) -> object:
    """Load JSON and keep parse errors actionable."""
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(stream)
    except OSError as error:
        raise ManifestError(f"{description} {path} could not be read: {error}") from error
    except UnicodeDecodeError:
        raise ManifestError(f"{description} {path} is not valid UTF-8.") from None
    except json.JSONDecodeError as error:
        raise ManifestError(
            f"{description} {path} is not valid JSON at line {error.lineno}, "
            f"column {error.colno}: {error.msg}"
        ) from error


def _schema_validator() -> Draft202012Validator:
    """Load the pinned manifest schema."""
    schema = _load_json(SCHEMA_PATH, description="manifest schema")
    return Draft202012Validator(schema)


def _schema_errors(document: object) -> list[str]:
    """Return stable, path-qualified JSON Schema failures."""
    errors = list(_schema_validator().iter_errors(document))
    errors.sort(key=lambda error: (tuple(str(part) for part in error.absolute_path), error.message))
    output: list[str] = []
    for error in errors:
        path = ".".join(_safe_diagnostic_value(part) for part in error.absolute_path) or "manifest"
        if error.validator == "additionalProperties":
            message = f"{path}: contains an unknown field. Remove it or update the manifest schema."
        elif error.validator == "required":
            missing = sorted(set(error.validator_value) - set(error.instance))
            message = (
                f"{path}: missing required field {', '.join(missing)}. Add the required field."
            )
        else:
            message = (
                f"{path}: {_safe_diagnostic_value(error.message)}. "
                "Correct this value to match the manifest schema."
            )
        output.append(message)
    return output


def _version_message(document: object) -> str | None:
    """Return M1 before schema validation can obscure an unsupported version."""
    if not isinstance(document, dict):
        return None
    version = document.get("schemaVersion")
    if isinstance(version, bool):
        return None
    if isinstance(version, int):
        normalized_version: int | None = version
    elif isinstance(version, float) and version.is_integer():
        normalized_version = int(version)
    else:
        normalized_version = None
    if normalized_version is not None and normalized_version > 1:
        return (
            f"android-image.json: schemaVersion {normalized_version} is newer than this tool "
            "supports (1). Update Images/tools."
        )
    if normalized_version is not None and normalized_version != 1:
        return f"android-image.json: schemaVersion {normalized_version} is not supported (needs 1)."
    return None


def _artifacts_by_id(document: Mapping[str, Any]) -> dict[str, tuple[int, Mapping[str, Any]]]:
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list):
        return {}
    result: dict[str, tuple[int, Mapping[str, Any]]] = {}
    for index, artifact in enumerate(artifacts):
        if isinstance(artifact, dict) and isinstance(artifact.get("id"), str):
            result.setdefault(artifact["id"], (index, artifact))
    return result


def _role_values(roles: Mapping[str, Any]) -> list[tuple[str, str, int | None]]:
    values: list[tuple[str, str, int | None]] = []
    for role, value in roles.items():
        if isinstance(value, str):
            values.append((role, value, None))
        elif isinstance(value, list):
            values.extend(
                (role, item, index) for index, item in enumerate(value) if isinstance(item, str)
            )
    return values


def _found_kind(artifact: Mapping[str, Any]) -> str:
    kind = str(artifact.get("kind", "unknown"))
    details = artifact.get("details")
    version = details.get("headerVersion") if isinstance(details, dict) else None
    version_text = f" v{version}" if isinstance(version, int) else ""
    boot_kind = details.get("bootKind") if isinstance(details, dict) else None
    boot_text = f" ({boot_kind})" if isinstance(boot_kind, str) else ""
    return f"{kind}{version_text}{boot_text}"


def _manifest_only_checks(document: Mapping[str, Any]) -> list[str]:
    """Run manifest-only rules, including exact androidInfo key validation."""
    failures: list[str] = []
    artifact_index = _artifacts_by_id(document)
    artifact_ids = list(artifact_index)
    roles = document.get("roles")
    if not isinstance(roles, dict):
        roles = {}

    for role, artifact_id, role_index in _role_values(roles):
        if artifact_id not in artifact_index:
            index_text = f"[{role_index}]" if role_index is not None else ""
            failures.append(
                f'roles.{role}{index_text} = "{_safe_diagnostic_value(artifact_id)}": '
                "no artifact with that id. "
                f"Known ids: {', '.join(_safe_diagnostic_value(value) for value in artifact_ids)}."
            )

    for role, (expected_kind, expected_partition) in ROLE_KINDS.items():
        role_value = roles.get(role)
        if not isinstance(role_value, str) or role_value not in artifact_index:
            continue
        index, artifact = artifact_index[role_value]
        actual_kind = artifact.get("kind")
        expected_kinds = (
            ("dynamicPartitions", "sparse")
            if role == "super"
            else ("filesystem", "sparse")
            if role == "userdataTemplate"
            else (expected_kind,)
        )
        if actual_kind not in expected_kinds or artifact.get("partition") != expected_partition:
            expected_kind_label = " or ".join(expected_kinds)
            failures.append(
                f"artifacts[{index}] (role {role}): expected kind {expected_kind_label} on "
                f"partition {expected_partition}, found {_found_kind(artifact)} on "
                f"partition {_safe_diagnostic_value(artifact.get('partition'))}. "
                "Is the file swapped?"
            )

    vbmeta_ids = roles.get("vbmeta")
    if isinstance(vbmeta_ids, list):
        for position, artifact_id in enumerate(vbmeta_ids):
            found = artifact_index.get(artifact_id) if isinstance(artifact_id, str) else None
            if found is None:
                continue
            index, artifact = found
            expected_partition = " on partition vbmeta" if position == 0 else ""
            if artifact.get("kind") != "vbmeta" or (
                position == 0 and artifact.get("partition") != "vbmeta"
            ):
                failures.append(
                    f"artifacts[{index}] (role roles.vbmeta[{position}]): expected kind vbmeta"
                    f"{expected_partition}, found {_found_kind(artifact)} on partition "
                    f"{_safe_diagnostic_value(artifact.get('partition'))}. Is the file swapped?"
                )

        listed_vbmeta_ids = set(vbmeta_ids)
        top_vbmeta = (
            artifact_index.get(vbmeta_ids[0])
            if vbmeta_ids and isinstance(vbmeta_ids[0], str)
            else None
        )
        artifacts = document.get("artifacts")
        if (
            top_vbmeta is not None
            and top_vbmeta[1].get("kind") == "vbmeta"
            and top_vbmeta[1].get("partition") == "vbmeta"
            and isinstance(artifacts, list)
        ):
            for index, artifact in enumerate(artifacts):
                if (
                    isinstance(artifact, dict)
                    and artifact.get("kind") == "vbmeta"
                    and artifact.get("id") not in listed_vbmeta_ids
                ):
                    failures.append(
                        f"artifacts[{index}] (vbmeta): id "
                        f'"{_safe_diagnostic_value(artifact.get("id"))}" is missing '
                        "from roles.vbmeta. Add it to the chain order."
                    )

    architecture = document.get("architecture")
    if architecture != "arm64":
        failures.append(
            f"architecture {_safe_diagnostic_value(architecture)} is not supported. "
            "Use an arm64 target."
        )

    partitions: dict[str, tuple[str, int]] = {}
    artifacts = document.get("artifacts")
    if isinstance(artifacts, list):
        for index, artifact in enumerate(artifacts):
            if not isinstance(artifact, dict) or not isinstance(artifact.get("partition"), str):
                continue
            partition = artifact["partition"]
            if partition in partitions:
                previous_kind, previous_index = partitions[partition]
                failures.append(
                    f'partition "{_safe_diagnostic_value(partition)}" appears in '
                    f"{previous_kind}[{previous_index}] "
                    f"and artifacts[{index}]."
                )
            else:
                partitions[partition] = ("artifacts", index)
    blank_partitions = document.get("blankPartitions")
    if isinstance(blank_partitions, list):
        for index, partition_entry in enumerate(blank_partitions):
            if not isinstance(partition_entry, dict) or not isinstance(
                partition_entry.get("partition"), str
            ):
                continue
            partition = partition_entry["partition"]
            if partition in partitions:
                previous_kind, previous_index = partitions[partition]
                failures.append(
                    f'partition "{_safe_diagnostic_value(partition)}" appears in '
                    f"{previous_kind}[{previous_index}] "
                    f"and blankPartitions[{index}]."
                )
            else:
                partitions[partition] = ("blankPartitions", index)

    seen_ids: dict[str, int] = {}
    if isinstance(artifacts, list):
        for index, artifact in enumerate(artifacts):
            if not isinstance(artifact, dict) or not isinstance(artifact.get("id"), str):
                continue
            artifact_id = artifact["id"]
            if artifact_id in seen_ids:
                failures.append(
                    f'artifact id "{_safe_diagnostic_value(artifact_id)}" appears in '
                    f"artifacts[{seen_ids[artifact_id]}] "
                    f"and artifacts[{index}]."
                )
            else:
                seen_ids[artifact_id] = index

    android = document.get("android")
    source = document.get("source")
    if isinstance(android, dict) and isinstance(source, dict):
        variant = android.get("variant")
        target = source.get("target")
        if isinstance(variant, str) and isinstance(target, str):
            target_variant = target.rsplit("-", 1)[-1]
            if variant != target_variant:
                failures.append(
                    f'android.variant "{_safe_diagnostic_value(variant)}" does not match '
                    f"target {_safe_diagnostic_value(target)}."
                )

        origin = source.get("origin")
        build_id = source.get("buildId")
        if isinstance(origin, str) and isinstance(build_id, str):
            expected_format = (
                "a numeric build ID"
                if origin == "ci.android.com"
                else "an ar-prefixed six-digit build ID"
            )
            valid_pair = (
                origin == "ci.android.com" and re.fullmatch(r"[0-9]{1,20}", build_id) is not None
            ) or (origin == "apkrun-builder" and re.fullmatch(r"ar[0-9]{6}", build_id) is not None)
            if not valid_pair:
                failures.append(
                    f'source.buildId "{_safe_diagnostic_value(build_id)}" does not match '
                    f"origin {_safe_diagnostic_value(origin)}. "
                    f"Use {expected_format}."
                )

    logical_partitions = document.get("logicalPartitions")
    if isinstance(logical_partitions, list):
        logical_partition_locations: dict[str, int] = {}
        for index, partition in enumerate(logical_partitions):
            if not isinstance(partition, dict) or not isinstance(partition.get("name"), str):
                continue
            name = partition["name"]
            if name in logical_partition_locations:
                failures.append(
                    f'logicalPartitions[{index}].name "{_safe_diagnostic_value(name)}" duplicates '
                    f"logicalPartitions[{logical_partition_locations[name]}].name. "
                    "Use a unique logical partition name."
                )
            else:
                logical_partition_locations[name] = index
    return failures


def _validate_manifest_shape(document: object) -> list[str]:
    """Run M1, JSON Schema, then manifest-only semantic checks."""
    version_failure = _version_message(document)
    if version_failure:
        return [version_failure]
    errors = _schema_errors(document)
    if errors:
        return errors
    return _manifest_only_checks(document)


def _inventory_files(inventory_document: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    files = inventory_document.get("files")
    if not isinstance(files, list):
        raise ManifestError("inventory.json: missing files array.")
    return [entry for entry in files if isinstance(entry, dict)]


def _archive_paths(source: Path, archives: Sequence[Mapping[str, Any]]) -> list[Path]:
    """Resolve manifest archives from an explicit file, directory, or default work path."""
    if source.is_file():
        return [source]
    if source.is_dir():
        paths = [source / entry["name"] for entry in archives if isinstance(entry.get("name"), str)]
        existing = [path for path in paths if path.is_file() and not path.is_symlink()]
        if existing:
            return existing
        if (source / "fetch.json").is_file():
            return [source]
        return []
    return []


def _read_actual_inventories(
    source: Path,
    archive_declarations: Sequence[Mapping[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Path]]:
    """Inventory each declared archive and index its entries by archive path."""
    paths = _archive_paths(source, archive_declarations)
    if not paths and source.is_dir():
        try:
            inventory_document = create_inventory(source)
        except InventoryError as error:
            raise ManifestError(_safe_diagnostic_text(str(error))) from error
        source_name = inventory_document.get("source", {}).get("name")
        actual_inventories = [inventory_document]
        source_record = inventory_document.get("source")
        if (
            isinstance(source_record, dict)
            and source_record.get("type") == "zip"
            and isinstance(source_name, str)
        ):
            path_by_source_name = {source_name: source / source_name}
        else:
            path_by_source_name = {str(source_name): source}
    else:
        actual_inventories = []
        path_by_source_name: dict[str, Path] = {}
        for path in paths:
            try:
                inventory_document = create_inventory(path)
            except InventoryError as error:
                raise ManifestError(_safe_diagnostic_text(str(error))) from error
            actual_inventories.append(inventory_document)
            source_record = inventory_document.get("source")
            if isinstance(source_record, dict):
                path_by_source_name[str(source_record.get("name"))] = path
    return actual_inventories, path_by_source_name


def _source_files(
    actual_inventories: Sequence[Mapping[str, Any]],
) -> tuple[list[tuple[str, Mapping[str, Any], Mapping[str, Any]]], Counter[str]]:
    entries: list[tuple[str, Mapping[str, Any], Mapping[str, Any]]] = []
    counts: Counter[str] = Counter()
    for inventory_document in actual_inventories:
        source_record = inventory_document.get("source")
        archive_name = (
            str(source_record.get("name"))
            if isinstance(source_record, dict) and source_record.get("name") is not None
            else ""
        )
        for entry in _inventory_files(inventory_document):
            path = entry.get("path")
            if isinstance(path, str):
                entries.append((archive_name, entry, source_record or {}))
                counts[path] += 1
    return entries, counts


def _hash_descriptor(descriptor: int) -> str:
    """Hash bytes from an already-open descriptor without resolving its path again."""
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def _open_image_stream(
    archive_path: Path,
    member: str,
    *,
    expected_sha256: str,
    expected_size: int,
) -> BinaryIO:
    """Open and verify one image through a stable descriptor."""
    if archive_path.is_dir():
        safe_path = PurePosixPath(member)
        if safe_path.is_absolute() or any(part in {"", ".", ".."} for part in member.split("/")):
            raise ManifestError(f"{member}: unsafe inventory path.")
        directory_descriptor = -1
        descriptor = -1
        try:
            directory_descriptor = os.open(
                archive_path,
                os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0),
            )
            for component in safe_path.parts[:-1]:
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0),
                    dir_fd=directory_descriptor,
                )
                os.close(directory_descriptor)
                directory_descriptor = next_descriptor
            descriptor = os.open(
                safe_path.parts[-1],
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=directory_descriptor,
            )
            opened_stat = os.fstat(descriptor)
            if not stat.S_ISREG(opened_stat.st_mode):
                raise ManifestError(f"{member}: source image must be a regular file.")
            if opened_stat.st_size != expected_size:
                raise ManifestError(f"{member}: size changed before logical-partition inspection.")
            if _hash_descriptor(descriptor) != expected_sha256:
                raise ManifestError(
                    f"{member}: SHA-256 changed before logical-partition inspection."
                )
            os.lseek(descriptor, 0, os.SEEK_SET)
            stream = os.fdopen(descriptor, "rb")
            descriptor = -1
            return stream
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            if directory_descriptor >= 0:
                os.close(directory_descriptor)

    descriptor = os.open(archive_path, os.O_RDONLY | os.O_NOFOLLOW)
    owner_stream = os.fdopen(descriptor, "rb")
    archive: zipfile.ZipFile | None = None
    try:
        opened_stat = os.fstat(descriptor)
        if not stat.S_ISREG(opened_stat.st_mode):
            raise ManifestError(f"{archive_path}: source archive must be a regular file.")
        if opened_stat.st_size != expected_size:
            raise ManifestError(
                f"{archive_path}: archive size changed before logical-partition inspection."
            )
        if _hash_descriptor(descriptor) != expected_sha256:
            raise ManifestError(
                f"{archive_path}: archive SHA-256 changed before logical-partition inspection."
            )
        owner_stream.seek(0)
        archive = zipfile.ZipFile(owner_stream, "r")
        return _ZipMemberStream(archive, archive.open(member, "r"), owner_stream)
    except Exception:
        if archive is not None:
            archive.close()
        owner_stream.close()
        raise


class _ZipMemberStream:
    """Close the owning archive together with its member stream."""

    def __init__(
        self,
        archive: zipfile.ZipFile,
        stream: BinaryIO,
        owner_stream: BinaryIO,
    ) -> None:
        self._archive = archive
        self._stream = stream
        self._owner_stream = owner_stream

    def __enter__(self) -> BinaryIO:
        return self._stream

    def __exit__(self, exception_type: object, exception: object, traceback: object) -> None:
        self._stream.close()
        self._archive.close()
        self._owner_stream.close()


def validate_manifest(
    document: object,
    *,
    include_files: bool = False,
    source: Path | None = None,
    inventory_path: Path | None = None,
) -> list[str]:
    """Validate structure, semantics, and optionally the image inputs."""
    failures = _validate_manifest_shape(document)
    if failures or not include_files or not isinstance(document, dict):
        return failures
    try:
        archive_declarations = document.get("source", {}).get("archives", [])
        if not isinstance(archive_declarations, list):
            return ["source.archives must be an array."]
        root = _resolve_archive_root(document, source=source)
        actual_inventories, archive_paths = _read_actual_inventories(root, archive_declarations)
    except (ManifestError, OSError) as error:
        return [str(error)]
    file_failures: list[str] = []
    if inventory_path is None:
        build_id = document.get("source", {}).get("buildId")
        inventory_path = _repository_root() / "Images/manifests" / str(build_id) / "inventory.json"
    try:
        recorded_inventory = _load_json(inventory_path, description="inventory")
    except ManifestError as error:
        file_failures.append(str(error))
    else:
        if not isinstance(recorded_inventory, dict):
            file_failures.append("inventory.json: top level must be an object.")
        else:
            _validate_inventory_provenance(
                document,
                recorded_inventory,
                actual_inventories,
                file_failures,
            )
            if actual_inventories and all(
                item.get("source", {}).get("type") != "directory" for item in actual_inventories
            ):
                recorded_files = recorded_inventory.get("files")
                actual_files = [
                    entry
                    for inventory_document in actual_inventories
                    for entry in inventory_document.get("files", [])
                ]
                if recorded_files != actual_files:
                    file_failures.append(
                        "inventory.json: file entries do not match the source archive. "
                        "Re-run the inventory."
                    )
    _validate_inventory_records(document, actual_inventories, archive_paths, file_failures)
    return file_failures


def _validate_inventory_provenance(
    document: Mapping[str, Any],
    inventory_document: Mapping[str, Any],
    actual_inventories: Sequence[Mapping[str, Any]],
    failures: list[str],
) -> None:
    """Ensure the manifest does not misstate its fetched build provenance."""
    manifest_source = document.get("source")
    inventory_source = inventory_document.get("source")
    if not isinstance(manifest_source, dict) or not isinstance(inventory_source, dict):
        failures.append("inventory.json: source metadata is missing. Re-run inventory.")
        return
    actual_sources = [
        actual_inventory.get("source") if isinstance(actual_inventory.get("source"), dict) else {}
        for actual_inventory in actual_inventories
    ]
    has_complete_fetched_provenance = bool(actual_sources) and all(
        isinstance(actual_source.get(field), str) and actual_source[field]
        for actual_source in actual_sources
        for field in ("branch", "buildId", "target")
    )
    if not has_complete_fetched_provenance:
        failures.append(
            "source: actual archive inventory is missing complete fetched build metadata "
            "(branch, buildId, target). Pass the fetched download directory or create a "
            "valid fetch.json."
        )
    for field in ("branch", "buildId", "target"):
        expected = inventory_source.get(field)
        found = manifest_source.get(field)
        if not isinstance(expected, str):
            failures.append(
                f"inventory.json: source.{field} is missing. Re-run inventory on the "
                "fetched archive."
            )
        elif found != expected:
            failures.append(
                f'source.{field} "{_safe_diagnostic_value(found)}" does not match '
                f'inventory.json source.{field} "{_safe_diagnostic_value(expected)}". '
                "Re-run manifest generation."
            )
        elif isinstance(found, str):
            for actual_source in actual_sources:
                actual_value = actual_source.get(field)
                if (
                    has_complete_fetched_provenance
                    and isinstance(actual_value, str)
                    and found != actual_value
                ):
                    failures.append(
                        f'source.{field} "{_safe_diagnostic_value(found)}" does not match '
                        "the fetched archive metadata "
                        f'"{_safe_diagnostic_value(actual_value)}". '
                        "Re-run inventory or manifest generation."
                    )

    if inventory_source.get("type") != "zip":
        failures.append(
            'inventory.json: source type must be "zip" to match source.archives. '
            "Re-run inventory on the fetched archive."
        )
        return

    archive_name = inventory_source.get("name")
    archives = manifest_source.get("archives")
    archive = (
        next(
            (
                item
                for item in archives
                if isinstance(item, dict) and item.get("name") == archive_name
            ),
            None,
        )
        if isinstance(archives, list)
        else None
    )
    if not isinstance(archive_name, str) or archive is None:
        failures.append(
            "inventory.json: source archive is not declared in source.archives. "
            "Re-run manifest generation."
        )
    else:
        for field in ("size", "sha256"):
            expected = inventory_source.get(field)
            found = archive.get(field)
            if expected != found:
                failures.append(
                    f"inventory.json: source archive "
                    f'"{_safe_diagnostic_value(archive_name)}" {field} '
                    f"does not match source.archives. Re-run inventory or manifest "
                    "generation."
                )


def _safe_diagnostic_value(value: object) -> str:
    """Escape and bound an untrusted value before adding it to a diagnostic."""
    if not isinstance(value, str):
        return json.dumps(value, ensure_ascii=True, separators=(",", ":"))[:128]
    truncated = value[:128]
    escaped = json.dumps(truncated, ensure_ascii=True, separators=(",", ":"))[1:-1]
    if len(value) > len(truncated):
        escaped += "…"
    return escaped


def _safe_diagnostic_text(value: str) -> str:
    """Escape a diagnostic and retain both ends when its untrusted text is long."""
    escaped = json.dumps(value, ensure_ascii=True, separators=(",", ":"))[1:-1]
    if len(escaped) > 512:
        escaped = f"{escaped[:255]}…{escaped[-256:]}"
    return escaped


def _read_logical_partitions(
    stream: BinaryIO,
    *,
    sparse: bool,
) -> dict[str, tuple[int, str]] | None:
    """Read non-empty liblp partitions and detect their filesystem types."""
    metadata = read_dynamic_partitions(stream, sparse=sparse)
    if metadata is None:
        return None
    partitions = [partition for partition in metadata.logical_partitions if partition.size > 0]
    inspectable = [partition for partition in partitions if partition.size >= 2048]
    samples = read_partition_ranges(stream, inspectable, 1024, 1024, sparse=sparse)
    samples_by_name = {
        partition.name: sample for partition, sample in zip(inspectable, samples, strict=True)
    }
    result: dict[str, tuple[int, str]] = {}
    for partition in partitions:
        sample = samples_by_name.get(partition.name)
        if sample is None:
            result[partition.name] = (partition.size, "unknown")
            continue
        detected = _parse_filesystem_at(
            lambda _offset, size, value=sample: value[:size],
            partition.size,
        )
        filesystem = (
            str(detected.details.get("type", "unknown")) if detected is not None else "unknown"
        )
        result[partition.name] = (partition.size, filesystem)
    return result


def _validate_inventory_records(
    document: Mapping[str, Any],
    actual_inventories: Sequence[Mapping[str, Any]],
    archive_path_by_name: Mapping[str, Path],
    failures: list[str],
) -> None:
    """Apply file checks against prepared inventories and the matching archive paths."""
    entries, _counts = _source_files(actual_inventories)
    actual_by_path: dict[str, list[tuple[str, Mapping[str, Any], Mapping[str, Any]]]] = {}
    for archive_name, entry, source_record in entries:
        path = entry.get("path")
        if isinstance(path, str):
            actual_by_path.setdefault(path, []).append((archive_name, entry, source_record))

    source_record = document.get("source")
    archives = source_record.get("archives", []) if isinstance(source_record, dict) else []
    archive_by_name = {
        archive["name"]: archive
        for archive in archives
        if isinstance(archive, dict) and isinstance(archive.get("name"), str)
    }
    for archive in archives:
        if not isinstance(archive, dict):
            continue
        name = archive.get("name")
        display_name = _safe_diagnostic_value(name)
        actual = next(
            (
                item.get("source")
                for item in actual_inventories
                if isinstance(item.get("source"), dict) and item["source"].get("name") == name
            ),
            None,
        )
        if actual is None:
            if not any(
                item.get("source", {}).get("type") == "directory" for item in actual_inventories
            ):
                failures.append(
                    f"{display_name}: source archive is missing. Re-run fetch or pass --source."
                )
        elif actual.get("type") != "directory":
            if actual.get("size") != archive.get("size"):
                failures.append(f"{display_name}: archive size does not match source.archives.")
            if actual.get("sha256") != archive.get("sha256"):
                failures.append(f"{display_name}: archive SHA-256 does not match source.archives.")

    artifacts = document.get("artifacts", [])
    artifact_by_id = _artifacts_by_id(document)
    manifest_vbmeta_paths: set[str] = set()
    if isinstance(artifacts, list):
        manifest_vbmeta_paths = {
            artifact["file"]
            for artifact in artifacts
            if isinstance(artifact, dict)
            and artifact.get("kind") == "vbmeta"
            and isinstance(artifact.get("file"), str)
        }
    for _archive_name, entry, _source in entries:
        path = entry.get("path")
        if (
            entry.get("kind") == "vbmeta"
            and isinstance(path, str)
            and path not in manifest_vbmeta_paths
        ):
            failures.append(
                f'inventory.json: vbmeta file "{_safe_diagnostic_value(path)}" is missing '
                "from artifacts and "
                "roles.vbmeta. Regenerate the manifest."
            )
    for index, artifact in enumerate(artifacts if isinstance(artifacts, list) else []):
        if not isinstance(artifact, dict):
            continue
        path = artifact.get("file")
        candidates = actual_by_path.get(path, []) if isinstance(path, str) else []
        display_path = _safe_diagnostic_value(path)
        if len(candidates) != 1:
            failures.append(
                f"{display_path}: expected exactly one archive entry, found {len(candidates)}."
            )
            continue
        entry = candidates[0][1]
        if artifact.get("size") != entry.get("size"):
            failures.append(
                f"{display_path}: size mismatch "
                f"(expected {artifact.get('size')}, got {entry.get('size')})."
            )
        if artifact.get("sha256") != entry.get("sha256"):
            failures.append(
                f"{display_path}: SHA-256 mismatch (expected {artifact.get('sha256')}, "
                f"got {entry.get('sha256')}). Re-run fetch or re-inventory."
            )
        if artifact.get("kind") != entry.get("kind"):
            failures.append(
                f"artifacts[{index}] ({display_path}): kind {artifact.get('kind')} does not match "
                f"the inventory ({entry.get('kind')}). Re-run the inventory."
            )

    userdata_id = document.get("roles", {}).get("userdataTemplate")
    userdata_found = artifact_by_id.get(userdata_id) if isinstance(userdata_id, str) else None
    if userdata_found is not None and userdata_found[1].get("kind") == "sparse":
        artifact_index, artifact = userdata_found
        candidates = actual_by_path.get(str(artifact.get("file")), [])
        details = candidates[0][1].get("details") if len(candidates) == 1 else None
        content = details.get("content") if isinstance(details, dict) else None
        content_kind = content.get("kind") if isinstance(content, dict) else "unknown"
        if content_kind != "filesystem":
            failures.append(
                f"artifacts[{artifact_index}] (role userdataTemplate): expected sparse with "
                f"filesystem content, found sparse with {content_kind} content. "
                "Is the template swapped?"
            )

    android_info_candidates = [
        entry
        for _archive_name, entry, _source in entries
        if entry.get("kind") == "text"
        and entry.get("probablePurpose") == "device information key/value metadata"
        and isinstance(_classification_details(entry).get("values"), dict)
    ]
    manifest_android_info = document.get("androidInfo")
    if len(android_info_candidates) != 1:
        failures.append(
            "inventory.json: expected exactly one device information key/value record, "
            f"found {len(android_info_candidates)}. Re-run inventory."
        )
    elif manifest_android_info != _classification_details(android_info_candidates[0]).get("values"):
        failures.append(
            "androidInfo does not match the inventory's device information key/value record. "
            "Re-run manifest generation."
        )

    expected_boot_kinds = {"kernel": "boot", "genericRamdisk": "init_boot"}
    for role in ("kernel", "genericRamdisk", "vendorBoot"):
        artifact_id = document.get("roles", {}).get(role)
        found = artifact_by_id.get(artifact_id) if isinstance(artifact_id, str) else None
        if found is None:
            continue
        artifact = found[1]
        entry = actual_by_path.get(str(artifact.get("file")), [])
        details = entry[0][1].get("details") if len(entry) == 1 else None
        version = details.get("headerVersion") if isinstance(details, dict) else None
        if version != 4:
            display_file = _safe_diagnostic_value(artifact.get("file"))
            failures.append(
                f"{display_file} header v{version} is not supported (needs v4 ramdisk table)."
            )
        expected_boot_kind = expected_boot_kinds.get(role)
        if expected_boot_kind is not None:
            boot_kind = details.get("bootKind") if isinstance(details, dict) else None
            if boot_kind != expected_boot_kind:
                found_boot_kind = boot_kind if isinstance(boot_kind, str) else "unknown"
                failures.append(
                    f"{_safe_diagnostic_value(artifact.get('file'))} bootKind "
                    f"{_safe_diagnostic_value(found_boot_kind)} does not match "
                    f"roles.{role} (needs {expected_boot_kind}). Check the manifest role mapping."
                )

    vbmeta_ids = document.get("roles", {}).get("vbmeta")
    if isinstance(vbmeta_ids, list) and vbmeta_ids:
        top = artifact_by_id.get(vbmeta_ids[0]) if isinstance(vbmeta_ids[0], str) else None
        top_file = top[1].get("file") if top else None
        top_entries = actual_by_path.get(str(top_file), [])
        details = top_entries[0][1].get("details") if len(top_entries) == 1 else None
        descriptors = details.get("descriptors", []) if isinstance(details, dict) else []
        chain_partitions = [
            item.get("partition")
            for item in descriptors
            if (
                isinstance(item, dict)
                and item.get("type") == "chainPartition"
                and isinstance(item.get("partition"), str)
            )
        ]
        vbmeta_id_by_partition = {
            artifact.get("partition"): artifact.get("id")
            for artifact in document.get("artifacts", [])
            if (
                isinstance(artifact, dict)
                and artifact.get("kind") == "vbmeta"
                and isinstance(artifact.get("partition"), str)
                and isinstance(artifact.get("id"), str)
            )
        }
        ordered_child_ids = [
            vbmeta_id_by_partition[partition]
            for partition in chain_partitions
            if partition in vbmeta_id_by_partition
        ]
        expected_vbmeta_ids = [vbmeta_ids[0], *ordered_child_ids]
        child_roles_are_chained = all(
            isinstance(artifact_id, str)
            and (found := artifact_by_id.get(artifact_id)) is not None
            and found[1].get("partition") in chain_partitions
            for artifact_id in vbmeta_ids[1:]
        )
        if child_roles_are_chained and vbmeta_ids != expected_vbmeta_ids:
            display_vbmeta_ids = [_safe_diagnostic_value(artifact_id) for artifact_id in vbmeta_ids]
            display_expected_vbmeta_ids = [
                _safe_diagnostic_value(artifact_id) for artifact_id in expected_vbmeta_ids
            ]
            failures.append(
                f"roles.vbmeta order {display_vbmeta_ids} does not match top-level chain "
                f"descriptor order {display_expected_vbmeta_ids}."
            )
        for position, artifact_id in enumerate(vbmeta_ids[1:], start=1):
            found = artifact_by_id.get(artifact_id) if isinstance(artifact_id, str) else None
            if found and found[1].get("partition") not in chain_partitions:
                failures.append(
                    f'roles.vbmeta[{position}] = "{_safe_diagnostic_value(artifact_id)}": '
                    f"{_safe_diagnostic_value(top_file)} has no chain descriptor for partition "
                    f"{_safe_diagnostic_value(found[1].get('partition'))}."
                )

    super_found = artifact_by_id.get(document.get("roles", {}).get("super"))
    if super_found:
        super_artifact = super_found[1]
        candidates = actual_by_path.get(str(super_artifact.get("file")), [])
        if len(candidates) == 1:
            source_name = candidates[0][0]
            archive_path = archive_path_by_name.get(source_name)
            if archive_path is not None:
                try:
                    source_info = candidates[0][2]
                    if source_info.get("type") == "directory":
                        expected_sha256 = str(super_artifact.get("sha256"))
                        expected_size = int(super_artifact.get("size", 0))
                    else:
                        archive_info = archive_by_name.get(source_name)
                        if archive_info is None:
                            raise ManifestError(f"{source_name}: archive declaration is missing.")
                        expected_sha256 = str(archive_info.get("sha256"))
                        expected_size = int(archive_info.get("size", 0))
                    with _open_image_stream(
                        archive_path,
                        str(super_artifact.get("file")),
                        expected_sha256=expected_sha256,
                        expected_size=expected_size,
                    ) as stream:
                        sparse = candidates[0][1].get("kind") == "sparse"
                        actual_partitions = _read_logical_partitions(stream, sparse=sparse)
                        if actual_partitions is None:
                            failures.append(
                                f"{_safe_diagnostic_value(super_artifact.get('file'))}: "
                                "liblp metadata is missing."
                            )
                        else:
                            manifest_values = {
                                item.get("name"): (item.get("size"), item.get("filesystem"))
                                for item in document.get("logicalPartitions", [])
                                if isinstance(item, dict)
                            }
                            for name in sorted(set(actual_partitions) - set(manifest_values)):
                                failures.append(
                                    f"logicalPartitions: {_safe_diagnostic_value(name)} is in "
                                    f"{_safe_diagnostic_value(super_artifact.get('file'))} "
                                    "but not in the manifest."
                                )
                            for name in sorted(set(manifest_values) - set(actual_partitions)):
                                failures.append(
                                    f"logicalPartitions: {_safe_diagnostic_value(name)} is in the "
                                    "manifest but not in "
                                    f"{_safe_diagnostic_value(super_artifact.get('file'))}."
                                )
                            for name in sorted(set(actual_partitions) & set(manifest_values)):
                                if manifest_values[name] != actual_partitions[name]:
                                    display_expected = _safe_diagnostic_value(manifest_values[name])
                                    display_actual = _safe_diagnostic_value(actual_partitions[name])
                                    failures.append(
                                        f"logicalPartitions: {_safe_diagnostic_value(name)} "
                                        f"expected {display_expected}, found {display_actual} "
                                        "in "
                                        f"{_safe_diagnostic_value(super_artifact.get('file'))}."
                                    )
                except (
                    OSError,
                    InventoryError,
                    LpMetadataError,
                    ManifestError,
                    SparseImageError,
                    zipfile.BadZipFile,
                ) as error:
                    failures.append(
                        f"{_safe_diagnostic_value(super_artifact.get('file'))}: could not "
                        f"inspect logical partitions: {_safe_diagnostic_value(str(error))}."
                    )

    kernel_found = artifact_by_id.get(document.get("roles", {}).get("kernel"))
    if kernel_found:
        kernel_file = str(kernel_found[1].get("file"))
        candidates = actual_by_path.get(kernel_file, [])
        details = candidates[0][1].get("details") if len(candidates) == 1 else None
        os_version = details.get("osVersion") if isinstance(details, dict) else None
        android = document.get("android")
        if isinstance(android, dict) and isinstance(os_version, dict):
            raw_release = os_version.get("release")
            expected_release = (
                raw_release.split(".", 1)[0] if isinstance(raw_release, str) else None
            )
            if android.get("release") != expected_release:
                failures.append(
                    f'android.release "{_safe_diagnostic_value(android.get("release"))}" does '
                    f"not match {_safe_diagnostic_value(kernel_file)} "
                    f"os_version {_safe_diagnostic_value(raw_release)}."
                )
            if android.get("securityPatch") != os_version.get("securityPatch"):
                failures.append(
                    f"android.securityPatch "
                    f'"{_safe_diagnostic_value(android.get("securityPatch"))}" does not match '
                    f"{_safe_diagnostic_value(kernel_file)} os_version security patch "
                    f"{_safe_diagnostic_value(os_version.get('securityPatch'))}."
                )
            expected_sdk = SDK_BY_RELEASE.get(str(expected_release))
            if android.get("sdk") != expected_sdk:
                failures.append(
                    f"android.sdk {_safe_diagnostic_value(android.get('sdk'))} does not match "
                    f"release {_safe_diagnostic_value(android.get('release'))} "
                    f"(expected {expected_sdk}). Update the SDK table."
                )


def _resolve_archive_root(
    inventory_document: Mapping[str, Any],
    *,
    source: Path | None,
) -> Path:
    """Find the downloaded archive or directory used by the inventory."""
    if source is not None:
        return source.expanduser()
    build_id = inventory_document.get("source", {}).get("buildId")
    if not isinstance(build_id, str):
        raise ManifestError(
            "inventory source has no buildId; pass --source with the archive or image directory."
        )
    return _repository_root() / "Images/work" / build_id / "download"


def _safe_id(path_value: str) -> str:
    """Derive an artifact and partition identifier from an inventory path."""
    stem = PurePosixPath(path_value).stem
    if stem.startswith("cuttlefish_example_"):
        stem = stem.removeprefix("cuttlefish_example_")
    normalized = re.sub(r"[^a-z0-9_]+", "_", stem.lower()).strip("_")
    if not normalized or not normalized[0].isalpha():
        normalized = f"artifact_{normalized}"
    return normalized[:36]


def _classification_details(entry: Mapping[str, Any]) -> Mapping[str, Any]:
    details = entry.get("details")
    return details if isinstance(details, dict) else {}


def _artifact_candidates(files: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for entry in files:
        kind = entry.get("kind")
        if kind == "text":
            continue
        path = entry.get("path")
        if not isinstance(path, str):
            continue
        artifact_id = _safe_id(path)
        details = _classification_details(entry)
        nested_content = details.get("content")
        content_kind = nested_content.get("kind") if isinstance(nested_content, dict) else None
        if kind == "dynamicPartitions" or (
            kind == "sparse" and content_kind == "dynamicPartitions"
        ):
            artifact_id = "super"
        elif kind == "sparse" and content_kind == "filesystem":
            artifact_id = _safe_id(path)
        artifacts.append(
            {
                "id": artifact_id,
                "file": path,
                "sha256": entry.get("sha256"),
                "size": entry.get("size"),
                "kind": kind,
                "partition": artifact_id,
            }
        )
    artifacts.sort(key=lambda artifact: str(artifact["id"]))
    return artifacts


def _ordered_vbmeta_roles(
    artifacts: Sequence[Mapping[str, Any]],
    inventory_by_path: Mapping[str, Mapping[str, Any]],
) -> list[str]:
    """Order available vbmeta artifacts by the top-level chain descriptor table."""
    vbmeta_artifacts = [artifact for artifact in artifacts if artifact.get("kind") == "vbmeta"]
    top = next(
        (artifact for artifact in vbmeta_artifacts if artifact.get("partition") == "vbmeta"),
        None,
    )
    if top is None:
        raise ManifestError("inventory.json: cannot identify the top-level vbmeta artifact.")

    vbmeta_by_partition: dict[str, Mapping[str, Any]] = {}
    for artifact in vbmeta_artifacts:
        partition = artifact.get("partition")
        if not isinstance(partition, str) or partition in vbmeta_by_partition:
            raise ManifestError("inventory.json: vbmeta artifacts have duplicate partitions.")
        vbmeta_by_partition[partition] = artifact

    top_entry = inventory_by_path.get(str(top.get("file")))
    descriptors = _classification_details(top_entry or {}).get("descriptors")
    if not isinstance(descriptors, list):
        raise ManifestError("inventory.json: top-level vbmeta has no descriptor table.")

    ordered = [str(top["id"])]
    for descriptor in descriptors:
        if not isinstance(descriptor, dict) or descriptor.get("type") != "chainPartition":
            continue
        partition = descriptor.get("partition")
        child = vbmeta_by_partition.get(partition) if isinstance(partition, str) else None
        if child is not None:
            artifact_id = str(child["id"])
            if artifact_id in ordered:
                raise ManifestError(
                    "inventory.json: top-level vbmeta has duplicate chain descriptors for "
                    f"partition {partition}."
                )
            ordered.append(artifact_id)

    unchained = sorted(
        str(artifact["id"]) for artifact in vbmeta_artifacts if artifact.get("id") not in ordered
    )
    if unchained:
        raise ManifestError(
            "inventory.json: vbmeta artifacts have no top-level chain descriptor: "
            f"{', '.join(unchained)}."
        )
    return ordered


def _select_role(
    artifacts: Sequence[Mapping[str, Any]],
    inventory_by_path: Mapping[str, Mapping[str, Any]],
    *,
    kind: str,
    boot_kind: str | None = None,
    sparse_content_kind: str | None = None,
) -> str | None:
    matches: list[str] = []
    for artifact in artifacts:
        if artifact.get("kind") != kind:
            continue
        entry = inventory_by_path.get(str(artifact.get("file")), {})
        details = _classification_details(entry)
        if boot_kind is not None and details.get("bootKind") != boot_kind:
            continue
        content = details.get("content")
        if sparse_content_kind is not None and (
            not isinstance(content, dict) or content.get("kind") != sparse_content_kind
        ):
            continue
        if kind == "filesystem" and artifact.get("partition") != "userdata":
            continue
        if kind == "sparse" and sparse_content_kind == "filesystem":
            basename = PurePosixPath(str(artifact.get("file"))).stem
            if _safe_id(str(artifact.get("file"))) != "userdata" and basename != "userdata":
                continue
        matches.append(str(artifact["id"]))
    return matches[0] if len(matches) == 1 else None


def generate_manifest(
    inventory_document: Mapping[str, Any],
    *,
    source: Path | None = None,
) -> dict[str, Any]:
    """Generate a draft manifest from the inventory and its source archive."""
    inventory_source = inventory_document.get("source")
    if not isinstance(inventory_source, dict):
        raise ManifestError("inventory.json: source must be an object.")
    for required in ("branch", "buildId", "target"):
        if not isinstance(inventory_source.get(required), str):
            raise ManifestError(
                f"inventory.json: source.{required} is missing; re-run inventory "
                "on the fetched archive."
            )
    archive_record = inventory_source
    if archive_record.get("type") != "zip":
        raise ManifestError("manifest generation requires a fetched archive inventory.")
    if (
        not isinstance(archive_record.get("name"), str)
        or isinstance(archive_record.get("size"), bool)
        or not isinstance(archive_record.get("size"), int)
        or archive_record.get("size", 0) < 1
        or not isinstance(archive_record.get("sha256"), str)
        or not re.fullmatch(r"[0-9a-f]{64}", archive_record["sha256"])
    ):
        raise ManifestError("inventory.json: source archive name, size, or SHA-256 is invalid.")
    archives = [
        {
            "name": archive_record.get("name"),
            "size": archive_record.get("size"),
            "sha256": archive_record.get("sha256"),
        }
    ]
    root = _resolve_archive_root(inventory_document, source=source)
    actual_inventories, archive_path_by_name = _read_actual_inventories(root, archives)
    if not actual_inventories:
        raise ManifestError(
            f"could not find the source archive under {root}; pass --source with the archive."
        )
    missing_fetched_provenance = any(
        not isinstance(actual_inventory.get("source"), dict)
        or any(
            not isinstance(actual_inventory["source"].get(field), str)
            or not actual_inventory["source"][field]
            for field in ("branch", "buildId", "target")
        )
        for actual_inventory in actual_inventories
    )
    if missing_fetched_provenance:
        raise ManifestError(
            "source: actual archive inventory is missing complete fetched build metadata "
            "(branch, buildId, target). Pass the fetched download directory or create a "
            "valid fetch.json."
        )
    files = _inventory_files(inventory_document)
    actual_files = [
        entry
        for actual_inventory in actual_inventories
        for entry in _inventory_files(actual_inventory)
    ]
    if files != actual_files:
        raise ManifestError(
            "inventory.json: file entries do not match the source image set. Re-run inventory."
        )
    for actual_inventory in actual_inventories:
        actual_source = actual_inventory.get("source")
        assert isinstance(actual_source, dict)
        for field in ("branch", "buildId", "target"):
            if actual_source[field] != inventory_source.get(field):
                raise ManifestError(
                    f"inventory.json: source.{field} does not match the fetched source. "
                    "Re-run inventory."
                )
    by_path = {str(entry["path"]): entry for entry in files if isinstance(entry.get("path"), str)}
    artifacts = _artifact_candidates(files)
    roles: dict[str, Any] = {}
    selectors = (
        ("kernel", "bootImage", "boot"),
        ("genericRamdisk", "bootImage", "init_boot"),
        ("vendorBoot", "vendorBootImage", None),
    )
    for role, kind, boot_kind in selectors:
        artifact_id = _select_role(
            artifacts,
            by_path,
            kind=kind,
            boot_kind=boot_kind,
        )
        if artifact_id is None:
            raise ManifestError(f"inventory.json: cannot uniquely identify the {role} artifact.")
        roles[role] = artifact_id
    super_candidates = [
        artifact
        for artifact in artifacts
        if artifact.get("kind") == "dynamicPartitions"
        or (
            artifact.get("kind") == "sparse"
            and isinstance(
                _classification_details(by_path[str(artifact.get("file"))]).get("content"),
                dict,
            )
            and _classification_details(by_path[str(artifact.get("file"))])["content"].get("kind")
            == "dynamicPartitions"
        )
    ]
    if len(super_candidates) != 1:
        raise ManifestError(
            "inventory.json: cannot uniquely identify the super artifact with liblp metadata."
        )
    roles["super"] = str(super_candidates[0]["id"])
    if not any(artifact.get("kind") == "vbmeta" for artifact in artifacts):
        raise ManifestError("inventory.json: no vbmeta artifacts were found.")
    roles["vbmeta"] = _ordered_vbmeta_roles(artifacts, by_path)
    userdata_candidates: list[str] = []
    for artifact in artifacts:
        if artifact.get("id") != "userdata":
            continue
        entry = by_path[str(artifact["file"])]
        details = _classification_details(entry)
        content = details.get("content")
        if artifact.get("kind") == "filesystem" or (
            artifact.get("kind") == "sparse"
            and isinstance(content, dict)
            and content.get("kind") == "filesystem"
        ):
            userdata_candidates.append(str(artifact["id"]))
    if len(userdata_candidates) == 1:
        roles["userdataTemplate"] = userdata_candidates[0]

    kernel_id = roles["kernel"]
    kernel_entry = by_path[str(next(item["file"] for item in artifacts if item["id"] == kernel_id))]
    os_version = _classification_details(kernel_entry).get("osVersion")
    if not isinstance(os_version, dict) or not isinstance(os_version.get("release"), str):
        raise ManifestError(
            "kernel boot header has no Android os_version; cannot generate android."
        )
    release = os_version["release"].split(".", 1)[0]
    sdk = SDK_BY_RELEASE.get(release)
    if sdk is None:
        raise ManifestError(
            f"Android release {release} has no SDK entry. Update SDK_BY_RELEASE before generating."
        )
    target = str(inventory_source["target"])
    variant = target.rsplit("-", 1)[-1]
    if variant not in {"user", "userdebug", "eng"}:
        raise ManifestError(f"inventory source target {target} has an unsupported build variant.")
    patch = os_version.get("securityPatch")
    if not isinstance(patch, str):
        raise ManifestError("kernel boot header has no security patch month.")

    android_info_entries = [
        entry
        for entry in files
        if entry.get("kind") == "text"
        and entry.get("probablePurpose") == "device information key/value metadata"
        and isinstance(_classification_details(entry).get("values"), dict)
    ]
    if len(android_info_entries) != 1:
        raise ManifestError(
            "inventory must contain exactly one device information key/value record; "
            f"found {len(android_info_entries)}."
        )
    android_info_entry = android_info_entries[0]
    android_info = _classification_details(android_info_entry)["values"]

    manifest: dict[str, Any] = {
        "schemaVersion": 1,
        "source": {
            "origin": "ci.android.com",
            "branch": inventory_source["branch"],
            "target": target,
            "buildId": inventory_source["buildId"],
            "archives": archives,
        },
        "android": {
            "release": release,
            "sdk": sdk,
            "variant": variant,
            "securityPatch": patch,
        },
        "architecture": "arm64",
        "deviceFamily": "cuttlefish-phone-arm64",
        "artifacts": artifacts,
        "roles": roles,
        "logicalPartitions": [],
        "blankPartitions": BLANK_PARTITIONS,
        "androidInfo": dict(android_info),
    }

    super_artifact = next(item for item in artifacts if item["id"] == roles["super"])
    actual_entries, _ = _source_files(actual_inventories)
    super_entries = [
        entry for entry in actual_entries if entry[1].get("path") == super_artifact["file"]
    ]
    if len(super_entries) != 1:
        raise ManifestError(
            f"{super_artifact['file']}: expected exactly one source entry, "
            f"found {len(super_entries)}."
        )
    source_name, super_entry, super_source = super_entries[0]
    archive_path = archive_path_by_name.get(source_name)
    if archive_path is None:
        raise ManifestError(f"could not resolve source for {super_artifact['file']}.")
    if super_source.get("type") == "directory":
        expected_sha256 = str(super_artifact["sha256"])
        expected_size = int(super_artifact["size"])
    else:
        expected_sha256 = str(archives[0]["sha256"])
        expected_size = int(archives[0]["size"])
    try:
        with _open_image_stream(
            archive_path,
            str(super_artifact["file"]),
            expected_sha256=expected_sha256,
            expected_size=expected_size,
        ) as stream:
            is_sparse = super_artifact["kind"] == "sparse"
            detected_partitions = _read_logical_partitions(stream, sparse=is_sparse)
            if detected_partitions is None:
                raise ManifestError(f"{super_artifact['file']}: liblp metadata is missing.")
            logical_partitions = []
            for name, (size, filesystem) in sorted(detected_partitions.items()):
                logical_partitions.append(
                    {
                        "name": name,
                        "size": size,
                        "filesystem": filesystem,
                    }
                )
            manifest["logicalPartitions"] = logical_partitions
    except ManifestError:
        raise
    except (
        OSError,
        InventoryError,
        LpMetadataError,
        SparseImageError,
        zipfile.BadZipFile,
    ) as error:
        raise ManifestError(f"could not inspect {super_artifact['file']}: {error}") from error
    file_failures: list[str] = []
    _validate_inventory_records(manifest, actual_inventories, archive_path_by_name, file_failures)
    if file_failures:
        raise ManifestError("draft manifest failed file checks: " + "; ".join(file_failures))
    return manifest


def serialize_manifest(value: Mapping[str, Any]) -> str:
    """Serialize a manifest in the committed deterministic format."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def _write_manifest(path: Path, content: str) -> None:
    """Atomically write a manifest without following an output symlink."""
    if path.is_symlink():
        raise ManifestError(f"manifest output must not be a symbolic link: {path}")
    temporary_path: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".partial",
            delete=False,
        ) as output:
            temporary_path = Path(output.name)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
    except OSError as error:
        raise ManifestError(f"could not safely write manifest output {path}: {error}") from error
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def build_parser() -> argparse.ArgumentParser:
    """Build the manifest command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image manifest",
        description="Generate or validate a build-time Android image manifest.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the manifest at the positional path",
    )
    parser.add_argument("path", nargs="?", type=Path)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--source",
        type=Path,
        help="source archive or directory; defaults to Images/work/<buildId>/download",
    )
    parser.add_argument("--no-files", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Generate a draft or check one manifest."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.check:
        if arguments.path is None:
            parser.error("--check requires a manifest path")
        try:
            document = _load_json(arguments.path, description="manifest")
            failures = validate_manifest(
                document,
                include_files=not arguments.no_files,
                source=arguments.source,
                inventory_path=arguments.inventory,
            )
        except (ManifestError, OSError) as error:
            print(f"apkrun_image manifest: {error}", file=sys.stderr)
            return 2
        if failures:
            for failure in failures:
                print(f"apkrun_image manifest: {failure}", file=sys.stderr)
            return 1
        return 0

    if arguments.path is not None or arguments.no_files:
        parser.error(
            "generation uses --inventory and --out; positional paths and --no-files are for --check"
        )
    if arguments.inventory is None or arguments.out is None:
        parser.error("generation requires --inventory <inventory.json> and --out <manifest.json>")
    try:
        inventory_document = _load_json(arguments.inventory, description="inventory")
        if not isinstance(inventory_document, dict):
            raise ManifestError("inventory.json: top level must be an object.")
        manifest_document = generate_manifest(inventory_document, source=arguments.source)
        failures = _validate_manifest_shape(manifest_document)
        if failures:
            raise ManifestError("draft manifest failed validation: " + "; ".join(failures))
        _write_manifest(arguments.out, serialize_manifest(manifest_document))
    except (ManifestError, OSError, zipfile.BadZipFile) as error:
        print(f"apkrun_image manifest: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
