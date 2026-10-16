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
from apkrun_image.avb import VBMETA_HEADER_SIZE, _read_vbmeta
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
AOSP_TEST_KEY = _repository_root() / "Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem"
FIXTURE_BUILD = "16373615"


def _avbtool() -> Path:
    return verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))


def _blob(data: bytes) -> bytes:
    """The authenticated vbmeta blob at the start of `data` (header, authentication, auxiliary)."""
    authentication, auxiliary = struct.unpack_from(">QQ", data, 12)
    return data[: 256 + authentication + auxiliary]


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _corrupt_vbmeta_signature(image: Path) -> None:
    data = bytearray(image.read_bytes())
    signature_offset, signature_size = struct.unpack_from(">QQ", data, 48)
    assert signature_size > 0
    data[256 + signature_offset] ^= 0x01
    image.write_bytes(data)


def _change_vendor_hashtree_u32(image: Path, field_offset: int, value: int) -> Path:
    """Change a uint32 field in the footer's vendor descriptor of an unsigned fixture image."""
    data = bytearray(image.read_bytes())
    header, vbmeta_offset = _read_vbmeta(
        io.BytesIO(data), artifact_size=len(data), artifact_name=str(image)
    )
    table_start = (
        vbmeta_offset
        + VBMETA_HEADER_SIZE
        + header.authentication_size
        + header.descriptors_offset
    )
    table_end = table_start + header.descriptors_size
    cursor = table_start
    while cursor < table_end:
        tag, following_size = struct.unpack_from(">QQ", data, cursor)
        descriptor_end = cursor + 16 + following_size
        if tag == 1:
            name_size = struct.unpack_from(">I", data, cursor + 104)[0]
            name = data[cursor + 180 : cursor + 180 + name_size].decode("utf-8")
            if name == "vendor":
                struct.pack_into(">I", data, cursor + field_offset, value)
                output = image.with_name(f"{image.stem}-modified.img")
                output.write_bytes(data)
                return output
        cursor = descriptor_end
    raise AssertionError("fixture vbmeta has no vendor hashtree descriptor")


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


def _vbmeta_for(
    avbtool: Path,
    tmp: Path,
    name: str,
    vendor: Path,
    *,
    key: Path = AOSP_TEST_KEY,
    algorithm: str = vendor_reseal.VBMETA_ALGORITHM,
    properties: tuple[str, ...] = (),
    public_key_metadata: Path | None = None,
    release_string: str | None = None,
) -> Path:
    output = tmp / f"{name}-vbmeta.img"
    arguments = [
        "make_vbmeta_image",
        "--output",
        str(output),
        "--algorithm",
        algorithm,
        "--key",
        str(key),
        "--include_descriptors_from_image",
        str(vendor),
    ]
    for property_value in properties:
        arguments.extend(["--prop", property_value])
    if public_key_metadata is not None:
        arguments.extend(["--public_key_metadata", str(public_key_metadata)])
    if release_string is not None:
        arguments.extend(["--internal_release_string", release_string])
    arguments.extend(["--padding_size", "4096"])
    run_avbtool(avbtool, arguments)
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
        "schemaVersion": vendor_reseal.SCHEMA_VERSION,
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
            "algorithm": vendor_reseal.VBMETA_ALGORITHM,
            "signer": vendor_reseal.VBMETA_SIGNER,
            "publicKeySha1": vendor_reseal.VBMETA_PUBLIC_KEY_SHA1,
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


def test_a_refreshed_vbmeta_that_only_changes_the_vendor_descriptor_is_accepted(
    tmp_path: Path,
) -> None:
    inject, reseal, _record_path, _record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    stock_vendor = _sealed(avbtool, tmp_path, "baseline-vendor", "baseline")
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "baseline-vbmeta", stock_vendor)
    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )

    variant._verify_refreshed_vbmeta_matches_stock(
        avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
    )


