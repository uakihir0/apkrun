"""Extract kernel and boot artifacts from an AndroidImageManifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import zipfile
from collections.abc import Iterator, Mapping, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any, BinaryIO

from apkrun_image import __version__
from apkrun_image.bootimg import (
    BootImage,
    BootImageError,
    ImageSection,
    RamdiskType,
    VendorBootImage,
    parse_boot_image,
    parse_vendor_boot_image,
)
from apkrun_image.kernel import KernelImageError, decompress_kernel
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _open_image_stream,
    _repository_root,
    _resolve_archive_root,
    validate_manifest,
)

COPY_CHUNK_SIZE = 1024 * 1024
MAX_CMDLINE_SIZE = 2048
OUTPUT_FILES = (
    "kernel",
    "ramdisk.img",
    "vendor-bootconfig.txt",
    "cmdline.txt",
    "dtb",
)


class ExtractError(ValueError):
    """The manifest, layout, source images, or derived outputs are invalid."""


def _role_artifact(document: Mapping[str, Any], role: str) -> Mapping[str, Any]:
    """Resolve one role to its manifest artifact record."""
    roles = document.get("roles")
    artifacts = document.get("artifacts")
    if not isinstance(roles, dict) or not isinstance(artifacts, list):
        raise ExtractError("manifest roles or artifacts are missing.")
    artifact_id = roles.get(role)
    for artifact in artifacts:
        if isinstance(artifact, dict) and artifact.get("id") == artifact_id:
            return artifact
    raise ExtractError(f'roles.{role} does not resolve to an artifact: "{artifact_id}".')


def _archive_declaration(
    declarations: Sequence[Mapping[str, Any]],
    archive_path: Path,
) -> Mapping[str, Any]:
    """Find the manifest's expected hash and size for a source archive."""
    matches = [
        declaration for declaration in declarations if declaration.get("name") == archive_path.name
    ]
    if not matches and len(declarations) == 1:
        matches = list(declarations)
    if len(matches) != 1:
        raise ExtractError(
            f"{archive_path}: cannot identify one matching source archive in the manifest."
        )
    return matches[0]


def _locate_artifact_source(
    source_root: Path,
    archive_paths: Sequence[Path],
    artifact: Mapping[str, Any],
) -> tuple[Path, bool]:
    """Find the one source archive or directory containing an artifact."""
    member = artifact.get("file")
    if not isinstance(member, str) or not member:
        raise ExtractError("manifest artifact is missing its file path.")

    matches: list[tuple[Path, bool]] = []
    if source_root.is_dir() and (source_root / member).is_file():
        matches.append((source_root, False))

    for archive_path in archive_paths:
        if archive_path.is_dir():
            if archive_path == source_root:
                continue
            if (archive_path / member).is_file():
                matches.append((archive_path, False))
            continue
        try:
            with zipfile.ZipFile(archive_path, "r") as archive:
                entries = [
                    entry
                    for entry in archive.infolist()
                    if entry.filename == member and not entry.is_dir()
                ]
        except (OSError, zipfile.BadZipFile) as error:
            raise ExtractError(
                f"{archive_path}: could not inspect source archive: {error}."
            ) from None
        if len(entries) > 1:
            raise ExtractError(f"{archive_path}: contains duplicate entries for {member}.")
        if entries:
            if entries[0].file_size != artifact.get("size"):
                raise ExtractError(
                    f"{member}: archive member size does not match the manifest artifact."
                )
            matches.append((archive_path, True))

    if len(matches) != 1:
        raise ExtractError(
            f"{member}: expected exactly one source entry, found {len(matches)}. "
            "Check --source and the manifest archives."
        )
    return matches[0]


@contextmanager
def _open_artifact(
    document: Mapping[str, Any],
    source_root: Path,
    archive_paths: Sequence[Path],
    artifact: Mapping[str, Any],
) -> Iterator[BinaryIO]:
    """Open one verified, read-only image member."""
    source_path, is_archive = _locate_artifact_source(source_root, archive_paths, artifact)
    member = artifact.get("file")
    if not isinstance(member, str):
        raise ExtractError("manifest artifact is missing its file path.")

    if is_archive:
        source = document.get("source")
        declarations = source.get("archives") if isinstance(source, dict) else None
        if not isinstance(declarations, list) or not all(
            isinstance(item, dict) for item in declarations
        ):
            raise ExtractError("manifest source.archives is invalid.")
        declaration = _archive_declaration(declarations, source_path)
        expected_hash = declaration.get("sha256")
        expected_size = declaration.get("size")
        if not isinstance(expected_hash, str) or not isinstance(expected_size, int):
            raise ExtractError(f"{source_path}: manifest archive hash or size is invalid.")
    else:
        expected_hash = artifact.get("sha256")
        expected_size = artifact.get("size")
        if not isinstance(expected_hash, str) or not isinstance(expected_size, int):
            raise ExtractError(f"{member}: manifest artifact hash or size is invalid.")

    try:
        with _open_image_stream(
            source_path,
            member,
            expected_sha256=expected_hash,
            expected_size=expected_size,
        ) as stream:
            yield stream
    except (ManifestError, OSError, KeyError, zipfile.BadZipFile) as error:
        raise ExtractError(str(error)) from None


