"""Inject the guest Mesa libraries into the vendor partition of an Android image (#099, step 2
offline).

The inputs are an AndroidImageManifest, its source archive, and the verified output of
`scripts/guest/build-mesa-android.sh`. The tool reads `vendor_a` and `system_a` from `super.img`
through the manifest, exports the vendor EROFS, and rebuilds it with the four Mesa libraries added.
Every other entry must match the stock partition in kind, mode, owner, timestamp, content, target,
and label. The labels of the new files come from the image's own file contexts. The partition keeps
its size in the super metadata, and its dm-verity tree and footer are made again with the pinned
avbtool.

The top-level vbmeta is not changed. It still holds the stock vendor root digest, so the output
does not verify until vbmeta is signed again (see the output record). The tool never boots
anything.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Iterable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from apkrun_image import lp
from apkrun_image.erofs import (
    BLOCK_SIZE,
    DIRECTORY,
    MKFS_COMPRESSION,
    REGULAR_FILE,
    Entry,
    ErofsTools,
    TarMember,
    build_image,
    export_tree,
    extract_file,
    image_geometry,
    load_component,
    read_tree,
    sha256_file,
    tree_members,
    verify_tools,
    write_tar,
)
from apkrun_image.extract import _open_artifact, _role_artifact
from apkrun_image.manifest import (
    _archive_paths,
    _load_json,
    _repository_root,
    _resolve_archive_root,
    validate_manifest,
)
from apkrun_image.selinux_labels import (
    ContextRule,
    ContextsError,
    check_reproduces,
    label_for,
    last_rule_label,
    load_contexts,
    read_contexts_text,
    summarize,
)

PARTITION = "vendor_a"
SYSTEM_PARTITION = "system_a"
PLAT_CONTEXTS = "/system/etc/selinux/plat_file_contexts"
VENDOR_CONTEXTS = "/etc/selinux/vendor_file_contexts"
MESA_SOURCE_DIRECTORY = "vendor/lib64"
MESA_TARGET_DIRECTORY = "lib64/egl"
MESA_LIBRARIES = (
    "libEGL_mesa.so",
    "libGLESv2_mesa.so",
    "libGLESv1_CM_mesa.so",
    "libgallium_dri.so",
)
MESA_FILE_MODE = 0o644
MESA_COMPONENT = "mesa"
AVBTOOL_COMPONENT = "aosp-avbtool"
AVBTOOL_PATH = "Images/tools/vendor/avb/avbtool.py"
VERITY_PARTITION = "vendor"
VERITY_ALGORITHM = "sha256"
# The EROFS build time of the stock image (-T 1230768000, 2009-01-01T00:00:00Z).
BUILD_TIMESTAMP = 1230768000
COPY_CHUNK = 64 * 1024 * 1024
OUTPUT_IMAGE = "vendor_a.img"
OUTPUT_RECORD = "inject.json"
COMPARED_FIELDS = ("kind", "mode", "uid", "gid", "mtime", "target", "sha256", "label")
UUID_NAMESPACE = uuid.UUID("3a3b0f5e-8c1d-4a6e-9f7b-0b1e2c3d4e5f")


class InjectError(ValueError):
    """The inputs, the rebuilt partition, or its checks are not acceptable."""


@dataclass(frozen=True)
class MesaLibrary:
    """One verified Mesa library of the build output."""

    name: str
    source: Path
    sha256: str
    size: int

    @property
    def target(self) -> str:
        """Return the EROFS path of the library in the vendor partition."""
        return f"/{MESA_TARGET_DIRECTORY}/{self.name}"


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_mesa_output(
    directory: Path, lock_mesa: Mapping[str, Any]
) -> tuple[list[MesaLibrary], dict[str, Any]]:
    """Check the Mesa build output against its manifest and the lock's `mesa` entry."""
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise InjectError(f"{manifest_path}: the Mesa build manifest is missing.")
    document = _load_json(manifest_path, description="Mesa build manifest")
    if not isinstance(document, dict) or document.get("component") != "mesa-android":
        raise InjectError(f"{manifest_path}: not a mesa-android build manifest.")
    if document.get("schemaVersion") != 1:
        raise InjectError(f"{manifest_path}: unsupported schemaVersion.")
    mesa = document.get("mesa")
    if not isinstance(mesa, dict):
        raise InjectError(f"{manifest_path}: the mesa record is missing.")
    if mesa.get("commit") != lock_mesa.get("commit") or mesa.get("version") != lock_mesa.get(
        "version"
    ):
        raise InjectError(
            "the Mesa output was built from another commit or version than the lock pins; "
            "rebuild it."
        )
    if document.get("buildFlags") != lock_mesa.get("buildFlags"):
        raise InjectError(
            "the Mesa output was built with other Meson flags than the lock pins; rebuild it."
        )
    records = document.get("files")
    if not isinstance(records, list) or len(records) != len(MESA_LIBRARIES):
        raise InjectError(f"{manifest_path}: expected exactly {len(MESA_LIBRARIES)} shipped files.")
    by_path = {record.get("path"): record for record in records if isinstance(record, dict)}
    libraries: list[MesaLibrary] = []
    for name in MESA_LIBRARIES:
        relative = f"{MESA_SOURCE_DIRECTORY}/{name}"
        record = by_path.get(relative)
        if record is None:
            raise InjectError(f"{relative}: not listed in the Mesa build manifest.")
        if record.get("class") != "ELF64" or record.get("machine") != "AArch64":
            raise InjectError(f"{relative}: the manifest does not record an AArch64 ELF64 file.")
        if record.get("soname") != name:
            raise InjectError(f"{relative}: SONAME {record.get('soname')!r} is not {name!r}.")
        source = directory / relative
        if source.is_symlink() or not source.is_file():
            raise InjectError(f"{source}: the Mesa library is missing or is not a regular file.")
        size = source.stat().st_size
        digest = sha256_file(source)
        if size != record.get("size") or digest != record.get("sha256"):
            raise InjectError(f"{source}: size or SHA-256 differs from the Mesa build manifest.")
        libraries.append(MesaLibrary(name=name, source=source, sha256=digest, size=size))
    provenance = {
        "manifestSha256": sha256_file(manifest_path),
        "commit": mesa["commit"],
        "version": mesa["version"],
        "ndk": (document.get("tools") or {}).get("ndk"),
        "buildFlags": document.get("buildFlags"),
    }
    return libraries, provenance


