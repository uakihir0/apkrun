#!/usr/bin/env python3
"""Tests the release check's rules for the test keystores and signing keys (IR-338).

The checker takes its signing folder, its pins, and its image bundle from its own location and from its
arguments, so every case copies the checker and its pins into a temporary repository layout. A test
keystore is accepted only when its name and full-file SHA-256 match scripts/release/test-keystore-pins.json.
Any other keystore is refused, and so is a bundle file that carries the keystore's bytes, its fragments,
its certificate, its certificate fingerprint, or its public key. PEM private keys are parsed and their
encoded and raw private components are scanned in app bundles.
"""

import base64
import copy
import hashlib
import json
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from io import BytesIO

UNSUPPORTED = "unsupported binary or certificate signing fixture format"
TEST_MATERIAL = "test signing material"

repository = pathlib.Path(sys.argv[1]).resolve()
checker = repository / "scripts/release/check-release-build.sh"
pins_file = repository / "scripts/release/test-keystore-pins.json"
signing_folder = repository / "Tests/Fixtures/signing"
committed = signing_folder / "test-fixture-a.jks"
keystore = committed.read_bytes()
pins = {entry["name"]: entry for entry in json.loads(pins_file.read_text(encoding="utf-8"))["keystores"]}
certificate_der = base64.b64decode(pins["test-fixture-a.jks"]["certificate_der"], validate=True)
public_key_der = base64.b64decode(pins["test-fixture-a.jks"]["public_key_der"], validate=True)


def openssl(*arguments, stdin=None):
    return subprocess.run(
        ["openssl", *arguments], input=stdin, capture_output=True, check=True
    ).stdout


def der_length(length):
    if length < 0x80:
        return bytes([length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(encoded)]) + encoded


def der_value(tag, contents):
    return bytes([tag]) + der_length(len(contents)) + contents


def with_nonminimal_rsa_version(der):
    """Makes a structurally complete PKCS#1 key with a non-minimal DER version integer."""
    sequence_tag, sequence_length = der[0], der[1]
    offset = 2
    if sequence_length & 0x80:
        length_size = sequence_length & 0x7F
        sequence_length = int.from_bytes(der[offset : offset + length_size], "big")
        offset += length_size
    contents = der[offset : offset + sequence_length]
    fields = []
    offset = 0
    while offset < len(contents):
        tag = contents[offset]
        first_length = contents[offset + 1]
        offset += 2
        if first_length & 0x80:
            length_size = first_length & 0x7F
            length = int.from_bytes(contents[offset : offset + length_size], "big")
            offset += length_size
        else:
            length = first_length
        value = contents[offset : offset + length]
        offset += length
        if not fields:
            value = b"\x00\x00"
        fields.append(der_value(tag, value))
    return der_value(sequence_tag, b"".join(fields))


def rsa_private_pem(der):
    encoded = base64.encodebytes(der)
    return b"-----BEGIN RSA PRIVATE KEY-----\n" + encoded + b"-----END RSA PRIVATE KEY-----\n"


def check(signing_files, app_files=None, image_files=None, signing_directories=()):
    """Runs the checker on a temporary repository with the given signing folder, app, and image bundle."""
    with tempfile.TemporaryDirectory(prefix="apkrun-release-keystores-") as directory:
        root = pathlib.Path(directory)
        release = root / "scripts/release"
        release.mkdir(parents=True)
        for name in ("check-release-build.sh", "generate-notices.py"):
            shutil.copy2(repository / "scripts/release" / name, release / name)
        shutil.copy2(pins_file, release / "test-keystore-pins.json")
        (root / "ThirdParty").mkdir()
        shutil.copy2(repository / "ThirdParty/ThirdParty.lock.json", root / "ThirdParty/ThirdParty.lock.json")
        signing = root / "Tests/Fixtures/signing"
        signing.mkdir(parents=True)
        for name, data in signing_files.items():
            (signing / name).write_bytes(data)
        for name in signing_directories:
            (signing / name).mkdir()
            (signing / name / "test-fixture-a.jks").write_bytes(keystore)
        app = root / "APKRun.app"
        (app / "Contents").mkdir(parents=True)
        for relative, data in (app_files or {}).items():
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        arguments = [str(release / "check-release-build.sh"), str(app)]
        if image_files is not None:
            image = root / "image"
            image.mkdir()
            for relative, data in image_files.items():
                path = image / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            arguments.append(str(image))
        result = subprocess.run(arguments, capture_output=True, text=True, check=False)
        return result.stdout + result.stderr


