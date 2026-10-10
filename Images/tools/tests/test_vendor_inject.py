"""Tests for the offline Mesa injection into vendor_a (#099 step 2, IR-620 to IR-627).

The partition tests build a synthetic vendor EROFS with the pinned erofs-utils and seal it with the
vendored avbtool, so they need APKRUN_EROFS_UTILS like test_erofs.py. Nothing here starts a VM, and
the super.img of the pinned archive is never read.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import pytest

from apkrun_image.erofs import (
    DIRECTORY,
    REGULAR_FILE,
    SYMLINK,
    Entry,
    ErofsTools,
    TarMember,
    build_image,
    verify_tools,
    write_tar,
)
from apkrun_image.manifest import _repository_root
from apkrun_image.selinux_labels import label_for, load_contexts
from apkrun_image.vendor_inject import (
    AVBTOOL_COMPONENT,
    MESA_FILE_MODE,
    MESA_LIBRARIES,
    InjectError,
    MesaLibrary,
    _ensure_output,
    _work_area,
    compare_entries,
    load_component,
    load_mesa_output,
    main,
    parse_hashtrees,
    rebuild_partition,
    seal_partition,
    verify_avbtool,
)

FIXTURES = Path(__file__).parent / "fixtures" / "selinux"
PLAT_NAME = "system_a:/system/etc/selinux/plat_file_contexts"
VENDOR_NAME = "vendor_a:/etc/selinux/vendor_file_contexts"
TOOLS_ROOT = os.environ.get("APKRUN_EROFS_UTILS")
SALT = "16b6a5f2fb07bc9ff4d92dc782d830af4eb572c1213156e732d0bcf67fbc162e"
UUID = "22222222-3333-4444-8555-666666666666"
MESA_COMMIT = "0fadfea4f394211946f308458f614839ef253ee8"
LOCK_MESA = {
    "name": "mesa",
    "commit": MESA_COMMIT,
    "version": "26.1.8",
    "buildFlags": ["--buildtype=release", "-Dplatforms=android"],
}
# The hashtree lines of `avbtool info_image` for a vbmeta with a hash descriptor and two hashtrees.
AVB_INFO = """Minimum libavb version:   1.0
Descriptors:
    Chain Partition descriptor:
      Partition Name:          boot
      Public key (sha1):       2597c218aae470a130f61162feaae70afd97f011
    Hash descriptor:
      Image Size:            18827264 bytes
      Partition Name:        vendor_boot
      Digest:                4751b9d4efd2316640ddbe2ff56edd2f650bf9b09991a1fed68264fcbe9882ce
    Hashtree descriptor:
      Image Size:            8192 bytes
      Partition Name:        odm_dlkm
      Root Digest:           08323ce005ea92a9cfc8240b4afc7e8721ad15e8bf7221cb7f16dec45c0fdf3b
    Hashtree descriptor:
      Image Size:            285683712 bytes
      Partition Name:        vendor
      Salt:                  16b6a5f2fb07bc9ff4d92dc782d830af4eb572c1213156e732d0bcf67fbc162e
      Root Digest:           d8895f6a3dc07758a60bddc6de96b416d02a3e93da4e2a8cf63d0ea6bd783a5a
    Prop: com.android.build.vendor.os_version -> '17'
