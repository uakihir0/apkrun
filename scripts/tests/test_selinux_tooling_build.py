"""T0 checks for the pinned CIL-enabled macOS secilc tool."""

import hashlib
import io
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "tools"))

import build_selinux_tools as builder  # noqa: E402


def lock_document():
    return json.loads((REPO_ROOT / "ThirdParty/ThirdParty.lock.json").read_text(encoding="utf-8"))


class LockedInputTests(unittest.TestCase):
    def test_selinux_source_pin_and_cil_build_flags(self):
        components = builder.validate_lock(REPO_ROOT)
        entry = components[builder.COMPONENT]
        self.assertEqual(
            entry["commit"], "2233a23a4d4f1bf29054037babec13f30d038e65"
        )
        self.assertEqual(entry["version"], "3.11")
        self.assertEqual(
            entry["buildFlags"],
            [
                "libsepol.DISABLE_CIL=n",
                "libsepol.DISABLE_SHARED=y",
                "secilc.target=secilc",
            ],
        )
        for license_file in entry["licenseFiles"]:
            self.assertTrue((REPO_ROOT / "ThirdParty/licenses/selinux-cil" / license_file).is_file())

    def test_existing_libsepol_archive_stays_cil_disabled(self):
        entry = builder.lock_component(lock_document(), "libsepol")
        self.assertEqual(entry["version"], "3.11")
        self.assertEqual(entry["buildFlags"], ["DISABLE_CIL=y", "CFLAGS=-O2"])

    def test_flex_and_m4_are_built_from_existing_sha_pins(self):
        components = builder.validate_lock(REPO_ROOT)
        self.assertEqual(
            components["flex"]["sha256"],
            "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995",
        )
        self.assertEqual(
            components["m4"]["sha256"],
            "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b",
        )

    def test_reviewed_commit_change_is_rejected_before_build(self):
        document = lock_document()
        source = builder.lock_component(document, builder.COMPONENT)
        source["commit"] = "a" * 40
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-lock-") as temporary:
            root = pathlib.Path(temporary)
            (root / "ThirdParty").mkdir()
            (root / "ThirdParty/ThirdParty.lock.json").write_text(
                json.dumps(document), encoding="utf-8"
            )
            shutil.copytree(
                REPO_ROOT / "ThirdParty/licenses/selinux-cil",
                root / "ThirdParty/licenses/selinux-cil",
            )
            with self.assertRaisesRegex(builder.BuildFailure, "reviewed CIL build pin"):
                builder.validate_lock(root)

    def test_build_cache_key_changes_when_builder_changes(self):
        components = builder.validate_lock(REPO_ROOT)
        environment = {"sdk": "27.0", "clang": "test"}
        original = builder.cache_key(REPO_ROOT, components, environment)
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-hash-") as temporary:
            root = pathlib.Path(temporary)
            for relative in builder.BUILD_INPUTS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((REPO_ROOT / relative).read_bytes())
            lock_path = root / "ThirdParty/ThirdParty.lock.json"
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            lock_path.write_text(
                json.dumps({"components": list(components.values())}), encoding="utf-8"
            )
            baseline = builder.cache_key(root, components, environment)
            script = root / builder.BUILD_INPUTS[-1]
            script.write_bytes(script.read_bytes() + b"\n# cache input change\n")
            self.assertNotEqual(baseline, builder.cache_key(root, components, environment))
        self.assertEqual(original, builder.cache_key(REPO_ROOT, components, environment))

    def test_dangling_tool_prefix_symlink_is_rejected_before_cache_lookup(self):
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-cache-") as temporary:
            root = pathlib.Path(temporary)
            tools_root = root / "tools"
            tools_root.mkdir()
            (tools_root / "m4").symlink_to(root / "missing-target")
            with self.assertRaisesRegex(builder.BuildFailure, "symlinked tool prefix"):
                builder.build_pinned_tool(
                    name="m4",
                    version="1.4.20",
                    expected_sha256="a" * 64,
                    url="https://example.invalid/m4.tar.xz",
                    archive=root / "missing-archive",
                    tools_root=tools_root,
                    build_root=root / "build",
                    jobs=1,
                )

    def test_private_build_directory_ignores_a_dangling_predictable_path(self):
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-work-") as temporary:
            parent = pathlib.Path(temporary)
            predictable = parent / "flex-src"
            predictable.symlink_to(parent / "missing-target")
            private = builder.private_directory(parent, ".flex-source-")
            self.assertNotEqual(private, predictable)
            self.assertTrue(private.is_dir())
            self.assertTrue(predictable.is_symlink())
            self.assertEqual(private.stat().st_mode & 0o777, 0o700)

    def test_safe_extract_rejects_dangling_symlink_destination(self):
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-extract-") as temporary:
            root = pathlib.Path(temporary)
            destination = root / "extract"
            destination.symlink_to(root / "missing-target")
            with self.assertRaisesRegex(builder.BuildFailure, "symlinked extraction directory"):
                builder.safe_extract(root / "unused-archive", destination)
            self.assertTrue(destination.is_symlink())


