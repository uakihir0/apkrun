"""Tests for `bundle` (#13, #66; android-image.md §10; runtime-image-manifest.md §3, §6, §7)."""

from __future__ import annotations

import hashlib
import json
import zipfile
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

import pytest

import apkrun_image.bundle as bundle_module
from apkrun_image.bootconfig import (
    BootconfigLayer,
    merge_bootconfig_layers,
    parse_bootconfig_text,
    serialize_bootconfig,
)
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


def _composition_fixture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[Path, dict[str, Any], Path, Path]:
    directory = tmp_path / "composition"
    directory.mkdir()
    repository = tmp_path / "repository"
    manifest_path = repository / FIXTURE_MANIFEST.relative_to(REPOSITORY_ROOT)
    manifest_path.parent.mkdir(parents=True)
    manifest_path.write_bytes(FIXTURE_MANIFEST.read_bytes())
    compose_path = repository / "Guest/product/compose.json"
    compose_path.parent.mkdir(parents=True, exist_ok=True)
    compose_path.write_bytes(b'{"product":"test"}\n')
    metadata_path = repository / bundle_module.GUEST_AGENT_METADATA
    metadata_path.parent.mkdir(parents=True)
    metadata_path.write_text(
        '{"packageName":"io.apkrun.guest","versionCode":1000,"versionName":"0.1.0"}\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(bundle_module, "_repository_root", lambda: repository)
    document = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    # The small fixture omits vbmeta_system; reuse its unreferenced EROFS slot.
    next(artifact for artifact in document["artifacts"] if artifact["id"] == "erofs")[
        "partition"
    ] = "vbmeta_system"
    with zipfile.ZipFile(FIXTURE_ARCHIVE) as archive:
        stock_super = archive.read("super.img")
    contents = {
        "super.img": stock_super,
        "vbmeta_system_a.img": b"s" * 4096,
        "vbmeta_a.img": b"v" * 1536,
    }
    for filename, data in contents.items():
        (directory / filename).write_bytes(data)
    record = {
        "schemaVersion": 1,
        "sourceManifest": {
            "path": manifest_path.relative_to(repository).as_posix(),
            "sha256": _sha256(manifest_path),
        },
        "productInputs": [
            {"path": "Guest/product/compose.json", "sha256": _sha256(compose_path)},
            {
                "path": bundle_module.GUEST_AGENT_METADATA,
                "sha256": _sha256(metadata_path),
            },
        ],
        "apkrunRevision": "b" * 40,
        "outputHashes": {
            filename: hashlib.sha256(data).hexdigest() for filename, data in contents.items()
        },
    }
    (directory / "composition.json").write_text(json.dumps(record), encoding="utf-8")
    return directory, document, manifest_path, metadata_path


def _write_test_overlay_sources() -> list[dict[str, str]]:
    repository = bundle_module._repository_root()
    sources = {
        "Tests/Fixtures/AndroidImageProduct/compose.json": b'{"layers":[]}\n',
        "Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc": b"on init\n",
    }
    inputs: list[dict[str, str]] = []
    for relative, contents in sources.items():
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        inputs.append({"path": relative, "sha256": _sha256(path)})
    return inputs


def test_composition_outputs_match_the_recorded_hashes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)

    composition, overrides, agents = bundle_module._composition_inputs(
        directory, document, manifest_path
    )

    assert set(overrides) == {"super", "vbmeta_system", "vbmeta"}
    assert (
        composition["sourceManifest"]["path"]
        == manifest_path.relative_to(bundle_module._repository_root()).as_posix()
    )
    assert agents == [{"package": "io.apkrun.guest", "versionCode": 1000}]


def test_composition_keeps_opt_in_test_overlay_provenance_separate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    record_path = directory / "composition.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["testOverlayInputs"] = _write_test_overlay_sources()
    record_path.write_text(json.dumps(record), encoding="utf-8")

    composition, _overrides, _agents = bundle_module._composition_inputs(
        directory, document, manifest_path
    )

    assert composition["testOverlayInputs"] == record["testOverlayInputs"]
    assert all(item["path"].startswith("Guest/product/") for item in composition["productInputs"])