def verify_avbtool(repository: Path, lock_avb: Mapping[str, Any]) -> Path:
    """Return the vendored avbtool after checking its SHA-256 against the lock."""
    path = repository / AVBTOOL_PATH
    files = lock_avb.get("files")
    pinned = None
    if isinstance(files, list):
        for entry in files:
            if isinstance(entry, dict) and entry.get("path") == AVBTOOL_PATH:
                pinned = entry.get("sha256")
    if not isinstance(pinned, str):
        raise InjectError("the lock does not pin the vendored avbtool.")
    if path.is_symlink() or not path.is_file():
        raise InjectError(f"{path}: the vendored avbtool is missing.")
    if sha256_file(path) != pinned:
        raise InjectError(f"{path}: SHA-256 differs from the lock.")
    return path


def run_avbtool(avbtool: Path, arguments: Sequence[str]) -> str:
    """Run the vendored avbtool in isolated mode and return its output."""
    result = subprocess.run(
        [sys.executable, "-I", str(avbtool), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        tail = result.stderr.strip().splitlines()[-2:]
        raise InjectError(
            f"avbtool {arguments[0]} failed with exit {result.returncode}: {' | '.join(tail)}"
        )
    return result.stdout


def parse_hashtrees(info_text: str) -> dict[str, dict[str, Any]]:
    """Return the hashtree descriptors of `avbtool info_image`, keyed by partition name."""
    blocks: dict[str, dict[str, Any]] = {}
    current: dict[str, Any] | None = None
    for raw in info_text.splitlines():
        line = raw.strip()
        if line.endswith("descriptor:") or line.startswith("Prop:"):
            if line == "Hashtree descriptor:":
                current = {}
            else:
                current = None
            continue
        if current is None or ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if key == "Partition Name":
            current["name"] = value
            blocks[value] = current
        elif key == "Root Digest":
            current["rootDigest"] = value
        elif key == "Salt":
            current["salt"] = value
        elif key == "Image Size":
            current["imageSize"] = int(value.split()[0])
    return {name: block for name, block in blocks.items() if "rootDigest" in block}


def read_super_partition(
    document: Mapping[str, Any],
    source_root: Path,
    archive_paths: Sequence[Path],
    partition: str,
    destination: Path,
) -> str:
    """Write one logical partition of the manifest's super image to `destination`.

    Return the SHA-256 of the partition.
    """
    logical = next(
        (item for item in document.get("logicalPartitions", []) if item.get("name") == partition),
        None,
    )
    if not isinstance(logical, dict):
        raise InjectError(f"{partition}: the manifest has no such logical partition.")
    if logical.get("filesystem") != "erofs":
        raise InjectError(f"{partition}: the manifest does not describe it as EROFS.")
    size = logical.get("size")
    if not isinstance(size, int) or size <= 0:
        raise InjectError(f"{partition}: the manifest size is invalid.")
    super_artifact = _role_artifact(document, "super")
    with _open_artifact(document, source_root, archive_paths, super_artifact) as stream:
        metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if metadata is None:
            raise InjectError("super.img has no liblp metadata.")
        found = next((item for item in metadata.logical_partitions if item.name == partition), None)
        if found is None or found.size != size:
            raise InjectError(f"{partition}: super metadata does not match the manifest.")
        digest = hashlib.sha256()
        with destination.open("wb") as handle:
            offset = 0
            while offset < size:
                length = min(COPY_CHUNK, size - offset)
                chunk = lp.read_partition_range(stream, found, offset, length, sparse=True)
                handle.write(chunk)
                digest.update(chunk)
                offset += length
    return digest.hexdigest()


def read_member(
    document: Mapping[str, Any], source_root: Path, archive_paths: Sequence[Path], artifact_id: str
) -> bytes:
    """Read one manifest artifact by id through the verified opener."""
    artifacts = document.get("artifacts")
    artifact = next(
        (
            item
            for item in artifacts or []
            if isinstance(item, dict) and item.get("id") == artifact_id
        ),
        None,
    )
    if artifact is None:
        raise InjectError(f"{artifact_id}: no manifest artifact has this id.")
    with _open_artifact(document, source_root, archive_paths, artifact) as stream:
        return stream.read()


def compare_entries(
    before: Mapping[str, Entry],
    after: Mapping[str, Entry],
    *,
    added: Iterable[str] = (),
    directory_sizes: bool = False,
) -> list[str]:
    """Return every difference between two exports. `added` names the only new entries allowed."""
    expected_new = set(added)
    problems: list[str] = []
    for path in sorted(set(before) - set(after)):
        problems.append(f"{path}: missing from the rebuild")
    for path in sorted(set(after) - set(before)):
        if path not in expected_new:
            problems.append(f"{path}: new in the rebuild and not expected")
    for path in sorted(expected_new - set(after)):
        problems.append(f"{path}: expected in the rebuild but missing")
    for path in sorted(set(before) & set(after)):
        if path in expected_new:
            problems.append(f"{path}: expected to be new but it exists in the stock partition")
            continue
        old, new = before[path], after[path]
        for field in COMPARED_FIELDS:
            if getattr(old, field) != getattr(new, field):
                problems.append(f"{path}: {field} differs")
        if directory_sizes or old.kind != DIRECTORY:
            if old.size != new.size:
                problems.append(f"{path}: size differs")
    return problems


def _mesa_entries(
    libraries: Sequence[MesaLibrary], rules: Sequence[ContextRule], stock_mtime: str
) -> tuple[dict[str, Entry], list[TarMember]]:
    entries: dict[str, Entry] = {}
    members: list[TarMember] = []
    for library in libraries:
        label = label_for(rules, library.target, REGULAR_FILE)
        if label is None:
            raise ContextsError(f"{library.target}: the file contexts give no label.")
        if last_rule_label(rules, library.target, REGULAR_FILE) != label:
            raise ContextsError(
                f"{library.target}: the longest-stem and last-match rules disagree."
            )
        entries[library.target] = Entry(
            path=library.target,
            kind=REGULAR_FILE,
            mode=MESA_FILE_MODE,
            uid=0,
            gid=0,
            size=library.size,
            mtime=stock_mtime,
            sha256=library.sha256,
            label=label,
        )
        members.append(
            TarMember(
                path=library.target,
                kind=REGULAR_FILE,
                mode=MESA_FILE_MODE,
                uid=0,
                gid=0,
                mtime=BUILD_TIMESTAMP,
                label=label,
                source=library.source,
            )
        )
    return entries, members


def _rebuild(
    tools: ErofsTools,
    members: Sequence[TarMember],
    scratch: Path,
    name: str,
    image_uuid: str,
) -> Path:
    tar_path = scratch / f"{name}.tar"
    image_path = scratch / f"{name}.part"
    write_tar(members, tar_path)
    build_image(tools, tar_path, image_path, timestamp=BUILD_TIMESTAMP, uuid=image_uuid)
    tar_path.unlink()
    return image_path


def _ensure_output(output: Path, repository: Path) -> Path:
    resolved = output.expanduser().resolve()
    if resolved == repository.resolve() or repository.resolve() in resolved.parents:
        raise InjectError(f"{resolved}: the output must be outside the repository.")
    if resolved.exists() and (not resolved.is_dir() or any(resolved.iterdir())):
        raise InjectError(f"{resolved}: the output directory must not exist or must be empty.")
    resolved.mkdir(parents=True, exist_ok=True)
    return resolved


@contextmanager
def _work_area(work_directory: Path | None) -> Iterator[str]:
    """Yield a temporary work directory, or a caller-chosen one that is kept (it must be empty)."""
    if work_directory is None:
        with tempfile.TemporaryDirectory(prefix="apkrun-099-inject-") as name:
            yield name
        return
    resolved = work_directory.expanduser().resolve()
    if resolved.exists() and (not resolved.is_dir() or any(resolved.iterdir())):
        raise InjectError(f"{resolved}: the work directory must not exist or must be empty.")
    resolved.mkdir(parents=True, exist_ok=True)
    yield str(resolved)


@dataclass(frozen=True)
class RebuildResult:
    """The rebuilt EROFS image of one partition, and what was checked on it."""

    image: Path
    vendor_contexts: str
    stock_entries: dict[str, Entry]
    injected_entries: dict[str, Entry]
    mesa_entries: dict[str, Entry]
    rules: list[ContextRule]
    reproduced: int
    stock_blocks: int
    fs_blocks: int


def rebuild_partition(
    tools: ErofsTools,
    stock_image: Path,
    scratch: Path,
    libraries: Sequence[MesaLibrary],
    *,
    plat_name: str,
    plat_text: str,
    image_uuid: str,
) -> RebuildResult:
    """Rebuild an EROFS partition with the Mesa libraries, and check the result against the stock.

    A plain rebuild of the stock must reproduce it exactly. The injected rebuild may differ from
    the stock only by the new Mesa entries and by the sizes of the directories that hold them.
    """
    stock_tree = scratch / "stock-tree"
    export_tree(tools, stock_image, stock_tree)
    stock_entries = read_tree(tools, stock_image, stock_tree)
    block_size, stock_blocks, _ = image_geometry(tools, stock_image)
    if block_size != BLOCK_SIZE:
        raise InjectError(f"the stock partition uses {block_size}-byte blocks, not {BLOCK_SIZE}.")

    vendor_text = read_contexts_text(stock_tree / VENDOR_CONTEXTS.lstrip("/"))
    rules = load_contexts([(plat_name, plat_text), (f"{PARTITION}:{VENDOR_CONTEXTS}", vendor_text)])
    reproduced = check_reproduces(rules, stock_entries)

    stock_mtimes = {entry.mtime for entry in stock_entries.values()}
    if len(stock_mtimes) != 1:
        raise InjectError(
            "the stock entries do not share one timestamp; the rebuild cannot match them."
        )
    stock_mtime = stock_mtimes.pop()

    base_members = tree_members(stock_entries, stock_tree, BUILD_TIMESTAMP)
    round_trip = _rebuild(tools, base_members, scratch, "round-trip", image_uuid)
    round_tree = scratch / "round-trip-tree"
    export_tree(tools, round_trip, round_tree)
    problems = compare_entries(
        stock_entries, read_tree(tools, round_trip, round_tree), directory_sizes=True
    )
    if problems:
        raise InjectError(f"the round trip changed the stock partition: {problems[0]}")
    shutil.rmtree(round_tree)
    round_trip.unlink()

    target_directory = stock_entries.get(f"/{MESA_TARGET_DIRECTORY}")
    if target_directory is None or target_directory.kind != DIRECTORY:
        raise InjectError(f"/{MESA_TARGET_DIRECTORY}: the stock partition has no such directory.")
    for library in libraries:
        if library.target in stock_entries:
            raise InjectError(f"{library.target}: the stock partition already has this file.")
    mesa_entries, mesa_members = _mesa_entries(libraries, rules, stock_mtime)
    inject_image = _rebuild(
        tools,
        sorted(base_members + mesa_members, key=lambda item: item.path),
        scratch,
        "inject",
        image_uuid,
    )
    inject_tree = scratch / "inject-tree"
    export_tree(tools, inject_image, inject_tree)
    injected_entries = read_tree(tools, inject_image, inject_tree)
    problems = compare_entries(stock_entries, injected_entries, added=mesa_entries.keys())
    for path, expected in mesa_entries.items():
        actual = injected_entries.get(path)
        if actual is None:
            continue
        for field in (*COMPARED_FIELDS, "size"):
            if getattr(actual, field) != getattr(expected, field):
                problems.append(f"{path}: {field} differs from the expected Mesa entry")
    if problems:
        raise InjectError(f"the injected partition differs from the plan: {problems[0]}")
    shutil.rmtree(inject_tree)

    _, fs_blocks, _ = image_geometry(tools, inject_image)
    if inject_image.stat().st_size != fs_blocks * block_size:
        raise InjectError("the rebuilt EROFS image has trailing bytes after its filesystem.")
    return RebuildResult(
        image=inject_image,
        vendor_contexts=vendor_text,
        stock_entries=stock_entries,
        injected_entries=injected_entries,
        mesa_entries=mesa_entries,
        rules=rules,
        reproduced=reproduced,
        stock_blocks=stock_blocks,
        fs_blocks=fs_blocks,
    )


def seal_partition(
    avbtool: Path,
    fs_image: Path,
    output: Path,
    *,
    partition_size: int,
    salt: str,
    scratch: Path,
) -> str:
    """Write the partition with a new dm-verity tree and an unsigned footer; return the root digest.

    The footer uses the same algorithm as the stock vendor footer (NONE; the top-level vbmeta
    authenticates it). FEC is not generated, because the `fec` tool is not pinned (IR-624).
    """
    if output.exists():
        raise InjectError(f"{output}: the partition output already exists.")
    shutil.copyfile(fs_image, output)
    run_avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image",
            str(output),
            "--partition_size",
            str(partition_size),
            "--partition_name",
            VERITY_PARTITION,
            "--salt",
            salt,
            "--hash_algorithm",
            VERITY_ALGORITHM,
            "--algorithm",
            "NONE",
            "--do_not_generate_fec",
        ],
    )
    # avbtool looks for <partition name><extension of --image> in the directory of --image.
    verify_dir = scratch / f"verify-{output.stem}"
    verify_dir.mkdir()
    link = verify_dir / f"{VERITY_PARTITION}.part"
    link.symlink_to(output)
    verified = run_avbtool(avbtool, ["verify_image", "--image", str(link)])
    if "Successfully verified sha256 hashtree" not in verified:
        raise InjectError("avbtool did not verify the new hashtree of the partition.")
    if output.stat().st_size != partition_size:
        raise InjectError("the sealed partition does not have the size of its super metadata.")
    info = run_avbtool(avbtool, ["info_image", "--image", str(output)])
    digest = parse_hashtrees(info).get(VERITY_PARTITION, {}).get("rootDigest")
    if not isinstance(digest, str):
        raise InjectError("the sealed partition has no vendor hashtree descriptor.")
    return digest


