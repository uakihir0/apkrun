"""Build a signed ODM overlay control for the exact #099 2026.10.2 image (test only).

The source bundle is the installed 2026.10.2-cf16373615-arm64 Mesa variant. The output uses a
new imageVersion and changes only the `odm_a` logical partition, its signed top-level `vbmeta_a`,
bootconfig's vbmeta digest, and the corresponding bundle hashes/signature:

- in `full-control`, the precompiled policy applies all 18 candidate rules together: the
  SurfaceFlinger rule of #022, candidate uevent and DRM-device rules for `untrusted_app` (IR-991),
  and candidate sysfs rules explored for privileged and system app DRM probes (IR-1278); no
  individual rule is isolated. `surfaceflinger-egl` applies only SurfaceFlinger's `sysfs` open/read
  pair, without isolating those two permissions from each other;
- the test binary `/bin/apkrun_egl_test` and its init rc `/etc/init/apkrun_egl_test.rc`, which runs
  the binary once on sys.boot_completed (test variant only; no command-line gate, IR-993);
- the top-level `vbmeta_a` carries the new `odm` hashtree descriptor.

These test-only bundles are diagnostic and must not be shipped or distributed as product images.
`full-control` grants broad type-wide access; `surfaceflinger-egl` limits its policy edit to the
two SurfaceFlinger rules but still adds the test binary and a service that starts automatically at
boot without an opt-in gate. Manifests and checksums use the bundle module's validators and signers;
the AOSP-key vbmeta is checked to differ from the source only in the ODM descriptor. The record
beside each bundle binds its exact policy, tools, source, signatures, and output hashes.

Stages (each one is checked, and the script stops at the first failed check):

  prepare   read `odm_a` and `vbmeta_a`, check the stock odm footer and descriptor, export the tree
  build     edit the precompiled policy, rebuild and seal `odm_a`, refresh and sign vbmeta,
            replace both partitions, update bootconfig, and sign a new bundle manifest
  check     read the bundle back and verify signatures, hashes, unchanged AVB descriptors,
            ODM hashtree, exact policy edit, diagnostic payloads, and provenance receipt

The default `full-control` profile applies all 18 candidate rules. The
`surfaceflinger-egl` profile applies only SurfaceFlinger's `sysfs` open/read
rules, to test the narrow EGL-initialization hypothesis. `prepare` is
profile-neutral; select the same profile for `build` and `check`.

No VM is started by this script. The ramdisk and the kernel are the #099 ones, unchanged.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Images" / "tools"))

from apkrun_image import bundle_variant as bv
from apkrun_image import erofs as ef
from apkrun_image import lp
from apkrun_image import vendor_inject as vi
from apkrun_image import vendor_reseal as vr
from apkrun_image.bundle import _checksums, _load_signing_key
from apkrun_image.sign import key_id_of, render_signature, verify_signature
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

SRC = Path(os.environ.get(
    "APKRUN_022_SOURCE_BUNDLE",
    "/tmp/apkrun-099-home-2026102/Images/2026.10.2-cf16373615-arm64",
))
WORK = Path(os.environ.get(
    "APKRUN_022_ODM_WORK", "/tmp/apkrun-022-odm-2026102-control"
))
TOOLS = Path(os.environ.get("APKRUN_022_EROFS_TOOLS", "/tmp/apkrun-099-lp-erofs/tools"))
EDITOR = Path(os.environ.get(
    "APKRUN_022_POLICY_EDIT", "/tmp/apkrun-022-sepol-bin/policy-edit"
))
KEY = Path(os.environ.get(
    "APKRUN_022_IMAGE_SIGN_KEY", "~/.config/apkrun/dev-image-key"
)).expanduser()
AVB_KEY = REPO / "Tests" / "Fixtures" / "signing" / "aosp-avb-testkey-rsa4096.pem"
LIBSEPOL_ROOT = Path("/tmp/apkrun-022-sepol-src/libsepol-3.11")
IMAGE_VERSION = os.environ.get("APKRUN_022_IMAGE_VERSION", "2026.10.3")
SOURCE_IMAGE_VERSION = "2026.10.2-cf16373615-arm64"
SOURCE_MANIFEST_SHA256 = "c61d182eb93dc980ceb4dae2cd4d8b840aea060835b45507197b0fccbe507978"
SOURCE_DISK_SHA256 = "2b0fe6ddbe6031eeb60f309f0a4998db38d634d869d18b6715b63282333e3d3a"
OUTPUT_BUNDLE = WORK / "bundle" / "android-bundle"
OUTPUT_RECEIPT = WORK / "bundle" / "android-bundle.odm-control.json"
PARTITION = "odm_a"
VERITY = "odm"
PRECOMPILED = "/etc/selinux/precompiled_sepolicy"
UUID = "0220220a-0220-4220-8220-022022022022"
CHUNK = 64 * 1024 * 1024
BLOCK = 4096
PART_PRECOMPILED_STOCK_SHA = "6a1f95dad28bdf50"  # prefix of the file the guest loaded at boot
# The rules added to the stock precompiled policy: (source type, target type, class, permission).
# SurfaceFlinger: the rule of #022 (IR-942). platform_app: the uevent read that aborted platform_app
# RenderThreads (IR-954; requested for this variant). untrusted_app: the domain of HelloText, which
# targets SDK 37 with the test key (seapp_contexts: `minTargetSdkVersion=37 domain=untrusted_app`,
# IR-991). The DRM-device rules copy what SurfaceFlinger's EGL uses on the same node; in the
# stock policy only priv_app and platform_app have getattr there, and untrusted_app and
# system_app have none (IR-1277).
RULES = (
    # Apply these candidate rules as one diagnostic set; no single permission or domain has been
    # isolated as necessary. In particular, the untrusted_app grants apply to every node labelled
    # graphics_device and are not constrained to this test binary.
    ("surfaceflinger", "sysfs", "file", "open"),
    ("surfaceflinger", "sysfs", "file", "read"),
    ("platform_app", "sysfs", "file", "open"),
    ("platform_app", "sysfs", "file", "read"),
    ("untrusted_app", "sysfs", "file", "open"),
    ("untrusted_app", "sysfs", "file", "read"),
    ("untrusted_app", "graphics_device", "chr_file", "open"),
    ("untrusted_app", "graphics_device", "chr_file", "read"),
    ("untrusted_app", "graphics_device", "chr_file", "write"),
    ("untrusted_app", "graphics_device", "chr_file", "ioctl"),
    ("untrusted_app", "graphics_device", "chr_file", "map"),
    # Candidate Mesa DRM-probe rules for the privileged (launcher) and system (Settings) apps,
    # based on IR-1275 to IR-1278. libdrm reads the uevent and stats the PCI sysfs nodes of the
    # virtio-gpu device, which carry the default `sysfs` label. priv_app has no open, read, or
    # getattr there. The available logs show no priv_app denials; the IR-1277 dontaudit mask can
    # hide open/getattr denials, while a read denial would remain visible. Its exact access was
    # not isolated. system_app is denied read on uevent and getattr on /dev/dri/card0, and open
    # on uevent (logged in IR-1278); its sysfs getattr is in the booted set but was not tested
    # alone. The no-overlay image fails the DRM probe, but this combined control does not prove
    # these particular rules are necessary.
    ("priv_app", "sysfs", "file", "open"),
    ("priv_app", "sysfs", "file", "read"),
    ("priv_app", "sysfs", "file", "getattr"),
    ("system_app", "sysfs", "file", "open"),
    ("system_app", "sysfs", "file", "read"),
    ("system_app", "sysfs", "file", "getattr"),
    ("system_app", "graphics_device", "chr_file", "getattr"),
)
SURFACEFLINGER_EGL_RULES = (
    ("surfaceflinger", "sysfs", "file", "open"),
    ("surfaceflinger", "sysfs", "file", "read"),
)
RULE_PROFILES = {
    "full-control": RULES,
    "surfaceflinger-egl": SURFACEFLINGER_EGL_RULES,
}
ACTIVE_PROFILE = "full-control"
EGL_DIR = REPO / "Experiments" / "sepolicy-022" / "egl_check"
EGL_BINARY = Path(os.environ.get("APKRUN_022_EGL_BIN", "/tmp/apkrun-odmc/egl/apkrun_egl_test"))
EGL_BIN_PATH = "/bin/apkrun_egl_test"
EGL_BIN_LABEL = "u:object_r:surfaceflinger_exec:s0"  # init then starts it in the surfaceflinger domain
EGL_DIR_LABEL = "u:object_r:vendor_file:s0"  # the label of /odm itself
EGL_RC_PATH = "/etc/init/apkrun_egl_test.rc"
EGL_RC_LABEL = "u:object_r:vendor_configs_file:s0"  # the label of the other /odm/etc files
ETC_INIT_DIR_LABEL = "u:object_r:vendor_configs_file:s0"


class Check(SystemExit):
    pass


def need(condition: bool, message: str) -> None:
    if not condition:
        raise Check(f"CHECK FAILED: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_source_bundle(public_key: bytes) -> tuple[bytes, dict[str, Any]]:
    """Verify the pinned 2026.10.2 bundle and return that same verified snapshot."""
    manifest_bytes, manifest = bv._verify_stock(SRC, public_key)
    need(
        hashlib.sha256(manifest_bytes).hexdigest() == SOURCE_MANIFEST_SHA256,
        "the source manifest is not the recorded 2026.10.2 variant manifest",
    )
    need(
        manifest["imageVersion"] == SOURCE_IMAGE_VERSION,
        "the source bundle is not the exact 2026.10.2 Mesa variant",
    )
    disk, _record = bv._super_record(manifest)
    disk_entry = next(
        (entry for entry in manifest["files"] if entry["path"] == disk["path"]), None
    )
    need(
        disk_entry is not None and disk_entry["sha256"] == SOURCE_DISK_SHA256,
        "the source disk is not the recorded 2026.10.2 variant disk",
    )
    return manifest_bytes, manifest


def tree_sha256(root: Path) -> str:
    """Hash every regular file and relative path under a source tree deterministically."""
    need(root.is_dir() and not root.is_symlink(), f"{root} is not a source directory")
    digest = hashlib.sha256(b"APKRun experiment source tree v1\0")
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise Check(f"source tree contains a symlink: {path}")
        if path.is_dir():
            continue
        need(path.is_file(), f"source tree contains a non-file: {path}")
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(path.stat().st_size.to_bytes(8, "big"))
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


class Window:
    """A read-only stream over `size` bytes of `path` that start at `base`."""

    def __init__(self, path: Path, base: int, size: int) -> None:
        self._file = path.open("rb")
        self._base = base
        self._size = size
        self._pos = 0

    def read(self, count: int = -1) -> bytes:
        remaining = self._size - self._pos
        if remaining <= 0:
            return b""
        count = remaining if count is None or count < 0 else min(count, remaining)
        self._file.seek(self._base + self._pos)
        data = self._file.read(count)
        self._pos += len(data)
        return data

    def seek(self, offset: int, whence: int = 0) -> int:
        target = {0: offset, 1: self._pos + offset, 2: self._size + offset}[whence]
        self._pos = target
        return self._pos

    def tell(self) -> int:
        return self._pos

    def close(self) -> None:
        self._file.close()


def avbtool_path() -> Path:
    return vi.verify_avbtool(REPO, ef.load_component(vi.AVBTOOL_COMPONENT))


def info(avbtool: Path, image: Path) -> str:
    return vi.run_avbtool(avbtool, ["info_image", "--image", str(image)])


def odm_tree(info_text: str, what: str) -> dict[str, Any]:
    tree = vr.parse_hashtrees(info_text).get(VERITY)
    need(tree is not None, f"{what} has no {VERITY} hashtree descriptor")
    return tree


def read_super_odm(os_img: Path, super_offset: int, super_size: int, out: Path) -> int:
    window = Window(os_img, super_offset, super_size)
    try:
        metadata = lp.read_dynamic_partitions(window, sparse=False)
        need(metadata is not None, "the super partition has no liblp metadata")
        names = {item.name: item for item in metadata.logical_partitions}
        need(PARTITION in names, f"the super partition has no {PARTITION}")
        found = names[PARTITION]
        with out.open("wb") as handle:
            offset = 0
            while offset < found.size:
                length = min(CHUNK, found.size - offset)
                handle.write(lp.read_partition_range(window, found, offset, length, sparse=False))
                offset += length
        return found.size
    finally:
        window.close()


def verify_prepared_baseline(
    avbtool: Path,
    manifest: dict[str, Any],
    tools: ef.ErofsTools,
    stage: str,
) -> None:
    """Bind prepare's reusable scratch files and extracted tree to the pinned source bundle."""
    need(WORK.is_dir() and not WORK.is_symlink(), "the prepared work directory is not a real directory")
    scratch = WORK / f"baseline-{stage}"
    need(not scratch.exists() and not scratch.is_symlink(), f"{scratch} already exists")
    scratch.mkdir()
    prepared_odm = WORK / "odm_stock.img"
    prepared_fs = WORK / "odm_fs_stock.img"
    prepared_vbmeta = WORK / "vbmeta_src.img"
    prepared_tree = WORK / "tree-stock"
    try:
        for path in (prepared_odm, prepared_fs, prepared_vbmeta):
            need(path.is_file() and not path.is_symlink(),
                 f"{path} is not a regular prepared file")
        need(prepared_tree.is_dir() and not prepared_tree.is_symlink(),
             f"{prepared_tree} is not the prepared source tree")
        disk, record = bv._super_record(manifest)
        source_disk = SRC / disk["path"]
        super_offset, super_size = bv._super_location(source_disk, disk, record)
        layout = bv._gpt_partitions(source_disk, disk["logicalSize"])
        source_odm_size = read_super_odm(
            source_disk, super_offset, super_size, scratch / "odm_source.img"
        )
        need(
            source_odm_size == prepared_odm.stat().st_size
            and sha256(scratch / "odm_source.img") == sha256(prepared_odm),
            "the prepared odm_stock.img differs from odm_a in the pinned source bundle",
        )
        with source_disk.open("rb") as stream:
            source_vbmeta = bv._read_range(
                stream, layout[bv.VBMETA_LABEL][0], layout[bv.VBMETA_LABEL][1]
            )
        need(
            hashlib.sha256(source_vbmeta).hexdigest() == sha256(prepared_vbmeta),
            "the prepared vbmeta_src.img differs from vbmeta_a in the pinned source bundle",
        )

        source_footer = info(avbtool, scratch / "odm_source.img")
        source_fs_size = vr._original_size(source_footer, "the pinned source odm_a")
        source_tree = odm_tree(source_footer, "the pinned source odm_a")
        need(
            source_tree["imageSize"] == source_fs_size,
            "the pinned source odm descriptor does not cover its original image size",
        )
        source_fs = scratch / "odm_fs_source.img"
        vr._copy_prefix(scratch / "odm_source.img", source_fs, source_fs_size)
        need(
            source_fs.stat().st_size == prepared_fs.stat().st_size
            and sha256(source_fs) == sha256(prepared_fs),
            "the prepared odm_fs_stock.img differs from odm_a in the pinned source bundle",
        )

        source_tree_dir = scratch / "tree-source"
        ef.export_tree(tools, source_fs, source_tree_dir)
        source_entries = ef.read_tree(tools, source_fs, source_tree_dir)
        prepared_entries = ef.read_tree(tools, prepared_fs, prepared_tree)
        problems = vi.compare_entries(source_entries, prepared_entries, directory_sizes=True)
        need(not problems, f"the prepared tree-stock differs from source odm_a: {problems[:3]}")
        need(
            PRECOMPILED in source_entries and PRECOMPILED in prepared_entries,
            "the pinned source or prepared odm tree has no precompiled policy",
        )
        source_policy = source_tree_dir / PRECOMPILED.lstrip("/")
        prepared_policy = prepared_tree / PRECOMPILED.lstrip("/")
        need(
            sha256(source_policy) == sha256(prepared_policy),
            "the prepared tree-stock policy differs from the pinned source policy",
        )
        prepared_policy_copy = WORK / "precompiled.orig"
        if prepared_policy_copy.exists() or prepared_policy_copy.is_symlink():
            need(
                prepared_policy_copy.is_file()
                and not prepared_policy_copy.is_symlink()
                and sha256(prepared_policy_copy) == sha256(source_policy),
                "precompiled.orig differs from the pinned source policy",
            )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"prepared ODM, vbmeta, filesystem, and tree rechecked against source during {stage}")


