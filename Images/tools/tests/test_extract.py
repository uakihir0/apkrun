"""End-to-end tests for manifest-driven Android boot artifact extraction."""

from __future__ import annotations

import hashlib
import json
import shutil
from dataclasses import replace
from pathlib import Path
from typing import BinaryIO
from zipfile import ZipFile

import pytest

import apkrun_image.extract as extract_module
from apkrun_image.bootimg import VendorBootImage
from apkrun_image.extract import ExtractError, extract_images, main

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)
PINNED_LAYOUT = REPOSITORY_ROOT / "Images/tools/layouts/cuttlefish-phone-arm64.json"
FIXTURE_ROOT = Path(__file__).parent / "fixtures/manifests"
FIXTURE_ARCHIVE = Path(__file__).parent / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"
FIXTURE_FETCH_METADATA = Path(__file__).parent / "fixtures/images/fetch.json"
FIXTURE_INVENTORY = FIXTURE_ROOT / "fixture-inventory.json"
FIXTURE_MANIFEST = FIXTURE_ROOT / "valid/fixture-build.json"


def _fixture_manifest() -> dict[str, object]:
    """Load the checked-in manifest fixture as a mutable test document."""
    value = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def _layout(path: Path, additions: list[dict[str, str]] | None = None) -> Path:
    """Write a minimal layout with documented, reviewable command-line values."""
    console_addition = {
        "comment": "Cuttlefish guest console on the virtio console device.",
        "value": "console=hvc0",
    }
    path.write_text(
        json.dumps(
            {
                "cmdline": {
                    "additions": [
                        console_addition,
                        *(
                            additions
                            if additions is not None
                            else [
                                {
                                    "comment": "Fixture-only command-line marker.",
                                    "value": "apkrun.test=enabled",
                                }
                            ]
                        ),
                    ]
                },
                "deviceFamily": "cuttlefish-phone-arm64",
            }
        ),
        encoding="utf-8",
    )
    return path