def _copy_section(
    source: BinaryIO,
    image_size: int,
    section: ImageSection,
    destination: BinaryIO,
    name: str,
) -> None:
    """Copy a bounded image section without buffering it all in memory."""
    if (
        section.offset < 0
        or section.size < 0
        or section.offset > image_size
        or section.size > image_size - section.offset
    ):
        raise ExtractError(f"{name} section exceeds the source image size.")
    try:
        source.seek(section.offset)
        remaining = section.size
        while remaining:
            chunk = source.read(min(COPY_CHUNK_SIZE, remaining))
            if not chunk:
                raise ExtractError(f"{name} section is truncated in the source image.")
            view = memoryview(chunk)
            written = 0
            while written < len(view):
                count = destination.write(view[written:])
                if count is None or count <= 0:
                    raise ExtractError(f"Could not finish writing {name} section.")
                written += count
            remaining -= len(chunk)
    except (OSError, ValueError) as error:
        raise ExtractError(f"Could not copy {name} section: {error}.") from None


def _section_record(section: ImageSection) -> dict[str, int]:
    """Serialize one validated source section range."""
    return {"offset": section.offset, "size": section.size}


def _boot_record(image: BootImage) -> dict[str, object]:
    """Serialize the fields needed to reproduce boot-image extraction."""
    return {
        "cmdline": image.cmdline,
        "headerSize": image.header_size,
        "headerVersion": image.header_version,
        "kernel": _section_record(image.kernel),
        "kind": image.kind,
        "osVersion": image.os_version,
        "pageSize": image.page_size,
        "ramdisk": _section_record(image.ramdisk),
    }


def _vendor_boot_record(image: VendorBootImage) -> dict[str, object]:
    """Serialize vendor_boot metadata and its table-order fragment records."""
    return {
        "bootconfig": _section_record(image.bootconfig),
        "cmdline": image.cmdline,
        "dtb": _section_record(image.dtb),
        "fragments": [
            {
                "included": fragment.kind is not RamdiskType.RECOVERY,
                "name": fragment.name,
                "offset": fragment.offset,
                "size": fragment.size,
                "type": fragment.kind.name,
            }
            for fragment in image.fragments
        ],
        "headerSize": image.header_size,
        "headerVersion": image.header_version,
        "pageSize": image.page_size,
        "vendorRamdiskSize": image.vendor_ramdisk_size,
    }


def _layout_additions(
    layout_path: Path,
    device_family: str,
) -> list[str]:
    """Read validated, commented kernel command-line additions from a layout."""
    try:
        layout = _load_json(layout_path, description="layout")
    except ManifestError as error:
        raise ExtractError(str(error)) from None
    if not isinstance(layout, dict):
        raise ExtractError("layout: top level must be an object.")
    if layout.get("deviceFamily") != device_family:
        raise ExtractError(
            f'layout deviceFamily "{layout.get("deviceFamily")}" does not match '
            f'manifest deviceFamily "{device_family}".'
        )
    command_line = layout.get("cmdline")
    additions = command_line.get("additions") if isinstance(command_line, dict) else None
    if not isinstance(additions, list):
        raise ExtractError("layout cmdline.additions must be an array.")
    result: list[str] = []
    for index, addition in enumerate(additions):
        if not isinstance(addition, dict):
            raise ExtractError(f"layout cmdline.additions[{index}] must be an object.")
        value = addition.get("value")
        comment = addition.get("comment")
        if (
            not isinstance(value, str)
            or not value
            or not value.isprintable()
            or any(char.isspace() for char in value)
        ):
            raise ExtractError(
                f"layout cmdline.additions[{index}].value must be one non-empty argument."
            )
        if not isinstance(comment, str) or not comment.strip():
            raise ExtractError(f"layout cmdline.additions[{index}] needs a non-empty comment.")
        result.append(value)
    if not result or result[0] != "console=hvc0":
        raise ExtractError("layout cmdline.additions must start with console=hvc0.")
    return result