def raw_to_sparse(os_img: Path, super_offset: int, super_size: int, out: Path) -> None:
    """Write the raw super region as an Android sparse image, with 4096-byte blocks.

    Zero blocks become DONT_CARE chunks. Runs of other blocks become RAW chunks of at most one
    CHUNK (64 MiB), so the memory use is bounded and no chunk size overflows its 32-bit field. The
    chunks are streamed to `out`, and the chunk count is written into the header last.
    `build_odm_bundle` checks that the expansion of the result is the manifest's super.
    """
    need(super_size % BLOCK == 0, "the super size is not a whole number of blocks")
    total_blocks = super_size // BLOCK
    raw_limit = CHUNK // BLOCK
    zero_block = bytes(BLOCK)
    chunk_count = 0
    with os_img.open("rb") as source, out.open("wb") as handle:
        handle.write(bytes(28))  # header, written again at the end
        source.seek(super_offset)

        def write_chunk(kind: int, blocks: int, data: bytes | None) -> None:
            nonlocal chunk_count
            payload = 0 if data is None else len(data)
            handle.write(kind.to_bytes(2, "little") + bytes(2) + blocks.to_bytes(4, "little")
                         + (12 + payload).to_bytes(4, "little"))
            if data is not None:
                handle.write(data)
            chunk_count += 1

        run_kind: int | None = None
        run_blocks = 0
        run_data: list[bytes] = []

        def flush() -> None:
            nonlocal run_kind, run_blocks, run_data
            if run_blocks:
                if run_kind == 0xCAC3:
                    write_chunk(0xCAC3, run_blocks, None)
                else:
                    write_chunk(0xCAC1, run_blocks, b"".join(run_data))
            run_kind, run_blocks, run_data = None, 0, []

        for _ in range(total_blocks):
            block = source.read(BLOCK)
            need(len(block) == BLOCK, "the super region is shorter than its size")
            kind = 0xCAC3 if block == zero_block else 0xCAC1
            if kind != run_kind or (kind == 0xCAC1 and run_blocks >= raw_limit):
                flush()
                run_kind = kind
            run_blocks += 1
            if kind == 0xCAC1:
                run_data.append(block)
        flush()
        handle.seek(0)
        handle.write((0xED26FF3A).to_bytes(4, "little") + (1).to_bytes(2, "little")
                     + (0).to_bytes(2, "little") + (28).to_bytes(2, "little")
                     + (12).to_bytes(2, "little") + BLOCK.to_bytes(4, "little")
                     + total_blocks.to_bytes(4, "little") + chunk_count.to_bytes(4, "little")
                     + (0).to_bytes(4, "little"))


