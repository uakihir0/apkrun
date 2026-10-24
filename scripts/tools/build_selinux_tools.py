#!/usr/bin/env python3
"""Build the pinned CIL-enabled secilc host tool for Apple silicon macOS."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from typing import Any, Mapping, Sequence


COMPONENT = "selinux-cil"
FLEX_COMPONENT = "flex"
M4_COMPONENT = "m4"
OUTPUT_NAME = "secilc"
SCHEMA_VERSION = 1
MINIMUM_MACOS = "27.0"
EXPECTED_SOURCE = {
    "repository": "https://github.com/SELinuxProject/selinux",
    "commit": "2233a23a4d4f1bf29054037babec13f30d038e65",
    "version": "3.11",
}
EXPECTED_TOOLS = {
    "flex": {
        "version": "2.6.4",
        "url": "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz",
        "sha256": "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995",
    },
    "m4": {
        "version": "1.4.20",
        "url": "https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz",
        "sha256": "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b",
    },
}
EXPECTED_BUILD_FLAGS = [
    "libsepol.DISABLE_CIL=n",
    "libsepol.DISABLE_SHARED=y",
    "secilc.target=secilc",
]
BUILD_INPUTS = (
    "scripts/build-selinux-tools.sh",
    "scripts/tools/build_selinux_tools.py",
)


class BuildFailure(RuntimeError):
    """A missing, unsafe, or unverifiable input to the pinned host build."""


def run(
    arguments: Sequence[str],
    *,
    cwd: pathlib.Path | None = None,
    env: Mapping[str, str] | None = None,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            list(arguments),
            cwd=str(cwd) if cwd else None,
            env=dict(env) if env is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except OSError as error:
        raise BuildFailure(f"could not run {arguments[0]}: {error}") from None
    if result.returncode and not allow_failure:
        raise BuildFailure(
            f"command failed ({result.returncode}): {' '.join(arguments)}\n"
            f"{result.stdout[-12000:]}"
        )
    return result


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def read_lock(root: pathlib.Path) -> dict[str, Any]:
    path = root / "ThirdParty/ThirdParty.lock.json"
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BuildFailure(f"{path}: {error}") from None
    if not isinstance(lock, dict) or not isinstance(lock.get("components"), list):
        raise BuildFailure(f"{path}: expected a components array")
    return lock


def lock_component(lock: Mapping[str, Any], name: str) -> dict[str, Any]:
    matches = [
        item
        for item in lock["components"]
        if isinstance(item, dict) and item.get("name") == name
    ]
    if len(matches) != 1:
        raise BuildFailure(f"ThirdParty.lock.json must contain exactly one {name} entry")
    return matches[0]


def validate_lock(root: pathlib.Path) -> dict[str, dict[str, Any]]:
    lock = read_lock(root)
    source = lock_component(lock, COMPONENT)
    if (
        source.get("group") != "image-tooling"
        or source.get("kind") != "source"
        or source.get("repository") != EXPECTED_SOURCE["repository"]
        or source.get("commit") != EXPECTED_SOURCE["commit"]
        or source.get("version") != EXPECTED_SOURCE["version"]
        or source.get("ships") != "tooling"
        or source.get("buildFlags") != EXPECTED_BUILD_FLAGS
    ):
        raise BuildFailure(f"lock entry {COMPONENT} differs from the reviewed CIL build pin")
    for field in ("license", "licenseFiles", "patches"):
        if field not in source:
            raise BuildFailure(f"lock entry {COMPONENT} is missing {field}")
    if source["patches"]:
        raise BuildFailure(f"lock entry {COMPONENT} unexpectedly declares patches")
    licenses = root / "ThirdParty/licenses" / COMPONENT
    for license_file in source["licenseFiles"]:
        if not isinstance(license_file, str) or not license_file:
            raise BuildFailure(f"lock entry {COMPONENT} has an invalid license path")
        path = licenses / license_file
        if path.is_symlink() or not path.is_file():
            raise BuildFailure(f"missing or unsafe license file: {path}")

    tools: dict[str, dict[str, Any]] = {}
    for name, expected in EXPECTED_TOOLS.items():
        entry = lock_component(lock, name)
        if (
            entry.get("kind") != "prebuilt"
            or entry.get("version") != expected["version"]
            or entry.get("url") != expected["url"]
            or entry.get("sha256") != expected["sha256"]
        ):
            raise BuildFailure(f"lock entry {name} differs from the reviewed tool source pin")
        tools[name] = entry
    return {COMPONENT: source, **tools}


def sanitized_git_environment() -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    return env


def git_output(path: pathlib.Path, *arguments: str) -> str:
    return run(
        ["git", "-C", str(path), *arguments],
        env=sanitized_git_environment(),
    ).stdout.strip()


def validate_clean_checkout(path: pathlib.Path, commit: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise BuildFailure(f"pinned SELinux checkout is missing or unsafe: {path}")
    if git_output(path, "rev-parse", "--verify", "HEAD^{commit}") != commit:
        raise BuildFailure(f"{path} is not at pinned commit {commit}")
    status = git_output(path, "status", "--porcelain", "--untracked-files=all", "--ignored")
    if status:
        raise BuildFailure(f"{path} is not clean, including ignored files")


def fetch_source(root: pathlib.Path, component: Mapping[str, Any]) -> pathlib.Path:
    name = component["name"]
    commit = component["commit"]
    destination = root / "ThirdParty/out/src" / name / commit
    if destination.exists():
        validate_clean_checkout(destination, commit)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{name}-fetch-", dir=str(destination.parent))
    )
    try:
        staging.rmdir()
        run(["git", "init", "--quiet", str(staging)], env=sanitized_git_environment())
        run(
            ["git", "-C", str(staging), "remote", "add", "origin", component["repository"]],
            env=sanitized_git_environment(),
        )
        run(
            [
                "git",
                "-C",
                str(staging),
                "fetch",
                "--depth=1",
                "--no-tags",
                "origin",
                commit,
            ],
            env=sanitized_git_environment(),
        )
        run(
            ["git", "-C", str(staging), "checkout", "--quiet", "--detach", "FETCH_HEAD"],
            env=sanitized_git_environment(),
        )
        validate_clean_checkout(staging, commit)
        try:
            os.rename(staging, destination)
        except FileExistsError:
            validate_clean_checkout(destination, commit)
            shutil.rmtree(staging)
        return destination
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def executable_identity(name: str, arguments: Sequence[str]) -> dict[str, str]:
    path = shutil.which(name)
    if not path:
        raise BuildFailure(f"required host tool is unavailable: {name}")
    resolved = pathlib.Path(path).resolve()
    output = run([str(resolved), *arguments]).stdout.strip()
    if not output:
        raise BuildFailure(f"{name} returned no version information")
    return {"path": str(resolved), "version": output, "sha256": sha256_file(resolved)}


def file_identity(path: str) -> dict[str, str]:
    resolved = pathlib.Path(path).resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise BuildFailure(f"required host tool is unavailable: {path}")
    return {
        "path": str(resolved),
        "version": "fingerprinted by SHA-256",
        "sha256": sha256_file(resolved),
    }


def xcrun_path(*arguments: str) -> str:
    value = run(["xcrun", *arguments]).stdout.strip()
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_file():
        raise BuildFailure(f"xcrun returned an invalid tool path: {value}")
    # Keep the tool's selected name: on Darwin ranlib is a symlink to libtool, and its
    # behavior depends on argv[0].
    return str(path)


def environment_fingerprint() -> dict[str, Any]:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise BuildFailure("secilc builds require Apple silicon macOS")
    if sys.version_info[:2] != (3, 12):
        raise BuildFailure("run this build with Python 3.12")
    clang = xcrun_path("--find", "clang")
    ar = xcrun_path("--find", "ar")
    ranlib = xcrun_path("--find", "ranlib")
    sdk_path = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    if not sdk_path or not pathlib.Path(sdk_path).is_dir():
        raise BuildFailure(f"xcrun returned an invalid macOS SDK path: {sdk_path}")
    return {
        "hostArchitecture": platform.machine(),
        "macOSBuild": run(["sw_vers", "-buildVersion"]).stdout.strip(),
        "xcode": run(["xcodebuild", "-version"]).stdout.strip(),
        "sdkVersion": run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip(),
        "sdkPath": str(pathlib.Path(sdk_path).resolve()),
        "clang": {
            "path": clang,
            "version": run([clang, "--version"]).stdout.splitlines()[0],
            "sha256": sha256_file(pathlib.Path(clang)),
        },
        "ar": ar,
        "ranlib": ranlib,
        "git": executable_identity("git", ["--version"]),
        "make": executable_identity("make", ["--version"]),
        "curl": executable_identity("curl", ["--version"]),
        "lipo": file_identity(xcrun_path("--find", "lipo")),
        "otool": executable_identity("otool", ["--version"]),
        "deploymentTarget": MINIMUM_MACOS,
    }


def environment_hash(environment: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(environment)).hexdigest()


def lock_input_hash(components: Mapping[str, Mapping[str, Any]], root: pathlib.Path) -> str:
    records: list[bytes] = [canonical_json(dict(components))]
    for relative in BUILD_INPUTS:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise BuildFailure(f"missing or unsafe build input: {path}")
        records.extend((relative.encode("utf-8"), path.read_bytes()))
    digest = hashlib.sha256()
    for record in records:
        digest.update(len(record).to_bytes(8, "big"))
        digest.update(record)
    return digest.hexdigest()


def cache_key(
    root: pathlib.Path,
    components: Mapping[str, Mapping[str, Any]],
    environment: Mapping[str, Any],
) -> str:
    return f"{lock_input_hash(components, root)}-{environment_hash(environment)}"


def fetch_archive(url: str, expected_sha256: str, destination: pathlib.Path) -> pathlib.Path:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise BuildFailure(f"untrusted archive URL: {url}")
    if destination.is_symlink():
        raise BuildFailure(f"refusing symlinked archive path: {destination}")
    if destination.is_file() and sha256_file(destination) == expected_sha256:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{destination.name}.part-", dir=str(destination.parent)
    ) as staging_directory:
        temporary = pathlib.Path(staging_directory) / destination.name
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "APKRun image tooling"})
            with temporary.open("xb") as output:
                with urllib.request.urlopen(request, timeout=45) as response:
                    if response.status != 200:
                        raise BuildFailure(f"archive download returned HTTP {response.status}: {url}")
                    shutil.copyfileobj(response, output)
            if sha256_file(temporary) != expected_sha256:
                raise BuildFailure(f"downloaded archive SHA-256 differs from the lock: {url}")
            os.replace(temporary, destination)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise BuildFailure(f"could not download pinned archive {url}: {error}") from None
    return destination


def safe_extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    if destination.is_symlink():
        raise BuildFailure(f"refusing symlinked extraction directory: {destination}")
    if destination.exists() and not destination.is_dir():
        raise BuildFailure(f"refusing non-directory extraction path: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive, "r:*") as bundle:
            members = bundle.getmembers()
            for member in members:
                path = pathlib.PurePosixPath(member.name)
                if (
                    path.is_absolute()
                    or not path.parts
                    or any(part in ("", ".", "..") for part in path.parts)
                ):
                    raise BuildFailure(f"unsafe path in pinned archive: {member.name}")
            if hasattr(tarfile, "data_filter"):
                bundle.extractall(destination, members=members, filter="data")
            else:
                bundle.extractall(destination, members=members)
    except (OSError, tarfile.TarError) as error:
        raise BuildFailure(f"could not unpack {archive}: {error}") from None


def tool_cache_matches(
    binary: pathlib.Path,
    stamp: pathlib.Path,
    source_sha256: str,
    expected_version: str,
    dependency_sha256: str,
) -> bool:
    if binary.is_symlink() or not binary.is_file() or stamp.is_symlink() or not stamp.is_file():
        return False
    try:
        version = run([str(binary), "--version"]).stdout.splitlines()[0]
        record = json.loads(stamp.read_text(encoding="utf-8"))
    except (OSError, ValueError, IndexError, BuildFailure):
        return False
    return (
        version == expected_version
        and record
        == {
            "archiveSha256": source_sha256,
            "binarySha256": sha256_file(binary),
            "dependencySha256": dependency_sha256,
            "version": expected_version,
        }
    )


def write_tool_stamp(
    binary: pathlib.Path,
    stamp: pathlib.Path,
    source_sha256: str,
    version: str,
    dependency_sha256: str,
) -> None:
    record = {
        "archiveSha256": source_sha256,
        "binarySha256": sha256_file(binary),
        "dependencySha256": dependency_sha256,
        "version": version,
    }
    temporary = stamp.with_name(stamp.name + f".tmp-{os.getpid()}")
    temporary.write_bytes(canonical_json(record) + b"\n")
    os.replace(temporary, stamp)


def private_directory(parent: pathlib.Path, prefix: str) -> pathlib.Path:
    if parent.is_symlink():
        raise BuildFailure(f"refusing symlinked temporary directory parent: {parent}")
    if parent.exists() and not parent.is_dir():
        raise BuildFailure(f"temporary directory parent is not a directory: {parent}")
    parent.mkdir(parents=True, exist_ok=True)
    try:
        return pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=str(parent)))
    except OSError as error:
        raise BuildFailure(f"could not create private build directory under {parent}: {error}") from None


def tool_cache_paths(
    tools_root: pathlib.Path, name: str
) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    if tools_root.is_symlink():
        raise BuildFailure(f"refusing symlinked pinned tool cache: {tools_root}")
    if tools_root.exists() and not tools_root.is_dir():
        raise BuildFailure(f"pinned tool cache is not a directory: {tools_root}")
    tools_root.mkdir(parents=True, exist_ok=True)
    prefix = tools_root / name
    if prefix.is_symlink():
        raise BuildFailure(f"refusing symlinked tool prefix: {prefix}")
    if prefix.exists() and not prefix.is_dir():
        raise BuildFailure(f"pinned tool prefix is not a directory: {prefix}")
    binary_dir = prefix / "bin"
    if binary_dir.is_symlink():
        raise BuildFailure(f"refusing symlinked tool binary directory: {binary_dir}")
    binary = binary_dir / name
    stamp = prefix / ".apkrun-source-pin.json"
    if binary.is_symlink() or stamp.is_symlink():
        raise BuildFailure(f"refusing symlinked pinned tool cache file: {prefix}")
    return prefix, binary, stamp


def publish_tool_cache(staging: pathlib.Path, prefix: pathlib.Path, tools_root: pathlib.Path, name: str):
    if prefix.is_symlink():
        raise BuildFailure(f"refusing symlinked tool prefix: {prefix}")
    quarantine: pathlib.Path | None = None
    backup: pathlib.Path | None = None
    if prefix.exists():
        if not prefix.is_dir():
            raise BuildFailure(f"pinned tool prefix is not a directory: {prefix}")
        quarantine = private_directory(tools_root, f".{name}-old-")
        backup = quarantine / "previous"
        os.rename(prefix, backup)
    try:
        os.rename(staging, prefix)
    except Exception:
        if backup is not None and backup.exists() and not prefix.exists():
            os.rename(backup, prefix)
            backup = None
        if quarantine is not None and quarantine.exists() and backup is None:
            shutil.rmtree(quarantine)
        raise
    if quarantine is not None and quarantine.exists():
        shutil.rmtree(quarantine)


def build_pinned_tool(
    *,
    name: str,
    version: str,
    expected_sha256: str,
    url: str,
    archive: pathlib.Path,
    tools_root: pathlib.Path,
    build_root: pathlib.Path,
    jobs: int,
    m4_binary: pathlib.Path | None = None,
    dependency_sha256: str = "none",
) -> pathlib.Path:
    expected_version = f"{'m4 (GNU M4)' if name == 'm4' else 'flex'} {version}"
    prefix, binary, stamp = tool_cache_paths(tools_root, name)
    if tool_cache_matches(binary, stamp, expected_sha256, expected_version, dependency_sha256):
        return binary

    if build_root.is_symlink() or not build_root.is_dir():
        raise BuildFailure(f"refusing missing or symlinked build directory: {build_root}")
    source_area = private_directory(build_root, f".{name}-source-")
    install_area = private_directory(build_root, f".{name}-install-")
    safe_extract(archive, source_area)
    source = source_area / f"{name}-{version}"
    if source.is_symlink() or not source.is_dir():
        raise BuildFailure(f"pinned {name} archive has no {source.name} directory")
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["ZERO_AR_DATE"] = "1"
    if name == "flex":
        if m4_binary is None or not m4_binary.is_file():
            raise BuildFailure("pinned m4 must be built before Flex")
        environment["PATH"] = str(m4_binary.parent) + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["M4"] = str(m4_binary)

    log = build_root / f"{name}.log"
    if log.is_symlink():
        raise BuildFailure(f"refusing symlinked build log: {log}")
    command = ["./configure", f"--prefix={install_area}"]
    try:
        configured = subprocess.run(
            command,
            cwd=str(source),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        compiled = (
            subprocess.run(
                ["make", f"-j{jobs}"],
                cwd=str(source),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if configured.returncode == 0
            else None
        )
        installed = (
            subprocess.run(
                ["make", "install"],
                cwd=str(source),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if compiled is not None and compiled.returncode == 0
            else None
        )
    except OSError as error:
        raise BuildFailure(f"could not build pinned {name}: {error}") from None
    output = configured.stdout
    if compiled is not None:
        output += compiled.stdout
    if installed is not None:
        output += installed.stdout
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(output, encoding="utf-8")
    result = installed or compiled or configured
    if result.returncode:
        raise BuildFailure(f"pinned {name} build failed; see {log}")
    installed_binary = install_area / "bin" / name
    if not installed_binary.is_file() or installed_binary.is_symlink():
        raise BuildFailure(f"pinned {name} build did not produce {installed_binary}")
    actual_version = run([str(installed_binary), "--version"]).stdout.splitlines()[0]
    if actual_version != expected_version:
        raise BuildFailure(f"pinned {name} expected {expected_version}, found {actual_version}")
    staging = private_directory(tools_root, f".{name}-cache-")
    try:
        staged_bin = staging / "bin"
        staged_bin.mkdir()
        staged_binary = staged_bin / name
        shutil.copy2(installed_binary, staged_binary)
        staged_binary.chmod(0o755)
        staged_stamp = staging / ".apkrun-source-pin.json"
        write_tool_stamp(
            staged_binary, staged_stamp, expected_sha256, expected_version, dependency_sha256
        )
        if not tool_cache_matches(
            staged_binary, staged_stamp, expected_sha256, expected_version, dependency_sha256
        ):
            raise BuildFailure(f"pinned {name} staging cache failed its post-build check")
        publish_tool_cache(staging, prefix, tools_root, name)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        if source_area.exists():
            shutil.rmtree(source_area)
        if install_area.exists():
            shutil.rmtree(install_area)
    _, binary, stamp = tool_cache_paths(tools_root, name)
    if not tool_cache_matches(binary, stamp, expected_sha256, expected_version, dependency_sha256):
        raise BuildFailure(f"pinned {name} cache failed its post-build check")
    return binary


def safe_rmtree(path: pathlib.Path) -> None:
    if path.is_symlink():
        raise BuildFailure(f"refusing to remove symlink: {path}")
    if path.exists():
        shutil.rmtree(path)


@contextlib.contextmanager
def build_lock(path: pathlib.Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise BuildFailure(f"refusing symlinked build lock: {path}")
    with path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def verify_binary(
    binary: pathlib.Path,
    *,
    source: pathlib.Path,
    lipo: str,
    otool: str,
) -> None:
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise BuildFailure(f"secilc is missing, non-executable, or symlinked: {binary}")
    arches = run([lipo, "-archs", str(binary)]).stdout.strip().split()
    if arches != ["arm64"]:
        raise BuildFailure(f"secilc must contain only arm64 code; found {arches}")
    linked_lines = run([otool, "-L", str(binary)]).stdout.splitlines()
    # otool includes the inspected binary's own path as the first line; only its dependencies
    # may be the platform's system library. Keep the allowlist exact so Homebrew or build-tree
    # dylibs cannot silently become runtime requirements.
    dependencies = [
        line.strip().split()[0]
        for line in linked_lines[1:]
        if line.strip()
    ]
    if dependencies != ["/usr/lib/libSystem.B.dylib"]:
        raise BuildFailure(f"secilc has unexpected dynamic dependencies: {dependencies}")
    help_result = run([str(binary), "--help"], allow_failure=True)
    if help_result.returncode != 1 or "Usage:" not in help_result.stdout:
        raise BuildFailure("secilc help probe failed")
    with tempfile.TemporaryDirectory(prefix="apkrun-secilc-smoke-") as temporary:
        smoke = pathlib.Path(temporary)
        policy = source / "secilc/test/policy.cil"
        if policy.is_symlink() or not policy.is_file():
            raise BuildFailure("pinned SELinux source is missing secilc/test/policy.cil")
        run(
            [
                str(binary),
                "--output",
                str(smoke / "policy.bin"),
                "--filecontexts",
                str(smoke / "file_contexts"),
                str(policy),
            ]
        )
        if not (smoke / "policy.bin").is_file() or not (smoke / "file_contexts").is_file():
            raise BuildFailure("secilc did not produce its smoke-test outputs")


def prepare_cil_header_overlay(build_root: pathlib.Path, source: pathlib.Path) -> pathlib.Path:
    """Expose SELinux's CIL public header under the secilc source's installed-header path."""
    cil_header = source / "libsepol/cil/include/cil/cil.h"
    if cil_header.is_symlink() or not cil_header.is_file():
        raise BuildFailure(f"pinned SELinux source is missing its CIL public header: {cil_header}")
    include_root = build_root / "include-overlay"
    destination = include_root / "sepol/cil/cil.h"
    if any(
        path.is_symlink()
        for path in (include_root, include_root / "sepol", include_root / "sepol/cil")
    ):
        raise BuildFailure(f"refusing unsafe CIL include overlay: {destination}")
    if destination.is_symlink():
        if destination.resolve() != cil_header.resolve():
            raise BuildFailure(f"CIL include overlay points outside the pinned source: {destination}")
        return include_root
    if destination.exists():
        raise BuildFailure(f"refusing existing non-symlink CIL include overlay: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(cil_header)
    return include_root


def read_manifest(path: pathlib.Path) -> dict[str, Any] | None:
    manifest_path = path / "build-manifest.json"
    if path.is_symlink() or not path.is_dir() or manifest_path.is_symlink():
        return None
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def output_matches(
    path: pathlib.Path,
    key: str,
    components: Mapping[str, Any],
    environment: Mapping[str, Any],
) -> bool:
    manifest = read_manifest(path)
    binary = path / "bin" / OUTPUT_NAME
    if manifest is None or binary.is_symlink() or not binary.is_file():
        return False
    expected = {
        "schemaVersion": SCHEMA_VERSION,
        "component": COMPONENT,
        "version": EXPECTED_SOURCE["version"],
        "sourceCommit": EXPECTED_SOURCE["commit"],
        "cacheKey": key,
        "sourceLock": dict(components[COMPONENT]),
        "toolArchives": {
            FLEX_COMPONENT: components[FLEX_COMPONENT]["sha256"],
            M4_COMPONENT: components[M4_COMPONENT]["sha256"],
        },
        "environment": dict(environment),
    }
    return all(manifest.get(field) == value for field, value in expected.items()) and (
        manifest.get("outputs") == {OUTPUT_NAME: sha256_file(binary)}
    )


def build(
    root: pathlib.Path,
    output_root: pathlib.Path,
    work_root: pathlib.Path,
    jobs: int,
    force: bool,
) -> pathlib.Path:
    if jobs < 1 or jobs > 128:
        raise BuildFailure("--jobs must be from 1 to 128")
    components = validate_lock(root)
    environment = environment_fingerprint()
    key = cache_key(root, components, environment)
    destination = output_root / key
    source_component = components[COMPONENT]

    with build_lock(root / "ThirdParty/out/locks/selinux-tools.lock"):
        if not force and output_matches(destination, key, components, environment):
            source = root / "ThirdParty/out/src" / COMPONENT / source_component["commit"]
            validate_clean_checkout(source, source_component["commit"])
            verify_binary(
                destination / "bin" / OUTPUT_NAME,
                source=source,
                lipo=environmental_tool(environment, "lipo"),
                otool=environmental_tool(environment, "otool"),
            )
            print(f"build-selinux-tools: verified cache at {destination}")
            return destination

        out_base = root / "ThirdParty/out"
        out_base.mkdir(parents=True, exist_ok=True)
        source = fetch_source(root, source_component)
        cache_dir = work_root / "cache"
        downloads = cache_dir / "downloads"
        tool_root = cache_dir / "tools"
        build_root = work_root / f"build-{key[:16]}"
        for path in (cache_dir, downloads, tool_root, build_root):
            if path.is_symlink():
                raise BuildFailure(f"refusing symlinked build directory: {path}")
            path.mkdir(parents=True, exist_ok=True)

        m4_component = components[M4_COMPONENT]
        flex_component = components[FLEX_COMPONENT]
        m4_archive = fetch_archive(
            m4_component["url"],
            m4_component["sha256"],
            downloads / f"m4-{m4_component['version']}.tar.xz",
        )
        flex_archive = fetch_archive(
            flex_component["url"],
            flex_component["sha256"],
            downloads / f"flex-{flex_component['version']}.tar.gz",
        )
        m4_binary = build_pinned_tool(
            name=M4_COMPONENT,
            version=m4_component["version"],
            expected_sha256=m4_component["sha256"],
            url=m4_component["url"],
            archive=m4_archive,
            tools_root=tool_root,
            build_root=build_root,
            jobs=jobs,
        )
        m4_digest = sha256_file(m4_binary)
        flex_binary = build_pinned_tool(
            name=FLEX_COMPONENT,
            version=flex_component["version"],
            expected_sha256=flex_component["sha256"],
            url=flex_component["url"],
            archive=flex_archive,
            tools_root=tool_root,
            build_root=build_root,
            jobs=jobs,
            m4_binary=m4_binary,
            dependency_sha256=m4_digest,
        )

        work_checkout = build_root / "selinux"
        safe_rmtree(work_checkout)
        run(
            [
                "git",
                "clone",
                "--shared",
                "--quiet",
                "--no-checkout",
                str(source),
                str(work_checkout),
            ],
            env=sanitized_git_environment(),
        )
        run(
            [
                "git",
                "-C",
                str(work_checkout),
                "checkout",
                "--quiet",
                "--detach",
                source_component["commit"],
            ],
            env=sanitized_git_environment(),
        )
        if git_output(work_checkout, "rev-parse", "HEAD") != source_component["commit"]:
            raise BuildFailure("build checkout differs from the locked SELinux source")

        flags = set(source_component["buildFlags"])
        if flags != set(EXPECTED_BUILD_FLAGS):
            raise BuildFailure("SELinux CIL build flags differ from the reviewed configuration")
        cc = environment["clang"]["path"]
        ar = environment["ar"]
        ranlib = environment["ranlib"]
        build_env = os.environ.copy()
        build_env["PATH"] = os.pathsep.join(
            [str(flex_binary.parent), str(m4_binary.parent), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        )
        build_env["LC_ALL"] = "C"
        build_env["ZERO_AR_DATE"] = "1"
        build_env["SDKROOT"] = environment["sdkPath"]
        common_cflags = (
            f"-O2 -arch arm64 -isysroot {environment['sdkPath']} "
            f"-mmacosx-version-min={MINIMUM_MACOS}"
        )
        libsepol = work_checkout / "libsepol"
        make_args = [
            "make",
            f"-j{jobs}",
            f"CC={cc}",
            f"AR={ar}",
            f"RANLIB={ranlib}",
            f"LEX={flex_binary}",
            f"CFLAGS={common_cflags}",
            "DISABLE_CIL=n",
        ]
        run(
            [*make_args, "DISABLE_SHARED=y", "-C", str(libsepol / "src")],
            env=build_env,
        )
        archive = libsepol / "src/libsepol.a"
        if archive.is_symlink() or not archive.is_file() or archive.stat().st_size == 0:
            raise BuildFailure("CIL-enabled static libsepol was not produced")

        secilc_dir = work_checkout / "secilc"
        cil_header_overlay = prepare_cil_header_overlay(build_root, work_checkout)
        run(
            [
                "make",
                "-j1",
                f"CC={cc}",
                f"CPPFLAGS=-I{cil_header_overlay} -I{libsepol / 'include'}",
                f"LDFLAGS=-L{libsepol / 'src'} -arch arm64 -isysroot {environment['sdkPath']} "
                f"-mmacosx-version-min={MINIMUM_MACOS}",
                f"CFLAGS={common_cflags}",
                "-C",
                str(secilc_dir),
                "secilc",
            ],
            env=build_env,
        )
        built_binary = secilc_dir / OUTPUT_NAME
        verify_binary(
            built_binary,
            source=work_checkout,
            lipo=environmental_tool(environment, "lipo"),
            otool=environmental_tool(environment, "otool"),
        )

        output_root.mkdir(parents=True, exist_ok=True)
        staging = pathlib.Path(
            tempfile.mkdtemp(prefix=f".{key[:16]}-staging-", dir=str(output_root))
        )
        try:
            (staging / "bin").mkdir()
            staged_binary = staging / "bin" / OUTPUT_NAME
            shutil.copy2(built_binary, staged_binary)
            staged_binary.chmod(0o755)
            manifest = {
                "schemaVersion": SCHEMA_VERSION,
                "component": COMPONENT,
                "version": source_component["version"],
                "sourceCommit": source_component["commit"],
                "cacheKey": key,
                "sourceLock": source_component,
                "toolArchives": {
                    "flex": flex_component["sha256"],
                    "m4": m4_component["sha256"],
                },
                "environment": environment,
                "outputs": {OUTPUT_NAME: sha256_file(staged_binary)},
            }
            (staging / "build-manifest.json").write_bytes(canonical_json(manifest) + b"\n")
            if not output_matches(staging, key, components, environment):
                raise BuildFailure("staged secilc output failed manifest validation")
            verify_binary(
                staged_binary,
                source=work_checkout,
                lipo=environmental_tool(environment, "lipo"),
                otool=environmental_tool(environment, "otool"),
            )
            quarantine: pathlib.Path | None = None
            if destination.exists():
                if destination.is_symlink() or not destination.is_dir():
                    raise BuildFailure(f"refusing to replace unsafe output: {destination}")
                quarantine = output_root / f".invalid-{key[:16]}-{os.getpid()}"
                os.rename(destination, quarantine)
            try:
                os.rename(staging, destination)
            except Exception:
                if quarantine is not None and quarantine.exists():
                    os.rename(quarantine, destination)
                    quarantine = None
                raise
            if quarantine is not None:
                shutil.rmtree(quarantine)
        except Exception:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
            raise
        verify_binary(
            destination / "bin" / OUTPUT_NAME,
            source=work_checkout,
            lipo=environmental_tool(environment, "lipo"),
            otool=environmental_tool(environment, "otool"),
        )
        safe_rmtree(build_root)
        print(f"build-selinux-tools: built and verified {destination}")
        return destination


def environmental_tool(environment: Mapping[str, Any], name: str) -> str:
    identity = environment.get(name)
    if not isinstance(identity, dict) or not isinstance(identity.get("path"), str):
        raise BuildFailure(f"build environment has no {name} identity")
    return identity["path"]


def check(root: pathlib.Path) -> None:
    components = validate_lock(root)
    environment = environment_fingerprint()
    for tool in ("git", "make", "curl", "lipo", "otool"):
        if not environment.get(tool):
            raise BuildFailure(f"build environment is missing {tool}")
    print(
        "check: Apple silicon macOS, Python 3.12, "
        f"SELinux {components[COMPONENT]['version']} at {components[COMPONENT]['commit']}"
    )
    print(
        f"check: pinned flex {components[FLEX_COMPONENT]['version']}, "
        f"m4 {components[M4_COMPONENT]['version']}, CIL enabled, static libsepol"
    )
    print(f"check: clang {environment['clang']['version']}")
    print("check: passed (no download, build, or output changes)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate pins and host tools only")
    parser.add_argument("--force", action="store_true", help="rebuild even when the cache is valid")
    parser.add_argument("--jobs", type=int, default=max(1, os.cpu_count() or 1))
    parser.add_argument("--out", type=pathlib.Path, help="output cache root")
    parser.add_argument("--work", type=pathlib.Path, help="build and tool cache root")
    arguments = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    output_root = arguments.out or root / "ThirdParty/out/selinux-tools"
    work_root = arguments.work or root / "ThirdParty/out/selinux-tools-work"
    try:
        if arguments.check:
            check(root)
        else:
            output = build(root, output_root.resolve(), work_root.resolve(), arguments.jobs, arguments.force)
            print(output / "bin" / OUTPUT_NAME)
    except BuildFailure as error:
        print(f"build-selinux-tools: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