def passed(name):
    print(f"PASS keystore {name}")


def fail(name, output):
    raise SystemExit(f"FAIL keystore {name}\n{output}")


def expect_refused(name, output, mentioning):
    if UNSUPPORTED not in output or mentioning not in output:
        fail(name, output)
    passed(name)


def expect_unrecognized(name, output, mentioning):
    if "unrecognized test signing fixture format" not in output or mentioning not in output:
        fail(name, output)
    passed(name)


def expect_bundle_refused(name, output):
    if TEST_MATERIAL not in output and "contains encrypted private-key material" not in output:
        fail(name, output)
    passed(name)


def expect_encrypted_bundle_refused(name, output):
    if "contains encrypted private-key material" not in output:
        fail(name, output)
    passed(name)


def expect_uninspectable_bundle_refused(name, output):
    if "too many encoded private-key candidates to inspect safely" not in output:
        fail(name, output)
    passed(name)


def expect_accepted(name, output):
    if (
        UNSUPPORTED in output
        or "unrecognized test signing fixture format" in output
        or "could not read" in output
        or TEST_MATERIAL in output
    ):
        fail(name, output)
    passed(name)


JKS_MAGIC = b"\xfe\xed\xfe\xed"


def store_passwords(name):
    """The store passwords that the Gradle files give to a keystore with this name (the first one after each use)."""
    gradle_files = sorted(repository.glob("Tests/Fixtures/AndroidApps/*/build.gradle.kts")) + sorted(
        repository.glob("Guest/*/build.gradle.kts")
    )
    found = set()
    for gradle in gradle_files:
        source = gradle.read_text(encoding="utf-8")
        for use in re.finditer(r"storeFile\s*=\s*[^\n]*" + re.escape(name) + r'"', source):
            password = re.search(r'storePassword\s*=\s*"([^"]+)"', source[use.end() :])
            if password:
                found.add(password.group(1))
    return found


def jks_certificates(data):
    """The certificate DER of each chain entry of a JKS keystore. A JKS keeps its chains unencrypted, only its keys are sealed."""
    position = 8

    def take(count):
        nonlocal position
        chunk = data[position : position + count]
        if len(chunk) != count:
            raise ValueError("the JKS keystore is truncated")
        position += count
        return chunk

    def u4():
        return struct.unpack(">I", take(4))[0]

    def utf():
        take(struct.unpack(">H", take(2))[0])

    certificates = []
    for _ in range(u4()):
        tag = u4()
        utf()  # alias
        take(8)  # creation time
        if tag == 1:  # a private key entry: sealed key, then its certificate chain
            take(u4())
            for _ in range(u4()):
                utf()  # certificate type
                certificates.append(take(u4()))
        elif tag == 2:  # a trusted certificate entry
            utf()
            certificates.append(take(u4()))
        else:
            raise ValueError(f"the JKS keystore has an unknown entry tag {tag}")
    if position + 20 != len(data):  # the keystore ends with a 20-byte SHA-1 integrity digest
        raise ValueError("the JKS keystore has unexpected trailing bytes")
    return certificates


