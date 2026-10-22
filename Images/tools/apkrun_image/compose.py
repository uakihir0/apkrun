"""Declarative, semantic EROFS composition for development Android images (#36)."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tempfile
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath

from apkrun_image.erofs import (
    BLOCK_SIZE,
    DIRECTORY,
    REGULAR_FILE,
    Entry,
    ErofsTools,
    TarMember,
    build_image,
    export_tree,
    image_geometry,
    read_tree,
    sha256_file,
    tree_members,
    write_tar,
)

TASK = "#36"
BUILD_TIMESTAMP = 1230768000
SYSTEM_EXT_PREFIX = PurePosixPath("/system_ext")
_LABEL = re.compile(r"^u:object_r:[A-Za-z0-9_]+:s0(?:[:][A-Za-z0-9_]+)?$")
_OCTAL_MODE = re.compile(r"^[0-7]{4}$")


class ComposeError(ValueError):
    """A composition plan or filesystem tree is unsafe or inconsistent."""


@dataclass(frozen=True)
class Placement:
    """One new system_ext inode and the metadata that will be written to EROFS."""

    source: Path | None
    image_path: str
    kind: str
    mode: int
    uid: int
    gid: int
    label: str

    @property
    def erofs_path(self) -> str:
        """Return the path relative to the root of the system_ext filesystem."""
        return PurePosixPath(self.image_path).relative_to(SYSTEM_EXT_PREFIX).as_posix()


@dataclass(frozen=True)
class RebuildResult:
    """A composed EROFS image and the semantic checks performed on it."""

    image: Path
    stock_sha256: str
    plan_sha256: str
    image_uuid: str
    stock_entries: dict[str, Entry]
    composed_entries: dict[str, Entry]
    added_entries: dict[str, Entry]
    stock_entries_reproduced: int
    stock_blocks: int
    filesystem_blocks: int


def _safe_posix_path(value: object, *, absolute: bool, what: str) -> PurePosixPath:
    if not isinstance(value, str) or not value:
        raise ComposeError(f"{what} must be a non-empty path.")
    path = PurePosixPath(value)
    if (
        path.is_absolute() != absolute
        or not path.parts
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ComposeError(
            f"{what} is not a normalized {'absolute' if absolute else 'relative'} path."
        )
    if "\\" in value or "\0" in value:
        raise ComposeError(f"{what} contains an unsupported path character.")
    return path


def _source_path(product_root: Path, value: object, index: int) -> Path:
    relative = _safe_posix_path(value, absolute=False, what=f"placement {index} source")
    if product_root.is_symlink():
        raise ComposeError(f"{product_root}: product root must not be a symlink.")
    root = product_root.resolve(strict=True)
    source = root.joinpath(*relative.parts)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ComposeError(f"{current}: composition sources must not be symlinks.")
    resolved = source.resolve(strict=True)
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise ComposeError(
            f"{source}: composition source must be a regular file inside Guest/product."
        )
    return resolved


def _mode(value: object, index: int) -> int:
    if isinstance(value, str) and _OCTAL_MODE.fullmatch(value):
        return int(value, 8)
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 0o7777:
        return value
    raise ComposeError(f"placement {index} mode must be a four-digit octal string or an integer.")


def _owner(value: object, index: int) -> tuple[int, int]:
    if not isinstance(value, Mapping) or set(value) != {"uid", "gid"}:
        raise ComposeError(f"placement {index} owner must contain exactly uid and gid.")
    uid, gid = value["uid"], value["gid"]
    if any(
        not isinstance(item, int) or isinstance(item, bool) or item < 0 or item > 0xFFFFFFFF
        for item in (uid, gid)
    ):
        raise ComposeError(
            f"placement {index} owner uid and gid must fit unsigned 32-bit integers."
        )
    return uid, gid


def load_placements(path: Path, product_root: Path) -> tuple[Placement, ...]:
    """Load and validate the product placement list from `Guest/product/compose.json`."""
    if product_root.is_symlink() or not product_root.is_dir():
        raise ComposeError(f"{product_root}: product root must be a real directory.")
    if path.is_symlink() or not path.is_file():
        raise ComposeError(f"{path}: composition list must be a regular file.")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ComposeError(f"{path}: cannot read composition list: {error}") from None
    if not isinstance(document, Mapping) or set(document) != {"schemaVersion", "entries"}:
        raise ComposeError(f"{path}: expected only schemaVersion and entries.")
    if (
        not isinstance(document["schemaVersion"], int)
        or isinstance(document["schemaVersion"], bool)
        or document["schemaVersion"] != 1
    ):
        raise ComposeError(f"{path}: unsupported composition schemaVersion.")
    entries = document["entries"]
    if not isinstance(entries, list) or not entries:
        raise ComposeError(f"{path}: entries must be a non-empty array.")

    placements: list[Placement] = []
    destinations: set[str] = set()
    for index, raw in enumerate(entries):
        if not isinstance(raw, Mapping) or set(raw) != {
            "source",
            "destination",
            "kind",
            "mode",
            "owner",
            "label",
        }:
            raise ComposeError(f"{path}: placement {index} has missing or unknown fields.")
        destination = _safe_posix_path(
            raw["destination"], absolute=True, what=f"placement {index} destination"
        )
        if SYSTEM_EXT_PREFIX not in destination.parents:
            raise ComposeError(f"placement {index} destination must be below /system_ext.")
        if destination.as_posix() in destinations:
            raise ComposeError(f"{path}: duplicate destination {destination}.")
        destinations.add(destination.as_posix())

        kind = raw["kind"]
        if not isinstance(kind, str):
            raise ComposeError(f"placement {index} kind must be {DIRECTORY!r} or {REGULAR_FILE!r}.")
        if kind not in {DIRECTORY, REGULAR_FILE}:
            raise ComposeError(f"placement {index} kind must be {DIRECTORY!r} or {REGULAR_FILE!r}.")
        source_value = raw["source"]
        if kind == DIRECTORY and source_value is not None:
            raise ComposeError(f"placement {index} directory source must be null.")
        if kind == REGULAR_FILE and source_value is None:
            raise ComposeError(f"placement {index} regular file needs a source.")
        source = None if source_value is None else _source_path(product_root, source_value, index)

        label = raw["label"]
        if not isinstance(label, str) or not _LABEL.fullmatch(label):
            raise ComposeError(f"placement {index} label is not a valid system SELinux context.")
        uid, gid = _owner(raw["owner"], index)
        placements.append(
            Placement(
                source=source,
                image_path=destination.as_posix(),
                kind=kind,
                mode=_mode(raw["mode"], index),
                uid=uid,
                gid=gid,
                label=label,
            )
        )

    by_destination = {item.image_path: item for item in placements}
    for placement in placements:
        for parent in PurePosixPath(placement.image_path).parents:
            parent_placement = by_destination.get(parent.as_posix())
            if parent_placement is not None and parent_placement.kind != DIRECTORY:
                raise ComposeError(
                    f"{path}: {parent} is a file but also a parent of another placement."
                )
    ordered = tuple(sorted(placements, key=lambda item: item.image_path))
    return ordered


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_tree_target(tree_root: Path, image_path: str) -> Path:
    relative = PurePosixPath(image_path).relative_to(SYSTEM_EXT_PREFIX)
    root = tree_root.resolve(strict=True)
    target = root.joinpath(*relative.parts)
    current = root
    for part in relative.parts[:-1]:
        current = current / part
        if current.is_symlink():
            raise ComposeError(f"{current}: exported parent directories must not be symlinks.")
    if not target.resolve(strict=False).is_relative_to(root):
        raise ComposeError(f"{target}: destination escapes the exported system_ext tree.")
    return target


def _preflight_placements(
    placements: Sequence[Placement], product: Path, tree: Path
) -> tuple[tuple[Placement, Path, Path | None], ...]:
    """Validate every input and target before the exported tree is changed."""
    by_destination: dict[str, Placement] = {}
    for placement in placements:
        destination = _safe_posix_path(
            placement.image_path, absolute=True, what="placement destination"
        )
        if SYSTEM_EXT_PREFIX not in destination.parents:
            raise ComposeError(f"{placement.image_path}: destination must be below /system_ext.")
        if placement.kind not in {DIRECTORY, REGULAR_FILE}:
            raise ComposeError(f"{placement.image_path}: unsupported inode kind.")
        if placement.image_path in by_destination:
            raise ComposeError(f"{placement.image_path}: duplicate destination.")
        by_destination[placement.image_path] = placement

    planned: list[tuple[Placement, Path, Path | None]] = []
    for placement in sorted(placements, key=lambda item: item.image_path):
        target = _safe_tree_target(tree, placement.image_path)
        if target.exists() or target.is_symlink():
            raise ComposeError(
                f"{placement.image_path}: composition refuses to replace a stock entry."
            )
        for parent in target.parents:
            if parent == tree:
                break
            if not parent.is_relative_to(tree):
                raise ComposeError(f"{target}: destination parent escapes the exported tree.")
            image_parent = SYSTEM_EXT_PREFIX / parent.relative_to(tree).as_posix()
            planned_parent = by_destination.get(image_parent.as_posix())
            if planned_parent is not None:
                if planned_parent.kind != DIRECTORY:
                    raise ComposeError(
                        f"{image_parent}: parent is a file but also a parent of another placement."
                    )
                continue
            if parent.is_symlink() or not parent.is_dir():
                raise ComposeError(
                    f"{placement.image_path}: parent directory is absent or unsafe; list new "
                    "directories explicitly before their contents."
                )

        source = placement.source
        if placement.kind == REGULAR_FILE:
            if source is None or source.is_symlink():
                raise ComposeError(f"{placement.image_path}: source is missing or a symlink.")
            resolved = source.resolve(strict=True)
            if not resolved.is_relative_to(product) or not resolved.is_file():
                raise ComposeError(
                    f"{source}: composition source must be a regular file inside Guest/product."
                )
            source = resolved
        elif source is not None:
            raise ComposeError(f"{placement.image_path}: directory must not have a source.")
        planned.append((placement, target, source))
    return tuple(planned)


def apply_placements(
    placements: Sequence[Placement],
    product_root: Path,
    tree_root: Path,
    *,
    entry_mtime: str | None = None,
) -> tuple[dict[str, Entry], list[TarMember]]:
    """Add only planned entries to an exported tree and return their expected metadata."""
    if product_root.is_symlink() or not product_root.is_dir():
        raise ComposeError(f"{product_root}: product root must be a real directory.")
    if tree_root.is_symlink() or not tree_root.is_dir():
        raise ComposeError(f"{tree_root}: exported tree root must be a real directory.")
    expected: dict[str, Entry] = {}
    members: list[TarMember] = []
    product = product_root.resolve(strict=True)
    tree = tree_root.resolve(strict=True)
    planned = _preflight_placements(placements, product, tree)
    created: list[Path] = []
    try:
        for placement, target, source in planned:
            size = 0
            digest: str | None = None
            member_source: Path | None = None
            if placement.kind == DIRECTORY:
                target.mkdir()
                created.append(target)
            else:
                if source is None:
                    raise ComposeError(f"{placement.image_path}: regular file has no source.")
                try:
                    with source.open("rb") as input_stream, target.open("xb") as output_stream:
                        created.append(target)
                        shutil.copyfileobj(input_stream, output_stream, length=1024 * 1024)
                except OSError as error:
                    raise ComposeError(
                        f"{placement.image_path}: cannot copy composition source: {error}"
                    ) from None
                size = target.stat().st_size
                digest = _sha256(target)
                member_source = target

            erofs_path = "/" + placement.erofs_path
            entry = Entry(
                path=erofs_path,
                kind=placement.kind,
                mode=placement.mode,
                uid=placement.uid,
                gid=placement.gid,
                size=size,
                mtime=entry_mtime if entry_mtime is not None else str(BUILD_TIMESTAMP),
                sha256=digest,
                label=placement.label,
            )
            expected[erofs_path] = entry
            members.append(
                TarMember(
                    path=erofs_path,
                    kind=placement.kind,
                    mode=placement.mode,
                    uid=placement.uid,
                    gid=placement.gid,
                    mtime=BUILD_TIMESTAMP,
                    label=placement.label,
                    source=member_source,
                )
            )
    except BaseException:
        for target in reversed(created):
            if target.is_dir() and not target.is_symlink():
                target.rmdir()
            else:
                target.unlink(missing_ok=True)
        raise
    return expected, members


def _entry_differences(
    before: Mapping[str, Entry],
    after: Mapping[str, Entry],
    *,
    added: Mapping[str, Entry] | None = None,
    allow_directory_size_changes: bool = False,
) -> list[str]:
    """Return semantic differences between stock and rebuilt EROFS entry maps."""
    expected_entries = added or {}
    expected_new = set(expected_entries)
    receiving = {str(PurePosixPath(path).parent) for path in expected_new}
    problems: list[str] = []
    for path in sorted(set(before) - set(after)):
        problems.append(f"{path}: missing from the rebuild")
    for path in sorted(set(after) - set(before)):
        if path not in expected_new:
            problems.append(f"{path}: new in the rebuild and not expected")
    for path in sorted(expected_new - set(after)):
        problems.append(f"{path}: expected in the rebuild but missing")

    fields = ("kind", "mode", "uid", "gid", "mtime", "target", "sha256", "label")
    for path in sorted(set(before) & set(after)):
        if path in expected_new:
            problems.append(f"{path}: expected to be new but it exists in the stock partition")
            continue
        old, new = before[path], after[path]
        for field in fields:
            if getattr(old, field) != getattr(new, field):
                problems.append(f"{path}: {field} differs")
        may_change_size = old.kind == DIRECTORY and (
            allow_directory_size_changes or path in receiving
        )
        if not may_change_size and old.size != new.size:
            problems.append(f"{path}: size differs")

    for path in sorted(expected_new & set(after)):
        expected, actual = expected_entries[path], after[path]
        for field in fields:
            if getattr(expected, field) != getattr(actual, field):
                problems.append(f"{path}: {field} differs from the placement plan")
        if expected.kind != DIRECTORY and expected.size != actual.size:
            problems.append(f"{path}: size differs from the placement plan")
    return problems


def _build_ero(
    image_tools: ErofsTools,
    members: Sequence[TarMember],
    scratch: Path,
    name: str,
    image_uuid: str,
) -> Path:
    tar_path = scratch / f"{name}.tar"
    image_path = scratch / f"{name}.erofs"
    write_tar(members, tar_path)
    build_image(
        image_tools,
        tar_path,
        image_path,
        timestamp=BUILD_TIMESTAMP,
        uuid=image_uuid,
    )
    tar_path.unlink()
    return image_path


def _rebuild_system_ext(
    image_tools: ErofsTools,
    stock_image: Path,
    product_root: Path,
    scratch: Path,
    *,
    image_uuid: str,
) -> RebuildResult:
    """Rebuild system_ext with the listed product entries and verify its exact semantic diff."""
    try:
        normalized_uuid = str(uuid.UUID(image_uuid))
    except ValueError:
        raise ComposeError(f"{image_uuid!r}: image UUID is invalid.") from None

    plan_path = product_root / "compose.json"
    placements = load_placements(plan_path, product_root)
    plan_sha256 = sha256_file(plan_path)
    stock_tree = scratch / "system-ext-stock-tree"
    export_tree(image_tools, stock_image, stock_tree)
    stock_entries = read_tree(image_tools, stock_image, stock_tree)
    block_size, stock_blocks, _ = image_geometry(image_tools, stock_image)
    if block_size != BLOCK_SIZE:
        raise ComposeError(f"stock system_ext uses {block_size}-byte blocks, not {BLOCK_SIZE}.")
    mtimes = {entry.mtime for entry in stock_entries.values()}
    if len(mtimes) != 1:
        raise ComposeError("stock system_ext entries do not share one timestamp.")

    stock_members = tree_members(stock_entries, stock_tree, BUILD_TIMESTAMP)

    roundtrip_image = _build_ero(
        image_tools,
        stock_members,
        scratch,
        "system-ext-roundtrip",
        normalized_uuid,
    )
    roundtrip_tree = scratch / "system-ext-roundtrip-tree"
    export_tree(image_tools, roundtrip_image, roundtrip_tree)
    roundtrip_entries = read_tree(image_tools, roundtrip_image, roundtrip_tree)
    roundtrip_problems = _entry_differences(
        stock_entries, roundtrip_entries, allow_directory_size_changes=True
    )
    if roundtrip_problems:
        raise ComposeError(f"stock system_ext round trip changed {roundtrip_problems[0]}.")
    shutil.rmtree(roundtrip_tree)
    roundtrip_image.unlink()

    added_entries, added_members = apply_placements(
        placements,
        product_root,
        stock_tree,
        entry_mtime=next(iter(mtimes)),
    )
    output_image = _build_ero(
        image_tools,
        sorted(stock_members + added_members, key=lambda member: member.path),
        scratch,
        "system-ext-composed",
        normalized_uuid,
    )
    composed_tree = scratch / "system-ext-composed-tree"
    export_tree(image_tools, output_image, composed_tree)
    composed_entries = read_tree(image_tools, output_image, composed_tree)
    problems = _entry_differences(
        stock_entries,
        composed_entries,
        added=added_entries,
    )
    if problems:
        raise ComposeError(f"composed system_ext differs from its plan: {problems[0]}.")

    block_size, filesystem_blocks, _ = image_geometry(image_tools, output_image)
    if block_size != BLOCK_SIZE:
        raise ComposeError(f"rebuilt system_ext uses {block_size}-byte blocks, not {BLOCK_SIZE}.")
    if output_image.stat().st_size != filesystem_blocks * block_size:
        raise ComposeError("rebuilt system_ext has bytes beyond its EROFS filesystem.")
    shutil.rmtree(composed_tree)

    return RebuildResult(
        image=output_image,
        stock_sha256=sha256_file(stock_image),
        plan_sha256=plan_sha256,
        image_uuid=normalized_uuid,
        stock_entries=stock_entries,
        composed_entries=composed_entries,
        added_entries=added_entries,
        stock_entries_reproduced=len(stock_entries),
        stock_blocks=stock_blocks,
        filesystem_blocks=filesystem_blocks,
    )


def rebuild_system_ext(
    image_tools: ErofsTools,
    stock_image: Path,
    product_root: Path,
    scratch: Path,
    *,
    image_uuid: str,
) -> RebuildResult:
    """Rebuild system_ext in a private work directory and retain only the checked image."""
    if scratch.is_symlink():
        raise ComposeError(f"{scratch}: scratch root must not be a symlink.")
    try:
        scratch.mkdir(parents=True, exist_ok=True)
        scratch_root = scratch.resolve(strict=True)
    except OSError as error:
        raise ComposeError(f"{scratch}: cannot create scratch root: {error}") from None
    if not scratch_root.is_dir():
        raise ComposeError(f"{scratch_root}: scratch root must be a directory.")

    work_directory = Path(tempfile.mkdtemp(prefix=".apkrun-compose-", dir=scratch_root))
    output_image: Path | None = None
    output_identity: tuple[int, int] | None = None
    try:
        result = _rebuild_system_ext(
            image_tools,
            stock_image,
            product_root,
            work_directory,
            image_uuid=image_uuid,
        )
        candidate = scratch_root / f"system-ext-{uuid.uuid4().hex}.erofs"
        source_identity = result.image.stat(follow_symlinks=False)
        try:
            os.link(result.image, candidate, follow_symlinks=False)
        except FileExistsError as error:
            raise ComposeError(f"{candidate}: output already exists.") from error
        output_image = candidate
        output_identity = (source_identity.st_dev, source_identity.st_ino)
        created = output_image.lstat()
        if (created.st_dev, created.st_ino) != output_identity:
            raise ComposeError(f"{output_image}: published image differs from the verified build.")
        return replace(result, image=output_image)
    except BaseException:
        if output_image is not None and output_identity is not None:
            try:
                current = output_image.lstat()
            except FileNotFoundError:
                current = None
            if current is not None and (current.st_dev, current.st_ino) == output_identity:
                output_image.unlink()
        raise
    finally:
        shutil.rmtree(work_directory, ignore_errors=True)