def seal_odm(avbtool: Path, data_image: Path, output: Path, *, partition_size: int,
             stock: dict[str, Any], scratch: Path) -> dict[str, Any]:
    """Write the ODM partition with a new hashtree and an unsigned footer, and check it."""
    need(not output.exists(), f"{output} exists")
    fs_size = data_image.stat().st_size
    shutil.copyfile(data_image, output)
    vi.run_avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image", str(output),
            "--partition_size", str(partition_size),
            "--partition_name", VERITY,
            "--salt", stock["salt"],
            "--hash_algorithm", stock["hashAlgorithm"],
            "--block_size", str(stock["dataBlockSize"]),
            "--algorithm", "NONE",
            "--do_not_generate_fec",
        ],
    )
    verify_dir = scratch / "verify-odm"
    verify_dir.mkdir(exist_ok=True)
    link = verify_dir / f"{VERITY}.part"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(output)
    verified = vi.run_avbtool(avbtool, ["verify_image", "--image", str(link)])
    need(f"Successfully verified {stock['hashAlgorithm']} hashtree" in verified,
         "avbtool did not verify the new odm hashtree")
    need(output.stat().st_size == partition_size, "the sealed odm is not the partition size")
    tree = odm_tree(info(avbtool, output), "the sealed odm")
    return {"fsSize": fs_size, "tree": tree}


