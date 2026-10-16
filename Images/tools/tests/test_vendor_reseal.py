"""Tests of the vendor reseal (#099, steps 2 and 3).

The partitions here are small synthetic images that the vendored avbtool seals, so the tests need
neither the erofs tools nor a VM. The stock vendor_a and vbmeta_a of the bundle are not in
the suite.
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
from pathlib import Path

import pytest

from apkrun_image import vendor_reseal
from apkrun_image.erofs import load_component
from apkrun_image.manifest import _repository_root
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    run_avbtool,
    seal_partition,
    verify_avbtool,
)
from apkrun_image.vendor_reseal import (
    VBMETA_ALGORITHM,
    VBMETA_PUBLIC_KEY_SHA1,
    VBMETA_SIGNER,
    ResealError,
    descriptor_blocks,
    main,
    parse_hashtrees,
    parse_top,
    refresh_vbmeta,
    refresh_vbmeta_partition,
    reseal,
    reseal_vendor,
    verify_vbmeta_signature,
)

SALT = "16b6a5f2fb07bc9ff4d92dc782d830af4eb572c1213156e732d0bcf67fbc162e"
PARTITION_SIZE = 2 * 1024 * 1024
FS_SIZE = 1024 * 1024
TEST_KEY = _repository_root() / "Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem"
OTHER_TEST_KEY = _repository_root() / "Tests/Fixtures/signing/test-apkrun-image-fixture-rsa.pem"


def _avbtool() -> Path:
    return verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))


def _content(seed: str, size: int = FS_SIZE) -> bytes:
    block = hashlib.sha256(seed.encode("utf-8")).digest()
    return (block * (size // len(block) + 1))[:size]


def _seal(avbtool: Path, tmp: Path, name: str, content: bytes, size: int = PARTITION_SIZE) -> Path:
    scratch = tmp / f"seal-{name}"
    scratch.mkdir()
    fs_image = scratch / "fs.img"
    fs_image.write_bytes(content)
    output = tmp / f"{name}.img"
    seal_partition(avbtool, fs_image, output, partition_size=size, salt=SALT, scratch=scratch)
    return output


def _seal_named(
    avbtool: Path,
    tmp: Path,
    image_name: str,
    partition_name: str,
    content: bytes,
    size: int = PARTITION_SIZE,
) -> Path:
    output = tmp / f"{image_name}.img"
    output.write_bytes(content)
    run_avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image",
            str(output),
            "--partition_size",
            str(size),
            "--partition_name",
            partition_name,
            "--salt",
            SALT,
            "--hash_algorithm",
            "sha256",
            "--block_size",
            "4096",
            "--algorithm",
            "NONE",
            "--do_not_generate_fec",
        ],
    )
    return output


def _raw_descriptors(image: Path) -> tuple[bytes, list[tuple[int, str | None, bytes]]]:
    data = image.read_bytes()
    vbmeta_offset = 0
    if data[-64:-60] == b"AVBf":
        _magic, _major, _minor, _original_size, vbmeta_offset, _vbmeta_size = struct.unpack_from(
            ">4sIIQQQ", data, len(data) - 64
        )
    header = data[vbmeta_offset : vbmeta_offset + 256]
    authentication_size, _auxiliary_size = struct.unpack_from(">QQ", header, 12)
    descriptor_offset, descriptor_size = struct.unpack_from(">QQ", header, 96)
    start = vbmeta_offset + 256 + authentication_size + descriptor_offset
    table = data[start : start + descriptor_size]
    descriptors: list[tuple[int, str | None, bytes]] = []
    offset = 0
    while offset < len(table):
        tag, following_size = struct.unpack_from(">QQ", table, offset)
        end = offset + 16 + following_size
        encoded = table[offset:end]
        name = None
        if tag == 1:
            name_size = struct.unpack_from(">I", encoded, 104)[0]
            name = encoded[180 : 180 + name_size].decode("utf-8")
        descriptors.append((tag, name, encoded))
        offset = end
    return header, descriptors


def _write_raw_vbmeta(image: Path, descriptors: bytes) -> None:
    header = bytearray(256)
    header[:4] = b"AVB0"
    struct.pack_into(">QQ", header, 12, 0, len(descriptors))
    struct.pack_into(">QQ", header, 96, 0, len(descriptors))
    image.write_bytes(header + descriptors)


def _info(avbtool: Path, image: Path) -> str:
    return run_avbtool(avbtool, ["info_image", "--image", str(image)])


def _corrupt_vbmeta_signature(image: Path) -> None:
    data = bytearray(image.read_bytes())
    signature_offset, signature_size = struct.unpack_from(">QQ", data, 48)
    assert signature_size > 0
    data[256 + signature_offset] ^= 0x01
    image.write_bytes(data)


def test_unknown_vbmeta_algorithm_is_a_typed_reseal_error(tmp_path: Path) -> None:
    avbtool = _avbtool()
    malformed = tmp_path / "unknown-algorithm.img"
    header = bytearray(256)
    header[:4] = b"AVB0"
    struct.pack_into(">I", header, 28, 999)
    malformed.write_bytes(header)

    with pytest.raises(ResealError, match="could not verify the vbmeta signature"):
        verify_vbmeta_signature(avbtool, malformed)


def test_short_avb_public_key_blob_is_a_typed_reseal_error(tmp_path: Path) -> None:
    avbtool = _avbtool()
    vendor = _seal(avbtool, tmp_path, "vendor", _content("vendor"))
    malformed = _stock_vbmeta(avbtool, tmp_path, "stock", vendor)
    data = bytearray(malformed.read_bytes())
    authentication_size, auxiliary_size = struct.unpack_from(">QQ", data, 12)
    hash_offset, hash_size = struct.unpack_from(">QQ", data, 32)
    struct.pack_into(">Q", data, 72, 1)
    auxiliary_offset = 256 + authentication_size
    digest = hashlib.sha256(data[:256] + data[auxiliary_offset : auxiliary_offset + auxiliary_size])
    assert hash_size == digest.digest_size
    data[256 + hash_offset : 256 + hash_offset + hash_size] = digest.digest()
    malformed.write_bytes(data)

    with pytest.raises(ResealError, match="could not verify the vbmeta signature"):
        verify_vbmeta_signature(avbtool, malformed)


def _stock_vbmeta(
    avbtool: Path,
    tmp: Path,
    name: str,
    vendor: Path,
    key: Path = TEST_KEY,
    algorithm: str = VBMETA_ALGORITHM,
    public_key_metadata: Path | None = None,
    release_string: str | None = None,
) -> Path:
    """A vbmeta_a-like image with a vendor hashtree, a hash descriptor, and a property."""
    boot = tmp / f"{name}-boot.img"
    boot.write_bytes(_content(f"{name}-boot", 32 * 1024))
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
    output = tmp / f"{name}-vbmeta.img"
    arguments = [
        "make_vbmeta_image",
        "--output",
        str(output),
        "--algorithm",
        algorithm,
        "--key",
        str(key),
        "--rollback_index",
        "7",
        "--prop",
        "test.key:value",
        "--include_descriptors_from_image",
        str(vendor),
        "--include_descriptors_from_image",
        str(boot),
        "--padding_size",
        "4096",
    ]
    if public_key_metadata is not None:
        arguments.extend(["--public_key_metadata", str(public_key_metadata)])
    if release_string is not None:
        arguments.extend(["--internal_release_string", release_string])
    run_avbtool(avbtool, arguments)
    return output


def test_a_fresh_injected_partition_is_reproduced_byte_for_byte(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    output = tmp_path / "out.img"

    record = reseal_vendor(avbtool, injected, stock, output, scratch)

    assert output.read_bytes() == injected.read_bytes()
    assert record["identicalToInjected"] is True
    assert record["tree"]["fecRoots"] == 0
    assert record["tree"]["imageSize"] == FS_SIZE


def test_a_stale_tree_is_replaced_by_one_for_the_content_it_holds(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    stale_root = parse_hashtrees(_info(avbtool, injected))["vendor"]["rootDigest"]
    # One byte of the EROFS part changes after sealing, so the footer's tree no longer matches.
    data = bytearray(injected.read_bytes())
    data[8192] ^= 0xFF
    injected.write_bytes(bytes(data))
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    output = tmp_path / "out.img"

    record = reseal_vendor(avbtool, injected, stock, output, scratch)

    expected = _seal(avbtool, tmp_path, "expected", bytes(data[:FS_SIZE]))
    assert output.read_bytes() == expected.read_bytes()
    assert record["tree"]["rootDigest"] != stale_root
    assert record["identicalToInjected"] is False


def test_an_injected_partition_of_another_size_is_refused(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    smaller = _seal(
        avbtool, tmp_path, "smaller", _content("smaller", FS_SIZE // 2), size=PARTITION_SIZE // 2
    )
    scratch = tmp_path / "scratch"
    scratch.mkdir()

    with pytest.raises(ResealError, match="not the size of the stock partition"):
        reseal_vendor(avbtool, smaller, stock, tmp_path / "out.img", scratch)
    assert not (tmp_path / "out.img").exists()


def test_the_hashtree_parser_reads_only_hashtree_descriptors() -> None:
    info = "\n".join(
        [
            "Footer version:           1.0",
            "Image size:               2097152 bytes",
            "Original image size:      1048576 bytes",
            "--",
            "Algorithm:                NONE",
            "Descriptors:",
            "    Hashtree descriptor:",
            "      Version of dm-verity:  1",
            "      Image Size:            1048576 bytes",
            "      Tree Offset:           1048576",
            "      Tree Size:             36864 bytes",
            "      Data Block Size:       4096 bytes",
            "      Hash Block Size:       4096 bytes",
            "      FEC num roots:         0",
            "      FEC offset:            0",
            "      FEC size:              0 bytes",
            "      Hash Algorithm:        sha256",
            "      Partition Name:        vendor",
            "      Salt:                  abcd",
            "      Root Digest:           1234",
            "      Flags:                 0",
            "    Hash descriptor:",
            "      Image Size:            4096 bytes",
            "      Partition Name:        boot",
            "      Salt:                  ffff",
            "      Digest:                00",
            "    Prop: com.android.build.vendor.os_version -> '17'",
        ]
    )
    trees = parse_hashtrees(info)
    assert list(trees) == ["vendor"]
    assert trees["vendor"]["imageSize"] == 1048576
    assert trees["vendor"]["fecRoots"] == 0
    assert trees["vendor"]["rootDigest"] == "1234"
    top = parse_top(info)
    assert top["Original image size"] == "1048576 bytes"
    assert top["Algorithm"] == "NONE"
    assert [header for header, _ in descriptor_blocks(info)] == [
        "Hashtree descriptor:",
        "Hash descriptor:",
        "Prop: com.android.build.vendor.os_version -> '17'",
    ]


@pytest.mark.parametrize(
    ("descriptor", "message"),
    [
        (bytes(8), "truncated AVB descriptor header"),
        (struct.pack(">QQ", 2, 1) + bytes(1), "invalid AVB descriptor size"),
        (struct.pack(">QQ", 1, 0), "truncated hashtree descriptor"),
        (
            struct.pack(">QQ", 1, 168)
            + bytes(88)
            + struct.pack(">III", 1, 0, 0)
            + bytes(64)
            + b"a\x00\x00\x01",
            "invalid hashtree partition name",
        ),
    ],
)
def test_raw_descriptor_reader_rejects_malformed_descriptor_bytes(
    tmp_path: Path, descriptor: bytes, message: str
) -> None:
    malformed = tmp_path / "malformed-vbmeta.img"
    _write_raw_vbmeta(malformed, descriptor)

    with pytest.raises(ResealError, match=message):
        vendor_reseal._raw_vbmeta_descriptors(malformed)


def test_the_refreshed_vbmeta_changes_only_the_vendor_descriptor(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    vendor = tmp_path / "vendor_a.img"
    reseal_vendor(avbtool, injected, stock, vendor, scratch)
    stock_vbmeta = _stock_vbmeta(
        avbtool, tmp_path, "stock", stock, release_string="stock-builder 1.0"
    )
    refreshed_scratch = tmp_path / "refresh"
    refreshed_scratch.mkdir()
    output = tmp_path / "vbmeta_a.img"

    record = refresh_vbmeta(avbtool, stock_vbmeta, vendor, TEST_KEY, output, refreshed_scratch)

    assert output.stat().st_size == stock_vbmeta.stat().st_size
    assert record["rollbackIndex"] == 7
    new_info = _info(avbtool, output)
    old_info = _info(avbtool, stock_vbmeta)
    assert parse_top(new_info)["Algorithm"] == VBMETA_ALGORITHM
    assert parse_top(new_info)["Public key (sha1)"] == VBMETA_PUBLIC_KEY_SHA1
    assert parse_top(new_info)["Rollback Index"] == "7"
    assert parse_top(new_info)["Release String"] == parse_top(old_info)["Release String"]
    assert record["signer"] == VBMETA_SIGNER
    assert record["publicKeySha1"] == VBMETA_PUBLIC_KEY_SHA1
    assert parse_hashtrees(new_info)["vendor"] == parse_hashtrees(_info(avbtool, vendor))["vendor"]
    assert (
        parse_hashtrees(old_info)["vendor"]["rootDigest"]
        != record["vendorDescriptor"]["rootDigest"]
    )
    assert "test.key" in new_info
    old_others = [block for block in descriptor_blocks(old_info) if "Hashtree" not in block[0]]
    new_others = [block for block in descriptor_blocks(new_info) if "Hashtree" not in block[0]]
    assert old_others == new_others
    assert (
        record["previousVendorDescriptor"]["rootDigest"]
        == parse_hashtrees(old_info)["vendor"]["rootDigest"]
    )

    verify_dir = tmp_path / "verify"
    verify_dir.mkdir()
    (verify_dir / "vbmeta_a.img").symlink_to(output)
    (verify_dir / "vendor.img").symlink_to(vendor)
    (verify_dir / "boot.img").symlink_to(tmp_path / "stock-boot.img")
    verified = run_avbtool(
        avbtool,
        [
            "verify_image",
            "--image",
            str(verify_dir / "vbmeta_a.img"),
            "--key",
            str(TEST_KEY),
        ],
    )
    assert "Successfully verified SHA256_RSA4096 vbmeta struct" in verified


def test_refresh_vbmeta_retains_the_vendor_block_size_invariant(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    replacement = _seal(avbtool, tmp_path, "replacement", _content("replacement"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    original_info = vendor_reseal._info

    def mismatched_vendor_info(tool: Path, image: Path) -> str:
        text = original_info(tool, image)
        if image == replacement:
            text, count = re.subn(
                r"(Hash Block Size:\s*)4096(?=\s+bytes)", r"\g<1>2048", text, count=1
            )
            assert count == 1
        return text

    monkeypatch.setattr(vendor_reseal, "_info", mismatched_vendor_info)
    with pytest.raises(ResealError, match="data and hash block sizes that differ"):
        refresh_vbmeta(
            avbtool,
            stock_vbmeta,
            replacement,
            TEST_KEY,
            tmp_path / "refreshed-vbmeta.img",
            scratch,
        )


def test_refresh_vbmeta_partition_preserves_everything_except_the_target_descriptor(
    tmp_path: Path,
) -> None:
    avbtool = _avbtool()
    old_partition = _seal_named(avbtool, tmp_path, "odm-stock", "odm", _content("odm-stock"))
    new_partition = _seal_named(avbtool, tmp_path, "odm-new", "odm", _content("odm-new"))
    metadata = tmp_path / "public-key-metadata.bin"
    metadata.write_bytes(b"APKRun generic partition metadata")
    stock_vbmeta = _stock_vbmeta(
        avbtool,
        tmp_path,
        "odm-stock",
        old_partition,
        public_key_metadata=metadata,
        release_string="stock-builder 2.0",
    )
    scratch = tmp_path / "refresh-odm"
    scratch.mkdir()
    output = tmp_path / "vbmeta-odm.img"

    record = refresh_vbmeta_partition(
        avbtool, stock_vbmeta, new_partition, "odm", TEST_KEY, output, scratch
    )

    stock_header, stock_descriptors = _raw_descriptors(stock_vbmeta)
    output_header, output_descriptors = _raw_descriptors(output)
    old_target = [
        (index, descriptor)
        for index, descriptor in enumerate(stock_descriptors)
        if descriptor[0] == 1 and descriptor[1] == "odm"
    ]
    new_targets = [
        (index, descriptor)
        for index, descriptor in enumerate(output_descriptors)
        if descriptor[0] == 1 and descriptor[1] == "odm"
    ]
    _partition_header, partition_descriptors = _raw_descriptors(new_partition)
    image_targets = [
        descriptor
        for descriptor in partition_descriptors
        if descriptor[0] == 1 and descriptor[1] == "odm"
    ]

    assert len(old_target) == len(new_targets) == len(image_targets) == 1
    assert output_header == stock_header
    assert new_targets[0][0] == old_target[0][0]
    assert new_targets[0][1] == image_targets[0]
    assert len(output_descriptors) == len(stock_descriptors)
    assert [
        descriptor
        for index, descriptor in enumerate(output_descriptors)
        if index != new_targets[0][0]
    ] == [
        descriptor
        for index, descriptor in enumerate(stock_descriptors)
        if index != old_target[0][0]
    ]

    output_data = output.read_bytes()
    authentication_size, auxiliary_size = struct.unpack_from(">QQ", output_data, 12)
    blob_size = 256 + authentication_size + auxiliary_size
    assert record == {
        "rollbackIndex": 7,
        "blobSize": blob_size,
        "signer": VBMETA_SIGNER,
        "publicKeySha1": VBMETA_PUBLIC_KEY_SHA1,
        "partitionName": "odm",
        "previousDescriptor": parse_hashtrees(_info(avbtool, old_partition))["odm"],
        "descriptor": parse_hashtrees(_info(avbtool, new_partition))["odm"],
    }
    assert output.stat().st_size == stock_vbmeta.stat().st_size
    assert output.stat().st_size <= stock_vbmeta.stat().st_size
    assert output_data[blob_size:] == bytes(len(output_data) - blob_size)
    assert verify_vbmeta_signature(avbtool, stock_vbmeta) == metadata.read_bytes()
    assert verify_vbmeta_signature(avbtool, output) == metadata.read_bytes()
    old_top = parse_top(_info(avbtool, stock_vbmeta))
    new_top = parse_top(_info(avbtool, output))
    assert old_top["Public key (sha1)"] == new_top["Public key (sha1)"] == VBMETA_PUBLIC_KEY_SHA1
    assert old_top["Release String"] == new_top["Release String"]
    for field in ("Rollback Index", "Rollback Index Location", "Flags", "Minimum libavb version"):
        assert new_top[field] == old_top[field]


def test_refresh_vbmeta_partition_rejects_a_vbmeta_signed_by_another_key(
    tmp_path: Path,
) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    avbtool = _avbtool()
    partition = _seal_named(avbtool, tmp_path, "odm", "odm", _content("odm"))
    other_key = tmp_path / "other-rsa4096.pem"
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    other_key.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    stock_vbmeta = _stock_vbmeta(
        avbtool,
        tmp_path,
        "wrong-key",
        partition,
        key=other_key,
        algorithm=VBMETA_ALGORITHM,
    )
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "refreshed.img"

    with pytest.raises(ResealError, match="pinned AOSP AVB test key"):
        refresh_vbmeta_partition(avbtool, stock_vbmeta, partition, "odm", TEST_KEY, output, scratch)
    assert not output.exists()


def test_refresh_vbmeta_partition_requires_one_stock_target_descriptor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    avbtool = _avbtool()
    partition = _seal_named(avbtool, tmp_path, "odm", "odm", _content("odm"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock-odm", partition)
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "refreshed.img"

    original_reader = vendor_reseal._raw_vbmeta_descriptors

    def report_duplicate_target(
        image: Path,
    ) -> tuple[bytes, list[tuple[int, str | None, bytes]]]:
        header, descriptors = original_reader(image)
        if image == stock_vbmeta:
            index = next(
                index
                for index, (tag, name, _encoded) in enumerate(descriptors)
                if tag == 1 and name == "odm"
            )
            descriptors.insert(index, descriptors[index])
        return header, descriptors

    monkeypatch.setattr(vendor_reseal, "_raw_vbmeta_descriptors", report_duplicate_target)

    with pytest.raises(ResealError, match="exactly one odm hashtree descriptor"):
        refresh_vbmeta_partition(avbtool, stock_vbmeta, partition, "odm", TEST_KEY, output, scratch)
    assert not output.exists()


def test_refresh_vbmeta_partition_rejects_an_invalid_replacement_footer(
    tmp_path: Path,
) -> None:
    avbtool = _avbtool()
    stock_partition = _seal_named(avbtool, tmp_path, "odm-stock", "odm", _content("odm-stock"))
    replacement = _seal_named(avbtool, tmp_path, "odm-new", "odm", _content("odm-new"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "odm-stock", stock_partition)
    data = bytearray(replacement.read_bytes())
    data[8192] ^= 0xFF
    replacement.write_bytes(data)
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "refreshed.img"

    with pytest.raises(ResealError, match="could not verify the hashtree footer"):
        refresh_vbmeta_partition(
            avbtool, stock_vbmeta, replacement, "odm", TEST_KEY, output, scratch
        )
    assert not output.exists()


def test_public_key_metadata_is_preserved_by_refresh(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    metadata = tmp_path / "public-key-metadata.bin"
    metadata.write_bytes(b"APKRun public-key metadata fixture")
    stock_vbmeta = _stock_vbmeta(
        avbtool, tmp_path, "stock-with-metadata", stock, public_key_metadata=metadata
    )
    vendor_scratch = tmp_path / "vendor-scratch"
    vendor_scratch.mkdir()
    vendor = tmp_path / "vendor_a.img"
    reseal_vendor(avbtool, injected, stock, vendor, vendor_scratch)
    refresh_scratch = tmp_path / "refresh-scratch"
    refresh_scratch.mkdir()
    refreshed = tmp_path / "vbmeta_a.img"

    assert verify_vbmeta_signature(avbtool, stock_vbmeta) == metadata.read_bytes()
    refresh_vbmeta(avbtool, stock_vbmeta, vendor, TEST_KEY, refreshed, refresh_scratch)
    assert verify_vbmeta_signature(avbtool, refreshed) == metadata.read_bytes()


def test_a_signing_key_with_another_avb_identity_is_refused(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "vbmeta_a.img"

    with pytest.raises(ResealError, match="does not match the pinned AOSP AVB test key"):
        refresh_vbmeta(avbtool, stock_vbmeta, stock, OTHER_TEST_KEY, output, scratch)
    assert not output.exists()


def test_a_stock_vbmeta_with_another_algorithm_is_refused(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    stock_vbmeta = _stock_vbmeta(
        avbtool,
        tmp_path,
        "stock",
        stock,
        key=OTHER_TEST_KEY,
        algorithm="SHA256_RSA2048",
    )
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "vbmeta_a.img"

    with pytest.raises(ResealError, match="stock vbmeta_a is not signed with SHA256_RSA4096"):
        refresh_vbmeta(avbtool, stock_vbmeta, stock, TEST_KEY, output, scratch)
    assert not output.exists()


def test_a_stock_vbmeta_with_an_invalid_signature_is_refused(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)
    _corrupt_vbmeta_signature(stock_vbmeta)
    scratch = tmp_path / "refresh"
    scratch.mkdir()
    output = tmp_path / "vbmeta_a.img"

    with pytest.raises(ResealError, match="vbmeta signature does not verify"):
        refresh_vbmeta(avbtool, stock_vbmeta, stock, TEST_KEY, output, scratch)
    assert not output.exists()


def test_a_vbmeta_whose_vendor_root_is_another_is_refused_by_the_driver(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    other = _seal(avbtool, tmp_path, "other", _content("other"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    other_vbmeta = _stock_vbmeta(avbtool, tmp_path, "other", other)

    with pytest.raises(ResealError, match="disagree on the root"):
        reseal(
            injected=injected,
            stock_vendor=stock,
            stock_vbmeta=other_vbmeta,
            signing_key=TEST_KEY,
            output_directory=tmp_path / "out",
        )
    assert not (tmp_path / "out").exists() or not any((tmp_path / "out").iterdir())


def test_the_driver_writes_the_two_images_and_a_record_and_refuses_an_existing_output(
    tmp_path: Path,
) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)
    output = tmp_path / "out"

    record = reseal(
        injected=injected,
        stock_vendor=stock,
        stock_vbmeta=stock_vbmeta,
        signing_key=TEST_KEY,
        output_directory=output,
    )

    assert sorted(path.name for path in output.iterdir()) == [
        "reseal.json",
        "vbmeta_a.img",
        "vendor_a.img",
    ]
    written = json.loads((output / "reseal.json").read_text(encoding="utf-8"))
    assert written == record
    assert (
        record["vendor"]["sha256"]
        == hashlib.sha256((output / "vendor_a.img").read_bytes()).hexdigest()
    )
    assert record["vbmeta"]["algorithm"] == VBMETA_ALGORITHM
    assert record["vbmeta"]["signer"] == VBMETA_SIGNER
    with pytest.raises(ValueError, match="must not exist or must be empty"):
        reseal(
            injected=injected,
            stock_vendor=stock,
            stock_vbmeta=stock_vbmeta,
            signing_key=TEST_KEY,
            output_directory=output,
        )


def test_the_output_must_be_outside_the_repository(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)

    with pytest.raises(ValueError, match="must be outside the repository"):
        reseal(
            injected=injected,
            stock_vendor=stock,
            stock_vbmeta=stock_vbmeta,
            signing_key=TEST_KEY,
            output_directory=_repository_root() / "reseal-test-output",
        )
    assert not (_repository_root() / "reseal-test-output").exists()


def test_the_command_reports_an_unreadable_input_and_exits_1(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    bad = tmp_path / "bad.img"
    bad.write_bytes(b"not an image")
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)

    status = main(
        [
            "--injected",
            str(bad),
            "--stock-vendor",
            str(stock),
            "--stock-vbmeta",
            str(stock_vbmeta),
            "--key",
            str(TEST_KEY),
            "--out",
            str(tmp_path / "out"),
        ]
    )

    assert status == 1
    assert capsys.readouterr().err.startswith("vendor-reseal: ")