class ArchiveDownloadTests(unittest.TestCase):
    def test_part_symlink_created_during_download_cannot_redirect_archive_bytes(self):
        payload = b"pinned archive payload"

        class Response(io.BytesIO):
            status = 200

        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-download-") as temporary:
            root = pathlib.Path(temporary)
            destination = root / "m4-1.4.20.tar.xz"
            victim = root / "outside"
            victim.write_bytes(b"do not overwrite")
            legacy_part = destination.with_name(destination.name + f".part-{os.getpid()}")
            legacy_part.symlink_to(victim)

            def recreate_legacy_symlink(*_arguments, **_kwargs):
                legacy_part.unlink(missing_ok=True)
                legacy_part.symlink_to(victim)
                return Response(payload)

            with mock.patch.object(
                builder.urllib.request, "urlopen", side_effect=recreate_legacy_symlink
            ):
                builder.fetch_archive(
                    "https://example.invalid/m4-1.4.20.tar.xz",
                    hashlib.sha256(payload).hexdigest(),
                    destination,
                )

            self.assertEqual(victim.read_bytes(), b"do not overwrite")
            self.assertEqual(destination.read_bytes(), payload)
            self.assertTrue(legacy_part.is_symlink())

    def test_failed_retry_preserves_existing_archive_and_cleans_staging(self):
        with tempfile.TemporaryDirectory(prefix="apkrun-selinux-retry-") as temporary:
            root = pathlib.Path(temporary)
            destination = root / "flex-2.6.4.tar.gz"
            destination.write_bytes(b"previous incomplete download")
            with mock.patch.object(
                builder.urllib.request,
                "urlopen",
                side_effect=builder.urllib.error.URLError("offline"),
            ):
                with self.assertRaisesRegex(builder.BuildFailure, "could not download pinned archive"):
                    builder.fetch_archive(
                        "https://example.invalid/flex-2.6.4.tar.gz",
                        "a" * 64,
                        destination,
                    )
            self.assertEqual(destination.read_bytes(), b"previous incomplete download")
            self.assertEqual(list(root.glob(f".{destination.name}.part-*")), [])


class BinaryVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="apkrun-secilc-verify-")
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / "source"
        (self.source / "secilc/test").mkdir(parents=True)
        (self.source / "secilc/test/policy.cil").write_text(
            "(handleunknown deny)\n", encoding="utf-8"
        )
        self.binary = self.root / "secilc"
        self.binary.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib, sys\n"
            "if '--help' in sys.argv:\n"
            "    print('Usage: secilc')\n"
            "    raise SystemExit(1)\n"
            "for option in ('--output', '--filecontexts'):\n"
            "    pathlib.Path(sys.argv[sys.argv.index(option) + 1]).write_text('ok')\n",
            encoding="utf-8",
        )
        self.binary.chmod(0o755)
        self.lipo = self._tool("lipo", "print('arm64')\n")
        self.otool = self._tool(
            "otool",
            "import pathlib, sys\n"
            "if sys.argv[1] == '-L':\n"
            "    print(sys.argv[-1] + ':')\n"
            "    print('  ' + DEPENDENCY + ' (compatibility version 1.0.0, current version 1.0.0)')\n",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def _tool(self, name, body):
        path = self.root / name
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "DEPENDENCY = os.environ.get('APKRUN_TEST_DEPENDENCY', '/usr/lib/libSystem.B.dylib')\n"
            + body,
            encoding="utf-8",
        )
        path.chmod(0o755)
        return str(path)

    def _verify(self):
        builder.verify_binary(
            self.binary,
            source=self.source,
            lipo=self.lipo,
            otool=self.otool,
        )

    def test_arm64_static_cil_binary_compiles_a_policy(self):
        self._verify()

    def test_non_arm64_binary_is_rejected(self):
        self.lipo = self._tool("lipo-x86", "print('x86_64')\n")
        with self.assertRaisesRegex(builder.BuildFailure, "only arm64"):
            self._verify()

    def test_dynamic_libsepol_dependency_is_rejected(self):
        previous = os.environ.get("APKRUN_TEST_DEPENDENCY")
        os.environ["APKRUN_TEST_DEPENDENCY"] = "/build/libsepol.dylib"
        try:
            with self.assertRaisesRegex(builder.BuildFailure, "unexpected dynamic dependencies"):
                self._verify()
        finally:
            if previous is None:
                os.environ.pop("APKRUN_TEST_DEPENDENCY", None)
            else:
                os.environ["APKRUN_TEST_DEPENDENCY"] = previous

    def test_non_system_dynamic_library_is_rejected(self):
        previous = os.environ.get("APKRUN_TEST_DEPENDENCY")
        os.environ["APKRUN_TEST_DEPENDENCY"] = "/opt/homebrew/lib/libhelper.dylib"
        try:
            with self.assertRaisesRegex(builder.BuildFailure, "unexpected dynamic dependencies"):
                self._verify()
        finally:
            if previous is None:
                os.environ.pop("APKRUN_TEST_DEPENDENCY", None)
            else:
                os.environ["APKRUN_TEST_DEPENDENCY"] = previous


if __name__ == "__main__":
    unittest.main()
