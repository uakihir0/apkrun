"""Ed25519 signatures for runtime image bundles (runtime-image-manifest.md §6.1).

`manifest.sig` has exactly four ASCII lines, each ending in LF: the format tag,
the key ID, the algorithm, and the standard base64 signature over the exact
bytes of `manifest.json`. The key ID is the first 8 bytes of SHA-256 over the
raw 32-byte public key, in lowercase hex. The header is not signed, so a changed
key ID only selects another key, and the check still fails.

ImageCore's `ImageSignature` reads the same format. Both sides check the vectors
in `Images/tools/tests/fixtures/signing/image-signature-vectors.json`.
"""

from __future__ import annotations

import base64
import hashlib
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

SIGNATURE_TAG = "apkrun-signature-v1"
ALGORITHM = "ed25519"
MAX_SIGNATURE_BYTES = 4096
PUBLIC_KEY_BYTES = 32
SIGNATURE_BYTES = 64
_KEY_ID_PATTERN = re.compile(r"[0-9a-f]{16}")


class SignatureError(ValueError):
    """`manifest.sig` does not parse, names no trusted key, or does not verify.

    `kind` is `manifestInvalid`, `untrustedKey`, or `signatureInvalid`, the
    `ImageFailure` case the Swift reader raises for the same input.
    """

    def __init__(self, kind: str, detail: str, key_id: str | None = None) -> None:
        super().__init__(detail)
        self.kind = kind
        self.key_id = key_id


@dataclass(frozen=True)
class ParsedSignature:
    """The fields of a parsed `manifest.sig`."""

    key_id: str
    signature: bytes


def key_id_of(public_key: bytes) -> str:
    """Return the key ID of a raw 32-byte Ed25519 public key."""
    if len(public_key) != PUBLIC_KEY_BYTES:
        raise SignatureError("manifestInvalid", "public key must be 32 bytes")
    return hashlib.sha256(public_key).hexdigest()[:16]


def render_signature(message: bytes, private_key: Ed25519PrivateKey) -> bytes:
    """Return the `manifest.sig` bytes for `message`."""
    public = private_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    signature = private_key.sign(message)
    text = (
        f"{SIGNATURE_TAG}\n"
        f"key-id: {key_id_of(public)}\n"
        f"algorithm: {ALGORITHM}\n"
        f"signature: {base64.b64encode(signature).decode('ascii')}\n"
    )
    return text.encode("ascii")


def parse_signature(data: bytes) -> ParsedSignature:
    """Parse `manifest.sig` strictly (runtime-image-manifest.md §6.1)."""
    if len(data) > MAX_SIGNATURE_BYTES:
        raise SignatureError("manifestInvalid", "manifest.sig is larger than 4 KiB")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise SignatureError("manifestInvalid", "manifest.sig is not ASCII") from None
    lines = text.split("\n")
    if len(lines) != 5 or lines[4] != "" or not text.endswith("\n") or "\r" in text:
        raise SignatureError("manifestInvalid", "manifest.sig must be four LF-terminated lines")
    if lines[0] != SIGNATURE_TAG:
        raise SignatureError("manifestInvalid", "manifest.sig has an unknown format tag")
    if not lines[1].startswith("key-id: "):
        raise SignatureError("manifestInvalid", "manifest.sig has no key-id line")
    key_id = lines[1][len("key-id: ") :]
    if not _KEY_ID_PATTERN.fullmatch(key_id):
        raise SignatureError(
            "manifestInvalid", "manifest.sig key ID is not 16 lowercase hex digits"
        )
    if lines[2] != f"algorithm: {ALGORITHM}":
        raise SignatureError("manifestInvalid", "manifest.sig algorithm is not ed25519")
    if not lines[3].startswith("signature: "):
        raise SignatureError("manifestInvalid", "manifest.sig has no signature line")
    try:
        signature = base64.b64decode(lines[3][len("signature: ") :], validate=True)
    except ValueError:
        raise SignatureError("manifestInvalid", "manifest.sig signature is not base64") from None
    if len(signature) != SIGNATURE_BYTES:
        raise SignatureError("manifestInvalid", "manifest.sig signature is not 64 bytes")
    return ParsedSignature(key_id=key_id, signature=signature)


def verify_signature(
    message: bytes, signature_file: bytes, trusted_keys: Mapping[str, bytes]
) -> ParsedSignature:
    """Check `signature_file` over `message` against `trusted_keys` (key ID to raw key).

    The order matches the reader: parse, then trust, then the signature.
    """
    parsed = parse_signature(signature_file)
    public_key = trusted_keys.get(parsed.key_id)
    if public_key is None:
        raise SignatureError("untrustedKey", "no trusted key has this ID", parsed.key_id)
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(parsed.signature, message)
    except (InvalidSignature, ValueError):
        raise SignatureError(
            "signatureInvalid", "the signature does not verify", parsed.key_id
        ) from None
    return parsed


def encode_public_key(public_key: bytes) -> str:
    """Render the `.pub` file: base64 of the raw key on one line (§6.1)."""
    return base64.b64encode(public_key).decode("ascii") + "\n"


def decode_public_key(text: str) -> bytes:
    """Parse a `.pub` file; reject anything that is not one 32-byte key."""
    stripped = text.strip()
    try:
        key = base64.b64decode(stripped, validate=True)
    except ValueError:
        raise SignatureError("manifestInvalid", "public key file is not base64") from None
    if len(key) != PUBLIC_KEY_BYTES:
        raise SignatureError("manifestInvalid", "public key file does not hold a 32-byte key")
    return key


def load_private_key(path: Path) -> Ed25519PrivateKey:
    """Load a PKCS#8 PEM Ed25519 private key."""
    key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise SignatureError("manifestInvalid", f"{path} is not an Ed25519 private key")
    return key


def private_key_pem(private_key: Ed25519PrivateKey) -> bytes:
    """Serialize a key as PKCS#8 PEM with no encryption."""
    return private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
