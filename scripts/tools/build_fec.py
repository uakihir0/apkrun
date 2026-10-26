#!/usr/bin/env python3
"""Build a pinned AOSP fec host utility for Apple silicon macOS."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
from collections.abc import Mapping, Sequence
from typing import Any

SCHEMA_VERSION = 1
MINIMUM_MACOS = "27.0"
COMPONENT = "fec"
OUTPUT_RELATIVE = pathlib.Path("ThirdParty/out/fec/bin/fec")
SOURCE_COMPONENTS = {
    "aosp-verity": {
        "repository": "https://android.googlesource.com/platform/system/extras",
        "commit": "1289e9b3f282909eec6e80414e14dcc207bda439",
        "version": "android-17.0.0_r1",
        "license": "Apache-2.0",
        "licenseFiles": ("verity/NOTICE",),
        "buildFlags": (
            "upstream-tag-object=740be3463713251280b0471d3dfb3cdd321520dd",
            "fec-host-adapter=macOS-arm64",
            "FEC-root-count=2",
        ),
        "tagObject": "740be3463713251280b0471d3dfb3cdd321520dd",
        "files": (
            "verity/fec/main.cpp",
            "verity/fec/image.cpp",
            "verity/fec/image.h",
            "verity/NOTICE",
            "libfec/include/fec/ecc.h",
        ),
    },
    "libfec-rs": {
        "repository": "https://android.googlesource.com/platform/external/fec",
        "commit": "90857deb7973c0ca24c79b9c1809fc9667f32c4f",
        "version": "2024-11-20",
        "license": "LGPL-2.1-or-later",
        "licenseFiles": ("NOTICE",),
        "buildFlags": (
            "pinned-upstream-reed-solomon-source",
            "C11",
            "no-source-patches",
        ),
        "files": (
            "NOTICE",
            "char.h",
            "decode_rs.h",
            "decode_rs_char.c",
            "encode_rs.h",
            "encode_rs_char.c",
            "init_rs.h",
            "init_rs_char.c",
            "rs-common.h",
        ),
    },
}
SPARSE_CHECKOUT_PATHS = {
    "aosp-verity": (
        "/verity/fec/**",
        "/verity/NOTICE",
        "/libfec/include/fec/**",
    ),
}
LICENSE_COPIES = {
    ("aosp-verity", "verity/NOTICE"): "ThirdParty/licenses/aosp-verity/verity/NOTICE",
    ("libfec-rs", "NOTICE"): "ThirdParty/licenses/libfec-rs/NOTICE",
}
SHIM_FILES = (
    "scripts/build-fec-tool.sh",
    "scripts/tools/build_fec.py",
    "scripts/tools/fec_host/include/android-base/file.h",
    "scripts/tools/fec_host/include/fec/io.h",
    "scripts/tools/fec_host/include/openssl/sha.h",
    "scripts/tools/fec_host/include/sparse/sparse.h",
    "scripts/tools/fec_host/include/utils/Compat.h",
    "scripts/tools/fec_host/sparse_compat.cpp",
)
BUILD_FLAGS = (
    "-arch arm64",
    "-mmacosx-version-min=27.0",
    "-O3",
    "C++17",
    "C11",
    "CommonCrypto",
    "content-hash Mach-O UUID",
    "pinned upstream sources, no source patches",
    "compiler environment excludes host flags, include paths, and library paths",
)
COMPILER_ENVIRONMENT_REMOVED = (
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "OBJC_INCLUDE_PATH",
    "LIBRARY_PATH",
    "CFLAGS",
    "CPPFLAGS",
    "CXXFLAGS",
    "LDFLAGS",
    "ARCHFLAGS",
    "SDKROOT",
    "MACOSX_DEPLOYMENT_TARGET",
    "GCC_EXEC_PREFIX",
    "COMPILER_PATH",
    "CLANG_CONFIG_FILE",
    "CLANG_CONFIG_FILE_SYSTEM_DIR",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
)
FEC_HEADER = struct.Struct("<IIIIIQ32s")


class BuildFailure(RuntimeError):
    """An unavailable or unverifiable input to the pinned host build."""


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


def validate_lock(root: pathlib.Path) -> dict[str, dict[str, Any]]:
    lock_path = root / "ThirdParty/ThirdParty.lock.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BuildFailure(f"{lock_path}: {error}") from None
    if not isinstance(lock, dict) or not isinstance(lock.get("components"), list):
        raise BuildFailure(f"{lock_path}: expected a components array")

    locked: dict[str, dict[str, Any]] = {}
    for name, expected in SOURCE_COMPONENTS.items():
        matches = [
            component
            for component in lock["components"]
            if isinstance(component, dict) and component.get("name") == name
        ]
        if len(matches) != 1:
            raise BuildFailure(
                f"ThirdParty.lock.json must contain exactly one {name} entry"
            )
        component = matches[0]
        fields = {
            "group": "image-tooling",
            "kind": "source",
            "repository": expected["repository"],
            "commit": expected["commit"],
            "version": expected["version"],
            "license": expected["license"],
            "licenseFiles": list(expected["licenseFiles"]),
            "buildFlags": list(expected["buildFlags"]),
            "patches": [],
            "ships": "tooling",
        }
        if any(component.get(field) != value for field, value in fields.items()):
            raise BuildFailure(
                f"ThirdParty.lock.json {name} entry differs from the reviewed FEC pin"
            )
        for relative in expected["licenseFiles"]:
            path = root / "ThirdParty/licenses" / name / relative
            if path.is_symlink() or not path.is_file():
                raise BuildFailure(f"missing or unsafe third-party notice copy: {path}")
        locked[name] = component
    return locked


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sanitized_git_environment() -> dict[str, str]:
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    return environment


def compiler_environment(
    environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Keep toolchain selection while removing ambient compiler and linker overrides."""
    result = dict(os.environ if environment is None else environment)
    for name in COMPILER_ENVIRONMENT_REMOVED:
        result.pop(name, None)
    return result


