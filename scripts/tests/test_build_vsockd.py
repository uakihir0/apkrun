#!/usr/bin/env python3
"""Focused checks for the pinned Android vsockd build and staging path."""

import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build-vsockd.sh"
STAGE_HELPER = REPO_ROOT / "scripts" / "guest" / "stage_vsockd.py"
LOCK_HELPER = REPO_ROOT / "scripts" / "guest" / "mesa_android.py"


class BuildVsockdTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "repo"
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir(parents=True)
        self.crate = self.root / "Guest" / "vsockd"
        self.prebuilt = self.root / "Guest" / "product" / "prebuilt"
        self.ndk = self.root / "ndk"
        self.crate.mkdir(parents=True)
        self.prebuilt.mkdir(parents=True)
        self.ndk.mkdir()

        (self.root / "scripts" / "guest").mkdir(parents=True)
        (self.root / "scripts" / "tool-versions.env").parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BUILD_SCRIPT, self.root / "scripts" / "build-vsockd.sh")
        shutil.copy2(STAGE_HELPER, self.root / "scripts" / "guest" / "stage_vsockd.py")
        shutil.copy2(LOCK_HELPER, self.root / "scripts" / "guest" / "mesa_android.py")
        (self.root / "scripts" / "tool-versions.env").write_text(
            "CARGO_NDK_VERSION=3.5.4\n",
            encoding="utf-8",
        )
        (self.root / "ThirdParty").mkdir()
        (self.root / "ThirdParty" / "ThirdParty.lock.json").write_text(
            """
{
  "components": [
    {
      "name": "ndk",
      "group": "guest-mesa",
      "kind": "prebuilt",
      "version": "28.2.13676358 (r28c)",
      "url": "https://example.invalid/android-ndk.zip",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "ships": "tooling"
    }
  ]
}
""".strip()
            + "\n",
            encoding="utf-8",
        )
        (self.crate / "Cargo.toml").write_text("[package]\nname = \"apkrun_vsockd\"\n", encoding="utf-8")
        (self.crate / "Cargo.lock").write_text("# fake lock for the command harness\n", encoding="utf-8")
        (self.crate / "rust-toolchain.toml").write_text(
            '[toolchain]\nchannel = "1.88.0"\ntargets = ["aarch64-linux-android"]\n',
            encoding="utf-8",
        )
        (self.ndk / "source.properties").write_text(
            "Pkg.Revision = 28.2.13676358\n",
            encoding="utf-8",
        )
        self.cargo_log = self.root / "cargo.log"
        self._write_executable(
            self.fake_bin / "cargo",
            f"""#!{sys.executable}
import os
import pathlib
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_CARGO_LOG"], "a", encoding="utf-8") as output:
    output.write(" ".join(args) + "\\n")
if args == ["--version"]:
    print("cargo " + os.environ.get("FAKE_RUST_VERSION", "1.88.0") + " (fixture)")
elif args == ["ndk", "--version"]:
    print("cargo-ndk " + os.environ.get("FAKE_CARGO_NDK_VERSION", "3.5.4"))
elif args == ["ndk", "-t", "arm64-v8a", "build", "--locked", "--release"]:
    target = pathlib.Path(os.environ["CARGO_TARGET_DIR"])
    binary = target / "aarch64-linux-android" / "release" / "apkrun_vsockd"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(b"fixture-vsockd")
    binary.chmod(0o755)
else:
    raise SystemExit("unexpected cargo invocation: " + repr(args))
""",
        )
        self._write_executable(
            self.fake_bin / "rustc",
            f"""#!{sys.executable}
import os
import sys

if sys.argv[1:] != ["--version"]:
    raise SystemExit("unexpected rustc invocation: " + repr(sys.argv[1:]))
print("rustc " + os.environ.get("FAKE_RUST_VERSION", "1.88.0") + " (fixture)")
""",
        )
        self._write_executable(
            self.fake_bin / "uname",
            "#!/bin/sh\ncase \"$1\" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 1 ;; esac\n",
        )

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def _write_executable(path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_build(self, *arguments, **overrides):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
                "ANDROID_NDK_HOME": str(self.ndk),
                "ANDROID_HOME": "",
                "ANDROID_SDK_ROOT": "",
                "HOME": str(self.root / "home"),
                "FAKE_CARGO_LOG": str(self.cargo_log),
                "FAKE_CARGO_NDK_VERSION": "3.5.4",
                "FAKE_RUST_VERSION": "1.88.0",
            }
        )
        environment.update(overrides)
        return subprocess.run(
            ["bash", str(self.root / "scripts" / "build-vsockd.sh"), *arguments],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def cargo_calls(self):
        if not self.cargo_log.exists():
            return []
        return self.cargo_log.read_text(encoding="utf-8").splitlines()

    def test_build_stages_only_the_executable_at_the_product_path(self):
        marker = self.prebuilt / "keep.txt"
        marker.write_text("keep\n", encoding="utf-8")
        destination = self.prebuilt / "apkrun_vsockd"
        destination.write_bytes(b"old binary")

        result = self.run_build()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(destination.read_bytes(), b"fixture-vsockd")
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o755)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep\n")
        self.assertEqual(
            self.cargo_calls(),
            [
                "--version",
                "ndk --version",
                "ndk -t arm64-v8a build --locked --release",
            ],
        )
        self.assertEqual(
            {path.name for path in self.prebuilt.iterdir()},
            {"keep.txt", "apkrun_vsockd"},
        )

    def test_check_validates_pins_without_building_or_staging(self):
        result = self.run_build("--check")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Rust 1.88.0, cargo-ndk 3.5.4, NDK 28.2.13676358", result.stdout)
        self.assertEqual(self.cargo_calls(), ["--version", "ndk --version"])
        self.assertFalse((self.prebuilt / "apkrun_vsockd").exists())

    def test_wrong_cargo_ndk_pin_stops_before_build(self):
        result = self.run_build(FAKE_CARGO_NDK_VERSION="3.4.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected cargo-ndk 3.5.4", result.stderr)
        self.assertEqual(self.cargo_calls(), ["--version", "ndk --version"])
        self.assertFalse((self.prebuilt / "apkrun_vsockd").exists())

    def test_wrong_rust_pin_stops_before_build(self):
        result = self.run_build(FAKE_RUST_VERSION="1.89.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected Rust 1.88.0", result.stderr)
        self.assertEqual(self.cargo_calls(), [])
        self.assertFalse((self.prebuilt / "apkrun_vsockd").exists())

    def test_wrong_ndk_revision_stops_before_build(self):
        (self.ndk / "source.properties").write_text("Pkg.Revision = 29.0.0\n", encoding="utf-8")

        result = self.run_build()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NDK 28.2.13676358 not found", result.stderr)
        self.assertEqual(self.cargo_calls(), [])
        self.assertFalse((self.prebuilt / "apkrun_vsockd").exists())

    def test_dangling_destination_symlink_is_rejected_without_following_it(self):
        destination = self.prebuilt / "apkrun_vsockd"
        referent = self.root / "missing-referent"
        destination.symlink_to(referent)

        result = self.run_build()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace a symlink", result.stderr)
        self.assertEqual(self.cargo_calls(), [])
        self.assertFalse(referent.exists())
        self.assertTrue(destination.is_symlink())

    def test_stager_refuses_a_dangling_symlink_and_keeps_its_referent_absent(self):
        source = self.root / "built-apkrun-vsockd"
        source.write_bytes(b"fixture-vsockd")
        source.chmod(0o755)
        destination = self.prebuilt / "apkrun_vsockd"
        referent = self.root / "still-missing"
        destination.symlink_to(referent)

        result = subprocess.run(
            [
                sys.executable,
                str(self.root / "scripts" / "guest" / "stage_vsockd.py"),
                str(self.root),
                str(source),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-regular destination", result.stderr)
        self.assertTrue(destination.is_symlink())
        self.assertFalse(referent.exists())


if __name__ == "__main__":
    unittest.main()
