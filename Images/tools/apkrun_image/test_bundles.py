"""Build the opt-in Android test bundle variants described in test-strategy.md §3.5 (#36).

The input must be a signed, composed development bundle made with the fixed test overlay. Each
output is a separate, signed bundle. Large immutable files are APFS clones where available and
otherwise copied while preserving sparse extents. The source bundle is never changed.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import re
import shutil
import sys
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from apkrun_image.bootconfig import (
    BootconfigError,
    parse_bootconfig_text,
    serialize_bootconfig,
)
from apkrun_image.bundle import (
    _checksums,
    _file_entry,
    _load_signing_key,
    _repository_root,
    _sha256,
)
from apkrun_image.runtime_manifest import load_and_validate, validate
from apkrun_image.sign import (
    SignatureError,
    key_id_of,
    render_signature,
    verify_signature,
)

TEST_OVERLAY_INPUTS = (
    "Tests/Fixtures/AndroidImageProduct/compose.json",
    "Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc",
)
TEST_KEY_PREFIX = "androidboot.apkrun.test."
MANIFEST_NAME = "manifest.json"
SIGNATURE_NAME = "manifest.sig"
CHECKSUMS_NAME = "SHA256SUMS"
IMAGE_VERSION = re.compile(
    r"^(?P<year>[0-9]{4})\.(?P<month>0[1-9]|1[0-2])\."
    r"(?P<sequence>0|[1-9][0-9]{0,2})-(?P<base>cf[0-9]{1,20})-arm64$"
)
META_FILES = frozenset({MANIFEST_NAME, SIGNATURE_NAME, CHECKSUMS_NAME})
CHUNK_BYTES = 4 * 1024 * 1024
CLONE_FALLBACK_ERRNOS = {
    errno.EINVAL,
    errno.ENOSYS,
    errno.ENOTSUP,
    errno.EXDEV,
}
if hasattr(errno, "EOPNOTSUPP"):
    CLONE_FALLBACK_ERRNOS.add(errno.EOPNOTSUPP)


class TestBundleError(ValueError):
    """The input is not a safe test base, or a requested variant cannot be built."""


@dataclass(frozen=True)
class _Variant:
    """One fixed test variant and its deterministic version offset."""

    name: str
    version_offset: int
    bootconfig: Mapping[str, str]
    missing_init: bool = False


VARIANTS = (
    _Variant("A", 0, {}),
    _Variant("B", 1, {"androidboot.apkrun.test.marker": "B"}),
    _Variant(
        "B-prime",
        2,
        {
            "androidboot.apkrun.test.marker": "B",
            "androidboot.apkrun.test.fail_health": "1",
        },
    ),
    _Variant("F", 3, {"androidboot.apkrun.test.fail_boot": "1"}),
    _Variant("P", 4, {}, missing_init=True),
    _Variant("S", 5, {"androidboot.apkrun.test.secret": "1"}),
)


def _manifest_failure(data: bytes, *, description: str) -> dict[str, Any]:
    violations = load_and_validate(data)
    if violations:
        first = violations[0]
        raise TestBundleError(
            f"{description} manifest fails {first.rule} at {first.path}: {first.reason}"
        )
    try:
        manifest = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TestBundleError(f"{description} manifest cannot be parsed: {error}") from None
    if not isinstance(manifest, dict):
        raise TestBundleError(f"{description} manifest must be an object.")
    return manifest


def _required_test_overlay(manifest: Mapping[str, Any]) -> None:
    """Require provenance for the exact local init hook that variant S relies on."""
    provenance = manifest.get("provenance")
    composition = provenance.get("composition") if isinstance(provenance, Mapping) else None
    inputs = composition.get("testOverlayInputs") if isinstance(composition, Mapping) else None
    if not isinstance(inputs, list):
        raise TestBundleError(
            "the composed input must record the fixed AndroidImageProduct test overlay; "
            "rebuild it with `compose --test-overlay`."
        )
    observed: dict[str, str] = {}
    for item in inputs:
        if not isinstance(item, Mapping):
            raise TestBundleError("testOverlayInputs contains a malformed record.")
        path, digest = item.get("path"), item.get("sha256")
        if not isinstance(path, str) or not isinstance(digest, str):
            raise TestBundleError("testOverlayInputs contains a malformed path or SHA-256.")
        observed[path] = digest
    if set(observed) != set(TEST_OVERLAY_INPUTS):
        raise TestBundleError(
            "the test overlay must contain exactly the fixed compose.json and "
            "init/apkrun-test.rc inputs."
        )
    repository = _repository_root().resolve()
    for relative in TEST_OVERLAY_INPUTS:
        source = repository / relative
        if source.is_symlink() or not source.is_file():
            raise TestBundleError(f"the fixed test overlay source is missing or unsafe: {relative}")
        if _sha256(source) != observed[relative]:
            raise TestBundleError(
                f"the input bundle's test overlay does not match the current fixture: {relative}"
            )


def _verify_bundle(
    bundle: Path,
    *,
    public_key: bytes,
    require_test_overlay: bool,
) -> tuple[bytes, dict[str, Any]]:
    """Verify a signed bundle's canonical file set and every listed file hash."""
    if bundle.is_symlink() or not bundle.is_dir():
        raise TestBundleError(f"{bundle} must be a real bundle directory.")
    root = bundle.resolve()
    manifest_path = root / MANIFEST_NAME
    signature_path = root / SIGNATURE_NAME
    checksums_path = root / CHECKSUMS_NAME
    for path in (manifest_path, signature_path, checksums_path):
        if path.is_symlink() or not path.is_file():
            raise TestBundleError(f"the bundle is missing a regular {path.name}.")
    manifest_bytes = manifest_path.read_bytes()
    manifest = _manifest_failure(manifest_bytes, description="input")
    if manifest.get("kind") != "apkrun":
        raise TestBundleError("the input must be a composed kind: apkrun bundle.")
    provenance = manifest.get("provenance")
    composition = provenance.get("composition") if isinstance(provenance, Mapping) else None
    if not isinstance(composition, Mapping):
        raise TestBundleError("the input must have provenance.composition.")
    if require_test_overlay:
        _required_test_overlay(manifest)
    try:
        verify_signature(
            manifest_bytes,
            signature_path.read_bytes(),
            {key_id_of(public_key): public_key},
        )
    except SignatureError as error:
        raise TestBundleError(f"the bundle signature does not verify: {error}") from None

    files = manifest.get("files")
    if not isinstance(files, list):
        raise TestBundleError("the manifest files list is missing.")
    listed_paths: set[str] = set()
    for entry in files:
        if not isinstance(entry, Mapping) or not isinstance(entry.get("path"), str):
            raise TestBundleError("the manifest has a malformed files entry.")
        relative = entry["path"]
        if relative in listed_paths:
            raise TestBundleError(f"the manifest lists {relative} more than once.")
        listed_paths.add(relative)
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise TestBundleError(f"the bundle file {relative} is missing or unsafe.")
        if _file_entry(root, relative) != dict(entry):
            raise TestBundleError(f"the bundle file {relative} differs from its manifest entry.")
    expected_files = listed_paths | META_FILES
    present_files: set[str] = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise TestBundleError(
                f"the bundle contains a symbolic link at {path.relative_to(root).as_posix()}."
            )
        if path.is_file():
            present_files.add(path.relative_to(root).as_posix())
        elif path.is_dir():
            # Empty directories and unrelated directory trees are not part of a bundle.
            relative_directory = path.relative_to(root).as_posix()
            if not any(item.startswith(relative_directory + "/") for item in expected_files):
                raise TestBundleError(
                    f"the bundle contains an unexpected directory {relative_directory}."
                )
        else:
            raise TestBundleError(
                f"the bundle contains a non-regular file at {path.relative_to(root).as_posix()}."
            )
    if present_files != expected_files:
        raise TestBundleError(
            f"the bundle file set differs from the manifest; unexpected "
            f"{sorted(present_files - expected_files)}, "
            f"missing {sorted(expected_files - present_files)}."
        )
    try:
        sums = checksums_path.read_text(encoding="ascii")
    except UnicodeDecodeError:
        raise TestBundleError("SHA256SUMS is not ASCII.") from None
    if sums != _checksums(files):
        raise TestBundleError("SHA256SUMS does not match the manifest.")
    vendor, image = _parse_bootconfig(root / manifest["boot"]["bootconfig"]["path"])
    if any(key.startswith(TEST_KEY_PREFIX) for key in (*vendor, *image)):
        raise TestBundleError("the base bundle already contains an androidboot.apkrun.test.* key.")
    _parse_cmdline(root / manifest["boot"]["cmdline"]["path"])
    return manifest_bytes, manifest


