"""AVB resealing tests for development image composition (#36)."""

from __future__ import annotations

import collections
import hashlib
import os
from pathlib import Path

import pytest

from apkrun_image.compose_avb import (
    FEC_ROOTS,
    HASH_ALGORITHM,
    PARTITION_NAME,
    ComposeAvbError,
    _publish_new_file,
    minimum_partition_size,
    refresh_system_ext_vbmeta,
    resign_top_vbmeta,
    seal_system_ext,
    stock_system_ext_descriptor,
)
from apkrun_image.compose_avb import (
    _avbtool as run_image_avbtool,
)
from apkrun_image.erofs import load_component
from apkrun_image.manifest import _repository_root
from apkrun_image.vendor_inject import AVBTOOL_COMPONENT, run_avbtool, verify_avbtool
from apkrun_image.vendor_reseal import (
    VBMETA_PUBLIC_KEY_SHA1,
    _info,
    _raw_vbmeta_descriptors,
    parse_top,
    verify_vbmeta_signature,
)

BLOCK_SIZE = 4096
PARTITION_SIZE = 4 * 1024 * 1024
SALT = "16b6a5f2fb07bc9ff4d92dc782d830af4eb572c1213156e732d0bcf67fbc162e"
SIGNING_KEY = _repository_root() / "Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem"
FEC_TOOL = Path(
    os.environ.get(
        "APKRUN_FEC_TOOL",
        str(_repository_root() / "ThirdParty/out/fec/bin/fec"),
    )
)


def _avbtool() -> Path:
    return verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))


