"""Tests for AVB bootconfig values and the vendored avbtool digest."""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
from collections.abc import Callable, Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from io import BytesIO
from pathlib import Path
from typing import Any, BinaryIO

import pytest

from apkrun_image.avb import (
    AVB_VERSION_MAJOR,
    AVB_VERSION_MINOR,
    AvbError,
    calculate_vbmeta_bootconfig,
    ordered_vbmeta_artifacts,
)
from apkrun_image.extract import _open_artifact
from apkrun_image.manifest import (
    _archive_paths,
    _load_json,
    _resolve_archive_root,
)

TEST_ROOT = Path(__file__).resolve().parent
FIXTURE_IMAGE_DIRECTORY = TEST_ROOT / "fixtures/images"
REPOSITORY_ROOT = TEST_ROOT.parents[2]
AVBTOOL = TEST_ROOT / "../vendor/avb/avbtool.py"
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)
PINNED_MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"


def _run_avbtool(*arguments: str) -> subprocess.CompletedProcess[str]:
    """Run the checked-in AVB tool with an isolated output path."""
    return subprocess.run(
        [sys.executable, str(AVBTOOL), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )


def _write_child_vbmeta(path: Path, name: str) -> None:
    """Build a deterministic unsigned child vbmeta image."""
    _run_avbtool(
        "make_vbmeta_image",
        "--output",
        str(path),
        "--algorithm",
        "NONE",
        "--prop",
        f"apkrun.fixture:{name}",
    )


def _fixture_manifest(image_paths: Mapping[str, Path]) -> dict[str, Any]:
    """Make a minimal ordered manifest for the synthetic chain fixture."""
    artifact_ids = {
        "vbmeta.img": ("vbmeta", "vbmeta", "vbmeta"),
        "system_a.img": ("boot", "system_a", "bootImage"),
        "vendor_a.img": ("vbmeta_vendor", "vendor_a", "vbmeta"),
    }
    artifacts = []
    for file_name, (artifact_id, partition, kind) in artifact_ids.items():
        path = image_paths[file_name]
        artifacts.append(
            {
                "file": file_name,
                "id": artifact_id,
                "kind": kind,
                "partition": partition,
                "size": path.stat().st_size,
            }
        )
    return {
        "artifacts": artifacts,
        "roles": {"vbmeta": ["vbmeta", "vbmeta_vendor"]},
    }


def _path_opener(
    image_paths: Mapping[str, Path],
) -> tuple[list[str], Callable[[Mapping[str, Any]], AbstractContextManager[BinaryIO]]]:
    """Return a stream opener which records manifest role order."""
    opened: list[str] = []

    def open_artifact(artifact: Mapping[str, Any]) -> AbstractContextManager[BinaryIO]:
        opened.append(str(artifact["id"]))
        return image_paths[str(artifact["file"])].open("rb")

    return opened, open_artifact


def _metadata_size(path: Path) -> int:
    """Read the AVB header's authenticated vbmeta blob size."""
    image = path.read_bytes()
    offset = 0
    footer_size: int | None = None
    if image[-64:-60] == b"AVBf":
        _magic, _major, _minor, _original_size, offset, footer_size = struct.unpack_from(
            ">4sIIQQQ", image, len(image) - 64
        )
    header = image[offset : offset + 256]
    authentication_size, auxiliary_size = struct.unpack_from(">QQ", header, 12)
    metadata_size = 256 + authentication_size + auxiliary_size
    if footer_size is not None:
        assert footer_size == metadata_size
    return metadata_size


def _synthetic_chain(tmp_path: Path) -> tuple[dict[str, Path], dict[str, Any]]:
    """Create a padded top-level image and its two named chain images."""
    paths = {
        "vbmeta.img": tmp_path / "vbmeta.img",
        "system_a.img": tmp_path / "system_a.img",
        "vendor_a.img": tmp_path / "vendor_a.img",
    }
    paths["vbmeta.img"].write_bytes(
        (FIXTURE_IMAGE_DIRECTORY / "vbmeta.img").read_bytes() + bytes(512)
    )
    _write_child_vbmeta(paths["system_a.img"], "system")
    system_blob = paths["system_a.img"].read_bytes()
    system_size = _metadata_size(paths["system_a.img"])
    system_offset = 512
    footer = struct.pack(
        ">4sIIQQQ",
        b"AVBf",
        1,
        0,
        system_offset,
        system_offset,
        system_size,
    ) + bytes(28)
    paths["system_a.img"].write_bytes(bytes(system_offset) + system_blob[:system_size] + footer)
    _write_child_vbmeta(paths["vendor_a.img"], "vendor")
    paths["vendor_a.img"].write_bytes(paths["vendor_a.img"].read_bytes() + bytes(512))
    return paths, _fixture_manifest(paths)


def test_vbmeta_digest_matches_vendored_avbtool_in_manifest_order(tmp_path: Path) -> None:
    """The digest and aggregate size match AVB's handling of chained metadata."""
    image_paths, document = _synthetic_chain(tmp_path)
    opened, open_artifact = _path_opener(image_paths)
    values = calculate_vbmeta_bootconfig(document, open_artifact)

    digest_path = tmp_path / "avbtool-digest.txt"
    _run_avbtool(
        "calculate_vbmeta_digest",
        "--image",
        str(image_paths["vbmeta.img"]),
        "--hash_algorithm",
        values["androidboot.vbmeta.hash_alg"],
        "--output",
        str(digest_path),
    )

    expected_size = sum(_metadata_size(path) for path in image_paths.values())
    assert values["androidboot.vbmeta.digest"] == digest_path.read_text(encoding="ascii").strip()
    assert values["androidboot.vbmeta.hash_alg"] == "sha256"
    assert values["androidboot.vbmeta.size"] == str(expected_size)
    assert expected_size < sum(path.stat().st_size for path in image_paths.values())
    assert values["androidboot.vbmeta.avb_version"] == (f"{AVB_VERSION_MAJOR}.{AVB_VERSION_MINOR}")
    assert values["androidboot.vbmeta.invalidate_on_error"] == "yes"
    assert opened == ["vbmeta", "boot", "vbmeta_vendor"]


def test_avb_version_matches_the_vendored_toolchain() -> None:
    """The guest-visible libavb version stays aligned with its pinned tool."""
    result = _run_avbtool("version")

    assert result.stdout.strip() == f"avbtool {AVB_VERSION_MAJOR}.{AVB_VERSION_MINOR}.0"


def test_sha512_algorithm_and_non_invalidating_policy_are_supported(tmp_path: Path) -> None:
    """Hash selection follows the top-level signature algorithm and boot policy."""
    image_paths, document = _synthetic_chain(tmp_path)
    top = image_paths["vbmeta.img"]
    image = bytearray(top.read_bytes())
    struct.pack_into(">I", image, 28, 4)
    top.write_bytes(image)
    _opened, open_artifact = _path_opener(image_paths)

    values = calculate_vbmeta_bootconfig(
        document,
        open_artifact,
        hashtree_error_mode="restart",
    )
    digest_path = tmp_path / "avbtool-sha512-digest.txt"
    _run_avbtool(
        "calculate_vbmeta_digest",
        "--image",
        str(top),
        "--hash_algorithm",
        "sha512",
        "--output",
        str(digest_path),
    )

    assert values["androidboot.vbmeta.hash_alg"] == "sha512"
    assert values["androidboot.vbmeta.digest"] == digest_path.read_text(encoding="ascii").strip()
    assert values["androidboot.vbmeta.size"] == str(
        sum(_metadata_size(path) for path in image_paths.values())
    )
    assert values["androidboot.vbmeta.avb_version"] == (f"{AVB_VERSION_MAJOR}.{AVB_VERSION_MINOR}")
    assert values["androidboot.vbmeta.invalidate_on_error"] == "no"


def test_hashtree_disabled_vbmeta_does_not_invalidate_on_error(tmp_path: Path) -> None:
    """A disabled hashtree suppresses the invalidate-on-error boot policy."""
    top = tmp_path / "vbmeta.img"
    _run_avbtool("make_vbmeta_image", "--output", str(top), "--algorithm", "NONE")
    image = bytearray(top.read_bytes())
    struct.pack_into(">I", image, 120, 1)
    top.write_bytes(image)
    document = {
        "artifacts": [
            {
                "file": top.name,
                "id": "vbmeta",
                "kind": "vbmeta",
                "partition": "vbmeta",
                "size": top.stat().st_size,
            }
        ],
        "roles": {"vbmeta": ["vbmeta"]},
    }
    _opened, open_artifact = _path_opener({"vbmeta.img": top})

    values = calculate_vbmeta_bootconfig(document, open_artifact)

    assert values["androidboot.vbmeta.invalidate_on_error"] == "no"


def test_verification_disabled_vbmeta_is_rejected(tmp_path: Path) -> None:
    """AVB properties are not emitted when the root image disables verification."""
    image_paths, document = _synthetic_chain(tmp_path)
    top = image_paths["vbmeta.img"]
    image = bytearray(top.read_bytes())
    struct.pack_into(">I", image, 120, 2)
    top.write_bytes(image)
    _opened, open_artifact = _path_opener(image_paths)

    with pytest.raises(AvbError, match="vbmeta verification is disabled"):
        calculate_vbmeta_bootconfig(document, open_artifact)


def test_roles_vbmeta_must_match_descriptor_order(tmp_path: Path) -> None:
    """Raw vbmeta role order cannot silently disagree with the AVB chain."""
    image_paths, document = _synthetic_chain(tmp_path)
    document["artifacts"][1]["kind"] = "vbmeta"
    document["roles"]["vbmeta"] = ["vbmeta", "vbmeta_vendor", "boot"]
    _opened, open_artifact = _path_opener(image_paths)

    with pytest.raises(AvbError, match="does not match top-level chain order"):
        calculate_vbmeta_bootconfig(document, open_artifact)


def test_missing_chain_artifact_is_rejected(tmp_path: Path) -> None:
    """Every top-level chain descriptor must resolve to one manifest artifact."""
    image_paths, document = _synthetic_chain(tmp_path)
    document["artifacts"] = [
        artifact for artifact in document["artifacts"] if artifact["partition"] != "system_a"
    ]
    _opened, open_artifact = _path_opener(image_paths)

    with pytest.raises(AvbError, match='chained partition "system_a" is missing'):
        calculate_vbmeta_bootconfig(document, open_artifact)


def test_truncated_footer_and_vbmeta_body_are_rejected(tmp_path: Path) -> None:
    """Footer-backed chains require an intact footer and complete metadata body."""
    image_paths, document = _synthetic_chain(tmp_path)
    footer_path = image_paths["system_a.img"]
    footer_path.write_bytes(footer_path.read_bytes()[:-10])
    document["artifacts"][1]["size"] = footer_path.stat().st_size
    _opened, open_artifact = _path_opener(image_paths)

    with pytest.raises(AvbError, match="chained image is missing its AVB footer"):
        calculate_vbmeta_bootconfig(document, open_artifact)

    image_paths, document = _synthetic_chain(tmp_path)
    raw_path = image_paths["vendor_a.img"]
    metadata_end = _metadata_size(raw_path)

    class TruncatedBodyStream(BytesIO):
        """Keep a valid file length while returning EOF one byte early in the AVB blob."""

        def read(self, size: int = -1) -> bytes:
            position = self.tell()
            if 256 <= position < metadata_end:
                body_end = metadata_end - 1
                if position >= body_end:
                    return b""
                if size < 0 or size > body_end - position:
                    size = body_end - position
            return super().read(size)

    def open_truncated_body(artifact: Mapping[str, Any]) -> AbstractContextManager[BinaryIO]:
        if artifact["id"] == "vbmeta_vendor":
            return TruncatedBodyStream(raw_path.read_bytes())
        return image_paths[str(artifact["file"])].open("rb")

    with pytest.raises(AvbError, match="vbmeta data is truncated"):
        calculate_vbmeta_bootconfig(document, open_truncated_body)


@pytest.mark.parametrize(
    ("footer_field_offset", "footer_field_value", "message"),
    [
        (20, 1 << 30, "footer points outside the image"),
        (28, 1, "footer size does not match"),
    ],
)
def test_malformed_chain_footer_is_rejected(
    tmp_path: Path,
    footer_field_offset: int,
    footer_field_value: int,
    message: str,
) -> None:
    """Footer offsets and sizes cannot escape or disagree with the vbmeta header."""
    image_paths, document = _synthetic_chain(tmp_path)
    footer_backed_image = bytearray(image_paths["system_a.img"].read_bytes())
    struct.pack_into(
        ">Q",
        footer_backed_image,
        len(footer_backed_image) - 64 + footer_field_offset,
        footer_field_value,
    )
    image_paths["system_a.img"].write_bytes(footer_backed_image)
    document["artifacts"][1]["size"] = len(footer_backed_image)
    _opened, open_artifact = _path_opener(image_paths)

    with pytest.raises(AvbError, match=message):
        calculate_vbmeta_bootconfig(document, open_artifact)


@pytest.mark.parametrize(
    ("document", "message"),
    [
        ({}, "roles.vbmeta must contain the top-level"),
        ({"roles": {"vbmeta": ["missing"]}, "artifacts": []}, "does not resolve"),
        (
            {
                "roles": {"vbmeta": ["vbmeta", "vbmeta"]},
                "artifacts": [
                    {"id": "vbmeta", "kind": "vbmeta", "partition": "vbmeta"},
                ],
            },
            "duplicate artifact ID",
        ),
        (
            {
                "roles": {"vbmeta": ["vbmeta"]},
                "artifacts": [
                    {"id": "vbmeta", "kind": "filesystem", "partition": "vbmeta"},
                ],
            },
            "not a vbmeta artifact",
        ),
    ],
)
def test_invalid_vbmeta_role_sets_are_rejected(
    document: dict[str, Any],
    message: str,
) -> None:
    """Malformed role lists never select an ambiguous or non-vbmeta artifact."""
    with pytest.raises(AvbError, match=message):
        ordered_vbmeta_artifacts(document)


def test_invalid_headers_and_size_limits_are_rejected(tmp_path: Path) -> None:
    """AVB headers must be complete and remain within the image and AVB bounds."""
    top = tmp_path / "vbmeta.img"
    document = {
        "artifacts": [
            {
                "file": top.name,
                "id": "vbmeta",
                "kind": "vbmeta",
                "partition": "vbmeta",
                "size": 256,
            }
        ],
        "roles": {"vbmeta": ["vbmeta"]},
    }
    _opened, open_artifact = _path_opener({"vbmeta.img": top})

    top.write_bytes(bytes(256))
    with pytest.raises(AvbError, match="invalid or truncated vbmeta header"):
        calculate_vbmeta_bootconfig(document, open_artifact)

    header = bytearray(256)
    header[:4] = b"AVB0"
    struct.pack_into(">Q", header, 12, 64 * 1024)
    top.write_bytes(header)
    with pytest.raises(AvbError, match="64 KiB AVB limit"):
        calculate_vbmeta_bootconfig(document, open_artifact)


def test_pinned_build_digest_matches_vendored_avbtool(tmp_path: Path) -> None:
    """T1 compares a downloaded pinned build against the vendored reference tool."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")

    document = _load_json(PINNED_MANIFEST, description="pinned Android image manifest")
    source_root = _resolve_archive_root(document, source=None)
    archives = document.get("source", {}).get("archives", [])
    assert isinstance(archives, list)
    archive_paths = _archive_paths(source_root, archives)
    image_paths: dict[str, Path] = {}

    @contextmanager
    def open_artifact(artifact: Mapping[str, Any]) -> Iterator[BinaryIO]:
        destination = tmp_path / str(artifact["file"])
        with (
            _open_artifact(document, source_root, archive_paths, artifact) as source_stream,
            destination.open("wb") as output_stream,
        ):
            shutil.copyfileobj(source_stream, output_stream)
        image_paths[str(artifact["file"])] = destination
        with destination.open("rb") as stream:
            yield stream

    artifacts = ordered_vbmeta_artifacts(document)
    values = calculate_vbmeta_bootconfig(document, open_artifact)
    digest_path = tmp_path / "pinned-avbtool-digest.txt"
    _run_avbtool(
        "calculate_vbmeta_digest",
        "--image",
        str(image_paths[str(artifacts[0]["file"])]),
        "--hash_algorithm",
        values["androidboot.vbmeta.hash_alg"],
        "--output",
        str(digest_path),
    )

    assert values["androidboot.vbmeta.digest"] == digest_path.read_text(encoding="ascii").strip()
    assert values["androidboot.vbmeta.hash_alg"] == "sha256"
    assert values["androidboot.vbmeta.size"] == str(
        sum(_metadata_size(path) for path in image_paths.values())
    )
    assert values["androidboot.vbmeta.avb_version"] == (f"{AVB_VERSION_MAJOR}.{AVB_VERSION_MINOR}")
    assert values["androidboot.vbmeta.invalidate_on_error"] == "yes"
