"""Schema, generation, and semantic validation tests for Android image manifests."""

from __future__ import annotations

import hashlib
import json
import re
import struct
import tempfile
import zipfile
from pathlib import Path
from typing import Any

import pytest

from apkrun_image.__main__ import main as package_main
from apkrun_image.inventory import inventory, serialize_inventory
from apkrun_image.manifest import (
    ManifestError,
    _ordered_vbmeta_roles,
    generate_manifest,
    serialize_manifest,
    validate_manifest,
)
from apkrun_image.manifest import (
    main as manifest_main,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures/manifests"
FIXTURE_ARCHIVE = (
    Path(__file__).resolve().parent / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"
)
FIXTURE_INVENTORY = FIXTURE_ROOT / "fixture-inventory.json"
FIXTURE_MANIFEST = FIXTURE_ROOT / "valid/fixture-build.json"
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)
PINNED_INVENTORY = REPOSITORY_ROOT / "Images/manifests/16373615/inventory.json"
PINNED_MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"


def _load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def _write_fetch_metadata(
    archive_path: Path,
    manifest_source: dict[str, object],
) -> None:
    """Attach pinned build metadata to a synthetic archive used as file-check input."""
    fetch_metadata = {
        "schemaVersion": 2,
        "branchProvenance": "caller-asserted",
        "branch": manifest_source["branch"],
        "buildId": manifest_source["buildId"],
        "target": manifest_source["target"],
        "artifacts": [
            {
                "name": archive_path.name,
                "size": archive_path.stat().st_size,
                "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
            }
        ],
    }
    (archive_path.parent / "fetch.json").write_text(
        json.dumps(fetch_metadata),
        encoding="utf-8",
    )


def _python_only_fixtures() -> set[str]:
    path = FIXTURE_ROOT / "invalid/python-only.txt"
    return {
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    }


def _fixture_source_for_m6(manifest: dict[str, object], directory: Path) -> tuple[Path, Path]:
    """Change the synthetic vendor boot header to v3 while preserving the archive files."""
    modified_archive = directory / FIXTURE_ARCHIVE.name
    with zipfile.ZipFile(FIXTURE_ARCHIVE, "r") as original:
        with zipfile.ZipFile(modified_archive, "w", compression=zipfile.ZIP_STORED) as output:
            for item in original.infolist():
                content = original.read(item)
                if item.filename == "vendor_boot.img":
                    mutable = bytearray(content)
                    struct.pack_into("<I", mutable, 8, 3)
                    content = bytes(mutable)
                output.writestr(item, content)

    manifest_source = manifest["source"]
    assert isinstance(manifest_source, dict)
    _write_fetch_metadata(modified_archive, manifest_source)
    modified_inventory = inventory(modified_archive)
    source_archive = manifest_source["archives"][0]
    assert isinstance(source_archive, dict)
    modified_source = modified_inventory["source"]
    source_archive["size"] = modified_source["size"]
    source_archive["sha256"] = modified_source["sha256"]

    vendor_boot = next(
        item for item in manifest["artifacts"] if item["id"] == manifest["roles"]["vendorBoot"]
    )
    inventory_vendor_boot = next(
        item for item in modified_inventory["files"] if item["path"] == vendor_boot["file"]
    )
    vendor_boot["size"] = inventory_vendor_boot["size"]
    vendor_boot["sha256"] = inventory_vendor_boot["sha256"]
    inventory_path = directory / "inventory.json"
    modified_source = modified_inventory["source"]
    manifest_source = manifest["source"]
    assert isinstance(modified_source, dict)
    assert isinstance(manifest_source, dict)
    for field in ("branch", "buildId", "target"):
        modified_source[field] = manifest_source[field]
    inventory_path.write_text(serialize_inventory(modified_inventory), encoding="utf-8")
    return modified_archive, inventory_path


def test_schema_matches_the_reference_copy_byte_for_byte() -> None:
    """The checked-in schema stays identical to the normative reference block."""
    reference = (REPOSITORY_ROOT / "docs/03-reference/android-image-manifest.md").read_text(
        encoding="utf-8"
    )
    match = re.search(r"## 7\. JSON Schema\n.*?```json\n(.*?)\n```", reference, re.S)

    assert match is not None
    checked_in = (
        REPOSITORY_ROOT / "Images/tools/schemas/android-image-manifest.schema.json"
    ).read_text(encoding="utf-8")
    assert checked_in == match.group(1) + "\n"


