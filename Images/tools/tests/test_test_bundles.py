"""T0 coverage for the opt-in Android test bundles in test-strategy.md §3.5 (#36)."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from typing import Any

import pytest

import apkrun_image.test_bundles as test_bundles
from apkrun_image.bundle import _checksums, _load_signing_key
from apkrun_image.runtime_manifest import validate
from apkrun_image.sign import (
    decode_public_key,
    key_id_of,
    render_signature,
    verify_signature,
)

REPOSITORY = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).parent / "fixtures/runtime-manifests/valid/apkrun-composed-cf16373615.json"
TEST_KEY = REPOSITORY / "Tests/Fixtures/signing/test-image-ed25519"
TEST_PUBLIC_KEY = REPOSITORY / "Tests/Fixtures/signing/test-image-ed25519.pub"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


@pytest.fixture(autouse=True)
def _plain_file_copies_only(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep T0 tests on regular files; APFS clone and sparse behavior belongs to T1."""
    monkeypatch.setattr(test_bundles, "_try_clonefile", lambda _source, _destination: False)
    monkeypatch.setattr(
        test_bundles,
        "_copy_sparse",
        lambda source, destination: shutil.copyfile(source, destination),
    )


def _resign(bundle: Path, manifest: dict[str, Any]) -> None:
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    (bundle / "manifest.json").write_bytes(manifest_bytes)
    (bundle / "SHA256SUMS").write_text(_checksums(manifest["files"]), encoding="ascii")
    (bundle / "manifest.sig").write_bytes(
        render_signature(manifest_bytes, _load_signing_key(TEST_KEY))
    )


