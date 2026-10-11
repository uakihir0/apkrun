"""Boot-time ODM variant for the #022 sepolicy experiment (test only, never a product image).

The variant is the #099 variant bundle (`install-src`, vendor replaced and resealed) with one more
change: the ODM logical partition `odm_a` holds a copy of `/etc/selinux/precompiled_sepolicy` that
has the same single allow rule as the runtime test (`allow surfaceflinger sysfs:file { open read }`).
The top-level `vbmeta_a` carries the new `odm` hashtree descriptor. The bundle is made by the bundle
tool's `build_variant`, which needs a sparse super and a reseal record.

Stages (each one is checked, and the script stops at the first failed check):

  prepare   read `odm_a` and `vbmeta_a`, check the stock odm footer and descriptor, export the tree
  build     edit the precompiled policy, rebuild and seal `odm_a`, update the vbmeta descriptor,
            write the sparse super, and call `build_variant`
  check     read the variant bundle back: the ODM root digest in its vbmeta against the repacked
            ODM image, the hashtree of that image, the edited policy inside it, and the vendor

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

from apkrun_image import bundle_variant as bv  # noqa: E402
from apkrun_image import erofs as ef  # noqa: E402
from apkrun_image import lp  # noqa: E402
from apkrun_image import vendor_inject as vi  # noqa: E402
from apkrun_image import vendor_reseal as vr  # noqa: E402

SRC = Path("/tmp/apkrun-099-vh-install-src/android-bundle")
WORK = Path("/tmp/apkrun-022-odm")
TOOLS = Path("/tmp/apkrun-099-lp-erofs/tools")
EDITOR = Path("/tmp/apkrun-022-sepol-bin/policy-edit")
KEY = Path("~/.config/apkrun/dev-image-key").expanduser()
PARTITION = "odm_a"
VERITY = "odm"
PRECOMPILED = "/etc/selinux/precompiled_sepolicy"
UUID = "0220220a-0220-4220-8220-022022022022"
CHUNK = 64 * 1024 * 1024
BLOCK = 4096
PART_PRECOMPILED_STOCK_SHA = "6a1f95dad28bdf50"  # prefix of the file the guest loaded at boot
PART_PRECOMPILED_EDIT_SHA = "cbcad7113c3acf70"  # prefix of the boot policy plus open and read


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


class Window:
    """A read-only stream over `size` bytes of `path` that start at `base`."""

    def __init__(self, path: Path, base: int, size: int) -> None:
        self._file = path.open("rb")
        self._base = base
        self._size = size
        self._pos = 0

    def read(self, count: int = -1) -> bytes:
        remaining = self._size - self._pos
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


def raw_to_sparse(os_img: Path, super_offset: int, super_size: int, out: Path) -> None:
    """Write the raw super region as an Android sparse image (4096-byte blocks, zero blocks skipped).

    The chunks are streamed to `out`, so the data is never held in memory. The header's chunk count
    is written last. `build_variant` checks the expansion of the result against the manifest.
    """
    need(super_size % BLOCK == 0, "the super size is not a whole number of blocks")
    total_blocks = super_size // BLOCK
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
            if run_kind is None:
                return
            if run_kind == 0xCAC3:
                write_chunk(0xCAC3, run_blocks, None)
            else:
                write_chunk(0xCAC1, run_blocks, b"".join(run_data))
            run_kind, run_blocks, run_data = None, 0, []

        for _ in range(total_blocks):
            block = source.read(BLOCK)
            need(len(block) == BLOCK, "the super region is shorter than its size")
            kind = 0xCAC3 if block == zero_block else 0xCAC1
            if kind != run_kind:
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
    return tuple(tree.get(k) for k in vr.DESCRIPTOR_FIELDS)


def prepare(args: argparse.Namespace) -> None:
    need(not WORK.exists(), f"{WORK} must not exist (the stages are not repeated in place)")
    WORK.mkdir(parents=True)
    avbtool = avbtool_path()
    manifest = json.loads((SRC / "manifest.json").read_text())
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


def build(args: argparse.Namespace) -> None:
    avbtool = avbtool_path()
    manifest = json.loads((SRC / "manifest.json").read_text())
    disk, record = bv._super_record(manifest)
    stock_disk = SRC / disk["path"]
    super_offset, super_size = bv._super_location(stock_disk, disk, record)
    tools = ef.verify_tools(TOOLS, ef.load_component())
    footer = info(avbtool, WORK / "odm_stock.img")
    fs_size = vr._original_size(footer, "the stock odm_a")
    stock = odm_tree(footer, "the stock odm_a")
    partition_size = (WORK / "odm_stock.img").stat().st_size
    entries = ef.read_tree(tools, WORK / "odm_fs_stock.img", WORK / "tree-stock")
    tree_stock = WORK / "tree-stock"

    # 1. Edit the precompiled policy with the same two allow calls as the runtime test.
    shutil.copyfile(tree_stock / PRECOMPILED.lstrip("/"), WORK / "precompiled.orig")
    for step, src, dst in (("open", "precompiled.orig", "precompiled.step1"),
                           ("read", "precompiled.step1", "precompiled.new")):
        subprocess.run([str(EDITOR), "add", str(WORK / src), str(WORK / dst),
                        "surfaceflinger", "sysfs", "file", step], check=True, capture_output=True)
    need(sha256(WORK / "precompiled.new").startswith(PART_PRECOMPILED_EDIT_SHA),
         "the edited precompiled policy is not the boot policy plus open and read")
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
    odm_fs = vi._rebuild(tools, members, WORK, "odm", UUID)
    ef.export_tree(tools, odm_fs, WORK / "tree-new")
    entries_new = ef.read_tree(tools, odm_fs, WORK / "tree-new")
    problems = vi.compare_entries(entries, entries_new, directory_sizes=True)
    other = [p for p in problems if PRECOMPILED not in p]
    need(not other, f"the rebuild changed more than the policy: {other[:3]}")
    need(entries_new[PRECOMPILED].sha256 == sha256(WORK / "precompiled.new"),
         "the rebuilt policy is not the edited one")
    print(f"rebuild changed only {PRECOMPILED} ({len(problems)} entry differences on it)")
    shutil.rmtree(WORK / "tree-new")

    _, fs_blocks, _ = ef.image_geometry(tools, odm_fs)
    need(odm_fs.stat().st_size == fs_blocks * BLOCK, "the rebuilt erofs has trailing bytes")
    shutil.copyfile(odm_fs, WORK / "odm_new_data.img")
    sealed = seal_odm(avbtool, WORK / "odm_new_data.img", WORK / "odm_new.img",
                      partition_size=partition_size, stock=stock, scratch=WORK)
    new_tree = sealed["tree"]
    print(f"new odm: fsSize {sealed['fsSize']} root {new_tree['rootDigest']}")

    # 3. The vbmeta: the stock chain plus the new odm descriptor, unsigned (IR-744).
    vb_info = info(avbtool, WORK / "vbmeta_src.img")
    rollback = vr.parse_top(vb_info).get("Rollback Index")
    need(rollback is not None, "the source vbmeta has no rollback index")
    rollback_value = rollback.split()[0]
    vi.run_avbtool(avbtool, [
        "update_partition_descriptor",
        "--image", str(WORK / "vbmeta_src.img"),
        "--partition_image", str(WORK / "odm_new.img"),
        "--output", str(WORK / "vbmeta-raw.bin"),
        "--algorithm", "NONE",
        "--rollback_index", rollback_value,
    ])
    raw = (WORK / "vbmeta-raw.bin").read_bytes()
    vb_size = (WORK / "vbmeta_src.img").stat().st_size
    need(len(raw) <= vb_size, "the refreshed vbmeta is larger than the partition")
    (WORK / "vbmeta_new.img").write_bytes(raw + bytes(vb_size - len(raw)))
    new_info = info(avbtool, WORK / "vbmeta_new.img")
    need(vr.parse_top(new_info).get("Algorithm") == "NONE", "the refreshed vbmeta is not NONE")
    for key in ("Rollback Index", "Rollback Index Location", "Flags", "Minimum libavb version"):
        need(vr.parse_top(new_info).get(key) == vr.parse_top(vb_info).get(key),
             f"the refreshed vbmeta changed its {key}")
    need(descriptor_key(odm_tree(new_info, "the refreshed vbmeta")) == descriptor_key(new_tree),
         "the vbmeta odm descriptor is not the new odm footer")
    old_others = [b for b in vi_descriptor_blocks(vb_info) if not is_odm(b)]
    new_others = [b for b in vi_descriptor_blocks(new_info) if not is_odm(b)]
    need(old_others == new_others, "the refreshed vbmeta changed a descriptor other than odm")
    print(f"new vbmeta: rollback {rollback_value}, odm root {new_tree['rootDigest']}")

    # 4. The sparse super of the source (its expansion must be the manifest's super), then the bundle.
    raw_to_sparse(stock_disk, super_offset, super_size, WORK / "super-src.sparse")
    rec = {
        "schemaVersion": 1,
        "task": "#022",
        "stock": {"vbmetaSha256": bv._disk_partition(manifest, bv.VBMETA_LABEL)["sha256"]},
        "vbmeta": {"rollbackIndex": int(rollback_value)},
        "odm": {"rootDigest": new_tree["rootDigest"]},
    }
    rec_path = WORK / "odm-reseal.json"
    rec_path.write_text(json.dumps(rec, indent=2, sort_keys=True) + "\n")
    out = WORK / "bundle" / "android-bundle"
    (WORK / "bundle").mkdir()
    refresh = bv._Refresh(vendor=WORK / "odm_new.img", vbmeta=WORK / "vbmeta_new.img",
                          record=rec, record_path=rec_path)
    result = bv.build_variant(
        stock_bundle=SRC,
        stock_super=WORK / "super-src.sparse",
        partition=PARTITION,
        replacement=WORK / "odm_new.img",
        output=out,
        sign_key=KEY,
        refresh=refresh,
    )
    print(f"bundle written: {out}")
    print(f"variant manifest sha256 {result['variantManifestSHA256']}")
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
    out = WORK / "bundle" / "android-bundle"
    manifest = json.loads((out / "manifest.json").read_text())
    disk, record = bv._super_record(manifest)
    os_img = out / disk["path"]
    super_offset, super_size = bv._super_location(os_img, disk, record)
    layout = bv._gpt_partitions(os_img, disk["logicalSize"])
    vb_offset, vb_size = layout[bv.VBMETA_LABEL]
    with os_img.open("rb") as stream:
        vbmeta = bv._read_range(stream, vb_offset, vb_size)
    (WORK / "check").mkdir(exist_ok=True)
    (WORK / "check" / "vbmeta_a.img").write_bytes(vbmeta)
    vb_info = info(avbtool, WORK / "check" / "vbmeta_a.img")
    vb_odm = odm_tree(vb_info, "the variant vbmeta_a")
    vb_vendor = vr.parse_hashtrees(vb_info).get("vendor")
    size = read_super_odm(os_img, super_offset, super_size, WORK / "check" / "odm_final.img")
    odm_info = info(avbtool, WORK / "check" / "odm_final.img")
    odm_footer = odm_tree(odm_info, "the odm_a of the variant")
    print(f"vbmeta_a odm rootDigest      {vb_odm['rootDigest']}")
    print(f"odm_a footer rootDigest      {odm_footer['rootDigest']}")
    need(vb_odm["rootDigest"] == odm_footer["rootDigest"],
         "the ODM root digest in vbmeta does not match the ODM image")
    need(descriptor_key(vb_odm) == descriptor_key(odm_footer),
         "the odm descriptor fields in vbmeta do not match the ODM footer")
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
    if vb_vendor is not None:
        vendor_bytes = read_super_partition(os_img, super_offset, super_size, "vendor_a",
                                            WORK / "check" / "vendor_final.img")
        vendor_info = info(avbtool, WORK / "check" / "vendor_final.img")
        vendor_footer = vr.parse_hashtrees(vendor_info).get("vendor")
        need(vendor_footer is not None and vendor_footer["rootDigest"] == vb_vendor["rootDigest"],
             "the vendor descriptor in vbmeta does not match the vendor image")
        print(f"vendor_a footer matches the vendor descriptor in vbmeta ({vendor_bytes} bytes)")
    tools = ef.verify_tools(TOOLS, ef.load_component())
    fs_size = vr._original_size(odm_info, "the variant odm_a")
    vr._copy_prefix(WORK / "check" / "odm_final.img", WORK / "check" / "odm_final_fs.img", fs_size)
    ef.extract_file(tools, WORK / "check" / "odm_final_fs.img", PRECOMPILED,
                    WORK / "check" / "precompiled_final")
    got = sha256(WORK / "check" / "precompiled_final")
    print(f"precompiled in the variant odm sha256 {got}")
    need(got.startswith(PART_PRECOMPILED_EDIT_SHA), "the variant odm does not carry the edited policy")
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
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("stage", choices=("prepare", "build", "check"))
    args = parser.parse_args(argv)
    {"prepare": prepare, "build": build, "check": check}[args.stage](args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