def test_a_corrupt_resealed_vendor_payload_is_refused_even_with_updated_record(
    tmp_path: Path,
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    vendor = reseal / "vendor_a.img"
    corrupted = bytearray(vendor.read_bytes())
    corrupted[0] ^= 0x01
    vendor.write_bytes(corrupted)
    record["vendor"]["sha256"] = _sha(corrupted)
    record_path.write_text(json.dumps(record), encoding="utf-8")
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-corrupt", vendor)

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    with pytest.raises(BundleVariantError, match="AVB hashtree verification failed"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


def test_a_validly_resealed_vendor_cannot_replace_the_checked_injected_payload(
    tmp_path: Path,
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    vendor = reseal / "vendor_a.img"
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-original", vendor)
    changed_vendor = _sealed(avbtool, tmp_path, "changed-vendor", "changed-vendor")
    vendor.write_bytes(changed_vendor.read_bytes())
    descriptor = vendor_reseal.vendor_tree(
        run_avbtool(avbtool, ["info_image", "--image", str(vendor)]),
        "the changed test vendor",
    )
    changed_vbmeta = _vbmeta_for(avbtool, tmp_path, "changed-vendor", vendor)
    (reseal / "vbmeta_a.img").write_bytes(changed_vbmeta.read_bytes())
    record["vendor"]["sha256"] = _sha(vendor.read_bytes())
    record["vendor"]["descriptor"] = descriptor
    record["vbmeta"]["sha256"] = _sha(changed_vbmeta.read_bytes())
    record["vbmeta"]["vendorDescriptor"] = descriptor
    record_path.write_text(json.dumps(record), encoding="utf-8")

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    tree = vendor_reseal.vendor_tree(
        run_avbtool(avbtool, ["info_image", "--image", str(refresh.vendor)]),
        "the changed test vendor",
    )
    assert not variant._same_file_prefix(
        refresh.vendor, refresh.injected, tree["imageSize"]
    )
    with pytest.raises(
        BundleVariantError,
        match="does not carry the exact descriptor of the checked inject-vendor output",
    ):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


def test_the_builder_helper_rejects_a_refreshed_vbmeta_signed_by_another_key(
    tmp_path: Path,
) -> None:
    inject, reseal, _record_path, _record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    vendor = reseal / "vendor_a.img"
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-key", vendor)
    wrong_key_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "wrong-key-helper",
        vendor,
        key=FIXTURE_RSA_KEY,
        algorithm="SHA256_RSA2048",
    )

    with pytest.raises(
        BundleVariantError,
        match="refreshed vbmeta_a is not signed with the pinned",
    ):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, wrong_key_vbmeta, vendor, inject / "vendor_a.img"
        )


def test_the_builder_helper_rejects_nonzero_vbmeta_partition_padding(tmp_path: Path) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    vendor = reseal / "vendor_a.img"
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-padding", vendor)
    refreshed_vbmeta = reseal / "vbmeta_a.img"
    data = bytearray(refreshed_vbmeta.read_bytes())
    header, _offset = _read_vbmeta(
        io.BytesIO(data), artifact_size=len(data), artifact_name=str(refreshed_vbmeta)
    )
    assert header.blob_size < len(data)
    data[-1] = 0x01
    refreshed_vbmeta.write_bytes(data)
    record["vbmeta"]["sha256"] = _sha(data)
    record_path.write_text(json.dumps(record), encoding="utf-8")
    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )

    with pytest.raises(BundleVariantError, match="has nonzero bytes after its vbmeta blob"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"injected.sha256": "00"}, "was not made from this inject-vendor output"),
        ({"stock.vendorSha256": "00"}, "names another stock vendor_a"),
        ({"vbmeta.algorithm": "NONE"}, "does not name a vbmeta signed with"),
        ({"vbmeta.publicKeySha1": "00"}, "does not record the pinned AOSP AVB development"),
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


