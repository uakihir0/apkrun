"""Tests for `bundle` (#012, #065; android-image.md §10; runtime-image-manifest.md §3, §6, §7)."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

import pytest

import apkrun_image.bundle as bundle_module
from apkrun_image.bootconfig import parse_bootconfig_text
from apkrun_image.bundle import BundleError, build_bundle, main
from apkrun_image.runtime_manifest import validate
from apkrun_image.sign import decode_public_key, key_id_of, parse_signature, verify_signature

TESTS = Path(__file__).parent
REPOSITORY_ROOT = TESTS.parents[2]
FIXTURE_ARCHIVE = TESTS / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"
FIXTURE_MANIFEST = TESTS / "fixtures/manifests/valid/fixture-build.json"
FIXTURE_INVENTORY = TESTS / "fixtures/manifests/fixture-inventory.json"
PINNED_LAYOUT = REPOSITORY_ROOT / "Images/tools/layouts/cuttlefish-phone-arm64.json"
TEST_KEY = REPOSITORY_ROOT / "Tests/Fixtures/signing/test-image-ed25519"
TEST_PUBLIC_KEY = REPOSITORY_ROOT / "Tests/Fixtures/signing/test-image-ed25519.pub"
# Layouts are written under build/, which is git-ignored and not a symlink. Images/work
# is a symlink in a worktree, and the layout must resolve inside the repository.
LAYOUT_DIRECTORY = REPOSITORY_ROOT / "build/apkrun-image-tests"


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
    directory = LAYOUT_DIRECTORY
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{tmp_path.name}.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


# The fixture kernel is 4 KiB of zeros with the arm64 magic, and its header flags
# declare no page size. Real kernels declare one (the stock build declares 4 KiB),
# so the tests record the page size the fixture stands for. The refusal is tested
# below with the real extraction.
REAL_EXTRACT_IMAGES = bundle_module.extract_images


@pytest.fixture(autouse=True)
def _fixture_kernel_declares_4k_pages(monkeypatch: pytest.MonkeyPatch) -> None:
    def declare_page_size(
        document: Mapping[str, Any], *, output_directory: Path, **options: Path | None
    ) -> dict[str, object]:
        result = REAL_EXTRACT_IMAGES(document, output_directory=output_directory, **options)
        path = output_directory / "extraction.json"
        extraction = json.loads(path.read_text(encoding="utf-8"))
        extraction["kernel"]["pageSize"] = 4096
        path.write_text(json.dumps(extraction), encoding="utf-8")
        return result

    monkeypatch.setattr(bundle_module, "extract_images", declare_page_size)


@pytest.fixture(autouse=True)
def _remove_test_layouts(tmp_path: Path) -> Iterator[None]:
    yield
    (LAYOUT_DIRECTORY / f"{tmp_path.name}.json").unlink(missing_ok=True)


def _build(tmp_path: Path, output: Path) -> dict[str, Any]:
    return build_bundle(
        json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8")),
        layout_path=_layout(tmp_path),
        reference=None,
        image_version="2026.10.0",
        output_directory=output,
        source=FIXTURE_ARCHIVE,
        inventory_path=FIXTURE_INVENTORY,
        sign_key=TEST_KEY,
    )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_signed_bundle_has_the_documented_tree_and_manifest(tmp_path: Path) -> None:
    output = tmp_path / "bundle"
    manifest = _build(tmp_path, output)

    files = sorted(
        path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()
    )
    assert files == [
        "SHA256SUMS",
        "boot/bootconfig.txt",
        "boot/cmdline.txt",
        "boot/kernel",
        "boot/ramdisk.img",
        "disks/os.img",
        "manifest.json",
        "manifest.sig",
        "templates/userdata.img",
    ]
    assert manifest["schemaVersion"] == 1
    assert manifest["imageVersion"].startswith("2026.10.0-cf")
    assert manifest["imageVersion"].endswith("-arm64")
    assert manifest["kind"] == "stock"
    assert [entry["path"] for entry in manifest["files"]] == [
        name for name in files if name not in {"manifest.json", "manifest.sig", "SHA256SUMS"}
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
    assert validate(manifest) == []


def test_sha256sums_lists_every_file_in_files_order(tmp_path: Path) -> None:
    output = tmp_path / "bundle"
    manifest = _build(tmp_path, output)
    lines = (output / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    assert lines == [f"{entry['sha256']}  {entry['path']}" for entry in manifest["files"]]


def test_the_signature_verifies_against_the_manifest_bytes(tmp_path: Path) -> None:
    output = tmp_path / "bundle"
    _build(tmp_path, output)
    public_key = decode_public_key(TEST_PUBLIC_KEY.read_text(encoding="ascii"))
    signature_file = (output / "manifest.sig").read_bytes()
    parsed = verify_signature(
        (output / "manifest.json").read_bytes(), signature_file, {key_id_of(public_key): public_key}
    )
    assert parsed.key_id == key_id_of(public_key)
    assert parse_signature(signature_file).key_id == key_id_of(public_key)


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
    for name in ("manifest.json", "manifest.sig", "SHA256SUMS"):
        assert (tmp_path / "first" / name).read_bytes() == (tmp_path / "second" / name).read_bytes()


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
            sign_key=TEST_KEY,
        )


def test_the_unsigned_flag_is_removed(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as error:
        main(
            [
                "--unsigned",
                "--manifest",
                str(FIXTURE_MANIFEST),
                "--image-version",
                "2026.10.0",
                "--sign-key",
                str(TEST_KEY),
                "--out",
                "/tmp/apkrun-065-unused",
            ]
        )
    assert error.value.code == 2
    assert "unrecognized arguments: --unsigned" in capsys.readouterr().err


def test_a_kernel_that_declares_no_page_size_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(bundle_module, "extract_images", REAL_EXTRACT_IMAGES)
    with pytest.raises(BundleError, match="declares no page size"):
        _build(tmp_path, tmp_path / "bundle")


def test_a_missing_signing_key_says_how_to_make_one(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    exit_code = main(
        [
            "--manifest",
            str(FIXTURE_MANIFEST),
            "--image-version",
            "2026.10.0",
            "--sign-key",
            str(tmp_path / "missing-key"),
            "--out",
            str(tmp_path / "bundle"),
        ]
    )
    assert exit_code == 2
    assert "keygen" in capsys.readouterr().err


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
            sign_key=TEST_KEY,
        )
