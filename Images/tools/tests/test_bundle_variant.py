"""Tests for `bundle-variant` (#099, IR-680 to IR-689; runtime-image-manifest.md §5, §6).

The stock bundle is built once for the module with `build_bundle`, from a copy of the fixture
archive whose `super.img` is the synthetic super of test_lp_write.py. The fixture archive's own
super carries a whole-image checksum, which the writer refuses (IR-665), and the stock super has
none (IR-686). Every test writes only under its own `tmp_path`. The replacement is synthetic: the
real vendor_a is checked by a gated test.
"""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import zipfile
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

import pytest
from test_bundle import (
    AVB_VALUES,
    FIXTURE_ARCHIVE,
    FIXTURE_MANIFEST,
    LAYOUT_DIRECTORY,
    TEST_KEY,
    TEST_PUBLIC_KEY,
    _layout,
)
from test_lp_write import STOCK_LIKE, VENDOR_SIZE, make_super

import apkrun_image.bundle as bundle_module
from apkrun_image import lp
from apkrun_image.bundle import build_bundle
from apkrun_image.bundle_variant import BundleVariantError, _read_inject_output, build_variant
from apkrun_image.gpt import SECTOR_SIZE, read_gpt
from apkrun_image.inventory import inventory
from apkrun_image.lp_write import LpWriteError, replace_partition
from apkrun_image.runtime_manifest import validate
from apkrun_image.sign import decode_public_key, key_id_of, verify_signature

VENDOR = "vendor_a"
STOCK_SUPER = "stock-super.sparse"
PLAIN_FILES = (
    "boot/bootconfig.txt",
    "boot/cmdline.txt",
    "boot/kernel",
    "boot/ramdisk.img",
    "templates/userdata.img",
)
REAL_EXTRACT_IMAGES = bundle_module.extract_images


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _declare_4k_pages(
    document: Mapping[str, Any], *, output_directory: Path, **options: Path | None
) -> dict[str, object]:
    """The fixture kernel declares no page size; the stock build declares 4 KiB (as test_bundle)."""
    result = REAL_EXTRACT_IMAGES(document, output_directory=output_directory, **options)
    path = output_directory / "extraction.json"
    extraction = json.loads(path.read_text(encoding="utf-8"))
    extraction["kernel"]["pageSize"] = 4096
    path.write_text(json.dumps(extraction), encoding="utf-8")
    return result


