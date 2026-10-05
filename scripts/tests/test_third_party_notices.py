#!/usr/bin/env python3
"""T0 coverage for offline third-party notices generation."""

import importlib.util
import json
import pathlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts/release/generate-notices.py"
SPEC = importlib.util.spec_from_file_location("generate_notices", MODULE_PATH)
notices = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notices)


class NoticeGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "ThirdParty/licenses/example").mkdir(parents=True)
        (self.root / "ThirdParty/licenses/reference").mkdir(parents=True)
        (self.root / "ThirdParty/licenses/derived").mkdir(parents=True)
        (self.root / "ThirdParty/licenses/example/LICENSE").write_text(
            "Copyright (c) Example & Company\nPermission is hereby granted.\n",
            encoding="utf-8",
        )
        (self.root / "ThirdParty/licenses/reference/LICENSE").write_text(
            "Reference license text.\n", encoding="utf-8"
        )
        (self.root / "ThirdParty/licenses/derived/LICENSE").write_text(
            "Copyright © Derived Authors\nDerived license text.\n", encoding="utf-8"
        )
        self.lock = {
            "components": [
                {
                    "name": "example",
                    "version": "1.0",
                    "repository": "https://example.invalid/repo?a=1&b=2",
                    "license": "MIT",
                    "licenseFiles": ["LICENSE"],
                    "ships": "app",
                },
                {
                    "name": "reference",
                    "version": "2.0",
                    "license": "MIT",
                    "licenseFiles": ["LICENSE"],
                    "ships": "reference",
                },
                {
                    "name": "derived",
                    "version": "3.0",
                    "license": "MIT",
                    "licenseFiles": ["LICENSE"],
                    "ships": ["derived"],
                    "derivedFiles": ["Sources/A.swift"],
                },
            ]
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_html_is_deterministic_self_contained_and_excludes_reference(self):
        first = notices.generate_html(self.root, self.lock)
        second = notices.generate_html(self.root, self.lock)
        self.assertEqual(first, second)
        self.assertIn("APKRun project license has not been selected", first)
        self.assertIn("Example &amp; Company", first)
        self.assertIn("https://example.invalid/repo?a=1&amp;b=2", first)
        self.assertIn("Sources/A.swift", first)
        self.assertNotIn("Reference license text", first)
        self.assertNotIn("<script", first)
        self.assertIn("<pre>", first)

    def test_shipped_lock_entries_have_committed_license_copies(self):
        lock = notices.read_lock(REPO_ROOT)
        records = notices.component_records(REPO_ROOT, lock)
        names = [component["name"] for component, _ in records]
        self.assertIn("virglrenderer", names)
        self.assertIn("libepoxy", names)
        self.assertIn("angle", names)
        self.assertNotIn("riftvm", names)

    def test_license_paths_reject_traversal_and_symlinks(self):
        component = self.lock["components"][0]
        component["licenseFiles"] = ["../outside"]
        with self.assertRaisesRegex(notices.NoticeFailure, "unsafe license path"):
            notices.license_paths(self.root, component)

        outside = self.root / "outside"
        outside.write_text("outside\n", encoding="utf-8")
        component["licenseFiles"] = ["redirect"]
        license_directory = self.root / "ThirdParty/licenses/example"
        (license_directory / "redirect").symlink_to(outside)
        with self.assertRaisesRegex(notices.NoticeFailure, "symlink"):
            notices.license_paths(self.root, component)


if __name__ == "__main__":
    unittest.main()
