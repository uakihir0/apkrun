"""Compose the pinned stock Android image with the APKRun development product (#36)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import replace
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO

from cryptography import x509
from cryptography.hazmat.primitives import hashes

from apkrun_image import lp
from apkrun_image.compose import (
    BUILD_TIMESTAMP,
    ComposeError,
    Placement,
    _build_ero,
    _entry_differences,
    load_placements,
    rebuild_system_ext,
)
from apkrun_image.compose_avb import (
    ComposeAvbError,
    minimum_partition_size,
    minimum_partition_size_for_descriptor,
    refresh_system_ext_vbmeta,
    seal_partition,
    seal_system_ext,
    stock_system_ext_descriptor,
)
from apkrun_image.compose_policy import (
    PolicyComposeError,
    calculate_policy_hashes,
    compile_precompiled_policy,
    derive_ordered_cil_paths,
    install_precompiled_policy,
    merge_policy_file,
    merge_policy_text,
    verify_pinned_secilc,
)
from apkrun_image.erofs import (
    REGULAR_FILE,
    Entry,
    ErofsError,
    ErofsTools,
    export_tree,
    load_component,
    read_tree,
    sha256_file,
    tree_members,
    verify_tools,
)
from apkrun_image.extract import (
    ExtractError,
    _open_artifact,
)
from apkrun_image.lp_grow import LpGrowError, grow_partition, partition_growth_limit
from apkrun_image.lp_write import LpWriteError, replace_partition
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _repository_root,
    _resolve_archive_root,
    validate_manifest,
)
from apkrun_image.selinux_labels import (
    ContextsError,
    label_for_partition,
    load_contexts,
    read_contexts_text,
)
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    MESA_COMPONENT,
    load_mesa_output,
    verify_avbtool,
)
from apkrun_image.vendor_inject import rebuild_partition as rebuild_vendor
from apkrun_image.vendor_reseal import (
    _info,
    _original_size,
    _partition_tree,
    parse_hashtrees,
    refresh_vbmeta_partition,
)

COPY_CHUNK = 8 * 1024 * 1024
SYSTEM_EXT = "system_ext_a"
SYSTEM_PARTITION = "system_a"
ODM_PARTITION = "odm_a"
VENDOR_PARTITION = "vendor_a"
MESA_PRODUCT_RELATIVE_PATH = "mesa/prebuilt"
OUTPUT_FILES = ("super.img", "vbmeta_system_a.img", "vbmeta_a.img", "composition.json")
PRODUCT_POLICY_INPUTS = (
    "sepolicy/apkrun_guest.cil",
    "sepolicy/apkrun_vsockd.cil",
    "sepolicy/apkrun_gpu.cil",
    "sepolicy/userdebug_permissive.cil",
    "sepolicy/apkrun_file_contexts",
    "sepolicy/apkrun_seapp_contexts",
)
PRODUCT_BUNDLE_INPUTS = ("prebuilt/ApkRunGuest.json", "prebuilt/ApkRunStore.json")
TEST_OVERLAY_RELATIVE_ROOT = "Tests/Fixtures/AndroidImageProduct"
TEST_OVERLAY_INPUT_PREFIX = TEST_OVERLAY_RELATIVE_ROOT + "/"
GUEST_AGENT_APK = "prebuilt/ApkRunGuest.apk"
GUEST_AGENT_IMAGE_PATH = "/system_ext/priv-app/ApkRunGuest/ApkRunGuest.apk"
GUEST_AGENT_PACKAGE = "io.apkrun.guest"
STORE_AGENT_APK = "prebuilt/ApkRunStore.apk"
STORE_AGENT_IMAGE_PATH = "/system_ext/priv-app/ApkRunStore/ApkRunStore.apk"
STORE_AGENT_PACKAGE = "io.apkrun.store"
COMPOSITION_AGENTS = (
    (
        PRODUCT_BUNDLE_INPUTS[0],
        GUEST_AGENT_PACKAGE,
        GUEST_AGENT_APK,
        GUEST_AGENT_IMAGE_PATH,
        "Guest Agent",
        True,
    ),
    (
        PRODUCT_BUNDLE_INPUTS[1],
        STORE_AGENT_PACKAGE,
        STORE_AGENT_APK,
        STORE_AGENT_IMAGE_PATH,
        "Store Agent",
        False,
    ),
)
ANDROID_BUILD_TOOLS_VERSION = "37.0.0"
ODM_POLICY_FILES = (
    "/etc/selinux/precompiled_sepolicy",
    "/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256",
    "/etc/selinux/precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256",
)


class ImageCompositionError(ValueError):
    """An invalid source build or an unsuccessful development-image composition."""


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _copy_stream(stream: BinaryIO, destination: Path) -> None:
    """Copy a verified artifact stream to a fresh file and sync it before use."""
    with destination.open("xb") as output:
        while block := stream.read(COPY_CHUNK):
            output.write(block)
        output.flush()
        os.fsync(output.fileno())


def _artifact_for_partition(document: Mapping[str, Any], partition: str) -> Mapping[str, Any]:
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list):
        raise ImageCompositionError("manifest artifacts must be an array.")
    matches = [
        item for item in artifacts if isinstance(item, dict) and item.get("partition") == partition
    ]
    if len(matches) != 1:
        raise ImageCompositionError(
            f"manifest must contain exactly one artifact for partition {partition!r}."
        )
    return matches[0]


def _artifact_id(document: Mapping[str, Any], role: str) -> Mapping[str, Any]:
    roles = document.get("roles")
    artifacts = document.get("artifacts")
    artifact_id = roles.get(role) if isinstance(roles, dict) else None
    if not isinstance(artifact_id, str) or not isinstance(artifacts, list):
        raise ImageCompositionError(f"manifest role {role!r} is missing.")
    matches = [
        item for item in artifacts if isinstance(item, dict) and item.get("id") == artifact_id
    ]
    if len(matches) != 1:
        raise ImageCompositionError(f"manifest role {role!r} does not resolve to one artifact.")
    return matches[0]


def _product_input_files(
    product_root: Path,
    placements: Sequence[Placement],
    *,
    additional: Sequence[Path] = (),
) -> list[dict[str, str]]:
    """Return stable repository-relative hashes for every consumed product input."""
    paths = {product_root / "compose.json"}
    paths.update(placement.source for placement in placements if placement.source is not None)
    paths.update(additional)
    repository = _repository_root().resolve()
    product = product_root.resolve(strict=True)
    try:
        product_prefix = product.relative_to(repository).as_posix() + "/"
    except ValueError:
        raise ImageCompositionError(
            f"{product_root}: product inputs must be inside the APKRun repository."
        ) from None
    result: list[dict[str, str]] = []
    normalized: list[tuple[str, Path]] = []
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ImageCompositionError(f"{path}: a composition input is missing or symlinked.")
        try:
            resolved = path.resolve(strict=True)
            relative = resolved.relative_to(repository).as_posix()
        except (OSError, ValueError):
            raise ImageCompositionError(
                f"{path}: composition inputs must resolve inside the APKRun repository."
            ) from None
        if not relative.startswith(product_prefix):
            raise ImageCompositionError(
                f"{path}: composition inputs must be under {product_prefix}."
            )
        normalized.append((relative, resolved))
    for relative, path in sorted(normalized, key=lambda item: item[0].encode("utf-8")):
        result.append(
            {
                "path": relative,
                "sha256": sha256_file(path),
            }
        )
    return result


def _path_has_symlink_component(path: Path, *, root: Path) -> bool:
    """Return whether a path or any component beneath a trusted root is a symlink."""
    try:
        relative = path.relative_to(root)
    except ValueError:
        return True
    current = root
    if current.is_symlink():
        return True
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            return True
    return False


def _test_overlay_inputs(
    repository: Path,
) -> list[dict[str, str]]:
    """Hash only the fixed test overlay plan and the sources it explicitly references."""
    fixture_root = repository / TEST_OVERLAY_RELATIVE_ROOT
    plan_path = fixture_root / "compose.json"
    if _path_has_symlink_component(fixture_root, root=repository) or not fixture_root.is_dir():
        raise ImageCompositionError(
            f"{fixture_root}: the fixed test overlay root must be a real directory."
        )
    if _path_has_symlink_component(plan_path, root=repository) or not plan_path.is_file():
        raise ImageCompositionError(
            f"{plan_path}: the fixed test overlay compose.json must be a real file."
        )
    try:
        placements = load_placements(plan_path, fixture_root)
    except ComposeError as error:
        raise ImageCompositionError(f"invalid fixed test overlay: {error}") from None

    paths = {plan_path}
    paths.update(placement.source for placement in placements if placement.source is not None)
    inputs: list[dict[str, str]] = []
    for path in paths:
        if _path_has_symlink_component(path, root=fixture_root) or not path.is_file():
            raise ImageCompositionError(
                f"{path}: test overlay inputs must be real files under {fixture_root}."
            )
        try:
            resolved = path.resolve(strict=True)
            relative = resolved.relative_to(repository).as_posix()
        except (OSError, ValueError):
            raise ImageCompositionError(
                f"{path}: test overlay input must resolve inside the APKRun repository."
            ) from None
        if not relative.startswith(TEST_OVERLAY_INPUT_PREFIX):
            raise ImageCompositionError(
                f"{path}: test overlay inputs must be under {TEST_OVERLAY_INPUT_PREFIX}."
            )
        inputs.append({"path": relative, "sha256": sha256_file(resolved)})
    return sorted(inputs, key=lambda item: item["path"].encode("utf-8"))


def _snapshot_product_inputs(
    product_root: Path,
    product_inputs: Sequence[Mapping[str, str]],
    snapshot_root: Path,
    *,
    test_overlay_inputs: Sequence[Mapping[str, str]] = (),
    repository: Path | None = None,
) -> None:
    """Copy declared inputs into a private snapshot and verify their recorded hashes."""
    try:
        snapshot_root.mkdir()
    except OSError as error:
        raise ImageCompositionError(
            f"{snapshot_root}: cannot create product input snapshot: {error}"
        ) from None

    repository = (repository or _repository_root()).resolve(strict=True)
    product = product_root.resolve(strict=True)
    overlay_root = repository / TEST_OVERLAY_RELATIVE_ROOT
    input_roots = (
        ("Guest/product/", product, snapshot_root),
        (TEST_OVERLAY_INPUT_PREFIX, overlay_root, snapshot_root / TEST_OVERLAY_RELATIVE_ROOT),
    )
    for item, overlay in (
        *((item, False) for item in product_inputs),
        *((item, True) for item in test_overlay_inputs),
    ):
        relative = item.get("path", "")
        expected = item.get("sha256", "")
        prefix, source_root, destination_root = input_roots[1] if overlay else input_roots[0]
        suffix = relative[len(prefix) :] if isinstance(relative, str) else ""
        suffix_path = PurePosixPath(suffix)
        if (
            not isinstance(relative, str)
            or not relative.startswith(prefix)
            or not suffix
            or suffix_path.is_absolute()
            or suffix_path.as_posix() != suffix
            or "\\" in suffix
            or "\0" in suffix
            or any(part in {"", ".", ".."} for part in suffix_path.parts)
            or not isinstance(expected, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected)
        ):
            what = "test overlay input" if overlay else "product input"
            raise ImageCompositionError(f"{what} record is invalid.")
        source = source_root.joinpath(*suffix_path.parts)
        destination = destination_root.joinpath(*suffix_path.parts)
        if _path_has_symlink_component(source, root=source_root) or not source.is_file():
            raise ImageCompositionError(f"{source}: composition input changed or became a symlink.")
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        try:
            with source.open("rb") as input_stream, destination.open("xb") as output_stream:
                for chunk in iter(lambda: input_stream.read(1024 * 1024), b""):
                    digest.update(chunk)
                    output_stream.write(chunk)
        except OSError as error:
            raise ImageCompositionError(
                f"{source}: cannot snapshot composition input: {error}"
            ) from None
        if digest.hexdigest() != expected:
            raise ImageCompositionError(
                f"{source}: changed while composition inputs were being snapshotted."
            )


def _verify_product_agents(product_root: Path, placements: Sequence[Placement]) -> None:
    """Verify persistent agent APKs present in the product against metadata and platform signing."""
    agents: list[tuple[Path, Path, Mapping[str, Any], str]] = []
    for (
        metadata_relative,
        package_name,
        apk_relative,
        image_path,
        agent_name,
        required,
    ) in COMPOSITION_AGENTS:
        metadata_path = product_root / metadata_relative
        apk_path = product_root / apk_relative
        apk_source = apk_path.resolve()
        present = (
            metadata_path.exists()
            or metadata_path.is_symlink()
            or apk_path.exists()
            or apk_path.is_symlink()
            or any(
                placement.image_path == image_path or placement.source == apk_source
                for placement in placements
            )
        )
        if not required and not present:
            continue
        for path, description in (
            (metadata_path, f"{agent_name} metadata"),
            (apk_path, f"{agent_name} APK"),
        ):
            current = product_root
            for component in path.relative_to(product_root).parts:
                current /= component
                if current.is_symlink():
                    raise ImageCompositionError(f"{current}: {description} must not use symlinks.")
            if not path.is_file():
                raise ImageCompositionError(f"{path}: {description} is missing.")

        apk_placements = [placement for placement in placements if placement.source == apk_source]
        if len(apk_placements) != 1 or apk_placements[0].image_path != image_path:
            raise ImageCompositionError(
                f"{apk_path}: compose.json must place the persistent {agent_name} at {image_path}."
            )

        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ImageCompositionError(
                f"{metadata_path}: cannot read {agent_name} metadata: {error}"
            ) from None
        if (
            not isinstance(metadata, Mapping)
            or set(metadata) != {"packageName", "versionCode", "versionName"}
            or metadata.get("packageName") != package_name
            or isinstance(metadata.get("versionCode"), bool)
            or not isinstance(metadata.get("versionCode"), int)
            or metadata["versionCode"] < 1
            or not isinstance(metadata.get("versionName"), str)
            or not metadata["versionName"]
        ):
            raise ImageCompositionError(f"{metadata_path}: {agent_name} metadata is invalid.")
        agents.append((metadata_path, apk_path, metadata, agent_name))

    repository = _repository_root()
    android_home = Path(
        os.environ.get("ANDROID_HOME")
        or os.environ.get("ANDROID_SDK_ROOT")
        or repository / "build/android-sdk"
    ).expanduser()
    build_tools = android_home / "build-tools" / ANDROID_BUILD_TOOLS_VERSION
    aapt2 = build_tools / "aapt2"
    apksigner = build_tools / "apksigner"
    for tool in (aapt2, apksigner):
        if tool.is_symlink() or not tool.is_file() or not os.access(tool, os.X_OK):
            raise ImageCompositionError(
                f"{tool}: pinned Android build tool is missing or unsafe "
                f"(environment-setup.md §2.5)."
            )

    certificate_path = repository / "Tests/Fixtures/signing/aosp-test-platform.x509.pem"
    try:
        if certificate_path.is_symlink() or not certificate_path.is_file():
            raise OSError("the pinned AOSP test platform certificate is missing or unsafe")
        certificate = x509.load_pem_x509_certificate(certificate_path.read_bytes())
    except (OSError, ValueError) as error:
        raise ImageCompositionError(f"{certificate_path}: {error}") from None
    expected_signer = certificate.fingerprint(hashes.SHA256()).hex()

    for metadata_path, apk_path, metadata, agent_name in agents:
        try:
            badging = subprocess.run(
                [str(aapt2), "dump", "badging", str(apk_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            signature = subprocess.run(
                [str(apksigner), "verify", "--print-certs", str(apk_path)],
                check=False,
                capture_output=True,
                text=True,
            )
        except OSError as error:
            raise ImageCompositionError(f"could not verify {agent_name} APK: {error}") from None
        if badging.returncode:
            raise ImageCompositionError(
                f"{apk_path}: aapt2 could not read the {agent_name} APK "
                f"({badging.stderr.strip() or badging.returncode})."
            )
        package_line = next(
            (line for line in badging.stdout.splitlines() if line.startswith("package: ")),
            "",
        )
        package_match = re.search(
            r"(?:^| )name='([^']*)'.* versionCode='([0-9]+)' versionName='([^']*)'(?: |$)",
            package_line,
        )
        if (
            package_match is None
            or package_match.group(1) != metadata["packageName"]
            or int(package_match.group(2)) != metadata["versionCode"]
            or package_match.group(3) != metadata["versionName"]
        ):
            actual = (
                f"{package_match.group(1)} versionCode={package_match.group(2)} "
                f"versionName={package_match.group(3)}"
                if package_match is not None
                else package_line or "no package entry"
            )
            raise ImageCompositionError(
                f"{apk_path}: Android manifest package/version {actual} do not match "
                f"{metadata_path} ({metadata['packageName']} versionCode={metadata['versionCode']} "
                f"versionName={metadata['versionName']})."
            )
        if signature.returncode:
            raise ImageCompositionError(
                f"{apk_path}: apksigner rejected the {agent_name} APK "
                f"({signature.stderr.strip() or signature.returncode})."
            )
        signers = re.findall(
            r"certificate SHA-256 digest:\s*([0-9a-fA-F]{64})",
            signature.stdout,
            flags=re.IGNORECASE,
        )
        if len(signers) != 1 or signers[0].lower() != expected_signer:
            raise ImageCompositionError(
                f"{apk_path}: {agent_name} must have exactly one signature from the pinned "
                "AOSP test platform certificate."
            )


def _policy_replacements(
    tools: ErofsTools,
    product_root: Path,
    partition_trees: Mapping[str, Path],
    work: Path,
    repository: Path,
    secilc_tools_root: Path,
    odm_output_tree: Path,
) -> tuple[dict[str, Path], Path, dict[str, Any]]:
    """Merge product SELinux fragments, compile init's split policy, and update ODM inputs."""
    for name in ("system", "system_ext", "product", "vendor", "odm"):
        if name not in partition_trees or partition_trees[name].is_symlink():
            raise ImageCompositionError(f"{name}: exported policy partition is missing or unsafe.")

    fragments: list[Path] = []
    for relative in PRODUCT_POLICY_INPUTS:
        path = product_root / relative
        if path.is_symlink() or not path.is_file():
            raise ImageCompositionError(f"{path}: required product policy input is missing.")
        fragments.append(path)

    policy_trees = {
        name: _partition_mount_root(partition_trees[name], name)
        for name in ("system", "system_ext", "product", "vendor", "odm")
    }
    system_ext_selinux = policy_trees["system_ext"] / "etc/selinux"
    odm_tree = policy_trees["odm"]
    if odm_output_tree.is_symlink() or not odm_output_tree.is_dir():
        raise ImageCompositionError("the writable ODM policy tree is missing or unsafe.")
    merged_directory = work / "merged-system-ext-policy"
    merged_directory.mkdir()
    merged_cil = merged_directory / "system_ext_sepolicy.cil"
    try:
        cil = (system_ext_selinux / "system_ext_sepolicy.cil").read_bytes()
        for path in fragments[:4]:
            cil = merge_policy_text(cil, path.read_bytes(), kind="cil")
        merged_cil.write_bytes(cil)
        merged_contexts = merge_policy_file(
            system_ext_selinux / "system_ext_file_contexts",
            fragments[4],
            merged_directory / "system_ext_file_contexts",
            kind="file_contexts",
        )
        merged_seapp = merge_policy_file(
            system_ext_selinux / "system_ext_seapp_contexts",
            fragments[5],
            merged_directory / "system_ext_seapp_contexts",
            kind="seapp_contexts",
        )
        policy_inputs = derive_ordered_cil_paths(policy_trees)
        stock_system_ext_cil = (system_ext_selinux / "system_ext_sepolicy.cil").resolve()
        cil_paths = tuple(
            merged_cil if path.resolve() == stock_system_ext_cil else path
            for path in policy_inputs.cil_paths
        )
        hashes = calculate_policy_hashes(
            {
                **policy_inputs.hashes_as_mapping(),
                "system_ext": (
                    merged_cil,
                    (system_ext_selinux / f"mapping/{policy_inputs.mapping_version}.cil"),
                ),
            },
            unchanged_odm_root=odm_tree,
        )
        compiled_policy = work / "compiled-precompiled-sepolicy"
        lock = repository / "ThirdParty/ThirdParty.lock.json"
        compiler = _resolve_secilc_directory(secilc_tools_root, lock)
        compile_precompiled_policy(compiler, lock, cil_paths, compiled_policy)
        policy_outputs = install_precompiled_policy(compiled_policy, odm_output_tree, hashes)
    except (OSError, PolicyComposeError) as error:
        raise ImageCompositionError(
            f"cannot compose Android split SELinux policy: {error}"
        ) from None

    replacements = {
        "/system_ext/etc/selinux/system_ext_sepolicy.cil": merged_cil,
        "/system_ext/etc/selinux/system_ext_file_contexts": merged_contexts,
        "/system_ext/etc/selinux/system_ext_seapp_contexts": merged_seapp,
    }
    return (
        replacements,
        partition_trees["odm"],
        {
            "cilInputs": len(cil_paths),
            "mappingVersion": policy_inputs.mapping_version,
            "genfsVersion": policy_inputs.genfs_version,
            "compiledPolicyBytes": policy_outputs["policy"].stat().st_size,
            "hashes": {name: content.decode("ascii").strip() for name, content in hashes.items()},
        },
    )