def keystore_certificates(path, data):
    """The certificate DER of each entry of a committed test keystore (IR-338).

    A JKS is parsed here. A PKCS#12 keystore is opened with openssl and the one store password that the Gradle
    files give it. Anything else, or a password that does not open it, is an error.
    """
    if data[:4] == JKS_MAGIC:
        return jks_certificates(data)
    passwords = store_passwords(path.name)
    if len(passwords) != 1:
        raise ValueError(f"expected one store password in the Gradle files for {path.name}, found {sorted(passwords)}")
    (password,) = passwords
    opened = subprocess.run(
        ["openssl", "pkcs12", "-in", str(path), "-passin", f"pass:{password}", "-nokeys", "-clcerts"],
        capture_output=True,
        check=False,
    )
    start = opened.stdout.find(b"-----BEGIN CERTIFICATE-----")
    if opened.returncode != 0 or start < 0:
        raise ValueError(f"{path.name} is neither a JKS keystore nor a PKCS#12 keystore that its Gradle password opens")
    return [openssl("x509", "-outform", "DER", stdin=opened.stdout[start:])]


def verify_pins(entries):
    """The failures of a pin list against the committed keystores (IR-338). An empty list passes."""
    failures = []
    committed_names = sorted(
        path.name for path in signing_folder.iterdir() if path.suffix == ".jks" and path.name.startswith("test-")
    )
    try:
        pinned_names = sorted(entry["name"] for entry in entries)
    except (KeyError, TypeError) as error:
        return [f"a pin has no usable name: {error}"]
    if committed_names != pinned_names:
        failures.append(f"committed keystores {committed_names}, pinned {pinned_names}")
    for entry in entries:
        name = entry["name"]
        path = signing_folder / name
        if not path.is_file():
            continue  # reported by the name comparison above
        try:
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != entry["file_sha256"]:
                failures.append(f"{name}: the committed file does not match its pinned SHA-256")
                continue
            certificate = base64.b64decode(entry["certificate_der"], validate=True)
            public_key = base64.b64decode(entry["public_key_der"], validate=True)
            if certificate not in keystore_certificates(path, data):
                failures.append(f"{name}: the pinned certificate is not in the committed keystore")
                continue
            spki_pem = openssl("x509", "-inform", "DER", "-noout", "-pubkey", stdin=certificate)
            if openssl("pkey", "-pubin", "-outform", "DER", stdin=spki_pem) != public_key:
                failures.append(f"{name}: the pinned public key does not match the pinned certificate")
        except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
            failures.append(f"{name}: {error}")
    return failures


def entry_named(entries, name):
    return next(entry for entry in entries if entry["name"] == name)


# 1. The pins match the committed files: every committed keystore is pinned, its digest matches, and its pinned
# certificate and public key are the committed keystore's. Each mutant below must be refused, so a check that
# stopped refusing would fail here.
pins_document = json.loads(pins_file.read_text(encoding="utf-8"))
failures = verify_pins(pins_document["keystores"])
if failures:
    raise SystemExit("FAIL keystore pins: " + "; ".join(failures))
passed("pins-match-committed-keystores")

guest_signer = re.search(
    r'expected_signer_sha256="([0-9a-f]{64})"', (repository / "scripts/build-guest.sh").read_text(encoding="utf-8")
).group(1)
guest_certificate = base64.b64decode(entry_named(pins_document["keystores"], "test-guest-dev.jks")["certificate_der"])
if hashlib.sha256(guest_certificate).hexdigest() != guest_signer:
    raise SystemExit("FAIL keystore pins: test-guest-dev.jks is not the signer that scripts/build-guest.sh pins")
passed("guest-pin-is-the-build-guest-signer")


def expect_pin_refused(name, entries, mentioning):
    found = verify_pins(entries)
    if not any(mentioning in failure for failure in found):
        fail(name, "\n".join(found) or "no failure was reported")
    passed(name)


fixture_entry = entry_named(pins_document["keystores"], "test-fixture-a.jks")
guest_entry = entry_named(pins_document["keystores"], "test-guest-dev.jks")


def mutated(change):
    entries = copy.deepcopy(pins_document["keystores"])
    change(entries)
    return entries


