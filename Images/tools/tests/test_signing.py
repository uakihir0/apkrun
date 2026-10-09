"""Tests for manifest.sig and key generation (runtime-image-manifest.md §6.1; #065)."""

from __future__ import annotations

import base64
import hashlib
import json
import stat
from pathlib import Path
from typing import Any

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from apkrun_image.keygen import KeygenError, write_key_pair
from apkrun_image.keygen import main as keygen_main
from apkrun_image.sign import (
    SignatureError,
    decode_public_key,
    encode_public_key,
    key_id_of,
    load_private_key,
    parse_signature,
    render_signature,
    verify_signature,
)

TESTS = Path(__file__).parent
VECTORS = TESTS / "fixtures/signing/image-signature-vectors.json"
TEST_KEY = TESTS.parents[2] / "Tests/Fixtures/signing/test-image-ed25519"


def _vectors() -> dict[str, Any]:
    return json.loads(VECTORS.read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", _vectors()["cases"], ids=lambda case: str(case["name"]))
def test_vector_outcomes_match_the_hand_written_expectations(case: dict[str, Any]) -> None:
    keys = _vectors()["keys"]
    trusted = {
        keys[name]["keyID"]: base64.b64decode(keys[name]["publicKey"])
        for name in case["trustedKeys"]
    }
    message = base64.b64decode(case["message"])
    signature_file = case["signatureFile"].encode("utf-8")
    if case["expected"] == "ok":
        parsed = verify_signature(message, signature_file, trusted)
        assert parsed.key_id == case["keyID"]
        return
    with pytest.raises(SignatureError) as error:
        verify_signature(message, signature_file, trusted)
    assert error.value.kind == case["expected"]
    if case["keyID"] is not None and error.value.kind != "manifestInvalid":
        assert error.value.key_id == case["keyID"]


def test_key_id_is_the_first_eight_bytes_of_sha256_in_lowercase_hex() -> None:
    public_key = bytes(range(32))
    assert key_id_of(public_key) == hashlib.sha256(public_key).hexdigest()[:16]
    with pytest.raises(SignatureError):
        key_id_of(bytes(31))


def test_a_signature_round_trips_with_a_generated_key() -> None:
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes_raw()
    message = b'{"imageVersion": "2026.10.0-cf1-arm64"}\n'
    signature_file = render_signature(message, private_key)
    assert signature_file.endswith(b"\n")
    assert signature_file.count(b"\n") == 4
    verify_signature(message, signature_file, {key_id_of(public_key): public_key})
    with pytest.raises(SignatureError) as error:
        verify_signature(message + b" ", signature_file, {key_id_of(public_key): public_key})
    assert error.value.kind == "signatureInvalid"


def test_the_committed_test_key_matches_its_public_file() -> None:
    private_key = load_private_key(TEST_KEY)
    public_file = (TEST_KEY.parent / "test-image-ed25519.pub").read_text(encoding="ascii")
    assert decode_public_key(public_file) == private_key.public_key().public_bytes_raw()


def test_keygen_writes_a_private_key_and_a_base64_public_key(tmp_path: Path) -> None:
    out = tmp_path / "dev-image-key"
    key_id = write_key_pair(out)
    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    public_file = out.with_name("dev-image-key.pub")
    assert stat.S_IMODE(public_file.stat().st_mode) == 0o644
    public_key = decode_public_key(public_file.read_text(encoding="ascii"))
    assert len(public_key) == 32
    assert key_id_of(public_key) == key_id
    assert public_file.read_text(encoding="ascii") == encode_public_key(public_key)
    assert public_file.read_text(encoding="ascii").count("\n") == 1


def test_keygen_never_overwrites_an_existing_key(tmp_path: Path) -> None:
    out = tmp_path / "dev-image-key"
    write_key_pair(out)
    before = out.read_bytes()
    with pytest.raises(KeygenError, match="already exists"):
        write_key_pair(out)
    assert out.read_bytes() == before


def test_keygen_command_reports_a_refusal(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "dev-image-key"
    assert keygen_main(["--out", str(out)]) == 0
    assert keygen_main(["--out", str(out)]) == 2
    assert "already exists" in capsys.readouterr().err


def test_the_parser_rejects_a_signature_file_with_an_unknown_tag() -> None:
    private_key = Ed25519PrivateKey.generate()
    text = render_signature(b"message", private_key).decode("ascii")
    with pytest.raises(SignatureError, match="format tag"):
        parse_signature(text.replace("apkrun-signature-v1", "apkrun-signature-v0").encode())