def _content(name: str, size: int) -> bytes:
    block = hashlib.sha256(name.encode("utf-8")).digest()
    return (block * (size // len(block) + 1))[:size]


def _make_fec_partition(
    avbtool: Path, filesystem: Path, output: Path, fec: Path, partition_size: int
) -> None:
    run_image_avbtool(
        avbtool,
        [
            "add_hashtree_footer",
            "--image",
            str(filesystem),
            "--partition_size",
            str(partition_size),
            "--partition_name",
            PARTITION_NAME,
            "--salt",
            SALT,
            "--hash_algorithm",
            HASH_ALGORITHM,
            "--block_size",
            str(BLOCK_SIZE),
            "--fec_num_roots",
            str(FEC_ROOTS),
            "--algorithm",
            "NONE",
        ],
        fec=fec,
    )
    filesystem.replace(output)


@pytest.fixture
def avbtool() -> Path:
    return _avbtool()


@pytest.fixture
def fec_tool() -> Path:
    if FEC_TOOL.is_symlink() or not FEC_TOOL.is_file() or not os.access(FEC_TOOL, os.X_OK):
        if os.environ.get("CI"):
            pytest.fail(
                "build the pinned FEC tool with scripts/build-fec-tool.sh "
                "before running image tests"
            )
        pytest.skip("build the pinned FEC tool with scripts/build-fec-tool.sh to run AVB/FEC tests")
    return FEC_TOOL


def test_minimum_partition_size_reserves_the_stock_fec(
    avbtool: Path, fec_tool: Path, tmp_path: Path
) -> None:
    filesystem = tmp_path / "erofs.img"
    filesystem.write_bytes(_content("large-erofs", 1024 * 1024))

    size = minimum_partition_size(
        avbtool,
        filesystem,
        current_size=PARTITION_SIZE // 8,
        maximum_size=PARTITION_SIZE,
        salt=SALT,
        fec=fec_tool,
    )
    assert size % BLOCK_SIZE == 0
    assert size > PARTITION_SIZE // 8


def test_composed_footer_keeps_stock_hash_and_fec_parameters(
    avbtool: Path, fec_tool: Path, tmp_path: Path
) -> None:
    stock_filesystem = tmp_path / "stock-erofs.img"
    stock_filesystem.write_bytes(_content("stock-erofs", BLOCK_SIZE * 24))
    stock = tmp_path / "stock-system-ext.img"
    _make_fec_partition(avbtool, stock_filesystem, stock, fec_tool, PARTITION_SIZE)
    template = stock_system_ext_descriptor(avbtool, stock)

    filesystem = tmp_path / "composed-erofs.img"
    filesystem.write_bytes(_content("composed-erofs", BLOCK_SIZE * 28))
    output = tmp_path / "sealed-system-ext.img"
    descriptor = seal_system_ext(
        avbtool,
        filesystem,
        output,
        partition_size=PARTITION_SIZE,
        stock_descriptor=template,
        fec=fec_tool,
    )

    assert descriptor["fecRoots"] == FEC_ROOTS
    assert descriptor["hashAlgorithm"] == HASH_ALGORITHM
    assert descriptor["salt"] == SALT
    assert descriptor["imageSize"] == filesystem.stat().st_size
    assert descriptor["treeSize"] > 0
    assert descriptor["fecOffset"] >= descriptor["treeOffset"] + descriptor["treeSize"]
    assert descriptor["fecSize"] > 0
    assert descriptor["fecOffset"] + descriptor["fecSize"] <= PARTITION_SIZE
    assert output.stat().st_size == PARTITION_SIZE


def test_refreshed_vbmeta_system_replaces_only_the_system_ext_descriptor(
    avbtool: Path, fec_tool: Path, tmp_path: Path
) -> None:
    stock_filesystem = tmp_path / "stock-erofs.img"
    stock_filesystem.write_bytes(_content("stock-erofs", BLOCK_SIZE * 24))
    stock_partition = tmp_path / "stock-system-ext.img"
    _make_fec_partition(avbtool, stock_filesystem, stock_partition, fec_tool, PARTITION_SIZE)

    stock_vbmeta_raw = tmp_path / "vbmeta-system.raw"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(stock_vbmeta_raw),
            "--algorithm",
            "SHA256_RSA4096",
            "--key",
            str(SIGNING_KEY),
            "--rollback_index",
            "1780617600",
            "--rollback_index_location",
            "1",
            "--flags",
            "0",
            "--internal_release_string",
            "avbtool 1.4.0",
            "--include_descriptors_from_image",
            str(stock_partition),
            "--prop",
            "test.vbmeta_system:value",
        ],
    )
    stock_vbmeta = tmp_path / "vbmeta_system_a.img"
    stock_vbmeta.write_bytes(
        stock_vbmeta_raw.read_bytes() + bytes(12 * 1024 - stock_vbmeta_raw.stat().st_size)
    )
    metadata = verify_vbmeta_signature(avbtool, stock_vbmeta)

    composed_filesystem = tmp_path / "composed-erofs.img"
    composed_filesystem.write_bytes(_content("composed-erofs", BLOCK_SIZE * 28))
    sealed_partition = tmp_path / "composed-system-ext.img"
    stock_descriptor = stock_system_ext_descriptor(avbtool, stock_partition)
    sealed_descriptor = seal_system_ext(
        avbtool,
        composed_filesystem,
        sealed_partition,
        partition_size=PARTITION_SIZE,
        stock_descriptor=stock_descriptor,
        fec=fec_tool,
    )
    output = tmp_path / "vbmeta-system-composed.img"

    refresh_system_ext_vbmeta(
        avbtool,
        stock_vbmeta,
        sealed_partition,
        SIGNING_KEY,
        output,
    )

    old_header, old_descriptors = _raw_vbmeta_descriptors(stock_vbmeta)
    new_header, new_descriptors = _raw_vbmeta_descriptors(output)
    assert old_header == new_header
    old_system_ext = [item for item in old_descriptors if item[1] == PARTITION_NAME]
    new_system_ext = [item for item in new_descriptors if item[1] == PARTITION_NAME]
    assert len(old_system_ext) == len(new_system_ext) == 1
    assert old_system_ext[0][2] != new_system_ext[0][2]
    assert [item for item in old_descriptors if item[1] != PARTITION_NAME] == [
        item for item in new_descriptors if item[1] != PARTITION_NAME
    ]
    assert verify_vbmeta_signature(avbtool, output) == metadata
    assert parse_top(_info(avbtool, output))["Public key (sha1)"].lower() == (
        VBMETA_PUBLIC_KEY_SHA1
    )
    assert _info(avbtool, sealed_partition)
    assert sealed_descriptor["rootDigest"] in new_system_ext[0][2].hex()
    assert output.stat().st_size == stock_vbmeta.stat().st_size


