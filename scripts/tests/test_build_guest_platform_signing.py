#!/usr/bin/env python3
"""Checks Guest APK signing modes and the composed-image privileged-permission allowlist."""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
BUILD_SCRIPT = REPOSITORY / "scripts" / "build-guest.sh"
DEVELOPMENT_SIGNER = "c58db702f39e9b809ad166d173f165478b4c7cb718d4d0cc89ebe8956438c900"
PLATFORM_SIGNER = "c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"
ANDROID_NAMESPACE = "{http://schemas.android.com/apk/res/android}"
PRIVILEGED_PERMISSIONS = {
    "android.permission.FORCE_STOP_PACKAGES",
    "android.permission.WRITE_SECURE_SETTINGS",
    "android.permission.REBOOT",
}
STORE_PRIVILEGED_PERMISSIONS = {
    "android.permission.DELETE_PACKAGES",
    "android.permission.INSTALL_PACKAGES",
    "android.permission.TEST_MANAGE_ROLLBACKS",
}
REQUESTED_PERMISSIONS = {
    "android.permission.FORCE_STOP_PACKAGES",
    "android.permission.INJECT_EVENTS",
    "android.permission.INTERNAL_SYSTEM_WINDOW",
    "android.permission.MANAGE_ACTIVITY_TASKS",
    "android.permission.REMOVE_TASKS",
    "android.permission.SET_ACTIVITY_WATCHER",
    "android.permission.QUERY_ALL_PACKAGES",
    "android.permission.WRITE_SECURE_SETTINGS",
    "android.permission.REBOOT",
    "android.permission.WRITE_SETTINGS",
    "android.permission.ACCESS_KEYGUARD_SECURE_STORAGE",
}


class BuildGuestSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="apkrun-build-guest-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(BUILD_SCRIPT, self.root / "scripts" / "build-guest.sh")
        (self.root / "project.yml").write_text(
            'MARKETING_VERSION: "1.2.3"\n',
            encoding="utf-8",
        )
        (self.root / "Guest/guestd/build/outputs/apk/release").mkdir(parents=True)
        (self.root / "Guest/APKRunStore/build/outputs/apk/release").mkdir(parents=True)
        (self.root / "Guest/product/prebuilt").mkdir(parents=True)
        (self.root / "Tests/Fixtures/signing").mkdir(parents=True)
        for fixture in (
            "aosp-test-platform.pk8",
            "aosp-test-platform.x509.pem",
        ):
            shutil.copy2(
                REPOSITORY / "Tests/Fixtures/signing" / fixture,
                self.root / "Tests/Fixtures/signing" / fixture,
            )

        gradlew = self.root / "gradlew"
        gradlew.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            'repo_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"\n'
            'printf "%s\\n" "$@" > "$repo_dir/gradle-arguments.txt"\n'
            'printf "development-signed APK\\n" > '
            '"$repo_dir/Guest/guestd/build/outputs/apk/release/guestd-release.apk"\n'
            'printf "development-signed Store APK\\n" > '
            '"$repo_dir/Guest/APKRunStore/build/outputs/apk/release/store-release.apk"\n',
            encoding="utf-8",
        )
        gradlew.chmod(0o755)

        build_tools = self.root / "build/android-sdk/build-tools/37.0.0"
        build_tools.mkdir(parents=True)
        apksigner = build_tools / "apksigner"
        apksigner.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, shutil, sys\n"
            "args = sys.argv[1:]\n"
            "if args[0] == 'verify':\n"
            "    data = pathlib.Path(args[-1]).read_bytes()\n"
            "    digest = os.environ['APKRUN_PLATFORM_DIGEST'] if b'PLATFORM-SIGNED' in data else os.environ['APKRUN_DEV_DIGEST']\n"
            "    print(f'Signer #1 certificate SHA-256 digest: {digest}')\n"
            "elif args[0] == 'sign':\n"
            "    key = pathlib.Path(args[args.index('--key') + 1])\n"
            "    cert = pathlib.Path(args[args.index('--cert') + 1])\n"
            "    output = pathlib.Path(args[args.index('--out') + 1])\n"
            "    source = pathlib.Path(args[-1])\n"
            "    if not key.is_file() or not cert.is_file():\n"
            "        raise SystemExit('missing platform test key material')\n"
            "    output.write_bytes(source.read_bytes() + b'PLATFORM-SIGNED')\n"
            "    pathlib.Path(str(output) + '.idsig').write_bytes(b'V4 signature sidecar')\n"
            "else:\n"
            "    raise SystemExit(f'unexpected apksigner invocation: {args}')\n",
            encoding="utf-8",
        )
        apksigner.chmod(0o755)

    def invoke(self, *arguments, platform_digest=PLATFORM_SIGNER):
        environment = os.environ.copy()
        environment.update(
            {
                "ANDROID_HOME": str(self.root / "build/android-sdk"),
                "APKRUN_DEV_DIGEST": DEVELOPMENT_SIGNER,
                "APKRUN_PLATFORM_DIGEST": platform_digest,
            }
        )
        return subprocess.run(
            [str(self.root / "scripts/build-guest.sh"), *arguments],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_default_build_stays_development_signed(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "Guest/build/out/apkrun-guest.apk").read_bytes(),
            b"development-signed APK\n",
        )
        self.assertEqual(
            (self.root / "Guest/build/out/apkrun-store.apk").read_bytes(),
            b"development-signed Store APK\n",
        )
        self.assertFalse(
            (self.root / "Guest/product/prebuilt/ApkRunGuest.apk").exists()
        )
        self.assertNotIn(
            "-PapkrunPersistentAgent=true",
            (self.root / "gradle-arguments.txt").read_text(),
        )
        self.assertNotIn(
            "-PapkrunTestHealthFailureProperty=",
            (self.root / "gradle-arguments.txt").read_text(),
        )
        self.assertIn(
            '"versionCode": 1002003',
            (self.root / "Guest/build/out/apkrun-guest.json").read_text(),
        )
        store_metadata = json.loads(
            (self.root / "Guest/build/out/apkrun-store.json").read_text()
        )
        self.assertEqual(store_metadata["packageName"], "io.apkrun.store")
        self.assertEqual(store_metadata["versionCode"], 1002003)

    def test_for_aosp_requires_platform_test_key_before_building(self):
        result = self.invoke("--for-aosp")
        self.assertEqual(result.returncode, 64)
        self.assertIn("--for-aosp requires --platform-test-key", result.stderr)
        self.assertFalse((self.root / "gradle-arguments.txt").exists())

    def test_platform_test_key_signs_only_the_aosp_prebuilt_and_checks_the_pinned_cert(
        self,
    ):
        result = self.invoke("--platform-test-key")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "Guest/product/prebuilt/ApkRunGuest.apk").read_bytes(),
            b"development-signed APK\nPLATFORM-SIGNED",
        )
        self.assertEqual(
            (self.root / "Guest/product/prebuilt/ApkRunStore.apk").read_bytes(),
            b"development-signed Store APK\nPLATFORM-SIGNED",
        )
        self.assertTrue(
            (self.root / "Guest/product/prebuilt/ApkRunGuest.json").is_file()
        )
        store_metadata = json.loads(
            (self.root / "Guest/product/prebuilt/ApkRunStore.json").read_text()
        )
        self.assertEqual(store_metadata["packageName"], "io.apkrun.store")
        self.assertEqual(store_metadata["versionCode"], 1002003)
        self.assertIn(
            "-PapkrunPersistentAgent=true",
            (self.root / "gradle-arguments.txt").read_text(),
        )
        self.assertFalse((self.root / "Guest/build/out/apkrun-guest.apk").exists())
        self.assertEqual(
            sorted(
                path.name for path in (self.root / "Guest/product/prebuilt").iterdir()
            ),
            [
                "ApkRunGuest.apk",
                "ApkRunGuest.json",
                "ApkRunStore.apk",
                "ApkRunStore.json",
            ],
        )
        self.assertFalse(
            any(
                path.name.endswith(".idsig")
                for path in (self.root / "Guest/product/prebuilt").iterdir()
            )
        )

    def test_health_failure_hook_requires_platform_test_signing(self):
        result = self.invoke("--test-image-hooks")

        self.assertEqual(result.returncode, 64)
        self.assertIn("--test-image-hooks requires --platform-test-key", result.stderr)
        self.assertFalse((self.root / "gradle-arguments.txt").exists())

    def test_health_failure_hook_is_explicit_and_platform_signed(self):
        result = self.invoke("--platform-test-key", "--test-image-hooks")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = (self.root / "gradle-arguments.txt").read_text()
        self.assertIn(
            "-PapkrunTestHealthFailureProperty=ro.boot.apkrun.test.fail_health",
            arguments,
        )
        self.assertEqual(
            (self.root / "Guest/product/prebuilt/ApkRunGuest.apk").read_bytes(),
            b"development-signed APK\nPLATFORM-SIGNED",
        )
        self.assertEqual(
            (self.root / "Guest/product/prebuilt/ApkRunStore.apk").read_bytes(),
            b"development-signed Store APK\nPLATFORM-SIGNED",
        )

    def test_platform_test_key_rejects_custom_output_path_before_building(self):
        result = self.invoke(
            "--platform-test-key", "--out", str(self.root / "elsewhere")
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("--for-aosp chooses", result.stderr)
        self.assertFalse((self.root / "gradle-arguments.txt").exists())

    def test_platform_signer_mismatch_preserves_existing_prebuilt_and_cleans_temporary_files(
        self,
    ):
        apk = self.root / "Guest/product/prebuilt/ApkRunGuest.apk"
        metadata = self.root / "Guest/product/prebuilt/ApkRunGuest.json"
        store_apk = self.root / "Guest/product/prebuilt/ApkRunStore.apk"
        store_metadata = self.root / "Guest/product/prebuilt/ApkRunStore.json"
        apk.write_bytes(b"previous APK")
        metadata.write_bytes(b"previous metadata")
        store_apk.write_bytes(b"previous Store APK")
        store_metadata.write_bytes(b"previous Store metadata")

        result = self.invoke("--platform-test-key", platform_digest="0" * 64)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not signed by the pinned AOSP test platform key", result.stderr)
        self.assertEqual(apk.read_bytes(), b"previous APK")
        self.assertEqual(metadata.read_bytes(), b"previous metadata")
        self.assertEqual(store_apk.read_bytes(), b"previous Store APK")
        self.assertEqual(store_metadata.read_bytes(), b"previous Store metadata")
        self.assertEqual(
            sorted(
                path.name for path in (self.root / "Guest/product/prebuilt").iterdir()
            ),
            [
                "ApkRunGuest.apk",
                "ApkRunGuest.json",
                "ApkRunStore.apk",
                "ApkRunStore.json",
            ],
        )
        self.assertFalse(
            any(
                path.name.endswith(".idsig")
                for path in (self.root / "Guest/product/prebuilt").iterdir()
            )
        )


class GuestProductPermissionTests(unittest.TestCase):
    def test_privapp_allowlist_contains_exactly_manifest_permissions_that_need_it(self):
        guest_manifest = ET.parse(
            REPOSITORY / "Guest/guestd/src/main/AndroidManifest.xml"
        ).getroot()
        guest_requested = {
            permission.attrib[f"{ANDROID_NAMESPACE}name"]
            for permission in guest_manifest.findall("uses-permission")
        }
        self.assertEqual(guest_requested, REQUESTED_PERMISSIONS)
        self.assertTrue(PRIVILEGED_PERMISSIONS <= guest_requested)
        store_manifest = ET.parse(
            REPOSITORY / "Guest/APKRunStore/src/main/AndroidManifest.xml"
        ).getroot()
        store_requested = {
            permission.attrib[f"{ANDROID_NAMESPACE}name"]
            for permission in store_manifest.findall("uses-permission")
        }
        self.assertTrue(STORE_PRIVILEGED_PERMISSIONS <= store_requested)

        allowlist_path = (
            REPOSITORY / "Guest/product/permissions/privapp-permissions-apkrun.xml"
        )
        allowlist = ET.parse(allowlist_path).getroot()
        entries = {
            entry.attrib["package"]: {
                permission.attrib["name"] for permission in entry.findall("permission")
            }
            for entry in allowlist.findall("privapp-permissions")
        }
        self.assertEqual(
            entries,
            {
                "io.apkrun.guest": PRIVILEGED_PERMISSIONS,
                "io.apkrun.store": STORE_PRIVILEGED_PERMISSIONS,
            },
        )
        self.assertTrue(entries["io.apkrun.guest"] <= guest_requested)
        self.assertTrue(entries["io.apkrun.store"] <= store_requested)

    def test_platform_certificate_matches_the_pinned_full_sha256(self):
        certificate = REPOSITORY / "Tests/Fixtures/signing/aosp-test-platform.x509.pem"
        private_key = REPOSITORY / "Tests/Fixtures/signing/aosp-test-platform.pk8"
        result = subprocess.run(
            ["openssl", "x509", "-in", str(certificate), "-outform", "DER"],
            capture_output=True,
            check=True,
        )
        self.assertEqual(hashlib.sha256(result.stdout).hexdigest(), PLATFORM_SIGNER)
        cert_public_key = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"],
            input=result.stdout,
            capture_output=True,
            check=True,
        )
        cert_public_key_der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=cert_public_key.stdout,
            capture_output=True,
            check=True,
        )
        private_key_public_key = subprocess.run(
            [
                "openssl",
                "pkey",
                "-inform",
                "DER",
                "-in",
                str(private_key),
                "-pubout",
                "-outform",
                "DER",
            ],
            capture_output=True,
            check=True,
        )
        self.assertEqual(cert_public_key_der.stdout, private_key_public_key.stdout)


if __name__ == "__main__":
    unittest.main()
