"""EROFS support for the Android image tools: pinned erofs-utils, tree export, and rebuilds (#099).

The binaries are the erofs-utils bottle of `ThirdParty/ThirdParty.lock.json` (component `erofs-
utils`). Each binary's SHA-256 is checked before it runs. A tree is exported with `fsck.erofs
--extract --xattrs`. The owner, mode, and timestamp of each entry come from `dump.erofs --path`,
because a host that is not root cannot restore them. A rebuild writes a PAX tar that carries the
same metadata and the `security.selinux` labels, and `mkfs.erofs --tar=f` builds the image from it.
Nothing here runs a VM.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from apkrun_image.manifest import _load_json, _repository_root

COMPONENT = "erofs-utils"
SELINUX_XATTR = "security.selinux"
# macOS adds this name to files it creates. It is not part of an image, so it is not compared.
HOST_XATTRS_IGNORED = frozenset({"com.apple.provenance"})
DIRECTORY = "directory"
REGULAR_FILE = "regular file"
SYMLINK = "symlink file"
ENTRY_KINDS = (DIRECTORY, REGULAR_FILE, SYMLINK)
BLOCK_SIZE = 4096
COPY_CHUNK = 1024 * 1024
MKFS_COMPRESSION = "lz4hc,9"

_DUMP_SIZE = re.compile(
    r"^Size: (\d+)\s+On-disk size: \d+\s+(regular file|directory|symlink file)$", re.MULTILINE
)
_DUMP_OWNER = re.compile(r"^Uid: (\d+)\s+Gid: (\d+)\s+Access: ([0-7]{3,4})/", re.MULTILINE)
_DUMP_TIME = re.compile(r"^Timestamp: (.+)$", re.MULTILINE)
_DUMP_BLOCKS = re.compile(r"^Filesystem blocks:\s+(\d+)$", re.MULTILINE)
_DUMP_BLOCK_SIZE = re.compile(r"^Filesystem blocksize:\s+(\d+)$", re.MULTILINE)
_DUMP_INODES = re.compile(r"^Filesystem inode count:\s+(\d+)$", re.MULTILINE)
_GHCR_REPOSITORY = re.compile(r"^/v2/(.+)/blobs/sha256:[0-9a-f]{64}$")


class ErofsError(ValueError):
    """The erofs-utils tools, an EROFS image, or a rebuild is invalid."""


@dataclass(frozen=True)
class ErofsTools:
    """Verified erofs-utils binaries under one root directory (its `bin/` holds them)."""

    root: Path
    version: str

    @property
    def mkfs(self) -> Path:
        """Return the mkfs.erofs binary."""
        return self.root / "bin" / "mkfs.erofs"

    @property
    def fsck(self) -> Path:
        """Return the fsck.erofs binary."""
        return self.root / "bin" / "fsck.erofs"

    @property
    def dump(self) -> Path:
        """Return the dump.erofs binary."""
        return self.root / "bin" / "dump.erofs"


@dataclass(frozen=True)
class Entry:
    """One EROFS inode as seen through dump.erofs and the exported host tree."""

    path: str
    kind: str
    mode: int
    uid: int
    gid: int
    size: int
    mtime: str
    target: str | None = None
    sha256: str | None = None
    label: str | None = None


@dataclass(frozen=True)
class TarMember:
    """One member of the PAX tar that `mkfs.erofs --tar=f` turns into an image."""

    path: str
    kind: str
    mode: int
    uid: int
    gid: int
    mtime: int
    target: str | None = None
    label: str | None = None
    source: Path | None = None


def sha256_file(path: Path) -> str:
    """Return the SHA-256 of a file, read in chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(COPY_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_component(name: str = COMPONENT, lock_path: Path | None = None) -> dict[str, Any]:
    """Return one named component of the ThirdParty lock (erofs-utils by default)."""
    path = lock_path or _repository_root() / "ThirdParty" / "ThirdParty.lock.json"
    document = _load_json(path, description="ThirdParty lock")
    components = document.get("components") if isinstance(document, dict) else None
    if not isinstance(components, list):
        raise ErofsError(f"{path}: components is missing.")
    for component in components:
        if isinstance(component, dict) and component.get("name") == name:
            return component
    raise ErofsError(f"{path}: no {name} component is pinned.")


def _run(
    argv: Sequence[str | os.PathLike[str]], description: str
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(part) for part in argv], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        tail = result.stderr.strip().splitlines()[-3:]
        raise ErofsError(f"{description} failed with exit {result.returncode}: {' | '.join(tail)}")
    if "<E>" in result.stderr or "<E>" in result.stdout:
        raise ErofsError(f"{description} reported an EROFS error: {result.stderr.strip()[-300:]}")
    return result


def verify_tools(root: Path, component: Mapping[str, Any] | None = None) -> ErofsTools:
    """Check every pinned binary under `root` by SHA-256, then check the reported version."""
    pinned = component or load_component()
    version = pinned.get("version")
    binaries = pinned.get("binaries")
    if not isinstance(version, str) or not isinstance(binaries, list) or not binaries:
        raise ErofsError("the erofs-utils lock entry has no version or binaries.")
    for binary in binaries:
        relative = binary.get("path") if isinstance(binary, dict) else None
        expected = binary.get("sha256") if isinstance(binary, dict) else None
        if not isinstance(relative, str) or not isinstance(expected, str):
            raise ErofsError("an erofs-utils binary entry in the lock is malformed.")
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise ErofsError(f"{path}: erofs-utils binary is missing. Run `erofs-tools` first.")
        actual = sha256_file(path)
        if actual != expected:
            raise ErofsError(
                f"{path}: SHA-256 {actual} differs from the lock ({expected}). "
                "Fetch the pinned bottle again with `erofs-tools`."
            )
    tools = ErofsTools(root=root, version=version)
    reported = _run([tools.mkfs, "-V"], "mkfs.erofs -V").stdout
    if f"(erofs-utils) {version}" not in reported:
        raise ErofsError(f"mkfs.erofs reports {reported.strip()!r}, not erofs-utils {version}.")
    return tools


def image_geometry(tools: ErofsTools, image: Path) -> tuple[int, int, int]:
    """Return (block size, block count, inode count) from the superblock."""
    text = _run([tools.dump, "-s", image], "dump.erofs -s").stdout
    sizes = _DUMP_BLOCK_SIZE.search(text)
    blocks = _DUMP_BLOCKS.search(text)
    inodes = _DUMP_INODES.search(text)
    if not (sizes and blocks and inodes):
        raise ErofsError(f"{image}: dump.erofs did not report the superblock.")
    return int(sizes.group(1)), int(blocks.group(1)), int(inodes.group(1))


def export_tree(tools: ErofsTools, image: Path, destination: Path) -> None:
    """Extract every file of `image` into `destination` with its xattrs (it must not exist)."""
    if destination.exists() or destination.is_symlink():
        raise ErofsError(f"{destination}: export destination already exists.")
    _run(
        [tools.fsck, f"--extract={destination}", "--xattrs", "--no-preserve", image],
        "fsck.erofs --extract",
    )


def extract_file(tools: ErofsTools, image: Path, erofs_path: str, destination: Path) -> None:
    """Extract one file of `image` to `destination` (the file must not exist)."""
    if destination.exists() or destination.is_symlink():
        raise ErofsError(f"{destination}: extraction destination already exists.")
    _run(
        [tools.fsck, f"--extract={destination}", f"--path={erofs_path}", image],
        "fsck.erofs --extract --path",
    )
    if not destination.is_file():
        raise ErofsError(f"{erofs_path}: fsck.erofs did not write a regular file.")


def parse_dump_inode(text: str, erofs_path: str) -> dict[str, Any]:
    """Parse the text of `dump.erofs --path` for one inode."""
    size = _DUMP_SIZE.search(text)
    owner = _DUMP_OWNER.search(text)
    stamp = _DUMP_TIME.search(text)
    if not (size and owner and stamp):
        raise ErofsError(f"{erofs_path}: dump.erofs output is not an inode this tool understands.")
    return {
        "kind": size.group(2),
        "size": int(size.group(1)),
        "uid": int(owner.group(1)),
        "gid": int(owner.group(2)),
        "mode": int(owner.group(3), 8) & 0o7777,
        "mtime": stamp.group(1).strip(),
    }


def _dump_inode(tools: ErofsTools, image: Path, erofs_path: str) -> dict[str, Any]:
    text = _run([tools.dump, f"--path={erofs_path}", image], "dump.erofs --path").stdout
    return parse_dump_inode(text, erofs_path)


def _host_xattr_names(path: Path) -> list[str]:
    """Return the xattr names of a host path, without following a symlink."""
    if hasattr(os, "listxattr"):
        return list(os.listxattr(path, follow_symlinks=False))  # type: ignore[attr-defined]
    listing = subprocess.run(
        ["/usr/bin/xattr", "-s", str(path)], capture_output=True, text=True, check=True
    ).stdout
    return listing.split()


def _host_xattr_value(path: Path, name: str) -> str:
    """Return one xattr value of a host path as text (the labels are ASCII)."""
    if hasattr(os, "getxattr"):
        return os.getxattr(path, name, follow_symlinks=False).decode("utf-8")  # type: ignore[attr-defined]
    value = subprocess.run(
        ["/usr/bin/xattr", "-s", "-p", name, str(path)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return value[:-1] if value.endswith("\n") else value


def _host_selinux_label(path: Path) -> str | None:
    """Return the SELinux label of a host path, refusing any other xattr the rebuild would drop."""
    names = [name for name in _host_xattr_names(path) if name not in HOST_XATTRS_IGNORED]
    unexpected = sorted(name for name in names if name != SELINUX_XATTR)
    if unexpected:
        raise ErofsError(f"{path}: unexpected xattr {unexpected[0]!r}; the rebuild cannot keep it.")
    if SELINUX_XATTR not in names:
        return None
    return _host_xattr_value(path, SELINUX_XATTR)


def read_tree(tools: ErofsTools, image: Path, tree: Path) -> dict[str, Entry]:
    """Describe every entry of `image` from dump.erofs and the exported `tree`, by EROFS path."""
    paths = ["/"]
    for root, dirs, files in os.walk(tree):
        relative = os.path.relpath(root, tree)
        for name in dirs + files:
            paths.append("/" + (name if relative == "." else os.path.join(relative, name)))
    _, _, inode_count = image_geometry(tools, image)
    if len(paths) != inode_count:
        raise ErofsError(
            f"{image}: the export has {len(paths)} entries, the superblock counts {inode_count}."
        )
    entries: dict[str, Entry] = {}
    for erofs_path in paths:
        inode = _dump_inode(tools, image, erofs_path)
        host = tree if erofs_path == "/" else tree / erofs_path.lstrip("/")
        is_link = host.is_symlink()
        if is_link and inode["kind"] != SYMLINK:
            raise ErofsError(
                f"{erofs_path}: exported as a symlink but the image has {inode['kind']}."
            )
        target = None
        digest = None
        if inode["kind"] == SYMLINK:
            target = os.readlink(host)
        elif inode["kind"] == REGULAR_FILE:
            if host.stat().st_size != inode["size"]:
                raise ErofsError(f"{erofs_path}: exported size differs from the image.")
            digest = sha256_file(host)
        elif inode["kind"] != DIRECTORY:
            raise ErofsError(f"{erofs_path}: unsupported inode kind {inode['kind']!r}.")
        entries[erofs_path] = Entry(
            path=erofs_path,
            kind=inode["kind"],
            mode=inode["mode"],
            uid=inode["uid"],
            gid=inode["gid"],
            size=inode["size"],
            mtime=inode["mtime"],
            target=target,
            sha256=digest,
            label=_host_selinux_label(host),
        )
    return entries


def tree_members(entries: Mapping[str, Entry], tree: Path, timestamp: int) -> list[TarMember]:
    """Turn exported entries into tar members that keep their metadata and labels."""
    members: list[TarMember] = []
    for path in sorted(entries):
        entry = entries[path]
        source = None if entry.kind != REGULAR_FILE else tree / path.lstrip("/")
        members.append(
            TarMember(
                path=path,
                kind=entry.kind,
                mode=entry.mode,
                uid=entry.uid,
                gid=entry.gid,
                mtime=timestamp,
                target=entry.target,
                label=entry.label,
                source=source,
            )
        )
    return members


def write_tar(members: Iterable[TarMember], tar_path: Path) -> int:
    """Write the members as a PAX tar, with the labels as SCHILY xattrs. Return the member count."""
    count = 0
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as archive:
        for member in members:
            name = "." if member.path == "/" else "." + member.path
            info = tarfile.TarInfo(name)
            info.mode = member.mode
            info.uid = member.uid
            info.gid = member.gid
            info.mtime = member.mtime
            if member.label is not None:
                info.pax_headers = {f"SCHILY.xattr.{SELINUX_XATTR}": member.label}
            if member.kind == DIRECTORY:
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            elif member.kind == SYMLINK:
                if member.target is None:
                    raise ErofsError(f"{member.path}: symlink without a target.")
                info.type = tarfile.SYMTYPE
                info.linkname = member.target
                archive.addfile(info)
            elif member.kind == REGULAR_FILE:
                if member.source is None:
                    raise ErofsError(f"{member.path}: regular file without content.")
                info.type = tarfile.REGTYPE
                info.size = member.source.stat().st_size
                with member.source.open("rb") as handle:
                    archive.addfile(info, handle)
            else:
                raise ErofsError(f"{member.path}: unsupported kind {member.kind!r}.")
            count += 1
    return count


def build_image(
    tools: ErofsTools,
    tar_path: Path,
    output: Path,
    *,
    timestamp: int,
    uuid: str,
) -> None:
    """Build an EROFS image from a PAX tar with fixed timestamps, UUID, and block size."""
    if output.exists():
        raise ErofsError(f"{output}: image output already exists.")
    _run(
        [
            tools.mkfs,
            "--tar=f",
            "-T",
            str(timestamp),
            f"-z{MKFS_COMPRESSION}",
            "-b",
            str(BLOCK_SIZE),
            "-U",
            uuid,
            "-d1",
            output,
            tar_path,
        ],
        "mkfs.erofs --tar=f",
    )


def _download(url: str, target: Path) -> None:
    """Download a bottle. A ghcr.io blob needs the registry's anonymous pull token."""
    parsed = urllib.parse.urlparse(url)
    request = urllib.request.Request(url)
    match = _GHCR_REPOSITORY.match(parsed.path)
    if parsed.hostname == "ghcr.io" and match:
        token_url = f"https://ghcr.io/token?service=ghcr.io&scope=repository:{match.group(1)}:pull"
        with urllib.request.urlopen(token_url, timeout=60) as response:  # noqa: S310
            token = json.loads(response.read().decode("utf-8")).get("token")
        if not isinstance(token, str) or not token:
            raise ErofsError("the registry returned no anonymous pull token.")
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=600) as response:  # noqa: S310
        with target.open("wb") as handle:
            for chunk in iter(lambda: response.read(COPY_CHUNK), b""):
                handle.write(chunk)


def _safe_member_name(name: str) -> str:
    parts = name.split("/")
    if name.startswith("/") or any(part in {"", ".", ".."} for part in parts):
        raise ErofsError(f"unsafe member name in the bottle: {name!r}")
    return name


def fetch_tools(destination: Path, *, component: Mapping[str, Any] | None = None) -> ErofsTools:
    """Download the pinned bottle, check it, unpack it, relocate it, and verify every binary.

    The bottle's binaries name Homebrew's library paths with a placeholder. The lock lists the
    exact `install_name_tool -change` pairs, and each binary is ad-hoc signed again after that.
    """
    pinned = dict(component or load_component())
    url = pinned.get("url")
    expected = pinned.get("sha256")
    version = pinned.get("version")
    if not (isinstance(url, str) and isinstance(expected, str) and isinstance(version, str)):
        raise ErofsError("the erofs-utils lock entry has no url, sha256, or version.")
    if destination.exists() and any(destination.iterdir()):
        raise ErofsError(f"{destination}: fetch destination is not empty.")
    destination.mkdir(parents=True, exist_ok=True)
    prefix = f"{COMPONENT}/{version}/"
    with tempfile.TemporaryDirectory(prefix="apkrun-erofs-fetch-") as scratch:
        bottle = Path(scratch) / "bottle.tar.gz"
        _download(url, bottle)
        digest = sha256_file(bottle)
        if digest != expected:
            raise ErofsError(f"the bottle SHA-256 {digest} differs from the lock ({expected}).")
        with tarfile.open(bottle, "r:gz") as archive:
            for member in archive.getmembers():
                name = _safe_member_name(member.name)
                if not name.startswith(prefix):
                    continue
                relative = name[len(prefix) :]
                if relative == "" or not member.isfile():
                    continue
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ErofsError(f"unreadable bottle member {name}")
                with source, target.open("wb") as handle:
                    handle.write(source.read())
                target.chmod(0o755 if relative.startswith("bin/") else 0o644)
    _relocate(destination, pinned)
    return verify_tools(destination, pinned)


def _relocate(root: Path, component: Mapping[str, Any]) -> None:
    changes = component.get("relocation") or []
    if not changes:
        return
    binaries = [root / entry["path"] for entry in component.get("binaries", [])]
    for binary in binaries:
        for change in changes:
            _run(
                ["/usr/bin/install_name_tool", "-change", change["from"], change["to"], binary],
                "install_name_tool -change",
            )
        _run(["/usr/bin/codesign", "--force", "-s", "-", binary], "codesign")


def main(argv: Sequence[str] | None = None) -> int:
    """Fetch and verify the pinned erofs-utils tools."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image erofs-tools",
        description="Fetch the pinned erofs-utils bottle, relocate it, and verify its binaries.",
    )
    parser.add_argument(
        "--out", required=True, type=Path, help="directory to create (must be empty)"
    )
    arguments = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        tools = fetch_tools(arguments.out.expanduser().resolve())
    except (ErofsError, OSError, tarfile.TarError) as error:
        print(f"erofs-tools: {error}", file=sys.stderr)
        return 1
    print(f"erofs-tools: erofs-utils {tools.version} verified under {tools.root}")
    return 0