def _tool_versions() -> dict[str, object]:
    """Record the AOSP tool revision used as the parser's test oracle."""
    lock_path = _repository_root() / "ThirdParty/ThirdParty.lock.json"
    try:
        lock = _load_json(lock_path, description="third-party lock")
    except ManifestError as error:
        raise ExtractError(str(error)) from None
    components = lock.get("components") if isinstance(lock, dict) else None
    if not isinstance(components, list):
        raise ExtractError(f"{lock_path}: missing components array.")
    component = next(
        (
            item
            for item in components
            if isinstance(item, dict) and item.get("name") == "aosp-mkbootimg"
        ),
        None,
    )
    if not isinstance(component, dict):
        raise ExtractError(f"{lock_path}: aosp-mkbootimg pin is missing.")
    return {
        "apkrunImage": __version__,
        "unpackBootimg": {
            "commit": component.get("commit"),
            "version": component.get("version"),
        },
    }


def _file_record(path: Path) -> dict[str, object]:
    """Return the byte size and SHA-256 of one completed output file."""
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(COPY_CHUNK_SIZE):
                digest.update(chunk)
                size += len(chunk)
    except OSError as error:
        raise ExtractError(f"Could not hash output {path.name}: {error}.") from None
    return {"sha256": digest.hexdigest(), "size": size}


def _source_metadata(
    artifact: Mapping[str, Any],
) -> dict[str, object]:
    """Select the source identity fields that are copied to extraction.json."""
    return {
        "file": artifact.get("file"),
        "sha256": artifact.get("sha256"),
        "size": artifact.get("size"),
    }


def _publish_outputs(stage: Path, output_directory: Path) -> None:
    """Publish the new outputs as one recoverable set, with metadata last."""
    if output_directory.is_symlink():
        raise ExtractError(f"{output_directory}: output directory must not be a symlink.")
    if output_directory.exists() and not output_directory.is_dir():
        raise ExtractError(f"{output_directory}: output path is not a directory.")
    metadata = "extraction.json"
    filenames = (*OUTPUT_FILES, metadata)
    try:
        output_directory.mkdir(parents=True, exist_ok=True)
        existing: set[str] = set()
        for filename in filenames:
            destination = output_directory / filename
            try:
                mode = destination.lstat().st_mode
            except FileNotFoundError:
                continue
            if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                raise ExtractError(
                    f"{destination}: existing output must be a regular file or symlink."
                )
            existing.add(filename)
        backup_directory = Path(
            tempfile.mkdtemp(prefix=".apkrun-extract-previous-", dir=output_directory)
        )
    except ExtractError:
        raise
    except OSError as error:
        raise ExtractError(
            f"Could not prepare output directory {output_directory}: {error}."
        ) from None

    backups: set[str] = set()
    installed: set[str] = set()
    try:
        for filename in (metadata, *OUTPUT_FILES):
            if filename in existing:
                os.replace(output_directory / filename, backup_directory / filename)
                backups.add(filename)
        for filename in OUTPUT_FILES:
            os.replace(stage / filename, output_directory / filename)
            installed.add(filename)
        os.replace(stage / metadata, output_directory / metadata)
        installed.add(metadata)
    except OSError as error:
        rollback_errors: list[str] = []
        for filename in reversed(filenames):
            if filename in installed:
                try:
                    (output_directory / filename).unlink(missing_ok=True)
                except OSError as rollback_error:
                    rollback_errors.append(f"remove {filename}: {rollback_error}")
        for filename in OUTPUT_FILES:
            if filename in backups:
                try:
                    os.replace(backup_directory / filename, output_directory / filename)
                except OSError as rollback_error:
                    rollback_errors.append(f"restore {filename}: {rollback_error}")
        if metadata in backups and not rollback_errors:
            try:
                os.replace(backup_directory / metadata, output_directory / metadata)
            except OSError as rollback_error:
                rollback_errors.append(f"restore {metadata}: {rollback_error}")
        if rollback_errors:
            raise ExtractError(
                f"Could not publish extracted images to {output_directory}: {error}. "
                f"Rollback was incomplete; previous outputs are retained in "
                f"{backup_directory}. Details: {'; '.join(rollback_errors)}."
            ) from None
        shutil.rmtree(backup_directory, ignore_errors=True)
        raise ExtractError(
            f"Could not publish extracted images to {output_directory}: {error}."
        ) from None
    shutil.rmtree(backup_directory, ignore_errors=True)