def _resolve_secilc_directory(tool_root: Path, lock_path: Path) -> Path:
    """Find one verified build cache under the configured SELinux tool root."""
    if tool_root.is_symlink():
        raise ImageCompositionError(f"{tool_root}: SELinux tools root must not be a symlink.")
    candidates = (
        [tool_root]
        if (tool_root / "build-manifest.json").is_file()
        else sorted(
            (
                path
                for path in tool_root.iterdir()
                if path.is_dir()
                and not path.is_symlink()
                and (path / "build-manifest.json").is_file()
            ),
            key=lambda path: path.name,
        )
        if tool_root.is_dir()
        else []
    )
    verified: list[tuple[Path, str]] = []
    errors: list[str] = []
    for candidate in candidates:
        try:
            binary = verify_pinned_secilc(candidate, lock_path)
            verified.append((candidate, sha256_file(binary)))
        except (PolicyComposeError, OSError) as error:
            errors.append(str(error))
    if not verified:
        detail = errors[0] if errors else "no build-manifest.json was found."
        raise ImageCompositionError(
            f"{tool_root}: no valid pinned secilc build is available ({detail})"
        )
    hashes = {digest for _path, digest in verified}
    if len(hashes) != 1:
        raise ImageCompositionError(
            f"{tool_root}: valid secilc caches disagree; select one with --selinux-tools."
        )
    return verified[0][0]


