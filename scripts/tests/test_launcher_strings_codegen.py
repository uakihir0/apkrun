#!/usr/bin/env python3
"""Tests for the launcher string catalog generator."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import unittest

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR_PATH = REPOSITORY_ROOT / "scripts/build/generate-launcher-strings.py"
SPEC = importlib.util.spec_from_file_location("launcher_strings_generator", GENERATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class LauncherStringsCodegenTests(unittest.TestCase):
    def test_checked_in_generated_file_matches_catalog(self) -> None:
        catalog = json.loads(GENERATOR.CATALOG_PATH.read_text(encoding="utf-8"))
        self.assertEqual(GENERATOR.OUTPUT_PATH.read_text(encoding="utf-8"), GENERATOR.render(catalog))

    def test_generation_is_deterministic_and_escapes_swift_literals(self) -> None:
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": 'A "quote" and \\(value)'}},
                        "ja": {"stringUnit": {"state": "translated", "value": "日本語"}},
                    }
                }
            },
        }
        generated = GENERATOR.render(catalog)
        self.assertEqual(generated, GENERATOR.render(catalog))
        self.assertIn('"en", "ja"', generated)
        self.assertIn(r'A \"quote\" and \\(value)', generated)

    def test_source_language_is_required_for_every_key(self) -> None:
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "example": {
                    "localizations": {
                        "ja": {"stringUnit": {"state": "translated", "value": "日本語"}}
                    }
                }
            },
        }
        with self.assertRaisesRegex(ValueError, "source language en is missing"):
            GENERATOR.render(catalog)


if __name__ == "__main__":
    unittest.main(verbosity=2)