def extract_images(
    document: Mapping[str, Any],
    *,
    output_directory: Path,
    layout_path: Path,
    source: Path | None = None,
    inventory_path: Path | None = None,
) -> dict[str, object]:
    """Validate inputs and extract the kernel, ramdisk, bootconfig, command line, and DTB."""
    failures = validate_manifest(
        document,
        include_files=True,
        source=source,
        inventory_path=inventory_path,
    )
    if failures:
        raise ExtractError(failures[0])

    source_root = _resolve_archive_root(document, source=source)
    source_archives = document.get("source", {}).get("archives", [])
    if not isinstance(source_archives, list):
        raise ExtractError("manifest source.archives must be an array.")
    archive_paths = _archive_paths(source_root, source_archives)
    device_family = document.get("deviceFamily")
    if not isinstance(device_family, str):
        raise ExtractError("manifest deviceFamily is missing.")
    additions = _layout_additions(layout_path, device_family)

    kernel_artifact = _role_artifact(document, "kernel")
    init_boot_artifact = _role_artifact(document, "genericRamdisk")
    vendor_boot_artifact = _role_artifact(document, "vendorBoot")
    for artifact in (kernel_artifact, init_boot_artifact, vendor_boot_artifact):
        member = artifact.get("file")
        if not isinstance(member, str):
            raise ExtractError("a required role artifact is missing its file path.")
        if isinstance(artifact.get("size"), bool) or not isinstance(artifact.get("size"), int):
            raise ExtractError(f"{member}: artifact size is invalid.")

    output_directory = output_directory.expanduser()
    resolved_output = output_directory.resolve()
    resolved_source = source_root.resolve()
    if source_root.is_dir() and resolved_output.is_relative_to(resolved_source):
        raise ExtractError("output directory must be outside the source image directory.")
    if source_root.is_file() and resolved_output == resolved_source:
        raise ExtractError("output directory must not replace the source archive.")
    if output_directory.is_symlink():
        raise ExtractError(f"{output_directory}: output directory must not be a symlink.")
    if output_directory.exists() and not output_directory.is_dir():
        raise ExtractError(f"{output_directory}: output path is not a directory.")
    try:
        output_directory.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise ExtractError(f"Could not create output parent: {error}.") from None

    with tempfile.TemporaryDirectory(
        prefix=f".{output_directory.name}.extract-",
        dir=output_directory.parent,
    ) as temporary_directory:
        stage = Path(temporary_directory)
        kernel_path = stage / "kernel"
        ramdisk_path = stage / "ramdisk.img"
        bootconfig_path = stage / "vendor-bootconfig.txt"
        command_line_path = stage / "cmdline.txt"
        dtb_path = stage / "dtb"

        try:
            with _open_artifact(
                document,
                source_root,
                archive_paths,
                kernel_artifact,
            ) as stream:
                image_size = int(kernel_artifact["size"])
                boot = parse_boot_image(stream, image_size, kind="boot")
                stream.seek(boot.kernel.offset)
                with kernel_path.open("w+b") as kernel_output:
                    kernel_metadata = decompress_kernel(
                        stream,
                        boot.kernel.size,
                        kernel_output,
                    )

            with _open_artifact(
                document,
                source_root,
                archive_paths,
                init_boot_artifact,
            ) as stream:
                image_size = int(init_boot_artifact["size"])
                init_boot = parse_boot_image(stream, image_size, kind="init_boot")

            with _open_artifact(
                document,
                source_root,
                archive_paths,
                vendor_boot_artifact,
            ) as stream:
                image_size = int(vendor_boot_artifact["size"])
                vendor_boot = parse_vendor_boot_image(stream, image_size)
                with ramdisk_path.open("wb") as ramdisk_output:
                    for fragment in vendor_boot.fragments:
                        if fragment.kind is not RamdiskType.RECOVERY:
                            _copy_section(
                                stream,
                                image_size,
                                fragment.section,
                                ramdisk_output,
                                f"vendor ramdisk fragment {fragment.name}",
                            )
                    with _open_artifact(
                        document,
                        source_root,
                        archive_paths,
                        init_boot_artifact,
                    ) as init_boot_stream:
                        _copy_section(
                            init_boot_stream,
                            int(init_boot_artifact["size"]),
                            init_boot.ramdisk,
                            ramdisk_output,
                            "generic ramdisk",
                        )
                with bootconfig_path.open("wb") as bootconfig_output:
                    _copy_section(
                        stream,
                        image_size,
                        vendor_boot.bootconfig,
                        bootconfig_output,
                        "vendor bootconfig",
                    )
                with dtb_path.open("wb") as dtb_output:
                    _copy_section(
                        stream,
                        image_size,
                        vendor_boot.dtb,
                        dtb_output,
                        "vendor DTB",
                    )

            command_line = " ".join(
                part for part in (vendor_boot.cmdline, boot.cmdline, *additions) if part
            )
            command_line_bytes = command_line.encode("utf-8")
            if command_line and not command_line.isprintable():
                raise ExtractError(
                    "combined kernel command line contains non-printable characters."
                )
            if len(command_line_bytes) > MAX_CMDLINE_SIZE:
                raise ExtractError(
                    f"combined kernel command line is {len(command_line_bytes)} bytes, "
                    f"over the {MAX_CMDLINE_SIZE}-byte limit."
                )
            if any(
                token.partition("=")[0].startswith("androidboot.") for token in command_line.split()
            ):
                raise ExtractError(
                    "kernel command line contains androidboot.*. Move Android boot keys "
                    "to bootconfig."
                )
            command_line_path.write_bytes(command_line_bytes)

            outputs = {
                path.name: _file_record(path)
                for path in (
                    kernel_path,
                    ramdisk_path,
                    bootconfig_path,
                    command_line_path,
                    dtb_path,
                )
            }
            extraction = {
                "buildId": document["source"]["buildId"],
                "cmdlineLength": len(command_line_bytes),
                "inputs": {
                    "genericRamdisk": _source_metadata(init_boot_artifact),
                    "kernel": _source_metadata(kernel_artifact),
                    "vendorBoot": _source_metadata(vendor_boot_artifact),
                },
                "kernel": {
                    "compression": kernel_metadata.compression.value,
                    "flags": kernel_metadata.flags,
                    "imageSize": kernel_metadata.image_size,
                    "inputSize": boot.kernel.size,
                    "outputSize": kernel_metadata.size,
                    "pageSize": kernel_metadata.page_size,
                    "textOffset": kernel_metadata.text_offset,
                },
                "outputs": outputs,
                "ramdiskFragments": _vendor_boot_record(vendor_boot)["fragments"],
                "toolVersions": _tool_versions(),
                "headers": {
                    "boot": _boot_record(boot),
                    "initBoot": _boot_record(init_boot),
                    "vendorBoot": _vendor_boot_record(vendor_boot),
                },
            }
            metadata_path = stage / "extraction.json"
            metadata_path.write_text(
                json.dumps(extraction, ensure_ascii=True, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
        except (
            BootImageError,
            KernelImageError,
            ExtractError,
            OSError,
            ValueError,
            zipfile.BadZipFile,
        ) as error:
            raise ExtractError(str(error)) from None

        failures = validate_manifest(
            document,
            include_files=True,
            source=source,
            inventory_path=inventory_path,
        )
        if failures:
            raise ExtractError(f"source images changed during extraction: {failures[0]}")
        _publish_outputs(stage, output_directory)
        return extraction


def build_parser() -> argparse.ArgumentParser:
    """Build the extract command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image extract",
        description="Extract and verify boot artifacts from an Android image manifest.",
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="source archive or directory")
    parser.add_argument("--inventory", type=Path, help="inventory.json for manifest checks")
    parser.add_argument(
        "--layout",
        type=Path,
        help="device layout; defaults to Images/tools/layouts/<deviceFamily>.json",
    )
    parser.add_argument("--out", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Validate inputs, extract boot artifacts, and report actionable failures."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        document = _load_json(arguments.manifest, description="manifest")
        if not isinstance(document, dict):
            raise ExtractError("manifest: top level must be an object.")
        device_family = document.get("deviceFamily")
        if not isinstance(device_family, str):
            raise ExtractError("manifest deviceFamily is missing.")
        layout_path = arguments.layout
        if layout_path is None:
            layout_path = _repository_root() / "Images/tools/layouts" / f"{device_family}.json"
        extract_images(
            document,
            output_directory=arguments.out,
            layout_path=layout_path,
            source=arguments.source,
            inventory_path=arguments.inventory,
        )
    except (ExtractError, ManifestError, OSError) as error:
        print(f"apkrun_image extract: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