def _rebuild_odm_policy(
    tools: ErofsTools,
    stock_image: Path,
    stock_tree: Path,
    modified_tree: Path,
    scratch: Path,
    *,
    image_uuid: str,
) -> tuple[Path, dict[str, Any]]:
    """Rebuild ODM with only the generated precompiled policy and hashes changed."""
    stock_entries = read_tree(tools, stock_image, stock_tree)
    stock_members = tree_members(stock_entries, stock_tree, BUILD_TIMESTAMP)
    members_by_path = {member.path: member for member in stock_members}
    replaced: dict[str, Entry] = {}
    replacements: dict[str, Path] = {}
    for path in ODM_POLICY_FILES:
        entry = stock_entries.get(path)
        if entry is None or entry.kind != REGULAR_FILE:
            raise ImageCompositionError(f"{path}: ODM policy target is absent or not a file.")
        source = modified_tree / path.lstrip("/")
        member = members_by_path.get(path)
        if source.is_symlink() or not source.is_file() or member is None:
            raise ImageCompositionError(f"{source}: generated ODM policy output is missing.")
        try:
            updated = replace(entry, size=source.stat().st_size, sha256=sha256_file(source))
        except OSError as error:
            raise ImageCompositionError(
                f"{source}: cannot read generated policy output: {error}"
            ) from None
        replaced[path] = updated
        replacements[path] = source

    image_uuid = str(uuid.UUID(image_uuid))
    roundtrip = _build_ero(tools, stock_members, scratch, "odm-roundtrip", image_uuid)
    roundtrip_tree = scratch / "odm-roundtrip-tree"
    export_tree(tools, roundtrip, roundtrip_tree)
    roundtrip_entries = read_tree(tools, roundtrip, roundtrip_tree)
    roundtrip_differences = _entry_differences(stock_entries, roundtrip_entries)
    if roundtrip_differences:
        raise ImageCompositionError(
            f"ODM round trip changed stock entry {roundtrip_differences[0]}."
        )

    modified_members = [
        replace(members_by_path[member.path], source=replacements[member.path])
        if member.path in replacements
        else member
        for member in stock_members
    ]
    image = _build_ero(tools, modified_members, scratch, "odm-composed", image_uuid)
    composed_tree = scratch / "odm-composed-tree"
    export_tree(tools, image, composed_tree)
    composed_entries = read_tree(tools, image, composed_tree)
    differences = _entry_differences(stock_entries, composed_entries, replaced=replaced)
    if differences:
        raise ImageCompositionError(f"ODM rebuild changed an unexpected entry: {differences[0]}.")
    return image, {
        "imageUUID": image_uuid,
        "filesystemBytes": image.stat().st_size,
        "stockEntriesReproduced": len(stock_entries) - len(replaced),
        "replacedEntries": len(replaced),
    }


