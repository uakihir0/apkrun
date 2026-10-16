#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if (($# < 1 || $# > 2)); then
    printf 'usage: scripts/release/check-release-build.sh <APKRun.app> [<image bundle>]\n' >&2
    exit 2
fi

app_bundle="$1"
if [[ ! -d "$app_bundle" ]]; then
    printf 'check-release-build: app bundle does not exist: %s\n' "$app_bundle" >&2
    exit 1
fi
if (($# == 2)) && [[ ! -e "$2" ]]; then
    printf 'check-release-build: image bundle does not exist: %s\n' "$2" >&2
    exit 1
fi

python3 - "$repo_root" "$app_bundle" "${2:-}" <<'PY'
import base64
import binascii
import hashlib
import importlib.util
import json
import math
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile

repository = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2]).resolve()
image_bundle = pathlib.Path(sys.argv[3]).resolve() if len(sys.argv) > 3 and sys.argv[3] else None
signing_fixtures = repository / "Tests/Fixtures/signing"
failures = []

notice_path = app / "Contents/Resources/ThirdPartyNotices.html"
notices_script = repository / "scripts/release/generate-notices.py"
notice_spec = importlib.util.spec_from_file_location("apkrun_generate_notices", notices_script)
if notice_spec is None or notice_spec.loader is None:
    failures.append(f"{notices_script}: could not load the notices generator")
else:
    notices_module = importlib.util.module_from_spec(notice_spec)
    try:
        notice_spec.loader.exec_module(notices_module)
        expected_notices = notices_module.generate_html(
            repository,
            json.loads((repository / "ThirdParty/ThirdParty.lock.json").read_text(encoding="utf-8")),
        )
        actual_notices = notice_path.read_text(encoding="utf-8")
        if actual_notices != expected_notices:
            failures.append(f"{notice_path}: notices differ from the current locked components")
    except Exception as error:
        failures.append(f"{notice_path}: could not verify third-party notices: {error}")

hook_patterns = (
    re.compile(r"APKRUN_[A-Z0-9_]*_FAULT"),
    re.compile(r"APKRUN_TEST_[A-Z0-9_]+"),
    re.compile(r"APKRUN_LAUNCHER_TEST_NO_RUNTIME"),
    re.compile(r"ReleaseUpdateTest"),
    # The developer image key is read only in Debug builds (ImageTrustStore.standard).
    re.compile(r"dev-image-key"),
)

def parse_ed25519_public_key(data):
    text = data.decode("ascii", "ignore")
    stripped = "".join(line.strip() for line in text.splitlines())
    if len(stripped) == 64 and re.fullmatch(r"[0-9a-fA-F]{64}", stripped):
        return bytes.fromhex(stripped)
    if len(data) == 32:
        return data

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    encoded = ""
    if len(lines) >= 2 and lines[0] == "ssh-ed25519":
        encoded = lines[1]
    elif lines and lines[0].startswith("ssh-ed25519 "):
        encoded = lines[0].split()[1]
    else:
        encoded = "".join(line for line in lines if not line.startswith("-----"))
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        return None
    if len(decoded) == 32:
        return decoded

    spki_prefix = bytes.fromhex("302a300506032b6570032100")
    if len(decoded) == len(spki_prefix) + 32 and decoded.startswith(spki_prefix):
        return decoded[-32:]

    cursor = 0
    if len(decoded) >= 4:
        algorithm_length = int.from_bytes(decoded[cursor : cursor + 4], "big")
        cursor += 4
        algorithm = decoded[cursor : cursor + algorithm_length]
        cursor += algorithm_length
        if algorithm == b"ssh-ed25519" and len(decoded) >= cursor + 4:
            key_length = int.from_bytes(decoded[cursor : cursor + 4], "big")
            cursor += 4
            key = decoded[cursor : cursor + key_length]
            if key_length == 32 and len(key) == 32 and cursor + key_length == len(decoded):
                return key
    return None

def parse_pkcs8_private_key(data):
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return None
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 3 or lines[0] != "-----BEGIN PRIVATE KEY-----" or lines[-1] != "-----END PRIVATE KEY-----":
        return None
    try:
        decoded = base64.b64decode("".join(lines[1:-1]), validate=True)
    except (ValueError, binascii.Error):
        return None
    rsa_oid = b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"
    ed25519_oid = b"\x06\x03\x2b\x65\x70"
    if len(decoded) < 16 or decoded[0] != 0x30 or (rsa_oid not in decoded and ed25519_oid not in decoded):
        return None
    return decoded

def read_der_value(data, offset, tag):
    value = read_der_any_value(data, offset)
    if value is None or value[0] != tag:
        return None
    return value[1], value[2]

def read_der_any_value(data, offset):
    if offset >= len(data) or data[offset] & 0x1f == 0x1f or offset + 1 >= len(data):
        return None
    tag = data[offset]
    offset += 1
    first_length = data[offset]
    offset += 1
    if first_length < 0x80:
        length = first_length
    else:
        length_bytes = first_length & 0x7f
        if length_bytes == 0 or length_bytes > 4 or offset + length_bytes > len(data):
            return None
        if data[offset] == 0:
            return None
        length = int.from_bytes(data[offset : offset + length_bytes], "big")
        if length < 0x80 or length < 1 << (8 * (length_bytes - 1)):
            return None
        offset += length_bytes
    end = offset + length
    if end > len(data):
        return None
    return tag, data[offset:end], end