def test_a_resigned_long_non_vendor_property_change_is_refused_even_with_updated_record(
    tmp_path: Path,
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    stock_vbmeta = _vbmeta_for(
        avbtool, tmp_path, "stock", reseal / "vendor_a.img",
        properties=("apkrun:" + "a" * 300,),
    )
    altered_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "altered",
        reseal / "vendor_a.img",
        properties=("apkrun:" + "b" * 300,),
    )
    (reseal / "vbmeta_a.img").write_bytes(altered_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(altered_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    with pytest.raises(BundleVariantError, match="changed a descriptor other than the vendor"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


@pytest.mark.parametrize(("field_offset", "value"), [(16, 2), (116, 1)])
def test_a_resigned_vendor_descriptor_version_or_flags_change_is_refused(
    tmp_path: Path, field_offset: int, value: int
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-vendor", reseal / "vendor_a.img")
    changed_vendor = _change_vendor_hashtree_u32(
        reseal / "vendor_a.img", field_offset, value
    )
    altered_vbmeta = _vbmeta_for(avbtool, tmp_path, "altered-vendor", changed_vendor)
    (reseal / "vbmeta_a.img").write_bytes(altered_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(altered_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    with pytest.raises(BundleVariantError, match="does not carry the exact descriptor"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


def test_a_resigned_public_key_metadata_change_is_refused_even_with_updated_record(
    tmp_path: Path,
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    stock_metadata = tmp_path / "stock-public-key-metadata.bin"
    altered_metadata = tmp_path / "altered-public-key-metadata.bin"
    stock_metadata.write_bytes(b"stock metadata")
    altered_metadata.write_bytes(b"other metadata")
    stock_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "stock-with-metadata",
        reseal / "vendor_a.img",
        public_key_metadata=stock_metadata,
    )
    altered_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "altered-with-metadata",
        reseal / "vendor_a.img",
        public_key_metadata=altered_metadata,
    )
    (reseal / "vbmeta_a.img").write_bytes(altered_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(altered_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    with pytest.raises(BundleVariantError, match="changed stock public-key metadata"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


def test_a_resigned_release_string_change_is_refused_even_with_updated_record(
    tmp_path: Path,
) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    altered_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "altered-release-string",
        reseal / "vendor_a.img",
        release_string="attacker-controlled-release-string",
    )
    (reseal / "vbmeta_a.img").write_bytes(altered_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(altered_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")
    stock_vbmeta = _vbmeta_for(avbtool, tmp_path, "stock-release-string", reseal / "vendor_a.img")

    refresh = variant._read_reseal_output(
        reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
    )
    with pytest.raises(BundleVariantError, match="changed stock AVB header fields"):
        variant._verify_refreshed_vbmeta_matches_stock(
            avbtool, stock_vbmeta, refresh.vbmeta, refresh.vendor, refresh.injected
        )


def test_a_reseal_record_cannot_hide_a_vbmeta_signed_by_another_key(tmp_path: Path) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    avbtool = _avbtool()
    wrong_key_vbmeta = _vbmeta_for(
        avbtool,
        tmp_path,
        "wrong-key",
        reseal / "vendor_a.img",
        key=FIXTURE_RSA_KEY,
        algorithm="SHA256_RSA2048",
    )
    (reseal / "vbmeta_a.img").write_bytes(wrong_key_vbmeta.read_bytes())
    record["vbmeta"]["sha256"] = _sha(wrong_key_vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")

    with pytest.raises(BundleVariantError, match="not signed with the pinned AOSP AVB"):
        variant._read_reseal_output(
            reseal, inject_directory=inject, partition="vendor_a", build_id=FIXTURE_BUILD
        )


def test_a_reseal_record_cannot_hide_an_invalid_vbmeta_signature(tmp_path: Path) -> None:
    inject, reseal, record_path, record = _reseal_fixture(tmp_path)
    vbmeta = reseal / "vbmeta_a.img"
    _corrupt_vbmeta_signature(vbmeta)
    record["vbmeta"]["sha256"] = _sha(vbmeta.read_bytes())
    record_path.write_text(json.dumps(record), encoding="utf-8")

    with pytest.raises(
        BundleVariantError,
        match="signature verification failed.*signature does not verify",
    ):
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
            "--image-version",
            "2026.10.1",
            "--sign-key",
            str(tmp_path / "missing-key"),
            "--out",
            str(tmp_path / "variant"),
        ]
    )
    assert status == 2
    assert "--reseal-output is required" in capsys.readouterr().err
    assert not (tmp_path / "variant").exists()