def test_resigned_top_vbmeta_preserves_chains_and_public_metadata(
    avbtool: Path, tmp_path: Path
) -> None:
    public_key = tmp_path / "test.avbpubkey"
    run_avbtool(
        avbtool,
        ["extract_public_key", "--key", str(SIGNING_KEY), "--output", str(public_key)],
    )
    metadata = tmp_path / "pkmd.bin"
    metadata.write_bytes(b"APKRun fixture public key metadata")
    stock_raw = tmp_path / "vbmeta.raw"
    run_avbtool(
        avbtool,
        [
            "make_vbmeta_image",
            "--output",
            str(stock_raw),
            "--algorithm",
            "SHA256_RSA4096",
            "--key",
            str(SIGNING_KEY),
            "--rollback_index",
            "1780617600",
            "--rollback_index_location",
            "0",
            "--flags",
            "0",
            "--internal_release_string",
            "avbtool 1.4.0",
            "--chain_partition",
            f"vbmeta_system:1:{public_key}",
            "--chain_partition",
            f"boot:2:{public_key}",
            "--prop",
            "test.key:value",
            "--public_key_metadata",
            str(metadata),
        ],
    )
    stock = tmp_path / "vbmeta_a.img"
    stock.write_bytes(stock_raw.read_bytes() + bytes(12 * 1024 - stock_raw.stat().st_size))
    output = tmp_path / "vbmeta-a-composed.img"

    record = resign_top_vbmeta(
        avbtool,
        stock,
        SIGNING_KEY,
        output,
    )

    old_header, old_descriptors = _raw_vbmeta_descriptors(stock)
    new_header, new_descriptors = _raw_vbmeta_descriptors(output)
    assert old_header == new_header
    assert collections.Counter(item[2] for item in old_descriptors) == collections.Counter(
        item[2] for item in new_descriptors
    )
    assert verify_vbmeta_signature(avbtool, output) == metadata.read_bytes()
    assert parse_top(_info(avbtool, output))["Public key (sha1)"].lower() == (
        VBMETA_PUBLIC_KEY_SHA1
    )
    assert record["descriptorCount"] == len(old_descriptors)
    assert output.stat().st_size == stock.stat().st_size


def test_sealed_output_is_removed_when_footer_verification_fails(
    avbtool: Path, fec_tool: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    filesystem = tmp_path / "composed-erofs.img"
    filesystem.write_bytes(_content("composed-erofs", BLOCK_SIZE * 28))
    stock_descriptor = {
        "salt": SALT,
        "partition": PARTITION_NAME,
        "dataBlockSize": BLOCK_SIZE,
        "hashBlockSize": BLOCK_SIZE,
        "fecRoots": FEC_ROOTS,
        "hashAlgorithm": HASH_ALGORITHM,
    }
    output = tmp_path / "sealed-system-ext.img"

    real_avbtool = run_image_avbtool

    def fail_verification(tool: Path, args: list[str], *, fec: Path | None = None) -> str:
        if args[0] == "verify_image":
            raise ComposeAvbError("injected footer-verification failure")
        return real_avbtool(tool, args, fec=fec)

    monkeypatch.setattr("apkrun_image.compose_avb._avbtool", fail_verification)
    with pytest.raises(ComposeAvbError, match="injected footer-verification failure"):
        seal_system_ext(
            avbtool,
            filesystem,
            output,
            partition_size=PARTITION_SIZE,
            stock_descriptor=stock_descriptor,
            fec=fec_tool,
        )
    assert not output.exists()
    assert list(tmp_path.glob(".apkrun-system-ext-*")) == []


def test_atomic_publication_preserves_a_concurrent_symlink(tmp_path: Path) -> None:
    staged = tmp_path / "staged.img"
    victim = tmp_path / "victim.img"
    output = tmp_path / "output.img"
    staged.write_bytes(b"verified")
    victim.write_bytes(b"keep")
    output.symlink_to(victim)

    with pytest.raises(ComposeAvbError, match="output appeared"):
        _publish_new_file(staged, output)

    assert output.is_symlink()
    assert victim.read_bytes() == b"keep"
