"""Tests for `bundle --unsigned` (#012; android-image.md §10; runtime-image-manifest.md)."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

import apkrun_image.bundle as bundle_module
from apkrun_image.bootconfig import parse_bootconfig_text
from apkrun_image.bundle import BundleError, build_bundle, main

TESTS = Path(__file__).parent
REPOSITORY_ROOT = TESTS.parents[2]
FIXTURE_ARCHIVE = TESTS / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"
FIXTURE_MANIFEST = TESTS / "fixtures/manifests/valid/fixture-build.json"
FIXTURE_INVENTORY = TESTS / "fixtures/manifests/fixture-inventory.json"
PINNED_LAYOUT = REPOSITORY_ROOT / "Images/tools/layouts/cuttlefish-phone-arm64.json"


# The fixture vbmeta chains to partitions the fixture build does not ship, so the
# AVB values (tested in test_avb.py) are fixed here.
AVB_VALUES = {
    "androidboot.vbmeta.avb_version": "1.4",
    "androidboot.vbmeta.device_state": "unlocked",
    "androidboot.vbmeta.digest": "0" * 64,
    "androidboot.vbmeta.hash_alg": "sha256",
    "androidboot.vbmeta.invalidate_on_error": "yes",
    "androidboot.vbmeta.size": "1536",
}


@pytest.fixture(autouse=True)
def _fixed_avb_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        bundle_module,
        "calculate_vbmeta_bootconfig",
        lambda _document, _open_artifact: {
            key: value
            for key, value in AVB_VALUES.items()
            if key != "androidboot.vbmeta.device_state"
        },
    )


def _layout(tmp_path: Path) -> Path:
    pinned = json.loads(PINNED_LAYOUT.read_text(encoding="utf-8"))
    document = {
        "deviceFamily": "cuttlefish-phone-arm64",
        "bootconfig": {"image": {"androidboot.slot_suffix": "_a"}},
        "cmdline": {
            "additions": [
                *pinned["cmdline"]["additions"],
                {"comment": "The fixture vendor cmdline lacks it.", "value": "bootconfig"},
            ]
        },
        "consolePorts": pinned["consolePorts"],
        "gpuProfiles": pinned["gpuProfiles"],
        "disks": [
            {
                "role": "os",
                "file": "os.img",
                "readOnly": True,
                "identifier": "apkrun-os",
                "partitions": [
                    {"label": "boot_a", "source": "boot"},
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
                    {"label": "userdata", "source": "userdata", "blank": True, "size": 1048576},
                ],
            },
        ],
    }
    # provenance.layout.path is repository-relative, so the layout lives under the
    # ignored Images/work tree for the duration of the test.
    directory = REPOSITORY_ROOT / "Images/work/test-layouts"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{tmp_path.name}.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


@pytest.fixture(autouse=True)
def _remove_test_layouts(tmp_path: Path) -> Iterator[None]:
    yield
    (REPOSITORY_ROOT / f"Images/work/test-layouts/{tmp_path.name}.json").unlink(missing_ok=True)


def _build(tmp_path: Path, output: Path) -> dict[str, Any]:
    return build_bundle(
        json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8")),
        layout_path=_layout(tmp_path),
        reference=None,
        image_version="2026.10.0",
        output_directory=output,
        source=FIXTURE_ARCHIVE,
        inventory_path=FIXTURE_INVENTORY,
    )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_unsigned_bundle_has_the_documented_tree_and_manifest(tmp_path: Path) -> None:
    output = tmp_path / "bundle"
    manifest = _build(tmp_path, output)

    files = sorted(
        path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()
    )
    assert files == [
        "boot/bootconfig.txt",
        "boot/cmdline.txt",
        "boot/kernel",
        "boot/ramdisk.img",
        "disks/os.img",
        "manifest.json",
        "templates/userdata.img",
    ]
    assert manifest["schemaVersion"] == 1
    assert manifest["imageVersion"].startswith("2026.10.0-cf")
    assert manifest["imageVersion"].endswith("-arm64")
    assert manifest["kind"] == "stock"
    assert [entry["path"] for entry in manifest["files"]] == [
        name for name in files if name != "manifest.json"
    ]
    for entry in manifest["files"]:
        assert entry["sha256"] == _sha256(output / entry["path"])
        assert entry["size"] == (output / entry["path"]).stat().st_size
    assert manifest["boot"]["kernel"] == next(
        entry for entry in manifest["files"] if entry["path"] == "boot/kernel"
    )
    assert [disk["role"] for disk in manifest["disks"]] == ["os"]
    assert [disk["role"] for disk in manifest["templates"]] == ["userdata"]
    assert manifest["templates"][0]["userdataStrategy"] == "blankFormattable"
    assert len(manifest["consolePorts"]) == 20
    assert manifest["consolePorts"][18] == {
        "index": 18,
        "role": "service",
        "name": "sensors_control",
    }
    assert sorted(manifest["gpuProfiles"]) == ["drmVirgl", "guestSwiftshader", "headless"]
    assert manifest["guest"]["sdk"] == manifest["provenance"]["android"]["sdk"]
    assert json.loads((output / "manifest.json").read_text()) == manifest
    assert (output / "manifest.json").read_text().endswith("}\n")


def test_bootconfig_file_has_the_vendor_and_image_sections(tmp_path: Path) -> None:
    output = tmp_path / "bundle"
    _build(tmp_path, output)

    text = (output / "boot/bootconfig.txt").read_text(encoding="ascii")
    vendor_part, image_part = text.split("[image]\n")
    assert vendor_part.startswith("[vendor]\n")
    image = parse_bootconfig_text(image_part, layer_name="image")
    assert image["androidboot.slot_suffix"] == "_a"
    assert {
        "androidboot.vbmeta.digest",
        "androidboot.vbmeta.hash_alg",
        "androidboot.vbmeta.size",
    } <= set(image)
    assert text.endswith("\n")
    assert "\n\n" not in text
    command_line = (output / "boot/cmdline.txt").read_text(encoding="ascii")
    assert not command_line.endswith("\n")
    assert "bootconfig" in command_line.split()


def test_two_builds_are_identical(tmp_path: Path) -> None:
    first = _build(tmp_path, tmp_path / "first")
    second = _build(tmp_path, tmp_path / "second")
    assert first == second


def test_a_full_image_version_is_refused(tmp_path: Path) -> None:
    with pytest.raises(BundleError, match="short form"):
        build_bundle(
            json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8")),
            layout_path=_layout(tmp_path),
            reference=None,
            image_version="2026.10.0-cf1-arm64",
            output_directory=tmp_path / "bundle",
            source=FIXTURE_ARCHIVE,
            inventory_path=FIXTURE_INVENTORY,
        )


def test_signed_bundles_are_not_built_yet(capsys: pytest.CaptureFixture[str]) -> None:
    exit_code = main(
        ["--manifest", str(FIXTURE_MANIFEST), "--image-version", "2026.10.0", "--out", "/tmp/x"]
    )
    assert exit_code == 2
    assert "pass --unsigned" in capsys.readouterr().err


def test_a_command_line_without_bootconfig_is_refused(tmp_path: Path) -> None:
    layout = _layout(tmp_path)
    document = json.loads(layout.read_text(encoding="utf-8"))
    document["cmdline"]["additions"].pop()
    layout.write_text(json.dumps(document), encoding="utf-8")
    with pytest.raises(BundleError, match="lacks the bootconfig token"):
        build_bundle(
            json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8")),
            layout_path=layout,
            reference=None,
            image_version="2026.10.0",
            output_directory=tmp_path / "bundle",
            source=FIXTURE_ARCHIVE,
            inventory_path=FIXTURE_INVENTORY,
        )
