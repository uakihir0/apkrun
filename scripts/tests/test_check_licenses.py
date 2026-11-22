#!/usr/bin/env python3
"""Tests for scripts/check-licenses.sh (legal-and-licensing.md §6.3, #94)."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SCRIPT = ROOT / "scripts/check-licenses.sh"


def run_check(root):
    return subprocess.run(
        ["bash", str(SCRIPT), str(root)], cwd=root,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def make_root(tmp):
    root = pathlib.Path(tmp)
    (root / "ThirdParty/licenses/demo").mkdir(parents=True)
    (root / "docs/05-development").mkdir(parents=True)
    shutil.copy(ROOT / "docs/05-development/legal-and-licensing.md",
                root / "docs/05-development/legal-and-licensing.md")
    shutil.copy(ROOT / "Package.resolved", root / "Package.resolved")
    return root


def write_lock(root, components):
    (root / "ThirdParty/ThirdParty.lock.json").write_text(
        json.dumps({"schemaVersion": 1, "components": components}), encoding="utf-8")


ENTRY = {
    "name": "demo", "kind": "source", "ships": "app",
    "license": "MIT", "licenseFiles": ["LICENSE"],
}


class CheckLicensesTests(unittest.TestCase):
    def test_real_lock_passes(self):
        result = run_check(ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_license_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            entry = dict(ENTRY, license="")
            write_lock(root, [entry])
            result = run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("demo", result.stderr)

    def test_disallowed_license_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            (root / "ThirdParty/licenses/demo/LICENSE").write_text("x")
            entry = dict(ENTRY, license="GPL-3.0-only")
            write_lock(root, [entry])
            result = run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not on the app list", result.stderr)

    def test_missing_committed_copy_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            write_lock(root, [dict(ENTRY)])
            result = run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing committed license copy", result.stderr)

    def test_or_and_precedence(self):
        # AND binds tighter than OR: `MIT OR GPL-3.0-only AND GPL-2.0-only`
        # allows MIT even though the GPL pair is not on the list.
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            (root / "ThirdParty/licenses/demo/LICENSE").write_text("x")
            (root / "Package.resolved").write_text('{"pins": []}')
            entry = dict(ENTRY, license="MIT OR GPL-3.0-only AND GPL-2.0-only")
            write_lock(root, [entry])
            result = run_check(root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_reference_entry_needs_identified_license(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            entry = dict(ENTRY, ships="reference", license="NOASSERTION")
            write_lock(root, [entry])
            result = run_check(root)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
