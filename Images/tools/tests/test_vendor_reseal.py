"""Tests of the vendor footer reseal (#099, step 2).

The partitions here are small synthetic images that the vendored avbtool seals, so the tests need
neither the erofs tools nor a VM. The stock vendor_a and vbmeta_a of the bundle are not in
the suite.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from apkrun_image.erofs import load_component
from apkrun_image.manifest import _repository_root
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    run_avbtool,
    seal_partition,
    verify_avbtool,
)
from apkrun_image.vendor_reseal import (
    ResealError,
    descriptor_blocks,
    parse_hashtrees,
    parse_top,
    reseal_vendor,
)

SALT = "16b6a5f2fb07bc9ff4d92dc782d830af4eb572c1213156e732d0bcf67fbc162e"
PARTITION_SIZE = 2 * 1024 * 1024
FS_SIZE = 1024 * 1024


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


def _info(avbtool: Path, image: Path) -> str:
    return run_avbtool(avbtool, ["info_image", "--image", str(image)])


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

