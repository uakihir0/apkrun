#!/usr/bin/env python3
"""Build and validate the pinned macOS graphics runtime libraries."""

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
import stat
import subprocess
import sys
import tempfile
import uuid
import urllib.parse
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SCHEMA_VERSION = 2
GROUP = "virgl-runtime"
MINIMUM_MACOS = (27, 0)
ARTIFACTS = (
    "libvirglrenderer.1.dylib",
    "libepoxy.0.dylib",
    "libEGL.dylib",
    "libGLESv2.dylib",
)
PUBLIC_HEADER_EXTENSIONS = {".h", ".hpp", ".inc"}
BUILD_SCRIPTS = (
    "scripts/tools/check-lock.swift",
    "scripts/check-lock.sh",
    "scripts/tools/build_third_party.py",
    "ThirdParty/build/build-angle.sh",
    "ThirdParty/build/build-libepoxy.sh",
    "ThirdParty/build/build-virglrenderer.sh",
    "scripts/build-third-party.sh",
)


class BuildFailure(RuntimeError):
    pass


def run(
    arguments: Sequence[str],
    *,
    cwd: Optional[pathlib.Path] = None,
    env: Optional[Mapping[str, str]] = None,
    capture: bool = True,
    check: bool = True,
) -> str:
    try:
        result = subprocess.run(
            list(arguments),
            cwd=str(cwd) if cwd else None,
            env=dict(env) if env is not None else None,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
            text=True,
            check=False,
        )
    except OSError as error:
        raise BuildFailure("could not run {}: {}".format(arguments[0], error))
    output = result.stdout or ""
    if check and result.returncode:
        raise BuildFailure(
            "command failed ({}): {}\n{}".format(
                result.returncode, " ".join(arguments), output[-12000:]
            )
        )
    return output


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def framed_hash(records: Iterable[bytes]) -> str:
    digest = hashlib.sha256()
    for record in records:
        digest.update(len(record).to_bytes(8, byteorder="big"))
        digest.update(record)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def read_lock(root: pathlib.Path) -> Dict[str, Any]:
    lock_path = root / "ThirdParty/ThirdParty.lock.json"
    try:
        value = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BuildFailure("{}: {}".format(lock_path, error))
    if not isinstance(value, dict) or not isinstance(value.get("components"), list):
        raise BuildFailure("{}: expected a components array".format(lock_path))
    return value


def selected_components(lock: Mapping[str, Any], group: str) -> List[Dict[str, Any]]:
    selected = []
    for item in lock["components"]:
        if item.get("group") != group:
            continue
        ships = item.get("ships")
        if ships == "reference" or ships == ["reference"]:
            continue
        if isinstance(ships, list) and "reference" in ships:
            raise BuildFailure(
                "build group {} has an invalid mixed reference classification for {}".format(
                    group, item.get("name", "<unnamed>")
                )
            )
        if item.get("kind") != "source":
            raise BuildFailure(
                "build group {} contains non-source component {}".format(
                    group, item.get("name", "<unnamed>")
                )
            )
        selected.append(item)
    if not selected:
        raise BuildFailure("no buildable source components in group {}".format(group))
    return sorted(selected, key=lambda item: item["name"])


def patch_input_path(root: pathlib.Path, patch: Any) -> pathlib.Path:
    if not isinstance(patch, str) or not patch or "\\" in patch or "\0" in patch:
        raise BuildFailure("invalid patch path: {!r}".format(patch))
    relative = pathlib.PurePosixPath(patch)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise BuildFailure("unsafe patch path: {}".format(patch))

    repository = root.resolve()
    third_party = repository / "ThirdParty"
    patches_root = third_party / "patches"
    if third_party.is_symlink() or patches_root.is_symlink():
        raise BuildFailure("unsafe patch directory: {}".format(patches_root))
    if not patches_root.is_dir():
        raise BuildFailure("missing patch directory: {}".format(patches_root))

    candidate = patches_root
    for part in relative.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise BuildFailure("unsafe patch path: {}".format(candidate))
    try:
        resolved = candidate.resolve(strict=True)
        resolved_root = patches_root.resolve(strict=True)
    except OSError as error:
        raise BuildFailure("missing or unsafe patch {}: {}".format(patch, error))
    if not resolved.is_relative_to(resolved_root) or not stat.S_ISREG(candidate.stat().st_mode):
        raise BuildFailure("missing or unsafe patch: {}".format(candidate))
    return candidate


def input_hash(root: pathlib.Path, group: str) -> str:
    lock = read_lock(root)
    entries = selected_components(lock, group)
    records = [
        canonical_json(
            {
                "hashSchema": SCHEMA_VERSION,
                "lockSchema": lock.get("schemaVersion"),
                "group": group,
            }
        ),
        canonical_json(entries),
    ]
    for component in entries:
        for patch in component.get("patches", []):
            patch_path = patch_input_path(root, patch)
            records.append(patch.encode("utf-8"))
            records.append(patch_path.read_bytes())
    for relative in BUILD_SCRIPTS:
        script = root / relative
        if not script.is_file() or script.is_symlink():
            raise BuildFailure("missing or unsafe build input: {}".format(script))
        records.append(relative.encode("utf-8"))
        records.append(str(stat.S_IMODE(script.stat().st_mode)).encode("ascii"))
        records.append(script.read_bytes())
    return framed_hash(records)


def output_of(arguments: Sequence[str]) -> str:
    value = run(arguments).strip()
    if not value:
        raise BuildFailure("version probe returned no output: {}".format(arguments[0]))
    return value


def executable_identity(name: str, version_arguments: Sequence[str]) -> Dict[str, str]:
    path = shutil.which(name)
    if not path:
        raise BuildFailure("required build tool is unavailable: {}".format(name))
    resolved = str(pathlib.Path(path).resolve())
    return {
        "path": resolved,
        "version": output_of([resolved, *version_arguments]),
        "sha256": sha256_file(pathlib.Path(resolved)),
    }


