"""Tests for safe Cuttlefish composite-disk config collection."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

TOOLS_ROOT = Path(__file__).parents[1]
COLLECTOR = TOOLS_ROOT / "reference/collect_composite_specs.py"


def load_collector_module() -> ModuleType:
    module_spec = importlib.util.spec_from_file_location("collect_composite_specs", COLLECTOR)
    assert module_spec is not None
    assert module_spec.loader is not None
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def run_collector(
    instance_runtime: Path,
    destination: Path,
    *,
    trusted_home: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    if trusted_home is None:
        trusted_home = instance_runtime.parents[1]
    return subprocess.run(
        [
            sys.executable,
            str(COLLECTOR),
            str(trusted_home),
            str(instance_runtime),
            str(destination),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


def test_collects_all_nested_composite_disk_configs(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-3"
    nested = instance / "internal"
    nested.mkdir(parents=True)
    expected = {
        "ap_composite_disk_config.txt": "path=/var/tmp/cvd/host-501/ap.img\n",
        "internal/os_composite_disk_config.txt": "partitions=boot_a,system_a\n",
        "persistent_composite_disk_config.txt": "path=/var/tmp/cvd/host-501/persistent.img\n",
    }
    for relative_name, contents in expected.items():
        path = instance / relative_name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
    (instance / "cuttlefish_config.json").write_text(
        '{"instances": []}\n',
        encoding="utf-8",
    )

    destination = tmp_path / "capture/composite-disk-specs.json"
    destination.parent.mkdir()
    result = run_collector(instance, destination)

    assert result.returncode == 0, result.stderr
    assert json.loads(destination.read_text(encoding="utf-8")) == {"files": expected}


def test_rejects_missing_composite_disk_configs(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    (instance / "cuttlefish_config.json").write_text(
        '{"disks":{"os_composite":{"partitions":["boot_a"]}}}\n',
        encoding="utf-8",
    )
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "no composite-disk config files" in result.stderr
    assert not destination.exists()


@pytest.mark.parametrize("outside_target", (False, True))
def test_rejects_composite_disk_symlinks(tmp_path: Path, outside_target: bool) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    target = tmp_path / "outside.txt" if outside_target else instance / "real.txt"
    target.write_text("path=/var/tmp/cvd/disk.img\n", encoding="utf-8")
    link = instance / "os_composite_disk_config.txt"
    link.symlink_to(target)
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "symlink" in result.stderr
    assert not destination.exists()


def test_does_not_follow_symlinked_directories(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "os_composite_disk_config.txt").write_text(
        "path=/var/tmp/cvd/disk.img\n",
        encoding="utf-8",
    )
    (instance / "redirected").symlink_to(outside, target_is_directory=True)
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "no composite-disk config files" in result.stderr
    assert not destination.exists()


def test_rejects_parent_directory_replaced_by_symlink_during_walk(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    instance = tmp_path / "instances/cvd-1"
    nested = instance / "nested"
    nested.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (nested / "os_composite_disk_config.txt").write_text("disk=inside\n", encoding="utf-8")
    (outside / "os_composite_disk_config.txt").write_text("disk=outside\n", encoding="utf-8")
    displaced = instance / "nested-displaced"
    collector = load_collector_module()
    original_open = collector.os.open

    def replace_directory_before_open(
        path: str | os.PathLike[str],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        if path == "nested" and dir_fd is not None:
            nested.rename(displaced)
            nested.symlink_to(outside, target_is_directory=True)
        return original_open(path, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(collector.os, "open", replace_directory_before_open)

    with pytest.raises(collector.CollectionError, match="changed during inventory"):
        collector.collect_specs(tmp_path, instance)


def test_rejects_root_ancestor_replaced_by_symlink_during_open(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted_home = tmp_path / "home"
    selected_parent = trusted_home / "runtime"
    instance = selected_parent / "instances/cvd-1"
    instance.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "os_composite_disk_config.txt").write_text("disk=outside\n", encoding="utf-8")
    displaced = trusted_home / "runtime-displaced"
    collector = load_collector_module()
    original_open = collector.os.open

    def replace_ancestor_before_open(
        path: str | os.PathLike[str],
        flags: int,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> int:
        if path == "runtime" and dir_fd is not None:
            selected_parent.rename(displaced)
            selected_parent.symlink_to(outside, target_is_directory=True)
        return original_open(path, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(collector.os, "open", replace_ancestor_before_open)

    with pytest.raises(collector.CollectionError, match="could not be safely opened"):
        collector.collect_specs(trusted_home, instance)


def test_rejects_invalid_utf8_without_writing_partial_output(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    (instance / "os_composite_disk_config.txt").write_bytes(b"\xff\xfe")
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "not valid UTF-8" in result.stderr
    assert not destination.exists()


def test_rejects_configs_over_the_per_file_limit(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    (instance / "os_composite_disk_config.txt").write_bytes(b"x" * (256 * 1024 + 1))
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "per-file size limit" in result.stderr
    assert not destination.exists()


def test_rejects_composite_disk_fifo_without_blocking(tmp_path: Path) -> None:
    if not hasattr(os, "mkfifo"):
        pytest.skip("requires POSIX named pipes")
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    os.mkfifo(instance / "os_composite_disk_config.txt")
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "not a regular file" in result.stderr
    assert not destination.exists()


def test_rejects_excessive_flat_directory_inventory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted_home = tmp_path / "home"
    instance = trusted_home / "instances/cvd-1"
    instance.mkdir(parents=True)
    for index in range(9):
        (instance / f"unrelated-{index:02}.txt").touch()
    collector = load_collector_module()
    monkeypatch.setattr(collector, "MAX_INVENTORY_ENTRIES", 8)

    with pytest.raises(collector.CollectionError, match="entry limit"):
        collector.collect_specs(trusted_home, instance)


def test_rejects_excessive_directory_count(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted_home = tmp_path / "home"
    instance = trusted_home / "instances/cvd-1"
    (instance / "one/two").mkdir(parents=True)
    collector = load_collector_module()
    monkeypatch.setattr(collector, "MAX_DIRECTORIES", 2)

    with pytest.raises(collector.CollectionError, match="directory limit"):
        collector.collect_specs(trusted_home, instance)


def test_rejects_excessive_directory_depth(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted_home = tmp_path / "home"
    instance = trusted_home / "instances/cvd-1"
    (instance / "one/two/three/four").mkdir(parents=True)
    collector = load_collector_module()
    monkeypatch.setattr(collector, "MAX_DIRECTORY_DEPTH", 3)

    with pytest.raises(collector.CollectionError, match="depth limit"):
        collector.collect_specs(trusted_home, instance)


def test_accepts_directory_depth_at_the_configured_limit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    trusted_home = tmp_path / "home"
    instance = trusted_home / "instances/cvd-1"
    deepest = instance / "one/two/three"
    deepest.mkdir(parents=True)
    (deepest / "os_composite_disk_config.txt").write_text("disk=system\n", encoding="utf-8")
    collector = load_collector_module()
    monkeypatch.setattr(collector, "MAX_DIRECTORY_DEPTH", 3)

    assert collector.collect_specs(trusted_home, instance) == {
        "one/two/three/os_composite_disk_config.txt": "disk=system\n"
    }


def test_rejects_too_many_composite_disk_configs(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    for index in range(33):
        (instance / f"disk-{index:02}_composite_disk_config.txt").write_text(
            "disk=system\n",
            encoding="utf-8",
        )
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "config limit" in result.stderr
    assert not destination.exists()


def test_rejects_composite_disk_configs_over_the_aggregate_limit(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    contents = b"x" * (256 * 1024)
    for index in range(5):
        (instance / f"disk-{index:02}_composite_disk_config.txt").write_bytes(contents)
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(instance, destination)

    assert result.returncode == 1
    assert "total size limit" in result.stderr
    assert not destination.exists()


def test_cleans_temporary_json_when_atomic_replace_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    (instance / "os_composite_disk_config.txt").write_text("disk=system\n", encoding="utf-8")
    output_directory = tmp_path / "capture"
    output_directory.mkdir()
    destination = output_directory / "composite-disk-specs.json"
    collector = load_collector_module()

    def fail_replace(_source: Path, _destination: Path) -> None:
        raise OSError("synthetic replace failure")

    monkeypatch.setattr(collector.os, "replace", fail_replace)

    with pytest.raises(OSError, match="synthetic replace failure"):
        collector.write_capture(tmp_path, instance, destination)

    assert list(output_directory.iterdir()) == []


@pytest.mark.skipif(os.name == "nt", reason="symlink permissions vary on Windows")
def test_rejects_a_selected_instance_symlink(tmp_path: Path) -> None:
    instance = tmp_path / "instances/cvd-1"
    instance.mkdir(parents=True)
    (instance / "os_composite_disk_config.txt").write_text("disk=system\n", encoding="utf-8")
    runtime_link = tmp_path / "cuttlefish_runtime"
    runtime_link.symlink_to(instance, target_is_directory=True)
    destination = tmp_path / "composite-disk-specs.json"

    result = run_collector(runtime_link, destination, trusted_home=tmp_path)

    assert result.returncode == 1
    assert "could not be safely opened" in result.stderr
    assert not destination.exists()


@pytest.mark.skipif(
    not Path("/proc/self/fd").is_dir() and not Path("/dev/fd").is_dir(),
    reason="file-descriptor inventory is unavailable",
)
def test_visits_many_directories_without_leaking_file_descriptors(tmp_path: Path) -> None:
    trusted_home = tmp_path / "home"
    instance = trusted_home / "instances/cvd-1"
    instance.mkdir(parents=True)
    for index in range(256):
        (instance / f"directory-{index:03}").mkdir()
    (instance / "os_composite_disk_config.txt").write_text("disk=system\n", encoding="utf-8")
    collector = load_collector_module()
    fd_root = Path("/proc/self/fd") if Path("/proc/self/fd").is_dir() else Path("/dev/fd")

    def count_open_descriptors() -> int:
        return len(list(fd_root.iterdir()))

    before = count_open_descriptors()
    assert collector.collect_specs(trusted_home, instance) == {
        "os_composite_disk_config.txt": "disk=system\n"
    }
    assert count_open_descriptors() == before