def _parse_bootconfig(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Parse and require canonical `[vendor]`/`[image]` bootconfig sections."""
    try:
        text = path.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise TestBundleError(f"{path}: cannot read ASCII bootconfig: {error}") from None
    if not text.endswith("\n"):
        raise TestBundleError("boot/bootconfig.txt must end in LF.")
    lines = text.splitlines()
    if not lines or lines[0] != "[vendor]":
        raise TestBundleError("boot/bootconfig.txt must begin with [vendor].")
    if lines.count("[vendor]") != 1 or lines.count("[image]") != 1:
        raise TestBundleError("boot/bootconfig.txt must have one vendor and one image section.")
    image_header = lines.index("[image]")
    if image_header < 1 or any(line.startswith("[") for line in lines[1:] if line != "[image]"):
        raise TestBundleError("boot/bootconfig.txt has an unexpected section.")
    try:
        vendor = parse_bootconfig_text("\n".join(lines[1:image_header]) + "\n", layer_name="vendor")
        image = parse_bootconfig_text(
            "\n".join(lines[image_header + 1 :]) + "\n", layer_name="image"
        )
    except BootconfigError as error:
        raise TestBundleError(f"boot/bootconfig.txt is invalid: {error}") from None
    canonical = (
        "[vendor]\n"
        + serialize_bootconfig(vendor).decode("ascii")
        + "[image]\n"
        + serialize_bootconfig(image).decode("ascii")
    )
    if canonical != text:
        raise TestBundleError("boot/bootconfig.txt is not in canonical sorted form.")
    return vendor, image


def _render_bootconfig(vendor: Mapping[str, str], image: Mapping[str, str]) -> bytes:
    return (
        "[vendor]\n"
        + serialize_bootconfig(vendor).decode("ascii")
        + "[image]\n"
        + serialize_bootconfig(image).decode("ascii")
    ).encode("ascii")


def _parse_cmdline(path: Path) -> list[str]:
    """Read the canonical one-line kernel command line."""
    try:
        data = path.read_bytes()
        text = data.decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise TestBundleError(f"{path}: cannot read ASCII command line: {error}") from None
    tokens = text.split(" ")
    if (
        not text
        or "\n" in text
        or "\r" in text
        or any(not token for token in tokens)
        or " ".join(tokens) != text
        or "bootconfig" not in tokens
        or any(token.startswith("androidboot.") for token in tokens)
    ):
        raise TestBundleError("boot/cmdline.txt is not a canonical Android kernel command line.")
    return tokens


def _version_for(base: str, offset: int) -> str:
    """Return a deterministic later version, rolling the image sequence across months."""
    match = IMAGE_VERSION.fullmatch(base)
    if match is None:
        raise TestBundleError("the composed bundle has an unsupported imageVersion.")
    year, month, sequence = (
        int(match.group("year")),
        int(match.group("month")),
        int(match.group("sequence")),
    )
    sequence += offset
    while sequence > 999:
        sequence -= 1000
        month += 1
        if month > 12:
            year += 1
            month = 1
    if year > 9999:
        raise TestBundleError("the test bundle version exceeds year 9999.")
    return f"{year:04d}.{month:02d}.{sequence}-{match.group('base')}-arm64"


def _try_clonefile(source: Path, destination: Path) -> bool:
    """Use APFS clonefile when available, returning false only for supported fallbacks."""
    if sys.platform != "darwin":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    clonefile = getattr(libc, "clonefile", None)
    if clonefile is None:
        return False
    clonefile.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
    clonefile.restype = ctypes.c_int
    if clonefile(os.fsencode(source), os.fsencode(destination), 0) == 0:
        return True
    error_number = ctypes.get_errno()
    if error_number in CLONE_FALLBACK_ERRNOS:
        return False
    raise OSError(error_number, os.strerror(error_number), str(destination))


def _copy_sparse(source: Path, destination: Path) -> None:
    """Copy a regular file while preserving holes when the filesystem reports extents."""
    size = source.stat().st_size
    with source.open("rb") as input_stream, destination.open("xb") as output_stream:
        output_stream.truncate(size)
        if not all(hasattr(os, item) for item in ("SEEK_DATA", "SEEK_HOLE")):
            _copy_extent(input_stream, output_stream, 0, size)
            output_stream.truncate(size)
            return
        input_fd = input_stream.fileno()
        position = 0
        try:
            while position < size:
                try:
                    data_start = os.lseek(input_fd, position, os.SEEK_DATA)
                except OSError as error:
                    if error.errno == errno.ENXIO:
                        break
                    if error.errno in CLONE_FALLBACK_ERRNOS:
                        output_stream.seek(0)
                        output_stream.truncate(0)
                        _copy_extent(input_stream, output_stream, 0, size)
                        output_stream.truncate(size)
                        return
                    raise
                data_end = os.lseek(input_fd, data_start, os.SEEK_HOLE)
                if data_end <= data_start:
                    raise TestBundleError("the filesystem returned an invalid sparse-file extent.")
                _copy_extent(input_stream, output_stream, data_start, data_end)
                position = data_end
        finally:
            output_stream.truncate(size)


def _copy_extent(input_stream: BinaryIO, output_stream: BinaryIO, start: int, end: int) -> None:
    """Copy one half-open byte range between seekable streams."""
    position = start
    while position < end:
        length = min(CHUNK_BYTES, end - position)
        input_stream.seek(position)
        data = input_stream.read(length)
        if len(data) != length:
            raise TestBundleError(f"the input bundle file ended at byte {position + len(data)}.")
        output_stream.seek(position)
        output_stream.write(data)
        position += length


def _clone_bundle(source: Path, destination: Path) -> None:
    """Create one file-by-file clone without following links."""
    destination.mkdir()
    for entry in json.loads((source / MANIFEST_NAME).read_bytes())["files"]:
        relative = entry["path"]
        source_file = source / relative
        destination_file = destination / relative
        destination_file.parent.mkdir(parents=True, exist_ok=True)
        if not _try_clonefile(source_file, destination_file):
            _copy_sparse(source_file, destination_file)
    for name in META_FILES:
        shutil.copyfile(source / name, destination / name)


def _rewrite_manifest_files(manifest: dict[str, Any], root: Path, changed: str) -> None:
    """Refresh only the one manifest file record whose bytes the variant changed."""
    entry = next((item for item in manifest["files"] if item["path"] == changed), None)
    if entry is None:
        raise TestBundleError(f"the manifest does not list {changed}.")
    refreshed = _file_entry(root, changed)
    entry.update(refreshed)
    for boot_entry in manifest["boot"].values():
        if isinstance(boot_entry, dict) and boot_entry.get("path") == changed:
            boot_entry.update(refreshed)


def _write_variant(
    *,
    base_bundle: Path,
    output_bundle: Path,
    base_manifest: Mapping[str, Any],
    variant: _Variant,
    signing_key: Ed25519PrivateKey,
) -> None:
    """Clone one base bundle, apply one fixed variant, sign, and validate it."""
    _clone_bundle(base_bundle, output_bundle)
    if variant.name == "A":
        return
    manifest = json.loads(json.dumps(base_manifest))
    image_version = _version_for(str(base_manifest["imageVersion"]), variant.version_offset)
    manifest["imageVersion"] = image_version

    changed: set[str] = set()
    if variant.bootconfig:
        vendor, image = _parse_bootconfig(output_bundle / "boot/bootconfig.txt")
        if any(key.startswith(TEST_KEY_PREFIX) for key in (*vendor, *image)):
            raise TestBundleError(
                "the base bundle already contains an androidboot.apkrun.test.* key."
            )
        image.update(variant.bootconfig)
        (output_bundle / "boot/bootconfig.txt").write_bytes(_render_bootconfig(vendor, image))
        changed.add("boot/bootconfig.txt")
    if variant.missing_init:
        tokens = _parse_cmdline(output_bundle / "boot/cmdline.txt")
        init_tokens = [index for index, token in enumerate(tokens) if token.startswith("init=")]
        if len(init_tokens) != 1:
            raise TestBundleError("P requires exactly one init= token in boot/cmdline.txt.")
        tokens[init_tokens[0]] = "init=/apkrun-test-missing"
        (output_bundle / "boot/cmdline.txt").write_text(" ".join(tokens), encoding="ascii")
        changed.add("boot/cmdline.txt")

    for relative in changed:
        _rewrite_manifest_files(manifest, output_bundle, relative)
    manifest_violations = validate(manifest)
    if manifest_violations:
        first = manifest_violations[0]
        raise TestBundleError(
            f"{variant.name} manifest fails {first.rule} at {first.path}: {first.reason}"
        )
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    (output_bundle / MANIFEST_NAME).write_bytes(manifest_bytes)
    (output_bundle / CHECKSUMS_NAME).write_text(_checksums(manifest["files"]), encoding="ascii")
    (output_bundle / SIGNATURE_NAME).write_bytes(render_signature(manifest_bytes, signing_key))
    # Recheck metadata/signature after the write without hashing the cloned multi-gigabyte disks.
    public_key = signing_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    verify_signature(
        manifest_bytes,
        (output_bundle / SIGNATURE_NAME).read_bytes(),
        {key_id_of(public_key): public_key},
    )


def build_test_bundles(
    *,
    bundle: Path,
    sign_key: Path,
    output_directory: Path,
) -> dict[str, str]:
    """Build A, B, B-prime, F, P, and S from one verified composed test bundle."""
    source = bundle.expanduser()
    output = output_directory.expanduser()
    key = _load_signing_key(sign_key)
    public_key = key.public_key().public_bytes_raw()
    manifest_bytes, manifest = _verify_bundle(
        source,
        public_key=public_key,
        require_test_overlay=True,
    )
    version = str(manifest["imageVersion"])
    for variant in VARIANTS:
        _version_for(version, variant.version_offset)

    source_root = source.resolve()
    output_root = output.parent.resolve(strict=False) / output.name
    if (
        output_root == source_root
        or source_root in output_root.parents
        or output_root in source_root.parents
    ):
        raise TestBundleError("the output directory must be separate from the input bundle.")
    if output.exists() or output.is_symlink():
        raise TestBundleError(f"{output} already exists; choose a new output directory.")
    output_root.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(
        tempfile.mkdtemp(prefix=f".{output_root.name}.test-bundles-", dir=output_root.parent)
    )
    try:
        results: dict[str, str] = {}
        for variant in VARIANTS:
            destination = stage / variant.name
            _write_variant(
                base_bundle=source_root,
                output_bundle=destination,
                base_manifest=manifest,
                variant=variant,
                signing_key=key,
            )
            # Ensure the newly written manifest remains schema-valid. Base file data is checked
            # once above; variants only write boot files and signed metadata.
            written_manifest = (destination / MANIFEST_NAME).read_bytes()
            checked = _manifest_failure(written_manifest, description=variant.name)
            if checked["imageVersion"] != _version_for(version, variant.version_offset):
                raise TestBundleError(f"{variant.name} has an unexpected imageVersion.")
            results[variant.name] = checked["imageVersion"]
        os.replace(stage, output_root)
        return results
    finally:
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    """Build the opt-in `test-bundles` command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image test-bundles",
        description="Build signed Android T2 test variants from a composed test image.",
    )
    parser.add_argument(
        "--bundle",
        required=True,
        type=Path,
        help="signed composed input bundle made with compose --test-overlay",
    )
    parser.add_argument(
        "--sign-key",
        required=True,
        type=Path,
        help="the Ed25519 private key that signed the input bundle",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="new output directory for A, B, B-prime, F, P, and S test bundles",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Build all fixed test bundles and print their image identities."""
    arguments = build_parser().parse_args(argv)
    try:
        versions = build_test_bundles(
            bundle=arguments.bundle,
            sign_key=arguments.sign_key,
            output_directory=arguments.out,
        )
    except (OSError, SignatureError, TestBundleError, ValueError) as error:
        print(f"apkrun_image test-bundles: {error}", file=sys.stderr)
        return 2
    for name, version in versions.items():
        print(f"{name}: {arguments.out.expanduser() / name} ({version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