"""


def _shared_object(soname: str, *, machine: int = 183) -> bytes:
    """Return a minimal 64-bit little-endian shared object header that names `soname`."""
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # ELFDATA2LSB
    header[6] = 1  # EV_CURRENT
    header[16:18] = (3).to_bytes(2, "little")  # ET_DYN
    header[18:20] = machine.to_bytes(2, "little")  # EM_AARCH64 is 183
    return bytes(header) + b"\0" + soname.encode("utf-8") + b"\0"


def _mesa_directory(
    root: Path,
    *,
    commit: str = MESA_COMMIT,
    wrong_hash: bool = False,
    drop: str | None = None,
    extra: bool = False,
) -> Path:
    """Write a fake Mesa build output with a manifest that describes it."""
    output = root / "mesa"
    records = []
    for name in MESA_LIBRARIES:
        content = _shared_object(name)
        path = output / "vendor" / "lib64" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        if name == drop:
            continue
        digest = hashlib.sha256(content).hexdigest()
        if wrong_hash:
            digest = "0" * 64
        records.append(
            {
                "path": f"vendor/lib64/{name}",
                "sha256": digest,
                "size": len(content),
                "class": "ELF64",
                "machine": "AArch64",
                "soname": name,
            }
        )
    if extra:
        records.append(
            {
                "path": "vendor/lib64/libextra.so",
                "sha256": "0" * 64,
                "size": 1,
                "class": "ELF64",
                "machine": "AArch64",
                "soname": "libextra.so",
            }
        )
    manifest = {
        "schemaVersion": 1,
        "component": "mesa-android",
        "mesa": {"commit": commit, "version": "26.1.8"},
        "tools": {"ndk": "28.2.13676358 (r28c)"},
        "buildFlags": ["--buildtype=release", "-Dplatforms=android"],
        "files": records,
    }
    (output / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return output


def test_a_matching_mesa_output_is_accepted(tmp_path: Path) -> None:
    libraries, provenance = load_mesa_output(_mesa_directory(tmp_path), LOCK_MESA)
    assert [library.name for library in libraries] == list(MESA_LIBRARIES)
    assert libraries[0].target == "/lib64/egl/libEGL_mesa.so"
    assert provenance["commit"] == MESA_COMMIT
    assert provenance["ndk"] == "28.2.13676358 (r28c)"


def test_a_mesa_output_from_another_commit_is_refused(tmp_path: Path) -> None:
    with pytest.raises(InjectError, match="another commit or version"):
        load_mesa_output(_mesa_directory(tmp_path, commit="1" * 40), LOCK_MESA)


def test_a_library_that_differs_from_the_manifest_is_refused(tmp_path: Path) -> None:
    with pytest.raises(InjectError, match="differs from the Mesa build manifest"):
        load_mesa_output(_mesa_directory(tmp_path, wrong_hash=True), LOCK_MESA)


def test_a_missing_library_is_refused(tmp_path: Path) -> None:
    with pytest.raises(InjectError, match="expected exactly 4 shipped files"):
        load_mesa_output(_mesa_directory(tmp_path, drop="libgallium_dri.so"), LOCK_MESA)


def test_an_extra_listed_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(InjectError, match="expected exactly 4 shipped files"):
        load_mesa_output(_mesa_directory(tmp_path, extra=True), LOCK_MESA)


def test_the_flags_must_match_the_lock(tmp_path: Path) -> None:
    lock = dict(LOCK_MESA, buildFlags=["--buildtype=debug"])
    with pytest.raises(InjectError, match="other Meson flags"):
        load_mesa_output(_mesa_directory(tmp_path), lock)


def test_the_hashtree_parser_reads_only_hashtree_descriptors() -> None:
    blocks = parse_hashtrees(AVB_INFO)
    assert set(blocks) == {"odm_dlkm", "vendor"}
    assert blocks["vendor"]["rootDigest"] == (
        "d8895f6a3dc07758a60bddc6de96b416d02a3e93da4e2a8cf63d0ea6bd783a5a"
    )
    assert blocks["vendor"]["salt"] == SALT
    assert blocks["vendor"]["imageSize"] == 285683712


def test_the_comparison_allows_only_the_named_additions() -> None:
    def entry(path: str, kind: str = REGULAR_FILE, size: int = 1, sha: str = "a") -> Entry:
        return Entry(path, kind, 0o644, 0, 0, size, "t", sha256=sha, label="l")

    before = {"/": Entry("/", DIRECTORY, 0o755, 0, 2000, 10, "t", label="l"), "/a": entry("/a")}
    after = {
        "/": Entry("/", DIRECTORY, 0o755, 0, 2000, 99, "t", label="l"),
        "/a": entry("/a"),
        "/b": entry("/b"),
    }
    assert compare_entries(before, after, added=["/b"]) == []
    # Only a directory that receives an added entry may change size. "/" receives "/b", so it may;
    # "/d" receives nothing, so its size must stay.
    with_dir_before = dict(before, **{"/d": Entry("/d", DIRECTORY, 0o755, 0, 0, 7, "t", label="l")})
    with_dir_after = dict(after, **{"/d": Entry("/d", DIRECTORY, 0o755, 0, 0, 9, "t", label="l")})
    assert compare_entries(with_dir_before, with_dir_after, added=["/b"]) == ["/d: size differs"]
    every_size = compare_entries(
        with_dir_before, with_dir_after, added=["/b"], directory_sizes=True
    )
    assert every_size == ["/: size differs", "/d: size differs"]
    assert compare_entries(before, after) == [
        "/b: new in the rebuild and not expected",
        "/: size differs",
    ]
    changed = dict(after, **{"/a": entry("/a", sha="b")})
    assert compare_entries(before, changed, added=["/b"]) == ["/a: sha256 differs"]
    assert compare_entries(before, {"/": after["/"]}) == [
        "/a: missing from the rebuild",
        "/: size differs",
    ]
    assert compare_entries(before, after, added=["/b", "/c"]) == [
        "/c: expected in the rebuild but missing"
    ]


def test_a_library_that_is_not_an_aarch64_shared_object_is_refused(tmp_path: Path) -> None:
    output = _mesa_directory(tmp_path)
    target = output / "vendor" / "lib64" / "libEGL_mesa.so"
    wrong = _shared_object("libEGL_mesa.so", machine=62)  # x86-64
    target.write_bytes(wrong)
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    for record in manifest["files"]:
        if record["path"] == "vendor/lib64/libEGL_mesa.so":
            record["size"] = len(wrong)
            record["sha256"] = hashlib.sha256(wrong).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(InjectError, match="not an AArch64 shared object"):
        load_mesa_output(output, LOCK_MESA)


def test_a_library_without_its_soname_in_the_file_is_refused(tmp_path: Path) -> None:
    output = _mesa_directory(tmp_path)
    target = output / "vendor" / "lib64" / "libEGL_mesa.so"
    other = _shared_object("libOther.so")
    target.write_bytes(other)
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    for record in manifest["files"]:
        if record["path"] == "vendor/lib64/libEGL_mesa.so":
            record["size"] = len(other)
            record["sha256"] = hashlib.sha256(other).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(InjectError, match="does not contain its SONAME"):
        load_mesa_output(output, LOCK_MESA)


def test_the_work_directory_must_be_outside_the_repository(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    repository.mkdir()
    with pytest.raises(InjectError, match="work directory must be outside the repository"):
        with _work_area(repository / "work", repository):
            pass
    assert not (repository / "work").exists()


def test_the_output_must_be_outside_the_repository(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    repository.mkdir()
    with pytest.raises(InjectError, match="outside the repository"):
        _ensure_output(repository / "out", repository)
    occupied = tmp_path / "occupied"
    occupied.mkdir()
    (occupied / "file").write_text("x", encoding="utf-8")
    with pytest.raises(InjectError, match="must not exist or must be empty"):
        _ensure_output(occupied, repository)


def test_the_vendored_avbtool_is_checked_against_the_lock() -> None:
    lock = load_component(AVBTOOL_COMPONENT)
    path = verify_avbtool(_repository_root(), lock)
    assert path.name == "avbtool.py"
    tampered = json.loads(json.dumps(lock))
    tampered["files"][0]["sha256"] = "0" * 64
    with pytest.raises(InjectError, match="differs from the lock"):
        verify_avbtool(_repository_root(), tampered)


def test_a_missing_manifest_is_a_reported_failure(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = main(
        [
            "--manifest",
            str(tmp_path / "missing.json"),
            "--mesa",
            str(tmp_path),
            "--erofs-tools",
            str(tmp_path),
            "--out",
            str(tmp_path / "out"),
        ]
    )
    assert code == 1
    assert "inject-vendor:" in capsys.readouterr().err


def _real_tools() -> ErofsTools:
    if not TOOLS_ROOT:
        pytest.skip("set APKRUN_EROFS_UTILS to a fetched erofs-utils root (erofs-tools)")
    return verify_tools(Path(TOOLS_ROOT))


def _rules() -> list:
    return load_contexts(
        [
            (PLAT_NAME, (FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8")),
            (VENDOR_NAME, (FIXTURES / "vendor_file_contexts.excerpt").read_text(encoding="utf-8")),
        ]
    )


def _synthetic_stock(
    root: Path, tools: ErofsTools, *, existing: str | None = None, without_egl: bool = False
) -> Path:
    """Build a small vendor EROFS whose labels follow the stock contexts."""
    rules = _rules()
    vendor_contexts = (FIXTURES / "vendor_file_contexts.excerpt").read_bytes()
    files: list[tuple[str, str, int, int, bytes | None, str | None]] = [
        ("/", DIRECTORY, 0o755, 0, None, None),
        ("/bin", DIRECTORY, 0o755, 2000, None, None),
        ("/bin/sh", SYMLINK, 0o755, 2000, None, "toybox_vendor"),
        ("/etc", DIRECTORY, 0o755, 0, None, None),
        ("/etc/selinux", DIRECTORY, 0o755, 0, None, None),
        ("/etc/selinux/vendor_file_contexts", REGULAR_FILE, 0o644, 0, vendor_contexts, None),
        ("/lib64", DIRECTORY, 0o755, 0, None, None),
        ("/lib64/libdrm.so", REGULAR_FILE, 0o644, 0, b"drm", None),
    ]
    if not without_egl:
        files.append(("/lib64/egl", DIRECTORY, 0o755, 0, None, None))
        files.append(("/lib64/egl/libEGL_emulation.so", REGULAR_FILE, 0o644, 0, b"emu", None))
    if existing:
        files.append((f"/lib64/egl/{existing}", REGULAR_FILE, 0o644, 0, b"old", None))
    source_root = root / "stock-source"
    members = []
    for path, kind, mode, gid, content, target in sorted(files):
        label = label_for(rules, path, kind)
        source = None
        if kind == REGULAR_FILE:
            source = source_root / path.lstrip("/")
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(content or b"")
        members.append(
            TarMember(
                path, kind, mode, 0, gid, 1230768000, target=target, label=label, source=source
            )
        )
    tar_path = root / "stock.tar"
    write_tar(members, tar_path)
    image = root / "stock.img"
    build_image(tools, tar_path, image, timestamp=1230768000, uuid=UUID)
    return image


def _libraries(root: Path) -> list[MesaLibrary]:
    libraries = []
    for name in MESA_LIBRARIES:
        path = root / "mesa-out" / "vendor" / "lib64" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\x7fELF" + name.encode("utf-8") * 16)
        libraries.append(
            MesaLibrary(
                name=name,
                source=path,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                size=path.stat().st_size,
            )
        )
    return libraries


def test_the_rebuild_adds_only_the_mesa_libraries_and_labels_them(tmp_path: Path) -> None:
    tools = _real_tools()
    stock = _synthetic_stock(tmp_path, tools)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    libraries = _libraries(tmp_path)
    result = rebuild_partition(
        tools,
        stock,
        scratch,
        libraries,
        plat_name=PLAT_NAME,
        plat_text=(FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8"),
        image_uuid=UUID,
    )
    added = set(result.injected_entries) - set(result.stock_entries)
    assert added == {library.target for library in libraries}
    assert result.reproduced == len(result.stock_entries)
    for library in libraries:
        entry = result.injected_entries[library.target]
        assert entry.sha256 == library.sha256
        assert (entry.kind, entry.mode, entry.uid, entry.gid) == (
            REGULAR_FILE,
            MESA_FILE_MODE,
            0,
            0,
        )
        assert entry.label == "u:object_r:same_process_hal_file:s0"
        assert entry.mtime == result.stock_entries["/lib64"].mtime


def test_the_rebuild_refuses_a_stock_partition_that_has_the_file(tmp_path: Path) -> None:
    tools = _real_tools()
    stock = _synthetic_stock(tmp_path, tools, existing="libgallium_dri.so")
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    with pytest.raises(InjectError, match="already has this file"):
        rebuild_partition(
            tools,
            stock,
            scratch,
            _libraries(tmp_path),
            plat_name=PLAT_NAME,
            plat_text=(FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8"),
            image_uuid=UUID,
        )


def test_the_rebuild_refuses_a_partition_without_the_target_directory(tmp_path: Path) -> None:
    tools = _real_tools()
    stock = _synthetic_stock(tmp_path, tools, without_egl=True)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    with pytest.raises(InjectError, match="has no such directory"):
        rebuild_partition(
            tools,
            stock,
            scratch,
            _libraries(tmp_path),
            plat_name=PLAT_NAME,
            plat_text=(FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8"),
            image_uuid=UUID,
        )


def test_the_sealed_partition_has_its_size_and_a_verified_hashtree(tmp_path: Path) -> None:
    tools = _real_tools()
    stock = _synthetic_stock(tmp_path, tools)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    result = rebuild_partition(
        tools,
        stock,
        scratch,
        _libraries(tmp_path),
        plat_name=PLAT_NAME,
        plat_text=(FIXTURES / "plat_file_contexts.excerpt").read_text(encoding="utf-8"),
        image_uuid=UUID,
    )
    avbtool = verify_avbtool(_repository_root(), load_component(AVBTOOL_COMPONENT))
    output = tmp_path / "vendor_a.img"
    partition_size = 4 * 1024 * 1024
    digest = seal_partition(
        avbtool, result.image, output, partition_size=partition_size, salt=SALT, scratch=scratch
    )
    assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
    assert output.stat().st_size == partition_size
    with pytest.raises(InjectError, match="already exists"):
        seal_partition(
            avbtool, result.image, output, partition_size=partition_size, salt=SALT, scratch=scratch
        )
