"""Tests of the refreshed-vbmeta path of bundle-variant (#099, step 4).

The chain digest is checked against an independent computation on small vbmeta images that the
vendored avbtool makes, and the reseal record is checked on small fabricated files. The whole
variant is checked on the real stock bundle, which is not in the suite.
"""

from __future__ import annotations

import hashlib
import io
import json
import struct
from pathlib import Path

import pytest

from apkrun_image import bundle_variant as variant
from apkrun_image import vendor_reseal
from apkrun_image.bundle_variant import BundleVariantError
from apkrun_image.erofs import load_component
from apkrun_image.manifest import _repository_root
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    run_avbtool,
    seal_partition,
    verify_avbtool,
)

FIXTURE_RSA_KEY = _repository_root() / "Tests/Fixtures/signing/test-apkrun-image-fixture-rsa.pem"
FIXTURE_BUILD = "16373615"


def _avbtool() -> Path:
    return verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))


def _blob(data: bytes) -> bytes:
    """The authenticated vbmeta blob at the start of `data` (header, authentication, auxiliary)."""
    authentication, auxiliary = struct.unpack_from(">QQ", data, 12)
    return data[: 256 + authentication + auxiliary]


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_the_chain_digest_is_the_top_blob_then_each_chained_blob(tmp_path: Path) -> None:
    avbtool = _avbtool()
    boot = tmp_path / "boot.img"
    boot.write_bytes(bytes(range(256)) * 64)
    run_avbtool(
        avbtool,
        [
            "add_hash_footer",
            "--image",
            str(boot),
            "--partition_size",
            str(128 * 1024),
            "--partition_name",
            "boot",
            "--algorithm",
            "NONE",
        ],
    )
    system = tmp_path / "vbmeta_system.img"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(system),
            "--algorithm",
            "NONE",
            "--padding_size",
            "4096",
        ],
    )
    top = tmp_path / "vbmeta.img"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(top),
            "--algorithm",
            "NONE",
            "--chain_partition",
            f"boot:1:{FIXTURE_RSA_KEY}",
            "--chain_partition",
            f"vbmeta_system:2:{FIXTURE_RSA_KEY}",
            "--padding_size",
            "4096",
        ],
    )
    boot_bytes = boot.read_bytes()
    system_bytes = system.read_bytes()
    top_bytes = top.read_bytes()
    layout = {
        "boot_a": (0, len(boot_bytes)),
        "vbmeta_system_a": (len(boot_bytes), len(system_bytes)),
    }
    values = variant._bootconfig_values(io.BytesIO(boot_bytes + system_bytes), layout, top_bytes)

    # The footer of the boot image names its vbmeta, which is the blob after the image.
    footer = boot_bytes[-64:]
    _magic, _major, _minor, _original, vbmeta_offset, vbmeta_size = struct.unpack_from(
        ">4sIIQQQ", footer
    )
    boot_blob = boot_bytes[vbmeta_offset : vbmeta_offset + vbmeta_size]
    expected_top = _blob(top_bytes)
    expected_system = _blob(system_bytes)
    assert values["androidboot.vbmeta.digest"] == _sha(expected_top + boot_blob + expected_system)
    assert values["androidboot.vbmeta.size"] == str(
        len(expected_top) + len(boot_blob) + len(expected_system)
    )
    # A different order of the chain would give another digest.
    assert values["androidboot.vbmeta.digest"] != _sha(expected_top + expected_system + boot_blob)


def test_a_chained_partition_missing_from_the_layout_is_refused(tmp_path: Path) -> None:
    avbtool = _avbtool()
    system = tmp_path / "vbmeta_system.img"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(system),
            "--algorithm",
            "NONE",
            "--padding_size",
            "4096",
        ],
    )
    top = tmp_path / "vbmeta.img"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(top),
            "--algorithm",
            "NONE",
            "--chain_partition",
            f"vbmeta_system:2:{FIXTURE_RSA_KEY}",
            "--padding_size",
            "4096",
        ],
    )
    with pytest.raises(BundleVariantError, match="has no vbmeta_system_a"):
        variant._bootconfig_values(io.BytesIO(b""), {}, top.read_bytes())