def _sha256(path: Path) -> str:
    """Hash a file without relying on external tools."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_extract(
    output: Path,
    layout: Path,
    *,
    manifest: dict[str, object] | None = None,
    source: Path = FIXTURE_ARCHIVE,
) -> dict[str, object]:
    """Run extraction against the checked-in fixture source and inventory."""
    return extract_images(
        _fixture_manifest() if manifest is None else manifest,
        output_directory=output,
        layout_path=layout,
        source=source,
        inventory_path=FIXTURE_INVENTORY,
    )


def test_extract_outputs_expected_bytes_hashes_and_reproducible_metadata(
    tmp_path: Path,
) -> None:
    """Extraction follows manifest roles, excludes recovery, and is deterministic."""
    layout = _layout(tmp_path / "layout.json")
    first_output = tmp_path / "first"
    source_hash = _sha256(FIXTURE_ARCHIVE)

    first_metadata = _run_extract(first_output, layout)

    with ZipFile(FIXTURE_ARCHIVE) as archive:
        boot_image = archive.read("boot.img")
    expected_kernel = boot_image[4096:8192]
    expected_ramdisk = (
        b"platform fragment\n" + b"dlkm fragment\n" + b"APKRun synthetic generic ramdisk\n"
    )
    expected = {
        "kernel": expected_kernel,
        "ramdisk.img": expected_ramdisk,
        "vendor-bootconfig.txt": b"androidboot.hardware=cutf_cvm\n",
        "cmdline.txt": (
            b"console=hvc0 panic=-1 console=hvc0 panic=-1 console=hvc0 apkrun.test=enabled"
        ),
        "dtb": b"",
    }

    assert {name: (first_output / name).read_bytes() for name in expected} == expected
    assert first_metadata["cmdlineLength"] == len(expected["cmdline.txt"])
    assert first_metadata["outputs"] == {
        name: {"sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}
        for name, content in expected.items()
    }
    fragments = first_metadata["ramdiskFragments"]
    assert isinstance(fragments, list)
    assert [(item["name"], item["included"]) for item in fragments] == [
        ("platform", True),
        ("recovery", False),
        ("dlkm", True),
    ]
    assert (first_output / "extraction.json").read_text(encoding="utf-8") == (
        json.dumps(first_metadata, ensure_ascii=True, sort_keys=True, indent=2) + "\n"
    )
    assert _sha256(FIXTURE_ARCHIVE) == source_hash

    second_output = tmp_path / "second"
    second_metadata = _run_extract(second_output, layout)

    assert second_metadata == first_metadata
    assert {path.name: path.read_bytes() for path in first_output.iterdir()} == {
        path.name: path.read_bytes() for path in second_output.iterdir()
    }


def test_extract_rejects_androidboot_command_line_additions(tmp_path: Path) -> None:
    """Android boot keys must be carried by bootconfig, not the kernel cmdline."""
    layout = _layout(
        tmp_path / "layout.json",
        [{"comment": "Invalid test value.", "value": "androidboot.hardware=test"}],
    )

    with pytest.raises(ExtractError, match=r"Move Android boot keys to bootconfig"):
        _run_extract(tmp_path / "output", layout)

    assert not (tmp_path / "output").exists()


def test_extract_rejects_command_line_over_2048_bytes(tmp_path: Path) -> None:
    """The kernel command line limit counts encoded ASCII bytes."""
    layout = _layout(
        tmp_path / "layout.json",
        [{"comment": "ASCII byte boundary test.", "value": "x" * 2000}],
    )

    with pytest.raises(ExtractError, match="over the 2048-byte limit"):
        _run_extract(tmp_path / "output", layout)


def test_extract_accepts_command_line_at_2048_byte_limit(tmp_path: Path) -> None:
    """An ASCII command line at the documented byte limit is accepted."""
    prefix_layout = _layout(
        tmp_path / "prefix-layout.json",
        [{"comment": "Prefix marker.", "value": "x"}],
    )
    prefix_output = tmp_path / "prefix"
    _run_extract(prefix_output, prefix_layout)
    prefix = (prefix_output / "cmdline.txt").read_bytes()[:-1]
    boundary_value = "x" * (2048 - len(prefix))

    layout = _layout(
        tmp_path / "boundary-layout.json",
        [{"comment": "Exact command-line limit.", "value": boundary_value}],
    )
    output = tmp_path / "boundary"
    metadata = _run_extract(output, layout)

    assert metadata["cmdlineLength"] == 2048
    assert len((output / "cmdline.txt").read_bytes()) == 2048


def test_extract_rejects_non_ascii_source_command_line(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """UTF-8 source headers cannot produce a VM-invalid command line."""
    layout = _layout(tmp_path / "layout.json")
    parse_vendor_boot_image = extract_module.parse_vendor_boot_image

    def parse_with_non_ascii_command_line(
        stream: BinaryIO,
        image_size: int,
    ) -> VendorBootImage:
        image = parse_vendor_boot_image(stream, image_size)
        return replace(image, cmdline="console=hvc0 café")

    monkeypatch.setattr(
        extract_module,
        "parse_vendor_boot_image",
        parse_with_non_ascii_command_line,
    )

    with pytest.raises(ExtractError, match="non-ASCII or non-printable"):
        _run_extract(tmp_path / "output", layout)

    assert not (tmp_path / "output").exists()


@pytest.mark.parametrize(
    ("addition", "message"),
    (
        ({"comment": "Missing value."}, "must be one non-empty argument"),
        ({"comment": "Whitespace.", "value": "two words"}, "one non-empty argument"),
        (
            {"comment": "NUL prefix.", "value": "\x00androidboot.hardware=test"},
            "one non-empty argument",
        ),
        (
            {"comment": "Non-ASCII.", "value": "café"},
            "printable ASCII argument",
        ),
        ({"value": "apkrun.test=value"}, "needs a non-empty comment"),
    ),
)
def test_extract_rejects_invalid_layout_additions(
    tmp_path: Path,
    addition: dict[str, str],
    message: str,
) -> None:
    """Layout additions require a single argument and an auditable comment."""
    layout = _layout(tmp_path / "layout.json", [addition])

    with pytest.raises(ExtractError, match=message):
        _run_extract(tmp_path / "output", layout)


def test_extract_rejects_layout_for_another_device_family(tmp_path: Path) -> None:
    """The layout family must match the manifest family."""
    layout = _layout(tmp_path / "layout.json")
    layout.write_text(
        json.dumps(
            {
                "cmdline": {"additions": []},
                "deviceFamily": "another-device",
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ExtractError, match="does not match manifest deviceFamily"):
        _run_extract(tmp_path / "output", layout)


def test_extract_requires_documented_cuttlefish_console_addition(tmp_path: Path) -> None:
    """The layout's first command-line addition keeps the guest console available."""
    layout = _layout(
        tmp_path / "layout.json",
        [{"comment": "Marker.", "value": "apkrun.test=enabled"}],
    )
    document = json.loads(layout.read_text(encoding="utf-8"))
    document["cmdline"]["additions"].pop(0)
    layout.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(ExtractError, match="must start with console=hvc0"):
        _run_extract(tmp_path / "output", layout)