def _base_bundle(tmp_path: Path) -> Path:
    """Create a tiny signed bundle from the committed composed manifest fixture."""
    bundle = tmp_path / "composed"
    bundle.mkdir()
    manifest = json.loads(FIXTURE.read_text(encoding="utf-8"))
    contents = {
        "boot/bootconfig.txt": (
            b'[vendor]\nandroidboot.hardware = "cutf_cvm"\n'
            b'[image]\nandroidboot.slot_suffix = "_a"\n'
        ),
        "boot/cmdline.txt": b"init=/init bootconfig console=hvc0",
        "boot/kernel": b"fixture-kernel",
        "boot/ramdisk.img": b"fixture-ramdisk",
        "disks/os.img": b"o" * (2 * 1024 * 1024),
        "templates/userdata.img": b"u" * (2 * 1024 * 1024),
    }
    for relative, data in contents.items():
        path = bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    entries = [
        {"path": relative, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for relative, data in sorted(contents.items())
    ]
    manifest["files"] = entries
    by_path = {entry["path"]: entry for entry in entries}
    for name in ("kernel", "ramdisk", "bootconfig", "cmdline"):
        relative = manifest["boot"][name]["path"]
        manifest["boot"][name] = dict(by_path[relative])
    disk = manifest["disks"][0]
    disk.update(
        logicalSize=len(contents[disk["path"]]),
        partitions=[
            {
                "firstLBA": 2048,
                "label": "super",
                "sha256": "d" * 64,
                "size": 512 * 1024,
            }
        ],
    )
    template = manifest["templates"][0]
    template.update(
        logicalSize=len(contents[template["path"]]),
        partitions=[
            {
                "firstLBA": 2048,
                "label": "userdata",
                "sha256": "e" * 64,
                "size": 512 * 1024,
            }
        ],
    )
    manifest["provenance"]["composition"]["testOverlayInputs"] = [
        {"path": relative, "sha256": _sha256(REPOSITORY / relative)}
        for relative in test_bundles.TEST_OVERLAY_INPUTS
    ]
    _resign(bundle, manifest)
    assert validate(manifest) == []
    return bundle


def _bundle_tree(bundle: Path) -> dict[str, bytes]:
    return {
        path.relative_to(bundle).as_posix(): path.read_bytes()
        for path in bundle.rglob("*")
        if path.is_file()
    }


def test_builds_all_six_signed_variants_without_changing_the_input(tmp_path: Path) -> None:
    base = _base_bundle(tmp_path)
    before = _bundle_tree(base)
    output = tmp_path / "test-bundles"

    versions = test_bundles.build_test_bundles(
        bundle=base,
        sign_key=TEST_KEY,
        output_directory=output,
    )

    assert list(versions) == ["A", "B", "B-prime", "F", "P", "S"]
    assert _bundle_tree(base) == before
    assert versions["A"] == "2026.10.0-cf16373615-arm64"
    assert len(set(versions.values())) == 6
    assert [versions[name] for name in versions] == sorted(versions.values())

    public_key = decode_public_key(TEST_PUBLIC_KEY.read_text(encoding="ascii"))
    for name, version in versions.items():
        variant = output / name
        manifest_bytes = (variant / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        assert manifest["imageVersion"] == version
        assert validate(manifest) == []
        verify_signature(
            manifest_bytes,
            (variant / "manifest.sig").read_bytes(),
            {key_id_of(public_key): public_key},
        )
        assert (variant / "SHA256SUMS").read_text(encoding="ascii") == _checksums(manifest["files"])
        for entry in manifest["files"]:
            path = variant / entry["path"]
            assert entry == {
                "path": entry["path"],
                "size": path.stat().st_size,
                "sha256": _sha256(path),
            }

    bootconfig = {
        name: (output / name / "boot/bootconfig.txt").read_text(encoding="ascii")
        for name in ("A", "B", "B-prime", "F", "S")
    }
    assert 'androidboot.apkrun.test.marker = "B"' not in bootconfig["A"]
    assert 'androidboot.apkrun.test.marker = "B"' in bootconfig["B"]
    assert 'androidboot.apkrun.test.marker = "B"' in bootconfig["B-prime"]
    assert 'androidboot.apkrun.test.fail_health = "1"' in bootconfig["B-prime"]
    assert 'androidboot.apkrun.test.fail_boot = "1"' in bootconfig["F"]
    assert 'androidboot.apkrun.test.secret = "1"' in bootconfig["S"]
    assert "init=/apkrun-test-missing" in (output / "P/boot/cmdline.txt").read_text(
        encoding="ascii"
    ).split(" ")
    assert "androidboot.apkrun.test." not in (output / "A/boot/bootconfig.txt").read_text(
        encoding="ascii"
    )


def test_refuses_stock_and_uncomposed_bundles_before_creating_output(tmp_path: Path) -> None:
    composed = _base_bundle(tmp_path)
    stock = tmp_path / "stock"
    shutil.copytree(composed, stock)
    manifest = json.loads((stock / "manifest.json").read_text(encoding="utf-8"))
    manifest["kind"] = "stock"
    manifest["provenance"].pop("composition")
    manifest["provenance"]["revisions"]["guest"] = None
    manifest["requirements"]["agents"] = []
    _resign(stock, manifest)
    assert validate(manifest) == []
    with pytest.raises(test_bundles.TestBundleError, match="kind: apkrun"):
        test_bundles.build_test_bundles(
            bundle=stock, sign_key=TEST_KEY, output_directory=tmp_path / "stock-output"
        )

    builder = tmp_path / "builder"
    shutil.copytree(stock, builder)
    manifest = json.loads((builder / "manifest.json").read_text(encoding="utf-8"))
    manifest["kind"] = "apkrun"
    manifest["provenance"]["source"].update(
        origin="apkrun-builder",
        buildId="ar000123",
    )
    manifest["imageVersion"] = "2026.10.0-ar000123-arm64"
    manifest["provenance"]["revisions"]["guest"] = "a" * 40
    manifest["provenance"]["pinnedManifestSHA256"] = "b" * 64
    manifest["provenance"]["builderImageDigest"] = "sha256:" + "c" * 64
    manifest["requirements"]["agents"] = [{"package": "io.apkrun.guest", "versionCode": 1000}]
    _resign(builder, manifest)
    assert validate(manifest) == []
    with pytest.raises(test_bundles.TestBundleError, match="provenance.composition"):
        test_bundles.build_test_bundles(
            bundle=builder, sign_key=TEST_KEY, output_directory=tmp_path / "uncomposed-output"
        )
    assert not (tmp_path / "stock-output").exists()
    assert not (tmp_path / "uncomposed-output").exists()


def test_requires_the_current_fixed_test_overlay_provenance(tmp_path: Path) -> None:
    base = _base_bundle(tmp_path)
    manifest = json.loads((base / "manifest.json").read_text(encoding="utf-8"))
    manifest["provenance"]["composition"].pop("testOverlayInputs")
    _resign(base, manifest)

    with pytest.raises(
        test_bundles.TestBundleError,
        match="fixed AndroidImageProduct test overlay",
    ):
        test_bundles.build_test_bundles(
            bundle=base, sign_key=TEST_KEY, output_directory=tmp_path / "missing-overlay"
        )
    assert not (tmp_path / "missing-overlay").exists()


def test_refuses_an_existing_output_without_replacing_it(tmp_path: Path) -> None:
    base = _base_bundle(tmp_path)
    output = tmp_path / "existing"
    output.mkdir()
    marker = output / "preserve-me"
    marker.write_text("untouched", encoding="ascii")

    with pytest.raises(test_bundles.TestBundleError, match="already exists"):
        test_bundles.build_test_bundles(bundle=base, sign_key=TEST_KEY, output_directory=output)
    assert marker.read_text(encoding="ascii") == "untouched"


def test_refuses_a_bad_signature_before_copying_any_files(tmp_path: Path) -> None:
    base = _base_bundle(tmp_path)
    signature = base / "manifest.sig"
    signature.write_bytes(b"invalid\\n")

    with pytest.raises(test_bundles.TestBundleError, match="signature does not verify"):
        test_bundles.build_test_bundles(
            bundle=base, sign_key=TEST_KEY, output_directory=tmp_path / "bad-signature"
        )
    assert not (tmp_path / "bad-signature").exists()
