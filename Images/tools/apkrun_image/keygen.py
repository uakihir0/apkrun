"""Create the Ed25519 key pair that signs runtime image bundles (#065).

`python3 -m apkrun_image keygen --out ~/.config/apkrun/dev-image-key` writes the
PKCS#8 PEM private key to `--out` (mode 0600) and the base64 public key to
`--out.pub` (runtime-image-manifest.md §6.1). An existing file is never
overwritten: a key that signed a bundle must stay, or that bundle cannot be
checked again.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Sequence
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from apkrun_image.sign import encode_public_key, key_id_of, private_key_pem


class KeygenError(ValueError):
    """The key pair cannot be written."""


def write_key_pair(out: Path) -> str:
    """Write the private key and its `.pub` file; return the key ID."""
    out = out.expanduser()
    public_path = out.with_name(out.name + ".pub")
    for path in (out, public_path):
        if path.exists() or path.is_symlink():
            raise KeygenError(f"{path} already exists; choose another --out or keep the key")
    out.parent.mkdir(parents=True, exist_ok=True)

    private_key = Ed25519PrivateKey.generate()
    public_raw = private_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    # O_EXCL keeps a racing keygen from replacing a key that was just written.
    descriptor = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(private_key_pem(private_key))
    descriptor = os.open(public_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write(encode_public_key(public_raw))
    return key_id_of(public_raw)


def build_parser() -> argparse.ArgumentParser:
    """Build the keygen command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image keygen",
        description="Create an Ed25519 key pair for signing image bundles.",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="private key path; the public key goes to the same path with .pub appended",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Write the key pair and report where it went."""
    arguments = build_parser().parse_args(argv)
    try:
        key_id = write_key_pair(arguments.out)
    except (KeygenError, OSError) as error:
        print(f"apkrun_image keygen: {error}", file=sys.stderr)
        return 2
    print(f"keygen: wrote {arguments.out.expanduser()} (key ID {key_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
