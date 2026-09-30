"""Compute Android Verified Boot bootconfig values from ordered vbmeta images."""

from __future__ import annotations

import hashlib
import struct
from collections.abc import Callable, Mapping
from contextlib import AbstractContextManager
from dataclasses import dataclass
from typing import Any, BinaryIO, Literal, Protocol

VBMETA_HEADER_SIZE = 256
AVB_FOOTER_SIZE = 64
MAX_VBMETA_SIZE = 64 * 1024
COPY_CHUNK_SIZE = 1024 * 1024
AVB_VERSION_MAJOR = 1
AVB_VERSION_MINOR = 4
HASHTREE_DISABLED = 1
VERIFICATION_DISABLED = 2
HASH_ALGORITHMS = {
    0: "sha256",
    1: "sha256",
    2: "sha256",
    3: "sha256",
    4: "sha512",
    5: "sha512",
    6: "sha512",
}
HASHTREE_ERROR_MODES = {
    "restart_and_invalidate",
    "restart",
    "eio",
    "logging",
    "panic",
}

ArtifactOpener = Callable[[Mapping[str, Any]], AbstractContextManager[BinaryIO]]
HashtreeErrorMode = Literal["restart_and_invalidate", "restart", "eio", "logging", "panic"]


class HashUpdater(Protocol):
    """The portion of a hash object needed by the bounded stream reader."""

    def update(self, data: bytes, /) -> None:
        """Add bytes to the running digest."""


class AvbError(ValueError):
    """An invalid vbmeta image or manifest role set."""


@dataclass(frozen=True)
class VbmetaHeader:
    """Bounded fields from one vbmeta header."""

    blob_size: int
    authentication_size: int
    auxiliary_size: int
    algorithm_type: int
    flags: int
    descriptors_offset: int
    descriptors_size: int


