#!/usr/bin/env python3
"""Write Contents/Resources/components.json for a built APKRun.app.

Runs as the APKRun target's "Write Components" build phase (build-system.md
§5). All inputs come from Xcode build settings and the checked-in sources so
the manifest always matches the compiled constants:

  version        MARKETING_VERSION
  build          CURRENT_PROJECT_VERSION
  channel        APKRUN_CHANNEL ("stable" in release.yml, "dev" otherwise)
  commit         git rev-parse --short=7 HEAD (+ "-dirty" when the tree is dirty)
  runtimeAPI     APIVersion.current in RuntimeAPI/RuntimeAPI.swift
  guestProtocol  ProtocolVersion.host in GuestProtocol/ProtocolVersion.swift
  dataSchemas    DataSchemas.current in DiagnosticsCore/Build/ComponentManifest.swift
  agentPlistSHA256  SHA-256 of the generated LaunchAgent plist
  components     "version" of every shipped ThirdParty.lock.json entry plus
                 devGuestAgentVersionCode when Guest/build/out/apkrun-guest.json
                 exists
"""

import hashlib
import json
import os
import re
import subprocess
import sys


def fail(message: str) -> "None":
    print(f"write-components: {message}", file=sys.stderr)
    sys.exit(1)


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"missing build setting {name}")
    return value


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as error:
        fail(f"cannot read {path}: {error}")


def git_commit(srcroot: str) -> str:
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "--short=7", "HEAD"],
            cwd=srcroot, capture_output=True, text=True, check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=srcroot, capture_output=True, text=True, check=True,
        ).stdout.strip()
        return commit + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def version_pair(path: str, pattern: str, what: str) -> str:
    text = read(path)
    match = re.search(pattern, text)
    if not match:
        fail(f"cannot find {what} in {path}")
    return f"{match.group(1)}.{match.group(2)}"


def data_schemas(path: str) -> dict:
    text = read(path)
    block = re.search(r"let current: \[String: Int\] = \[(.*?)\]", text, re.S)
    if not block:
        fail(f"cannot find DataSchemas.current in {path}")
    return {
        key: int(value)
        for key, value in re.findall(r'"([^"]+)":\s*(\d+)', block.group(1))
    }


def lock_components(lock_path: str) -> dict:
    try:
        lock = json.loads(read(lock_path))
    except json.JSONDecodeError as error:
        fail(f"ThirdParty.lock.json is invalid: {error}")
    components = {}
    for entry in lock.get("components", []):
        if "version" in entry and "name" in entry:
            components[entry["name"]] = entry["version"]
    return components


def main() -> None:
    srcroot = require_env("SRCROOT")
    target_build_dir = require_env("TARGET_BUILD_DIR")
    wrapper_name = require_env("WRAPPER_NAME")
    version = require_env("MARKETING_VERSION")
    build = require_env("CURRENT_PROJECT_VERSION")
    channel = os.environ.get("APKRUN_CHANNEL", "dev").strip() or "dev"

    bundle = os.path.join(target_build_dir, wrapper_name)
    resources = os.path.join(bundle, "Contents", "Resources")
    if not os.path.isdir(resources):
        fail(f"built bundle has no Resources directory: {resources}")

    runtime_api = version_pair(
        os.path.join(srcroot, "Packages/RuntimeAPI/Sources/RuntimeAPI/RuntimeAPI.swift"),
        r"static let current = APIVersion\(major: (\d+), minor: (\d+)\)",
        "APIVersion.current",
    )
    guest_protocol = version_pair(
        os.path.join(srcroot, "Packages/GuestProtocol/Sources/GuestProtocol/ProtocolVersion.swift"),
        r"static let host = ProtocolVersion\(major: (\d+), minor: (\d+)\)",
        "ProtocolVersion.host",
    )
    schemas = data_schemas(
        os.path.join(
            srcroot,
            "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Build/ComponentManifest.swift",
        )
    )

    plist_file = os.environ.get("APKRUN_LAUNCH_AGENT_PLIST_FILE", "io.apkrun.apkrund.plist")
    plist_path = os.path.join(
        bundle, "Contents", "Library", "LaunchAgents", plist_file
    )
    if os.path.isfile(plist_path):
        with open(plist_path, "rb") as handle:
            agent_plist_sha = hashlib.sha256(handle.read()).hexdigest()
    else:
        agent_plist_sha = ""

    components = lock_components(
        os.path.join(srcroot, "ThirdParty", "ThirdParty.lock.json")
    )
    guest_json = os.path.join(resources, "guest", "apkrun-guest.json")
    if os.path.isfile(guest_json):
        try:
            guest = json.loads(read(guest_json))
            if "versionCode" in guest:
                components["devGuestAgentVersionCode"] = str(guest["versionCode"])
        except json.JSONDecodeError:
            pass

    manifest = {
        "version": version,
        "build": build,
        "channel": channel,
        "commit": git_commit(srcroot),
        "runtimeAPI": runtime_api,
        "guestProtocol": guest_protocol,
        "dataSchemas": schemas,
        "agentPlistSHA256": agent_plist_sha,
        "components": components,
    }
    output = os.path.join(resources, "components.json")
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"write-components: wrote {output}")


if __name__ == "__main__":
    main()
