"""Build and sign a runtime image bundle (android-image.md §10; runtime-image-manifest.md).

`bundle` runs `extract` and `disks`, writes `boot/bootconfig.txt` from the vendor
bootconfig, the layout's image layer, and the AVB values, then writes
`manifest.json`, `SHA256SUMS`, and `manifest.sig`. The manifest is validated
against the schema and rules S1–S14 before anything is written. The bundle is
deterministic: the same inputs and tool revision give the same bytes.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any, BinaryIO

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from apkrun_image import __version__
from apkrun_image.avb import AvbError, calculate_vbmeta_bootconfig
from apkrun_image.bootconfig import (
    MAX_BUILD_BOOTCONFIG_SIZE,
    BootconfigError,
    BootconfigLayer,
    merge_bootconfig_layers,
    parse_bootconfig_text,
    serialize_bootconfig,
)
from apkrun_image.disks import DisksError, build_disks
from apkrun_image.extract import RAMDISK_OUTPUT, ExtractError, _open_artifact, extract_images
from apkrun_image.gpt import GptError
from apkrun_image.layout import LayoutError, load_layout
from apkrun_image.manifest import (
    ManifestError,
    _archive_paths,
    _load_json,
    _repository_root,
    _resolve_archive_root,
)
from apkrun_image.runtime_manifest import validate
from apkrun_image.sign import SignatureError, load_private_key, render_signature
from apkrun_image.sparse import SparseImageError

SCHEMA_VERSION = 1
SHORT_VERSION_PATTERN = re.compile(r"^[0-9]{4}\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})$")
MINIMUM_RUNTIME_VERSION = "0.1.0"
GUEST_PROTOCOL = {"min": 1, "max": 1}
USERDATA_SCHEMA_VERSION = 1


class BundleError(ValueError):
    """The bundle cannot be built from these inputs."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _file_entry(root: Path, relative: str) -> dict[str, object]:
    path = root / relative
    return {"path": relative, "size": path.stat().st_size, "sha256": _sha256(path)}


def _lock_commit(name: str) -> str:
    lock = _load_json(_repository_root() / "ThirdParty/ThirdParty.lock.json", description="lock")
    for component in lock.get("components", []) if isinstance(lock, dict) else []:
        if isinstance(component, dict) and component.get("name") == name:
            commit = component.get("commit")
            if isinstance(commit, str):
                return commit
    raise BundleError(f"ThirdParty.lock.json has no commit for {name}.")


def _tools_revision() -> str:
    root = _repository_root()
    try:
        revision = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain", "--", "Images/tools"],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise BundleError(f"Could not read the git revision of Images/tools: {error}.") from None
    return revision + ("-dirty" if status.strip() else "")


def _load_signing_key(path: Path) -> Ed25519PrivateKey:
    expanded = path.expanduser()
    if not expanded.is_file():
        raise BundleError(
            f"--sign-key {expanded} does not exist; create it with "
            "python3 -m apkrun_image keygen --out " + str(expanded)
        )
    try:
        return load_private_key(expanded)
    except (SignatureError, ValueError, OSError) as error:
        raise BundleError(f"--sign-key {expanded} is not a usable Ed25519 key: {error}") from None


def _repository_relative(path: Path) -> str:
    root = _repository_root().resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise BundleError(f"{path} must be inside the repository.")
    return resolved.relative_to(root).as_posix()


def _bootconfig_text(vendor: Mapping[str, str], image: Mapping[str, str]) -> str:
    def section(values: Mapping[str, str]) -> str:
        return serialize_bootconfig(values).decode("ascii")

    return "[vendor]\n" + section(vendor) + "[image]\n" + section(image)


def _target_sdk_floor(sdk: int) -> int:
    return 23 if sdk <= 34 else 24


def _kernel_page_size(extraction: Mapping[str, Any]) -> int:
    """The page size the kernel header declares (runtime-image-manifest.md §4.4).

    Flags bits 1-2 of the arm64 Image header give 4 KiB, 16 KiB, or 64 KiB. Zero
    means the kernel declares nothing, and the schema has no value for that, so
    the build stops instead of guessing.
    """
    page_size = extraction["kernel"]["pageSize"]
    if page_size not in (4096, 16384, 65536):
        raise BundleError(
            "the kernel header declares no page size (flags bits 1-2 are 0); "
            "the bundle cannot record kernelPageSize"
        )
    return int(page_size)


def _checksums(files: Sequence[Mapping[str, object]]) -> str:
    """Render SHA256SUMS: one `<sha256>  <path>` line per file, in `files` order (§6.2)."""
    return "".join(f"{entry['sha256']}  {entry['path']}\n" for entry in files)


