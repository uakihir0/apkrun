"""Tests for layout validation (android-image.md §4.2; reference §8)."""

from __future__ import annotations

import copy
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from apkrun_image.layout import LayoutError, check_sources, load_layout, parse_layout

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PINNED_LAYOUT = REPOSITORY_ROOT / "Images/tools/layouts/cuttlefish-phone-arm64.json"
PINNED_MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"
FAMILY = "cuttlefish-phone-arm64"


def _document() -> dict[str, Any]:
    return json.loads(PINNED_LAYOUT.read_text(encoding="utf-8"))


def test_pinned_layout_has_the_two_disks_of_the_plan() -> None:
    layout = load_layout(PINNED_LAYOUT, FAMILY)

    assert [disk.role for disk in layout.disks] == ["os", "userdata"]
    assert [disk.read_only for disk in layout.disks] == [True, False]
    assert len(layout.disks[0].partitions) == 9
    assert [partition.label for partition in layout.disks[1].partitions] == [
        "misc",
        "metadata",
        "frp",
        "userdata",
    ]
    assert layout.disks[1].userdata_strategy == "blankFormattable"


def test_pinned_layout_names_only_manifest_partitions() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    check_sources(
        load_layout(PINNED_LAYOUT, FAMILY), manifest["artifacts"], manifest["blankPartitions"]
    )


def test_pinned_layout_bootconfig_has_no_platform_instance_or_graphics_keys() -> None:
    image = _document()["bootconfig"]["image"]

    for key in (
        "androidboot.boot_devices",
        "androidboot.serialno",
        "androidboot.ddr_size",
        "androidboot.lcd_density",
        "androidboot.hardware.egl",
    ):
        assert key not in image


def test_a_layout_for_another_device_family_is_rejected() -> None:
    document = _document()
    document["deviceFamily"] = "cuttlefish-tablet-arm64"
    with pytest.raises(
        LayoutError,
        match="layout cuttlefish-tablet-arm64 does not match deviceFamily cuttlefish-phone-arm64.",
    ):
        parse_layout(document, FAMILY)


def test_a_partition_without_a_source_is_named() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    artifacts = [
        artifact for artifact in manifest["artifacts"] if artifact["partition"] != "custom"
    ]
    with pytest.raises(LayoutError, match='layout partition "custom" has no artifact or blank'):
        check_sources(load_layout(PINNED_LAYOUT, FAMILY), artifacts, manifest["blankPartitions"])


def test_a_blank_partition_entry_must_be_marked_blank() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    document = _document()
    del document["disks"][1]["partitions"][0]["blank"]
    with pytest.raises(LayoutError, match='names blank partition "misc" and must be blank'):
        check_sources(
            parse_layout(document, FAMILY), manifest["artifacts"], manifest["blankPartitions"]
        )


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda d: d["disks"][0].update(readOnly=False), "disks\\[0\\] must be the read-only"),
        (lambda d: d["disks"][1].update(role="os"), "roles must be unique"),
        (lambda d: d["disks"][1].update(file="os.img"), "files must be unique"),
        (lambda d: d["disks"][1].update(identifier="Bad_ID"), "identifier must match"),
        (lambda d: d["disks"][1]["partitions"][0].update(label="frp"), "used twice: frp"),
        (lambda d: d["disks"][1]["partitions"][3].pop("size"), "last partition must be blank"),
        (lambda d: d["disks"][1].update(userdataStrategy="grow"), "userdataStrategy must be"),
        (lambda d: d["disks"][1]["partitions"][0].update(size=100), "multiple of 512"),
        (lambda d: d["disks"][0]["partitions"][0].update(size=512), "only allowed for a blank"),
        (lambda d: d["disks"][0].update(extra=1), "unknown fields: extra"),
        (lambda d: d.update(disks=[]), "non-empty array"),
    ],
)
def test_broken_layouts_name_the_problem(
    mutate: Callable[[dict[str, Any]], object], message: str
) -> None:
    document = copy.deepcopy(_document())
    mutate(document)
    with pytest.raises(LayoutError, match=message):
        parse_layout(document, FAMILY)