def git_output(path: pathlib.Path, *arguments: str) -> str:
    return run(
        ["git", "-C", str(path), *arguments],
        env=sanitized_git_environment(),
    ).stdout.strip()


def validate_clean_checkout(path: pathlib.Path, commit: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise BuildFailure(f"pinned source checkout is missing or unsafe: {path}")
    actual = git_output(path, "rev-parse", "--verify", "HEAD^{commit}")
    expected = git_output(path, "rev-parse", "--verify", f"{commit}^{{commit}}")
    if actual != expected:
        raise BuildFailure(
            f"{path} is at {actual}, expected the peeled source pin {expected}"
        )
    status = git_output(
        path, "status", "--porcelain", "--untracked-files=all", "--ignored"
    )
    if status:
        raise BuildFailure(f"{path} is not clean, including ignored files")


def fetch_source(
    root: pathlib.Path, name: str, component: Mapping[str, Any]
) -> pathlib.Path:
    destination = root / "ThirdParty/out/src" / name / component["commit"]
    if destination.exists():
        validate_clean_checkout(destination, component["commit"])
        return destination
    if destination.is_symlink():
        raise BuildFailure(f"refusing symlinked pinned source path: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{name}-fetch-", dir=destination.parent)
    )
    staging.rmdir()
    try:
        run(["git", "init", "--quiet", str(staging)], env=sanitized_git_environment())
        run(
            [
                "git",
                "-C",
                str(staging),
                "remote",
                "add",
                "origin",
                component["repository"],
            ],
            env=sanitized_git_environment(),
        )
        run(
            [
                "git",
                "-C",
                str(staging),
                "fetch",
                "--depth=1",
                "--filter=blob:none",
                "--no-tags",
                "origin",
                component["commit"],
            ],
            env=sanitized_git_environment(),
        )
        if name in SPARSE_CHECKOUT_PATHS:
            run(
                ["git", "-C", str(staging), "sparse-checkout", "init", "--no-cone"],
                env=sanitized_git_environment(),
            )
            run(
                [
                    "git",
                    "-C",
                    str(staging),
                    "sparse-checkout",
                    "set",
                    "--no-cone",
                    *SPARSE_CHECKOUT_PATHS[name],
                ],
                env=sanitized_git_environment(),
            )
        run(
            [
                "git",
                "-C",
                str(staging),
                "checkout",
                "--quiet",
                "--detach",
                "FETCH_HEAD",
            ],
            env=sanitized_git_environment(),
        )
        validate_clean_checkout(staging, component["commit"])
        try:
            os.rename(staging, destination)
        except FileExistsError:
            validate_clean_checkout(destination, component["commit"])
            shutil.rmtree(staging)
        return destination
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def checked_source_file(source: pathlib.Path, relative: str) -> pathlib.Path:
    path = source / relative
    if path.is_symlink() or not path.is_file():
        raise BuildFailure(f"pinned source is missing or unsafe: {path}")
    return path