ENCRYPTED_PRIVATE_KEY_OIDS = (
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x01",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x03",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x04",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x06",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x0a",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x0b",
    b"\x2a\x86\x48\x86\xf7\x0d\x01\x05\x0d",
)
ENCRYPTED_PRIVATE_KEY_OID_PATTERN = re.compile(
    b"|".join(
        re.escape(b"\x06" + bytes([len(oid)]) + oid)
        for oid in ENCRYPTED_PRIVATE_KEY_OIDS
    )
)
def contains_encrypted_pkcs8(data):
    for oid_match in ENCRYPTED_PRIVATE_KEY_OID_PATTERN.finditer(data):
        oid = data[oid_match.start() + 2 : oid_match.end()]
        for start in range(max(0, oid_match.start() - 16), oid_match.start()):
            if data[start] != 0x30:
                continue
            sequence = read_der_value(data, start, 0x30)
            if sequence is None:
                continue
            sequence_contents, _sequence_end = sequence
            algorithm = read_der_value(sequence_contents, 0, 0x30)
            if algorithm is None:
                continue
            algorithm_contents, algorithm_end = algorithm
            algorithm_oid = read_der_value(algorithm_contents, 0, 0x06)
            if algorithm_oid is None or algorithm_oid[0] != oid:
                continue
            parameter_end = algorithm_oid[1]
            if parameter_end < len(algorithm_contents):
                parameter = read_der_any_value(algorithm_contents, parameter_end)
                if parameter is None or parameter[2] != len(algorithm_contents):
                    continue
                parameter_end = parameter[2]
            if parameter_end != len(algorithm_contents):
                continue
            encrypted_data = read_der_value(sequence_contents, algorithm_end, 0x04)
            if encrypted_data is None or not encrypted_data[0]:
                continue
            if encrypted_data[1] == len(sequence_contents):
                return True
    return False

def append_base64_der_fragment(candidate, fragment):
    candidate["encoded_length"] += len(fragment)
    if candidate["encoded_length"] > MAX_BASE64_DER_CANDIDATE_CHARS:
        if ENCRYPTED_PRIVATE_KEY_OID_PATTERN.search(candidate["decoded"][:128]):
            return "too-large"
        return "invalid"
    encoded = candidate["pending"] + fragment
    padding_index = encoded.find(b"=")
    if padding_index >= 0:
        padding_end = padding_index
        while padding_end < len(encoded) and encoded[padding_end] == ord("="):
            padding_end += 1
        padded = encoded[:padding_end]
        if len(padded) % 4:
            return "invalid"
        try:
            candidate["decoded"].extend(
                base64.b64decode(
                    padded.translate(BASE64_URLSAFE_TRANSLATION), validate=True
                )
            )
        except (ValueError, binascii.Error):
            return "invalid"
        candidate["pending"] = b""
        if contains_encrypted_pkcs8(candidate["decoded"]):
            return "encrypted-key"
        return "complete"
    complete_length = len(encoded) - len(encoded) % 4
    complete = encoded[:complete_length]
    remainder = encoded[complete_length:]
    if complete:
        try:
            decoded = base64.b64decode(
                complete.translate(BASE64_URLSAFE_TRANSLATION), validate=True
            )
        except (ValueError, binascii.Error):
            return "invalid"
        candidate["decoded"].extend(decoded)
        candidate["pending"] = remainder
    else:
        candidate["pending"] = remainder
    if (
        len(candidate["decoded"]) >= 128
        and not ENCRYPTED_PRIVATE_KEY_OID_PATTERN.search(candidate["decoded"][:128])
    ):
        return "invalid"
    if len(candidate["decoded"]) >= candidate["next_check"]:
        candidate["next_check"] = len(candidate["decoded"]) + 64
        if contains_encrypted_pkcs8(candidate["decoded"]):
            return "encrypted-key"
    return "ok"

def finish_base64_der_candidate(candidate):
    if len(candidate["pending"]) in (2, 3):
        padded = candidate["pending"] + b"=" * (4 - len(candidate["pending"]))
        try:
            candidate["decoded"].extend(
                base64.b64decode(
                    padded.translate(BASE64_URLSAFE_TRANSLATION), validate=True
                )
            )
        except (ValueError, binascii.Error):
            return False
    return contains_encrypted_pkcs8(candidate["decoded"])

