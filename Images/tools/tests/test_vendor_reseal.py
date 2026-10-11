"""Tests of the vendor reseal (#099, steps 2 and 3).

The partitions here are small synthetic images that the vendored avbtool seals, so the tests need
neither the erofs tools nor a VM. The stock vendor_a and vbmeta_a of the bundle are not in
the suite.
"""

from __future__ import annotations

import hashlib
import json
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
    main,
    parse_hashtrees,
    parse_top,
    refresh_vbmeta,
    reseal,
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


def _stock_vbmeta(avbtool: Path, tmp: Path, name: str, vendor: Path) -> Path:
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
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(output),
            "--algorithm",
            "NONE",
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
        ],
    )
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


def test_the_refreshed_vbmeta_changes_only_the_vendor_descriptor(tmp_path: Path) -> None:
    avbtool = _avbtool()
    stock = _seal(avbtool, tmp_path, "stock", _content("stock"))
    injected = _seal(avbtool, tmp_path, "injected", _content("injected"))
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    vendor = tmp_path / "vendor_a.img"
    reseal_vendor(avbtool, injected, stock, vendor, scratch)
    stock_vbmeta = _stock_vbmeta(avbtool, tmp_path, "stock", stock)
    refreshed_scratch = tmp_path / "refresh"
    refreshed_scratch.mkdir()
    output = tmp_path / "vbmeta_a.img"

    record = refresh_vbmeta(avbtool, stock_vbmeta, vendor, output, refreshed_scratch)

    assert output.stat().st_size == stock_vbmeta.stat().st_size
    assert record["rollbackIndex"] == 7
    new_info = _info(avbtool, output)
    old_info = _info(avbtool, stock_vbmeta)
    assert parse_top(new_info)["Algorithm"] == "NONE"
    assert parse_top(new_info)["Rollback Index"] == "7"
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
    assert record["vbmeta"]["algorithm"] == "NONE"
    with pytest.raises(ValueError, match="must not exist or must be empty"):
        reseal(
            injected=injected,
            stock_vendor=stock,
            stock_vbmeta=stock_vbmeta,
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
            "--out",
            str(tmp_path / "out"),
        ]
    )

    assert status == 1
    assert capsys.readouterr().err.startswith("vendor-reseal: ")