def normalized_notice(contents: bytes) -> bytes:
    """Normalize line endings, page breaks, and insignificant trailing whitespace."""
    normalized = contents.replace(b"\x0c", b"")
    lines = normalized.splitlines()
    return b"\n".join(line.rstrip(b" \t") for line in lines).rstrip(b"\n")


def hash_inputs(
    root: pathlib.Path,
    sources: Mapping[str, pathlib.Path],
    components: Mapping[str, Mapping[str, Any]],
) -> str:
    digest = hashlib.sha256()
    records: list[tuple[str, bytes]] = []
    for relative in SHIM_FILES:
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise BuildFailure(f"missing or unsafe build input: {path}")
        records.append((relative, path.read_bytes()))
    for name, component in SOURCE_COMPONENTS.items():
        source = sources[name]
        for relative in component["files"]:
            path = checked_source_file(source, relative)
            contents = path.read_bytes()
            records.append((f"{name}/{relative}", contents))
            local_license = LICENSE_COPIES.get((name, relative))
            if local_license:
                copied = root / local_license
                if copied.is_symlink() or not copied.is_file():
                    raise BuildFailure(
                        f"missing or unsafe third-party notice copy: {copied}"
                    )
                if normalized_notice(copied.read_bytes()) != normalized_notice(
                    contents
                ):
                    raise BuildFailure(
                        f"third-party notice text differs from pinned source: {copied}"
                    )
    for name, component in components.items():
        records.append((f"{name}/repository", component["repository"].encode("utf-8")))
        records.append((f"{name}/commit", component["commit"].encode("ascii")))
        records.append((f"{name}/version", component["version"].encode("utf-8")))
    records.append(("flags", canonical_json(BUILD_FLAGS)))
    for name, content in sorted(records):
        digest.update(len(name.encode("utf-8")).to_bytes(8, "big"))
        digest.update(name.encode("utf-8"))
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def executable_path(name: str) -> str:
    value = run(["xcrun", "--find", name]).stdout.strip()
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_file():
        raise BuildFailure(f"xcrun returned an invalid {name} path: {value}")
    return str(path)


def host_environment() -> tuple[dict[str, Any], str, str, str]:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise BuildFailure(
            "FEC builds require Apple silicon macOS; Rosetta is unsupported"
        )
    clang = executable_path("clang")
    clangxx = executable_path("clang++")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    if not sdk or not pathlib.Path(sdk).is_dir():
        raise BuildFailure(f"xcrun returned an invalid macOS SDK path: {sdk}")
    compiler = run([clangxx, "--version"]).stdout.splitlines()[0]
    record = {
        "architecture": platform.machine(),
        "macOSBuild": run(["sw_vers", "-buildVersion"]).stdout.strip(),
        "xcodeVersion": run(["xcodebuild", "-version"]).stdout.strip(),
        "toolchainSelection": {
            name: os.environ.get(name)
            for name in ("DEVELOPER_DIR", "TOOLCHAINS", "XCODE_XCCONFIG_FILE")
        },
        "sdkVersion": run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-version"]
        ).stdout.strip(),
        "deploymentTarget": MINIMUM_MACOS,
        "clang": compiler,
        "clangSha256": sha256_file(pathlib.Path(clang)),
        "clangxxSha256": sha256_file(pathlib.Path(clangxx)),
    }
    return record, clang, clangxx, sdk