@pytest.mark.parametrize(
    "test_inputs",
    [
        [{"path": "Guest/product/compose.json", "sha256": "c" * 64}],
        [],
        [
            {
                "path": "Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc",
                "sha256": "d" * 64,
            },
            {
                "path": "Tests/Fixtures/AndroidImageProduct/compose.json",
                "sha256": "c" * 64,
            },
        ],
        [
            {
                "path": "Tests/Fixtures/AndroidImageProduct/compose.json",
                "sha256": "c" * 64,
            },
            {
                "path": "Tests/Fixtures/AndroidImageProduct/compose.json",
                "sha256": "c" * 64,
            },
        ],
    ],
)
def test_composition_rejects_unsafe_or_unsorted_test_overlay_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, test_inputs: list[dict[str, str]]
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    record_path = directory / "composition.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["testOverlayInputs"] = test_inputs
    record_path.write_text(json.dumps(record), encoding="utf-8")

    with pytest.raises(BundleError, match="test overlay input"):
        bundle_module._composition_inputs(directory, document, manifest_path)


@pytest.mark.parametrize(
    ("source_change", "message"),
    [
        ("tampered", "SHA-256 differs from composition test overlay inputs"),
        ("missing", "test overlay provenance source is missing or unsafe"),
    ],
)
def test_composition_rejects_tampered_or_missing_test_overlay_sources(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    source_change: str,
    message: str,
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    inputs = _write_test_overlay_sources()
    record_path = directory / "composition.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["testOverlayInputs"] = inputs
    record_path.write_text(json.dumps(record), encoding="utf-8")

    source = bundle_module._repository_root() / inputs[0]["path"]
    if source_change == "tampered":
        source.write_bytes(b'{"layers":["changed"]}\n')
    else:
        source.unlink()

    with pytest.raises(BundleError, match=message):
        bundle_module._composition_inputs(directory, document, manifest_path)


@pytest.mark.parametrize(
    ("source_change", "message"),
    [
        ("tampered", "SHA-256 differs from composition product inputs"),
        ("missing", "composition product provenance source is missing or unsafe"),
        ("symlink", "product input must not use symlinks"),
    ],
)
def test_composition_rejects_tampered_missing_or_symlinked_product_inputs(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    source_change: str,
    message: str,
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    source = bundle_module._repository_root() / "Guest/product/compose.json"
    if source_change == "tampered":
        source.write_bytes(b'{"product":"changed"}\n')
    elif source_change == "missing":
        source.unlink()
    else:
        outside = tmp_path / "outside-compose.json"
        outside.write_bytes(b'{"product":"test"}\n')
        source.unlink()
        source.symlink_to(outside)

    with pytest.raises(BundleError, match=message):
        bundle_module._composition_inputs(directory, document, manifest_path)


@pytest.mark.parametrize("filename", ["super.img", "vbmeta_system_a.img", "vbmeta_a.img"])
def test_composition_rejects_an_output_changed_after_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, filename: str
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    output = directory / filename
    data = output.read_bytes()
    output.write_bytes(bytes([data[0] ^ 1]) + data[1:])

    with pytest.raises(BundleError, match="SHA-256 differs from the composition record"):
        bundle_module._composition_inputs(directory, document, manifest_path)


def test_composition_requires_hashes_for_exactly_its_output_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    record_path = directory / "composition.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["outputHashes"].pop("vbmeta_a.img")
    record_path.write_text(json.dumps(record), encoding="utf-8")

    with pytest.raises(BundleError, match="output hashes"):
        bundle_module._composition_inputs(directory, document, manifest_path)


def test_composition_rejects_guest_agent_metadata_changed_after_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory, document, manifest_path, metadata_path = _composition_fixture(tmp_path, monkeypatch)
    metadata_path.write_text(
        '{"packageName":"io.apkrun.guest","versionCode":1001,"versionName":"changed"}\n',
        encoding="utf-8",
    )

    with pytest.raises(BundleError, match="SHA-256 differs from composition product inputs"):
        bundle_module._composition_inputs(directory, document, manifest_path)


def test_composition_requires_guest_agent_metadata_input(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory, document, manifest_path, _metadata_path = _composition_fixture(tmp_path, monkeypatch)
    record_path = directory / "composition.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["productInputs"] = [
        item
        for item in record["productInputs"]
        if item["path"] != bundle_module.GUEST_AGENT_METADATA
    ]
    record_path.write_text(json.dumps(record), encoding="utf-8")

    with pytest.raises(BundleError, match="must record .* as a product input"):
        bundle_module._composition_inputs(directory, document, manifest_path)


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


# The drmVirgl values that graphics.md §9 documents: Mesa (EGL and GLES), minigbm (gralloc),
# ranchu (HWC, composer APEX), client composition, the DRM display finder, and GLES 3.0.
# A change here, in the layout, or in the merge changes the documented profile.
DRM_VIRGL_STACK = {
    "androidboot.cpuvulkan.version": "0",
    "androidboot.hardware.egl": "mesa",
    "androidboot.hardware.gralloc": "minigbm",
    "androidboot.hardware.hwcomposer": "ranchu",
    "androidboot.hardware.hwcomposer.display_finder_mode": "drm",
    "androidboot.hardware.hwcomposer.mode": "client",
    "androidboot.opengles.version": "196608",
    "androidboot.vendor.apex.com.android.hardware.graphics.composer": (
        "com.android.hardware.graphics.composer.ranchu"
    ),
}
DRM_VIRGL_GOLDEN = TESTS / "fixtures/gpu-profiles/drm-virgl-bootconfig.txt"


def test_the_drm_virgl_bootconfig_follows_from_the_committed_layout(tmp_path: Path) -> None:
    """#23 criterion 2: the drmVirgl bootconfig is reproducible from the committed layout."""
    output = tmp_path / "bundle"
    manifest = _build(tmp_path, output)

    layout = json.loads(PINNED_LAYOUT.read_text(encoding="utf-8"))
    profile = layout["gpuProfiles"]["drmVirgl"]["bootconfig"]
    assert manifest["gpuProfiles"]["drmVirgl"]["bootconfig"] == profile
    assert {key: profile[key] for key in DRM_VIRGL_STACK} == DRM_VIRGL_STACK

    # The layers of AndroidBootPlanner.prepareBoot, without the platform and instance layers.
    text = (output / "boot/bootconfig.txt").read_text(encoding="ascii")
    vendor_part, image_part = text.split("[image]\n")
    vendor = parse_bootconfig_text(vendor_part.removeprefix("[vendor]\n"), layer_name="vendor")
    image = parse_bootconfig_text(image_part, layer_name="image")
    merged = merge_bootconfig_layers(
        [
            BootconfigLayer("vendor", vendor),
            BootconfigLayer("image", image),
            BootconfigLayer("gpu:drmVirgl", profile),
        ]
    )
    assert serialize_bootconfig(merged) == DRM_VIRGL_GOLDEN.read_bytes()


def test_two_builds_are_identical(tmp_path: Path) -> None:
    first = _build(tmp_path, tmp_path / "first")
    second = _build(tmp_path, tmp_path / "second")
    assert first == second
    for name in ("manifest.json", "manifest.sig", "SHA256SUMS"):
        assert (tmp_path / "first" / name).read_bytes() == (tmp_path / "second" / name).read_bytes()


def test_two_composed_builds_are_byte_identical(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    composition, document, manifest_path, _metadata_path = _composition_fixture(
        tmp_path, monkeypatch
    )
    repository = bundle_module._repository_root()
    repository_layout = repository / "Images/tools/layouts" / f"{tmp_path.name}.json"
    repository_layout.parent.mkdir(parents=True, exist_ok=True)
    layout_document = json.loads(_layout(tmp_path).read_text(encoding="utf-8"))
    layout_document["disks"][0]["partitions"].extend(
        [
            {"label": "vbmeta_system", "source": "vbmeta_system"},
            {"label": "vbmeta", "source": "vbmeta"},
        ]
    )
    repository_layout.write_text(json.dumps(layout_document), encoding="utf-8")
    monkeypatch.setattr(bundle_module, "_tools_revision", lambda: "c" * 40)
    monkeypatch.setattr(bundle_module, "_lock_commit", lambda _name: "d" * 40)

    def build(output: Path) -> dict[str, Any]:
        return build_bundle(
            document,
            layout_path=repository_layout,
            reference=None,
            image_version="2026.10.0",
            output_directory=output,
            source=FIXTURE_ARCHIVE,
            inventory_path=FIXTURE_INVENTORY,
            sign_key=TEST_KEY,
            composition_directory=composition,
            manifest_path=manifest_path,
        )

    first_output = tmp_path / "composed-first"
    second_output = tmp_path / "composed-second"
    first_manifest = build(first_output)
    second_manifest = build(second_output)

    def bundle_tree(directory: Path) -> dict[str, bytes]:
        return {
            path.relative_to(directory).as_posix(): path.read_bytes()
            for path in directory.rglob("*")
            if path.is_file()
        }

    assert first_manifest["kind"] == second_manifest["kind"] == "apkrun"
    assert first_manifest["provenance"]["composition"] == second_manifest["provenance"][
        "composition"
    ]
    assert bundle_tree(first_output) == bundle_tree(second_output)


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