expect_pin_refused(
    "pin-digest-changed-refused",
    mutated(lambda entries: entry_named(entries, "test-guest-dev.jks").update(file_sha256="0" * 64)),
    "does not match its pinned SHA-256",
)
expect_pin_refused(
    "pin-certificate-of-another-keystore-refused",
    mutated(lambda entries: entry_named(entries, "test-guest-dev.jks").update(certificate_der=fixture_entry["certificate_der"])),
    "the pinned certificate is not in the committed keystore",
)
expect_pin_refused(
    "pin-public-key-of-another-keystore-refused",
    mutated(lambda entries: entry_named(entries, "test-guest-dev.jks").update(public_key_der=fixture_entry["public_key_der"])),
    "the pinned public key does not match",
)
expect_pin_refused(
    "unpinned-committed-keystore-refused",
    mutated(lambda entries: entries.remove(guest_entry)),
    "committed keystores",
)
expect_pin_refused(
    "pin-for-a-missing-keystore-refused",
    mutated(lambda entries: entries.append({**guest_entry, "name": "test-missing.jks"})),
    "committed keystores",
)

# 2. The committed keystore is accepted: this is the regression case for a wrong refusal.
expect_accepted("committed-keystore-accepted", check({"test-fixture-a.jks": keystore}))

# 3. Name and magic are not enough: every other keystore is refused.
expect_refused(
    "renamed-copy-refused",
    check({"test-renamed.jks": keystore}),
    "test-renamed.jks",
)
expect_refused(
    "release-named-copy-refused",
    check({"release-signing.jks": keystore}),
    "release-signing.jks",
)
fake_jks = b"\xfe\xed\xfe\xed\x00\x00\x00\x02" + b"\x00" * 64
expect_refused("jks-magic-named-test-refused", check({"test-prod.jks": fake_jks}), "test-prod.jks")
expect_refused(
    "test-garbage-refused",
    check({"test-garbage.jks": b"not a keystore at all"}),
    "test-garbage.jks",
)
expect_refused(
    "truncated-committed-keystore-refused",
    check({"test-fixture-a.jks": keystore[:-100]}),
    "test-fixture-a.jks",
)
tampered = bytearray(keystore)
tampered[len(tampered) // 2] ^= 0x01
expect_refused(
    "tampered-committed-keystore-refused",
    check({"test-fixture-a.jks": bytes(tampered)}),
    "test-fixture-a.jks",
)
expect_refused(
    "other-suffix-refused",
    check({"test-fixture-a.p12": keystore}),
    "test-fixture-a.p12",
)

# 4. A subdirectory in the signing folder is refused. A keystore inside it is never searched for and never
# silently skipped: the folder must contain only its own test-*.jks files.
output = check({"test-fixture-a.jks": keystore}, signing_directories=("nested",))
if "nested: unexpected directory in the test signing folder" not in output:
    fail("directory-in-signing-folder-refused", output)
passed("directory-in-signing-folder-refused")

# 5. The app bundle: a copy of the keystore in any form is refused.
bundle_file = "Contents/Resources/copy"
expect_encrypted_bundle_refused(
    "bundle-full-keystore-refused",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: keystore}),
)
expect_bundle_refused(
    "bundle-truncated-keystore-refused",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: keystore[:300]}),
)
archive = BytesIO()
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
    zipped.writestr("keystore.jks", keystore)
expect_bundle_refused(
    "bundle-deflated-zip-refused",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: archive.getvalue()}),
)
half = len(keystore) // 2
expect_bundle_refused(
    "bundle-split-keystore-refused",
    check(
        {"test-fixture-a.jks": keystore},
        app_files={"Contents/Resources/first": keystore[:half], "Contents/Resources/second": keystore[half:]},
    ),
)
# The certificate embeds its public key, so this DER copy is matched through the public-key token as well as
# the certificate token; the fingerprint case below covers the certificate token by itself.
expect_bundle_refused(
    "bundle-certificate-der-refused",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: certificate_der}),
)
expect_bundle_refused(
    "bundle-certificate-fingerprint-refused",
    check(
        {"test-fixture-a.jks": keystore},
        app_files={bundle_file: hashlib.sha256(certificate_der).hexdigest().encode("ascii")},
    ),
)
expect_bundle_refused(
    "bundle-public-key-refused",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: public_key_der}),
)
expect_bundle_refused(
    "bundle-public-key-identity-refused",
    check(
        {"test-fixture-a.jks": keystore},
        app_files={bundle_file: hashlib.sha256(public_key_der).hexdigest().encode("ascii")},
    ),
)
expect_accepted(
    "clean-app-accepted",
    check({"test-fixture-a.jks": keystore}, app_files={bundle_file: b"an ordinary resource"}),
)

