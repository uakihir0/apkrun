"""Tests for the declarative system_ext composer (#36)."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from apkrun_image import compose
from apkrun_image.compose import ComposeError, apply_placements, load_placements
from apkrun_image.erofs import DIRECTORY, REGULAR_FILE

LABEL = "u:object_r:system_file:s0"


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
