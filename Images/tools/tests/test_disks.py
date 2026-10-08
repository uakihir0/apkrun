"""Tests for the disks command (#011, android-image.md §4.2-§4.5)."""

from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path
from typing import Any

import pytest

from apkrun_image.disks import DisksError, build_disks
from apkrun_image.gpt import SECTOR_SIZE, partition_guid, read_gpt
from apkrun_image.layout import LayoutError
from apkrun_image.sparse import expand_into, read_header

TESTS = Path(__file__).parent
REPOSITORY_ROOT = TESTS.parents[2]
FIXTURE_ARCHIVE = TESTS / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"
FIXTURE_MANIFEST = TESTS / "fixtures/manifests/valid/fixture-build.json"
FIXTURE_INVENTORY = TESTS / "fixtures/manifests/fixture-inventory.json"
EXPECTED_SHA256 = TESTS / "fixtures/sparse/expected-sha256.txt"
PINNED_MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)


def _manifest() -> dict[str, Any]:
    return json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))


def _layout(path: Path, **overrides: object) -> Path:
    document: dict[str, Any] = {
        "deviceFamily": "cuttlefish-phone-arm64",
        "disks": [
            {
                "role": "os",
                "file": "os.img",
                "readOnly": True,
                "identifier": "apkrun-os",
                "partitions": [
                    {"label": "boot_a", "source": "boot"},
                    {"label": "vbmeta_a", "source": "vbmeta"},
                    {"label": "super", "source": "super"},
                ],
            },
            {
                "role": "userdata",
                "file": "userdata.img",
                "readOnly": False,
                "identifier": "apkrun-data",
                "userdataStrategy": "blankFormattable",
                "partitions": [
                    {"label": "misc", "source": "misc", "blank": True},
                    {"label": "metadata", "source": "metadata", "blank": True},
                    {"label": "userdata", "source": "userdata", "blank": True, "size": 1048576},
                ],
            },
        ],
    }
    document.update(overrides)
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def _build(tmp_path: Path, output: Path, layout: Path | None = None) -> dict[str, object]:
    return build_disks(
        _manifest(),
        layout_path=layout or _layout(tmp_path / "layout.json"),
        output_directory=output,
        image_version="2026.10.0-test",
        source=FIXTURE_ARCHIVE,
        inventory_path=FIXTURE_INVENTORY,
    )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_disks_hold_the_layout_partitions_with_the_artifact_contents(tmp_path: Path) -> None:
    archive_hash = _sha256(FIXTURE_ARCHIVE)
    output = tmp_path / "disks"
    metadata = _build(tmp_path, output)

    os_image = output / "os.img"
    with os_image.open("rb") as stream:
        table = read_gpt(stream, os_image.stat().st_size)
    assert [partition.label for partition in table.partitions] == ["boot_a", "vbmeta_a", "super"]
    assert table.partitions[0].unique_guid == partition_guid("2026.10.0-test", "os", "boot_a")
    with zipfile.ZipFile(FIXTURE_ARCHIVE) as archive:
        boot = archive.read("boot.img")
        super_sparse = archive.read("super.img")
    raw = os_image.read_bytes()
    boot_offset = table.partitions[0].first_lba * SECTOR_SIZE
    assert raw[boot_offset : boot_offset + len(boot)] == boot
    assert table.partitions[0].size == len(boot)

    super_partition = table.partitions[2]
    super_offset = super_partition.first_lba * SECTOR_SIZE
    expanded = raw[super_offset : super_offset + super_partition.size]
    expected = [
        line.split()[0]
        for line in EXPECTED_SHA256.read_text().splitlines()
        if line.endswith("  super.img")
    ][0]
    assert hashlib.sha256(expanded).hexdigest() == expected

    records = {disk["role"]: disk for disk in metadata["disks"]}  # type: ignore[index]
    super_record = records["os"]["partitions"][2]
    assert super_record["sha256"] == expected
    assert super_record["content"] == "sparse"
    assert len(super_sparse) == _manifest()["artifacts"][6]["size"]
    assert records["userdata"]["userdataStrategy"] == "blankFormattable"
    assert records["userdata"]["partitions"][-1]["label"] == "userdata"
    assert records["userdata"]["partitions"][0]["content"] == "blank"
    assert (
        records["userdata"]["partitions"][0]["sha256"] == hashlib.sha256(bytes(1048576)).hexdigest()
    )
    assert json.loads((output / "disks.json").read_text()) == metadata
    assert _sha256(FIXTURE_ARCHIVE) == archive_hash


def test_partitions_start_on_1_mib_and_sizes_equal_image_sizes(tmp_path: Path) -> None:
    metadata = _build(tmp_path, tmp_path / "disks")
    for disk in metadata["disks"]:  # type: ignore[union-attr]
        assert disk["logicalSize"] % (1024 * 1024) == 0
        for partition in disk["partitions"]:
            assert partition["firstLBA"] % 2048 == 0
    super_size = next(
        partition["size"]
        for partition in metadata["disks"][0]["partitions"]  # type: ignore[index]
        if partition["label"] == "super"
    )
    with zipfile.ZipFile(FIXTURE_ARCHIVE) as archive, archive.open("super.img") as stream:
        assert super_size == read_header(stream).logical_size


def test_two_runs_give_identical_bytes(tmp_path: Path) -> None:
    _build(tmp_path, tmp_path / "first")
    _build(tmp_path, tmp_path / "second")
    for name in ("os.img", "userdata.img", "disks.json"):
        assert _sha256(tmp_path / "first" / name) == _sha256(tmp_path / "second" / name)


def test_a_broken_layout_writes_nothing(tmp_path: Path) -> None:
    layout = _layout(tmp_path / "layout.json", deviceFamily="cuttlefish-tablet-arm64")
    with pytest.raises(LayoutError, match="does not match deviceFamily"):
        _build(tmp_path, tmp_path / "disks", layout)
    assert not (tmp_path / "disks").exists()


def test_a_blank_artifact_partition_needs_a_size(tmp_path: Path) -> None:
    layout = _layout(tmp_path / "layout.json")
    document = json.loads(layout.read_text())
    del document["disks"][1]["partitions"][2]["size"]
    document["disks"][1].pop("userdataStrategy")
    layout.write_text(json.dumps(document))
    with pytest.raises(DisksError, match='"userdata" is blank but has no size'):
        _build(tmp_path, tmp_path / "disks", layout)


@pytest.mark.skipif(not PINNED_ARCHIVE.is_file(), reason="needs the pinned 16373615 archive (T1)")
def test_pinned_super_matches_simg2img(tmp_path: Path) -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    super_artifact = next(a for a in manifest["artifacts"] if a["partition"] == "super")
    expected = next(
        line.split()[0]
        for line in EXPECTED_SHA256.read_text().splitlines()
        if line.endswith(f"real:{super_artifact['sha256']}")
    )
    output = tmp_path / "super.raw"
    with zipfile.ZipFile(PINNED_ARCHIVE) as archive, archive.open("super.img") as stream:
        size = read_header(stream).logical_size
    with zipfile.ZipFile(PINNED_ARCHIVE) as archive, archive.open("super.img") as stream:
        with output.open("w+b") as out:
            out.truncate(size)
            expand_into(stream, out, 0)
    digest = hashlib.sha256()
    with output.open("rb") as stream:
        while data := stream.read(8 * 1024 * 1024):
            digest.update(data)
    assert digest.hexdigest() == expected
    assert output.stat().st_blocks * 512 < size // 2