def ordered_vbmeta_artifacts(document: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """Resolve vbmeta artifacts in the manifest's declared chain order."""
    roles = document.get("roles")
    artifacts = document.get("artifacts")
    role_ids = roles.get("vbmeta") if isinstance(roles, Mapping) else None
    if not isinstance(role_ids, list) or not role_ids:
        raise AvbError("roles.vbmeta must contain the top-level vbmeta artifact.")
    if not all(isinstance(artifact_id, str) and artifact_id for artifact_id in role_ids):
        raise AvbError("roles.vbmeta must contain non-empty artifact IDs.")
    if len(set(role_ids)) != len(role_ids):
        raise AvbError("roles.vbmeta contains a duplicate artifact ID.")
    if not isinstance(artifacts, list):
        raise AvbError("manifest artifacts must be an array.")

    artifact_by_id: dict[str, Mapping[str, Any]] = {}
    for artifact in artifacts:
        if isinstance(artifact, Mapping) and isinstance(artifact.get("id"), str):
            if artifact["id"] in artifact_by_id:
                raise AvbError(f'vbmeta artifact ID "{artifact["id"]}" is duplicated.')
            artifact_by_id[artifact["id"]] = artifact

    ordered: list[Mapping[str, Any]] = []
    for position, artifact_id in enumerate(role_ids):
        artifact = artifact_by_id.get(artifact_id)
        if artifact is None:
            raise AvbError(
                f'roles.vbmeta[{position}] = "{artifact_id}" does not resolve to an artifact.'
            )
        if artifact.get("kind") != "vbmeta":
            raise AvbError(f'roles.vbmeta[{position}] = "{artifact_id}" is not a vbmeta artifact.')
        if position == 0 and artifact.get("partition") != "vbmeta":
            raise AvbError("roles.vbmeta[0] must identify the top-level vbmeta partition.")
        ordered.append(artifact)
    return ordered


def _read_exact(stream: BinaryIO, size: int, artifact_name: str) -> bytes:
    """Read exactly one bounded section from a vbmeta stream."""
    content = bytearray()
    while len(content) < size:
        chunk = stream.read(size - len(content))
        if not chunk:
            raise AvbError(f"{artifact_name}: vbmeta data is truncated.")
        content.extend(chunk)
    return bytes(content)


def _header_fields(header: bytes, file_size: int, artifact_name: str) -> VbmetaHeader:
    """Parse and bound the authenticated vbmeta blob and descriptor table."""
    if len(header) != VBMETA_HEADER_SIZE or header[:4] != b"AVB0":
        raise AvbError(f"{artifact_name}: invalid or truncated vbmeta header.")

    authentication_size, auxiliary_size = struct.unpack_from(">QQ", header, 12)
    blob_size = VBMETA_HEADER_SIZE + authentication_size + auxiliary_size
    if blob_size > MAX_VBMETA_SIZE:
        raise AvbError(f"{artifact_name}: vbmeta metadata exceeds the 64 KiB AVB limit.")
    if blob_size > file_size:
        raise AvbError(f"{artifact_name}: vbmeta metadata extends past the image size.")

    algorithm_type = struct.unpack_from(">I", header, 28)[0]
    flags = struct.unpack_from(">I", header, 120)[0]
    descriptors_offset, descriptors_size = struct.unpack_from(">QQ", header, 96)
    if (
        descriptors_offset > auxiliary_size
        or descriptors_size > auxiliary_size - descriptors_offset
    ):
        raise AvbError(f"{artifact_name}: vbmeta descriptors exceed the auxiliary block.")
    return VbmetaHeader(
        blob_size=blob_size,
        authentication_size=authentication_size,
        auxiliary_size=auxiliary_size,
        algorithm_type=algorithm_type,
        flags=flags,
        descriptors_offset=descriptors_offset,
        descriptors_size=descriptors_size,
    )


def _footer_vbmeta_offset(
    stream: BinaryIO,
    *,
    artifact_size: int,
    artifact_name: str,
) -> tuple[int, int | None]:
    """Return the footer's vbmeta offset and declared size, or raw-image defaults."""
    try:
        if artifact_size < AVB_FOOTER_SIZE:
            return 0, None
        stream.seek(artifact_size - AVB_FOOTER_SIZE)
        footer = _read_exact(stream, AVB_FOOTER_SIZE, artifact_name)
    except (OSError, ValueError) as error:
        if isinstance(error, AvbError):
            raise
        raise AvbError(f"{artifact_name}: could not read vbmeta data: {error}.") from None
    if footer[:4] != b"AVBf":
        return 0, None

    _magic, _major, _minor, original_size, vbmeta_offset, vbmeta_size = struct.unpack_from(
        ">4sIIQQQ", footer
    )
    footer_offset = artifact_size - AVB_FOOTER_SIZE
    if (
        original_size > vbmeta_offset
        or vbmeta_offset > footer_offset
        or vbmeta_size > footer_offset - vbmeta_offset
    ):
        raise AvbError(f"{artifact_name}: AVB footer points outside the image.")
    return vbmeta_offset, vbmeta_size


def _read_vbmeta(
    stream: BinaryIO,
    *,
    artifact_size: int,
    artifact_name: str,
    hasher: HashUpdater | None = None,
    require_footer: bool = False,
) -> tuple[VbmetaHeader, int]:
    """Read one raw or footer-backed vbmeta blob and optionally hash its contents."""
    offset, footer_size = _footer_vbmeta_offset(
        stream,
        artifact_size=artifact_size,
        artifact_name=artifact_name,
    )
    if require_footer and footer_size is None:
        raise AvbError(f"{artifact_name}: chained image is missing its AVB footer.")
    try:
        stream.seek(offset)
        header_bytes = _read_exact(stream, VBMETA_HEADER_SIZE, artifact_name)
        header = _header_fields(header_bytes, artifact_size - offset, artifact_name)
        if footer_size is not None and footer_size != header.blob_size:
            raise AvbError(f"{artifact_name}: AVB footer size does not match its vbmeta header.")
        if hasher is not None:
            hasher.update(header_bytes)
            remaining = header.blob_size - VBMETA_HEADER_SIZE
            while remaining:
                chunk = stream.read(min(COPY_CHUNK_SIZE, remaining))
                if not chunk:
                    raise AvbError(f"{artifact_name}: vbmeta data is truncated.")
                hasher.update(chunk)
                remaining -= len(chunk)
    except (OSError, ValueError) as error:
        if isinstance(error, AvbError):
            raise
        raise AvbError(f"{artifact_name}: could not read vbmeta data: {error}.") from None
    return header, offset


def _chain_partitions(
    stream: BinaryIO,
    *,
    header: VbmetaHeader,
    vbmeta_offset: int,
    artifact_name: str,
) -> list[str]:
    """Read chain-partition names from the top-level vbmeta descriptor table."""
    table_offset = (
        vbmeta_offset + VBMETA_HEADER_SIZE + header.authentication_size + header.descriptors_offset
    )
    try:
        stream.seek(table_offset)
        table = _read_exact(stream, header.descriptors_size, artifact_name)
    except (OSError, ValueError) as error:
        if isinstance(error, AvbError):
            raise
        raise AvbError(f"{artifact_name}: could not read vbmeta descriptors: {error}.") from None

    partitions: list[str] = []
    offset = 0
    while offset < len(table):
        if len(table) - offset < 16:
            raise AvbError(f"{artifact_name}: truncated AVB descriptor header.")
        descriptor_type, following_size = struct.unpack_from(">QQ", table, offset)
        if following_size % 8:
            raise AvbError(f"{artifact_name}: AVB descriptor size is not 8-byte aligned.")
        end = offset + 16 + following_size
        if end > len(table):
            raise AvbError(f"{artifact_name}: AVB descriptor exceeds the descriptor table.")
        if descriptor_type == 4:
            payload = table[offset + 16 : end]
            if len(payload) < 76:
                raise AvbError(f"{artifact_name}: truncated AVB chain partition descriptor.")
            name_size, key_size = struct.unpack_from(">II", payload, 4)
            used_size = 76 + name_size + key_size
            if (used_size + 7) & ~7 != len(payload) or any(payload[used_size:]):
                raise AvbError(f"{artifact_name}: invalid AVB chain descriptor padding.")
            try:
                partition = payload[76 : 76 + name_size].decode("utf-8")
            except UnicodeDecodeError:
                raise AvbError(f"{artifact_name}: AVB chain partition name is not UTF-8.") from None
            if not partition or "/" in partition or "\\" in partition or "\0" in partition:
                raise AvbError(f"{artifact_name}: AVB chain partition name is invalid.")
            if partition in partitions:
                raise AvbError(f"{artifact_name}: duplicate AVB chain partition {partition!r}.")
            partitions.append(partition)
        offset = end
    return partitions


def calculate_vbmeta_bootconfig(
    document: Mapping[str, Any],
    open_artifact: ArtifactOpener,
    *,
    hashtree_error_mode: HashtreeErrorMode = "restart_and_invalidate",
) -> dict[str, str]:
    """Compute the five ``androidboot.vbmeta.*`` bootconfig values.

    ``open_artifact`` must return a context manager for the verified artifact
    stream. Raw vbmeta entries use ``roles.vbmeta`` order; footer-backed chain
    images are inserted in the descriptor order from the top-level vbmeta.
    ``avb_version`` follows the pinned AVB 1.4 toolchain, and
    ``hashtree_error_mode`` makes the boot policy explicit because it is not
    stored in a vbmeta image.
    """
    if hashtree_error_mode not in HASHTREE_ERROR_MODES:
        choices = ", ".join(sorted(HASHTREE_ERROR_MODES))
        raise AvbError(f"unsupported hashtree error mode {hashtree_error_mode!r}; use {choices}.")
    artifacts = ordered_vbmeta_artifacts(document)
    top = artifacts[0]
    top_size = top.get("size")
    if isinstance(top_size, bool) or not isinstance(top_size, int) or top_size < 0:
        raise AvbError("roles.vbmeta[0]: artifact size is invalid.")
    artifact_records = document.get("artifacts")
    if not isinstance(artifact_records, list):
        raise AvbError("manifest artifacts must be an array.")
    artifact_by_partition: dict[str, Mapping[str, Any]] = {}
    for artifact in artifact_records:
        if not isinstance(artifact, Mapping) or not isinstance(artifact.get("partition"), str):
            continue
        partition = artifact["partition"]
        if partition in artifact_by_partition:
            raise AvbError(f'partition "{partition}" is ambiguous in manifest artifacts.')
        artifact_by_partition[partition] = artifact

    try:
        with open_artifact(top) as stream:
            top_name = str(top.get("file", "vbmeta"))
            top_header, top_offset = _read_vbmeta(
                stream,
                artifact_size=top_size,
                artifact_name=top_name,
            )
            if top_header.flags & VERIFICATION_DISABLED:
                raise AvbError(f"{top_name}: vbmeta verification is disabled.")
            hash_algorithm = HASH_ALGORITHMS.get(top_header.algorithm_type)
            if hash_algorithm is None:
                raise AvbError(
                    f"{top_name}: unsupported AVB algorithm type {top_header.algorithm_type}."
                )
            hasher = hashlib.new(hash_algorithm)
            top_header, top_offset = _read_vbmeta(
                stream,
                artifact_size=top_size,
                artifact_name=top_name,
                hasher=hasher,
            )
            chain_partitions = _chain_partitions(
                stream,
                header=top_header,
                vbmeta_offset=top_offset,
                artifact_name=top_name,
            )
    except OSError as error:
        raise AvbError(f"Could not open {top.get('file', 'vbmeta')}: {error}.") from None

    chain_artifacts: list[Mapping[str, Any]] = []
    expected_role_ids = [str(top["id"])]
    for partition in chain_partitions:
        artifact = artifact_by_partition.get(partition)
        if artifact is None:
            raise AvbError(
                f'{top.get("file", "vbmeta")}: chained partition "{partition}" is missing.'
            )
        chain_artifacts.append(artifact)
        if artifact.get("kind") == "vbmeta":
            artifact_id = artifact.get("id")
            if not isinstance(artifact_id, str):
                raise AvbError(f'chained vbmeta partition "{partition}" has no artifact ID.')
            expected_role_ids.append(artifact_id)
    actual_role_ids = [artifact.get("id") for artifact in artifacts]
    if actual_role_ids != expected_role_ids:
        raise AvbError(
            f"roles.vbmeta order {actual_role_ids} does not match top-level chain order "
            f"{expected_role_ids}."
        )

    total_size = top_header.blob_size
    for position, artifact in enumerate(chain_artifacts, start=1):
        artifact_size = artifact.get("size")
        artifact_name = str(artifact.get("file", f"roles.vbmeta[{position}]"))
        if (
            isinstance(artifact_size, bool)
            or not isinstance(artifact_size, int)
            or artifact_size < 0
        ):
            raise AvbError(f"{artifact_name}: artifact size is invalid.")
        try:
            with open_artifact(artifact) as stream:
                child_header, _child_offset = _read_vbmeta(
                    stream,
                    artifact_size=artifact_size,
                    artifact_name=artifact_name,
                    hasher=hasher,
                    require_footer=artifact.get("kind") != "vbmeta",
                )
        except OSError as error:
            raise AvbError(f"Could not open {artifact_name}: {error}.") from None
        if child_header.flags != 0:
            raise AvbError(f"{artifact_name}: chained vbmeta images must have zero flags.")
        total_size += child_header.blob_size

    invalidate_on_error = (
        "yes"
        if not top_header.flags & HASHTREE_DISABLED
        and hashtree_error_mode == "restart_and_invalidate"
        else "no"
    )
    return {
        "androidboot.vbmeta.digest": hasher.hexdigest(),
        "androidboot.vbmeta.hash_alg": hash_algorithm,
        "androidboot.vbmeta.size": str(total_size),
        "androidboot.vbmeta.avb_version": f"{AVB_VERSION_MAJOR}.{AVB_VERSION_MINOR}",
        "androidboot.vbmeta.invalidate_on_error": invalidate_on_error,
    }