# 6. The AOSP AVB fixture is a PKCS#1 RSA private key. Its private material is refused in the app bundle
# regardless of whether it is copied as PEM, PKCS#1 DER, or re-encoded as PKCS#8 DER. The public key remains
# safe to include in the app.
avb_private_key_path = signing_folder / "aosp-avb-testkey-rsa4096.pem"
avb_private_key = avb_private_key_path.read_bytes()
avb_private_der = openssl("rsa", "-in", str(avb_private_key_path), "-outform", "DER")
avb_private_pkcs8_der = openssl(
    "pkcs8", "-topk8", "-nocrypt", "-outform", "DER", stdin=avb_private_key
)
avb_private_pkcs8_pem = openssl(
    "pkcs8", "-topk8", "-nocrypt", "-in", str(avb_private_key_path)
)
avb_private_pkcs8_encrypted_pem = openssl(
    "pkcs8",
    "-topk8",
    "-v2",
    "aes-256-cbc",
    "-passout",
    "pass:test-fixture",
    "-in",
    str(avb_private_key_path),
)
avb_private_pkcs8_encrypted_der = openssl(
    "pkcs8",
    "-topk8",
    "-v2",
    "aes-256-cbc",
    "-passout",
    "pass:test-fixture",
    "-in",
    str(avb_private_key_path),
    "-outform",
    "DER",
)
avb_private_pkcs1_encrypted_pem = openssl(
    "rsa",
    "-in",
    str(avb_private_key_path),
    "-traditional",
    "-aes256",
    "-passout",
    "pass:test-fixture",
)
avb_private_pkcs8_base64 = base64.b64encode(avb_private_pkcs8_der)
avb_public_der = openssl("pkey", "-in", str(avb_private_key_path), "-pubout", "-outform", "DER")
avb_fixture = {"aosp-avb-testkey-rsa4096.pem": avb_private_key}
expect_accepted("aosp-avb-pkcs1-fixture-accepted", check(avb_fixture))
expect_unrecognized(
    "malformed-pkcs1-private-key-refused",
    check({"test-malformed-rsa.pem": b"-----BEGIN RSA PRIVATE KEY-----\nYQ==\n-----END RSA PRIVATE KEY-----\n"}),
    "test-malformed-rsa.pem",
)
expect_unrecognized(
    "truncated-pkcs1-private-key-refused",
    check({"test-truncated-rsa.pem": rsa_private_pem(avb_private_der[:-1])}),
    "test-truncated-rsa.pem",
)
expect_unrecognized(
    "pkcs1-private-key-trailing-data-refused",
    check({"test-trailing-data-rsa.pem": rsa_private_pem(avb_private_der + b"\x00")}),
    "test-trailing-data-rsa.pem",
)
expect_unrecognized(
    "pkcs1-private-key-nonminimal-integer-refused",
    check({"test-nonminimal-rsa.pem": rsa_private_pem(with_nonminimal_rsa_version(avb_private_der))}),
    "test-nonminimal-rsa.pem",
)
nonminimal_sequence_length = (
    avb_private_der[:1]
    + bytes([avb_private_der[1] + 1, 0])
    + avb_private_der[2:]
)
expect_unrecognized(
    "pkcs1-private-key-nonminimal-length-refused",
    check({"test-nonminimal-length-rsa.pem": rsa_private_pem(nonminimal_sequence_length)}),
    "test-nonminimal-length-rsa.pem",
)
expect_bundle_refused(
    "bundle-pkcs1-private-key-pem-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.pem": avb_private_key},
    ),
)
expect_bundle_refused(
    "bundle-pkcs1-private-key-der-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.der": avb_private_der},
    ),
)
expect_bundle_refused(
    "bundle-pkcs8-reencoded-private-key-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.pk8": avb_private_pkcs8_der},
    ),
)
expect_bundle_refused(
    "bundle-pkcs8-reencoded-private-key-pem-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.pem": avb_private_pkcs8_pem},
    ),
)
expect_bundle_refused(
    "bundle-pkcs8-reencoded-private-key-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": avb_private_pkcs8_base64
        },
    ),
)
expect_bundle_refused(
    "bundle-pkcs8-reencoded-private-key-url-safe-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.urlsafe_b64encode(
                avb_private_pkcs8_der
            )
        },
    ),
)
expect_bundle_refused(
    "bundle-pkcs8-reencoded-private-key-wrapped-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.encodebytes(avb_private_pkcs8_der)
        },
    ),
)
for base64_prefix_length in (1, 2, 3):
    prefix = b"!" * (1024 * 1024 - base64_prefix_length - 1)
    expect_bundle_refused(
        f"bundle-base64-private-key-whitespace-boundary-{base64_prefix_length}-char-refused",
        check(
            avb_fixture,
            app_files={
                "Contents/Resources/private-key.base64": prefix
                + avb_private_pkcs8_base64[:base64_prefix_length]
                + b"\n"
                + avb_private_pkcs8_base64[base64_prefix_length:]
            },
        ),
    )
