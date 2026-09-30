#!/usr/bin/env python3
"""Tests for the TCC-safe Linux test artifact path validator."""

from __future__ import annotations

import os
import pwd
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

VALIDATOR = Path(__file__).resolve().parents[1] / "tools" / "validate-test-linux-dir.py"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class TestLinuxTestArtifactDirectory(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.home = Path(self.temporary_directory.name) / "home"
        self.home.mkdir()
        (self.home / "Documents").mkdir()

    def run_validator(self, value: Path | str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(value)],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )

    def test_accepts_and_resolves_an_absolute_path_outside_documents(self) -> None:
        directory = self.home / "temporary" / "linux-guest"

        result = self.run_validator(directory)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(directory.resolve()))

    def test_rejects_documents_without_creating_the_requested_directory(self) -> None:
        directory = self.home / "Documents" / "linux-guest"

        result = self.run_validator(directory)

        self.assertEqual(result.returncode, 64)
        self.assertIn("outside ~/Documents", result.stderr)
        self.assertFalse(directory.exists())

    def test_rejects_account_documents_when_home_is_overridden(self) -> None:
        """An environment HOME override cannot hide the actual account Documents."""
        account_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        directory = account_home / "Documents" / "apkrun-test-linux"

        result = self.run_validator(directory)

        self.assertEqual(result.returncode, 64)
        self.assertIn("outside ~/Documents", result.stderr)

    def test_rejects_a_symlink_that_resolves_into_documents(self) -> None:
        alias = self.home / "documents-alias"
        alias.symlink_to(self.home / "Documents", target_is_directory=True)

        result = self.run_validator(alias / "linux-guest")

        self.assertEqual(result.returncode, 64)
        self.assertIn("outside ~/Documents", result.stderr)

    def test_rejects_a_symlink_after_a_missing_component_and_parent_reference(self) -> None:
        alias = self.home / "documents-alias"
        alias.symlink_to(self.home / "Documents", target_is_directory=True)
        path = self.home / "missing" / ".." / "documents-alias" / "linux-guest"

        result = self.run_validator(path)

        self.assertEqual(result.returncode, 64)
        self.assertIn("outside ~/Documents", result.stderr)
        self.assertFalse((self.home / "Documents" / "linux-guest").exists())

    def test_rejects_a_relative_path(self) -> None:
        result = self.run_validator(Path("relative/artifacts"))

        self.assertEqual(result.returncode, 64)
        self.assertIn("absolute path", result.stderr)

    def test_artifact_scripts_refuse_documents_before_creating_files(self) -> None:
        directory = self.home / "Documents" / "linux-guest"
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        environment["APKRUN_TEST_LINUX_DIR"] = str(directory)

        for script_name in ("fetch-test-linux.sh", "build-test-initramfs.sh"):
            with self.subTest(script=script_name):
                result = subprocess.run(
                    [
                        "bash",
                        str(REPOSITORY_ROOT / "scripts" / script_name),
                    ],
                    check=False,
                    capture_output=True,
                    env=environment,
                    text=True,
                )

                self.assertEqual(result.returncode, 64)
                self.assertIn("outside ~/Documents", result.stderr)
                self.assertFalse(directory.exists())


if __name__ == "__main__":
    unittest.main()