@contextlib.contextmanager
def build_lock(path: pathlib.Path):
    if path.is_symlink():
        raise BuildFailure(f"refusing symlinked build lock: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


@contextlib.contextmanager
def verify_lock(path: pathlib.Path):
    """Lock an existing build without creating or changing anything."""
    if path.is_symlink() or not path.is_file():
        raise BuildFailure(f"existing FEC build lock is missing or unsafe: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise BuildFailure(
            f"cannot open existing FEC build lock {path}: {error}"
        ) from None
    with os.fdopen(descriptor, "rb") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def existing_sources(
    root: pathlib.Path,
    components: Mapping[str, Mapping[str, Any]],
) -> dict[str, pathlib.Path]:
    """Validate already-fetched source trees without fetching or creating directories."""
    source_root = root / "ThirdParty/out/src"
    if source_root.is_symlink() or not source_root.is_dir():
        raise BuildFailure(f"pinned source cache is missing or unsafe: {source_root}")
    sources: dict[str, pathlib.Path] = {}
    for name, component in components.items():
        destination = source_root / name / component["commit"]
        if destination.is_symlink() or not destination.is_dir():
            raise BuildFailure(
                f"pinned source checkout is missing or unsafe: {destination}"
            )
        validate_clean_checkout(destination, component["commit"])
        sources[name] = destination
    return sources


def verify_fec_header(data: bytes, input_size: int, roots: int = 2) -> int:
    if len(data) < 4096 or len(data) % 4096:
        raise BuildFailure("fec smoke test output has an invalid size")
    fec_size = len(data) - 4096
    expected_size = (
        ((input_size + 4095) // 4096 + (255 - roots) - 1)
        // (255 - roots)
        * roots
        * 4096
    )
    if fec_size != expected_size:
        raise BuildFailure(
            f"fec output is {fec_size} parity bytes, expected {expected_size}"
        )
    primary_offset = fec_size
    duplicate_offset = len(data) - FEC_HEADER.size
    primary = FEC_HEADER.unpack_from(data, primary_offset)
    duplicate = FEC_HEADER.unpack_from(data, duplicate_offset)
    expected = (0xFECFECFE, 0, FEC_HEADER.size, roots, fec_size, input_size)
    if primary[:6] != expected or duplicate[:6] != expected:
        raise BuildFailure("fec smoke test footer header differs from the AOSP format")
    parity_hash = hashlib.sha256(data[:fec_size]).digest()
    if primary[6] != parity_hash or duplicate[6] != parity_hash:
        raise BuildFailure("fec smoke test footer hash does not match its parity data")
    return fec_size


def smoke_test(binary: pathlib.Path, temporary_root: pathlib.Path) -> None:
    size = 4096
    result = run([str(binary), "--print-fec-size", str(size), "--roots", "2"])
    if result.stdout.strip() != "12288":
        raise BuildFailure(
            f"fec --print-fec-size returned unexpected value: {result.stdout!r}"
        )
    result = run([str(binary), "--print-fec-size", str(254 * size), "--roots", "2"])
    if result.stdout.strip() != "20480":
        raise BuildFailure(
            f"fec size boundary probe returned unexpected value: {result.stdout!r}"
        )

    original = bytes((index * 37 + 11) & 0xFF for index in range(size))
    input_path = temporary_root / "fec-input.img"
    fec_path = temporary_root / "fec-output.bin"
    decoded_path = temporary_root / "fec-decoded.img"
    input_path.write_bytes(original)
    run([str(binary), "--encode", "--roots", "2", str(input_path), str(fec_path)])
    fec_data = fec_path.read_bytes()
    verify_fec_header(fec_data, size)
    run(
        [
            str(binary),
            "--decode",
            "--roots",
            "2",
            str(input_path),
            str(fec_path),
            str(decoded_path),
        ]
    )
    if decoded_path.read_bytes() != original:
        raise BuildFailure("fec encode/decode round trip changed the input")


def source_set(
    sources: Mapping[str, pathlib.Path],
) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    aosp = sources["aosp-verity"]
    rs = sources["libfec-rs"]
    main = checked_source_file(aosp, "verity/fec/main.cpp")
    image = checked_source_file(aosp, "verity/fec/image.cpp")
    rs_files = (
        checked_source_file(rs, "encode_rs_char.c"),
        checked_source_file(rs, "decode_rs_char.c"),
        checked_source_file(rs, "init_rs_char.c"),
    )
    return main, image, rs_files


def compile_binary(
    root: pathlib.Path,
    sources: Mapping[str, pathlib.Path],
    staging: pathlib.Path,
    clang: str,
    clangxx: str,
    sdk: str,
) -> pathlib.Path:
    main, image, rs_files = source_set(sources)
    build_env = compiler_environment()
    shim_root = root / "scripts/tools/fec_host/include"
    aosp_includes = sources["aosp-verity"] / "libfec/include"
    rs_source = sources["libfec-rs"]
    common = [
        "-arch",
        "arm64",
        "-isysroot",
        sdk,
        "-mmacosx-version-min=" + MINIMUM_MACOS,
        "-O3",
        "-Wall",
        "-Wextra",
        "-Werror",
    ]
    cxx_common = [
        *common,
        "-std=c++17",
        "-Wno-vla-cxx-extension",
        "-Wno-gnu-zero-variadic-macro-arguments",
        "-I",
        str(shim_root),
        "-I",
        str(aosp_includes),
        "-I",
        str(rs_source),
    ]
    c_common = [
        *common,
        "-std=c11",
        "-I",
        str(shim_root),
        "-I",
        str(aosp_includes),
        "-I",
        str(rs_source),
    ]
    objects: list[pathlib.Path] = []
    for source in rs_files:
        obj = staging / f"{source.stem}.o"
        run([clang, *c_common, "-c", str(source), "-o", str(obj)], env=build_env)
        objects.append(obj)

    binary = staging / "fec"
    run(
        [
            clangxx,
            *cxx_common,
            "-pthread",
            str(main),
            str(image),
            str(root / "scripts/tools/fec_host/sparse_compat.cpp"),
            *(str(path) for path in objects),
            "-Wl,-dead_strip",
            "-o",
            str(binary),
        ],
        env=build_env,
    )
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise BuildFailure("the pinned AOSP source build did not produce an executable")
    return binary


def verify_binary(binary: pathlib.Path, *, lipo: str, otool: str) -> None:
    architectures = run([lipo, "-archs", str(binary)]).stdout.strip().split()
    if architectures != ["arm64"]:
        raise BuildFailure(
            f"FEC binary must contain only arm64 code; found {architectures}"
        )
    lines = run([otool, "-L", str(binary)]).stdout.splitlines()
    dependencies = [line.strip().split()[0] for line in lines[1:] if line.strip()]
    if dependencies != ["/usr/lib/libc++.1.dylib", "/usr/lib/libSystem.B.dylib"]:
        raise BuildFailure(
            f"FEC binary has unexpected dynamic dependencies: {dependencies}"
        )
    probe = run([str(binary), "--help"], allow_failure=True)
    if probe.returncode != 1 or "RS(255, N)" not in probe.stdout:
        raise BuildFailure(
            f"FEC command-line help probe failed (exit {probe.returncode}): {probe.stdout!r}"
        )


def manifest_matches(
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    *,
    inputs_hash: str,
    host: Mapping[str, Any],
    components: Mapping[str, Mapping[str, Any]],
) -> bool:
    if (
        binary.is_symlink()
        or not binary.is_file()
        or manifest.is_symlink()
        or not manifest.is_file()
    ):
        return False
    try:
        record = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(record, dict):
            return False
        source_records = {}
        for name, component in components.items():
            source_records[name] = {
                "repository": component["repository"],
                "pin": component["commit"],
                "version": component["version"],
                "commit": git_output(
                    root / "ThirdParty/out/src" / name / component["commit"],
                    "rev-parse",
                    "--verify",
                    "HEAD^{commit}",
                ),
            }
        expected = {
            "schemaVersion": SCHEMA_VERSION,
            "sources": source_records,
            "inputsSha256": inputs_hash,
            "host": dict(host),
            "flags": list(BUILD_FLAGS),
            "binarySha256": sha256_file(binary),
            "architecture": "arm64",
        }
    except (OSError, ValueError, KeyError, BuildFailure):
        return False
    return record == expected


def verify(root: pathlib.Path) -> pathlib.Path:
    """Verify an existing FEC tool and its provenance without building or fetching."""
    output = root / OUTPUT_RELATIVE
    prefix = output.parent
    if prefix.is_symlink() or not prefix.is_dir():
        raise BuildFailure(
            f"existing FEC output directory is missing or unsafe: {prefix}"
        )
    if output.is_symlink() or not output.is_file():
        raise BuildFailure(f"existing FEC binary is missing or unsafe: {output}")
    manifest = prefix / ".apkrun-fec-build.json"
    if manifest.is_symlink() or not manifest.is_file():
        raise BuildFailure(
            f"existing FEC build manifest is missing or unsafe: {manifest}"
        )

    with verify_lock(prefix / ".build.lock"):
        components = validate_lock(root)
        host, _clang, _clangxx, _sdk = host_environment()
        sources = existing_sources(root, components)
        inputs_hash = hash_inputs(root, sources, components)
        if not manifest_matches(
            root,
            output,
            manifest,
            inputs_hash=inputs_hash,
            host=host,
            components=components,
        ):
            raise BuildFailure(
                "existing FEC build manifest does not match the locked sources, "
                "host, inputs, flags, and binary; run scripts/build-fec-tool.sh to rebuild"
            )
        verify_binary(
            output,
            lipo=executable_path("lipo"),
            otool=executable_path("otool"),
        )
        with tempfile.TemporaryDirectory(prefix="apkrun-fec-verify-") as temp_name:
            smoke_test(output, pathlib.Path(temp_name))
    return output


def build(root: pathlib.Path, *, force: bool = False) -> pathlib.Path:
    components = validate_lock(root)
    host, clang, clangxx, sdk = host_environment()
    sources = {
        name: fetch_source(root, name, component)
        for name, component in components.items()
    }
    inputs_hash = hash_inputs(root, sources, components)
    output = root / OUTPUT_RELATIVE
    prefix = output.parent
    if prefix.is_symlink():
        raise BuildFailure(f"refusing symlinked FEC output directory: {prefix}")
    if prefix.exists() and not prefix.is_dir():
        raise BuildFailure(f"FEC output parent is not a directory: {prefix}")
    prefix.mkdir(parents=True, exist_ok=True)
    manifest = prefix / ".apkrun-fec-build.json"
    if manifest.is_symlink() or output.is_symlink():
        raise BuildFailure(f"refusing symlinked FEC output file: {output}")

    with build_lock(prefix / ".build.lock"):
        if not force and manifest_matches(
            root,
            output,
            manifest,
            inputs_hash=inputs_hash,
            host=host,
            components=components,
        ):
            with tempfile.TemporaryDirectory(prefix="apkrun-fec-check-") as temp_name:
                smoke_test(output, pathlib.Path(temp_name))
            return output

        staging = pathlib.Path(tempfile.mkdtemp(prefix=".fec-build-", dir=prefix))
        try:
            built = compile_binary(root, sources, staging, clang, clangxx, sdk)
            lipo = executable_path("lipo")
            otool = executable_path("otool")
            verify_binary(built, lipo=lipo, otool=otool)
            with tempfile.TemporaryDirectory(prefix="apkrun-fec-smoke-") as temp_name:
                smoke_test(built, pathlib.Path(temp_name))
            record = {
                "schemaVersion": SCHEMA_VERSION,
                "sources": {
                    name: {
                        "repository": component["repository"],
                        "pin": component["commit"],
                        "version": component["version"],
                        "commit": git_output(
                            sources[name], "rev-parse", "--verify", "HEAD^{commit}"
                        ),
                    }
                    for name, component in components.items()
                },
                "inputsSha256": inputs_hash,
                "host": host,
                "flags": list(BUILD_FLAGS),
                "binarySha256": sha256_file(built),
                "architecture": "arm64",
            }
            staged_manifest = staging / ".apkrun-fec-build.json"
            staged_manifest.write_bytes(canonical_json(record) + b"\n")
            os.chmod(built, 0o755)
            os.replace(built, output)
            os.replace(staged_manifest, manifest)
        finally:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
    return output


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        help="repository root (defaults to the parent of scripts/)",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--force",
        action="store_true",
        help="rebuild even if the pinned source and host fingerprint are unchanged",
    )
    modes.add_argument(
        "--verify",
        action="store_true",
        help="verify an existing FEC build without fetching or changing repository files",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_args(argv)
    root = (
        arguments.root.resolve()
        if arguments.root
        else pathlib.Path(__file__).resolve().parents[2]
    )
    try:
        binary = (
            verify(root) if arguments.verify else build(root, force=arguments.force)
        )
    except BuildFailure as error:
        action = "verify-fec-tool" if arguments.verify else "build-fec-tool"
        print(f"{action}: {error}", file=sys.stderr)
        return 1
    print(binary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
