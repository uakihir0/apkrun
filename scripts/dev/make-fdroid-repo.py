#!/usr/bin/env python3
"""Builds the committed F-Droid v2 test repository (#52).

Regenerates Tests/Fixtures/update-repos/fdroid/repo/ deterministically:

  entry.jar                 MANIFEST.MF + CERT.SF + CERT.RSA + entry.json
  entry-unsigned.jar        same jar without the signature block
  entry-tampered.jar        a valid signature over a changed entry.json
  index-v2.json             the current index
  index-v2-old.json         the previous index the committed diff patches
  diff/<old-ts>.json        RFC 7396 merge patch old -> current
  io.apkrun.fixture.helloupdate_<vc>.apk

The jar is signed with the test-only self-signed key
Tests/Fixtures/signing/test-fdroid-repo.pem (the certificate lives next
to the repo as update-repos/fdroid/repo-signing-cert.pem — signing
fixtures may not carry a certificate block). The printed certificate
SHA-256 is the fingerprint the T1 test spec uses.

Usage: scripts/dev/make-fdroid-repo.py
"""

import base64
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "Tests", "Fixtures", "update-repos", "fdroid", "repo")
KEY = os.path.join(ROOT, "Tests", "Fixtures", "signing", "test-fdroid-repo.pem")
CERT = os.path.join(ROOT, "Tests", "Fixtures", "update-repos", "fdroid",
                  "repo-signing-cert.pem")
APKS = os.path.join(ROOT, "Tests", "Fixtures", "apks")

PKG = "io.apkrun.fixture.helloupdate"
SIGNER_A = "a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"
SIGNER_B = "18193ac4f80aefb6e6c9a94aace58f188ded76c774d35cff13f4e8879b6c0581"

# Timestamps are fixed so the committed diff name is stable.
OLD_TS = 1_700_000_000_000
NEW_TS = 1_700_000_100_000


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def b64sha256(data: bytes) -> str:
    return base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")


def version_obj(version_code: int, apk_name: str, signer: str,
                version_name: str) -> dict:
    return {
        "added": OLD_TS,
        "file": {
            "name": apk_name,
            "sha256": sha256(open(os.path.join(OUT, apk_name), "rb").read()),
            "size": os.path.getsize(os.path.join(OUT, apk_name)),
        },
        "manifest": {
            "versionName": version_name,
            "versionCode": version_code,
            "usesSdk": {"minSdkVersion": 24, "targetSdkVersion": 35},
            "signer": {"sha256": [signer]},
            "nativecode": [],
            "usesPermission": [],
            "usesPermissionSdk23": [],
            "features": [],
        },
        "releaseChannels": ["Beta"],
        "antiFeatures": {},
        "whatsNew": {"en-US": "fixture"},
    }


def index_doc(package_versions: dict) -> dict:
    return {
        "repo": {
            "name": {"en-US": "APKRun test F-Droid repo"},
            "icon": {},
            "address": "http://127.0.0.1",
            "description": {"en-US": "fixture"},
            "timestamp": NEW_TS,
        },
        "packages": {PKG: {"metadata": {}, "versions": package_versions}},
    }


def file_entry(name: str) -> dict:
    data = open(os.path.join(OUT, name), "rb").read()
    return {"name": name, "sha256": sha256(data), "size": len(data)}


def wrap_72(text: str) -> str:
    """Manifest-style 72-byte lines (continuation lines start with a space)."""
    out = []
    while len(text.encode("utf-8")) > 70:
        # Split on bytes so a multibyte rune is never cut; fixture text is ASCII.
        out.append(text[:70])
        text = " " + text[70:]
    out.append(text)
    return "\r\n".join(out)


def manifest_for(entry_json: bytes) -> bytes:
    body = (
        "Manifest-Version: 1.0\r\n"
        "Created-By: apkrun-test\r\n"
        "\r\n"
        "Name: entry.json\r\n"
        "SHA-256-Digest: " + b64sha256(entry_json) + "\r\n"
        "\r\n"
    )
    return body.encode("utf-8")


def sf_for(manifest: bytes, entry_json: bytes) -> bytes:
    body = (
        "Signature-Version: 1.0\r\n"
        "Created-By: apkrun-test\r\n"
        "SHA-256-Digest-Manifest: " + b64sha256(manifest) + "\r\n"
        "\r\n"
    )
    return body.encode("utf-8")