def descriptor_key(tree: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(tree[k] for k in vr.DESCRIPTOR_FIELDS)


def prepare(args: argparse.Namespace) -> None:
    need(not WORK.exists(), f"{WORK} must not exist (the stages are not repeated in place)")
    WORK.mkdir(parents=True)
    avbtool = avbtool_path()
    image_key = _load_signing_key(KEY)
    image_public_key = image_key.public_key().public_bytes(
        encoding=Encoding.Raw, format=PublicFormat.Raw
    )
    _manifest_bytes, manifest = verify_source_bundle(image_public_key)
    need(IMAGE_VERSION != manifest["imageVersion"],
         "the overlay control must have a distinct imageVersion")
    disk, record = bv._super_record(manifest)
    stock_disk = SRC / disk["path"]
    super_offset, super_size = bv._super_location(stock_disk, disk, record)
    layout = bv._gpt_partitions(stock_disk, disk["logicalSize"])
    vb_offset, vb_size = layout[bv.VBMETA_LABEL]
    with stock_disk.open("rb") as stream:
        vbmeta = bv._read_range(stream, vb_offset, vb_size)
    (WORK / "vbmeta_src.img").write_bytes(vbmeta)
    need(sha256(WORK / "vbmeta_src.img") == bv._disk_partition(manifest, bv.VBMETA_LABEL)["sha256"],
         "vbmeta_a of the source does not match the manifest")
    odm_size = read_super_odm(stock_disk, super_offset, super_size, WORK / "odm_stock.img")
    print(f"odm_a partition size {odm_size}")
    footer = info(avbtool, WORK / "odm_stock.img")
    fs_size = vr._original_size(footer, "the stock odm_a")
    stock = odm_tree(footer, "the stock odm_a")
    print(f"stock odm footer: algorithm {vr.parse_top(footer).get('Algorithm')} "
          f"fsSize {fs_size} root {stock['rootDigest']} salt {stock['salt']} "
          f"fec {stock.get('fecRoots')}")
    vb_info = info(avbtool, WORK / "vbmeta_src.img")
    vr.verify_vbmeta_signature(avbtool, WORK / "vbmeta_src.img")
    vb_top = vr.parse_top(vb_info)
    need(vb_top.get("Algorithm") == vr.VBMETA_ALGORITHM,
         "the source vbmeta_a is not signed with the pinned AVB algorithm")
    need(vb_top.get("Public key (sha1)", "").lower() == vr.VBMETA_PUBLIC_KEY_SHA1,
         "the source vbmeta_a is not signed with the pinned AOSP AVB test key")
    vb_odm = odm_tree(vb_info, "the source vbmeta_a")
    need(vb_odm["rootDigest"] == stock["rootDigest"], "stock odm footer and vbmeta_a disagree")
    need(descriptor_key(vb_odm) == descriptor_key(stock), "stock odm descriptor fields differ")
    print("stock odm footer and vbmeta_a descriptor agree")
    vr._copy_prefix(WORK / "odm_stock.img", WORK / "odm_fs_stock.img", fs_size)
    tools = ef.verify_tools(TOOLS, ef.load_component())
    ef.export_tree(tools, WORK / "odm_fs_stock.img", WORK / "tree-stock")
    entries = ef.read_tree(tools, WORK / "odm_fs_stock.img", WORK / "tree-stock")
    need(PRECOMPILED in entries, "the stock odm has no precompiled policy")
    stock_pc = WORK / "tree-stock" / PRECOMPILED.lstrip("/")
    print(f"stock precompiled sha256 {sha256(stock_pc)}")
    need(sha256(stock_pc).startswith(PART_PRECOMPILED_STOCK_SHA),
         "the odm_a precompiled policy is not the one the guest loaded at boot")
    print("odm_a precompiled policy is the file the guest loaded at boot (same sha256 prefix)")
    print("prepare: ok")


def policy_entries(text: str) -> dict[tuple[str, str, str, str], int]:
    """Map each avtab key of a `policy_edit dump` to its allow data (`specified` is part of the key)."""
    entries: dict[tuple[str, str, str, str], int] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 6 and parts[0] == "avtab":
            entries[(parts[1], parts[2], parts[3], parts[4])] = int(parts[5], 16)
    return entries


def policy_changes(before: Path, after: Path) -> dict[tuple[str, str, str, str], tuple[int, int]]:
    """Return every avtab key whose data differs between two policies, as (before, after)."""
    old = policy_entries(subprocess.run([str(EDITOR), "dump", str(before)], check=True,
                                        capture_output=True, text=True).stdout)
    new = policy_entries(subprocess.run([str(EDITOR), "dump", str(after)], check=True,
                                        capture_output=True, text=True).stdout)
    return {key: (old.get(key, 0), new.get(key, 0))
            for key in set(old) | set(new) if old.get(key, 0) != new.get(key, 0)}


def policy_permission_allowed(
    policy: Path, rule: tuple[str, str, str, str]
) -> bool:
    """Query one named permission in the compiled policy, preserving the policy editor result."""
    result = subprocess.run(
        [str(EDITOR), "query", str(policy), *rule],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise Check(
            f"policy_edit query failed for {rule}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.returncode == 0


def expected_policy_changes(before: Path, after: Path) -> None:
    """Check that the edit added exactly the bits of RULES: one key per (source, target, class)."""
    for rule in RULES:
        need(
            not policy_permission_allowed(before, rule),
            f"the stock policy already allows {rule}",
        )
        need(
            policy_permission_allowed(after, rule),
            f"the overlay does not allow {rule}",
        )
    keys: dict[tuple[str, str, str], int] = {}
    for src, tgt, cls, _perm in RULES:
        keys[(src, tgt, cls)] = keys.get((src, tgt, cls), 0) + 1
    changes = policy_changes(before, after)
    expected = {(src, tgt, cls, "0x0001") for src, tgt, cls in keys}
    need(set(changes) == expected,
         f"the policy edit changed other avtab keys than the rules: {sorted(set(changes) ^ expected)[:4]}")
    for (src, tgt, cls, _spec), (old, new) in changes.items():
        added = new & ~old
        need(new & old == old, f"{src} {tgt}:{cls} lost an allow bit")
        need(added.bit_count() == keys[(src, tgt, cls)],
             f"{src} {tgt}:{cls} gained {added.bit_count()} bits, expected {keys[(src, tgt, cls)]}")
    print(f"policy edit: {len(changes)} avtab keys changed, the bits are the {len(RULES)} rules")


def overlay_members() -> list[ef.TarMember]:
    """The new ODM entries: /bin and /etc/init, the test binary, and its init rc."""
    stamp = vi.BUILD_TIMESTAMP
    return [
        ef.TarMember(path="/bin", kind=ef.DIRECTORY, mode=0o755, uid=0, gid=0, mtime=stamp,
                     label=EGL_DIR_LABEL),
        ef.TarMember(path=EGL_BIN_PATH, kind=ef.REGULAR_FILE, mode=0o755, uid=0, gid=0,
                     mtime=stamp, label=EGL_BIN_LABEL, source=EGL_BINARY),
        ef.TarMember(path="/etc/init", kind=ef.DIRECTORY, mode=0o755, uid=0, gid=0, mtime=stamp,
                     label=ETC_INIT_DIR_LABEL),
        ef.TarMember(path=EGL_RC_PATH, kind=ef.REGULAR_FILE, mode=0o644, uid=0, gid=0,
                     mtime=stamp, label=EGL_RC_LABEL, source=EGL_DIR / "apkrun_egl_test.rc"),
    ]


def build_odm_bundle(
    *,
    stock_manifest_bytes: bytes,
    stock_manifest: dict[str, Any],
    variant_super: Path,
    odm_image: Path,
    vbmeta_image: Path,
    vbmeta_refresh: dict[str, Any],
    output: Path,
) -> dict[str, Any]:
    """Write a signed, test-only bundle with an ODM policy overlay and checked vbmeta."""
    key = _load_signing_key(KEY)
    public_key = key.public_key().public_bytes(encoding=Encoding.Raw, format=PublicFormat.Raw)
    image_key_id = key_id_of(public_key)
    disk, super_record = bv._super_record(stock_manifest)
    disk_path = str(disk["path"])
    stock_disk = SRC / disk_path
    super_offset, super_size = bv._super_location(stock_disk, disk, super_record)
    layout = bv._gpt_partitions(stock_disk, disk["logicalSize"])
    vbmeta_offset, vbmeta_size = layout[bv.VBMETA_LABEL]
    stock_disk_entry = next(item for item in stock_manifest["files"] if item["path"] == disk_path)
    stock_vbmeta_sha = bv._disk_partition(stock_manifest, bv.VBMETA_LABEL)["sha256"]
    with stock_disk.open("rb") as stream:
        stock_vbmeta = bv._read_range(stream, vbmeta_offset, vbmeta_size)
        source_values = bv._bootconfig_values(stream, layout, stock_vbmeta)
    need(hashlib.sha256(stock_vbmeta).hexdigest() == stock_vbmeta_sha,
         "source vbmeta_a differs from the checked source manifest")
    if bv._read_bootconfig_values(
        (SRC / stock_manifest["boot"]["bootconfig"]["path"]).read_text(encoding="utf-8"),
        tuple(source_values),
    ) != source_values:
        raise Check("source bootconfig does not carry the source vbmeta chain values")
    refreshed_vbmeta = vbmeta_image.read_bytes()
    need(len(refreshed_vbmeta) == vbmeta_size,
         "the refreshed vbmeta does not fill the stock vbmeta_a partition")

    work = output.parent
    work.mkdir(parents=True, exist_ok=True)
    expected_super_sha = super_record["sha256"]
    expanded = bv._expanded_sha256(variant_super, super_size, work / "super-verify.raw")
    need(expanded == expected_super_sha,
         "the variant super does not preserve the source super hash")
    result = bv.replace_partition(
        variant_super, PARTITION, odm_image, work / "super-variant.sparse"
    )
    need(result.partition_size == (WORK / "odm_stock.img").stat().st_size,
         "the variant replacement has a different logical partition size")
    need(odm_image.stat().st_size == (WORK / "odm_stock.img").stat().st_size,
         "the replacement ODM image has a different partition size")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.with_name(output.name + ".staging")
    need(not output.exists() and not staging.exists(),
         "the output bundle and its staging directory must be new")
    staging.mkdir()
    try:
        for entry in stock_manifest["files"]:
            target = staging / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if entry["path"] == disk_path:
                bv._splice(
                    stock_disk,
                    work / "super-variant.sparse",
                    target,
                    super_offset,
                    super_size,
                    expected_disk_sha256=stock_disk_entry["sha256"],
                    expected_super_sha256=expected_super_sha,
                )
                bv._write_range(target, vbmeta_offset, refreshed_vbmeta)
            else:
                shutil.copyfile(SRC / entry["path"], target)
                need(bv._file_entry(SRC, entry["path"]) == entry,
                     f"source file {entry['path']} changed after validation")

        variant_disk = staging / disk_path
        bv._verify_variant(
            stock_disk,
            variant_disk,
            super_offset,
            super_size,
            PARTITION,
            odm_image,
            extra=[(vbmeta_offset, refreshed_vbmeta)],
            expected_replacement_sha256=sha256(odm_image),
        )
        with variant_disk.open("rb") as stream:
            variant_super_sha = bv._hash_range(stream, super_offset, super_size)
            variant_vbmeta_sha = bv._hash_range(stream, vbmeta_offset, vbmeta_size)
            bootconfig_values = bv._bootconfig_values(stream, layout, refreshed_vbmeta)
        bootconfig_path = str(stock_manifest["boot"]["bootconfig"]["path"])
        bootconfig = staging / bootconfig_path
        bootconfig.write_text(
            bv._with_bootconfig_values(
                bv._read_text(bootconfig), bootconfig_values
            ),
            encoding="utf-8",
        )

        variant_manifest = json.loads(stock_manifest_bytes)
        source = variant_manifest["provenance"]["source"]
        base = (
            f"cf{source['buildId']}"
            if source["origin"] == "ci.android.com"
            else source["buildId"]
        )
        variant_manifest["imageVersion"] = f"{IMAGE_VERSION}-{base}-arm64"
        need(variant_manifest["imageVersion"] != stock_manifest["imageVersion"],
             "the overlay control imageVersion must differ from its source")
        bv._super_record(variant_manifest)[1]["sha256"] = variant_super_sha
        bv._disk_partition(variant_manifest, bv.VBMETA_LABEL)["sha256"] = variant_vbmeta_sha
        new_files = [bv._file_entry(staging, entry["path"])
                     for entry in stock_manifest["files"]]
        by_path = {entry["path"]: entry for entry in new_files}
        for name in bv.BOOT_FILES:
            variant_manifest["boot"][name] = by_path[variant_manifest["boot"][name]["path"]]
        variant_manifest["files"] = new_files
        violations = bv.validate(variant_manifest)
        need(not violations,
             f"the overlay bundle manifest fails {violations[0].rule}: {violations[0].reason}"
             if violations else "")
        new_manifest_bytes = (
            json.dumps(variant_manifest, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        (staging / bv.MANIFEST_NAME).write_bytes(new_manifest_bytes)
        (staging / bv.CHECKSUMS_NAME).write_text(bv._checksums(new_files), encoding="ascii")
        signature = render_signature(new_manifest_bytes, key)
        (staging / bv.SIGNATURE_NAME).write_bytes(signature)
        verify_signature(new_manifest_bytes, signature, {image_key_id: public_key})
        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    record = {
        "schemaVersion": 1,
        "task": "#099",
        "purpose": "test-only ODM SELinux policy overlay control",
        "source": {
            "bundle": str(SRC),
            "imageVersion": stock_manifest["imageVersion"],
            "manifestSHA256": hashlib.sha256(stock_manifest_bytes).hexdigest(),
            "diskSHA256": stock_disk_entry["sha256"],
            "superSHA256": expected_super_sha,
            "odmSHA256": sha256(WORK / "odm_stock.img"),
            "vbmetaSHA256": stock_vbmeta_sha,
        },
        "policy": {
            "profile": ACTIVE_PROFILE,
            "path": PRECOMPILED,
            "stockSHA256": sha256(WORK / "precompiled.orig"),
            "overlaySHA256": sha256(WORK / "precompiled.new"),
            "rules": [list(rule) for rule in RULES],
            "editorSHA256": sha256(EDITOR),
            "editorSourceSHA256": sha256(REPO / "Experiments" / "sepolicy-022" / "policy_edit.c"),
            "editorBuildScriptSHA256": sha256(
                REPO / "Experiments" / "sepolicy-022" / "build-libsepol.sh"
            ),
            "libsepolReleaseSHA256": "79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d",
            "libsepolSourceTreeSHA256": tree_sha256(LIBSEPOL_ROOT),
            "libsepolStaticArchiveSHA256": sha256(LIBSEPOL_ROOT / "src" / "libsepol.a"),
            "clangVersion": subprocess.run(
                ["clang", "--version"], check=True, capture_output=True, text=True
            ).stdout.splitlines()[0],
        },
        "partition": {
            "name": PARTITION,
            "sha256": sha256(odm_image),
            "avbTree": odm_tree(info(avbtool_path(), odm_image), "the overlay odm_a"),
        },
        "vbmeta": {
            "sha256": sha256(vbmeta_image),
            "stockSHA256": stock_vbmeta_sha,
            "algorithm": vr.VBMETA_ALGORITHM,
            "signer": vr.VBMETA_SIGNER,
            "publicKeySha1": vr.VBMETA_PUBLIC_KEY_SHA1,
            "refresh": vbmeta_refresh,
        },
        "tools": {
            "builderSHA256": sha256(Path(__file__)),
            "avbtoolSHA256": sha256(avbtool_path()),
            "erofsVersion": ef.load_component()["version"],
            "erofsBinaries": {
                name: sha256(TOOLS / "bin" / name)
                for name in ("mkfs.erofs", "fsck.erofs", "dump.erofs")
            },
            "eglTestBinarySHA256": sha256(EGL_BINARY),
            "eglTestInitSHA256": sha256(EGL_DIR / "apkrun_egl_test.rc"),
        },
        "output": {
            "bundle": str(output),
            "imageVersion": variant_manifest["imageVersion"],
            "manifestSHA256": hashlib.sha256(new_manifest_bytes).hexdigest(),
            "manifestSignatureSHA256": sha256(output / bv.SIGNATURE_NAME),
            "checksumsSHA256": sha256(output / bv.CHECKSUMS_NAME),
            "diskSHA256": sha256(output / disk_path),
            "imageSigningKeyID": image_key_id,
        },
    }
    OUTPUT_RECEIPT.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    print(f"bundle written: {output}")
    print(f"bundle manifest sha256 {record['output']['manifestSHA256']}")
    print(f"bundle disk sha256 {record['output']['diskSHA256']}")
    print(f"control receipt sha256 {sha256(OUTPUT_RECEIPT)}")
    return record


def build(args: argparse.Namespace) -> None:
    avbtool = avbtool_path()
    key = _load_signing_key(KEY)
    public_key = key.public_key().public_bytes(encoding=Encoding.Raw, format=PublicFormat.Raw)
    manifest_bytes, manifest = verify_source_bundle(public_key)
    disk, record = bv._super_record(manifest)
    stock_disk = SRC / disk["path"]
    super_offset, super_size = bv._super_location(stock_disk, disk, record)
    tools = ef.verify_tools(TOOLS, ef.load_component())
    verify_prepared_baseline(avbtool, manifest, tools, "build")
    footer = info(avbtool, WORK / "odm_stock.img")
    stock = odm_tree(footer, "the stock odm_a")
    need(
        stock["imageSize"] == vr._original_size(footer, "the stock odm_a"),
        "the stock ODM descriptor does not cover the original image size",
    )
    partition_size = (WORK / "odm_stock.img").stat().st_size
    entries = ef.read_tree(tools, WORK / "odm_fs_stock.img", WORK / "tree-stock")
    tree_stock = WORK / "tree-stock"

    # 1. Edit the precompiled policy with one `add` per rule of RULES (the stock file is the base).
    shutil.copyfile(tree_stock / PRECOMPILED.lstrip("/"), WORK / "precompiled.orig")
    current = "precompiled.orig"
    for index, (src, tgt, cls, perm) in enumerate(RULES):
        target = f"precompiled.step{index}"
        subprocess.run([str(EDITOR), "add", str(WORK / current), str(WORK / target),
                        src, tgt, cls, perm], check=True, capture_output=True)
        current = target
    shutil.copyfile(WORK / current, WORK / "precompiled.new")
    expected_policy_changes(WORK / "precompiled.orig", WORK / "precompiled.new")
    print(f"edited precompiled sha256 {sha256(WORK / 'precompiled.new')}")

    # 2. Rebuild the erofs image with the vendor pipeline; the stock round trip must reproduce it.
    base = ef.tree_members(entries, tree_stock, vi.BUILD_TIMESTAMP)
    round_trip = vi._rebuild(tools, base, WORK, "round-trip", UUID)
    ef.export_tree(tools, round_trip, WORK / "tree-round")
    problems = vi.compare_entries(entries, ef.read_tree(tools, round_trip, WORK / "tree-round"),
                                  directory_sizes=True)
    need(not problems, f"the round trip changed the stock odm: {problems[:3]}")
    print("round trip of the stock odm reproduces its entries")
    shutil.rmtree(WORK / "tree-round")
    round_trip.unlink()

    members = []
    for member in base:
        if member.path == PRECOMPILED:
            member = dataclasses.replace(member, source=WORK / "precompiled.new")
        members.append(member)
    overlay = overlay_members()
    members = sorted(members + overlay, key=lambda member: member.path)
    odm_fs = vi._rebuild(tools, members, WORK, "odm", UUID)
    ef.export_tree(tools, odm_fs, WORK / "tree-new")
    entries_new = ef.read_tree(tools, odm_fs, WORK / "tree-new")
    problems = vi.compare_entries(entries, entries_new, added=[m.path for m in overlay])
    expected = {f"{PRECOMPILED}: sha256 differs", f"{PRECOMPILED}: size differs"}
    need(set(problems) == expected,
         f"the rebuild differs from the stock other than the policy and the overlay: {problems[:4]}")
    need(entries_new[PRECOMPILED].sha256 == sha256(WORK / "precompiled.new"),
         "the rebuilt policy is not the edited one")
    for member in overlay:
        got = entries_new[member.path]
        need(got.label == member.label and got.mode == member.mode and got.uid == 0 and got.gid == 0,
             f"{member.path}: label, mode, or owner is not the one set")
        if member.source is not None:
            need(got.sha256 == sha256(member.source), f"{member.path}: content differs from the source")
    print(f"rebuild added {[m.path for m in overlay]} and changed only {PRECOMPILED} (sha256 and size)")
    shutil.rmtree(WORK / "tree-new")

    _, fs_blocks, _ = ef.image_geometry(tools, odm_fs)
    need(odm_fs.stat().st_size == fs_blocks * BLOCK, "the rebuilt erofs has trailing bytes")
    shutil.copyfile(odm_fs, WORK / "odm_new_data.img")
    sealed = seal_odm(avbtool, WORK / "odm_new_data.img", WORK / "odm_new.img",
                      partition_size=partition_size, stock=stock, scratch=WORK)
    new_tree = sealed["tree"]
    print(f"new odm: fsSize {sealed['fsSize']} root {new_tree['rootDigest']}")

    # 3. Refresh only the ODM descriptor and sign vbmeta_a with the pinned AOSP test key.
    vbmeta_refresh = vr.refresh_vbmeta_partition(
        avbtool=avbtool,
        stock_vbmeta=WORK / "vbmeta_src.img",
        partition_image=WORK / "odm_new.img",
        partition_name=VERITY,
        signing_key=AVB_KEY,
        output=WORK / "vbmeta_new.img",
        scratch=WORK,
    )
    new_info = info(avbtool, WORK / "vbmeta_new.img")
    need(descriptor_key(odm_tree(new_info, "the refreshed vbmeta")) == descriptor_key(new_tree),
         "the signed vbmeta odm descriptor is not the new odm footer")
    print(
        f"signed vbmeta: rollback {vbmeta_refresh['rollbackIndex']} "
        f"odm root {new_tree['rootDigest']}"
    )

    # 4. Replace odm_a and vbmeta_a in the exact source bundle, then re-sign its manifest.
    raw_to_sparse(stock_disk, super_offset, super_size, WORK / "super-src.sparse")
    build_odm_bundle(
        stock_manifest_bytes=manifest_bytes,
        stock_manifest=manifest,
        variant_super=WORK / "super-src.sparse",
        odm_image=WORK / "odm_new.img",
        vbmeta_image=WORK / "vbmeta_new.img",
        vbmeta_refresh=vbmeta_refresh,
        output=OUTPUT_BUNDLE,
    )
    print("build: ok")


def vi_descriptor_blocks(text: str) -> list[tuple[str, tuple[str, ...]]]:
    return vr.descriptor_blocks(text)


def is_odm(block: tuple[str, tuple[str, ...]]) -> bool:
    header, body = block
    if header != "Hashtree descriptor:":
        return False
    names = [line.partition(":")[2].strip() for line in body if line.startswith("Partition Name:")]
    return names == [VERITY]


def check(args: argparse.Namespace) -> None:
    avbtool = avbtool_path()
    out = OUTPUT_BUNDLE
    source_key = _load_signing_key(KEY)
    public_key = source_key.public_key().public_bytes(
        encoding=Encoding.Raw, format=PublicFormat.Raw
    )
    manifest_bytes, manifest = bv._verify_stock(out, public_key)
    source_manifest_bytes, source_manifest = verify_source_bundle(public_key)
    receipt = json.loads(OUTPUT_RECEIPT.read_text(encoding="utf-8"))
    need(receipt["task"] == "#099" and
         receipt["purpose"] == "test-only ODM SELinux policy overlay control",
         "the control receipt has another purpose")
    need(receipt["source"]["manifestSHA256"] == hashlib.sha256(source_manifest_bytes).hexdigest(),
         "the receipt names a different source manifest")
    need(receipt["output"]["manifestSHA256"] == hashlib.sha256(manifest_bytes).hexdigest(),
         "the receipt names a different output manifest")
    need(receipt["tools"]["builderSHA256"] == sha256(Path(__file__)),
         "the builder source changed after the receipt was written")
    need(receipt["policy"]["rules"] == [list(rule) for rule in RULES],
         "the receipt policy rules differ from this experiment")
    need(receipt["policy"]["profile"] == ACTIVE_PROFILE,
         "the receipt names another policy profile")
    disk, record = bv._super_record(manifest)
    need(receipt["output"]["diskSHA256"] == sha256(out / disk["path"]),
         "the receipt names a different output disk")
    os_img = out / disk["path"]
    super_offset, super_size = bv._super_location(os_img, disk, record)
    layout = bv._gpt_partitions(os_img, disk["logicalSize"])
    vb_offset, vb_size = layout[bv.VBMETA_LABEL]
    with os_img.open("rb") as stream:
        vbmeta = bv._read_range(stream, vb_offset, vb_size)
        expected_bootconfig_values = bv._bootconfig_values(stream, layout, vbmeta)
    bootconfig_path = out / manifest["boot"]["bootconfig"]["path"]
    bootconfig_values = bv._read_bootconfig_values(
        bv._read_text(bootconfig_path), tuple(expected_bootconfig_values)
    )
    need(
        bootconfig_values == expected_bootconfig_values,
        "the output bootconfig does not match the final vbmeta chain",
    )
    (WORK / "check").mkdir(exist_ok=True)
    (WORK / "check" / "vbmeta_a.img").write_bytes(vbmeta)
    vb_info = info(avbtool, WORK / "check" / "vbmeta_a.img")
    vr.verify_vbmeta_signature(avbtool, WORK / "check" / "vbmeta_a.img")
    vb_top = vr.parse_top(vb_info)
    need(vb_top.get("Algorithm") == vr.VBMETA_ALGORITHM,
         "the output vbmeta_a is not signed with the pinned AVB algorithm")
    need(vb_top.get("Public key (sha1)", "").lower() == vr.VBMETA_PUBLIC_KEY_SHA1,
         "the output vbmeta_a is not signed with the pinned AOSP AVB test key")
    source_disk, source_super_record = bv._super_record(source_manifest)
    source_disk_path = SRC / source_disk["path"]
    source_disk_entry = next(
        item for item in source_manifest["files"] if item["path"] == source_disk["path"]
    )
    need(receipt["source"]["diskSHA256"] == source_disk_entry["sha256"],
         "the receipt names another source disk")
    need(receipt["source"]["superSHA256"] == source_super_record["sha256"],
         "the receipt names another source super")
    need(receipt["source"]["odmSHA256"] == sha256(WORK / "odm_stock.img"),
         "the source ODM image changed after the receipt was written")
    need(receipt["policy"]["stockSHA256"] == sha256(WORK / "precompiled.orig"),
         "the source precompiled policy changed after the receipt was written")
    need(receipt["policy"]["overlaySHA256"] == sha256(WORK / "precompiled.new"),
         "the edited precompiled policy changed after the receipt was written")
    need(receipt["policy"]["editorSourceSHA256"] == sha256(
             REPO / "Experiments" / "sepolicy-022" / "policy_edit.c"
         ), "the policy editor source changed after the receipt was written")
    need(receipt["policy"]["editorBuildScriptSHA256"] == sha256(
             REPO / "Experiments" / "sepolicy-022" / "build-libsepol.sh"
         ), "the policy editor build script changed after the receipt was written")
    need(receipt["policy"]["libsepolSourceTreeSHA256"] == tree_sha256(LIBSEPOL_ROOT),
         "the libsepol build source changed after the receipt was written")
    need(receipt["policy"]["libsepolStaticArchiveSHA256"] == sha256(
             LIBSEPOL_ROOT / "src" / "libsepol.a"
         ), "the libsepol static archive changed after the receipt was written")
    source_layout = bv._gpt_partitions(source_disk_path, source_disk["logicalSize"])
    with source_disk_path.open("rb") as stream:
        source_vbmeta = WORK / "check" / "vbmeta_source.img"
        source_vbmeta.write_bytes(
            bv._read_range(stream, source_layout[bv.VBMETA_LABEL][0],
                           source_layout[bv.VBMETA_LABEL][1])
        )
    need(receipt["source"]["vbmetaSHA256"] == sha256(source_vbmeta),
         "the receipt names another source vbmeta_a")
    vr.verify_vbmeta_signature(avbtool, source_vbmeta)
    source_header, source_descriptors, _, _ = bv._raw_vbmeta_descriptors(source_vbmeta)
    output_header, output_descriptors, _, _ = bv._raw_vbmeta_descriptors(
        WORK / "check" / "vbmeta_a.img"
    )
    need(output_header == source_header, "the overlay changed top-level vbmeta header fields")
    old_odm = [item for tag, name, item in source_descriptors if tag == 1 and name == VERITY]
    new_odm = [item for tag, name, item in output_descriptors if tag == 1 and name == VERITY]
    need(len(old_odm) == len(new_odm) == 1,
         "source and output vbmeta must each have exactly one odm descriptor")
    need([item for item in source_descriptors if not (item[0] == 1 and item[1] == VERITY)] ==
         [item for item in output_descriptors if not (item[0] == 1 and item[1] == VERITY)],
         "the refreshed vbmeta changed a descriptor other than odm")
    vb_odm = odm_tree(vb_info, "the variant vbmeta_a")
    vb_vendor = vr.parse_hashtrees(vb_info).get("vendor")
    odm_size = read_super_odm(os_img, super_offset, super_size, WORK / "check" / "odm_final.img")
    need(
        odm_size == (WORK / "odm_stock.img").stat().st_size,
        "the extracted ODM partition size differs from the bundle super metadata",
    )
    odm_info = info(avbtool, WORK / "check" / "odm_final.img")
    odm_footer = odm_tree(odm_info, "the odm_a of the variant")
    print(f"vbmeta_a odm rootDigest      {vb_odm['rootDigest']}")
    print(f"odm_a footer rootDigest      {odm_footer['rootDigest']}")
    need(vb_odm["rootDigest"] == odm_footer["rootDigest"],
         "the ODM root digest in vbmeta does not match the ODM image")
    need(descriptor_key(vb_odm) == descriptor_key(odm_footer),
         "the odm descriptor fields in vbmeta do not match the ODM footer")
    final_odm_descriptors = [
        item for tag, name, item in bv._raw_vbmeta_descriptors(
            WORK / "check" / "odm_final.img"
        )[1] if tag == 1 and name == VERITY
    ]
    need(new_odm == final_odm_descriptors,
         "the output vbmeta does not carry the exact ODM descriptor")
    need(receipt["partition"]["sha256"] == sha256(WORK / "check" / "odm_final.img"),
         "the receipt names another ODM image")
    need(receipt["vbmeta"]["sha256"] == sha256(WORK / "check" / "vbmeta_a.img"),
         "the receipt names another vbmeta image")
    print("ODM root digest in vbmeta matches the repacked ODM image")
    link_dir = WORK / "check" / "verify"
    link_dir.mkdir(exist_ok=True)
    link = link_dir / f"{VERITY}.part"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(WORK / "check" / "odm_final.img")
    verified = vi.run_avbtool(avbtool, ["verify_image", "--image", str(link)])
    need("Successfully verified sha256 hashtree" in verified, "the final odm hashtree did not verify")
    print("avbtool verify_image: odm hashtree verified")
    need(vb_vendor is not None, "the variant vbmeta_a has no vendor descriptor")
    vendor_bytes = read_super_partition(os_img, super_offset, super_size, "vendor_a",
                                        WORK / "check" / "vendor_final.img")
    vendor_info = info(avbtool, WORK / "check" / "vendor_final.img")
    vendor_footer = vr.parse_hashtrees(vendor_info).get("vendor")
    need(vendor_footer is not None and vendor_footer["rootDigest"] == vb_vendor["rootDigest"],
         "the vendor descriptor in vbmeta does not match the vendor image")
    print(f"vendor_a footer matches the vendor descriptor in vbmeta ({vendor_bytes} bytes)")
    tools = ef.verify_tools(TOOLS, ef.load_component())
    verify_prepared_baseline(avbtool, source_manifest, tools, "check")
    fs_size = vr._original_size(odm_info, "the variant odm_a")
    vr._copy_prefix(WORK / "check" / "odm_final.img", WORK / "check" / "odm_final_fs.img", fs_size)
    ef.extract_file(tools, WORK / "check" / "odm_final_fs.img", PRECOMPILED,
                    WORK / "check" / "precompiled_final")
    got = sha256(WORK / "check" / "precompiled_final")
    print(f"precompiled in the variant odm sha256 {got}")
    need(receipt["policy"]["overlaySHA256"] == got,
         "the receipt names another policy overlay")
    expected_policy_changes(WORK / "tree-stock" / PRECOMPILED.lstrip("/"), WORK / "check" / "precompiled_final")
    for member in overlay_members():
        if member.source is not None:
            destination = WORK / "check" / "overlay" / member.path.lstrip("/")
            destination.parent.mkdir(parents=True, exist_ok=True)
            ef.extract_file(tools, WORK / "check" / "odm_final_fs.img", member.path, destination)
    need(sha256(WORK / "check" / "overlay" / EGL_BIN_PATH.lstrip("/")) == sha256(EGL_BINARY),
         "the binary in the variant odm is not the built one")
    need(sha256(WORK / "check" / "overlay" / EGL_RC_PATH.lstrip("/")) == sha256(EGL_DIR / "apkrun_egl_test.rc"),
         "the rc in the variant odm is not the committed one")
    print("odm overlay: the test binary and the rc are in the variant odm")
    need(_checksums(manifest["files"]) == (out / "SHA256SUMS").read_text(encoding="ascii"),
         "the SHA256SUMS does not match the manifest")
    need(receipt["output"]["manifestSignatureSHA256"] == sha256(out / bv.SIGNATURE_NAME),
         "the receipt names a different manifest signature")
    need(receipt["output"]["checksumsSHA256"] == sha256(out / bv.CHECKSUMS_NAME),
         "the receipt names a different checksum file")
    need(receipt["output"]["imageVersion"] == manifest["imageVersion"],
         "the receipt names another output imageVersion")
    need(receipt["output"]["imageSigningKeyID"] == key_id_of(public_key),
         "the receipt names another image signing key")
    need(receipt["policy"]["editorSHA256"] == sha256(EDITOR),
         "the policy editor changed after the receipt was written")
    need(receipt["tools"]["avbtoolSHA256"] == sha256(avbtool),
         "the AVB tool changed after the receipt was written")
    need(receipt["tools"]["eglTestBinarySHA256"] == sha256(EGL_BINARY),
         "the EGL diagnostic binary changed after the receipt was written")
    need(receipt["tools"]["eglTestInitSHA256"] == sha256(
             EGL_DIR / "apkrun_egl_test.rc"
         ), "the EGL diagnostic init file changed after the receipt was written")
    for name, digest in receipt["tools"]["erofsBinaries"].items():
        need(digest == sha256(TOOLS / "bin" / name),
             f"the pinned EROFS tool {name} changed after the receipt was written")
    print("manifest.sig verified")
    print("check: ok")


def read_super_partition(os_img: Path, super_offset: int, super_size: int, name: str,
                         out: Path) -> int:
    window = Window(os_img, super_offset, super_size)
    try:
        metadata = lp.read_dynamic_partitions(window, sparse=False)
        found = {item.name: item for item in metadata.logical_partitions}[name]
        with out.open("wb") as handle:
            offset = 0
            while offset < found.size:
                length = min(CHUNK, found.size - offset)
                handle.write(lp.read_partition_range(window, found, offset, length, sparse=False))
                offset += length
        return found.size
    finally:
        window.close()


def main(argv: list[str]) -> int:
    global ACTIVE_PROFILE, RULES
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("stage", choices=("prepare", "build", "check"))
    parser.add_argument("--profile", choices=tuple(RULE_PROFILES), default="full-control")
    args = parser.parse_args(argv)
    ACTIVE_PROFILE = args.profile
    RULES = RULE_PROFILES[ACTIVE_PROFILE]
    {"prepare": prepare, "build": build, "check": check}[args.stage](args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
