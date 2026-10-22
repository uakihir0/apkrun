"""Tests for the declarative system_ext composer (#36)."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import pytest

from apkrun_image import compose
from apkrun_image.compose import (
    ComposeError,
    _entry_differences,
    apply_placements,
    load_placements,
    rebuild_system_ext,
)
from apkrun_image.erofs import (
    DIRECTORY,
    REGULAR_FILE,
    ErofsTools,
    TarMember,
    build_image,
    verify_tools,
    write_tar,
)

LABEL = "u:object_r:system_file:s0"
TOOLS_ROOT = os.environ.get("APKRUN_EROFS_UTILS")
FIXED_UUID = "11111111-2222-4333-8444-555555555555"


def write_plan(product: Path, entries: list[dict[str, object]], *, schema_version: int = 1) -> Path:
    product.mkdir(parents=True, exist_ok=True)
    path = product / "compose.json"
    path.write_text(
        json.dumps({"schemaVersion": schema_version, "entries": entries}), encoding="utf-8"
    )
    return path


def directory(destination: str) -> dict[str, object]:
    return {
        "source": None,
        "destination": destination,
        "kind": DIRECTORY,
        "mode": "0755",
        "owner": {"uid": 0, "gid": 0},
        "label": LABEL,
    }


def regular_file(source: str, destination: str) -> dict[str, object]:
    return {
        "source": source,
        "destination": destination,
        "kind": REGULAR_FILE,
        "mode": "0644",
        "owner": {"uid": 0, "gid": 0},
        "label": LABEL,
    }


def test_plan_applies_only_listed_files_and_returns_deterministic_metadata(
    tmp_path: Path,
) -> None:
    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("boot marker\n", encoding="utf-8")
    plan = write_plan(
        product,
        [
            regular_file("marker.txt", "/system_ext/etc/apkrun/marker.txt"),
            directory("/system_ext/etc/apkrun"),
        ],
    )
    tree = tmp_path / "tree"
    (tree / "etc").mkdir(parents=True)
    (tree / "etc/stock.conf").write_text("stock\n", encoding="utf-8")
    placements = load_placements(plan, product)

    expected, members = apply_placements(placements, product, tree)

    assert (tree / "etc/apkrun/marker.txt").read_text(encoding="utf-8") == "boot marker\n"
    assert set(expected) == {"/etc/apkrun", "/etc/apkrun/marker.txt"}
    assert expected["/etc/apkrun/marker.txt"].sha256 == hashlib.sha256(b"boot marker\n").hexdigest()
    assert [member.path for member in members] == ["/etc/apkrun", "/etc/apkrun/marker.txt"]
    assert [member.kind for member in members] == [DIRECTORY, REGULAR_FILE]
    assert (tree / "etc/stock.conf").read_text(encoding="utf-8") == "stock\n"


def test_plan_refuses_unknown_fields_schema_and_noncanonical_paths(tmp_path: Path) -> None:
    product = tmp_path / "product"
    plan = write_plan(product, [directory("/system_ext/etc/apkrun")], schema_version=2)
    with pytest.raises(ComposeError, match="schemaVersion"):
        load_placements(plan, product)

    plan.write_text(
        json.dumps({"schemaVersion": True, "entries": [directory("/system_ext/etc/apkrun")]}),
        encoding="utf-8",
    )
    with pytest.raises(ComposeError, match="schemaVersion"):
        load_placements(plan, product)

    plan = write_plan(product, [directory("/system_ext/etc/../apkrun")])
    with pytest.raises(ComposeError, match="normalized absolute path"):
        load_placements(plan, product)

    plan = write_plan(product, [directory("/system_ext/etc/apkrun"), {"unexpected": True}])
    with pytest.raises(ComposeError, match="missing or unknown fields"):
        load_placements(plan, product)


def test_plan_refuses_paths_outside_system_ext_and_duplicate_destinations(tmp_path: Path) -> None:
    product = tmp_path / "product"
    plan = write_plan(product, [directory("/vendor/etc/apkrun")])
    with pytest.raises(ComposeError, match="below /system_ext"):
        load_placements(plan, product)

    plan = write_plan(
        product,
        [
            directory("/system_ext/etc/apkrun"),
            directory("/system_ext/etc/apkrun"),
        ],
    )
    with pytest.raises(ComposeError, match="duplicate destination"):
        load_placements(plan, product)


def test_plan_refuses_source_symlinks_and_parent_file_conflicts(tmp_path: Path) -> None:
    product = tmp_path / "product"
    product.mkdir()
    (product / "real.txt").write_text("data", encoding="utf-8")
    (product / "linked.txt").symlink_to(product / "real.txt")
    plan = write_plan(product, [regular_file("linked.txt", "/system_ext/etc/file")])
    with pytest.raises(ComposeError, match="must not be symlinks"):
        load_placements(plan, product)

    plan = write_plan(
        product,
        [
            regular_file("real.txt", "/system_ext/etc/apkrun"),
            regular_file("real.txt", "/system_ext/etc/apkrun/child"),
        ],
    )
    with pytest.raises(ComposeError, match="is a file but also a parent"):
        load_placements(plan, product)

    invalid_kind = directory("/system_ext/etc/apkrun")
    invalid_kind["kind"] = []
    plan = write_plan(product, [invalid_kind])
    with pytest.raises(ComposeError, match="kind must be"):
        load_placements(plan, product)


def test_application_refuses_replacing_a_stock_path_or_missing_parent(tmp_path: Path) -> None:
    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("new\n", encoding="utf-8")
    plan = write_plan(product, [regular_file("marker.txt", "/system_ext/etc/stock.conf")])
    tree = tmp_path / "tree"
    (tree / "etc").mkdir(parents=True)
    (tree / "etc/stock.conf").write_text("stock\n", encoding="utf-8")

    with pytest.raises(ComposeError, match="refuses to replace"):
        apply_placements(load_placements(plan, product), product, tree)

    plan = write_plan(product, [regular_file("marker.txt", "/system_ext/missing/file")])
    with pytest.raises(ComposeError, match="parent directory is absent"):
        apply_placements(load_placements(plan, product), product, tree)


def test_application_preflights_all_targets_before_mutating_tree(tmp_path: Path) -> None:
    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("new\n", encoding="utf-8")
    plan = write_plan(
        product,
        [
            directory("/system_ext/etc/new-dir"),
            regular_file("marker.txt", "/system_ext/etc/stock.conf"),
        ],
    )
    tree = tmp_path / "tree"
    (tree / "etc").mkdir(parents=True)
    (tree / "etc/stock.conf").write_text("stock\n", encoding="utf-8")

    with pytest.raises(ComposeError, match="refuses to replace"):
        apply_placements(load_placements(plan, product), product, tree)

    assert sorted(path.relative_to(tree).as_posix() for path in tree.rglob("*")) == [
        "etc",
        "etc/stock.conf",
    ]
    assert (tree / "etc/stock.conf").read_text(encoding="utf-8") == "stock\n"


def test_application_rolls_back_partial_file_copy_and_created_directories(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("new\n", encoding="utf-8")
    plan = write_plan(
        product,
        [
            directory("/system_ext/etc/apkrun"),
            regular_file("marker.txt", "/system_ext/etc/apkrun/marker.txt"),
        ],
    )
    tree = tmp_path / "tree"
    (tree / "etc").mkdir(parents=True)

    def fail_after_partial_copy(source: object, destination: object, *, length: int = 0) -> None:
        destination.write(b"partial")  # type: ignore[attr-defined]
        raise OSError("injected copy failure")

    monkeypatch.setattr(compose.shutil, "copyfileobj", fail_after_partial_copy)

    with pytest.raises(ComposeError, match="cannot copy composition source"):
        apply_placements(load_placements(plan, product), product, tree)

    assert list(tree.rglob("*")) == [tree / "etc"]


def test_entry_diff_allows_only_planned_entries_and_receiving_directory_sizes() -> None:
    from apkrun_image.erofs import Entry

    stock = {
        "/": Entry("/", DIRECTORY, 0o755, 0, 0, 64, "stock"),
        "/etc": Entry("/etc", DIRECTORY, 0o755, 0, 0, 64, "stock", label=LABEL),
    }
    planned = {
        "/etc/apkrun": Entry("/etc/apkrun", DIRECTORY, 0o755, 0, 0, 0, "stock", label=LABEL),
        "/etc/apkrun/marker": Entry(
            "/etc/apkrun/marker",
            REGULAR_FILE,
            0o644,
            0,
            0,
            5,
            "stock",
            sha256=hashlib.sha256(b"hello").hexdigest(),
            label=LABEL,
        ),
    }
    composed = {
        **stock,
        "/etc": Entry("/etc", DIRECTORY, 0o755, 0, 0, 96, "stock", label=LABEL),
        "/etc/apkrun": Entry("/etc/apkrun", DIRECTORY, 0o755, 0, 0, 32, "stock", label=LABEL),
        "/etc/apkrun/marker": planned["/etc/apkrun/marker"],
    }

    assert _entry_differences(stock, composed, added=planned) == []
    unexpected = Entry(
        "/etc/unlisted",
        REGULAR_FILE,
        0o644,
        0,
        0,
        1,
        "stock",
        sha256=hashlib.sha256(b"x").hexdigest(),
        label=LABEL,
    )
    assert _entry_differences(stock, {**composed, "/etc/unlisted": unexpected}, added=planned) == [
        "/etc/unlisted: new in the rebuild and not expected"
    ]


def test_replacements_are_limited_to_stock_selinux_files_and_preserve_inode_metadata(
    tmp_path: Path,
) -> None:
    from apkrun_image.erofs import Entry

    tree = tmp_path / "tree"
    selinux_tree = tree / "etc/selinux"
    selinux_tree.mkdir(parents=True)
    names = (
        "system_ext_file_contexts",
        "system_ext_seapp_contexts",
        "system_ext_sepolicy.cil",
    )
    stock_entries = {}
    stock_members = []
    replacements = {}
    for name in names:
        relative_path = f"/etc/selinux/{name}"
        image_path = f"/system_ext{relative_path}"
        stock_path = selinux_tree / name
        stock_content = f"stock {name}\n".encode()
        stock_path.write_bytes(stock_content)
        replacement_path = tmp_path / f"replacement-{name}"
        replacement_content = f"product {name}\n".encode()
        replacement_path.write_bytes(replacement_content)
        stock_entries[relative_path] = Entry(
            relative_path,
            REGULAR_FILE,
            0o640,
            1000,
            1000,
            len(stock_content),
            "stock timestamp",
            sha256=hashlib.sha256(stock_content).hexdigest(),
            label="u:object_r:system_file:s0",
        )
        stock_members.append(
            TarMember(
                relative_path,
                REGULAR_FILE,
                0o640,
                1000,
                1000,
                compose.BUILD_TIMESTAMP,
                label="u:object_r:system_file:s0",
                source=stock_path,
            )
        )
        replacements[image_path] = replacement_path

    replaced_entries, replacement_members = compose._replacement_members(
        stock_entries,
        stock_members,
        replacements,
        tree,
    )

    assert set(replaced_entries) == set(stock_entries)
    assert len(replacement_members) == len(names)
    for name in names:
        relative_path = f"/etc/selinux/{name}"
        replacement_content = f"product {name}\n".encode()
        replaced = replaced_entries[relative_path]
        assert replaced.size == len(replacement_content)
        assert replaced.sha256 == hashlib.sha256(replacement_content).hexdigest()
        assert replaced.mode == stock_entries[relative_path].mode
        assert replaced.uid == stock_entries[relative_path].uid
        assert replaced.gid == stock_entries[relative_path].gid
        assert replaced.mtime == stock_entries[relative_path].mtime
        assert replaced.label == stock_entries[relative_path].label
        assert (selinux_tree / name).read_text(encoding="utf-8") == f"stock {name}\n"

    composed_entries = dict(stock_entries)
    composed_entries.update(replaced_entries)
    assert _entry_differences(stock_entries, composed_entries, replaced=replaced_entries) == []


def test_replacements_reject_unlisted_targets_and_symlink_sources(tmp_path: Path) -> None:
    tree = tmp_path / "tree"
    (tree / "etc/selinux").mkdir(parents=True)
    source = tmp_path / "replacement.cil"
    source.write_text("(type example)\n", encoding="utf-8")
    with pytest.raises(ComposeError, match="SELinux allowlist"):
        compose._replacement_members(
            {},
            [],
            {"/system_ext/etc/build.prop": source},
            tree,
        )

    linked_source = tmp_path / "linked.cil"
    linked_source.symlink_to(source)
    stock_path = "/etc/selinux/system_ext_sepolicy.cil"
    from apkrun_image.erofs import Entry

    stock_entry = Entry(
        stock_path,
        REGULAR_FILE,
        0o644,
        0,
        0,
        0,
        "stock timestamp",
        sha256=hashlib.sha256(b"").hexdigest(),
        label=LABEL,
    )
    (tree / stock_path.lstrip("/")).write_bytes(b"")
    with pytest.raises(ComposeError, match="real regular file"):
        compose._replacement_members(
            {stock_path: stock_entry},
            [
                TarMember(
                    stock_path,
                    REGULAR_FILE,
                    0o644,
                    0,
                    0,
                    compose.BUILD_TIMESTAMP,
                    label=LABEL,
                    source=tree / stock_path.lstrip("/"),
                )
            ],
            {"/system_ext" + stock_path: linked_source},
            tree,
        )


def test_rebuild_system_ext_checks_the_stock_round_trip_and_exact_placements(
    tmp_path: Path,
) -> None:
    if not TOOLS_ROOT:
        pytest.skip("set APKRUN_EROFS_UTILS to a fetched erofs-utils root (erofs-tools)")
    tools: ErofsTools = verify_tools(Path(TOOLS_ROOT))
    stock_source = tmp_path / "stock-tree"
    (stock_source / "etc").mkdir(parents=True)
    (stock_source / "etc/stock.conf").write_text("stock\n", encoding="utf-8")
    stock_members = [
        TarMember("/", DIRECTORY, 0o755, 0, 0, compose.BUILD_TIMESTAMP, label=LABEL),
        TarMember("/etc", DIRECTORY, 0o755, 0, 0, compose.BUILD_TIMESTAMP, label=LABEL),
        TarMember(
            "/etc/stock.conf",
            REGULAR_FILE,
            0o644,
            0,
            0,
            compose.BUILD_TIMESTAMP,
            label=LABEL,
            source=stock_source / "etc/stock.conf",
        ),
    ]
    stock_tar = tmp_path / "stock.tar"
    write_tar(stock_members, stock_tar)
    stock_image = tmp_path / "system_ext_a.img"
    build_image(
        tools,
        stock_tar,
        stock_image,
        timestamp=compose.BUILD_TIMESTAMP,
        uuid=FIXED_UUID,
    )

    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("boot marker\n", encoding="utf-8")
    write_plan(
        product,
        [
            directory("/system_ext/etc/apkrun"),
            regular_file("marker.txt", "/system_ext/etc/apkrun/marker.txt"),
        ],
    )
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep").write_text("unmodified\n", encoding="utf-8")
    (scratch / "system-ext-stock-tree").symlink_to(outside, target_is_directory=True)
    result = rebuild_system_ext(
        tools,
        stock_image,
        product,
        scratch,
        image_uuid=FIXED_UUID,
    )

    assert result.stock_entries_reproduced == len(result.stock_entries) == 3
    assert set(result.added_entries) == {
        "/etc/apkrun",
        "/etc/apkrun/marker.txt",
    }
    assert set(result.composed_entries) == set(result.stock_entries) | set(result.added_entries)
    assert (
        result.composed_entries["/etc/apkrun/marker.txt"].sha256
        == hashlib.sha256(b"boot marker\n").hexdigest()
    )
    assert (outside / "keep").read_text(encoding="utf-8") == "unmodified\n"
    assert (scratch / "system-ext-stock-tree").is_symlink()


def test_rebuild_system_ext_replaces_only_allowlisted_stock_policy_files(
    tmp_path: Path,
) -> None:
    if not TOOLS_ROOT:
        pytest.skip("set APKRUN_EROFS_UTILS to a fetched erofs-utils root (erofs-tools)")
    tools: ErofsTools = verify_tools(Path(TOOLS_ROOT))
    stock_source = tmp_path / "stock-tree"
    selinux_source = stock_source / "etc/selinux"
    selinux_source.mkdir(parents=True)
    names = (
        "system_ext_file_contexts",
        "system_ext_seapp_contexts",
        "system_ext_sepolicy.cil",
    )
    stock_members = [
        TarMember("/", DIRECTORY, 0o755, 0, 0, compose.BUILD_TIMESTAMP, label=LABEL),
        TarMember("/etc", DIRECTORY, 0o755, 0, 0, compose.BUILD_TIMESTAMP, label=LABEL),
        TarMember(
            "/etc/stock.conf",
            REGULAR_FILE,
            0o644,
            0,
            0,
            compose.BUILD_TIMESTAMP,
            label=LABEL,
            source=stock_source / "etc/stock.conf",
        ),
        TarMember(
            "/etc/selinux",
            DIRECTORY,
            0o755,
            0,
            0,
            compose.BUILD_TIMESTAMP,
            label=LABEL,
        ),
    ]
    (stock_source / "etc").mkdir(parents=True, exist_ok=True)
    (stock_source / "etc/stock.conf").write_text("preserve stock\n", encoding="utf-8")
    for name in names:
        source = selinux_source / name
        source.write_text(f"stock {name}\n", encoding="utf-8")
        stock_members.append(
            TarMember(
                f"/etc/selinux/{name}",
                REGULAR_FILE,
                0o644,
                0,
                0,
                compose.BUILD_TIMESTAMP,
                label=LABEL,
                source=source,
            )
        )
    stock_tar = tmp_path / "stock.tar"
    write_tar(stock_members, stock_tar)
    stock_image = tmp_path / "system_ext_a.img"
    build_image(
        tools,
        stock_tar,
        stock_image,
        timestamp=compose.BUILD_TIMESTAMP,
        uuid=FIXED_UUID,
    )

    product = tmp_path / "product"
    product.mkdir()
    (product / "marker.txt").write_text("boot marker\n", encoding="utf-8")
    write_plan(
        product,
        [
            directory("/system_ext/etc/apkrun"),
            regular_file("marker.txt", "/system_ext/etc/apkrun/marker.txt"),
        ],
    )
    replacement_root = tmp_path / "replacement"
    replacement_root.mkdir()
    replacements = {}
    for name in names:
        replacement = replacement_root / name
        replacement.write_text(f"product {name}\n", encoding="utf-8")
        replacements[f"/system_ext/etc/selinux/{name}"] = replacement

    result = rebuild_system_ext(
        tools,
        stock_image,
        product,
        tmp_path / "scratch",
        image_uuid=FIXED_UUID,
        replacements=replacements,
    )

    assert set(result.replaced_entries) == {f"/etc/selinux/{name}" for name in names}
    assert set(result.composed_entries) == set(result.stock_entries) | set(result.added_entries)
    assert result.composed_entries["/etc/stock.conf"] == result.stock_entries["/etc/stock.conf"]
    for name in names:
        path = f"/etc/selinux/{name}"
        assert (
            result.composed_entries[path].sha256
            == hashlib.sha256(f"product {name}\n".encode()).hexdigest()
        )
    assert set(result.added_entries) == {
        "/etc/apkrun",
        "/etc/apkrun/marker.txt",
    }