def tool_path(*arguments: str) -> str:
    path = output_of(arguments)
    if not pathlib.Path(path).is_absolute() or not pathlib.Path(path).exists():
        raise BuildFailure("tool path is missing or invalid: {}".format(path))
    return str(pathlib.Path(path).resolve())


def environment_fingerprint(root: pathlib.Path) -> Dict[str, Any]:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise BuildFailure("virgl-runtime builds require an Apple silicon Mac")
    lock = read_lock(root)
    yaml_components = [
        item
        for item in selected_components(lock, GROUP)
        if item["name"] == "pyyaml"
    ]
    if len(yaml_components) != 1:
        raise BuildFailure("virgl-runtime must contain exactly one pinned PyYAML source")
    yaml_component = yaml_components[0]
    clang = tool_path("xcrun", "--find", "clang")
    clangxx = tool_path("xcrun", "--find", "clang++")
    python3 = tool_path("xcrun", "--find", "python3")
    metal = tool_path("xcrun", "--find", "metal")
    metallib = tool_path("xcrun", "--find", "metallib")
    sdk = output_of(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    sdk_path = tool_path("xcrun", "--sdk", "macosx", "--show-sdk-path")
    python_command = executable_identity("python3", ["--version"])
    developer_directory = os.environ.get("DEVELOPER_DIR") or output_of(
        ["xcode-select", "-p"]
    )
    return {
        "hostArchitecture": platform.machine(),
        "macOSBuild": output_of(["sw_vers", "-buildVersion"]),
        "xcode": output_of(["xcodebuild", "-version"]),
        "developerDirectory": str(pathlib.Path(developer_directory).resolve()),
        "developerDirectoryOverride": os.environ.get("DEVELOPER_DIR", ""),
        "sdkVersion": sdk,
        "sdkPath": sdk_path,
        "clangPath": clang,
        "clangVersion": output_of([clang, "--version"]),
        "clangxxPath": clangxx,
        "clangxxVersion": output_of([clangxx, "--version"]),
        "pythonPath": python3,
        "pythonVersion": output_of([python3, "--version"]),
        "pythonYamlSource": {
            "commit": yaml_component["commit"],
            "version": yaml_component["version"],
        },
        "pythonCommand": python_command,
        "gitVersion": output_of(["git", "--version"]),
        "git": executable_identity("git", ["--version"]),
        "meson": executable_identity("meson", ["--version"]),
        "ninja": executable_identity("ninja", ["--version"]),
        "pkgConfig": executable_identity("pkg-config", ["--version"]),
        "metalPath": metal,
        "metalVersion": output_of([metal, "-v"]),
        "metallibPath": metallib,
        "deploymentTarget": "{}.{}".format(*MINIMUM_MACOS),
    }


def environment_hash(fingerprint: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json(fingerprint))


def ensure_no_symlink_components(path: pathlib.Path, root: pathlib.Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise BuildFailure("{} is outside {}".format(path, root))
    current = root
    if current.exists() and current.is_symlink():
        raise BuildFailure("cache root must not be a symlink: {}".format(current))
    for part in relative.parts:
        current = current / part
        if current.exists() or current.is_symlink():
            if current.is_symlink():
                raise BuildFailure("cache path contains a symlink: {}".format(current))


def git_output(path: pathlib.Path, *arguments: str) -> str:
    return run(
        ["git", "-C", str(path), *arguments],
        env=git_environment(),
    ).strip()


def validate_worktree(path: pathlib.Path, commit: str, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise BuildFailure("{} checkout is missing or symlinked: {}".format(label, path))
    actual = git_output(path, "rev-parse", "--verify", "HEAD^{commit}")
    if actual != commit:
        raise BuildFailure(
            "{} checkout expected {}, found {}".format(label, commit, actual)
        )
    run(
        ["git", "-C", str(path), "diff", "--quiet", "HEAD", "--"],
        env=git_environment(),
    )
    run(
        ["git", "-C", str(path), "diff", "--cached", "--quiet", "--"],
        env=git_environment(),
    )


def git_environment(base: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    source = dict(base) if base is not None else os.environ.copy()
    env = {key: value for key, value in source.items() if not key.startswith("GIT_")}
    env.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    return env


def validate_source_checkout(path: pathlib.Path, commit: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise BuildFailure("pinned source path is not a real directory: {}".format(path))
    actual = git_output(path, "rev-parse", "--verify", "HEAD^{commit}")
    if actual != commit:
        raise BuildFailure(
            "{}: expected pinned commit {}, found {}".format(path, commit, actual)
        )
    status = git_output(path, "status", "--porcelain", "--untracked-files=all", "--ignored")
    if status:
        raise BuildFailure(
            "{}: pinned source is not clean (including ignored files)".format(path)
        )


def fetch_source(root: pathlib.Path, component: Mapping[str, Any]) -> pathlib.Path:
    name = component["name"]
    commit = component["commit"]
    repository = component["repository"]
    validate_source_reference(name, repository, commit)
    out_root = root / "ThirdParty/out"
    destination = out_root / "src" / name / commit
    ensure_no_symlink_components(destination, out_root)
    if destination.exists():
        validate_source_checkout(destination, commit)
        return destination

    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(
        tempfile.mkdtemp(prefix=".{}-fetch-".format(name), dir=str(parent))
    )
    try:
        staging.rmdir()
        staging.mkdir()
        safe_git_env = git_environment()
        run(["git", "init", "--quiet", str(staging)], env=safe_git_env)
        run(
            ["git", "-C", str(staging), "remote", "add", "origin", repository],
            env=safe_git_env,
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
            env=safe_git_env,
            capture=False,
        )
        run(
            ["git", "-C", str(staging), "checkout", "--quiet", "--detach", "FETCH_HEAD"],
            env=safe_git_env,
        )
        validate_source_checkout(staging, commit)
        try:
            os.rename(str(staging), str(destination))
        except FileExistsError:
            validate_source_checkout(destination, commit)
            shutil.rmtree(staging)
        return destination
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def patch_digest(root: pathlib.Path, component: Mapping[str, Any]) -> str:
    records = []
    for relative in component.get("patches", []):
        content = (root / "ThirdParty/patches" / relative).read_bytes()
        records.append(len(content).to_bytes(8, "big") + content)
    return sha256_bytes(b"".join(records))


def validate_source_reference(name: str, repository: str, commit: str) -> None:
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name):
        raise BuildFailure("unsafe source component name: {!r}".format(name))
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise BuildFailure("{}: source commit must be a full lowercase SHA-1".format(name))
    try:
        parsed = urllib.parse.urlsplit(repository)
        _ = parsed.port
    except ValueError as error:
        raise BuildFailure("{}: invalid repository URL: {}".format(name, error))
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path
        or (parsed.port not in (None, 443))
    ):
        raise BuildFailure(
            "{}: repository must be a public HTTPS URL without credentials or query parameters".format(
                name
            )
        )


def patched_source(root: pathlib.Path, component: Mapping[str, Any]) -> pathlib.Path:
    base = root / "ThirdParty/out/src" / component["name"] / component["commit"]
    patches = component.get("patches", [])
    if not patches:
        validate_source_checkout(base, component["commit"])
        return base
    digest = patch_digest(root, component)
    path = (
        root
        / "ThirdParty/out/patched-src"
        / component["name"]
        / component["commit"]
        / digest
    )
    ensure_no_symlink_components(path, root / "ThirdParty/out")
    expected_head = git_output(path, "rev-parse", "--verify", "HEAD^{commit}") if path.is_dir() else None
    if not path.is_dir() or path.is_symlink():
        raise BuildFailure(
            "patched source is missing; check-lock --apply should have created {}".format(path)
        )
    if expected_head is None:
        raise BuildFailure("patched source has no Git HEAD: {}".format(path))
    status = git_output(path, "status", "--porcelain", "--untracked-files=all", "--ignored")
    if status:
        raise BuildFailure("patched source is not clean: {}".format(path))
    return path


def discover_patched_sources(
    root: pathlib.Path, components: Sequence[Mapping[str, Any]]
) -> Dict[str, pathlib.Path]:
    return {component["name"]: patched_source(root, component) for component in components}


def runtime_rpaths(path: pathlib.Path) -> List[str]:
    output = run(["otool", "-l", str(path)])
    lines = output.splitlines()
    result = []
    for index, line in enumerate(lines):
        if not re.search(r"\bcmd\s+LC_RPATH\b", line):
            continue
        for candidate in lines[index + 1 :]:
            if candidate.lstrip().startswith("Load command"):
                break
            match = re.search(r"\bpath\s+(\S+)\s+\(offset\s+[0-9]+\)", candidate)
            if match:
                result.append(match.group(1))
                break
    return result


def normalize_runtime_rpaths(path: pathlib.Path) -> None:
    rpaths = runtime_rpaths(path)
    for rpath in dict.fromkeys(rpaths):
        if rpath != "@loader_path":
            run(["install_name_tool", "-delete_rpath", rpath, str(path)])
    if "@loader_path" not in rpaths:
        add_runtime_rpath(path, "@loader_path")


def validate_local_dependency(
    dependency: str,
    prefix: str,
    base: pathlib.Path,
    bundle_root: pathlib.Path,
    artifact: pathlib.Path,
) -> None:
    relative = dependency[len(prefix) :]
    parsed = pathlib.PurePosixPath(relative)
    if (
        not relative
        or parsed.is_absolute()
        or any(part in ("", ".", "..") for part in parsed.parts)
        or "\\" in relative
    ):
        raise BuildFailure(
            "{}: unsafe bundled dependency path {}".format(artifact.name, dependency)
        )
    target = base.joinpath(*parsed.parts)
    try:
        resolved = target.resolve(strict=True)
        resolved_root = bundle_root.resolve(strict=True)
    except OSError:
        raise BuildFailure(
            "{}: bundled dependency is missing: {}".format(artifact.name, dependency)
        )
    if (
        target.is_symlink()
        or not target.is_file()
        or not resolved.is_relative_to(resolved_root)
        or target.name not in ARTIFACTS
    ):
        raise BuildFailure(
            "{}: dependency is not a regular bundled runtime artifact: {}".format(
                artifact.name, dependency
            )
        )


def public_header_manifest(directory: pathlib.Path) -> Dict[str, str]:
    if directory.is_symlink() or not directory.is_dir():
        raise BuildFailure("public header directory is missing or unsafe: {}".format(directory))
    result = {}
    for current, directory_names, file_names in os.walk(directory, followlinks=False):
        current_path = pathlib.Path(current)
        for name in directory_names:
            if (current_path / name).is_symlink():
                raise BuildFailure("symlink in public headers: {}".format(current_path / name))
        for name in file_names:
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                raise BuildFailure("public header is not a regular file: {}".format(path))
            if path.suffix not in PUBLIC_HEADER_EXTENSIONS:
                raise BuildFailure("unexpected public header file: {}".format(path))
            result[path.relative_to(directory).as_posix()] = sha256_file(path)
    if not result:
        raise BuildFailure("public header directory is empty: {}".format(directory))
    return dict(sorted(result.items()))


def validate_runtime_artifact(
    path: pathlib.Path,
    name: str,
    forbidden_root: pathlib.Path,
    bundle_root: Optional[pathlib.Path] = None,
) -> None:
    if path.is_symlink() or not path.is_file():
        raise BuildFailure("artifact is missing or not a regular file: {}".format(path))
    architectures = run(["lipo", "-archs", str(path)]).strip().split()
    if architectures != ["arm64"]:
        raise BuildFailure(
            "{}: expected exactly arm64, found {}".format(path.name, architectures)
        )
    build_info = run(["vtool", "-show-build", str(path)])
    minimums = re.findall(r"\bminos\s+([0-9]+(?:\.[0-9]+)+)", build_info)
    if not minimums:
        raise BuildFailure("{}: vtool did not report a minimum OS".format(path.name))
    for value in minimums:
        numbers = tuple(int(part) for part in value.split("."))
        numbers = numbers + (0,) * (2 - len(numbers))
        if numbers[:2] < MINIMUM_MACOS:
            raise BuildFailure(
                "{}: minimum macOS {} is older than 27.0".format(path.name, value)
            )
    install_name = run(["otool", "-D", str(path)]).splitlines()
    if len(install_name) < 2 or install_name[1].strip() != "@rpath/" + name:
        raise BuildFailure(
            "{}: expected install name @rpath/{}, found {}".format(
                path.name, name, install_name[1].strip() if len(install_name) > 1 else "<none>"
            )
        )
    dependencies = run(["otool", "-L", str(path)])
    load_commands = run(["otool", "-l", str(path)])
    forbidden = str(forbidden_root.resolve())
    dependency_records = "\n".join(dependencies.splitlines()[1:])
    load_command_records = "\n".join(load_commands.splitlines()[1:])
    if forbidden in dependency_records or forbidden in load_command_records:
        raise BuildFailure("{}: load commands refer to build path {}".format(path, forbidden))
    rpaths = runtime_rpaths(path)
    if "@loader_path" not in rpaths:
        raise BuildFailure("{}: must include @loader_path".format(path.name))
    unsupported_rpaths = sorted(set(rpaths) - {"@loader_path"})
    if unsupported_rpaths:
        raise BuildFailure(
            "{}: unsupported or build-specific LC_RPATH {}".format(
                path.name, ", ".join(unsupported_rpaths)
            )
        )
    bundle_root = bundle_root or path.parent
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("/"):
            if not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise BuildFailure(
                    "{}: non-system absolute dependency {}".format(path.name, dependency)
                )
        elif dependency.startswith("@rpath/"):
            validate_local_dependency(
                dependency, "@rpath/", bundle_root, bundle_root, path
            )
        elif dependency.startswith("@loader_path/"):
            validate_local_dependency(
                dependency, "@loader_path/", path.parent, bundle_root, path
            )
        elif dependency:
            raise BuildFailure(
                "{}: unsupported dependency path {}".format(path.name, dependency)
            )


def verify_manifest(
    path: pathlib.Path, group: str, lock_hash: str, env_hash: str
) -> bool:
    if path.is_symlink() or not path.is_dir():
        return False
    manifest_path = path / "build-manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        return False
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(manifest, dict):
        return False
    artifacts = manifest.get("artifacts")
    headers = manifest.get("headers")
    if (
        manifest.get("schemaVersion") != SCHEMA_VERSION
        or manifest.get("group") != group
        or manifest.get("lockHash") != lock_hash
        or manifest.get("environmentHash") != env_hash
        or not isinstance(artifacts, dict)
        or not isinstance(headers, dict)
    ):
        return False
    try:
        if public_header_manifest(path / "include") != headers:
            return False
    except (BuildFailure, OSError):
        return False
    for name in ARTIFACTS:
        artifact = path / name
        if artifact.is_symlink() or not artifact.is_file():
            return False
        if artifacts.get(name) != sha256_file(artifact):
            return False
        try:
            validate_runtime_artifact(artifact, name, path, bundle_root=path)
        except (BuildFailure, OSError):
            return False
    actual_names = {entry.name for entry in path.iterdir()}
    return actual_names == set(ARTIFACTS) | {"build-manifest.json", "include"}


def build_context(
    root: pathlib.Path,
    group: str,
    lock_hash: str,
    fingerprint: Mapping[str, Any],
) -> Tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    env_hash = environment_hash(fingerprint)
    cache_key = "{}-{}".format(lock_hash, env_hash)
    out_root = root / "ThirdParty/out"
    output_parent = out_root / group
    output_parent.mkdir(parents=True, exist_ok=True)
    destination = output_parent / cache_key
    work = out_root / "work" / group / cache_key
    ensure_no_symlink_components(destination, out_root)
    ensure_no_symlink_components(work, out_root)
    return destination, work, output_parent


def publish_current_cache(root: pathlib.Path, destination: pathlib.Path) -> None:
    out_root = root / "ThirdParty/out"
    output_parent = out_root / GROUP
    ensure_no_symlink_components(destination, out_root)
    if destination.parent != output_parent or destination.is_symlink() or not destination.is_dir():
        raise BuildFailure("verified runtime cache has an unsafe location: {}".format(destination))

    current = output_parent / "current"
    if current.exists() and not current.is_symlink():
        raise BuildFailure("refusing non-symlink runtime pointer: {}".format(current))
    if current.is_symlink() and current.parent != output_parent:
        raise BuildFailure("runtime pointer is outside its cache directory")

    temporary = output_parent / (".current-" + uuid.uuid4().hex)
    try:
        os.symlink(destination.name, str(temporary))
        os.replace(str(temporary), str(current))
    except Exception:
        if temporary.is_symlink():
            temporary.unlink()
        raise
    if not current.is_symlink() or os.readlink(str(current)) != destination.name:
        raise BuildFailure("failed to publish the verified runtime pointer")


@contextlib.contextmanager
def exclusive_build_lock(root: pathlib.Path, cache_key: str):
    out_root = root / "ThirdParty/out"
    lock_directory = out_root / ".locks"
    ensure_no_symlink_components(lock_directory, out_root)
    lock_directory.mkdir(parents=True, exist_ok=True)
    lock_path = lock_directory / (cache_key + ".lock")
    ensure_no_symlink_components(lock_path, out_root)
    descriptor = os.open(
        str(lock_path), os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise BuildFailure("build lock is not a regular file: {}".format(lock_path))
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def component_environment(
    root: pathlib.Path,
    group: str,
    stage: pathlib.Path,
    work: pathlib.Path,
    fingerprint: Mapping[str, Any],
    sources: Mapping[str, pathlib.Path],
) -> Dict[str, str]:
    tool_directories = [
        str(pathlib.Path(fingerprint[key]).parent)
        for key in ("pythonPath", "clangPath", "clangxxPath")
    ]
    for key in ("git", "meson", "ninja", "pkgConfig"):
        tool_directories.append(str(pathlib.Path(fingerprint[key]["path"]).parent))
    tool_directories.extend(["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env = {"PATH": os.pathsep.join(dict.fromkeys(tool_directories))}
    env["HOME"] = str(work / "home")
    env["TMPDIR"] = str(work / "tmp")
    env["LANG"] = "C"
    env["LC_ALL"] = "C"
    env["SDKROOT"] = str(fingerprint["sdkPath"])
    env["DEVELOPER_DIR"] = str(fingerprint["developerDirectory"])
    (work / "home").mkdir(parents=True, exist_ok=True)
    (work / "tmp").mkdir(parents=True, exist_ok=True)
    env.update(
        {
            "APKRUN_THIRDPARTY_ROOT": str(root),
            "APKRUN_THIRDPARTY_GROUP": group,
            "APKRUN_THIRDPARTY_STAGING_OUTPUT": str(stage),
            "APKRUN_THIRDPARTY_WORK": str(work),
            "APKRUN_THIRDPARTY_DEPLOYMENT_TARGET": "{}.{}".format(*MINIMUM_MACOS),
            "APKRUN_THIRDPARTY_CLANG": str(fingerprint["clangPath"]),
            "APKRUN_THIRDPARTY_CLANGXX": str(fingerprint["clangxxPath"]),
            "APKRUN_THIRDPARTY_PYTHON": str(fingerprint["pythonPath"]),
            "APKRUN_THIRDPARTY_PYYAML_LIB": str(sources["pyyaml"] / "lib"),
            "APKRUN_THIRDPARTY_PYYAML_VERSION": str(
                fingerprint["pythonYamlSource"]["version"]
            ),
        }
    )
    env["MACOSX_DEPLOYMENT_TARGET"] = env["APKRUN_THIRDPARTY_DEPLOYMENT_TARGET"]
    env["CC"] = env["APKRUN_THIRDPARTY_CLANG"]
    env["CXX"] = env["APKRUN_THIRDPARTY_CLANGXX"]
    env["CFLAGS"] = "-arch arm64 -mmacosx-version-min={}".format(
        env["APKRUN_THIRDPARTY_DEPLOYMENT_TARGET"]
    )
    env["CXXFLAGS"] = env["CFLAGS"]
    env["LDFLAGS"] = "-arch arm64 -mmacosx-version-min={}".format(
        env["APKRUN_THIRDPARTY_DEPLOYMENT_TARGET"]
    )
    return env


def make_manifest(
    root: pathlib.Path,
    stage: pathlib.Path,
    group: str,
    lock_hash: str,
    fingerprint: Mapping[str, Any],
) -> None:
    env_hash = environment_hash(fingerprint)
    for name in ARTIFACTS:
        validate_runtime_artifact(
            stage / name,
            name,
            root / "ThirdParty/out/work",
            bundle_root=stage,
        )
    headers = public_header_manifest(stage / "include")
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "group": group,
        "lockHash": lock_hash,
        "environmentHash": env_hash,
        "environment": fingerprint,
        "artifacts": {name: sha256_file(stage / name) for name in ARTIFACTS},
        "headers": headers,
    }
    (stage / "build-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def acquire_and_patch(
    root: pathlib.Path, components: Sequence[Mapping[str, Any]]
) -> Dict[str, pathlib.Path]:
    # Validate every lock field and patch before using a repository URL.
    run([str(root / "scripts/check-lock.sh")], cwd=root, capture=False)
    for component in components:
        validate_source_reference(
            component["name"], component["repository"], component["commit"]
        )
        fetch_source(root, component)
    # The checker validates all pinned inputs and atomically publishes complete
    # patch series. It never modifies the clean source checkouts.
    run([str(root / "scripts/check-lock.sh"), "--apply"], cwd=root, capture=False)
    return discover_patched_sources(root, components)


def validate_repository_lock(root: pathlib.Path) -> None:
    checker = root / "scripts/check-lock.sh"
    if checker.is_symlink() or not checker.is_file():
        raise BuildFailure("missing or unsafe lock validator: {}".format(checker))
    run([str(checker)], cwd=root)


def copy_artifact(source: pathlib.Path, stage: pathlib.Path, destination_name: str) -> None:
    if source.is_symlink() or not source.is_file():
        raise BuildFailure("expected build output is missing: {}".format(source))
    destination = stage / destination_name
    shutil.copy2(str(source), str(destination))


def copy_public_headers(
    source: pathlib.Path, stage: pathlib.Path, destination_name: str
) -> None:
    if source.is_symlink() or not source.is_dir():
        raise BuildFailure("public header source is missing or unsafe: {}".format(source))
    destination = stage / "include" / destination_name
    if destination.exists() or destination.is_symlink():
        raise BuildFailure("duplicate public header destination: {}".format(destination))
    destination.mkdir(parents=True)
    for current, directory_names, file_names in os.walk(source, followlinks=False):
        current_path = pathlib.Path(current)
        relative_root = current_path.relative_to(source)
        for name in directory_names:
            if (current_path / name).is_symlink():
                raise BuildFailure(
                    "symlink in public header source: {}".format(current_path / name)
                )
            (destination / relative_root / name).mkdir(exist_ok=True)
        for name in file_names:
            source_file = current_path / name
            if source_file.is_symlink() or not source_file.is_file():
                raise BuildFailure(
                    "public header source is not a regular file: {}".format(source_file)
                )
            if source_file.suffix not in PUBLIC_HEADER_EXTENSIONS:
                continue
            shutil.copy2(
                str(source_file),
                str(destination / relative_root / name),
            )
    public_header_manifest(destination)


def add_install_name(path: pathlib.Path, name: str) -> None:
    run(["install_name_tool", "-id", "@rpath/" + name, str(path)])


def add_runtime_rpath(path: pathlib.Path, rpath: str) -> None:
    run(["install_name_tool", "-add_rpath", rpath, str(path)])


def patch_dependency(path: pathlib.Path, old: str, new: str) -> None:
    if old == new:
        return
    run(["install_name_tool", "-change", old, new, str(path)])


def validate_angle_dependency_inventory(
    components: Sequence[Mapping[str, Any]],
    target_dependencies: Mapping[str, str],
) -> None:
    expected: Dict[str, str] = {}
    for component in components:
        prefixes = component.get("gnTargetPrefixes", [])
        if not prefixes:
            continue
        name = component.get("name")
        ships = component.get("ships")
        if (
            not isinstance(name, str)
            or not name.startswith("angle-")
            or component.get("group") != GROUP
            or component.get("kind") != "source"
            or not (
                ships == "app"
                or (isinstance(ships, list) and "app" in ships)
            )
            or not isinstance(prefixes, list)
            or any(
                not isinstance(prefix, str)
                or not prefix.startswith("//third_party/")
                or ":" in prefix
                or prefix.endswith("/")
                or "\\" in prefix
                or any(part in ("", ".", "..") for part in prefix[2:].split("/"))
                for prefix in prefixes
            )
        ):
            raise BuildFailure("invalid ANGLE GN dependency inventory entry")
        for prefix in prefixes:
            if prefix in expected:
                raise BuildFailure(
                    "duplicate ANGLE GN dependency prefix {}".format(prefix)
                )
            expected[prefix] = name
    if not expected:
        raise BuildFailure("ANGLE Metal dependency inventory is empty")

    observed = set()
    unmapped = set()
    for output in target_dependencies.values():
        for line in output.splitlines():
            label = line.strip()
            if not label.startswith("//third_party/"):
                continue
            path = label.split(":", 1)[0]
            matches = [
                prefix
                for prefix in expected
                if path == prefix or path.startswith(prefix + "/")
            ]
            if not matches:
                unmapped.add(path)
            else:
                observed.add(max(matches, key=len))

    if unmapped:
        raise BuildFailure(
            "ANGLE Metal targets use unlicensed third_party dependencies: {}".format(
                ", ".join(sorted(unmapped))
            )
        )
    missing = sorted(set(expected) - observed)
    if missing:
        raise BuildFailure(
            "ANGLE license inventory has dependencies outside the Metal target graph: {}".format(
                ", ".join("{} ({})".format(prefix, expected[prefix]) for prefix in missing)
            )
        )


def build_angle(
    root: pathlib.Path,
    component: Mapping[str, Any],
    sources: Mapping[str, pathlib.Path],
    stage: pathlib.Path,
    work: pathlib.Path,
    env: Mapping[str, str],
) -> None:
    angle_work = work / "angle"
    checkout = angle_work / "src"
    angle_work.mkdir(parents=True, exist_ok=True)
    angle_src = sources["angle"]
    expected_head = git_output(angle_src, "rev-parse", "HEAD")
    if not checkout.exists():
        run(["git", "clone", "--shared", "--no-checkout", str(angle_src), str(checkout)])
        run(
            ["git", "-C", str(checkout), "checkout", "--detach", expected_head],
            env=git_environment(),
        )
    validate_worktree(checkout, expected_head, "ANGLE")

    depot_commit = next(
        item["commit"]
        for item in read_lock(root)["components"]
        if item["name"] == "depot_tools"
    )
    depot_source = root / "ThirdParty/out/src/depot_tools" / depot_commit
    validate_source_checkout(depot_source, depot_commit)
    # depot_tools writes CIPD and metrics state beside its scripts. Keep that
    # generated state in the build workspace, outside the pinned source cache.
    depot = work / "depot_tools"
    if not depot.exists():
        run(
            ["git", "clone", "--shared", "--no-checkout", str(depot_source), str(depot)],
            env=git_environment(),
        )
        run(
            ["git", "-C", str(depot), "checkout", "--detach", depot_commit],
            env=git_environment(),
        )
    if git_output(depot, "rev-parse", "HEAD") != depot_commit:
        raise BuildFailure("build-local depot_tools checkout is not at its pinned revision")
    if git_output(depot, "status", "--porcelain", "--untracked-files=all"):
        raise BuildFailure("build-local depot_tools checkout has unexpected source changes")
    gclient = depot / "gclient"
    if not gclient.is_file():
        raise BuildFailure("pinned depot_tools checkout has no gclient: {}".format(depot))
    angle_env = git_environment(env)
    angle_env["PATH"] = str(depot) + os.pathsep + angle_env.get("PATH", "")
    angle_env["DEPOT_TOOLS_UPDATE"] = "0"
    angle_env["DEPOT_TOOLS_METRICS"] = "0"
    angle_env["GCLIENT_SUPPRESS_GIT_VERSION_WARNING"] = "1"
    config_path = angle_work / ".gclient"
    if config_path.is_symlink():
        raise BuildFailure("refusing symlinked ANGLE gclient config: {}".format(config_path))
    if config_path.exists():
        config_path.unlink()
    run(
        [
            str(gclient),
            "config",
            "--unmanaged",
            "--name=src",
            component["repository"],
        ],
        cwd=angle_work,
        env=angle_env,
        capture=False,
    )
    if config_path.is_symlink() or not config_path.is_file():
        raise BuildFailure("gclient did not write a regular ANGLE config")
    run(
        [str(gclient), "sync", "--reset", "--no-history"],
        cwd=angle_work,
        env=angle_env,
        capture=False,
    )
    validate_worktree(checkout, expected_head, "ANGLE after gclient sync")

    args = "\n".join(component["buildFlags"])
    gn = checkout / "buildtools/mac/gn"
    ninja = checkout / "third_party/ninja/ninja"
    if not gn.is_file() or not ninja.is_file():
        raise BuildFailure("ANGLE GN or pinned Ninja is missing after gclient sync")
    output = angle_work / "out/Release"
    run(
        [str(gn), "gen", str(output), "--args=" + args],
        cwd=checkout,
        env=angle_env,
        capture=False,
    )
    target_dependencies = {
        target: run(
            [str(gn), "desc", str(output), target, "deps", "--all"],
            cwd=checkout,
            env=angle_env,
        )
        for target in ("//:libEGL", "//:libGLESv2")
    }
    validate_angle_dependency_inventory(
        read_lock(root)["components"], target_dependencies
    )
    run(
        [str(ninja), "-C", str(output), "libEGL", "libGLESv2"],
        cwd=checkout,
        env=angle_env,
        capture=False,
    )
    egl = output / "libEGL.dylib"
    gles = output / "libGLESv2.dylib"
    copy_artifact(egl, stage, "libEGL.dylib")
    copy_artifact(gles, stage, "libGLESv2.dylib")
    add_install_name(stage / "libEGL.dylib", "libEGL.dylib")
    add_install_name(stage / "libGLESv2.dylib", "libGLESv2.dylib")
    normalize_runtime_rpaths(stage / "libEGL.dylib")
    normalize_runtime_rpaths(stage / "libGLESv2.dylib")
    for header_directory in ("EGL", "GLES2", "GLES3", "KHR"):
        copy_public_headers(
            checkout / "include" / header_directory, stage, header_directory
        )

    include_root = checkout / "include"
    pkgconfig = work / "angle-pkgconfig"
    (pkgconfig / "pkgconfig").mkdir(parents=True, exist_ok=True)
    install_include = work / "angle-install/include"
    if install_include.exists():
        shutil.rmtree(install_include)
    shutil.copytree(str(include_root), str(install_include))
    pc_prefix = str(work / "angle-install")
    (pkgconfig / "pkgconfig/egl.pc").write_text(
        "prefix={}\nexec_prefix=${{prefix}}\nlibdir=${{prefix}}/lib\n"
        "includedir=${{prefix}}/include\n\nName: EGL\nDescription: ANGLE EGL\n"
        "Version: 1.5\nLibs: -L${{libdir}} -lEGL\n"
        "Cflags: -I${{includedir}}\n".format(pc_prefix),
        encoding="utf-8",
    )
    (pkgconfig / "pkgconfig/glesv2.pc").write_text(
        "prefix={}\nexec_prefix=${{prefix}}\nlibdir=${{prefix}}/lib\n"
        "includedir=${{prefix}}/include\n\nName: GLESv2\nDescription: ANGLE GLESv2\n"
        "Version: 3.2\nRequires: egl\nLibs: -L${{libdir}} -lGLESv2\n"
        "Cflags: -I${{includedir}}\n".format(pc_prefix),
        encoding="utf-8",
    )
    (work / "angle-install/lib").mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(stage / "libEGL.dylib"), str(work / "angle-install/lib/libEGL.dylib"))
    shutil.copy2(
        str(stage / "libGLESv2.dylib"),
        str(work / "angle-install/lib/libGLESv2.dylib"),
    )


def native_file(work: pathlib.Path, env: Mapping[str, str]) -> pathlib.Path:
    path = work / "macos-arm64.ini"
    path.write_text(
        "[binaries]\n"
        "c = {!r}\ncpp = {!r}\n"
        "pkgconfig = {!r}\npython = {!r}\n"
        "[host_machine]\n"
        "system = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\n"
        "endian = 'little'\n"
        "[built-in options]\n"
        "c_args = ['-arch', 'arm64', '-mmacosx-version-min=27.0']\n"
        "cpp_args = ['-arch', 'arm64', '-mmacosx-version-min=27.0']\n"
        "c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=27.0']\n"
        "cpp_link_args = ['-arch', 'arm64', '-mmacosx-version-min=27.0']\n".format(
            env["CC"],
            env["CXX"],
            shutil.which("pkg-config") or "pkg-config",
            env["APKRUN_THIRDPARTY_PYTHON"],
        ),
        encoding="utf-8",
    )
    return path


def meson_environment_with_pinned_yaml(
    env: Mapping[str, str], expected_version: str
) -> Dict[str, str]:
    meson_env = dict(env)
    yaml_lib = pathlib.Path(env["APKRUN_THIRDPARTY_PYYAML_LIB"])
    yaml_package = yaml_lib / "yaml"
    if yaml_lib.is_symlink() or not (yaml_package / "__init__.py").is_file():
        raise BuildFailure("pinned PyYAML package is missing: {}".format(yaml_package))
    meson_env["PYTHONPATH"] = str(yaml_lib)
    meson_env["PYTHONDONTWRITEBYTECODE"] = "1"
    actual_version = run(
        [
            env["APKRUN_THIRDPARTY_PYTHON"],
            "-c",
            "import yaml; print(yaml.__version__)",
        ],
        env=meson_env,
    ).strip()
    if actual_version != expected_version:
        raise BuildFailure(
            "pinned PyYAML expected {}, found {}".format(expected_version, actual_version)
        )
    return meson_env


def run_meson_component(
    source: pathlib.Path,
    build: pathlib.Path,
    prefix: pathlib.Path,
    flags: Sequence[str],
    work: pathlib.Path,
    env: Mapping[str, str],
    python_yaml_version: Optional[str] = None,
) -> None:
    if python_yaml_version is not None:
        meson_env = meson_environment_with_pinned_yaml(env, python_yaml_version)
    else:
        meson_env = dict(env)
    meson_env["PKG_CONFIG_PATH"] = os.pathsep.join(
        [
            str(work / "angle-pkgconfig/pkgconfig"),
            str(prefix.parent / "libepoxy/lib/pkgconfig"),
        ]
    )
    native = native_file(work, env)
    run(
        [
            "meson",
            "setup",
            str(build),
            str(source),
            "--native-file",
            str(native),
            "--prefix",
            str(prefix),
            "--libdir=lib",
            *flags,
        ],
        env=meson_env,
        capture=False,
    )
    run(["meson", "compile", "-C", str(build)], env=meson_env, capture=False)
    run(["meson", "install", "-C", str(build)], env=meson_env, capture=False)


def build_libepoxy(
    component: Mapping[str, Any],
    sources: Mapping[str, pathlib.Path],
    stage: pathlib.Path,
    work: pathlib.Path,
    env: Mapping[str, str],
) -> None:
    prefix = work / "libepoxy"
    run_meson_component(
        sources["libepoxy"],
        work / "build-libepoxy",
        prefix,
        component["buildFlags"],
        work,
        env,
    )
    library = prefix / "lib/libepoxy.0.dylib"
    # Virglrenderer links against this installed library in the next build
    # step. Normalize its ID before linking so the dependency recorded in
    # libvirglrenderer is relocatable instead of containing this build prefix.
    add_install_name(library, "libepoxy.0.dylib")
    copy_artifact(library, stage, "libepoxy.0.dylib")
    add_install_name(stage / "libepoxy.0.dylib", "libepoxy.0.dylib")
    normalize_runtime_rpaths(stage / "libepoxy.0.dylib")
    copy_public_headers(prefix / "include/epoxy", stage, "epoxy")


def build_virglrenderer(
    component: Mapping[str, Any],
    sources: Mapping[str, pathlib.Path],
    stage: pathlib.Path,
    work: pathlib.Path,
    env: Mapping[str, str],
) -> None:
    # Meson's virglrenderer build requires PyYAML. Use only the locked source.
    prefix = work / "virglrenderer"
    run_meson_component(
        sources["virglrenderer"],
        work / "build-virglrenderer",
        prefix,
        component["buildFlags"],
        work,
        env,
        python_yaml_version=env["APKRUN_THIRDPARTY_PYYAML_VERSION"],
    )
    library = prefix / "lib/libvirglrenderer.1.dylib"
    copy_artifact(library, stage, "libvirglrenderer.1.dylib")
    add_install_name(stage / "libvirglrenderer.1.dylib", "libvirglrenderer.1.dylib")
    normalize_runtime_rpaths(stage / "libvirglrenderer.1.dylib")
    copy_public_headers(prefix / "include/virgl", stage, "virgl")


def run_component(root: pathlib.Path, name: str) -> None:
    required = (
        "APKRUN_THIRDPARTY_GROUP",
        "APKRUN_THIRDPARTY_STAGING_OUTPUT",
        "APKRUN_THIRDPARTY_WORK",
    )
    if any(not os.environ.get(key) for key in required):
        raise BuildFailure("component scripts must be invoked by build-third-party.sh")
    group = os.environ["APKRUN_THIRDPARTY_GROUP"]
    if group != GROUP:
        raise BuildFailure("unsupported build group: {}".format(group))
    root = pathlib.Path(os.environ["APKRUN_THIRDPARTY_ROOT"]).resolve()
    stage = pathlib.Path(os.environ["APKRUN_THIRDPARTY_STAGING_OUTPUT"])
    work = pathlib.Path(os.environ["APKRUN_THIRDPARTY_WORK"])
    lock = read_lock(root)
    components = selected_components(lock, group)
    sources = discover_patched_sources(root, components)
    component = next((item for item in components if item["name"] == name), None)
    if component is None:
        raise BuildFailure("{} is not a buildable component in {}".format(name, group))
    fingerprint = environment_fingerprint(root)
    env = component_environment(root, group, stage, work, fingerprint, sources)
    if name == "angle":
        build_angle(root, component, sources, stage, work, env)
    elif name == "libepoxy":
        build_libepoxy(component, sources, stage, work, env)
    elif name == "virglrenderer":
        build_virglrenderer(component, sources, stage, work, env)
    else:
        raise BuildFailure("no build implementation for {}".format(name))


def run_build(root: pathlib.Path, group: str, force: bool) -> pathlib.Path:
    if group != GROUP:
        raise BuildFailure("unsupported build group: {}".format(group))
    validate_repository_lock(root)
    lock = read_lock(root)
    components = selected_components(lock, group)
    lock_hash = input_hash(root, group)
    fingerprint = environment_fingerprint(root)
    env_hash = environment_hash(fingerprint)
    destination, work, output_parent = build_context(root, group, lock_hash, fingerprint)
    cache_key = destination.name
    with exclusive_build_lock(root, cache_key):
        if not force and verify_manifest(destination, group, lock_hash, env_hash):
            publish_current_cache(root, destination)
            print("build-third-party: verified cache hit at {}".format(destination))
            return destination

        sources = acquire_and_patch(root, components)
        if not sources:
            raise BuildFailure("no prepared source checkouts")
        work.mkdir(parents=True, exist_ok=True)
        staging = pathlib.Path(
            tempfile.mkdtemp(prefix=".{}-staging-".format(group), dir=str(output_parent))
        )
        env = component_environment(root, group, staging, work, fingerprint, sources)
        try:
            for component_name in ("angle", "libepoxy", "virglrenderer"):
                script = root / "ThirdParty/build/build-{}.sh".format(component_name)
                run([str(script), group], cwd=root, env=env, capture=False)
            make_manifest(root, staging, group, lock_hash, fingerprint)
            if not verify_manifest(staging, group, lock_hash, env_hash):
                raise BuildFailure("new runtime output failed manifest verification")
            quarantine = None
            if destination.exists():
                if destination.is_symlink():
                    raise BuildFailure("refusing to replace cache symlink {}".format(destination))
                quarantine = output_parent / ".invalid-{}-{}".format(
                    destination.name, uuid.uuid4().hex
                )
                os.rename(str(destination), str(quarantine))
            os.rename(str(staging), str(destination))
            if quarantine is not None:
                shutil.rmtree(quarantine, ignore_errors=True)
            publish_current_cache(root, destination)
            print("build-third-party: built and verified {}".format(destination))
            return destination
        except Exception as error:
            if staging.exists():
                print(
                    "build-third-party: failed; diagnostic output preserved at {}".format(staging),
                    file=sys.stderr,
                )
            raise error


def print_cache_key(root: pathlib.Path, group: str) -> str:
    validate_repository_lock(root)
    lock_hash = input_hash(root, group)
    env_hash = environment_hash(environment_fingerprint(root))
    return "{}-{}".format(lock_hash, env_hash)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("group")
    build_parser.add_argument("--force", action="store_true")
    key_parser = subparsers.add_parser("cache-key")
    key_parser.add_argument("group")
    component_parser = subparsers.add_parser("component")
    component_parser.add_argument("name")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    try:
        if args.command == "component":
            run_component(root, args.name)
        elif args.command == "cache-key":
            print(print_cache_key(root, args.group))
        else:
            run_build(root, args.group, args.force)
    except BuildFailure as error:
        print("build-third-party: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
