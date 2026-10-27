#!/usr/bin/env python3
"""Generate immutable launcher identity and compatibility constants."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import urllib.parse

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
API_SOURCE = REPOSITORY_ROOT / "Packages/RuntimeAPI/Sources/RuntimeAPI/RuntimeAPI.swift"
OUTPUT_DIRECTORY = REPOSITORY_ROOT / "Apps/APKRunLauncher"

CONFIGURATION_CONDITIONS = {
    "Debug": "APKRUN_LAUNCHER_DEBUG",
    "Release": "APKRUN_LAUNCHER_RELEASE",
}


def output_path(configuration: str) -> pathlib.Path:
    if configuration not in CONFIGURATION_CONDITIONS:
        raise ValueError(f"unsupported launcher build configuration: {configuration}")
    return OUTPUT_DIRECTORY / f"LauncherBuild.{configuration}.generated.swift"


OUTPUT_PATH = output_path("Debug")


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def valid_version(value: str, components: int) -> bool:
    parts = value.split(".")
    return (
        len(parts) == components
        and all(part.isdigit() and (len(part) == 1 or not part.startswith("0")) for part in parts)
        and len(value) <= 32
    )


def render(
    *,
    configuration: str = "Debug",
    identity: str,
    team_identifier: str,
    marketing_version: str,
    minimum_runtime_version: str,
    download_url: str,
    api_source: str,
) -> str:
    condition = CONFIGURATION_CONDITIONS.get(configuration)
    if condition is None:
        raise ValueError(f"unsupported launcher build configuration: {configuration}")
    if identity not in {"dev", "release", "updatetest"}:
        raise ValueError(f"unsupported build identity: {identity}")
    if not valid_version(marketing_version, 3):
        raise ValueError("marketing version must be MAJOR.MINOR.PATCH")
    if not valid_version(minimum_runtime_version, 3):
        raise ValueError("minimum runtime version must be MAJOR.MINOR.PATCH")
    if identity != "dev" and not re.fullmatch(r"[A-Z0-9]{10}", team_identifier):
        raise ValueError("release launcher builds require a 10-character DEVELOPMENT_TEAM")
    parsed_download_url = urllib.parse.urlsplit(download_url)
    if (
        parsed_download_url.scheme != "https"
        or not parsed_download_url.hostname
        or parsed_download_url.username is not None
        or parsed_download_url.password is not None
        or parsed_download_url.fragment
        or len(download_url) > 2048
    ):
        raise ValueError("download URL must be a bounded HTTPS URL with a host")

    version_match = re.search(
        r"public static let current = APIVersion\(major: ([0-9]+), minor: ([0-9]+)\)",
        api_source,
    )
    if version_match is None:
        raise ValueError("could not read APIVersion.current")
    api_major, api_minor = map(int, version_match.groups())
    if api_major < 1 or api_minor < 0:
        raise ValueError("RuntimeAPI.current is invalid")

    identity_expression = {
        "dev": ".development",
        "release": f".release(teamIdentifier: {swift_string(team_identifier)})",
        "updatetest": f".releaseUpdateTest(teamIdentifier: {swift_string(team_identifier)})",
    }[identity]
    host_identifier = {
        "dev": "io.apkrun.APKRun.dev",
        "release": "io.apkrun.APKRun",
        "updatetest": "io.apkrun.APKRun.updatetest",
    }[identity]
    source = "\n".join(
        [
            "import Foundation",
            "import RuntimeAPI",
            "import RuntimeClient",
            "",
            "enum LauncherBuild {",
            f"    static let version = {swift_string(marketing_version)}",
            f"    static let launcherAPI = APIVersion(major: {api_major}, minor: {api_minor})",
            "    static let minimumRuntimeVersion: WrapperMinimumRuntimeVersion = {",
            f"        guard let version = WrapperMinimumRuntimeVersion(rawValue: {swift_string(minimum_runtime_version)}) else {{",
            '            fatalError("Generated minimum runtime version is invalid.")',
            "        }",
            "        return version",
            "    }()",
            "    static let downloadURL: URL = {",
            f"        guard let url = URL(string: {swift_string(download_url)}) else {{",
            '            fatalError("Generated download URL is invalid.")',
            "        }",
            "        return url",
            "    }()",
            f"    static let hostAppBundleIdentifier = {swift_string(host_identifier)}",
            f"    static let daemonIdentity: RuntimeWrapperDaemonBuildIdentity = {identity_expression}",
            "}",
            "",
        ]
    )
    indented_source = "\n".join(f"    {line}" if line else "" for line in source.splitlines())
    return f"#if {condition}\n{indented_source}\n#endif\n"


def main() -> int:
    try:
        generated = render(
            configuration=os.environ.get("CONFIGURATION", "Debug"),
            identity=os.environ.get("APKRUN_BUILD_IDENTITY", "dev"),
            team_identifier=os.environ.get("DEVELOPMENT_TEAM", ""),
            marketing_version=os.environ.get("MARKETING_VERSION", "0.1.0"),
            minimum_runtime_version=os.environ.get("APKRUN_MINIMUM_RUNTIME_VERSION", "0.1.0"),
            download_url=os.environ.get(
                "APKRUN_DOWNLOADS_URL",
                "https://apkrun.io/apkrun/download/",
            ),
            api_source=API_SOURCE.read_text(encoding="utf-8"),
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(f"generate-launcher-build: {error}", file=sys.stderr)
        return 1

    output_path(os.environ.get("CONFIGURATION", "Debug")).write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