def test_valid_shared_fixtures_and_committed_manifests_pass() -> None:
    """Every checked-in valid example satisfies the versioned schema and M1–M9."""
    valid_directory = FIXTURE_ROOT / "valid"
    paths = sorted(valid_directory.glob("*.json"))
    paths.extend(sorted(REPOSITORY_ROOT.glob("Images/manifests/*/android-image.json")))

    assert paths
    for path in paths:
        assert validate_manifest(_load_json(path)) == [], path


def test_invalid_manifest_only_fixtures_match_their_expected_messages() -> None:
    """Python and Swift share exact expected messages for all manifest-only checks."""
    python_only = _python_only_fixtures()
    invalid_directory = FIXTURE_ROOT / "invalid"
    for path in sorted(invalid_directory.glob("*.json")):
        if path.name in python_only:
            continue
        expected_path = path.with_suffix(".expected.txt")
        expected = expected_path.read_text(encoding="utf-8").splitlines()

        assert validate_manifest(_load_json(path)) == expected, path.name


def test_manifest_model_round_trips_with_deterministic_json() -> None:
    """A parsed manifest can be serialized and loaded without changing its values."""
    document = _load_json(FIXTURE_MANIFEST)

    assert json.loads(serialize_manifest(document)) == document


def test_schema_diagnostics_escape_invalid_android_info_keys() -> None:
    """Schema diagnostics cannot echo control characters from AndroidInfo keys."""
    manifest = _load_json(FIXTURE_MANIFEST)
    manifest["androidInfo"] = {"x\nINJECTED": "37"}

    failures = validate_manifest(manifest)

    assert len(failures) == 1
    assert "x\\\\nINJECTED" in failures[0]
    assert "\n" not in failures[0]


def test_android_info_key_validation_rejects_trailing_line_feed() -> None:
    """The androidInfo key pattern rejects a trailing line feed."""
    manifest = _load_json(FIXTURE_MANIFEST)
    manifest["androidInfo"] = {"x\n": "37"}

    failures = validate_manifest(manifest)

    assert len(failures) == 1
    assert failures[0].startswith("androidInfo:")
    assert "\n" not in failures[0]


def test_schema_patterns_reject_trailing_linefeeds() -> None:
    """Every anchored manifest pattern requires the actual end of its string."""
    invalid_values: list[tuple[tuple[str | int, ...], str]] = [
        (("source", "branch"), "aosp-android-latest-release\n"),
        (("source", "target"), "aosp_cf_arm64_only_phone-userdebug\n"),
        (("source", "buildId"), "16373615\n"),
        (("source", "archives", 0, "name"), "archive.zip\n"),
        (("source", "archives", 0, "sha256"), f"{'0' * 64}\n"),
        (("android", "release"), "17\n"),
        (("android", "securityPatch"), "2026-09\n"),
        (("architecture",), "arm64\n"),
        (("deviceFamily",), "cuttlefish-phone-arm64\n"),
        (("artifacts", 0, "id"), "boot\n"),
        (("artifacts", 0, "file"), "boot.img\n"),
        (("artifacts", 0, "sha256"), f"{'0' * 64}\n"),
        (("artifacts", 0, "partition"), "boot\n"),
        (("roles", "kernel"), "boot\n"),
        (("logicalPartitions", 0, "name"), "system_a\n"),
        (("blankPartitions", 0, "partition"), "misc\n"),
        (("androidInfo",), "x\n"),
    ]

    for path, value in invalid_values:
        manifest = _load_json(FIXTURE_MANIFEST)
        if path == ("androidInfo",):
            manifest["androidInfo"] = {value: "37"}
        else:
            parent: Any = manifest
            for component in path[:-1]:
                parent = parent[component]
            parent[path[-1]] = value

        failures = validate_manifest(manifest)

        assert failures, path
        assert all("\n" not in failure for failure in failures), path


