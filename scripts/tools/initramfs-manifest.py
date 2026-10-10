#!/usr/bin/env python3
"""Check the virgl inputs of the Linux test initramfs and write its manifest.

The virgl check (graphics.md §12 step 1, #022) runs kmscube on Mesa's virtio_gpu
driver from pinned Alpine packages. scripts/build-test-initramfs.sh calls this
tool after it unpacks the packages and before it moves the archive into place.
The tool fails unless:

- every package is a prebuilt test-linux component of the lock, its apk has the
  lock's SHA-256, and its version appears in its download URL;
- every required path resolves to a regular file inside the root, following
  relative symlinks only;
- every DT_NEEDED soname of an ELF file that the packages install is a file in
  the root's library directories.

On success it writes a JSON manifest. Its key order is fixed, so the same inputs
give the same bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import tarfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
LIBRARY_DIRECTORIES = ("lib", "usr/lib")
ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1
PT_DYNAMIC = 2
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
MAX_SYMLINK_HOPS = 32


class ManifestError(Exception):
    """A check failed. The message names the input that failed."""


def read_list(path: Path) -> list[str]:
    entries: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    if len(set(entries)) != len(entries):
        raise ManifestError(f"{path}: an entry is listed more than once")
    return entries


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_components(lock_path: Path) -> dict[str, dict[str, Any]]:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    return {component["name"]: component for component in lock["components"]}


def check_package(name: str, components: dict[str, dict[str, Any]], downloads: Path) -> dict[str, Any]:
    component = components.get(name)
    if component is None:
        raise ManifestError(f"package is not in the lock: {name}")
    if component.get("group") != "test-linux" or component.get("kind") != "prebuilt":
        raise ManifestError(f"package is not a prebuilt test-linux component: {name}")
    url = component.get("url", "")
    version = component.get("version", "")
    if not url.startswith("https://") or not version:
        raise ManifestError(f"package has no HTTPS URL or version in the lock: {name}")
    file_name = url.rsplit("/", 1)[-1]
    if not file_name.endswith(f"-{version}.apk"):
        raise ManifestError(f"package version {version} is not in its URL: {name}")
    apk = downloads / file_name
    if not apk.is_file():
        raise ManifestError(f"package is not downloaded: {apk}")
    actual = sha256_file(apk)
    if actual != component.get("sha256"):
        raise ManifestError(f"SHA-256 mismatch for {name} ({apk})")
    return {"name": name, "version": version, "url": url, "sha256": actual, "apk": apk}


def resolve_inside(root: Path, relative: str) -> str:
    """Returns the root-relative path of the regular file that `relative` names.

    Symlinks in any component are followed, but only relative targets that stay
    inside the root are accepted, so the host file system is never read.
    """
    if relative.startswith("/"):
        raise ManifestError(f"required path is absolute: {relative}")
    pending = [part for part in relative.split("/") if part not in ("", ".")]
    resolved: list[str] = []
    hops = 0
    while pending:
        part = pending.pop(0)
        if part == "..":
            if not resolved:
                raise ManifestError(f"required path leaves the root: {relative}")
            resolved.pop()
            continue
        candidate = root.joinpath(*resolved, part)
        if candidate.is_symlink():
            hops += 1
            if hops > MAX_SYMLINK_HOPS:
                raise ManifestError(f"required path has too many symlinks: {relative}")
            target = os.readlink(candidate)
            if target.startswith("/"):
                raise ManifestError(f"required path has an absolute symlink: {relative}")
            pending = [item for item in target.split("/") if item not in ("", ".")] + pending
            continue
        resolved.append(part)
    final = root.joinpath(*resolved)
    if not resolved or final.is_symlink() or not final.is_file():
        raise ManifestError(f"required file is missing from the initramfs root: {relative}")
    return "/".join(resolved)


def read_needed(path: Path) -> list[str]:
    """Returns the DT_NEEDED sonames of a little-endian ELF64 file, or [] if it is not ELF."""
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:4] != ELF_MAGIC:
            return []
        if header[4] != 2 or header[5] != 1:
            raise ManifestError(f"ELF file is not little-endian ELF64: {path}")
        (program_offset,) = struct.unpack_from("<Q", header, 0x20)
        entry_size, entry_count = struct.unpack_from("<HH", header, 0x36)
        stream.seek(program_offset)
        program_headers = stream.read(entry_size * entry_count)
        loads: list[tuple[int, int, int]] = []
        dynamic: tuple[int, int] | None = None
        for index in range(entry_count):
            fields = struct.unpack_from("<IIQQQQQQ", program_headers, index * entry_size)
            p_type, p_offset, p_vaddr, p_filesz = fields[0], fields[2], fields[3], fields[5]
            if p_type == PT_LOAD:
                loads.append((p_vaddr, p_offset, p_filesz))
            elif p_type == PT_DYNAMIC:
                dynamic = (p_offset, p_filesz)
        if dynamic is None:
            return []

        def to_offset(address: int) -> int:
            for start, offset, size in loads:
                if start <= address < start + size:
                    return address - start + offset
            raise ManifestError(f"ELF address is outside its loadable segments: {path}")

        stream.seek(dynamic[0])
        entries = stream.read(dynamic[1])
        needed_offsets: list[int] = []
        strtab = strsz = None
        for index in range(len(entries) // 16):
            tag, value = struct.unpack_from("<qQ", entries, index * 16)
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                needed_offsets.append(value)
            elif tag == DT_STRTAB:
                strtab = value
            elif tag == DT_STRSZ:
                strsz = value
        if not needed_offsets:
            return []
        if strtab is None or strsz is None:
            raise ManifestError(f"ELF file has DT_NEEDED without a string table: {path}")
        stream.seek(to_offset(strtab))
        table = stream.read(strsz)
        names: list[str] = []
        for offset in needed_offsets:
            end = table.find(b"\0", offset)
            if end < 0:
                raise ManifestError(f"DT_NEEDED name is not terminated: {path}")
            names.append(table[offset:end].decode("ascii"))
        return names


def installed_regular_files(apk: Path) -> list[str]:
    """The paths of the regular files and hard links that an apk installs.

    apk metadata is a top-level dot entry (.PKGINFO, .SIGN.*), and it is skipped.
    A leading "./" is removed from a member name.
    """
    names: list[str] = []
    with tarfile.open(apk, "r:gz") as archive:
        for member in archive.getmembers():
            if not (member.isfile() or member.islnk()):
                continue
            name = member.name[2:] if member.name.startswith("./") else member.name
            if name.split("/", 1)[0].startswith("."):
                continue
            names.append(name)
    return names


def provided_libraries(root: Path) -> set[str]:
    """The names in the library directories that resolve to a regular file inside the root."""
    provided: set[str] = set()
    for directory in LIBRARY_DIRECTORIES:
        path = root / directory
        if not path.is_dir():
            continue
        for entry in path.iterdir():
            try:
                resolve_inside(root, f"{directory}/{entry.name}")
            except ManifestError:
                continue
            provided.add(entry.name)
    return provided


def check_needed_libraries(root: Path, packages: list[dict[str, Any]]) -> list[str]:
    provided = provided_libraries(root)
    needed: set[str] = set()
    missing: list[str] = []
    for package in packages:
        for member in installed_regular_files(package["apk"]):
            path = root / member
            if path.is_symlink() or not path.is_file():
                continue
            for soname in read_needed(path):
                needed.add(soname)
                if soname not in provided:
                    missing.append(f"{soname} (needed by {member})")
    if missing:
        raise ManifestError("DT_NEEDED soname is not in the initramfs root: " + "; ".join(sorted(missing)))
    return sorted(needed)


def build_manifest(
    root: Path,
    lock: Path,
    packages_list: Path,
    paths_list: Path,
    downloads: Path,
    cpio: Path,
) -> dict[str, Any]:
    components = load_components(lock)
    package_names = read_list(packages_list)
    if not package_names:
        raise ManifestError(f"{packages_list}: the package list is empty")
    packages = [check_package(name, components, downloads) for name in package_names]

    required: list[dict[str, Any]] = []
    for relative in read_list(paths_list):
        resolved = resolve_inside(root, relative)
        path = root / resolved
        required.append(
            {
                "path": relative,
                "resolvedPath": resolved,
                "sha256": sha256_file(path),
                "bytes": path.stat().st_size,
            }
        )

    needed = check_needed_libraries(root, packages)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "initramfs": {"sha256": sha256_file(cpio), "bytes": cpio.stat().st_size},
        "packages": [
            {key: package[key] for key in ("name", "version", "url", "sha256")}
            for package in packages
        ],
        "requiredPaths": required,
        "neededLibraries": needed,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True, type=Path, help="unpacked initramfs root")
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--packages", required=True, type=Path, help="virgl-packages.list")
    parser.add_argument("--paths", required=True, type=Path, help="virgl-paths.list")
    parser.add_argument("--downloads", required=True, type=Path)
    parser.add_argument("--cpio", required=True, type=Path, help="gzip-compressed initramfs")
    parser.add_argument("--output", required=True, type=Path, help="manifest to write")
    args = parser.parse_args(argv)
    try:
        manifest = build_manifest(
            args.root,
            args.lock,
            args.packages,
            args.paths,
            args.downloads,
            args.cpio,
        )
    except (ManifestError, OSError, ValueError, KeyError, tarfile.TarError, struct.error) as error:
        print(f"initramfs-manifest: {error}", file=sys.stderr)
        return 1
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