expect_bundle_refused(
    "bundle-unterminated-pkcs8-private-key-pem-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.pem": avb_private_pkcs8_pem.split(
                b"-----END PRIVATE KEY-----"
            )[0]
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-pem-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.pem": avb_private_pkcs8_encrypted_pem},
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-der-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.der": avb_private_pkcs8_encrypted_der},
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.b64encode(
                avb_private_pkcs8_encrypted_der
            )
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-url-safe-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.urlsafe_b64encode(
                avb_private_pkcs8_encrypted_der
            )
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-unpadded-url-safe-base64-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.urlsafe_b64encode(
                avb_private_pkcs8_encrypted_der
            ).rstrip(b"=")
        },
    ),
)
for base64_decoy in (b"MA\n", b"MAAAM\n", b"MIIJ\n", b"MAEAM\n"):
    expect_encrypted_bundle_refused(
        "bundle-encrypted-pkcs8-private-key-after-base64-decoy-refused",
        check(
            avb_fixture,
            app_files={
                "Contents/Resources/private-key.base64": base64_decoy
                + base64.urlsafe_b64encode(avb_private_pkcs8_encrypted_der)
            },
        ),
    )
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-after-contiguous-base64-decoy-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": b"MAAAM"
            + base64.urlsafe_b64encode(avb_private_pkcs8_encrypted_der)
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-after-contiguous-padded-decoy-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": b"MAAAM==A"
            + base64.b64encode(avb_private_pkcs8_encrypted_der)
        },
    ),
)
encrypted_pkcs8_key_base64 = base64.b64encode(avb_private_pkcs8_encrypted_der)
if not encrypted_pkcs8_key_base64.endswith(b"="):
    raise SystemExit("encrypted PKCS#8 fixture must exercise Base64 padding")
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-followed-by-base64-character-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": encrypted_pkcs8_key_base64
            + b"A"
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-after-invalid-base64-prefix-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": b"MA!"
            + b"!" * 160
            + base64.urlsafe_b64encode(avb_private_pkcs8_encrypted_der)
        },
    ),
)
oversized_encrypted_key_prefix = (
    b"\x30"
    + der_length(100_000)
    + der_value(0x30, der_value(0x06, bytes.fromhex("2a864886f70d01050d")))
    + b"\x00" * 8192
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-after-long-incomplete-der-prefix-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": base64.b64encode(
                oversized_encrypted_key_prefix
            )
            + b"\n"
            + base64.b64encode(avb_private_pkcs8_encrypted_der)
        },
    ),
)
encrypted_pkcs8_urlsafe_base64 = base64.urlsafe_b64encode(
    avb_private_pkcs8_encrypted_der
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-after-valid-base64-prefix-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": encrypted_pkcs8_urlsafe_base64[:61]
            + b"\n"
            + encrypted_pkcs8_urlsafe_base64
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-base64-chunk-boundary-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.base64": b"!" * (1024 * 1024 - 1)
            + base64.b64encode(avb_private_pkcs8_encrypted_der)
        },
    ),
)
encrypted_pkcs8_base64 = base64.b64encode(avb_private_pkcs8_encrypted_der)
for base64_line_width in (63, 1, 2, 3):
    expect_encrypted_bundle_refused(
        f"bundle-encrypted-pkcs8-private-key-wrapped-base64-{base64_line_width}-refused",
        check(
            avb_fixture,
            app_files={
                "Contents/Resources/private-key.base64": b"\n".join(
                    encrypted_pkcs8_base64[index : index + base64_line_width]
                    for index in range(0, len(encrypted_pkcs8_base64), base64_line_width)
                )
            },
        ),
    )