@contextlib.contextmanager
def _staging(output: Path) -> Iterator[Path]:
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.bundle-", dir=output.parent))
    try:
        yield stage
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def build_bundle(
    document: Mapping[str, Any],
    *,
    layout_path: Path,
    reference: Path | None,
    image_version: str,
    output_directory: Path,
    source: Path | None = None,
    inventory_path: Path | None = None,
    sign_key: Path,
) -> dict[str, object]:
    """Build a signed bundle in `output_directory`."""
    if not SHORT_VERSION_PATTERN.fullmatch(image_version):
        raise BundleError("--image-version must be the short form YYYY.MM.N.")
    signing_key = _load_signing_key(sign_key)
    device_family = document.get("deviceFamily")
    if not isinstance(device_family, str):
        raise BundleError("manifest deviceFamily is missing.")
    layout = load_layout(layout_path, device_family)
    if not layout.console_ports or layout.gpu_profiles is None:
        raise BundleError("the layout needs consolePorts and gpuProfiles to build a bundle.")
    source_block = document["source"]
    full_version = f"{image_version}-cf{source_block['buildId']}-arm64"

    output_directory = output_directory.expanduser()
    if output_directory.exists() and not output_directory.is_dir():
        raise BundleError(f"{output_directory}: output path is not a directory.")
    with _staging(output_directory) as stage:
        extract_images(
            document,
            output_directory=stage / "extract",
            layout_path=layout_path,
            source=source,
            inventory_path=inventory_path,
        )
        disks = build_disks(
            document,
            layout_path=layout_path,
            output_directory=stage / "disks-build",
            image_version=full_version,
            source=source,
            inventory_path=inventory_path,
        )
        bundle = stage / "bundle"
        for directory in ("boot", "disks", "templates"):
            (bundle / directory).mkdir(parents=True)
        os.replace(stage / "extract/kernel", bundle / "boot/kernel")
        os.replace(stage / "extract" / RAMDISK_OUTPUT, bundle / "boot" / RAMDISK_OUTPUT)
        command_line = (stage / "extract/cmdline.txt").read_text(encoding="ascii").strip()
        if "bootconfig" not in command_line.split():
            raise BundleError(
                "the kernel command line lacks the bootconfig token "
                "(runtime-image-manifest.md §3.3); add it to the layout cmdline.additions."
            )
        (bundle / "boot/cmdline.txt").write_text(command_line, encoding="ascii")

        vendor = parse_bootconfig_text(
            (stage / "extract/vendor-bootconfig.txt").read_text(encoding="ascii"),
            layer_name="vendor",
        )
        root = _resolve_archive_root(document, source=source)
        archives = _archive_paths(root, document["source"]["archives"])

        def open_artifact(
            artifact: Mapping[str, Any],
        ) -> contextlib.AbstractContextManager[BinaryIO]:
            return _open_artifact(document, root, archives, artifact)

        image = dict(layout.document["bootconfig"]["image"])
        image.update(calculate_vbmeta_bootconfig(document, open_artifact))
        merge_bootconfig_layers(
            [BootconfigLayer("vendor", vendor), BootconfigLayer("image", image)]
        )
        for name, profile in layout.gpu_profiles.items():
            merged = merge_bootconfig_layers(
                [
                    BootconfigLayer("vendor", vendor),
                    BootconfigLayer("image", image),
                    BootconfigLayer(f"gpu:{name}", profile["bootconfig"]),
                ]
            )
            if len(serialize_bootconfig(merged)) > MAX_BUILD_BOOTCONFIG_SIZE:
                raise BundleError(f"layers 1 and 2 with gpuProfiles.{name} exceed 16 KiB.")
        (bundle / "boot/bootconfig.txt").write_text(
            _bootconfig_text(vendor, image), encoding="ascii"
        )

        disk_entries: list[dict[str, object]] = []
        template_entries: list[dict[str, object]] = []
        for record in disks["disks"]:  # type: ignore[union-attr]
            target = "disks" if record["readOnly"] else "templates"
            relative = f"{target}/{record['file']}"
            os.replace(stage / "disks-build" / record["file"], bundle / relative)
            entry: dict[str, object] = {
                "role": record["role"],
                "path": relative,
                "readOnly": record["readOnly"],
                "identifier": record["identifier"],
                "logicalSize": record["logicalSize"],
                "partitions": [
                    {key: partition[key] for key in ("label", "firstLBA", "size", "sha256")}
                    for partition in record["partitions"]
                ],
            }
            if "userdataStrategy" in record:
                entry["userdataStrategy"] = record["userdataStrategy"]
            (disk_entries if record["readOnly"] else template_entries).append(entry)

        boot_paths = {
            "kernel": "boot/kernel",
            "ramdisk": f"boot/{RAMDISK_OUTPUT}",
            "bootconfig": "boot/bootconfig.txt",
            "cmdline": "boot/cmdline.txt",
        }
        file_paths = sorted(
            [
                *boot_paths.values(),
                *(str(entry["path"]) for entry in disk_entries + template_entries),
            ]
        )
        files = [_file_entry(bundle, path) for path in file_paths]
        by_path = {entry["path"]: entry for entry in files}
        extraction = json.loads((stage / "extract/extraction.json").read_text(encoding="utf-8"))
        android = document["android"]
        manifest: dict[str, object] = {
            "schemaVersion": SCHEMA_VERSION,
            "imageVersion": full_version,
            "kind": "stock",
            "provenance": {
                "source": source_block,
                "android": android,
                "deviceFamily": device_family,
                "layout": {
                    "path": _repository_relative(layout_path),
                    "sha256": _sha256(layout_path),
                },
                "reference": _repository_relative(reference) if reference is not None else None,
                "tools": {
                    "apkrunImage": __version__,
                    "mkbootimg": _lock_commit("aosp-mkbootimg"),
                    "avbtool": _lock_commit("aosp-avbtool"),
                },
                "revisions": {"imagesTools": _tools_revision(), "guest": None},
                "pinnedManifestSHA256": None,
                "builderImageDigest": None,
            },
            "guest": {
                "sdk": android["sdk"],
                "abis": ["arm64-v8a"],
                "targetSdkFloor": _target_sdk_floor(int(android["sdk"])),
            },
            "boot": {
                **{key: by_path[path] for key, path in boot_paths.items()},
                "kernelPageSize": _kernel_page_size(extraction),
                "bootconfigOverrides": [],
            },
            "disks": disk_entries,
            "templates": template_entries,
            "consolePorts": [
                {"index": port.index, "role": port.role, "name": port.name}
                for port in layout.console_ports
            ],
            "gpuProfiles": layout.gpu_profiles,
            "requirements": {
                "minimumRuntimeVersion": MINIMUM_RUNTIME_VERSION,
                "guestProtocol": GUEST_PROTOCOL,
                "agents": [],
            },
            "userdata": {
                "schemaVersion": USERDATA_SCHEMA_VERSION,
                "upgradableFrom": [USERDATA_SCHEMA_VERSION],
            },
            "compatibility": {"upgradeFrom": {"minimumImageVersion": image_version}},
            "files": files,
        }
        violations = validate(manifest)
        if violations:
            first = violations[0]
            raise BundleError(f"the manifest fails {first.rule} at {first.path}: {first.reason}")
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        (bundle / "manifest.json").write_bytes(manifest_bytes)
        (bundle / "SHA256SUMS").write_text(_checksums(files), encoding="ascii")
        (bundle / "manifest.sig").write_bytes(render_signature(manifest_bytes, signing_key))

        if output_directory.exists():
            shutil.rmtree(output_directory)
        os.replace(bundle, output_directory)
    return manifest