def test_the_bootconfig_values_are_replaced_once_each_and_a_missing_line_is_refused() -> None:
    text = (
        'androidboot.vbmeta.avb_version = "1.4"\n'
        'androidboot.vbmeta.digest = "0011"\n'
        'androidboot.vbmeta.hash_alg = "sha256"\n'
        'androidboot.vbmeta.size = "22912"\n'
        "androidboot.hardware = cuttlefish\n"
    )
    values = {"androidboot.vbmeta.digest": "ab12", "androidboot.vbmeta.size": "21312"}
    new = variant._with_bootconfig_values(text, values)
    assert new.splitlines() == [
        'androidboot.vbmeta.avb_version = "1.4"',
        'androidboot.vbmeta.digest = "ab12"',
        'androidboot.vbmeta.hash_alg = "sha256"',
        'androidboot.vbmeta.size = "21312"',
        "androidboot.hardware = cuttlefish",
    ]
    assert variant._read_bootconfig_values(new, tuple(values)) == values
    with pytest.raises(BundleVariantError, match="0 lines for androidboot.vbmeta.size"):
        variant._with_bootconfig_values('androidboot.vbmeta.digest = "00"\n', values)
    with pytest.raises(BundleVariantError, match="2 lines for androidboot.vbmeta.digest"):
        variant._read_bootconfig_values(text + text, ("androidboot.vbmeta.digest",))


def test_the_bootconfig_newlines_survive_a_value_on_the_last_line_or_before_a_blank_line() -> None:
    values = {"androidboot.vbmeta.size": "21312"}
    last = 'androidboot.hardware = cuttlefish\nandroidboot.vbmeta.size = "22912"\n'
    assert variant._with_bootconfig_values(last, values) == (
        'androidboot.hardware = cuttlefish\nandroidboot.vbmeta.size = "21312"\n'
    )
    blank = 'androidboot.vbmeta.size = "22912"\n\nandroidboot.hardware = cuttlefish\n'
    assert variant._with_bootconfig_values(blank, values) == (
        'androidboot.vbmeta.size = "21312"\n\nandroidboot.hardware = cuttlefish\n'
    )
    no_final_newline = 'androidboot.vbmeta.size = "22912"'
    assert variant._with_bootconfig_values(no_final_newline, values) == (
        'androidboot.vbmeta.size = "21312"'
    )


def _sealed(avbtool: Path, tmp: Path, name: str, seed: str) -> Path:
    """A real sealed partition with the vendored avbtool, small enough for the tests."""
    scratch = tmp / f"seal-{name}"
    scratch.mkdir()
    fs_image = scratch / "fs.img"
    fs_image.write_bytes(hashlib.sha256(seed.encode("utf-8")).digest() * 16384)
    output = tmp / f"{name}.img"
    seal_partition(
        avbtool,
        fs_image,
        output,
        partition_size=1024 * 1024,
        salt="00" * 16,
        scratch=scratch,
    )
    return output


def _vbmeta_for(avbtool: Path, tmp: Path, name: str, vendor: Path) -> Path:
    output = tmp / f"{name}-vbmeta.img"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(output),
            "--algorithm",
            "NONE",
            "--include_descriptors_from_image",
            str(vendor),
            "--padding_size",
            "4096",
        ],
    )
    return output


def _reseal_fixture(tmp_path: Path, **changes: object) -> tuple[Path, Path, Path, dict]:
    """Make an inject output and a reseal output that agree, and return them with the reseal record.

    `changes` replaces a field of the reseal record, named with dots (for example
    "stock.vendorSha256"). The images are real: the vendored avbtool seals the vendor and makes
    the vbmeta that carries its descriptor.
    """
    avbtool = _avbtool()
    inject = tmp_path / "inject"
    inject.mkdir()
    reseal = tmp_path / "reseal"
    reseal.mkdir()
    stock_vendor = _sealed(avbtool, tmp_path, "stock", "stock")
    injected = _sealed(avbtool, tmp_path, "injected", "injected")
    (inject / "vendor_a.img").write_bytes(injected.read_bytes())
    (reseal / "vendor_a.img").write_bytes(injected.read_bytes())
    vbmeta = _vbmeta_for(avbtool, tmp_path, "reseal", reseal / "vendor_a.img")
    (reseal / "vbmeta_a.img").write_bytes(vbmeta.read_bytes())
    descriptor = vendor_reseal.vendor_tree(
        run_avbtool(avbtool, ["info_image", "--image", str(reseal / "vendor_a.img")]),
        "the test vendor",
    )
    record = {
        "task": "#099",
        "schemaVersion": 1,
        "partition": {"name": "vendor_a", "verityName": "vendor", "size": injected.stat().st_size},
        "injected": {"sha256": _sha(injected.read_bytes()), "size": injected.stat().st_size},
        "stock": {"vendorSha256": _sha(stock_vendor.read_bytes()), "vbmetaSha256": "00"},
        "vendor": {
            "file": "vendor_a.img",
            "sha256": _sha((reseal / "vendor_a.img").read_bytes()),
            "descriptor": descriptor,
        },
        "vbmeta": {
            "file": "vbmeta_a.img",
            "sha256": _sha((reseal / "vbmeta_a.img").read_bytes()),
            "algorithm": "NONE",
            "rollbackIndex": 1780617600,
            "vendorDescriptor": descriptor,
        },
    }
    for dotted, value in changes.items():
        *parents, leaf = dotted.split(".")
        target = record
        for parent in parents:
            target = target[parent]
        target[leaf] = value
    (inject / "inject.json").write_text(
        json.dumps(
            {
                "buildId": FIXTURE_BUILD,
                "partition": {"name": "vendor_a"},
                "output": {"file": "vendor_a.img", "sha256": _sha(injected.read_bytes())},
                "stock": {"sha256": _sha(stock_vendor.read_bytes())},
            }
        ),
        encoding="utf-8",
    )
    (reseal / "reseal.json").write_text(json.dumps(record), encoding="utf-8")
    return inject, reseal, reseal / "reseal.json", record


