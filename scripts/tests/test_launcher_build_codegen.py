#!/usr/bin/env python3
"""Tests for immutable launcher build-identity generation."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR_PATH = REPOSITORY_ROOT / "scripts/build/generate-launcher-build.py"
SPEC = importlib.util.spec_from_file_location("launcher_build_generator", GENERATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class LauncherBuildCodegenTests(unittest.TestCase):
    def render_default(self, api_source: str | None = None, configuration: str = "Debug") -> str:
        if api_source is None:
            api_source = GENERATOR.API_SOURCE.read_text(encoding="utf-8")
        return GENERATOR.render(
            configuration=configuration,
            identity="dev",
            team_identifier="",
            marketing_version="0.1.0",
            minimum_runtime_version="0.1.0",
            download_url="https://apkrun.io/apkrun/download/",
            api_source=api_source,
        )

    def test_checked_in_generated_file_matches_development_defaults(self) -> None:
        self.assertEqual(
            GENERATOR.OUTPUT_PATH.read_text(encoding="utf-8"),
            self.render_default(),
        )
        self.assertEqual(
            GENERATOR.output_path("Release").read_text(encoding="utf-8"),
            self.render_default(configuration="Release"),
        )

    def test_api_version_tracks_runtime_api_source(self) -> None:
        api_source = GENERATOR.API_SOURCE.read_text(encoding="utf-8").replace(
            "APIVersion(major: 1, minor: 18)",
            "APIVersion(major: 2, minor: 0)",
            1,
        )
        self.assertIn(
            "static let launcherAPI = APIVersion(major: 2, minor: 0)",
            self.render_default(api_source),
        )

    def test_build_configuration_and_environment_values_are_embedded_separately(self) -> None:
        source = GENERATOR.API_SOURCE.read_text(encoding="utf-8")
        release = GENERATOR.render(
            configuration="Release",
            identity="release",
            team_identifier="ABCDE12345",
            marketing_version="2.3.4",
            minimum_runtime_version="1.2.3",
            download_url="https://downloads.example.invalid/apkrun/",
            api_source=source,
        )
        self.assertTrue(release.startswith("#if APKRUN_LAUNCHER_RELEASE\n"))
        self.assertIn('static let version = "2.3.4"', release)
        self.assertIn("WrapperMinimumRuntimeVersion(rawValue: \"1.2.3\")", release)
        self.assertIn('static let downloadURL: URL = {', release)
        self.assertIn('guard let url = URL(string: "https://downloads.example.invalid/apkrun/")', release)
        self.assertIn('.release(teamIdentifier: "ABCDE12345")', release)
        self.assertIn('static let hostAppBundleIdentifier = "io.apkrun.APKRun"', release)
        self.assertNotEqual(GENERATOR.output_path("Debug"), GENERATOR.output_path("Release"))

    def test_release_requires_a_valid_team_identifier(self) -> None:
        with self.assertRaisesRegex(ValueError, "10-character DEVELOPMENT_TEAM"):
            GENERATOR.render(
                configuration="Release",
                identity="release",
                team_identifier="",
                marketing_version="0.1.0",
                minimum_runtime_version="0.1.0",
                download_url="https://apkrun.io/apkrun/download/",
                api_source=GENERATOR.API_SOURCE.read_text(encoding="utf-8"),
            )

    def test_rejects_non_https_download_urls(self) -> None:
        with self.assertRaisesRegex(ValueError, "HTTPS URL"):
            GENERATOR.render(
                identity="dev",
                team_identifier="",
                marketing_version="0.1.0",
                minimum_runtime_version="0.1.0",
                download_url="http://example.invalid/",
                api_source=GENERATOR.API_SOURCE.read_text(encoding="utf-8"),
            )

    def test_rejects_unknown_configuration(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported launcher build configuration"):
            GENERATOR.render(
                configuration="Production",
                identity="dev",
                team_identifier="",
                marketing_version="0.1.0",
                minimum_runtime_version="0.1.0",
                download_url="https://apkrun.io/apkrun/download/",
                api_source=GENERATOR.API_SOURCE.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