def build_parser() -> argparse.ArgumentParser:
    """Build the bundle command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image bundle",
        description="Build a runtime image bundle from an Android image manifest.",
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="source archive or directory")
    parser.add_argument("--inventory", type=Path, help="inventory.json for manifest checks")
    parser.add_argument("--layout", type=Path, help="defaults to layouts/<deviceFamily>.json")
    parser.add_argument("--reference", type=Path, help="the reference capture used for the layout")
    parser.add_argument("--image-version", required=True, help="short form YYYY.MM.N")
    parser.add_argument(
        "--sign-key",
        required=True,
        type=Path,
        help="Ed25519 private key from `python3 -m apkrun_image keygen`",
    )
    parser.add_argument("--out", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Build the bundle and report actionable failures."""
    arguments = build_parser().parse_args(argv)
    try:
        document = _load_json(arguments.manifest, description="manifest")
        if not isinstance(document, dict) or not isinstance(document.get("deviceFamily"), str):
            raise BundleError("manifest: top level must be an object with a deviceFamily.")
        layout_path = arguments.layout or (
            _repository_root() / "Images/tools/layouts" / f"{document['deviceFamily']}.json"
        )
        build_bundle(
            document,
            layout_path=layout_path,
            reference=arguments.reference,
            image_version=arguments.image_version,
            output_directory=arguments.out,
            source=arguments.source,
            inventory_path=arguments.inventory,
            sign_key=arguments.sign_key,
        )
    except (
        AvbError,
        BootconfigError,
        BundleError,
        DisksError,
        ExtractError,
        GptError,
        LayoutError,
        ManifestError,
        SparseImageError,
        OSError,
    ) as error:
        print(f"apkrun_image bundle: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