def deterministic_system_ext_uuid(
    stock_sha256: str, product_inputs: Sequence[Mapping[str, str]]
) -> str:
    """Derive the rebuilt filesystem UUID solely from declared content inputs."""
    return deterministic_filesystem_uuid("system_ext", stock_sha256, product_inputs)


def deterministic_filesystem_uuid(
    partition_name: str,
    stock_sha256: str,
    product_inputs: Sequence[Mapping[str, str]],
) -> str:
    """Derive a partition-specific rebuilt filesystem UUID from declared content inputs."""
    encoded = json.dumps(
        {"partition": partition_name, "stock": stock_sha256, "product": list(product_inputs)},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return str(uuid.UUID(bytes=hashlib.sha256(encoded).digest()[:16], version=5))


def _copy_prefix(source: Path, destination: Path, size: int) -> None:
    if size <= 0 or size > source.stat().st_size:
        raise ImageCompositionError(f"{source}: AVB original image size is out of bounds.")
    with source.open("rb") as reader, destination.open("xb") as writer:
        remaining = size
        while remaining:
            block = reader.read(min(COPY_CHUNK, remaining))
            if not block:
                raise ImageCompositionError(f"{source}: image is shorter than its AVB data size.")
            writer.write(block)
            remaining -= len(block)


def _verify_product_labels(
    placements: Sequence[Placement],
    product_root: Path,
    system_tree: Path,
    system_ext_tree: Path,
) -> dict[str, int]:
    """Resolve placement labels with the stock platform contexts and product additions."""
    platform_root = _partition_mount_root(system_tree, "system")
    system_ext_root = _partition_mount_root(system_ext_tree, "system_ext")
    platform_contexts = platform_root / "etc/selinux/plat_file_contexts"
    stock_contexts = system_ext_root / "etc/selinux/system_ext_file_contexts"
    for path in (platform_contexts, stock_contexts):
        if path.is_symlink() or not path.is_file():
            raise ImageCompositionError(f"{path}: required stock SELinux contexts are missing.")
    product_contexts = product_root / "sepolicy/apkrun_file_contexts"
    context_parts = [
        ("system_a:/etc/selinux/plat_file_contexts", read_contexts_text(platform_contexts)),
        (
            "system_ext_a:/etc/selinux/system_ext_file_contexts",
            read_contexts_text(stock_contexts),
        ),
    ]
    if product_contexts.is_file():
        if product_contexts.is_symlink():
            raise ImageCompositionError(
                f"{product_contexts}: product contexts must not be a symlink."
            )
        context_parts.append(
            ("Guest/product/sepolicy/apkrun_file_contexts", read_contexts_text(product_contexts))
        )
    try:
        rules = load_contexts(context_parts)
        checked = {}
        for placement in placements:
            actual = label_for_partition(
                rules,
                "/" + placement.erofs_path,
                placement.kind,
                mount="/system_ext",
            )
            if actual != placement.label:
                raise ImageCompositionError(
                    f"{placement.image_path}: plan label {placement.label!r} does not match "
                    f"the image contexts ({actual!r})."
                )
            checked[placement.image_path] = len(rules)
        return {"rules": len(rules), "placements": len(checked)}
    except ContextsError as error:
        raise ImageCompositionError(f"cannot resolve placement SELinux labels: {error}") from None


def _partition_mount_root(tree: Path, partition: str) -> Path:
    """Resolve an exported EROFS root when AOSP stored files under its mount-name directory."""
    candidate = tree / partition
    if candidate.is_symlink():
        raise ImageCompositionError(f"{candidate}: exported mount root must not be a symlink.")
    return candidate if candidate.is_dir() else tree


def _verify_pinned_fec_tool(repository: Path, fec_tool: Path) -> Path:
    """Verify the selected FEC binary against the checked-in source and build pins."""
    if fec_tool.is_symlink() or not fec_tool.is_file() or not os.access(fec_tool, os.X_OK):
        raise ImageCompositionError(f"{fec_tool}: the pinned FEC tool is missing or unsafe.")
    verifier = repository / "scripts/tools/build_fec.py"
    if verifier.is_symlink() or not verifier.is_file():
        raise ImageCompositionError(f"{verifier}: the pinned FEC verifier is missing or unsafe.")
    try:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(verifier),
                "--root",
                str(repository),
                "--verify",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ImageCompositionError(f"could not verify the pinned FEC tool: {error}") from None
    if result.returncode:
        detail = result.stderr.strip().splitlines()[-1:] or result.stdout.strip().splitlines()[-1:]
        raise ImageCompositionError(
            "the existing FEC tool does not match the pinned build "
            f"({detail[0] if detail else f'exit {result.returncode}'}). "
            "Run scripts/build-fec-tool.sh to build or verify the locked tool."
        )
    reported = result.stdout.strip()
    try:
        verified = Path(reported).resolve(strict=True)
        selected = fec_tool.resolve(strict=True)
    except (OSError, RuntimeError):
        raise ImageCompositionError(
            "the FEC verifier did not return an existing pinned binary path."
        ) from None
    if verified != selected:
        raise ImageCompositionError(
            f"{fec_tool}: composition only accepts the verified pinned FEC binary {verified}."
        )
    return verified


def _copy_logical_partition(
    super_image: Path,
    partition_name: str,
    destination: Path,
) -> int:
    """Extract a logical partition from a sparse super image in bounded memory."""
    with super_image.open("rb") as stream:
        metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if metadata is None:
            raise ImageCompositionError("super.img has no liblp metadata.")
        partition = next(
            (item for item in metadata.logical_partitions if item.name == partition_name), None
        )
        if partition is None:
            raise ImageCompositionError(f"super.img has no logical partition {partition_name}.")
        with destination.open("xb") as output:
            offset = 0
            while offset < partition.size:
                amount = min(COPY_CHUNK, partition.size - offset)
                block = lp.read_partition_range(stream, partition, offset, amount, sparse=True)
                if len(block) != amount:
                    raise ImageCompositionError(
                        f"{partition_name}: sparse super returned a truncated partition range."
                    )
                output.write(block)
                offset += amount
            output.flush()
            os.fsync(output.fileno())
        return partition.size


def _filesystem_prefix(
    avbtool: Path,
    partition_image: Path,
    partition_name: str,
    destination: Path,
) -> int:
    """Remove a verified AVB suffix when present and return the EROFS byte count."""
    information = _info(avbtool, partition_image)
    tree = parse_hashtrees(information).get(partition_name)
    if tree is not None:
        size = tree.get("imageSize")
        original_size = _original_size(information, partition_name)
        if not isinstance(size, int) or size <= 0 or size != original_size:
            raise ImageCompositionError(
                f"{partition_image}: {partition_name} AVB image size is inconsistent."
            )
    else:
        try:
            size = _original_size(information, partition_name)
        except ValueError:
            size = partition_image.stat().st_size
    _copy_prefix(partition_image, destination, size)
    return size


def _validate_inputs(
    manifest_path: Path,
    source: Path | None,
    inventory_path: Path | None,
) -> tuple[dict[str, Any], Path, list[Path], Path]:
    repository = _repository_root().resolve(strict=True)
    pinned_manifest = (repository / "Images/manifests/16373615/android-image.json").resolve(
        strict=True
    )
    if manifest_path.resolve(strict=True) != pinned_manifest:
        raise ImageCompositionError(
            "composition requires the checked-in build 16373615 Android image manifest."
        )
    document = _load_json(manifest_path, description="manifest")
    if not isinstance(document, dict):
        raise ImageCompositionError("manifest: top level must be an object.")
    source_root = _resolve_archive_root(document, source=source)
    pinned_inventory = (repository / "Images/manifests/16373615/inventory.json").resolve(
        strict=True
    )
    if inventory_path is None:
        inventory_path = pinned_inventory
    elif inventory_path.resolve(strict=True) != pinned_inventory:
        raise ImageCompositionError(
            "composition requires the checked-in build 16373615 image inventory."
        )
    failures = validate_manifest(
        document,
        include_files=True,
        source=source_root,
        inventory_path=inventory_path,
    )
    if failures:
        raise ImageCompositionError(failures[0])
    archives = document.get("source", {}).get("archives")
    if not isinstance(archives, list):
        raise ImageCompositionError("manifest source.archives must be an array.")
    return document, source_root, _archive_paths(source_root, archives), inventory_path


def _composition_provenance(
    document: Mapping[str, Any],
    manifest_path: Path,
    product_inputs: Sequence[Mapping[str, str]],
    *,
    test_overlay_inputs: Sequence[Mapping[str, str]] | None = None,
    repository: Path,
    stock_system_ext_sha256: str,
    vendor: Mapping[str, Any],
    rebuild: Mapping[str, Any],
    system_ext_descriptor: Mapping[str, Any],
    odm_descriptor: Mapping[str, Any],
    vendor_descriptor: Mapping[str, Any],
    odm: Mapping[str, Any],
    policy: Mapping[str, Any],
    growth: Mapping[str, Any],
    tool_version: str,
) -> dict[str, Any]:
    source = document.get("source")
    if not isinstance(source, dict):
        raise ImageCompositionError("manifest source block is missing.")
    try:
        revision = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD:Guest"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", str(repository), "status", "--porcelain", "--", "Guest"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        if dirty:
            revision += "-dirty"
    except (OSError, subprocess.CalledProcessError):
        raise ImageCompositionError(
            "cannot resolve the Guest tree revision for composition provenance."
        ) from None
    try:
        manifest_location = manifest_path.resolve(strict=True).relative_to(repository).as_posix()
    except (OSError, ValueError):
        raise ImageCompositionError(
            "source manifest must be inside the APKRun repository for provenance."
        ) from None
    record = {
        "schemaVersion": 1,
        "source": source,
        "sourceManifest": {
            "path": manifest_location,
            "sha256": sha256_file(manifest_path),
        },
        "productInputs": list(product_inputs),
        "apkrunRevision": revision,
        "imageToolsVersion": "0.1.0",
        "erofsUtilsVersion": tool_version,
        "stockSystemExtSHA256": stock_system_ext_sha256,
        "vendor": dict(vendor),
        "systemExt": {
            "uuid": rebuild["image_uuid"],
            "filesystemBytes": rebuild["filesystem_bytes"],
            "sourceEntriesReproduced": rebuild["stock_entries_reproduced"],
            "stockEntriesAdded": rebuild["added_entries"],
        },
        "odm": dict(odm),
        "policy": dict(policy),
        "growth": growth,
        "avb": {
            "systemExt": {
                "partition": system_ext_descriptor["partition"],
                "fecRoots": system_ext_descriptor["fecRoots"],
                "hashAlgorithm": system_ext_descriptor["hashAlgorithm"],
            },
            "odm": {
                "partition": odm_descriptor["partition"],
                "fecRoots": odm_descriptor["fecRoots"],
                "hashAlgorithm": odm_descriptor["hashAlgorithm"],
            },
            "vendor": {
                "partition": vendor_descriptor["partition"],
                "fecRoots": vendor_descriptor["fecRoots"],
                "hashAlgorithm": vendor_descriptor["hashAlgorithm"],
            },
            "signer": "aosp-avb-testkey-rsa4096",
        },
    }
    if test_overlay_inputs is not None:
        record["testOverlayInputs"] = [dict(item) for item in test_overlay_inputs]
    return record


def compose_image(
    manifest_path: Path,
    *,
    output_directory: Path,
    product_root: Path,
    source: Path | None = None,
    inventory_path: Path | None = None,
    erofs_tools_root: Path | None = None,
    selinux_tools_root: Path | None = None,
    fec_tool: Path | None = None,
    avb_signing_key: Path | None = None,
    test_overlay: bool = False,
) -> dict[str, Any]:
    """Build checked super and vbmeta overlays from one pinned stock manifest."""
    repository = _repository_root()
    product_root = product_root.expanduser()
    if product_root.is_symlink():
        raise ImageCompositionError(f"{product_root}: product root must not be a symlink.")
    product_root = product_root.resolve(strict=True)
    manifest_path = manifest_path.expanduser().resolve(strict=True)
    output_directory = output_directory.expanduser()
    if output_directory.exists() or output_directory.is_symlink():
        raise ImageCompositionError(f"{output_directory}: output must not already exist.")
    output_parent = output_directory.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    if output_parent.is_symlink():
        raise ImageCompositionError(f"{output_parent}: output parent must not be a symlink.")

    document, source_root, archive_paths, _inventory_path = _validate_inputs(
        manifest_path, source, inventory_path
    )
    source_metadata = document.get("source")
    if (
        not isinstance(source_metadata, dict)
        or source_metadata.get("buildId") != "16373615"
        or source_metadata.get("target") != "aosp_cf_arm64_only_phone-userdebug"
    ):
        raise ImageCompositionError(
            "composition requires the pinned Android 17 build 16373615 "
            "(aosp_cf_arm64_only_phone-userdebug)."
        )
    if source_root.is_dir() and output_directory.resolve().is_relative_to(source_root.resolve()):
        raise ImageCompositionError("output directory must be outside the source image directory.")
    if output_directory.resolve().is_relative_to(product_root):
        raise ImageCompositionError("output directory must be outside Guest/product.")

    source_placements = load_placements(product_root / "compose.json", product_root)
    mesa_directory = product_root / MESA_PRODUCT_RELATIVE_PATH
    if (
        _path_has_symlink_component(mesa_directory, root=product_root)
        or not mesa_directory.is_dir()
    ):
        raise ImageCompositionError(
            f"{mesa_directory}: the staged Mesa product must be a real directory."
        )
    try:
        source_mesa_libraries, _source_mesa_record = load_mesa_output(
            mesa_directory, load_component(MESA_COMPONENT)
        )
    except (ErofsError, ValueError, OSError) as error:
        raise ImageCompositionError(f"invalid staged Mesa product: {error}") from None
    test_overlay_inputs = _test_overlay_inputs(repository) if test_overlay else None
    if test_overlay:
        test_overlay_root = repository / TEST_OVERLAY_RELATIVE_ROOT
        try:
            test_overlay_placements = load_placements(
                test_overlay_root / "compose.json",
                test_overlay_root,
            )
        except ComposeError as error:
            raise ImageCompositionError(f"invalid fixed test overlay: {error}") from None
        product_destinations = {placement.image_path for placement in source_placements}
        duplicate_destinations = sorted(
            product_destinations.intersection(
                placement.image_path for placement in test_overlay_placements
            )
        )
        if duplicate_destinations:
            raise ImageCompositionError(
                f"test overlay cannot replace a product placement: {duplicate_destinations[0]}."
            )
    product_inputs = _product_input_files(
        product_root,
        source_placements,
        additional=tuple(
            [
                *(product_root / path for path in PRODUCT_POLICY_INPUTS),
                product_root / PRODUCT_BUNDLE_INPUTS[0],
                *(
                    [product_root / PRODUCT_BUNDLE_INPUTS[1]]
                    if (product_root / PRODUCT_BUNDLE_INPUTS[1]).exists()
                    or (product_root / PRODUCT_BUNDLE_INPUTS[1]).is_symlink()
                    else []
                ),
                mesa_directory / "manifest.json",
                *(library.source for library in source_mesa_libraries),
            ]
        ),
    )
    super_artifact = _artifact_id(document, "super")
    system_ext_manifest_size = next(
        (
            item.get("size")
            for item in document.get("logicalPartitions", [])
            if isinstance(item, dict) and item.get("name") == SYSTEM_EXT
        ),
        None,
    )
    odm_manifest_size = next(
        (
            item.get("size")
            for item in document.get("logicalPartitions", [])
            if isinstance(item, dict) and item.get("name") == ODM_PARTITION
        ),
        None,
    )
    vendor_manifest_size = next(
        (
            item.get("size")
            for item in document.get("logicalPartitions", [])
            if isinstance(item, dict) and item.get("name") == VENDOR_PARTITION
        ),
        None,
    )
    if not isinstance(system_ext_manifest_size, int) or system_ext_manifest_size <= 0:
        raise ImageCompositionError("manifest has no valid system_ext_a size.")
    if not isinstance(odm_manifest_size, int) or odm_manifest_size <= 0:
        raise ImageCompositionError("manifest has no valid odm_a size.")
    if not isinstance(vendor_manifest_size, int) or vendor_manifest_size <= 0:
        raise ImageCompositionError("manifest has no valid vendor_a size.")

    erofs_tools_root = erofs_tools_root or repository / "ThirdParty/out/erofs-utils"
    selinux_tools_root = selinux_tools_root or repository / "ThirdParty/out/selinux-tools"
    fec_tool = fec_tool or repository / "ThirdParty/out/fec/bin/fec"
    avb_signing_key = (
        avb_signing_key or repository / "Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem"
    )
    try:
        tools = verify_tools(erofs_tools_root)
        avbtool = verify_avbtool(repository, load_component(AVBTOOL_COMPONENT))
        fec_tool = _verify_pinned_fec_tool(repository, fec_tool)
    except (ErofsError, ValueError, OSError) as error:
        raise ImageCompositionError(str(error)) from None

    stage = Path(tempfile.mkdtemp(prefix=".apkrun-compose-", dir=output_parent))
    try:
        work = stage / "work"
        work.mkdir()
        snapshot_product = stage / "product"
        _snapshot_product_inputs(
            product_root,
            product_inputs,
            snapshot_product,
            test_overlay_inputs=test_overlay_inputs or (),
            repository=repository,
        )
        try:
            mesa_libraries, mesa_record = load_mesa_output(
                snapshot_product / MESA_PRODUCT_RELATIVE_PATH,
                load_component(MESA_COMPONENT),
            )
        except (ErofsError, ValueError, OSError) as error:
            raise ImageCompositionError(
                f"staged Mesa product changed or is invalid in the input snapshot: {error}"
            ) from None
        if test_overlay_inputs is not None:
            overlay_snapshot_root = snapshot_product / TEST_OVERLAY_RELATIVE_ROOT
            overlay_document = _load_json(
                overlay_snapshot_root / "compose.json",
                description="test overlay composition list",
            )
            base_document = _load_json(
                snapshot_product / "compose.json",
                description="product composition list",
            )
            if (
                not isinstance(base_document, Mapping)
                or not isinstance(base_document.get("entries"), list)
                or not isinstance(overlay_document, Mapping)
                or not isinstance(overlay_document.get("entries"), list)
            ):
                raise ImageCompositionError(
                    "product and test overlay composition lists are invalid."
                )
            overlay_entries: list[dict[str, Any]] = []
            for raw_entry in overlay_document["entries"]:
                if not isinstance(raw_entry, Mapping):
                    raise ImageCompositionError("test overlay placement is invalid.")
                entry = dict(raw_entry)
                if isinstance(entry.get("source"), str):
                    entry["source"] = (
                        PurePosixPath(TEST_OVERLAY_RELATIVE_ROOT) / entry["source"]
                    ).as_posix()
                overlay_entries.append(entry)
            combined_document = dict(base_document)
            combined_document["entries"] = [
                *base_document["entries"],
                *overlay_entries,
            ]
            (snapshot_product / "compose.json").write_text(
                json.dumps(combined_document, indent=2) + "\n",
                encoding="utf-8",
            )
        try:
            placements = load_placements(snapshot_product / "compose.json", snapshot_product)
        except ComposeError as error:
            raise ImageCompositionError(f"invalid product composition plan: {error}") from None
        _verify_product_agents(snapshot_product, placements)
        stock_super = work / "super-stock.img"
        with _open_artifact(document, source_root, archive_paths, super_artifact) as stream:
            _copy_stream(stream, stock_super)

        with stock_super.open("rb") as stream:
            metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if metadata is None:
            raise ImageCompositionError("super.img has no liblp metadata.")
        system_ext_partition = next(
            (item for item in metadata.logical_partitions if item.name == SYSTEM_EXT), None
        )
        odm_partition = next(
            (item for item in metadata.logical_partitions if item.name == ODM_PARTITION), None
        )
        stock_vendor_partition = next(
            (item for item in metadata.logical_partitions if item.name == VENDOR_PARTITION), None
        )
        if (
            system_ext_partition is None
            or system_ext_partition.size != system_ext_manifest_size
            or system_ext_partition.group != "google_system_dynamic_partitions_a"
            or odm_partition is None
            or odm_partition.size != odm_manifest_size
            or odm_partition.group != "google_vendor_dynamic_partitions_a"
            or stock_vendor_partition is None
            or stock_vendor_partition.size != vendor_manifest_size
            or stock_vendor_partition.group != "google_vendor_dynamic_partitions_a"
        ):
            raise ImageCompositionError(
                "system_ext_a, odm_a, or vendor_a does not match the pinned manifest "
                "and super groups."
            )

        stock_vbmeta_system = work / "vbmeta-system-stock.img"
        with _open_artifact(
            document, source_root, archive_paths, _artifact_for_partition(document, "vbmeta_system")
        ) as stream:
            _copy_stream(stream, stock_vbmeta_system)
        stock_vbmeta = work / "vbmeta-stock.img"
        with _open_artifact(
            document, source_root, archive_paths, _artifact_for_partition(document, "vbmeta")
        ) as stream:
            _copy_stream(stream, stock_vbmeta)

        stock_system_ext = work / "system-ext-stock.img"
        _copy_logical_partition(stock_super, SYSTEM_EXT, stock_system_ext)
        descriptor = stock_system_ext_descriptor(avbtool, stock_system_ext)
        stock_fs = work / "system-ext-stock.erofs"
        _copy_prefix(stock_system_ext, stock_fs, int(descriptor["imageSize"]))

        # The plan labels must agree with the stock platform and system_ext file contexts.
        # The system partition footer is removed using the size recorded by its verified AVB tool.
        system_partition = work / "system-stock.img"
        _copy_logical_partition(stock_super, SYSTEM_PARTITION, system_partition)
        system_image = work / "system-stock.erofs"
        system_size = _original_size(_info(avbtool, system_partition), "system_a")
        _copy_prefix(system_partition, system_image, system_size)

        partition_trees: dict[str, Path] = {
            "system": work / "system-tree",
            "system_ext": work / "system-ext-tree",
        }
        export_tree(tools, system_image, partition_trees["system"])
        export_tree(tools, stock_fs, partition_trees["system_ext"])
        stock_product = work / "product-stock.img"
        stock_vendor = work / "vendor-stock.img"
        stock_odm = work / "odm-stock.img"
        _copy_logical_partition(stock_super, "product_a", stock_product)
        _copy_logical_partition(stock_super, VENDOR_PARTITION, stock_vendor)
        _copy_logical_partition(stock_super, ODM_PARTITION, stock_odm)
        product_fs = work / "product-stock.erofs"
        vendor_fs = work / "vendor-stock.erofs"
        odm_fs = work / "odm-stock.erofs"
        _filesystem_prefix(avbtool, stock_product, "product", product_fs)
        _filesystem_prefix(avbtool, stock_vendor, "vendor", vendor_fs)
        _filesystem_prefix(avbtool, stock_odm, "odm", odm_fs)
        stock_vendor_descriptor = _partition_tree(
            _info(avbtool, stock_vendor), "vendor", "the stock vendor_a"
        )
        top_vendor_descriptor = _partition_tree(
            _info(avbtool, stock_vbmeta), "vendor", "the stock vbmeta_a"
        )
        if top_vendor_descriptor != stock_vendor_descriptor:
            raise ImageCompositionError(
                "the stock vendor_a footer and vbmeta_a descriptor disagree."
            )
        for name, image in (("product", product_fs), ("vendor", vendor_fs), ("odm", odm_fs)):
            tree = work / f"{name}-tree"
            export_tree(tools, image, tree)
            partition_trees[name] = tree
        odm_output_tree = work / "odm-policy-tree"
        shutil.copytree(partition_trees["odm"], odm_output_tree, symlinks=True)

        _verify_product_labels(
            placements,
            snapshot_product,
            partition_trees["system"],
            partition_trees["system_ext"],
        )

        vendor_work = work / "vendor-rebuild"
        vendor_work.mkdir()
        vendor_uuid = deterministic_filesystem_uuid(
            "vendor", sha256_file(vendor_fs), product_inputs
        )
        platform_contexts = read_contexts_text(
            _partition_mount_root(partition_trees["system"], "system")
            / "etc/selinux/plat_file_contexts"
        )
        rebuilt_vendor = rebuild_vendor(
            tools,
            vendor_fs,
            vendor_work,
            mesa_libraries,
            plat_name="system_a:/system/etc/selinux/plat_file_contexts",
            plat_text=platform_contexts,
            image_uuid=vendor_uuid,
        )
        required_vendor_size = minimum_partition_size_for_descriptor(
            avbtool,
            rebuilt_vendor.image,
            partition_name="vendor",
            current_size=stock_vendor_partition.size,
            maximum_size=stock_vendor_partition.size,
            descriptor=stock_vendor_descriptor,
            fec=fec_tool,
        )
        if required_vendor_size != stock_vendor_partition.size:
            raise ImageCompositionError(
                "the Mesa libraries require changing the vendor_a partition size."
            )
        sealed_vendor = work / "vendor-sealed.img"
        sealed_vendor_descriptor = seal_partition(
            avbtool,
            rebuilt_vendor.image,
            sealed_vendor,
            partition_name="vendor",
            partition_size=stock_vendor_partition.size,
            stock_descriptor=stock_vendor_descriptor,
            fec=fec_tool,
        )

        policy_replacements, odm_tree, policy_record = _policy_replacements(
            tools,
            snapshot_product,
            partition_trees,
            work,
            repository,
            selinux_tools_root,
            odm_output_tree,
        )
        stock_odm_descriptor = _partition_tree(_info(avbtool, stock_odm), "odm", "the stock odm_a")
        top_odm_descriptor = _partition_tree(
            _info(avbtool, stock_vbmeta), "odm", "the stock vbmeta_a"
        )
        if top_odm_descriptor != stock_odm_descriptor:
            raise ImageCompositionError("the stock odm_a footer and vbmeta_a descriptor disagree.")
        image_uuid_inputs = [
            *product_inputs,
            *(test_overlay_inputs or ()),
        ]
        image_uuid = deterministic_system_ext_uuid(
            sha256_file(stock_fs),
            sorted(image_uuid_inputs, key=lambda item: item["path"].encode("utf-8")),
        )
        rebuilt = rebuild_system_ext(
            tools,
            stock_fs,
            snapshot_product,
            work,
            image_uuid=image_uuid,
            replacements=policy_replacements,
        )
        odm_uuid = deterministic_filesystem_uuid("odm", sha256_file(odm_fs), product_inputs)
        rebuilt_odm, odm_rebuild_record = _rebuild_odm_policy(
            tools,
            odm_fs,
            odm_tree,
            odm_output_tree,
            work,
            image_uuid=odm_uuid,
        )
        stock_limit = partition_growth_limit(stock_super, SYSTEM_EXT)
        required_partition_size = minimum_partition_size(
            avbtool,
            rebuilt.image,
            current_size=system_ext_partition.size,
            maximum_size=stock_limit,
            salt=str(descriptor["salt"]),
            fec=fec_tool,
        )

        base_super = stock_super
        growth_record: dict[str, Any] = {
            "previousBytes": system_ext_partition.size,
            "requiredBytes": required_partition_size,
            "grownBytes": system_ext_partition.size,
            "group": system_ext_partition.group,
        }
        if required_partition_size > system_ext_partition.size:
            grown_super = work / "super-grown.img"
            growth_result = grow_partition(
                stock_super, SYSTEM_EXT, required_partition_size, grown_super
            )
            base_super = grown_super
            growth_record["grownBytes"] = growth_result.partition_size
            growth_record["allocatedExtents"] = len(growth_result.allocated_extents)

        with base_super.open("rb") as stream:
            grown_metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if grown_metadata is None:
            raise ImageCompositionError("grown super.img has no liblp metadata.")
        grown_system_ext = next(
            item for item in grown_metadata.logical_partitions if item.name == SYSTEM_EXT
        )
        sealed_system_ext = work / "system-ext-sealed.img"
        sealed_descriptor = seal_system_ext(
            avbtool,
            rebuilt.image,
            sealed_system_ext,
            partition_size=grown_system_ext.size,
            stock_descriptor=descriptor,
            fec=fec_tool,
        )
        after_system_ext = work / "super-system-ext-composed.img"
        replace_partition(base_super, SYSTEM_EXT, sealed_system_ext, after_system_ext)

        with after_system_ext.open("rb") as stream:
            after_ext_metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if after_ext_metadata is None:
            raise ImageCompositionError("composed super.img has no liblp metadata.")
        stock_odm_partition = next(
            (item for item in metadata.logical_partitions if item.name == ODM_PARTITION), None
        )
        odm_partition = next(
            (item for item in after_ext_metadata.logical_partitions if item.name == ODM_PARTITION),
            None,
        )
        if (
            odm_partition is None
            or stock_odm_partition is None
            or odm_partition.group != stock_odm_partition.group
        ):
            raise ImageCompositionError(
                "odm_a does not preserve its pinned dynamic-partition group."
            )
        odm_limit = partition_growth_limit(after_system_ext, ODM_PARTITION)
        required_odm_size = minimum_partition_size_for_descriptor(
            avbtool,
            rebuilt_odm,
            partition_name="odm",
            current_size=odm_partition.size,
            maximum_size=odm_limit,
            descriptor=stock_odm_descriptor,
            fec=fec_tool,
        )
        after_odm_growth = after_system_ext
        odm_growth_record: dict[str, Any] = {
            "previousBytes": odm_partition.size,
            "requiredBytes": required_odm_size,
            "grownBytes": odm_partition.size,
            "group": odm_partition.group,
        }
        if required_odm_size > odm_partition.size:
            grown_odm_super = work / "super-grown-odm.img"
            odm_growth = grow_partition(
                after_system_ext, ODM_PARTITION, required_odm_size, grown_odm_super
            )
            after_odm_growth = grown_odm_super
            odm_growth_record["grownBytes"] = odm_growth.partition_size
            odm_growth_record["allocatedExtents"] = len(odm_growth.allocated_extents)

        with after_odm_growth.open("rb") as stream:
            final_metadata = lp.read_dynamic_partitions(stream, sparse=True)
        if final_metadata is None:
            raise ImageCompositionError("grown super.img has no liblp metadata.")
        final_odm = next(
            item for item in final_metadata.logical_partitions if item.name == ODM_PARTITION
        )
        sealed_odm = work / "odm-sealed.img"
        sealed_odm_descriptor = seal_partition(
            avbtool,
            rebuilt_odm,
            sealed_odm,
            partition_name="odm",
            partition_size=final_odm.size,
            stock_descriptor=stock_odm_descriptor,
            fec=fec_tool,
        )
        after_odm = work / "super-odm-composed.img"
        replace_partition(after_odm_growth, ODM_PARTITION, sealed_odm, after_odm)
        composed_super = stage / "super.img"
        replace_partition(after_odm, VENDOR_PARTITION, sealed_vendor, composed_super)

        composed_vbmeta_system = stage / "vbmeta_system_a.img"
        vbmeta_system_record = refresh_system_ext_vbmeta(
            avbtool,
            stock_vbmeta_system,
            sealed_system_ext,
            avb_signing_key,
            composed_vbmeta_system,
        )
        if vbmeta_system_record.get("previousDescriptor") != descriptor:
            raise ImageCompositionError(
                "the stock system_ext_a footer and vbmeta_system_a descriptor disagree."
            )
        vbmeta_after_odm = work / "vbmeta-after-odm.img"
        odm_vbmeta_record = refresh_vbmeta_partition(
            avbtool,
            stock_vbmeta,
            sealed_odm,
            "odm",
            avb_signing_key,
            vbmeta_after_odm,
            work,
        )
        if odm_vbmeta_record.get("previousDescriptor") != stock_odm_descriptor:
            raise ImageCompositionError("the stock odm_a footer and vbmeta_a descriptor disagree.")
        if odm_vbmeta_record.get("descriptor") != sealed_odm_descriptor:
            raise ImageCompositionError("the refreshed vbmeta_a odm descriptor is incorrect.")
        composed_vbmeta = stage / "vbmeta_a.img"
        vendor_vbmeta_record = refresh_vbmeta_partition(
            avbtool,
            vbmeta_after_odm,
            sealed_vendor,
            "vendor",
            avb_signing_key,
            composed_vbmeta,
            work,
        )
        if vendor_vbmeta_record.get("previousDescriptor") != stock_vendor_descriptor:
            raise ImageCompositionError(
                "the stock vendor_a footer and vbmeta_a descriptor disagree."
            )
        if vendor_vbmeta_record.get("descriptor") != sealed_vendor_descriptor:
            raise ImageCompositionError("the refreshed vbmeta_a vendor descriptor is incorrect.")
        if (
            _partition_tree(_info(avbtool, composed_vbmeta), "odm", "the composed vbmeta_a")
            != sealed_odm_descriptor
            or _partition_tree(_info(avbtool, composed_vbmeta), "vendor", "the composed vbmeta_a")
            != sealed_vendor_descriptor
        ):
            raise ImageCompositionError(
                "the composed vbmeta_a does not carry both updated partition descriptors."
            )
        growth_record["grownBytes"] = grown_system_ext.size
        odm_growth_record["grownBytes"] = final_odm.size
        vendor_record = {
            "stockFilesystemSHA256": sha256_file(vendor_fs),
            "imageUUID": vendor_uuid,
            "filesystemBytes": rebuilt_vendor.image.stat().st_size,
            "stockEntriesReproduced": rebuilt_vendor.reproduced,
            "stockBlocks": rebuilt_vendor.stock_blocks,
            "filesystemBlocks": rebuilt_vendor.fs_blocks,
            "mesa": mesa_record,
            "injectedLibraries": [
                {
                    "name": library.name,
                    "source": (
                        f"Guest/product/{MESA_PRODUCT_RELATIVE_PATH}/vendor/lib64/{library.name}"
                    ),
                    "target": library.target,
                    "sha256": library.sha256,
                    "size": library.size,
                    "selinuxLabel": rebuilt_vendor.mesa_entries[library.target].label,
                }
                for library in mesa_libraries
            ],
            "descriptor": sealed_vendor_descriptor,
        }
        record = _composition_provenance(
            document,
            manifest_path,
            product_inputs,
            test_overlay_inputs=test_overlay_inputs,
            repository=repository,
            stock_system_ext_sha256=sha256_file(stock_fs),
            vendor=vendor_record,
            rebuild={
                "image_uuid": rebuilt.image_uuid,
                "filesystem_bytes": rebuilt.image.stat().st_size,
                "stock_entries_reproduced": rebuilt.stock_entries_reproduced,
                "added_entries": len(rebuilt.added_entries),
            },
            system_ext_descriptor=sealed_descriptor,
            odm_descriptor=sealed_odm_descriptor,
            vendor_descriptor=sealed_vendor_descriptor,
            odm={
                **odm_rebuild_record,
                "stockFilesystemSHA256": sha256_file(odm_fs),
            },
            policy=policy_record,
            growth=growth_record,
            tool_version=tools.version,
        )
        record["vbmeta"] = {
            "systemExt": vbmeta_system_record,
            "topLevel": {
                "updates": [
                    {"updatedPartition": "odm", **odm_vbmeta_record},
                    {"updatedPartition": "vendor", **vendor_vbmeta_record},
                ]
            },
        }
        record["odmGrowth"] = odm_growth_record
        record["outputHashes"] = {
            filename: sha256_file(stage / filename)
            for filename in ("super.img", "vbmeta_system_a.img", "vbmeta_a.img")
        }
        record_bytes = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8")
        (stage / "composition.json").write_bytes(record_bytes)
        for filename in OUTPUT_FILES:
            path = stage / filename
            if path.is_symlink() or not path.is_file():
                raise ImageCompositionError(f"{path}: a composition output is missing or unsafe.")
        shutil.rmtree(snapshot_product)
        shutil.rmtree(work)
        os.rename(stage, output_directory)
        return record
    except (
        ComposeAvbError,
        ComposeError,
        ContextsError,
        ErofsError,
        ExtractError,
        ImageCompositionError,
        LpGrowError,
        LpWriteError,
        ManifestError,
        OSError,
        ValueError,
    ):
        shutil.rmtree(stage, ignore_errors=True)
        raise


def _filesystem_is_case_sensitive(directory: Path) -> bool:
    """Probe the output filesystem without leaving files behind."""
    try:
        with tempfile.TemporaryDirectory(prefix=".apkrun-case-check-", dir=directory) as probe:
            probe_directory = Path(probe)
            original = probe_directory / "ApkRunCaseCheck"
            differently_cased = probe_directory / "apkruncasecheck"
            original.write_bytes(b"")
            return not differently_cased.exists()
    except OSError as error:
        raise ImageCompositionError(
            f"{directory}: cannot check filesystem case sensitivity: {error}."
        ) from None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image compose",
        description="Compose an APKRun development image from a pinned stock Android build.",
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="source archive or image directory")
    parser.add_argument("--inventory", type=Path, help="inventory.json for manifest checks")
    parser.add_argument(
        "--product",
        type=Path,
        default=_repository_root() / "Guest/product",
        help="APKRun product directory (defaults to Guest/product)",
    )
    parser.add_argument(
        "--test-overlay",
        action="store_true",
        help=f"add the fixed {TEST_OVERLAY_RELATIVE_ROOT} fixture overlay",
    )
    parser.add_argument(
        "--erofs-tools",
        type=Path,
        default=_repository_root() / "ThirdParty/out/erofs-utils",
    )
    parser.add_argument(
        "--selinux-tools",
        type=Path,
        default=_repository_root() / "ThirdParty/out/selinux-tools",
        help="pinned secilc build directory or build-cache root",
    )
    parser.add_argument(
        "--fec-tool",
        type=Path,
        default=_repository_root() / "ThirdParty/out/fec/bin/fec",
        help="verified pinned FEC utility (defaults to ThirdParty/out/fec/bin/fec)",
    )
    parser.add_argument(
        "--avb-key",
        type=Path,
        default=_repository_root() / "Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem",
    )
    parser.add_argument("--out", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        output_directory = arguments.out.expanduser()
        output_parent = output_directory.parent
        output_parent.mkdir(parents=True, exist_ok=True)
        if output_parent.is_symlink():
            raise ImageCompositionError(f"{output_parent}: output parent must not be a symlink.")
        if not _filesystem_is_case_sensitive(output_parent):
            raise ImageCompositionError(
                f"{output_parent}: composition output must be on a case-sensitive filesystem; "
                "use case-sensitive APFS scratch storage on macOS."
            )
        compose_image(
            arguments.manifest,
            source=arguments.source,
            inventory_path=arguments.inventory,
            product_root=arguments.product,
            erofs_tools_root=arguments.erofs_tools,
            selinux_tools_root=arguments.selinux_tools,
            fec_tool=arguments.fec_tool,
            avb_signing_key=arguments.avb_key,
            output_directory=output_directory,
            test_overlay=arguments.test_overlay,
        )
    except (
        ComposeAvbError,
        ComposeError,
        ContextsError,
        ErofsError,
        ExtractError,
        ImageCompositionError,
        LpGrowError,
        LpWriteError,
        ManifestError,
        OSError,
        ValueError,
    ) as error:
        print(f"apkrun_image compose: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