expect_accepted(
    "bundle-noisy-binary-skips-fragmented-base64-scan",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/noisy.bin": b"Z\nA!" * (1024 * 1024 // 4)
        },
    ),
)
base64_noise = bytearray(base64.b64encode(bytes(range(256)) * 512))
base64_noise[:2] = b"MI"
expect_accepted(
    "bundle-noisy-base64-skips-invalid-der-candidates",
    check(
        avb_fixture,
        app_files={"Contents/Resources/noisy.base64": base64_noise},
    ),
)
expect_accepted(
    "bundle-noisy-base64-invalid-probe-candidates-remain-bounded",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/noisy-prefixes.base64": (
                (b"MA" * 63 + b"!") * 8192 + b"!" * 128
            )
        },
    ),
)
expect_uninspectable_bundle_refused(
    "bundle-base64-der-candidate-limit-fails-closed",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/dense-der-prefixes.base64": b"MII" * 350_000
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-hex-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.hex": avb_private_pkcs8_encrypted_der.hex().encode("ascii")
        },
    ),
)
encrypted_pkcs8_hex = avb_private_pkcs8_encrypted_der.hex().encode("ascii").upper()
for hex_line_width in (64, 63, 8):
    expect_encrypted_bundle_refused(
        f"bundle-encrypted-pkcs8-private-key-wrapped-hex-{hex_line_width}-refused",
        check(
            avb_fixture,
            app_files={
                "Contents/Resources/private-key.hex": b"\n".join(
                    encrypted_pkcs8_hex[index : index + hex_line_width]
                    for index in range(0, len(encrypted_pkcs8_hex), hex_line_width)
                )
            },
        ),
    )
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs8-private-key-hex-chunk-boundary-refused",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/private-key.hex": b"!" * (1024 * 1024 - 1)
            + encrypted_pkcs8_hex
        },
    ),
)
expect_accepted(
    "bundle-encryption-oid-fragment-without-private-key-accepted",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/crypto-documentation.bin": b"\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x05\x0d"
        },
    ),
)
expect_accepted(
    "bundle-encryption-oid-hex-fragment-without-private-key-accepted",
    check(
        avb_fixture,
        app_files={
            "Contents/Resources/crypto-documentation.hex": "06092a864886f70d01050d".encode("ascii")
        },
    ),
)
expect_encrypted_bundle_refused(
    "bundle-encrypted-pkcs1-private-key-pem-refused",
    check(
        avb_fixture,
        app_files={"Contents/Resources/private-key.pem": avb_private_pkcs1_encrypted_pem},
    ),
)
expect_accepted(
    "bundle-rsa-public-key-accepted",
    check(
        avb_fixture,
        app_files={"Contents/Resources/public-key.der": avb_public_der},
    ),
)

# 7. The image bundle, the second argument, is scanned the same way.
expect_bundle_refused(
    "image-bundle-keystore-refused",
    check({"test-fixture-a.jks": keystore}, image_files={"disks/os.img": keystore}),
)
expect_accepted(
    "clean-image-bundle-accepted",
    check({"test-fixture-a.jks": keystore}, image_files={"manifest.json": b"{}\n", "boot/kernel": b"kernel"}),
)