def _stock(base: Path) -> Path:
    """Build the stock bundle under `base` and return its directory; the super is beside it."""
    super_path, _logical = make_super(base, name=STOCK_SUPER)
    super_bytes = super_path.read_bytes()
    document = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    declared = document["source"]["archives"][0]
    archive = base / "source" / declared["name"]
    archive.parent.mkdir()
    with zipfile.ZipFile(FIXTURE_ARCHIVE) as source, zipfile.ZipFile(archive, "w") as target:
        for info in source.infolist():
            data = super_bytes if info.filename == "super.img" else source.read(info.filename)
            target.writestr(info.filename, data)
    declared["sha256"] = _sha256(archive.read_bytes())
    declared["size"] = archive.stat().st_size
    # The source directory must hold the fetch record of the archive, which names its hash.
    fetch = json.loads((FIXTURE_ARCHIVE.parent / "fetch.json").read_text(encoding="utf-8"))
    fetch["artifacts"][0].update(sha256=declared["sha256"], size=declared["size"])
    (archive.parent / "fetch.json").write_text(json.dumps(fetch), encoding="utf-8")
    artifact = next(item for item in document["artifacts"] if item["id"] == "super")
    artifact["sha256"] = _sha256(super_bytes)
    artifact["size"] = len(super_bytes)
    document["logicalPartitions"] = [
        {"filesystem": "unknown", "name": name, "size": sum(size for _, size, _ in extents)}
        for name, _group, extents in STOCK_LIKE
        if extents
    ]
    # The inventory is made by the inventory tool: the fixture's own record describes the
    # fixture super (its logical size and partitions), not this one.
    inventory_path = base / "inventory.json"
    inventory_path.write_text(
        json.dumps(inventory(archive), indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    build_bundle(
        document,
        layout_path=_layout(base),
        reference=None,
        image_version="2026.10.0",
        output_directory=base / "stock",
        source=archive,
        inventory_path=inventory_path,
        sign_key=TEST_KEY,
    )
    return base / "stock"


@pytest.fixture(scope="module")
def stock_bundle(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Path]:
    """The stock bundle of this module, built once with the settings of the bundle tests."""
    base = tmp_path_factory.mktemp("stock")
    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(
            bundle_module,
            "calculate_vbmeta_bootconfig",
            lambda _document, _open_artifact: {
                key: value
                for key, value in AVB_VALUES.items()
                if key != "androidboot.vbmeta.device_state"
            },
        )
        patch.setattr(bundle_module, "extract_images", _declare_4k_pages)
        path = _stock(base)
    yield path
    (LAYOUT_DIRECTORY / f"{base.name}.json").unlink(missing_ok=True)


def _payload(tmp_path: Path, size: int = 300_001) -> Path:
    """A non-zero replacement image that is smaller than the partition, so it is zero padded."""
    path = tmp_path / "vendor_a.img"
    path.write_bytes((bytes(range(1, 256)) * (size // 255 + 1))[:size])
    return path


def _super_region(bundle: Path) -> tuple[int, bytes]:
    """Return the offset and the bytes of the super partition, as the GPT locates it."""
    disk = bundle / "disks/os.img"
    with disk.open("rb") as stream:
        table = read_gpt(stream, disk.stat().st_size)
    entry = next(item for item in table.partitions if item.label == "super")
    start = entry.first_lba * SECTOR_SIZE
    return start, disk.read_bytes()[start : start + entry.size]


def _vendor_extents(region: bytes) -> tuple[lp.LogicalPartition, list[tuple[int, int]]]:
    """Return the vendor partition and its physical ranges inside the super region."""
    metadata = lp.read_dynamic_partitions(io.BytesIO(region), sparse=False)
    assert metadata is not None
    target = next(item for item in metadata.logical_partitions if item.name == VENDOR)
    return target, [(extent.target_data * SECTOR_SIZE, extent.size) for extent in target.extents]


def _variant(
    stock: Path, replacement: Path, output: Path, *, stock_super: Path | None = None
) -> dict[str, Any]:
    return build_variant(
        stock_bundle=stock,
        stock_super=stock_super or stock.parent / STOCK_SUPER,
        partition=VENDOR,
        replacement=replacement,
        output=output,
        sign_key=TEST_KEY,
    )


def test_the_replaced_partition_reads_back_as_the_replacement_then_zeros(
    tmp_path: Path, stock_bundle: Path
) -> None:
    replacement = _payload(tmp_path)
    record = _variant(stock_bundle, replacement, tmp_path / "variant")

    offset, region = _super_region(tmp_path / "variant")
    target, _ = _vendor_extents(region)
    expected = replacement.read_bytes() + bytes(target.size - replacement.stat().st_size)
    assert lp.read_partition_range(io.BytesIO(region), target, 0, target.size) == expected
    assert offset > 0
    assert record["partition"]["variantSuperSHA256"] == _sha256(region)  # type: ignore[index]


def test_only_the_replaced_extents_differ_from_the_stock_disk(
    tmp_path: Path, stock_bundle: Path
) -> None:
    _variant(stock_bundle, _payload(tmp_path), tmp_path / "variant")

    offset, region = _super_region(stock_bundle)
    _, extents = _vendor_extents(region)
    stock_disk = (stock_bundle / "disks/os.img").read_bytes()
    variant_disk = bytearray((tmp_path / "variant/disks/os.img").read_bytes())
    assert bytes(variant_disk) != stock_disk
    for physical, size in extents:
        start = offset + physical
        variant_disk[start : start + size] = stock_disk[start : start + size]
    assert bytes(variant_disk) == stock_disk
    for name in PLAIN_FILES:
        assert (tmp_path / "variant" / name).read_bytes() == (stock_bundle / name).read_bytes()


def test_the_manifest_changes_only_the_two_hashes_it_must(
    tmp_path: Path, stock_bundle: Path
) -> None:
    _variant(stock_bundle, _payload(tmp_path), tmp_path / "variant")
    variant = tmp_path / "variant"
    manifest_bytes = (variant / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)

    _, region = _super_region(variant)
    expected = json.loads((stock_bundle / "manifest.json").read_text(encoding="utf-8"))
    for partition in expected["disks"][0]["partitions"]:
        if partition["label"] == "super":
            partition["sha256"] = _sha256(region)
    for entry in expected["files"]:
        if entry["path"] == "disks/os.img":
            entry["sha256"] = _sha256((variant / "disks/os.img").read_bytes())
    assert manifest == expected
    assert validate(manifest) == []
    assert manifest["kind"] == "stock"
    for entry in manifest["files"]:
        data = (variant / entry["path"]).read_bytes()
        assert entry == {"path": entry["path"], "size": len(data), "sha256": _sha256(data)}
    assert (variant / "SHA256SUMS").read_text(encoding="ascii").splitlines() == [
        f"{entry['sha256']}  {entry['path']}" for entry in manifest["files"]
    ]
    public_key = decode_public_key(TEST_PUBLIC_KEY.read_text(encoding="ascii"))
    verify_signature(
        manifest_bytes,
        (variant / "manifest.sig").read_bytes(),
        {key_id_of(public_key): public_key},
    )


def test_a_damaged_stock_bundle_is_refused_and_nothing_is_written(
    tmp_path: Path, stock_bundle: Path
) -> None:
    damaged = tmp_path / "damaged"
    shutil.copytree(stock_bundle, damaged)
    (damaged / "templates/userdata.img").write_bytes(b"damaged")
    replacement = _payload(tmp_path)
    before = sorted(path.name for path in tmp_path.iterdir())
    with pytest.raises(BundleVariantError, match="does not match its manifest entry"):
        _variant(
            damaged,
            replacement,
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )
    assert sorted(path.name for path in tmp_path.iterdir()) == before


def test_a_stock_super_that_is_not_the_bundles_super_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    other = tmp_path / "other-super.sparse"
    replace_partition(
        stock_bundle.parent / STOCK_SUPER, VENDOR, _payload(tmp_path, size=4096), other
    )
    with pytest.raises(BundleVariantError, match="does not expand to the super partition"):
        _variant(
            stock_bundle,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=other,
        )
    assert not (tmp_path / "variant").exists()


def test_an_existing_output_is_refused_and_left_alone(tmp_path: Path, stock_bundle: Path) -> None:
    (tmp_path / "variant").mkdir()
    (tmp_path / "variant" / "keep.txt").write_text("keep", encoding="utf-8")
    with pytest.raises(BundleVariantError, match="already exists"):
        _variant(stock_bundle, _payload(tmp_path), tmp_path / "variant")
    assert (tmp_path / "variant" / "keep.txt").read_text(encoding="utf-8") == "keep"


def test_a_replacement_larger_than_the_partition_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    larger = _payload(tmp_path, size=VENDOR_SIZE + 4096)
    with pytest.raises(LpWriteError, match="does not grow a partition"):
        _variant(stock_bundle, larger, tmp_path / "variant")
    assert not (tmp_path / "variant").exists()


def test_the_inject_record_must_name_the_replacement_it_wrote(tmp_path: Path) -> None:
    replacement = _payload(tmp_path)
    directory = tmp_path / "inject"
    directory.mkdir()
    (directory / "vendor_a.img").write_bytes(replacement.read_bytes())
    record: dict[str, object] = {
        "partition": {"name": VENDOR},
        "output": {"file": "vendor_a.img", "sha256": _sha256(b"other")},
    }
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    with pytest.raises(BundleVariantError, match="does not match the SHA-256"):
        _read_inject_output(directory, VENDOR)

    record["output"] = {"file": "vendor_a.img", "sha256": _sha256(replacement.read_bytes())}
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    assert _read_inject_output(directory, VENDOR) == directory / "vendor_a.img"
    with pytest.raises(BundleVariantError, match="does not record the partition"):
        _read_inject_output(directory, "system_a")
