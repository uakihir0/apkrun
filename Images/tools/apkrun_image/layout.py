"""Device layout files: the disk plan of android-image.md §4.2 as data.

A layout names, per disk, its file, access, identifier, and GPT partitions.
Each partition takes its content from a manifest artifact `partition` or a
`blankPartitions` entry. Nothing in the Python or Swift code lists partitions
or image file names; they come from the layout and the manifest.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DISK_FILE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,19}$")
LABEL_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,35}$")
ROLE_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
USERDATA_STRATEGIES = {"blankFormattable", "prebuiltTemplate"}
SECTOR_SIZE = 512
CONSOLE_ROLES = {"systemConsole", "log", "silent", "service"}
PORT_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
BOOTCONFIG_KEY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,256}$")
GPU_PROFILES = ("drmVirgl", "guestSwiftshader", "headless")
REQUIRED_GPU_PROFILES = ("drmVirgl", "guestSwiftshader")
HOST_CAPABILITIES = {"virgl", "edid"}


class LayoutError(ValueError):
    """A layout that does not describe a buildable disk plan."""


@dataclass(frozen=True)
class LayoutPartition:
    """One GPT partition and the manifest entry that supplies its content."""

    label: str
    source: str
    blank: bool
    size: int | None


@dataclass(frozen=True)
class LayoutDisk:
    """One raw GPT disk of the plan."""

    role: str
    file: str
    read_only: bool
    identifier: str
    userdata_strategy: str | None
    partitions: tuple[LayoutPartition, ...]


@dataclass(frozen=True)
class LayoutConsolePort:
    """One console port of the plan (android-image.md §7.1)."""

    index: int
    name: str
    role: str


@dataclass(frozen=True)
class Layout:
    """The parsed parts of a layout file that the disk and bundle builders use."""

    device_family: str
    disks: tuple[LayoutDisk, ...]
    document: Mapping[str, Any]
    console_ports: tuple[LayoutConsolePort, ...] = ()
    gpu_profiles: Mapping[str, Mapping[str, Any]] | None = None


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LayoutError(message)


def _parse_partition(value: object, context: str) -> LayoutPartition:
    _require(isinstance(value, dict), f"{context} must be an object.")
    assert isinstance(value, dict)
    unknown = set(value) - {"label", "source", "blank", "size", "comment"}
    _require(not unknown, f"{context} has unknown fields: {', '.join(sorted(unknown))}.")
    label = value.get("label")
    _require(
        isinstance(label, str) and LABEL_PATTERN.fullmatch(label) is not None,
        f"{context}.label must match {LABEL_PATTERN.pattern}.",
    )
    source = value.get("source")
    _require(isinstance(source, str) and bool(source), f"{context}.source must be a name.")
    blank = value.get("blank", False)
    _require(isinstance(blank, bool), f"{context}.blank must be a boolean.")
    size = value.get("size")
    if size is not None:
        _require(
            isinstance(size, int) and not isinstance(size, bool) and size > 0,
            f"{context}.size must be a positive integer.",
        )
        _require(size % SECTOR_SIZE == 0, f"{context}.size must be a multiple of 512.")
        _require(blank, f"{context}.size is only allowed for a blank partition.")
    assert isinstance(label, str) and isinstance(source, str)
    return LayoutPartition(label=label, source=source, blank=blank, size=size)


def _parse_disk(value: object, context: str) -> LayoutDisk:
    _require(isinstance(value, dict), f"{context} must be an object.")
    assert isinstance(value, dict)
    unknown = set(value) - {
        "role",
        "file",
        "readOnly",
        "identifier",
        "userdataStrategy",
        "partitions",
        "comment",
    }
    _require(not unknown, f"{context} has unknown fields: {', '.join(sorted(unknown))}.")
    role = value.get("role")
    _require(
        isinstance(role, str) and ROLE_PATTERN.fullmatch(role) is not None,
        f"{context}.role must match {ROLE_PATTERN.pattern}.",
    )
    file = value.get("file")
    _require(
        isinstance(file, str) and DISK_FILE_PATTERN.fullmatch(file) is not None,
        f"{context}.file must match {DISK_FILE_PATTERN.pattern}.",
    )
    read_only = value.get("readOnly")
    _require(isinstance(read_only, bool), f"{context}.readOnly must be a boolean.")
    identifier = value.get("identifier")
    _require(
        isinstance(identifier, str) and IDENTIFIER_PATTERN.fullmatch(identifier) is not None,
        f"{context}.identifier must match {IDENTIFIER_PATTERN.pattern}.",
    )
    strategy = value.get("userdataStrategy")
    if strategy is not None:
        _require(
            strategy in USERDATA_STRATEGIES,
            f"{context}.userdataStrategy must be one of {', '.join(sorted(USERDATA_STRATEGIES))}.",
        )
        _require(not read_only, f"{context}.userdataStrategy needs a read-write disk.")
    partitions = value.get("partitions")
    _require(
        isinstance(partitions, list) and 1 <= len(partitions) <= 64,
        f"{context}.partitions must have 1 to 64 entries.",
    )
    assert isinstance(partitions, list)
    parsed = tuple(
        _parse_partition(item, f"{context}.partitions[{index}]")
        for index, item in enumerate(partitions)
    )
    if strategy == "blankFormattable":
        last = parsed[-1]
        _require(
            last.blank and last.size is not None,
            f"{context}: with blankFormattable the last partition must be blank and sized, "
            "so provisioning can grow it.",
        )
    assert isinstance(role, str) and isinstance(file, str) and isinstance(identifier, str)
    return LayoutDisk(
        role=role,
        file=file,
        read_only=read_only,
        identifier=identifier,
        userdata_strategy=strategy if isinstance(strategy, str) else None,
        partitions=parsed,
    )


def _bootconfig_value_ok(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= 1024
        and all(" " <= character <= "~" and character not in '"\\' for character in value)
    )


def _parse_console_ports(value: object) -> tuple[LayoutConsolePort, ...]:
    _require(
        isinstance(value, list) and 1 <= len(value) <= 32,
        "layout consolePorts must have 1 to 32 entries.",
    )
    assert isinstance(value, list)
    ports: list[LayoutConsolePort] = []
    for position, item in enumerate(value):
        context = f"layout consolePorts[{position}]"
        _require(isinstance(item, dict), f"{context} must be an object.")
        assert isinstance(item, dict)
        _require(set(item) == {"index", "name", "role"}, f"{context} needs index, name, and role.")
        _require(item["index"] == position, f"{context}.index must equal its position.")
        _require(
            isinstance(item["name"], str) and PORT_NAME_PATTERN.fullmatch(item["name"]) is not None,
            f"{context}.name must match {PORT_NAME_PATTERN.pattern}.",
        )
        _require(item["role"] in CONSOLE_ROLES, f"{context}.role is not a console role.")
        ports.append(LayoutConsolePort(index=position, name=item["name"], role=item["role"]))
    names = [port.name for port in ports]
    _require(len(set(names)) == len(names), "layout consolePorts names must be unique.")
    system = [port.index for port in ports if port.role == "systemConsole"]
    _require(system == [0], "layout consolePorts needs exactly one systemConsole, at index 0.")
    return tuple(ports)


def _parse_gpu_profiles(value: object) -> dict[str, Mapping[str, Any]]:
    _require(isinstance(value, dict), "layout gpuProfiles must be an object.")
    assert isinstance(value, dict)
    unknown = set(value) - set(GPU_PROFILES)
    _require(not unknown, f"layout gpuProfiles has unknown profiles: {', '.join(sorted(unknown))}.")
    for name in REQUIRED_GPU_PROFILES:
        _require(name in value, f"layout gpuProfiles needs {name}.")
    for name, profile in value.items():
        context = f"layout gpuProfiles.{name}"
        _require(isinstance(profile, dict), f"{context} must be an object.")
        assert isinstance(profile, dict)
        _require(
            set(profile) == {"bootconfig", "overrides", "requiredHostCapabilities"},
            f"{context} needs bootconfig, overrides, and requiredHostCapabilities.",
        )
        bootconfig = profile["bootconfig"]
        _require(
            isinstance(bootconfig, dict) and len(bootconfig) <= 64,
            f"{context}.bootconfig must be an object with at most 64 keys.",
        )
        for key, item in bootconfig.items():
            _require(
                BOOTCONFIG_KEY_PATTERN.fullmatch(key) is not None and _bootconfig_value_ok(item),
                f"{context}.bootconfig has an invalid key or value: {key}.",
            )
        overrides = profile["overrides"]
        _require(
            isinstance(overrides, list) and len(set(overrides)) == len(overrides) <= 64,
            f"{context}.overrides must be at most 64 unique keys.",
        )
        capabilities = profile["requiredHostCapabilities"]
        _require(
            isinstance(capabilities, list)
            and len(set(capabilities)) == len(capabilities)
            and set(capabilities) <= HOST_CAPABILITIES,
            f"{context}.requiredHostCapabilities must be unique items of virgl and edid.",
        )
    return dict(value)


def parse_layout(document: object, device_family: str) -> Layout:
    """Validate a layout document for one manifest's device family."""
    _require(isinstance(document, dict), "layout: top level must be an object.")
    assert isinstance(document, dict)
    family = document.get("deviceFamily")
    _require(
        family == device_family,
        f"layout {family} does not match deviceFamily {device_family}.",
    )
    disks = document.get("disks")
    _require(
        isinstance(disks, list) and bool(disks),
        "layout disks must be a non-empty array.",
    )
    assert isinstance(disks, list)
    parsed = tuple(_parse_disk(item, f"layout disks[{index}]") for index, item in enumerate(disks))
    _require(parsed[0].read_only, "layout disks[0] must be the read-only system disk.")
    roles = [disk.role for disk in parsed]
    _require(len(set(roles)) == len(roles), "layout disk roles must be unique.")
    files = [disk.file for disk in parsed]
    _require(len(set(files)) == len(files), "layout disk files must be unique.")
    identifiers = [disk.identifier for disk in parsed]
    _require(len(set(identifiers)) == len(identifiers), "layout disk identifiers must be unique.")
    labels = [partition.label for disk in parsed for partition in disk.partitions]
    duplicates = sorted({label for label in labels if labels.count(label) > 1})
    _require(not duplicates, f"layout partition labels are used twice: {', '.join(duplicates)}.")
    console_ports = (
        _parse_console_ports(document["consolePorts"]) if "consolePorts" in document else ()
    )
    gpu_profiles = (
        _parse_gpu_profiles(document["gpuProfiles"]) if "gpuProfiles" in document else None
    )
    return Layout(
        device_family=device_family,
        disks=parsed,
        document=document,
        console_ports=console_ports,
        gpu_profiles=gpu_profiles,
    )


def load_layout(path: Path, device_family: str) -> Layout:
    """Read and validate a layout file."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LayoutError(f"{path}: could not read the layout: {error}.") from None
    return parse_layout(document, device_family)


def check_sources(
    layout: Layout,
    artifacts: Sequence[Mapping[str, Any]],
    blank_partitions: Sequence[Mapping[str, Any]],
) -> None:
    """Require every layout partition to name an artifact or a blank partition."""
    artifact_partitions = {
        artifact.get("partition") for artifact in artifacts if isinstance(artifact, Mapping)
    }
    blank_names = {entry.get("partition") for entry in blank_partitions}
    for disk in layout.disks:
        for partition in disk.partitions:
            if partition.source in artifact_partitions:
                continue
            if partition.source in blank_names and partition.blank:
                continue
            if partition.source in blank_names:
                raise LayoutError(
                    f'layout partition "{partition.label}" names blank partition '
                    f'"{partition.source}" and must be blank.'
                )
            raise LayoutError(
                f'layout partition "{partition.label}" has no artifact or blank partition.'
            )