def sign_sf(sf: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        sf_path = os.path.join(tmp, "CERT.SF")
        rsa_path = os.path.join(tmp, "CERT.RSA")
        with open(sf_path, "wb") as handle:
            handle.write(sf)
        subprocess.run(
            [
                "openssl", "cms", "-sign", "-binary", "-outform", "DER",
                "-in", sf_path, "-signer", CERT, "-inkey", KEY,
                "-out", rsa_path, "-noattr",
            ],
            check=True, capture_output=True)
        with open(rsa_path, "rb") as handle:
            return handle.read()


def build_jar(path: str, entry_json: bytes, tamper: bool, unsigned: bool):
    # The digests and signature always cover the genuine entry.json; a
    # "tampered" jar ships a modified payload under them and must fail.
    manifest = manifest_for(entry_json)
    sf = sf_for(manifest, entry_json)
    shown_json = entry_json + (b" " if tamper else b"")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as jar:
        jar.writestr("META-INF/MANIFEST.MF", manifest)
        jar.writestr("META-INF/CERT.SF", sf)
        if not unsigned:
            jar.writestr("META-INF/CERT.RSA", sign_sf(sf))
        jar.writestr("entry.json", shown_json)


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.join(OUT, "diff"), exist_ok=True)

    # APK artifacts named like a real F-Droid repo.
    for source, name in (
        ("HelloUpdate-v1.apk", "%s_1.apk" % PKG),
        ("HelloUpdate-v2.apk", "%s_2.apk" % PKG),
    ):
        with open(os.path.join(APKS, source), "rb") as src, open(
            os.path.join(OUT, name), "wb"
        ) as dst:
            dst.write(src.read())

    old_index = index_doc(
        {
            sha256(open(os.path.join(OUT, "%s_1.apk" % PKG), "rb").read()):
            version_obj(1, "%s_1.apk" % PKG, SIGNER_A, "1.0"),
        })
    new_index = index_doc(dict(old_index["packages"][PKG]["versions"]))
    v2 = version_obj(2, "%s_2.apk" % PKG, SIGNER_A, "2.0")
    new_index["packages"][PKG]["versions"] = dict(
        new_index["packages"][PKG]["versions"])
    new_index["packages"][PKG]["versions"][v2["file"]["sha256"]] = v2
    # A version signed by key B: never a candidate for a key-A install.
    other = version_obj(3, "%s_2.apk" % PKG, SIGNER_B, "3.0-other")
    other["file"]["name"] = "%s_2.apk" % PKG
    new_index["packages"][PKG]["versions"]["b" * 64] = other

    with open(os.path.join(OUT, "index-v2-old.json"), "w") as handle:
        json.dump(old_index, handle, separators=(",", ":"), sort_keys=True)
    new_bytes = json.dumps(new_index, separators=(",", ":"),
                           sort_keys=True).encode("utf-8")
    with open(os.path.join(OUT, "index-v2.json"), "wb") as handle:
        handle.write(new_bytes)

    # The merge patch old -> new: adds the two new version entries.
    patch = {
        "packages": {
            PKG: {
                "versions": {
                    v2["file"]["sha256"]: v2,
                    "b" * 64: other,
                }
            }
        }
    }
    patch_name = "diff/%d.json" % OLD_TS
    with open(os.path.join(OUT, patch_name), "w") as handle:
        json.dump(patch, handle, separators=(",", ":"), sort_keys=True)

    index_ref = file_entry("index-v2.json")
    index_ref["numPackages"] = 1
    entry = {
        "timestamp": NEW_TS,
        "version": 2000,
        "index": index_ref,
        "diffs": {str(OLD_TS): file_entry(patch_name)},
    }
    entry_json = json.dumps(entry, separators=(",", ":"),
                            sort_keys=True).encode("utf-8")

    build_jar(os.path.join(OUT, "entry.jar"), entry_json, tamper=False,
              unsigned=False)
    build_jar(os.path.join(OUT, "entry-unsigned.jar"), entry_json,
              tamper=False, unsigned=True)
    # "tampered": a correctly signed jar whose entry.json no longer matches
    # the signed digests — verification must refuse it.
    build_jar(os.path.join(OUT, "entry-tampered.jar"), entry_json,
              tamper=True, unsigned=False)

    cert = subprocess.run(
        ["openssl", "x509", "-in", CERT, "-outform", "DER"],
        check=True, capture_output=True).stdout
    print("repo:", OUT)
    print("cert sha256 (spec fingerprint):", sha256(cert))
    return 0


if __name__ == "__main__":
    sys.exit(main())