def test_file_checks_escape_source_directory_inventory_errors(tmp_path: Path) -> None:
    """Inventory errors cannot return path newlines raw."""
    manifest = _load_json(FIXTURE_MANIFEST)
    source = manifest["source"]
    assert isinstance(source, dict)
    source_archives = source["archives"]
    assert isinstance(source_archives, list)
    source_archive = source_archives[0]
    assert isinstance(source_archive, dict)
    source_directory = tmp_path / "source\nINJECTED"
    source_directory.mkdir()
    (source_directory / source_archive["name"]).write_text(
        "this file is not a zip archive",
        encoding="utf-8",
    )

    failures = validate_manifest(
        manifest,
        include_files=True,
        source=source_directory,
        inventory_path=FIXTURE_INVENTORY,
    )

    assert len(failures) == 1
    assert "source\\nINJECTED" in failures[0]
    assert "neither a directory nor a readable zip archive" in failures[0]
    assert "\n" not in failures[0]


def test_generator_matches_the_shared_fixture_manifest() -> None:
    """The draft generator uses inventory metadata and liblp partition contents."""
    inventory_document = _load_json(FIXTURE_INVENTORY)
    generated = generate_manifest(inventory_document, source=FIXTURE_ARCHIVE)

    assert serialize_manifest(generated) == FIXTURE_MANIFEST.read_text(encoding="utf-8")
    assert validate_manifest(generated) == []
    assert {item["name"] for item in generated["logicalPartitions"]} == {"system_a", "vendor_a"}


def test_generator_rejects_missing_fetched_build_provenance(tmp_path: Path) -> None:
    """A standalone archive cannot supply trusted build provenance to a draft."""
    archive_path = tmp_path / FIXTURE_ARCHIVE.name
    archive_path.write_bytes(FIXTURE_ARCHIVE.read_bytes())
    inventory_document = inventory(archive_path)
    source = inventory_document["source"]
    assert isinstance(source, dict)
    source.update(
        {
            "branch": "aosp-android-latest-release",
            "buildId": "16373615",
            "target": "aosp_cf_arm64_only_phone-userdebug",
        }
    )

    with pytest.raises(
        ManifestError,
        match="actual archive inventory is missing complete fetched build metadata",
    ):
        generate_manifest(inventory_document, source=archive_path)


def test_vbmeta_role_order_follows_top_level_descriptor_order() -> None:
    """Chain role order comes from the top-level vbmeta descriptors, not IDs."""
    artifacts = [
        {"file": "vbmeta.img", "id": "vbmeta", "kind": "vbmeta", "partition": "vbmeta"},
        {
            "file": "vbmeta_system.img",
            "id": "vbmeta_system",
            "kind": "vbmeta",
            "partition": "vbmeta_system",
        },
        {
            "file": "vbmeta_vendor.img",
            "id": "vbmeta_vendor",
            "kind": "vbmeta",
            "partition": "vbmeta_vendor",
        },
    ]
    inventory_by_path = {
        "vbmeta.img": {
            "details": {
                "descriptors": [
                    {"partition": "vbmeta_vendor", "type": "chainPartition"},
                    {"partition": "vbmeta_system", "type": "chainPartition"},
                ]
            }
        }
    }

    assert _ordered_vbmeta_roles(artifacts, inventory_by_path) == [
        "vbmeta",
        "vbmeta_vendor",
        "vbmeta_system",
    ]


def test_generator_rejects_stale_inventory_entries() -> None:
    """Draft generation refuses hashes that do not match the inspected source."""
    inventory_document = _load_json(FIXTURE_INVENTORY)
    stale_inventory = json.loads(json.dumps(inventory_document))
    next(item for item in stale_inventory["files"] if item["path"] == "unknown.bin")["sha256"] = (
        "0" * 64
    )

    with pytest.raises(ManifestError, match="file entries do not match the source image set"):
        generate_manifest(stale_inventory, source=FIXTURE_ARCHIVE)


def test_file_backed_fixture_manifest_passes_m4_and_m6_to_m13() -> None:
    """The fixture archive, inventory, AVB chains, and logical partitions agree."""
    failures = validate_manifest(
        _load_json(FIXTURE_MANIFEST),
        include_files=True,
        source=FIXTURE_ARCHIVE,
        inventory_path=FIXTURE_INVENTORY,
    )

    assert failures == []