def test_extract_rejects_output_inside_source_directory(tmp_path: Path) -> None:
    """Extraction cannot overwrite or contaminate a directory used as input."""
    source_directory = tmp_path / "source"
    source_directory.mkdir()
    shutil.copyfile(FIXTURE_ARCHIVE, source_directory / FIXTURE_ARCHIVE.name)
    shutil.copyfile(FIXTURE_FETCH_METADATA, source_directory / "fetch.json")
    layout = _layout(tmp_path / "layout.json")

    with pytest.raises(ExtractError, match="outside the source image directory"):
        _run_extract(
            tmp_path / "source" / "output",
            layout,
            source=source_directory,
        )


def test_locate_artifact_deduplicates_fetch_directory_source(tmp_path: Path) -> None:
    """A fetch directory listed twice as source does not look ambiguous."""
    image_directory = tmp_path / "download"
    image_directory.mkdir()
    (image_directory / "fetch.json").write_text("{}", encoding="utf-8")
    (image_directory / "kernel.img").write_bytes(b"fixture")

    assert extract_module._locate_artifact_source(
        image_directory,
        [image_directory],
        {"file": "kernel.img", "size": 7},
    ) == (image_directory, False)


def test_extract_rejects_input_archive_hash_mismatch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """M4 validation prevents extraction when a source archive changed."""
    source = tmp_path / FIXTURE_ARCHIVE.name
    shutil.copyfile(FIXTURE_ARCHIVE, source)
    shutil.copyfile(FIXTURE_FETCH_METADATA, tmp_path / "fetch.json")
    layout = _layout(tmp_path / "layout.json")
    validate_manifest = extract_module.validate_manifest
    calls = 0

    def validate_then_mutate(*args: object, **kwargs: object) -> list[str]:
        nonlocal calls
        calls += 1
        failures = validate_manifest(*args, **kwargs)
        if calls == 1 and not failures:
            changed = bytearray(source.read_bytes())
            changed[50] ^= 1
            source.write_bytes(changed)
        return failures

    monkeypatch.setattr(extract_module, "validate_manifest", validate_then_mutate)

    with pytest.raises(ExtractError, match="SHA-256"):
        _run_extract(tmp_path / "output", layout, source=source)

    assert calls == 1
    assert not (tmp_path / "output").exists()