def inject_vendor(
    *,
    manifest_path: Path,
    source: Path | None,
    mesa_directory: Path,
    tools_root: Path,
    output_directory: Path,
    work_directory: Path | None = None,
) -> dict[str, Any]:
    """Rebuild `vendor_a` with the Mesa libraries and write the partition and its record."""
    repository = _repository_root()
    document = _load_json(manifest_path, description="Android image manifest")
    if not isinstance(document, dict):
        raise InjectError(f"{manifest_path}: the manifest is not an object.")
    failures = validate_manifest(document, include_files=True, source=source)
    if failures:
        raise InjectError(failures[0])
    source_root = _resolve_archive_root(document, source=source)
    archives = (document.get("source") or {}).get("archives")
    if not isinstance(archives, list):
        raise InjectError("the manifest source.archives is invalid.")
    archive_paths = _archive_paths(source_root, archives)
    build_id = (document.get("source") or {}).get("buildId")
    if not isinstance(build_id, str):
        raise InjectError("the manifest source.buildId is missing.")

    tools = verify_tools(tools_root, load_component())
    libraries, mesa_record = load_mesa_output(mesa_directory, load_component(MESA_COMPONENT))
    avbtool = verify_avbtool(repository, load_component(AVBTOOL_COMPONENT))
    output = _ensure_output(output_directory, repository)

    partition_size = next(
        (
            item["size"]
            for item in document.get("logicalPartitions", [])
            if item.get("name") == PARTITION
        ),
        None,
    )
    if not isinstance(partition_size, int):
        raise InjectError(f"{PARTITION}: the manifest has no size for it.")
    image_uuid = str(
        uuid.uuid5(UUID_NAMESPACE, f"{build_id}:{PARTITION}:mesa:{mesa_record['commit']}")
    )

    with _work_area(work_directory) as scratch_name:
        scratch = Path(scratch_name)
        stock_image = scratch / f"{PARTITION}.part"
        stock_sha = read_super_partition(
            document, source_root, archive_paths, PARTITION, stock_image
        )
        system_image = scratch / f"{SYSTEM_PARTITION}.part"
        system_sha = read_super_partition(
            document, source_root, archive_paths, SYSTEM_PARTITION, system_image
        )
        plat_path = scratch / "plat_file_contexts"
        extract_file(tools, system_image, PLAT_CONTEXTS, plat_path)
        system_image.unlink()
        plat_text = read_contexts_text(plat_path)

        result = rebuild_partition(
            tools,
            stock_image,
            scratch,
            libraries,
            plat_name=f"{SYSTEM_PARTITION}:{PLAT_CONTEXTS}",
            plat_text=plat_text,
            image_uuid=image_uuid,
        )

        stock_info = run_avbtool(avbtool, ["info_image", "--image", str(stock_image)])
        stock_hashtree = parse_hashtrees(stock_info).get(VERITY_PARTITION)
        if stock_hashtree is None or not isinstance(stock_hashtree.get("salt"), str):
            raise InjectError("the stock vendor partition has no hashtree descriptor with a salt.")
        salt = stock_hashtree["salt"]
        stock_partition_digest = stock_hashtree["rootDigest"]

        output_image = output / OUTPUT_IMAGE
        new_digest = seal_partition(
            avbtool,
            result.image,
            output_image,
            partition_size=partition_size,
            salt=salt,
            scratch=scratch,
        )

        vbmeta_path = scratch / "vbmeta.part"
        vbmeta_ids = (document.get("roles") or {}).get("vbmeta")
        if not isinstance(vbmeta_ids, list) or not vbmeta_ids:
            raise InjectError("the manifest roles.vbmeta is missing.")
        vbmeta_path.write_bytes(read_member(document, source_root, archive_paths, vbmeta_ids[0]))
        vbmeta_info = run_avbtool(avbtool, ["info_image", "--image", str(vbmeta_path)])
        vbmeta_digest = parse_hashtrees(vbmeta_info).get(VERITY_PARTITION, {}).get("rootDigest")
        if vbmeta_digest != stock_partition_digest:
            raise InjectError(
                "the stock vendor footer and the stock vbmeta disagree on the root digest."
            )

        record = {
            "schemaVersion": 1,
            "task": "#099",
            "buildId": build_id,
            "partition": {"name": PARTITION, "size": partition_size, "filesystem": "erofs"},
            "stock": {
                "sha256": stock_sha,
                "entries": len(result.stock_entries),
                "erofsBlocks": result.stock_blocks,
                "verityRootDigest": stock_partition_digest,
                "vbmetaVendorRootDigest": vbmeta_digest,
                "systemPartitionSha256": system_sha,
            },
            "mesa": {
                **mesa_record,
                "libraries": [
                    {
                        "name": library.name,
                        "source": f"{MESA_SOURCE_DIRECTORY}/{library.name}",
                        "target": library.target,
                        "sha256": library.sha256,
                        "size": library.size,
                        "label": result.mesa_entries[library.target].label,
                    }
                    for library in libraries
                ],
            },
            "placement": {
                "sourceDirectory": MESA_SOURCE_DIRECTORY,
                "targetDirectory": f"/{MESA_TARGET_DIRECTORY}",
                "decision": "IR-622",
            },
            "selinux": {
                "sources": [
                    {
                        "name": f"{SYSTEM_PARTITION}:{PLAT_CONTEXTS}",
                        "sha256": sha256_file(plat_path),
                    },
                    {
                        "name": f"{PARTITION}:{VENDOR_CONTEXTS}",
                        "sha256": hashlib.sha256(
                            result.vendor_contexts.encode("utf-8")
                        ).hexdigest(),
                    },
                ],
                **summarize(result.rules),
                "stockEntriesReproduced": result.reproduced,
                "precedence": "longest literal stem, a tie goes to the later rule (IR-623)",
            },
            "erofs": {
                "tools": f"erofs-utils {tools.version}",
                "compression": MKFS_COMPRESSION,
                "blockSize": BLOCK_SIZE,
                "timestamp": BUILD_TIMESTAMP,
                "uuid": image_uuid,
                "exportedEntries": len(result.injected_entries),
                "fsBlocks": result.fs_blocks,
            },
            "verity": {
                "tool": "vendored avbtool (aosp-avbtool, lock)",
                "algorithm": "NONE",
                "hashAlgorithm": VERITY_ALGORITHM,
                "salt": salt,
                "fec": False,
                "newRootDigest": new_digest,
                "verifiedByAvbtool": True,
            },
            "vbmeta": {
                "updated": False,
                "vendorRootDigestInVbmeta": vbmeta_digest,
                "matchesOutput": vbmeta_digest == new_digest,
                "decision": "IR-625",
            },
            "output": {
                "file": OUTPUT_IMAGE,
                "sha256": sha256_file(output_image),
                "size": output_image.stat().st_size,
            },
            "status": "vendor partition built offline; not booted; top-level vbmeta not re-signed",
        }
        (output / OUTPUT_RECORD).write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return record