def test_file_checks_reject_boot_and_init_boot_role_swaps() -> None:
    """File-backed M6 validation binds each boot image role to its header kind."""
    manifest = _load_json(FIXTURE_MANIFEST)
    artifacts = manifest["artifacts"]
    kernel = next(item for item in artifacts if item["id"] == "boot")
    generic_ramdisk = next(item for item in artifacts if item["id"] == "init_boot")
    for field in ("file", "sha256", "size"):
        kernel[field], generic_ramdisk[field] = generic_ramdisk[field], kernel[field]

    failures = validate_manifest(
        manifest,
        include_files=True,
        source=FIXTURE_ARCHIVE,
        inventory_path=FIXTURE_INVENTORY,
    )

    assert (
        "init_boot.img bootKind init_boot does not match roles.kernel (needs boot). "
        "Check the manifest role mapping."
    ) in failures
    assert (
        "boot.img bootKind boot does not match roles.genericRamdisk (needs init_boot). "
        "Check the manifest role mapping."
    ) in failures


def test_file_checks_reject_inventory_archive_fingerprint_mismatch(tmp_path: Path) -> None:
    """The recorded inventory fingerprint must agree with source.archives."""
    recorded_inventory = _load_json(FIXTURE_INVENTORY)
    recorded_inventory["source"]["sha256"] = "0" * 64
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(
        serialize_inventory(recorded_inventory),
        encoding="utf-8",
    )

    failures = validate_manifest(
        _load_json(FIXTURE_MANIFEST),
        include_files=True,
        source=FIXTURE_ARCHIVE,
        inventory_path=inventory_path,
    )

    assert failures == [
        'inventory.json: source archive "aosp_cf_arm64_only_phone-img-fixture.zip" '
        "sha256 does not match source.archives. Re-run inventory or manifest generation."
    ]


@pytest.mark.parametrize(
    ("field", "tampered_value"),
    (
        ("branch", "aosp-another-release"),
        ("buildId", "16373616"),
        ("target", "aosp_cf_arm64_only_tablet-userdebug"),
    ),
)
def test_file_checks_reject_provenance_that_disagrees_with_fetched_archive(
    tmp_path: Path,
    field: str,
    tampered_value: str,
) -> None:
    """Manifest and inventory cannot jointly override the fetched build metadata."""
    manifest = _load_json(FIXTURE_MANIFEST)
    manifest_source = manifest["source"]
    assert isinstance(manifest_source, dict)
    archive_name = manifest_source["archives"][0]["name"]
    assert isinstance(archive_name, str)

    download_dir = tmp_path / "download"
    download_dir.mkdir()
    archive_path = download_dir / archive_name
    archive_path.write_bytes(FIXTURE_ARCHIVE.read_bytes())
    archive_size = archive_path.stat().st_size
    archive_sha256 = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    fetch_metadata = {
        "schemaVersion": 2,
        "branchProvenance": "caller-asserted",
        "branch": manifest_source["branch"],
        "buildId": manifest_source["buildId"],
        "target": manifest_source["target"],
        "artifacts": [
            {
                "name": archive_name,
                "size": archive_size,
                "sha256": archive_sha256,
            }
        ],
    }
    (download_dir / "fetch.json").write_text(
        json.dumps(fetch_metadata),
        encoding="utf-8",
    )

    recorded_inventory = _load_json(FIXTURE_INVENTORY)
    recorded_source = recorded_inventory["source"]
    assert isinstance(recorded_source, dict)
    recorded_source[field] = tampered_value
    manifest_source[field] = tampered_value
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(
        serialize_inventory(recorded_inventory),
        encoding="utf-8",
    )

    failures = validate_manifest(
        manifest,
        include_files=True,
        source=download_dir,
        inventory_path=inventory_path,
    )

    assert failures == [
        f'source.{field} "{tampered_value}" does not match the fetched archive metadata '
        f'"{fetch_metadata[field]}". Re-run inventory or manifest generation.'
    ]