def test_a_reseal_output_for_the_same_inject_is_read(tmp_path: Path) -> None:
    inject, reseal, record_path, _record = _reseal_fixture(tmp_path)
    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    assert refresh.vendor == reseal / "vendor_a.img"
    assert refresh.vbmeta == reseal / "vbmeta_a.img"
    assert refresh.record_path == record_path


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"injected.sha256": "00"}, "was not made from this inject-vendor output"),
        ({"stock.vendorSha256": "00"}, "names another stock vendor_a"),
        ({"vbmeta.algorithm": "SHA256_RSA4096"}, "names a signed vbmeta"),
        (
            {"vbmeta.vendorDescriptor": {"rootDigest": "other"}},
            "does not describe the vendor descriptor of its vbmeta_a",
        ),
        ({"vendor.descriptor": {"rootDigest": "other"}}, "does not describe its vendor_a"),
        ({"partition.name": "system_a"}, "does not record the partition vendor_a"),
        ({"task": "#098"}, "is not a #099 vendor-reseal record"),
    ],
)
def test_a_reseal_record_that_does_not_match_its_inject_is_refused(
    tmp_path: Path, changes: dict[str, object], message: str
) -> None:
    inject, reseal, _path, _record = _reseal_fixture(tmp_path, **changes)
    with pytest.raises(BundleVariantError, match=message):
        variant._read_reseal_output(
            reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
        )


def test_a_refreshed_vbmeta_of_another_vendor_is_refused(tmp_path: Path) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    other = _sealed(avbtool, tmp_path, "other", "other")
    other_vbmeta = _vbmeta_for(avbtool, tmp_path, "other", other)
    (reseal / "vbmeta_a.img").write_bytes(other_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(other_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")
    with pytest.raises(BundleVariantError, match="does not carry the descriptor of the resealed"):
        variant._read_reseal_output(
            reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
        )


def test_a_reseal_file_that_changed_after_its_record_is_refused(tmp_path: Path) -> None:
    inject, reseal, _path, _record = _reseal_fixture(tmp_path)
    (reseal / "vbmeta_a.img").write_bytes(b"changed")
    with pytest.raises(BundleVariantError, match="does not match the SHA-256"):
        variant._read_reseal_output(
            reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
        )


def test_the_command_needs_the_reseal_output_after_the_inject_record_is_checked(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    inject = tmp_path / "inject"
    inject.mkdir()
    (inject / "vendor_a.img").write_bytes(b"injected")
    (inject / "inject.json").write_text(
        json.dumps(
            {
                "buildId": FIXTURE_BUILD,
                "partition": {"name": "vendor_a"},
                "output": {"file": "vendor_a.img", "sha256": _sha(b"injected")},
            }
        ),
        encoding="utf-8",
    )
    from test_bundle import FIXTURE_MANIFEST

    status = variant.main(
        [
            "--bundle",
            str(tmp_path / "missing-bundle"),
            "--manifest",
            str(FIXTURE_MANIFEST),
            "--inject-output",
            str(inject),
            "--sign-key",
            str(tmp_path / "missing-key"),
            "--out",
            str(tmp_path / "variant"),
        ]
    )
    assert status == 2
    assert "--reseal-output is required" in capsys.readouterr().err
    assert not (tmp_path / "variant").exists()