def build_parser() -> argparse.ArgumentParser:
    """Build the inject-vendor command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image inject-vendor",
        description="Rebuild vendor_a with the verified guest Mesa libraries (#099, offline).",
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="source archive or directory")
    parser.add_argument(
        "--mesa", required=True, type=Path, help="scripts/guest/build-mesa-android.sh output"
    )
    parser.add_argument(
        "--erofs-tools", required=True, type=Path, help="root of a fetched erofs-utils"
    )
    parser.add_argument(
        "--out", required=True, type=Path, help="new directory outside the repository"
    )
    parser.add_argument("--work", type=Path, help="keep the intermediates in this new directory")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the injection and print a summary."""
    arguments = build_parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        record = inject_vendor(
            manifest_path=arguments.manifest,
            source=arguments.source,
            mesa_directory=arguments.mesa,
            tools_root=arguments.erofs_tools,
            output_directory=arguments.out,
            work_directory=arguments.work,
        )
    except (ValueError, OSError) as error:
        # Every typed failure of this package (InjectError, ErofsError, ContextsError,
        # ManifestError, ExtractError, LpMetadataError) is a ValueError; the rest is I/O.
        print(f"inject-vendor: {error}", file=sys.stderr)
        return 1
    print(f"inject-vendor: wrote {record['output']['file']} ({record['output']['size']} bytes)")
    print(f"inject-vendor: vbmeta matches the output: {record['vbmeta']['matchesOutput']}")
    return 0