def test_file_checks_reject_joint_provenance_edits_without_fetch_metadata(
    tmp_path: Path,
) -> None:
    """An archive and edited metadata cannot invent build provenance without fetch.json."""
    manifest = _load_json(FIXTURE_MANIFEST)
    manifest_source = manifest["source"]
    assert isinstance(manifest_source, dict)
    manifest_source["branch"] = "aosp-another-release"
    recorded_inventory = _load_json(FIXTURE_INVENTORY)
    recorded_source = recorded_inventory["source"]
    assert isinstance(recorded_source, dict)
    recorded_source["branch"] = "aosp-another-release"
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(
        serialize_inventory(recorded_inventory),
        encoding="utf-8",
    )
    archive_path = tmp_path / FIXTURE_ARCHIVE.name
    archive_path.write_bytes(FIXTURE_ARCHIVE.read_bytes())

    failures = validate_manifest(
        manifest,
        include_files=True,
        source=archive_path,
        inventory_path=inventory_path,
    )

    assert failures == [
        "source: actual archive inventory is missing complete fetched build metadata "
        "(branch, buildId, target). Pass the fetched download directory or create a "
        "valid fetch.json."
    ]


def test_file_checks_escape_control_characters_in_inventory_provenance(
    tmp_path: Path,
) -> None:
    """Untrusted inventory source values cannot forge diagnostic lines."""
    recorded_inventory = _load_json(FIXTURE_INVENTORY)
    recorded_source = recorded_inventory["source"]
    assert isinstance(recorded_source, dict)
    recorded_source["branch"] = "bad\nINJECTED"
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(
        serialize_inventory(recorded_inventory),
        encoding="utf-8",
    )

    failures = validate_manifest(
        _load_json(FIXTURE_MANIFEST),
        include_files=True,
        source=FIXTURE_ARCHIVE,
        inventory_path=inventory_path,
    )

    assert failures == [
        'source.branch "aosp-android-latest-release" does not match inventory.json '
        'source.branch "bad\\nINJECTED". Re-run manifest generation.'
    ]


def test_file_checks_reject_directory_inventory_for_archive_manifest(tmp_path: Path) -> None:
    """Directory metadata cannot replace the declared archive provenance."""
    recorded_inventory = _load_json(FIXTURE_INVENTORY)
    source = recorded_inventory["source"]
    assert isinstance(source, dict)
    source["type"] = "directory"
    source.pop("name")
    source.pop("size")
    source.pop("sha256")
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(
        serialize_inventory(recorded_inventory),
        encoding="utf-8",
    )

    failures = validate_manifest(
        _load_json(FIXTURE_MANIFEST),
        include_files=True,
        source=FIXTURE_ARCHIVE,
        inventory_path=inventory_path,
    )

    assert failures == [
        'inventory.json: source type must be "zip" to match source.archives. '
        "Re-run inventory on the fetched archive."
    ]


