"""Make a development bundle whose boot ramdisk is replaced, with the bundle tool's own functions (#022).

`python -m apkrun_image bundle-variant` replaces a logical partition of `super`. The boot ramdisk
is the file `boot/ramdisk.img`, and no command replaces it. This script does what `build_variant`
does after a file changes: the file entry, the boot record, the checksums, the validation, and the
signature come from the bundle tool (`_file_entry`, `_checksums`, `validate`, `render_signature`,
`verify_signature`). No hash is typed by hand.

The source bundle is checked first: its manifest signature verifies with the developer key, its
SHA256SUMS matches its manifest, and each file matches its entry. The output bundle is new.

Usage (run with the Images/tools venv, from any directory):
  <venv python> -B refresh_bundle.py <source bundle> <new ramdisk.img> <out bundle dir>
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Images" / "tools"))

from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402

from apkrun_image.bundle import _checksums, _file_entry, _load_signing_key  # noqa: E402
from apkrun_image.runtime_manifest import validate  # noqa: E402
from apkrun_image.sign import key_id_of, render_signature, verify_signature  # noqa: E402

RAMDISK = "boot/ramdisk.img"
KEY = Path("~/.config/apkrun/dev-image-key").expanduser()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    source, ramdisk_path, out = Path(argv[1]), Path(argv[2]), Path(argv[3])
    if out.exists():
        raise SystemExit(f"{out} exists; the output bundle must be new")

    key = _load_signing_key(KEY)
    public_key = key.public_key().public_bytes(encoding=Encoding.Raw, format=PublicFormat.Raw)
    key_id = key_id_of(public_key)
    keys = {key_id: public_key}

    manifest_bytes = (source / "manifest.json").read_bytes()
    verify_signature(manifest_bytes, (source / "manifest.sig").read_bytes(), keys)
    manifest = json.loads(manifest_bytes)
    violations = validate(manifest)
    if violations:
        first = violations[0]
        raise SystemExit(f"the source manifest fails {first.rule} at {first.path}: {first.reason}")
    files = [_file_entry(source, entry["path"]) for entry in manifest["files"]]
    if (source / "SHA256SUMS").read_text(encoding="ascii") != _checksums(files):
        raise SystemExit("the source SHA256SUMS does not match its manifest")
    if files != manifest["files"]:
        raise SystemExit("the source file entries do not match the files")
    listed = {entry["path"] for entry in manifest["files"]} | {"manifest.json", "manifest.sig", "SHA256SUMS"}
    present = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
    if present != listed:
        raise SystemExit(f"the source bundle has files that the manifest does not list: {sorted(present - listed)}")

    shutil.copytree(source, out, symlinks=False)
    try:
        os.chmod(out / RAMDISK, 0o644)
        (out / RAMDISK).write_bytes(ramdisk_path.read_bytes())

        new_files = [_file_entry(out, entry["path"]) for entry in manifest["files"]]
        by_path = {entry["path"]: entry for entry in new_files}
        manifest["boot"]["ramdisk"] = by_path[RAMDISK]
        manifest["files"] = new_files
        violations = validate(manifest)
        if violations:
            first = violations[0]
            raise SystemExit(
                f"the refreshed manifest fails {first.rule} at {first.path}: {first.reason}"
            )

        new_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        (out / "manifest.json").write_bytes(new_bytes)
        (out / "SHA256SUMS").write_text(_checksums(new_files), encoding="ascii")
        signature = render_signature(new_bytes, key)
        (out / "manifest.sig").write_bytes(signature)
        verify_signature(new_bytes, signature, keys)
    except BaseException:
        shutil.rmtree(out, ignore_errors=True)
        raise

    print(f"source manifest.json sha256 {sha256(manifest_bytes)} (signature verified)")
    print(f"ramdisk {by_path[RAMDISK]['size']} bytes sha256 {by_path[RAMDISK]['sha256']}")
    print(f"out manifest.json sha256 {sha256(new_bytes)}")
    print(f"out SHA256SUMS sha256 {sha256((out / 'SHA256SUMS').read_bytes())}")
    print(f"out manifest.sig key id {key_id} (verified)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
