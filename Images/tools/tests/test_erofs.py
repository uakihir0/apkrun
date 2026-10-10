"""Tests for the pinned erofs-utils wrapper and the PAX rebuild (#099).

The tests that do not need the tools run everywhere: the dump parser, the PAX tar writer, the
checks of pinned binaries, and the fetch path on a local bottle. The round-trip tests need a
fetched erofs-utils, and they run when APKRUN_EROFS_UTILS names its root (`python3 -m apkrun_image
erofs-tools --out DIR`).
"""

from __future__ import annotations

import hashlib
import os
import stat
import tarfile
from pathlib import Path

import pytest

from apkrun_image.erofs import (
    BLOCK_SIZE,
    DIRECTORY,
    REGULAR_FILE,
    SYMLINK,
    ErofsError,
    ErofsTools,
    TarMember,
    build_image,
    export_tree,
    fetch_tools,
    image_geometry,
    parse_dump_inode,
    read_tree,
    tree_members,
    verify_tools,
    write_tar,
)

TOOLS_ROOT = os.environ.get("APKRUN_EROFS_UTILS")
BINARIES = ("mkfs.erofs", "fsck.erofs", "dump.erofs")
FIXED_UUID = "11111111-2222-4333-8444-555555555555"

DUMP_FILE = """Path : /lib64/libdrm.so
Size: 133736  On-disk size: 57344  regular file
NID: 8858982   Links: 1   Layout: 3   Compression ratio: 42.88%
Inode size: 32   Xattr size: 16
Uid: 0   Gid: 0  Access: 0644/rw-r--r--
Timestamp: 2009-01-01 09:00:00.000000000
"""
DUMP_LINK = """Path : /bin/sh
Size: 13  On-disk size: 13  symlink file
NID: 1234   Links: 1   Layout: 2   Compression ratio: 100.00%
Inode size: 32   Xattr size: 16
Uid: 0   Gid: 2000  Access: 0755/rwxr-xr-x
Timestamp: 2009-01-01 09:00:00.000000000
"""


