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

python3 - "$repo_root" "$app_bundle" <<'PY'
import base64
import binascii
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2]).resolve()
signing_fixtures = repository / "Tests/Fixtures/signing"
failures = []

hook_patterns = (
    re.compile(r"APKRUN_[A-Z0-9_]*_FAULT"),
    re.compile(r"APKRUN_TEST_[A-Z0-9_]+"),
    re.compile(r"APKRUN_LAUNCHER_TEST_NO_RUNTIME"),
    re.compile(r"ReleaseUpdateTest"),
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

def add_key_tokens(path):
    data = path.read_bytes()
    tokens = set()
    for match in re.finditer(rb"[\x20-\x7e]{8,}", data):
        token = match.group().decode("ascii", "ignore").strip()
        if token and not token.startswith("-----BEGIN ") and not token.startswith("-----END "):
            tokens.add(token)

    unsupported = None
    if path.suffix.lower() in {".jks", ".keystore", ".p12", ".pfx", ".der", ".crt", ".cer"}:
        unsupported = f"{path}: unsupported binary or certificate signing fixture format"
        raw_public_key = None
    elif b"-----BEGIN CERTIFICATE-----" in data:
        unsupported = f"{path}: certificate signing fixture cannot be inspected"
        raw_public_key = None
    else:
        raw_public_key = parse_ed25519_public_key(data)

    binary_tokens = set()
    if raw_public_key is not None:
        fingerprint = hashlib.sha256(raw_public_key).hexdigest()
        tokens.add(raw_public_key.hex())
        tokens.add(base64.b64encode(raw_public_key).decode("ascii"))
        tokens.add(fingerprint)
        tokens.add(fingerprint[:16])
        tokens.add(":".join(fingerprint[index : index + 2] for index in range(0, 64, 2)))
        binary_tokens.add(raw_public_key)
    elif unsupported is None:
        unsupported = f"{path}: unrecognized test signing fixture format"
    return tokens, binary_tokens, unsupported

key_tokens = set()
key_binary_tokens = set()
if signing_fixtures.is_dir():
    for key_file in signing_fixtures.rglob("*"):
        if key_file.is_file():
            try:
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

def scan_tokens(path, text_tokens, binary_tokens):
    tokens = [token.encode("ascii").lower() for token in text_tokens if token]
    raw_tokens = [token for token in binary_tokens if token]
    maximum_length = max((len(token) for token in tokens + raw_tokens), default=1)
    carry = b""
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            combined = carry + chunk
            lowered = combined.lower()
            if any(token in lowered for token in tokens):
                return "key"
            if any(token in combined for token in raw_tokens):
                return "key"
            if b"releaseupdatetest" in lowered:
                return "identity"
            carry = combined[-(maximum_length - 1) :] if maximum_length > 1 else b""
    return None

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
    elif match == "identity":
        failures.append(f"{file}: Release bundle contains the ReleaseUpdateTest setting")

if failures:
    for failure in failures:
        print(f"check-release-build: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("check-release-build: passed")
PY