def parse_pkcs1_rsa_private_key(data):
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return None
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 3 or lines[0] != "-----BEGIN RSA PRIVATE KEY-----" or lines[-1] != "-----END RSA PRIVATE KEY-----":
        return None
    try:
        decoded = base64.b64decode("".join(lines[1:-1]), validate=True)
    except (ValueError, binascii.Error):
        return None
    sequence = read_der_value(decoded, 0, 0x30)
    if sequence is None:
        return None
    contents, sequence_end = sequence
    if sequence_end != len(decoded):
        return None
    integers = []
    integer_bytes = []
    offset = 0
    while offset < len(contents):
        item = read_der_value(contents, offset, 0x02)
        if item is None:
            return None
        encoded_integer, offset = item
        if not encoded_integer or encoded_integer[0] & 0x80:
            return None
        if len(encoded_integer) > 1 and encoded_integer[0] == 0 and encoded_integer[1] & 0x80 == 0:
            return None
        integers.append(int.from_bytes(encoded_integer, "big"))
        integer_bytes.append(encoded_integer)
    if len(integers) != 9 or integers[0] != 0 or any(value == 0 for value in integers[1:]):
        return None
    (
        modulus,
        public_exponent,
        private_exponent,
        prime1,
        prime2,
        exponent1,
        exponent2,
        coefficient,
    ) = integers[1:]
    modulus_bits = modulus.bit_length()
    if (
        not 2048 <= modulus_bits <= 8192
        or public_exponent < 3
        or public_exponent % 2 == 0
    ):
        return None
    if modulus != prime1 * prime2:
        return None
    prime_floor = modulus_bits // 2 - 128
    if min(prime1.bit_length(), prime2.bit_length()) < prime_floor:
        return None
    private_floor = modulus_bits // 2 - 128
    if min(
        private_exponent.bit_length(),
        exponent1.bit_length(),
        exponent2.bit_length(),
        coefficient.bit_length(),
    ) < private_floor:
        return None
    totient = ((prime1 - 1) // math.gcd(prime1 - 1, prime2 - 1)) * (prime2 - 1)
    if (
        public_exponent * private_exponent % totient != 1
        or exponent1 != private_exponent % (prime1 - 1)
        or exponent2 != private_exponent % (prime2 - 1)
    ):
        return None
    try:
        if coefficient != pow(prime2, -1, prime1):
            return None
    except ValueError:
        return None
    return decoded, integer_bytes[3:]

def parse_avb_public_key(data):
    if len(data) < 8:
        return None
    key_bits = int.from_bytes(data[:4], "big")
    if key_bits not in {2048, 4096, 8192}:
        return None
    if len(data) != 8 + 2 * (key_bits // 8):
        return None
    return data

def add_material_tokens(tokens, binary_tokens, material):
    fingerprint = hashlib.sha256(material).hexdigest()
    tokens.add(material.hex())
    tokens.add(base64.b64encode(material).decode("ascii"))
    tokens.add(fingerprint)
    tokens.add(fingerprint[:16])
    tokens.add(":".join(fingerprint[index : index + 2] for index in range(0, 64, 2)))
    binary_tokens.add(material)

KEYSTORE_WINDOW = 16
KEYSTORE_WINDOWS = 16
BASE64_URLSAFE_TRANSLATION = bytes.maketrans(b"-_", b"+/")
BASE64_DER_PREFIX_PATTERN = re.compile(rb"M[ \t\r\n\v\f]*[A-P]")
BASE64_DER_START_PATTERN = re.compile(
    rb"(?=M(?:[C-H][A-Za-z0-9+/]|I[E-T]|[C-I]?$))"
)
BASE64_INVALID_PATTERN = re.compile(rb"[^A-Za-z0-9+/=_ \t\r\n\v\f-]")
BASE64_PROBE_BYTES = 128
DER_SCAN_CARRY_BYTES = 16 * 1024
HEX_SCAN_PATTERN = re.compile(rb"[A-Fa-f0-9]+")
MAX_BASE64_DER_CANDIDATES = 128
MAX_BASE64_DER_STARTS_PER_CHUNK = 4096
MAX_BASE64_DER_CANDIDATE_CHARS = 64 * 1024
BASE64_DER_CANDIDATE_PREFIX_CHARS = 172

def load_keystore_pins():
    """The pinned test keystores in scripts/release/test-keystore-pins.json (IR-338).

    Returns {name: (full-file SHA-256, certificate DER, public key DER)}, or None when the file cannot be read.
    """
    pins_path = repository / "scripts/release/test-keystore-pins.json"
    try:
        document = json.loads(pins_path.read_text(encoding="utf-8"))
        pins = {}
        for entry in document["keystores"]:
            pins[entry["name"]] = (
                entry["file_sha256"],
                base64.b64decode(entry["certificate_der"], validate=True),
                base64.b64decode(entry["public_key_der"], validate=True),
            )
        return pins
    except (OSError, ValueError, KeyError, TypeError) as error:
        failures.append(f"{pins_path}: could not read the test keystore pins: {error}")
        return None

def add_keystore_tokens(path, data, pins):
    """Tokens of a pinned test keystore. The name and the magic are not enough: the full-file digest must match."""
    entry = pins.get(path.name) if pins is not None else None
    if entry is None or hashlib.sha256(data).hexdigest() != entry[0]:
        return (
            set(),
            set(),
            f"{path}: unsupported binary or certificate signing fixture format: not a pinned test keystore",
        )
    _, certificate, public_key = entry
    tokens = set()
    binary_tokens = {data}
    # The certificate and the public key are not visible in the keystore itself, but a bundle that
    # exports them carries them. Their digests and key ID are matched in the same forms as other keys.
    add_material_tokens(tokens, binary_tokens, certificate)
    add_material_tokens(tokens, binary_tokens, public_key)
    # Fragments of the keystore: a truncated or split copy still contains some of them.
    span = max(len(data) - KEYSTORE_WINDOW, 1)
    for index in range(KEYSTORE_WINDOWS):
        offset = index * span // max(KEYSTORE_WINDOWS - 1, 1)
        binary_tokens.add(data[offset : offset + KEYSTORE_WINDOW])
    return tokens, binary_tokens, None

def add_key_tokens(path):
    data = path.read_bytes()
    tokens = set()
    for match in re.finditer(rb"[\x20-\x7e]{8,}", data):
        token = match.group().decode("ascii", "ignore").strip()
        if token and not token.startswith("-----BEGIN ") and not token.startswith("-----END "):
            tokens.add(token)

    unsupported = None
    raw_public_key = None
    private_key = None
    rsa_private_key = None
    avb_public_key = None
    if path.suffix.lower() in {".jks", ".keystore", ".p12", ".pfx", ".der", ".crt", ".cer"}:
        unsupported = f"{path}: unsupported binary or certificate signing fixture format"
    elif b"-----BEGIN CERTIFICATE-----" in data:
        unsupported = f"{path}: certificate signing fixture cannot be inspected"
    else:
        raw_public_key = parse_ed25519_public_key(data)
        private_key = parse_pkcs8_private_key(data)
        rsa_private_key = parse_pkcs1_rsa_private_key(data)
        if private_key is None and rsa_private_key is not None:
            private_key = rsa_private_key[0]
        avb_public_key = parse_avb_public_key(data) if path.suffix.lower() == ".avbpubkey" else None

    binary_tokens = set()
    if raw_public_key is not None:
        add_material_tokens(tokens, binary_tokens, raw_public_key)
    elif unsupported is None and private_key is not None:
        add_material_tokens(tokens, binary_tokens, private_key)
    elif unsupported is None and avb_public_key is not None:
        add_material_tokens(tokens, binary_tokens, avb_public_key)
    elif unsupported is None:
        unsupported = f"{path}: unrecognized test signing fixture format"
    if rsa_private_key is not None:
        for private_component in rsa_private_key[1]:
            tokens.add(private_component.hex())
            tokens.add(base64.b64encode(private_component).decode("ascii"))
            binary_tokens.add(private_component)
    return tokens, binary_tokens, unsupported

key_tokens = set()
key_binary_tokens = set()
if signing_fixtures.is_dir():
    keystore_pins = load_keystore_pins()
    for key_file in sorted(signing_fixtures.iterdir()):
        if key_file.is_dir():
            failures.append(f"{key_file}: unexpected directory in the test signing folder")
            continue
        if not key_file.is_file():
            continue
        try:
            if key_file.suffix.lower() == ".jks" and key_file.name.startswith("test-"):
                tokens, binary_tokens, unsupported = add_keystore_tokens(
                    key_file, key_file.read_bytes(), keystore_pins
                )
            else:
                tokens, binary_tokens, unsupported = add_key_tokens(key_file)
            key_tokens.update(tokens)
            key_binary_tokens.update(binary_tokens)
            if unsupported:
                failures.append(unsupported)
        except OSError as error:
            failures.append(f"{key_file}: could not read test signing fixture: {error}")

if not (app / "Contents/Info.plist").is_file():
    failures.append(f"{app}: missing Contents/Info.plist")

macho_files = []
for file in app.rglob("*"):
    if not file.is_file():
        continue
    result = subprocess.run(
        ["/usr/bin/file", "-b", str(file)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0 and "Mach-O" in result.stdout:
        macho_files.append(file)

if not macho_files:
    failures.append(f"{app}: no Mach-O executable found")

for binary in macho_files:
    result = subprocess.run(
        ["/usr/bin/strings", "-a", str(binary)],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        failures.append(f"{binary}: strings could not inspect the executable")
        continue
    strings = result.stdout.decode("utf-8", "replace")
    for pattern in hook_patterns:
        match = pattern.search(strings)
        if match:
            failures.append(f"{binary}: Release binary contains forbidden test marker {match.group()}")

def scan_stream(stream, text_tokens, binary_tokens):
    tokens = [token.encode("ascii").lower() for token in text_tokens if token]
    raw_tokens = [token for token in binary_tokens if token]
    maximum_length = max((len(token) for token in tokens + raw_tokens), default=1)
    carry = b""
    normalized_carry = b""
    base64_pending = b""
    decoded_base64_carry = b""
    der_carry = b""
    decoded_der_carry = b""
    last_base64_end = None
    key_found = False
    hex_pending = b""
    decoded_hex_carry = b""
    hex_continuation = False
    pem_pending = b""
    pem_label = None
    pem_payload = bytearray()
    base64_continuation = False
    base64_scanning = False
    base64_probe_carry = b""
    base64_der_candidates = []
    base64_pattern = re.compile(rb"[A-Za-z0-9+/_=-]+")
    begin_markers = (
        b"-----BEGIN ENCRYPTED PRIVATE KEY-----",
        b"-----BEGIN RSA PRIVATE KEY-----",
        b"-----BEGIN PRIVATE KEY-----",
    )
    while chunk := stream.read(1024 * 1024):
        combined = carry + chunk
        der_data = der_carry + chunk
        lowered = combined.lower()
        if contains_encrypted_pkcs8(der_data):
            return "encrypted-key"
        encrypted_key_oid_seen = ENCRYPTED_PRIVATE_KEY_OID_PATTERN.search(der_data) is not None
        if any(token in lowered for token in tokens):
            if encrypted_key_oid_seen:
                key_found = True
            else:
                return "key"
        if any(token in combined for token in raw_tokens):
            if encrypted_key_oid_seen:
                key_found = True
            else:
                return "key"
        if b"releaseupdatetest" in lowered:
            return "identity"
        der_carry = der_data[-DER_SCAN_CARRY_BYTES:]
        carry = combined[-(maximum_length - 1) :] if maximum_length > 1 else b""
        normalized = normalized_carry + chunk.translate(None, b" \t\r\n\v\f")
        if any(token in normalized.lower() for token in tokens):
            if encrypted_key_oid_seen:
                key_found = True
            else:
                return "key"
        normalized_carry = normalized[-(maximum_length - 1) :] if maximum_length > 1 else b""
        base64_chunk = chunk
        if not base64_scanning:
            base64_probe = base64_probe_carry + chunk
            base64_probe_carry = base64_probe[-BASE64_PROBE_BYTES:]
            prefix = None
            invalid_iterator = BASE64_INVALID_PATTERN.finditer(base64_probe)
            next_invalid = next(invalid_iterator, None)
            for candidate_prefix in BASE64_DER_PREFIX_PATTERN.finditer(base64_probe):
                candidate_start = candidate_prefix.start()
                while next_invalid is not None and next_invalid.start() < candidate_start:
                    next_invalid = next(invalid_iterator, None)
                sample_end = min(
                    candidate_start + BASE64_PROBE_BYTES, len(base64_probe)
                )
                if next_invalid is None or next_invalid.start() >= sample_end:
                    prefix = candidate_prefix
                    break
            if prefix is not None:
                base64_scanning = True
                base64_chunk = base64_probe[prefix.start() :]
        if not base64_scanning:
            base64_continuation = False
            base64_pending = b""
            decoded_base64_carry = b""
            decoded_der_carry = b""
            base64_der_candidates.clear()
        else:
            continues_previous_base64 = base64_continuation
            if not continues_previous_base64:
                base64_pending = b""
                base64_der_candidates.clear()
            if base64_pending:
                if base64_chunk[:1] in b" \t\r\n\v\f":
                    base64_chunk = base64_chunk.lstrip(b" \t\r\n\v\f")
                if base64_chunk[:1] not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=":
                    base64_pending = b""
                    continues_previous_base64 = False
            base64_data = base64_pending + base64_chunk
            base64_pending = b""
            base64_continuation = False
            match_iterator = base64_pattern.finditer(base64_data)
            candidate = next(match_iterator, None)
            decoded_der_segment = bytearray()
            last_base64_end = None
            base64_der_start_count = 0
            if candidate is None and continues_previous_base64 and not base64_data.strip(
                b" \t\r\n\v\f"
            ):
                base64_continuation = True
            while candidate is not None:
                next_candidate = next(match_iterator, None)
                if last_base64_end is None:
                    if not continues_previous_base64:
                        decoded_der_carry = b""
                        decoded_base64_carry = b""
                elif base64_data[last_base64_end : candidate.start()].strip(
                    b" \t\r\n\v\f"
                ):
                    if contains_encrypted_pkcs8(decoded_der_carry + decoded_der_segment):
                        return "encrypted-key"
                    decoded_der_carry = b""
                    decoded_der_segment.clear()
                    decoded_base64_carry = b""
                    base64_pending = b""
                    base64_der_candidates.clear()
                candidate_bytes = candidate.group()
                active_candidates = []
                for der_candidate in base64_der_candidates:
                    candidate_result = append_base64_der_fragment(
                        der_candidate, candidate_bytes
                    )
                    if candidate_result == "encrypted-key":
                        return candidate_result
                    if candidate_result == "too-large":
                        return "uninspectable"
                    if candidate_result == "ok":
                        active_candidates.append(der_candidate)
                base64_der_candidates = active_candidates
                candidate_starts = (
                    match.start()
                    for match in BASE64_DER_START_PATTERN.finditer(candidate_bytes)
                )
                for start_offset in candidate_starts:
                    base64_der_start_count += 1
                    if base64_der_start_count > MAX_BASE64_DER_STARTS_PER_CHUNK:
                        return "uninspectable"
                    der_candidate = {
                        "decoded": bytearray(),
                        "encoded_length": 0,
                        "next_check": 16,
                        "pending": b"",
                    }
                    prefix_end = min(
                        start_offset + BASE64_DER_CANDIDATE_PREFIX_CHARS,
                        len(candidate_bytes),
                    )
                    candidate_result = append_base64_der_fragment(
                        der_candidate, candidate_bytes[start_offset:prefix_end]
                    )
                    if candidate_result == "encrypted-key":
                        return candidate_result
                    if candidate_result == "too-large":
                        return "uninspectable"
                    if candidate_result == "ok" and prefix_end < len(candidate_bytes):
                        candidate_result = append_base64_der_fragment(
                            der_candidate, candidate_bytes[prefix_end:]
                        )
                        if candidate_result == "encrypted-key":
                            return candidate_result
                        if candidate_result == "too-large":
                            return "uninspectable"
                    if candidate_result == "ok":
                        base64_der_candidates.append(der_candidate)
                        if len(base64_der_candidates) > MAX_BASE64_DER_CANDIDATES:
                            return "uninspectable"
                encoded = base64_pending + candidate.group()
                base64_pending = b""
                trailing = (
                    next_candidate is None
                    and not base64_data[candidate.end() :].strip(b" \t\r\n\v\f")
                )
                last_base64_end = candidate.end()
                if b"-----" in encoded:
                    if contains_encrypted_pkcs8(decoded_der_carry + decoded_der_segment):
                        return "encrypted-key"
                    decoded_der_carry = b""
                    decoded_der_segment.clear()
                    decoded_base64_carry = b""
                    candidate = next_candidate
                    continue
                complete_length = len(encoded) - len(encoded) % 4
                complete = encoded[:complete_length]
                remainder = encoded[complete_length:]
                if b"=" in complete and remainder:
                    decoded_der_carry = b""
                    decoded_der_segment.clear()
                    decoded_base64_carry = b""
                    candidate = next_candidate
                    continue
                if not complete:
                    base64_pending = remainder
                    base64_continuation = trailing and b"=" not in encoded
                    candidate = next_candidate
                    continue
                try:
                    decoded_base64 = base64.b64decode(
                        complete.translate(BASE64_URLSAFE_TRANSLATION), validate=True
                    )
                except (ValueError, binascii.Error):
                    decoded_der_carry = b""
                    decoded_der_segment.clear()
                    decoded_base64_carry = b""
                    candidate = next_candidate
                    continue
                if b"=" in complete and len(remainder) == 0:
                    base64_continuation = False
                else:
                    base64_pending = remainder
                    base64_continuation = trailing and b"=" not in encoded
                decoded = decoded_base64_carry + decoded_base64
                der_candidate = decoded_der_carry + decoded_der_segment + decoded_base64
                encrypted_key_oid_seen = (
                    ENCRYPTED_PRIVATE_KEY_OID_PATTERN.search(der_candidate) is not None
                )
                if any(token in decoded for token in raw_tokens):
                    if encrypted_key_oid_seen:
                        key_found = True
                    else:
                        return "key"
                decoded_der_segment.extend(decoded_base64)
                decoded_base64_carry = (
                    decoded[-(maximum_length - 1) :] if maximum_length > 1 else b""
                )
                candidate = next_candidate
            decoded_der_candidate = decoded_der_carry + decoded_der_segment
            if contains_encrypted_pkcs8(decoded_der_candidate):
                return "encrypted-key"
            decoded_der_carry = decoded_der_candidate[-DER_SCAN_CARRY_BYTES:]
            if not base64_continuation:
                base64_scanning = False
                base64_probe_carry = chunk[-BASE64_PROBE_BYTES:]
        hex_chunk = chunk
        continues_previous_hex = hex_continuation
        if hex_pending:
            if hex_chunk[:1] in b" \t\r\n\v\f":
                hex_chunk = hex_chunk.lstrip(b" \t\r\n\v\f")
            if hex_chunk[:1] not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789":
                hex_pending = b""
                continues_previous_hex = False
        elif continues_previous_hex:
            next_hex_byte = hex_chunk.lstrip(b" \t\r\n\v\f")[:1]
            if next_hex_byte and next_hex_byte not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789":
                continues_previous_hex = False
        hex_data = hex_pending + hex_chunk
        hex_pending = b""
        hex_continuation = False
        hex_match_iterator = HEX_SCAN_PATTERN.finditer(hex_data)
        hex_candidate = next(hex_match_iterator, None)
        decoded_hex_segment = bytearray()
        last_hex_end = None
        while hex_candidate is not None:
            next_hex_candidate = next(hex_match_iterator, None)
            if last_hex_end is None:
                if not continues_previous_hex:
                    decoded_hex_carry = b""
            elif hex_data[last_hex_end : hex_candidate.start()].strip(b" \t\r\n\v\f"):
                if contains_encrypted_pkcs8(decoded_hex_carry + decoded_hex_segment):
                    return "encrypted-key"
                decoded_hex_carry = b""
                decoded_hex_segment.clear()
                hex_pending = b""
            encoded_hex = hex_pending + hex_candidate.group()
            hex_pending = b""
            trailing = (
                next_hex_candidate is None
                and not hex_data[hex_candidate.end() :].strip(b" \t\r\n\v\f")
            )
            if len(encoded_hex) % 2:
                hex_pending = encoded_hex[-1:]
                encoded_hex = encoded_hex[:-1]
            if trailing:
                hex_continuation = True
            if not encoded_hex:
                hex_candidate = next_hex_candidate
                continue
            try:
                decoded_hex = bytes.fromhex(encoded_hex.decode("ascii"))
            except ValueError:
                decoded_hex_carry = b""
                decoded_hex_segment.clear()
                hex_candidate = next_hex_candidate
                continue
            decoded_hex_segment.extend(decoded_hex)
            last_hex_end = hex_candidate.end()
            hex_candidate = next_hex_candidate
        der_hex = decoded_hex_carry + decoded_hex_segment
        if contains_encrypted_pkcs8(der_hex):
            return "encrypted-key"
        decoded_hex_carry = der_hex[-DER_SCAN_CARRY_BYTES:]
        if hex_candidate is None and continues_previous_hex and not hex_data.strip(
            b" \t\r\n\v\f"
        ):
            hex_continuation = True
        pem_data = pem_pending + chunk
        cursor = 0
        while cursor < len(pem_data):
            if pem_label is None:
                candidates = [
                    (pem_data.find(marker, cursor), marker)
                    for marker in begin_markers
                ]
                candidates = [(index, marker) for index, marker in candidates if index >= 0]
                if not candidates:
                    pending_length = max(len(marker) for marker in begin_markers) - 1
                    pem_pending = pem_data[-pending_length:]
                    break
                begin_index, begin_marker = min(candidates, key=lambda candidate: candidate[0])
                pem_label = begin_marker[len(b"-----BEGIN ") : -len(b"-----")]
                cursor = begin_index + len(begin_marker)
                pem_payload.clear()
                if pem_label == b"ENCRYPTED PRIVATE KEY":
                    return "encrypted-key"
            end_marker = b"-----END " + pem_label + b"-----"
            end_index = pem_data.find(end_marker, cursor)
            if end_index < 0:
                marker_tail = len(end_marker) - 1
                payload_end = max(cursor, len(pem_data) - marker_tail)
                pem_payload.extend(pem_data[cursor:payload_end])
                if len(pem_payload) > 1024 * 1024:
                    return "key"
                pem_pending = pem_data[payload_end:]
                break
            pem_payload.extend(pem_data[cursor:end_index])
            if len(pem_payload) > 1024 * 1024:
                return "key"
            if b"PROC-TYPE: 4,ENCRYPTED" in pem_payload.upper():
                return "encrypted-key"
            encoded = b"".join(pem_payload.split())
            try:
                decoded_pem = base64.b64decode(encoded, validate=True)
            except (ValueError, binascii.Error):
                decoded_pem = b""
            if any(token in decoded_pem for token in raw_tokens):
                return "key"
            pem_label = None
            pem_payload.clear()
            cursor = end_index + len(end_marker)
            pem_pending = b""
    if base64_scanning and len(base64_pending) in (2, 3):
        padded_tail = base64_pending + b"=" * (4 - len(base64_pending))
        try:
            decoded_tail = base64.b64decode(
                padded_tail.translate(BASE64_URLSAFE_TRANSLATION), validate=True
            )
        except (ValueError, binascii.Error):
            decoded_tail = b""
        decoded_tail_window = decoded_base64_carry + decoded_tail
        encrypted_key_oid_seen = (
            ENCRYPTED_PRIVATE_KEY_OID_PATTERN.search(
                decoded_der_carry + decoded_tail
            )
            is not None
        )
        if any(token in decoded_tail_window for token in raw_tokens):
            if encrypted_key_oid_seen:
                key_found = True
            else:
                return "key"
        if contains_encrypted_pkcs8(decoded_der_carry + decoded_tail):
            return "encrypted-key"
    if any(
        finish_base64_der_candidate(candidate)
        for candidate in base64_der_candidates
    ):
        return "encrypted-key"
    if pem_label is not None:
        if b"PROC-TYPE: 4,ENCRYPTED" in pem_payload.upper():
            return "encrypted-key"
        return "key"
    if key_found:
        return "key"
    return None

def scan_tokens(path, text_tokens, binary_tokens):
    """Scans a file, and the members of a zip archive, since a deflated copy of a keystore has no raw bytes (IR-338)."""
    if zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as archive:
                for member in archive.infolist():
                    if member.is_dir():
                        continue
                    with archive.open(member) as stream:
                        match = scan_stream(stream, text_tokens, binary_tokens)
                    if match:
                        return match
        except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
            raise OSError(f"could not read the archive: {error}") from error
    with path.open("rb") as stream:
        return scan_stream(stream, text_tokens, binary_tokens)

def embedded_info_plist(binary):
    result = subprocess.run(
        ["/usr/bin/otool", "-s", "__TEXT", "__info_plist", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or "Contents of (__TEXT,__info_plist) section" not in result.stdout:
        return None

    payload = bytearray()
    for line in result.stdout.splitlines():
        if "Contents of (__TEXT,__info_plist) section" in line:
            continue
        match = re.match(r"^\s*[0-9a-fA-F]+\s+((?:[0-9a-fA-F]{2,8}\s*)+)$", line)
        if not match:
            continue
        for word in match.group(1).split():
            if len(word) % 2 == 0:
                decoded = bytes.fromhex(word)
                payload.extend(decoded[::-1] if len(decoded) == 4 else decoded)

    start = payload.find(b"<?xml")
    end = payload.find(b"</plist>", start)
    if start < 0 or end < 0:
        return None
    try:
        return plistlib.loads(bytes(payload[start : end + len(b"</plist>")]))
    except (plistlib.InvalidFileException, ValueError):
        return None

for binary in macho_files:
    info = embedded_info_plist(binary)
    if info is None:
        if binary.name in {"apkrund", "apkrun"}:
            failures.append(f"{binary}: missing or unreadable embedded Info.plist")
        continue
    build_identity = info.get("APKRunBuildIdentity")
    if binary.name in {"apkrund", "apkrun"} and build_identity != "release":
        failures.append(
            f"{binary}: embedded Release APKRunBuildIdentity must be 'release', "
            + f"found {build_identity!r}"
        )
    elif build_identity is not None and build_identity != "release":
        failures.append(
            f"{binary}: embedded Release APKRunBuildIdentity must be 'release', "
            + f"found {build_identity!r}"
        )

for info_plist in app.rglob("Info.plist"):
    try:
        with info_plist.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        failures.append(f"{info_plist}: could not inspect bundle settings: {error}")
        continue
    build_identity = info.get("APKRunBuildIdentity")
    relative_parts = info_plist.relative_to(app).parts
    is_apkrun_bundle = (
        info_plist == app / "Contents/Info.plist"
        or "APKRunLauncher.app" in relative_parts
        or "APKRunMenuBar.app" in relative_parts
    )
    if is_apkrun_bundle and build_identity != "release":
        failures.append(
            f"{info_plist}: Release bundle APKRunBuildIdentity must be 'release', "
            + f"found {build_identity!r}"
        )
    elif isinstance(build_identity, str) and build_identity.casefold() != "release":
        failures.append(
            f"{info_plist}: nested Release bundle APKRunBuildIdentity must be 'release', "
            + f"found {build_identity!r}"
        )

for file in app.rglob("*"):
    if not file.is_file():
        continue
    try:
        match = scan_tokens(file, key_tokens, key_binary_tokens)
    except OSError as error:
        failures.append(f"{file}: could not scan release bundle file: {error}")
        continue
    if match == "key":
        failures.append(f"{file}: bundle file contains test signing material from Tests/Fixtures/signing")
    elif match == "encrypted-key":
        failures.append(f"{file}: bundle file contains encrypted private-key material")
    elif match == "uninspectable":
        failures.append(f"{file}: bundle file has too many encoded private-key candidates to inspect safely")
    elif match == "identity":
        failures.append(f"{file}: Release bundle contains the ReleaseUpdateTest setting")

if image_bundle is not None:
    image_files = [image_bundle] if image_bundle.is_file() else [item for item in image_bundle.rglob("*") if item.is_file()]
    for file in image_files:
        try:
            match = scan_tokens(file, key_tokens, key_binary_tokens)
        except OSError as error:
            failures.append(f"{file}: could not scan image bundle file: {error}")
            continue
        if match == "key":
            failures.append(f"{file}: image bundle file contains test signing material from Tests/Fixtures/signing")
        elif match == "encrypted-key":
            failures.append(f"{file}: image bundle file contains encrypted private-key material")
        elif match == "uninspectable":
            failures.append(f"{file}: image bundle file has too many encoded private-key candidates to inspect safely")
        elif match == "identity":
            failures.append(f"{file}: image bundle contains the ReleaseUpdateTest setting")

runtime_directory = app / "Contents/Frameworks/VirGLRuntime"
runtime_libraries = (
    "libvirglrenderer.1.dylib",
    "libepoxy.0.dylib",
    "libEGL.dylib",
    "libGLESv2.dylib",
)
if runtime_directory.is_symlink() or not runtime_directory.is_dir():
    failures.append(f"{runtime_directory}: Release app has an unsafe VirGL runtime directory")
else:
    unexpected = sorted(
        child.name
        for child in runtime_directory.iterdir()
        if child.name not in runtime_libraries
    )
    if unexpected:
        failures.append(
            f"{runtime_directory}: unexpected VirGL runtime files: {', '.join(unexpected)}"
        )

for name in runtime_libraries:
    library = runtime_directory / name
    if library.is_symlink() or not library.is_file():
        failures.append(f"{library}: Release app is missing the VirGL runtime library")
        continue
    architectures = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(library)],
        capture_output=True,
        text=True,
        check=False,
    )
    if architectures.returncode != 0 or architectures.stdout.strip() != "arm64":
        failures.append(f"{library}: Release runtime library must contain only arm64")
    install_name = subprocess.run(
        ["/usr/bin/otool", "-D", str(library)],
        capture_output=True,
        text=True,
        check=False,
    )
    install_names = install_name.stdout.splitlines()
    if (
        install_name.returncode != 0
        or len(install_names) < 2
        or install_names[1].strip() != f"@rpath/{name}"
    ):
        failures.append(f"{library}: Release runtime library has an unexpected install name")

if image_bundle is not None:
    # Image rows (build-system.md §3.1; runtime-image-manifest.md §7.3). Only a product image
    # may be published, so every bundle given to the release check is held to the release rules.
    manifest_path = image_bundle / "manifest.json"
    signature_path = image_bundle / "manifest.sig"
    manifest = None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        failures.append(f"{manifest_path}: could not read the image manifest: {error}")
    if isinstance(manifest, dict):
        if manifest.get("kind") != "apkrun":
            failures.append(
                f"{manifest_path}: a stock image cannot be published (kind {manifest.get('kind')!r})"
            )
        revisions = manifest.get("provenance", {}).get("revisions", {})
        for name in ("imagesTools", "guest"):
            value = revisions.get(name) if isinstance(revisions, dict) else None
            if isinstance(value, str) and value.endswith("-dirty"):
                failures.append(f"{manifest_path}: release image revision {name} is dirty")
        if "headless" in manifest.get("gpuProfiles", {}):
            failures.append(f"{manifest_path}: a release image cannot list the headless GPU profile")
    for name in ("boot/bootconfig.txt", "boot/cmdline.txt"):
        path = image_bundle / name
        if path.is_file() and b"androidboot.apkrun.test." in path.read_bytes():
            failures.append(f"{path}: release image contains an androidboot.apkrun.test.* key")
    if not signature_path.is_file():
        failures.append(f"{signature_path}: missing manifest.sig")
    else:
        signed_by = next(
            (
                line[len("key-id: ") :]
                for line in signature_path.read_text(encoding="ascii", errors="replace").splitlines()
                if line.startswith("key-id: ")
            ),
            None,
        )
        test_public = signing_fixtures / "test-image-ed25519.pub"
        if test_public.is_file():
            test_key = parse_ed25519_public_key(test_public.read_bytes())
            if test_key is not None and signed_by == hashlib.sha256(test_key).hexdigest()[:16]:
                failures.append(f"{signature_path}: release image is signed with the test image key")
        developer_public = pathlib.Path.home() / ".config/apkrun/dev-image-key.pub"
        if developer_public.is_file():
            developer_key = parse_ed25519_public_key(developer_public.read_bytes())
            if developer_key is not None and signed_by == hashlib.sha256(developer_key).hexdigest()[:16]:
                failures.append(f"{signature_path}: release image is signed with a developer key")

if failures:
    for failure in failures:
        print(f"check-release-build: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("check-release-build: passed")
PY