def test_extract_cli_reports_failure_without_traceback(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The command wrapper turns a missing layout into an actionable error."""
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(FIXTURE_MANIFEST.read_text(encoding="utf-8"), encoding="utf-8")

    result = main(
        [
            "--manifest",
            str(manifest_path),
            "--source",
            str(FIXTURE_ARCHIVE),
            "--inventory",
            str(FIXTURE_INVENTORY),
            "--layout",
            str(tmp_path / "missing-layout.json"),
            "--out",
            str(tmp_path / "output"),
        ]
    )

    assert result == 2
    assert "layout" in capsys.readouterr().err
    assert not (tmp_path / "output").exists()


def test_extract_cli_reports_invalid_utf8_layout_without_traceback(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Invalidly encoded JSON input stays on the normal CLI error path."""
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(FIXTURE_MANIFEST.read_text(encoding="utf-8"), encoding="utf-8")
    layout_path = tmp_path / "layout.json"
    layout_path.write_bytes(b"\xff")

    result = main(
        [
            "--manifest",
            str(manifest_path),
            "--source",
            str(FIXTURE_ARCHIVE),
            "--inventory",
            str(FIXTURE_INVENTORY),
            "--layout",
            str(layout_path),
            "--out",
            str(tmp_path / "output"),
        ]
    )

    error = capsys.readouterr().err
    assert result == 2
    assert "not valid UTF-8" in error
    assert "Traceback" not in error
    assert not (tmp_path / "output").exists()


def test_extract_rolls_back_previous_outputs_when_publish_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A mid-publish error restores the prior complete output set."""
    output = tmp_path / "output"
    output.mkdir()
    previous = {
        name: f"previous:{name}".encode()
        for name in (*extract_module.OUTPUT_FILES, "extraction.json")
    }
    for name, content in previous.items():
        (output / name).write_bytes(content)
    (output / "unrelated.txt").write_text("preserve", encoding="utf-8")
    layout = _layout(tmp_path / "layout.json")
    replace = extract_module.os.replace

    def fail_on_command_line_publish(source: str | Path, destination: str | Path) -> None:
        source_path = Path(source)
        destination_path = Path(destination)
        if (
            source_path.name == "cmdline.txt"
            and source_path.parent.name.startswith(".output.extract-")
            and destination_path == output / "cmdline.txt"
        ):
            raise OSError("injected publish failure")
        replace(source, destination)

    monkeypatch.setattr(extract_module.os, "replace", fail_on_command_line_publish)

    with pytest.raises(ExtractError, match="injected publish failure"):
        _run_extract(output, layout)

    assert {name: (output / name).read_bytes() for name in previous} == previous
    assert (output / "unrelated.txt").read_text(encoding="utf-8") == "preserve"
    assert not list(output.glob(".apkrun-extract-previous-*"))


@pytest.mark.skipif(
    not PINNED_ARCHIVE.is_file(),
    reason="the pinned Android archive is optional in a clean checkout",
)
def test_real_archive_extraction_uses_committed_default_layout(tmp_path: Path) -> None:
    """The default CLI layout extracts the pinned boot artifacts without overrides."""
    manifest_path = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"
    inventory_path = REPOSITORY_ROOT / "Images/manifests/16373615/inventory.json"
    output = tmp_path / "real-build"
    assert PINNED_LAYOUT.is_file()
    result = main(
        [
            "--manifest",
            str(manifest_path),
            "--source",
            str(PINNED_ARCHIVE),
            "--inventory",
            str(inventory_path),
            "--out",
            str(output),
        ]
    )

    assert result == 0
    expected_outputs = {
        "cmdline.txt",
        "dtb",
        "extraction.json",
        "kernel",
        "ramdisk.img",
        "vendor-bootconfig.txt",
    }
    assert {path.name for path in output.iterdir()} == expected_outputs
    assert len((output / "kernel").read_bytes()) == 42_031_616
    assert (output / "cmdline.txt").read_text(encoding="utf-8") == (
        "printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 binder.impl=rust cma=0 "
        "firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig "
        "console=hvc0"
    )
    metadata = json.loads((output / "extraction.json").read_text(encoding="utf-8"))
    assert metadata["kernel"]["compression"] == "none"
    assert metadata["cmdlineLength"] == 157
    for name, details in metadata["outputs"].items():
        assert (output / name).stat().st_size == details["size"]
        assert _sha256(output / name) == details["sha256"]