def _script(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def fake_tools(root: Path, *, version: str = "1.9.4") -> dict[str, object]:
    """Write stand-in binaries under `root/bin` and return a lock entry that pins them."""
    binaries = []
    for name in BINARIES:
        body = "#!/bin/sh\n"
        if name == "mkfs.erofs":
            body += f'echo "mkfs.erofs (erofs-utils) {version}"\n'
        body += f"echo fake {name}\n"
        path = root / "bin" / name
        _script(path, body)
        binaries.append(
            {"path": f"bin/{name}", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        )
    return {"name": "erofs-utils", "version": "1.9.4", "binaries": binaries}


def test_a_dump_of_a_regular_file_gives_its_metadata() -> None:
    inode = parse_dump_inode(DUMP_FILE, "/lib64/libdrm.so")
    assert inode == {
        "kind": REGULAR_FILE,
        "size": 133736,
        "uid": 0,
        "gid": 0,
        "mode": 0o644,
        "mtime": "2009-01-01 09:00:00.000000000",
    }


def test_a_dump_of_a_symlink_keeps_its_mode_and_group() -> None:
    inode = parse_dump_inode(DUMP_LINK, "/bin/sh")
    assert inode["kind"] == SYMLINK
    assert (inode["uid"], inode["gid"], inode["mode"]) == (0, 2000, 0o755)


def test_an_inode_the_tool_does_not_understand_is_refused() -> None:
    with pytest.raises(ErofsError, match="not an inode this tool understands"):
        parse_dump_inode("Path : /dev/x\n", "/dev/x")


def test_pinned_binaries_are_checked_by_hash_and_version(tmp_path: Path) -> None:
    component = fake_tools(tmp_path / "good")
    tools = verify_tools(tmp_path / "good", component)
    assert tools == ErofsTools(root=tmp_path / "good", version="1.9.4")


def test_a_binary_that_differs_from_the_lock_is_refused(tmp_path: Path) -> None:
    component = fake_tools(tmp_path / "tampered")
    _script(tmp_path / "tampered" / "bin" / "fsck.erofs", "#!/bin/sh\necho evil\n")
    with pytest.raises(ErofsError, match="differs from the lock"):
        verify_tools(tmp_path / "tampered", component)


def test_a_different_version_is_refused(tmp_path: Path) -> None:
    component = fake_tools(tmp_path / "old", version="1.8.0")
    component["version"] = "1.9.4"
    with pytest.raises(ErofsError, match="not erofs-utils 1.9.4"):
        verify_tools(tmp_path / "old", component)


def test_a_missing_binary_is_refused(tmp_path: Path) -> None:
    component = fake_tools(tmp_path / "missing")
    (tmp_path / "missing" / "bin" / "dump.erofs").unlink()
    with pytest.raises(ErofsError, match="erofs-utils binary is missing"):
        verify_tools(tmp_path / "missing", component)


def _bottle(directory: Path, component: dict[str, object]) -> Path:
    """Pack fake binaries into a bottle shaped like Homebrew's (erofs-utils/<version>/bin/...)."""
    bottle = directory / "bottle.tar.gz"
    staging = directory / "staging" / "erofs-utils" / "1.9.4"
    for entry in component["binaries"]:  # type: ignore[index]
        source = directory / "fake" / entry["path"]  # type: ignore[index]
        staging_path = staging / entry["path"]  # type: ignore[index]
        staging_path.parent.mkdir(parents=True, exist_ok=True)
        staging_path.write_bytes(source.read_bytes())
    (staging / "COPYING").write_text("licence\n", encoding="utf-8")
    with tarfile.open(bottle, "w:gz") as archive:
        archive.add(directory / "staging" / "erofs-utils", arcname="erofs-utils")
    return bottle


def test_fetch_checks_the_bottle_and_the_binaries(tmp_path: Path) -> None:
    fake = fake_tools(tmp_path / "fake")
    bottle = _bottle(tmp_path, {"binaries": fake["binaries"]})
    component = {
        "name": "erofs-utils",
        "version": "1.9.4",
        "url": bottle.resolve().as_uri(),
        "sha256": hashlib.sha256(bottle.read_bytes()).hexdigest(),
        "binaries": fake["binaries"],
        "relocation": [],
    }
    tools = fetch_tools(tmp_path / "fetched", component=component)
    assert tools.version == "1.9.4"
    assert (tmp_path / "fetched" / "bin" / "mkfs.erofs").is_file()
    assert (tmp_path / "fetched" / "COPYING").read_text(encoding="utf-8") == "licence\n"


def test_fetch_refuses_a_bottle_with_another_hash(tmp_path: Path) -> None:
    fake = fake_tools(tmp_path / "fake")
    bottle = _bottle(tmp_path, {"binaries": fake["binaries"]})
    component = {
        "name": "erofs-utils",
        "version": "1.9.4",
        "url": bottle.resolve().as_uri(),
        "sha256": "0" * 64,
        "binaries": fake["binaries"],
        "relocation": [],
    }
    with pytest.raises(ErofsError, match="differs from the lock"):
        fetch_tools(tmp_path / "fetched", component=component)


def test_fetch_refuses_a_member_that_escapes_the_bottle(tmp_path: Path) -> None:
    evil = tmp_path / "evil.tar.gz"
    payload = tmp_path / "payload"
    payload.write_text("x", encoding="utf-8")
    with tarfile.open(evil, "w:gz") as archive:
        archive.add(payload, arcname="erofs-utils/1.9.4/../../escape")
    component = {
        "name": "erofs-utils",
        "version": "1.9.4",
        "url": evil.resolve().as_uri(),
        "sha256": hashlib.sha256(evil.read_bytes()).hexdigest(),
        "binaries": [],
        "relocation": [],
    }
    with pytest.raises(ErofsError, match="unsafe member name"):
        fetch_tools(tmp_path / "fetched", component=component)


def test_the_pax_writer_keeps_owner_mode_target_and_label(tmp_path: Path) -> None:
    source = tmp_path / "libgallium_dri.so"
    source.write_bytes(b"\x7fELF-test")
    members = [
        TarMember("/", DIRECTORY, 0o755, 0, 2000, 1230768000, label="u:object_r:vendor_file:s0"),
        TarMember("/lib64", DIRECTORY, 0o755, 0, 0, 1230768000, label="u:object_r:vendor_file:s0"),
        TarMember(
            "/lib64/egl/libgallium_dri.so",
            REGULAR_FILE,
            0o644,
            0,
            0,
            1230768000,
            label="u:object_r:same_process_hal_file:s0",
            source=source,
        ),
        TarMember("/bin/sh", SYMLINK, 0o755, 0, 2000, 1230768000, target="toybox_vendor"),
    ]
    tar_path = tmp_path / "out.tar"
    assert write_tar(members, tar_path) == 4
    with tarfile.open(tar_path) as archive:
        by_name = {member.name: member for member in archive.getmembers()}
        assert set(by_name) == {".", "./lib64", "./lib64/egl/libgallium_dri.so", "./bin/sh"}
        lib = by_name["./lib64/egl/libgallium_dri.so"]
        assert (lib.mode, lib.uid, lib.gid, lib.mtime) == (0o644, 0, 0, 1230768000)
        assert (
            lib.pax_headers["SCHILY.xattr.security.selinux"]
            == "u:object_r:same_process_hal_file:s0"
        )
        assert by_name["./bin/sh"].linkname == "toybox_vendor"
        assert by_name["./bin/sh"].gid == 2000
        assert archive.extractfile(lib).read() == b"\x7fELF-test"  # type: ignore[union-attr]


def test_the_pax_writer_refuses_a_regular_file_without_content(tmp_path: Path) -> None:
    with pytest.raises(ErofsError, match="without content"):
        write_tar([TarMember("/x", REGULAR_FILE, 0o644, 0, 0, 1)], tmp_path / "bad.tar")


def test_tree_members_are_sorted_and_point_at_their_content(tmp_path: Path) -> None:
    from apkrun_image.erofs import Entry

    tree = tmp_path / "tree"
    (tree / "lib64").mkdir(parents=True)
    (tree / "lib64" / "a.so").write_bytes(b"a")
    entries = {
        "/lib64/a.so": Entry("/lib64/a.so", REGULAR_FILE, 0o644, 0, 0, 1, "t", sha256="x"),
        "/": Entry("/", DIRECTORY, 0o755, 0, 0, 0, "t"),
        "/lib64": Entry("/lib64", DIRECTORY, 0o755, 0, 0, 0, "t"),
    }
    members = tree_members(entries, tree, 42)
    assert [member.path for member in members] == ["/", "/lib64", "/lib64/a.so"]
    assert members[2].source == tree / "lib64" / "a.so"
    assert members[0].source is None and members[2].mtime == 42


def test_the_builder_refuses_an_existing_output(tmp_path: Path) -> None:
    (tmp_path / "exists.img").write_bytes(b"")
    tools = ErofsTools(root=tmp_path, version="1.9.4")
    with pytest.raises(ErofsError, match="already exists"):
        build_image(
            tools, tmp_path / "x.tar", tmp_path / "exists.img", timestamp=0, uuid=FIXED_UUID
        )


def test_the_export_refuses_an_existing_destination(tmp_path: Path) -> None:
    tools = ErofsTools(root=tmp_path, version="1.9.4")
    (tmp_path / "dest").mkdir()
    with pytest.raises(ErofsError, match="already exists"):
        export_tree(tools, tmp_path / "x.img", tmp_path / "dest")


def _real_tools() -> ErofsTools:
    if not TOOLS_ROOT:
        pytest.skip("set APKRUN_EROFS_UTILS to a fetched erofs-utils root (erofs-tools)")
    return verify_tools(Path(TOOLS_ROOT))


def test_a_rebuilt_image_keeps_content_metadata_and_labels(tmp_path: Path) -> None:
    tools = _real_tools()
    tree = tmp_path / "source"
    (tree / "lib64" / "egl").mkdir(parents=True)
    (tree / "etc").mkdir()
    (tree / "lib64" / "egl" / "libEGL_mesa.so").write_bytes(b"\x7fELF" + bytes(range(256)) * 64)
    (tree / "etc" / "note.txt").write_bytes(b"hello\n")
    os.symlink("toybox_vendor", tree / "bin_sh")
    members = [
        TarMember("/", DIRECTORY, 0o755, 0, 2000, 1230768000, label="u:object_r:vendor_file:s0"),
        TarMember(
            "/etc", DIRECTORY, 0o755, 0, 0, 1230768000, label="u:object_r:vendor_configs_file:s0"
        ),
        TarMember(
            "/etc/note.txt",
            REGULAR_FILE,
            0o644,
            0,
            0,
            1230768000,
            label="u:object_r:vendor_configs_file:s0",
            source=tree / "etc" / "note.txt",
        ),
        TarMember("/lib64", DIRECTORY, 0o755, 0, 0, 1230768000, label="u:object_r:vendor_file:s0"),
        TarMember(
            "/lib64/egl",
            DIRECTORY,
            0o755,
            0,
            0,
            1230768000,
            label="u:object_r:same_process_hal_file:s0",
        ),
        TarMember(
            "/lib64/egl/libEGL_mesa.so",
            REGULAR_FILE,
            0o644,
            0,
            0,
            1230768000,
            label="u:object_r:same_process_hal_file:s0",
            source=tree / "lib64" / "egl" / "libEGL_mesa.so",
        ),
        TarMember(
            "/bin_sh",
            SYMLINK,
            0o755,
            0,
            0,
            1230768000,
            target="toybox_vendor",
            label="u:object_r:vendor_file:s0",
        ),
    ]
    tar_path = tmp_path / "in.tar"
    write_tar(members, tar_path)
    image = tmp_path / "out.img"
    build_image(tools, tar_path, image, timestamp=1230768000, uuid=FIXED_UUID)
    block_size, blocks, inodes = image_geometry(tools, image)
    assert (block_size, inodes) == (BLOCK_SIZE, 7)
    assert image.stat().st_size >= blocks * block_size - BLOCK_SIZE

    exported = tmp_path / "exported"
    export_tree(tools, image, exported)
    entries = read_tree(tools, image, exported)
    assert set(entries) == {member.path for member in members}
    for member in members:
        entry = entries[member.path]
        assert (entry.kind, entry.mode, entry.uid, entry.gid) == (
            member.kind,
            member.mode,
            member.uid,
            member.gid,
        )
        assert entry.label == member.label
        assert entry.target == member.target
        assert entry.mtime == entries["/"].mtime
    lib = entries["/lib64/egl/libEGL_mesa.so"]
    assert (
        lib.sha256
        == hashlib.sha256((tree / "lib64" / "egl" / "libEGL_mesa.so").read_bytes()).hexdigest()
    )


def test_the_real_tools_refuse_an_image_that_is_not_erofs(tmp_path: Path) -> None:
    tools = _real_tools()
    garbage = tmp_path / "garbage.img"
    garbage.write_bytes(b"\0" * 8192)
    with pytest.raises(ErofsError):
        image_geometry(tools, garbage)