def test_file_checks_reject_vbmeta_roles_out_of_descriptor_order() -> None:
    """A file-backed manifest must preserve the top-level chain descriptor order."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")
    manifest = _load_json(PINNED_MANIFEST)
    vbmeta_roles = manifest["roles"]["vbmeta"]
    if len(vbmeta_roles) < 3:
        pytest.skip("pinned Cuttlefish build has fewer than two chained vbmeta images")
    vbmeta_roles[1:] = reversed(vbmeta_roles[1:])

    failures = validate_manifest(
        manifest,
        include_files=True,
        source=PINNED_ARCHIVE,
        inventory_path=PINNED_INVENTORY,
    )

    assert len(failures) == 1
    assert failures[0].startswith("roles.vbmeta order ")
    assert "does not match top-level chain descriptor order" in failures[0]


def test_file_checks_reject_source_vbmeta_omitted_from_manifest_and_roles(
    tmp_path: Path,
) -> None:
    """Every source vbmeta image must survive manifest and chain selection."""
    manifest = _load_json(FIXTURE_MANIFEST)
    modified_archive = tmp_path / FIXTURE_ARCHIVE.name
    with zipfile.ZipFile(FIXTURE_ARCHIVE, "r") as original:
        with zipfile.ZipFile(modified_archive, "w", compression=zipfile.ZIP_STORED) as output:
            for item in original.infolist():
                output.writestr(item, original.read(item))
            output.writestr("vbmeta_unlisted.img", b"AVB0" + bytes(252))

    manifest_source = manifest["source"]
    assert isinstance(manifest_source, dict)
    _write_fetch_metadata(modified_archive, manifest_source)
    modified_inventory = inventory(modified_archive)
    archive_declarations = manifest_source["archives"]
    assert isinstance(archive_declarations, list)
    archive_declaration = archive_declarations[0]
    assert isinstance(archive_declaration, dict)
    inventory_source = modified_inventory["source"]
    assert isinstance(inventory_source, dict)
    for field in ("branch", "buildId", "target"):
        inventory_source[field] = manifest_source[field]
    archive_declaration["size"] = inventory_source["size"]
    archive_declaration["sha256"] = inventory_source["sha256"]
    inventory_path = tmp_path / "inventory.json"
    inventory_path.write_text(serialize_inventory(modified_inventory), encoding="utf-8")

    assert validate_manifest(
        manifest,
        include_files=True,
        source=modified_archive,
        inventory_path=inventory_path,
    ) == [
        'inventory.json: vbmeta file "vbmeta_unlisted.img" is missing from artifacts and '
        "roles.vbmeta. Regenerate the manifest."
    ]


def test_python_only_invalid_fixtures_match_file_check_messages() -> None:
    """File-dependent checks compare the manifest against the inspected archive."""
    invalid_directory = FIXTURE_ROOT / "invalid"
    names = _python_only_fixtures()
    assert names
    for name in sorted(names):
        manifest = _load_json(invalid_directory / name)
        source = FIXTURE_ARCHIVE
        inventory_path = FIXTURE_INVENTORY
        if name == "m6-vendor-boot-v3.json":
            temporary_directory = tempfile.TemporaryDirectory()
            try:
                source, inventory_path = _fixture_source_for_m6(
                    manifest,
                    Path(temporary_directory.name),
                )
                expected = (
                    (invalid_directory / Path(name).with_suffix(".expected.txt"))
                    .read_text(encoding="utf-8")
                    .splitlines()
                )
                assert (
                    validate_manifest(
                        manifest,
                        include_files=True,
                        source=source,
                        inventory_path=inventory_path,
                    )
                    == expected
                ), name
            finally:
                temporary_directory.cleanup()
            continue
        expected = (
            (invalid_directory / Path(name).with_suffix(".expected.txt"))
            .read_text(encoding="utf-8")
            .splitlines()
        )

        assert (
            validate_manifest(
                manifest,
                include_files=True,
                source=source,
                inventory_path=inventory_path,
            )
            == expected
        ), name


def test_pinned_manifest_generation_matches_the_committed_file() -> None:
    """The pinned build draft is deterministic and includes every non-empty partition."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")
    generated = generate_manifest(_load_json(PINNED_INVENTORY), source=PINNED_ARCHIVE)
    committed = _load_json(PINNED_MANIFEST)

    assert generated == committed
    assert "system_b" in {item["name"] for item in generated["logicalPartitions"]}
    assert len(generated["logicalPartitions"]) == 9


def test_pinned_manifest_passes_file_checks_against_the_real_archive() -> None:
    """T1 verifies the manifest, inventory, and actual build 16373615 archive."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")

    assert (
        validate_manifest(
            _load_json(PINNED_MANIFEST),
            include_files=True,
            source=PINNED_ARCHIVE,
            inventory_path=PINNED_INVENTORY,
        )
        == []
    )


def test_package_help_lists_manifest_command(capsys: pytest.CaptureFixture[str]) -> None:
    """The top-level Python command exposes the manifest subcommand."""
    assert package_main(["--help"]) == 0
    assert "manifest" in capsys.readouterr().out


def test_manifest_command_generates_and_checks_a_fixture(
    tmp_path: Path,
) -> None:
    """The documented CLI writes a draft and checks the same source files."""
    output_path = tmp_path / "android-image.json"
    assert (
        manifest_main(
            [
                "--inventory",
                str(FIXTURE_INVENTORY),
                "--source",
                str(FIXTURE_ARCHIVE),
                "--out",
                str(output_path),
            ]
        )
        == 0
    )
    assert (
        manifest_main(
            [
                "--check",
                str(output_path),
                "--inventory",
                str(FIXTURE_INVENTORY),
                "--source",
                str(FIXTURE_ARCHIVE),
            ]
        )
        == 0
    )
