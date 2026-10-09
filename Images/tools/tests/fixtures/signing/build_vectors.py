"""Write `image-signature-vectors.json`, the manifest.sig vectors shared by Python and Swift.

Run from `Images/tools` with the image-tools virtualenv:

    python3 tests/fixtures/signing/build_vectors.py

The private key is `Tests/Fixtures/signing/test-image-ed25519` (a test key). The
second key, `other`, is derived from a fixed seed, so the vectors are reproducible.
Every expected outcome is written here by hand. The Python and Swift tests check
the code against these outcomes, not against each other.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[4]
sys.path.insert(0, str(HERE.parents[2]))

from apkrun_image.sign import (  # noqa: E402
    decode_public_key,
    key_id_of,
    load_private_key,
    render_signature,
)

TEST_KEY = REPOSITORY / "Tests/Fixtures/signing/test-image-ed25519"
TEST_PUBLIC = REPOSITORY / "Tests/Fixtures/signing/test-image-ed25519.pub"
OUTPUT = HERE / "image-signature-vectors.json"

MESSAGE = b'{\n  "schemaVersion": 1,\n  "imageVersion": "2026.10.0-cf16373615-arm64"\n}\n'


def public_bytes(key: Ed25519PrivateKey) -> bytes:
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def replace_signature(text: str, encoded: str) -> str:
    lines = text.split("\n")
    lines[3] = f"signature: {encoded}"
    return "\n".join(lines)


def main() -> int:
    test_private = load_private_key(TEST_KEY)
    test_public = decode_public_key(TEST_PUBLIC.read_text(encoding="ascii"))
    if public_bytes(test_private) != test_public:
        raise SystemExit("the test private key does not match the committed .pub file")
    other_private = Ed25519PrivateKey.from_private_bytes(
        hashlib.sha256(b"apkrun-test-image-other").digest()
    )
    other_public = public_bytes(other_private)
    test_id = key_id_of(test_public)
    other_id = key_id_of(other_public)

    good = render_signature(MESSAGE, test_private).decode("ascii")
    signature = base64.b64decode(good.split("\n")[3][len("signature: ") :])
    flipped = bytearray(signature)
    flipped[0] ^= 0x01
    tampered_message = MESSAGE.replace(b"1,", b"2,", 1)
    unknown_id = "0123456789abcdef"
    other_header = good.replace(f"key-id: {test_id}", f"key-id: {other_id}")
    cases = [
        ("valid-test-key", MESSAGE, good, ["test"], "ok", test_id),
        ("valid-among-several-keys", MESSAGE, good, ["other", "test"], "ok", test_id),
        ("message-byte-changed", tampered_message, good, ["test"], "signatureInvalid", test_id),
        (
            "key-id-unknown",
            MESSAGE,
            good.replace(test_id, unknown_id),
            ["test"],
            "untrustedKey",
            unknown_id,
        ),
        ("no-trusted-keys", MESSAGE, good, [], "untrustedKey", test_id),
        (
            "key-id-selects-other-trusted-key",
            MESSAGE,
            other_header,
            ["other", "test"],
            "signatureInvalid",
            other_id,
        ),
        (
            "signature-bit-flipped",
            MESSAGE,
            replace_signature(good, b64(bytes(flipped))),
            ["test"],
            "signatureInvalid",
            test_id,
        ),
        (
            "signature-63-bytes",
            MESSAGE,
            replace_signature(good, b64(signature[:63])),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        (
            "signature-not-base64",
            MESSAGE,
            replace_signature(good, "not base64!!"),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        ("extra-line", MESSAGE, good + "extra: x\n", ["test"], "manifestInvalid", test_id),
        (
            "crlf-line-ends",
            MESSAGE,
            good.replace("\n", "\r\n"),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        ("missing-final-lf", MESSAGE, good[:-1], ["test"], "manifestInvalid", test_id),
        (
            "wrong-format-tag",
            MESSAGE,
            good.replace("apkrun-signature-v1", "apkrun-signature-v2"),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        (
            "wrong-algorithm",
            MESSAGE,
            good.replace("algorithm: ed25519", "algorithm: ed448"),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        (
            "uppercase-key-id",
            MESSAGE,
            good.replace(test_id, test_id.upper()),
            ["test"],
            "manifestInvalid",
            None,
        ),
        (
            "non-ascii-byte",
            MESSAGE,
            good.replace("ed25519", "ed25519é"),
            ["test"],
            "manifestInvalid",
            test_id,
        ),
        ("larger-than-4-kib", MESSAGE, good + "a" * 4096, ["test"], "manifestInvalid", None),
    ]

    keys = {
        "test": {"keyID": test_id, "publicKey": b64(test_public)},
        "other": {"keyID": other_id, "publicKey": b64(other_public)},
    }
    document = {
        "schemaVersion": 1,
        "keys": keys,
        "cases": [
            {
                "name": name,
                "message": b64(message),
                "signatureFile": signature_file,
                "trustedKeys": trusted,
                "expected": expected,
                "keyID": key_id,
            }
            for name, message, signature_file, trusted, expected, key_id in cases
        ],
    }
    OUTPUT.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPOSITORY)} with {len(cases)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
