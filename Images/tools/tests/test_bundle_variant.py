"""Tests for `bundle-variant` (#99, IR-680 to IR-689; runtime-image-manifest.md §5, §6).

The stock bundle is built once for the module with `build_bundle`, from a copy of the fixture
archive whose `super.img` is the synthetic super of test_lp_write.py. The fixture archive's own
super carries a whole-image checksum, which the writer refuses (IR-665), and the stock super has
none (IR-686). Every test writes only under its own `tmp_path`. The replacement is synthetic: the
real vendor_a is checked outside the suite (IR-706).
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import shutil
import subprocess
import zipfile
from collections.abc import Callable, Iterator, Mapping
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
from apkrun_image import bundle_variant, lp
from apkrun_image.bundle import build_bundle
from apkrun_image.bundle_variant import (
    BundleVariantError,
    _builder_provenance,
    _read_inject_output,
    build_parser,
    build_variant,
    main,
)
from apkrun_image.gpt import SECTOR_SIZE, read_gpt
from apkrun_image.inventory import inventory
from apkrun_image.lp_write import LpWriteError, replace_partition
from apkrun_image.runtime_manifest import validate
from apkrun_image.sign import (
    decode_public_key,
    key_id_of,
    load_private_key,
    render_signature,
    verify_signature,
)

VENDOR = "vendor_a"
VARIANT_IMAGE_VERSION = "2026.10.1"
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
    stock: Path,
    replacement: Path,
    output: Path,
    *,
    stock_super: Path | None = None,
    image_version: str = VARIANT_IMAGE_VERSION,
) -> dict[str, Any]:
    return build_variant(
        stock_bundle=stock,
        stock_super=stock_super or stock.parent / STOCK_SUPER,
        partition=VENDOR,
        replacement=replacement,
        image_version=image_version,
        output=output,
        sign_key=TEST_KEY,
    )


def test_builder_provenance_binds_the_commit_and_local_tool_source(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    tools = repository / "Images" / "tools"
    tools.mkdir(parents=True)
    source = tools / "builder.py"
    source.write_text("value = 1\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(repository), "add", "Images/tools/builder.py"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "-c",
            "user.name=APKRun Test",
            "-c",
            "user.email=apkrun-test@example.invalid",
            "commit",
            "-q",
            "-m",
            "fixture",
        ],
        check=True,
    )

    clean = _builder_provenance(repository)
    source.write_text("value = 2\n", encoding="utf-8")
    dirty = _builder_provenance(repository)

    assert clean["repository"] == "Images/tools"
    assert clean["workingTreeClean"] is True
    assert dirty["workingTreeClean"] is False
    assert dirty["gitRevision"] == clean["gitRevision"]
    assert dirty["sourceSHA256"] != clean["sourceSHA256"]


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


def test_the_manifest_changes_identity_and_hashes_and_is_resigned(
    tmp_path: Path, stock_bundle: Path
) -> None:
    record = _variant(stock_bundle, _payload(tmp_path), tmp_path / "variant")
    variant = tmp_path / "variant"
    manifest_bytes = (variant / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)

    _, region = _super_region(variant)
    expected = json.loads((stock_bundle / "manifest.json").read_text(encoding="utf-8"))
    expected["imageVersion"] = (
        f"{VARIANT_IMAGE_VERSION}-cf{expected['provenance']['source']['buildId']}-arm64"
    )
    for partition in expected["disks"][0]["partitions"]:
        if partition["label"] == "super":
            partition["sha256"] = _sha256(region)
    for entry in expected["files"]:
        if entry["path"] == "disks/os.img":
            entry["sha256"] = _sha256((variant / "disks/os.img").read_bytes())
    assert manifest == expected
    assert validate(manifest) == []
    assert manifest["kind"] == "stock"
    stock_manifest = json.loads((stock_bundle / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["provenance"] == stock_manifest["provenance"]
    assert manifest["provenance"]["source"]["buildId"] == "16373615"
    assert record["schemaVersion"] == 3
    assert record["imageVersion"] == manifest["imageVersion"]
    assert record["builder"]["repository"] == "Images/tools"
    assert re.fullmatch(r"[0-9a-f]{40}", record["builder"]["gitRevision"])
    assert re.fullmatch(r"[0-9a-f]{64}", record["builder"]["sourceSHA256"])
    assert isinstance(record["builder"]["workingTreeClean"], bool)
    assert json.loads((tmp_path / "variant.variant.json").read_text(encoding="utf-8")) == record
    assert "IR-1322" in record["decisions"]["identity"]  # type: ignore[index]
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


def test_the_variant_version_must_be_distinct_from_the_stock_version(
    tmp_path: Path, stock_bundle: Path
) -> None:
    with pytest.raises(BundleVariantError, match="distinct from the stock bundle"):
        _variant(
            stock_bundle,
            _payload(tmp_path),
            tmp_path / "variant",
            image_version="2026.10.0",
        )
    assert not (tmp_path / "variant").exists()
    assert not (tmp_path / "variant.variant.json").exists()


def test_the_variant_version_uses_the_short_image_version_form(
    tmp_path: Path, stock_bundle: Path
) -> None:
    with pytest.raises(BundleVariantError, match="short form YYYY.MM.N"):
        _variant(
            stock_bundle,
            _payload(tmp_path),
            tmp_path / "variant",
            image_version="2026.10.2-cf16373615-arm64",
        )
    assert not (tmp_path / "variant").exists()
    assert not (tmp_path / "variant.variant.json").exists()


def test_the_command_requires_an_explicit_variant_version() -> None:
    with pytest.raises(SystemExit, match="2"):
        build_parser().parse_args(
            [
                "--bundle",
                "bundle",
                "--manifest",
                "manifest.json",
                "--inject-output",
                "inject",
                "--sign-key",
                "key",
                "--out",
                "variant",
            ]
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
        "buildId": "16373615",
        "partition": {"name": VENDOR},
        "output": {"file": "vendor_a.img", "sha256": _sha256(b"other")},
    }
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    with pytest.raises(BundleVariantError, match="does not match the SHA-256"):
        _read_inject_output(directory, VENDOR, "16373615")

    record["output"] = {"file": "vendor_a.img", "sha256": _sha256(replacement.read_bytes())}
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    assert _read_inject_output(directory, VENDOR, "16373615") == directory / "vendor_a.img"
    with pytest.raises(BundleVariantError, match="does not record the partition"):
        _read_inject_output(directory, "system_a", "16373615")
    with pytest.raises(BundleVariantError, match="was made for build"):
        _read_inject_output(directory, VENDOR, "99999999")


def test_an_inject_record_whose_partition_is_not_an_object_is_refused(tmp_path: Path) -> None:
    directory = tmp_path / "inject"
    directory.mkdir()
    record = {"buildId": "16373615", "partition": "vendor_a"}
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    with pytest.raises(BundleVariantError, match="does not record the partition"):
        _read_inject_output(directory, VENDOR, "16373615")


def test_the_command_reports_a_bad_inject_record_and_exits_2(
    tmp_path: Path, stock_bundle: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    directory = tmp_path / "inject"
    directory.mkdir()
    record = {"buildId": "16373615", "partition": {"name": "system_a"}}
    (directory / "inject.json").write_text(json.dumps(record), encoding="utf-8")
    exit_code = main(
        [
            "--bundle",
            str(stock_bundle),
            "--manifest",
            str(FIXTURE_MANIFEST),
            "--inject-output",
            str(directory),
            "--image-version",
            VARIANT_IMAGE_VERSION,
            "--sign-key",
            str(TEST_KEY),
            "--out",
            str(tmp_path / "variant"),
        ]
    )
    assert exit_code == 2
    assert "does not record the partition vendor_a" in capsys.readouterr().err
    assert not (tmp_path / "variant").exists()


def test_a_stock_bundle_whose_signature_does_not_verify_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    damaged = tmp_path / "damaged"
    shutil.copytree(stock_bundle, damaged)
    # One space keeps the JSON valid and the files unchanged, so only the signature fails.
    (damaged / "manifest.json").write_bytes((damaged / "manifest.json").read_bytes() + b" ")
    with pytest.raises(BundleVariantError, match="does not verify"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )
    assert not (tmp_path / "variant").exists()


def test_an_extra_file_or_a_changed_checksum_list_in_the_stock_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    damaged = tmp_path / "damaged"
    shutil.copytree(stock_bundle, damaged)
    (damaged / "extra.txt").write_text("extra", encoding="utf-8")
    with pytest.raises(BundleVariantError, match="holds \\['extra.txt'\\]"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )
    (damaged / "extra.txt").unlink()
    (damaged / "SHA256SUMS").write_bytes(b"\xff\n")
    with pytest.raises(BundleVariantError, match="is not ASCII"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )
    (damaged / "SHA256SUMS").write_text("0" * 64 + "  boot/kernel\n", encoding="ascii")
    with pytest.raises(BundleVariantError, match="SHA256SUMS does not match"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )


def _stock_with_manifest_edit(
    tmp_path: Path, stock_bundle: Path, edit: Callable[[dict[str, Any]], None]
) -> Path:
    """A copy of the stock whose manifest is edited and signed again with the test key.

    The files and the checksum list are unchanged, so only the check that `edit` touches fails.
    """
    damaged = tmp_path / "damaged"
    shutil.copytree(stock_bundle, damaged)
    manifest = json.loads((damaged / "manifest.json").read_text(encoding="utf-8"))
    edit(manifest)
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    (damaged / "manifest.json").write_bytes(manifest_bytes)
    (damaged / "manifest.sig").write_bytes(
        render_signature(manifest_bytes, load_private_key(TEST_KEY))
    )
    return damaged


def _super_partition(manifest: dict[str, Any]) -> dict[str, Any]:
    return next(item for item in manifest["disks"][0]["partitions"] if item["label"] == "super")


def test_a_super_hash_that_the_manifest_does_not_match_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    def edit(manifest: dict[str, Any]) -> None:
        _super_partition(manifest)["sha256"] = "0" * 64

    damaged = _stock_with_manifest_edit(tmp_path, stock_bundle, edit)
    with pytest.raises(BundleVariantError, match="does not expand to the super partition"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )


def test_a_super_size_that_the_gpt_does_not_have_is_refused(
    tmp_path: Path, stock_bundle: Path
) -> None:
    def edit(manifest: dict[str, Any]) -> None:
        # One MiB less keeps the schema and the partition order valid, so the GPT check is reached.
        _super_partition(manifest)["size"] -= 1048576

    damaged = _stock_with_manifest_edit(tmp_path, stock_bundle, edit)
    with pytest.raises(BundleVariantError, match="differs from the manifest"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )


def test_a_replacement_of_exactly_the_partition_size_reads_back_without_padding(
    tmp_path: Path, stock_bundle: Path
) -> None:
    replacement = _payload(tmp_path, size=VENDOR_SIZE)
    _variant(stock_bundle, replacement, tmp_path / "variant")
    super_offset, region = _super_region(tmp_path / "variant")
    target, _ = _vendor_extents(region)
    assert target.size == VENDOR_SIZE
    assert lp.read_partition_range(io.BytesIO(region), target, 0, target.size) == (
        replacement.read_bytes()
    )
    bundle_variant._verify_variant(
        stock_bundle / "disks/os.img",
        tmp_path / "variant/disks/os.img",
        super_offset,
        len(region),
        VENDOR,
        replacement,
        expected_replacement_sha256=_sha256(replacement.read_bytes()),
    )
    with pytest.raises(BundleVariantError, match="differs from its checked AVB snapshot"):
        bundle_variant._verify_variant(
            stock_bundle / "disks/os.img",
            tmp_path / "variant/disks/os.img",
            super_offset,
            len(region),
            VENDOR,
            replacement,
            expected_replacement_sha256="0" * 64,
        )


@pytest.mark.parametrize(
    ("where", "message"),
    [("outside", "differs from the stock bundle"), ("inside", "does not read back")],
)
def test_a_splice_that_changes_one_byte_is_refused_and_nothing_is_written(
    tmp_path: Path,
    stock_bundle: Path,
    monkeypatch: pytest.MonkeyPatch,
    where: str,
    message: str,
) -> None:
    offset, region = _super_region(stock_bundle)
    _, extents = _vendor_extents(region)
    position = 0 if where == "outside" else offset + extents[0][0]
    original = bundle_variant._splice

    def corrupt(
        stock_disk: Path,
        sparse: Path,
        destination: Path,
        start: int,
        size: int,
        **checksums: str,
    ) -> None:
        original(stock_disk, sparse, destination, start, size, **checksums)
        with destination.open("r+b") as stream:
            stream.seek(position)
            byte = stream.read(1)
            stream.seek(position)
            stream.write(bytes([byte[0] ^ 0xFF]))

    monkeypatch.setattr(bundle_variant, "_splice", corrupt)
    with pytest.raises(BundleVariantError, match=message):
        _variant(stock_bundle, _payload(tmp_path), tmp_path / "variant")
    assert not (tmp_path / "variant").exists()
    assert not (tmp_path / "variant.variant.json").exists()


def test_a_symbolic_link_in_the_stock_bundle_is_refused_before_anything_is_read(
    tmp_path: Path, stock_bundle: Path
) -> None:
    # The link points at a regular file, so a missing check would fail on the size, not hang.
    damaged = tmp_path / "damaged"
    shutil.copytree(stock_bundle, damaged)
    (damaged / "templates/userdata.img").unlink()
    (damaged / "templates/userdata.img").symlink_to(damaged / "boot/cmdline.txt")
    with pytest.raises(BundleVariantError, match="not a regular file"):
        _variant(
            damaged,
            _payload(tmp_path),
            tmp_path / "variant",
            stock_super=stock_bundle.parent / STOCK_SUPER,
        )


def test_a_refreshed_vbmeta_is_restricted_to_stock_development_images(
    tmp_path: Path,
    stock_bundle: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manifest = json.loads((stock_bundle / "manifest.json").read_text(encoding="utf-8"))
    manifest["kind"] = "apkrun"
    manifest["provenance"]["source"]["origin"] = "apkrun-builder"
    manifest["provenance"]["source"]["buildId"] = "ar123456"
    manifest["requirements"]["agents"] = [
        {"package": "io.apkrun.guest", "versionCode": 12},
        {"package": "io.apkrun.store", "versionCode": 12},
    ]
    manifest["provenance"]["revisions"]["guest"] = "f" * 40
    manifest["provenance"]["pinnedManifestSHA256"] = "2" * 64
    manifest["provenance"]["builderImageDigest"] = "sha256:" + "3" * 64
    manifest["imageVersion"] = "2026.10.0-ar123456-arm64"
    monkeypatch.setattr(
        bundle_variant,
        "_verify_stock",
        lambda _bundle, _key: (json.dumps(manifest).encode("utf-8"), manifest),
    )
    refresh = bundle_variant._Refresh(
        injected=tmp_path / "injected-vendor_a.img",
        vendor=tmp_path / "vendor_a.img",
        vbmeta=tmp_path / "vbmeta_a.img",
        record={},
        inject_record_sha256="0" * 64,
        record_sha256="1" * 64,
        record_path=tmp_path / "reseal.json",
    )

    with pytest.raises(BundleVariantError, match="only in a kind: stock development bundle"):
        build_variant(
            stock_bundle=stock_bundle,
            stock_super=stock_bundle.parent / STOCK_SUPER,
            partition=VENDOR,
            replacement=_payload(tmp_path),
            image_version=VARIANT_IMAGE_VERSION,
            output=tmp_path / "variant",
            sign_key=TEST_KEY,
            refresh=refresh,
        )
    assert not (tmp_path / "variant").exists()
    assert not (tmp_path / "variant.variant.json").exists()
