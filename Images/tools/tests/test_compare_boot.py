"""Synthetic tests for reference boot normalization and comparison."""

from __future__ import annotations

import gzip
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

TOOL = Path(__file__).parents[1] / "reference/compare_boot.py"
ROOT = Path(__file__).parents[3]

CATEGORY_CASES = (
    ("cmdline", "cmdline.txt", "console=hvc0 mode=one\n", "console=hvc0 mode=two\n", "mode"),
    (
        "bootconfig",
        "bootconfig.txt",
        'androidboot.slot_suffix = "_a"\n',
        'androidboot.slot_suffix = "_b"\n',
        "androidboot.slot_suffix",
    ),
    (
        "bootconfig",
        "internal-bootconfig.txt",
        "androidboot.synthetic = before\n",
        "androidboot.synthetic = after\n",
        "androidboot.synthetic",
    ),
    (
        "props",
        "properties.txt",
        "[ro.build.version.sdk]: [37]\n",
        "[ro.build.version.sdk]: [38]\n",
        "ro.build.version.sdk",
    ),
    (
        "block devices",
        "block-by-name.txt",
        "boot_a -> /dev/block/vda1\n",
        "boot_a -> /dev/block/vdb1\n",
        "block-by-name.txt:boot_a",
    ),
    (
        "mounts",
        "mounts.txt",
        "/dev/block/vda /system ext4 rw 0 0\n",
        "/dev/block/vdb /system ext4 rw 0 0\n",
        "mounts.txt:/system",
    ),
    (
        "modules",
        "modules.txt",
        "virtio_blk 4096 0 - Live 0x1\n",
        "virtio_blk 8192 0 - Live 0x1\n",
        "modules.txt:virtio_blk",
    ),
    (
        "HALs",
        "lshal.txt",
        "android.hardware.graphics.allocator@4.0::IAllocator/default\n",
        "android.hardware.graphics.allocator@4.0::IAllocator/other\n",
        "lshal.txt:android.hardware.graphics.allocator@4.0::IAllocator/default",
    ),
    (
        "hvc users",
        "hvc-users.txt",
        "apkrun-vsockd fd=3 -> /dev/hvc0\n",
        "apkrun-vsockd fd=4 -> /dev/hvc0\n",
        "hvc-users.txt:apkrun-vsockd:fd3",
    ),
    (
        "network",
        "ip-link.txt",
        "2: eth0: <BROADCAST,UP> mtu 1500\n",
        "2: eth0: <BROADCAST,UP> mtu 1400\n",
        "ip-link.txt:eth0",
    ),
    (
        "SELinux",
        "selinux-mode.txt",
        "Enforcing\n",
        "Permissive\n",
        "getenforce",
    ),
)
BASE_CATEGORY_FILES = {
    "cmdline.txt": "console=hvc0\n",
    "bootconfig.txt": 'androidboot.slot_suffix = "_a"\n',
    "internal-bootconfig.txt": "androidboot.synthetic = 1\n",
    "properties.txt": "[ro.build.version.sdk]: [37]\n",
    "block-by-name.txt": "boot_a -> /dev/block/vda1\n",
    "mounts.txt": "/dev/block/vda /system ext4 rw 0 0\n",
    "modules.txt": "virtio_blk 4096 0 - Live 0x1\n",
    "lshal.txt": "android.hardware.graphics.allocator@4.0::IAllocator/default\n",
    "hvc-users.txt": "apkrun-vsockd fd=3 -> /dev/hvc0\n",
    "ip-link.txt": "2: eth0: <BROADCAST,UP> mtu 1500\n",
    "selinux-mode.txt": "Enforcing\n",
}


def _run(*arguments: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["TMPDIR"] = "/tmp"
    return subprocess.run(
        [sys.executable, str(TOOL), *arguments],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def _expected_diff(category: str, key: str) -> list[dict[str, str]]:
    return [
        {
            "category": category,
            "key": key,
            "reason": "The direct boot topology intentionally differs.",
            "design": "android-image.md §8",
        }
    ]


def _write_expected(path: Path, entries: list[dict[str, str]]) -> None:
    path.write_text("# Expected differences\n" + json.dumps(entries) + "\n", encoding="utf-8")


def _seed_category_files(reference: Path, candidate: Path) -> None:
    reference.mkdir()
    candidate.mkdir()
    for filename, content in BASE_CATEGORY_FILES.items():
        (reference / filename).write_text(content, encoding="utf-8")
        (candidate / filename).write_text(content, encoding="utf-8")


@pytest.mark.parametrize(
    ("category", "filename", "before", "after", "key"),
    CATEGORY_CASES,
)
def test_unexplained_change_in_each_category_fails_with_category_and_key(
    tmp_path: Path,
    category: str,
    filename: str,
    before: str,
    after: str,
    key: str,
) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    (reference / filename).write_text(before, encoding="utf-8")
    (candidate / filename).write_text(after, encoding="utf-8")

    result = _run(str(reference), str(candidate))

    assert result.returncode == 1
    assert f"unexplained: {category} :: {key}" in result.stdout
    assert (candidate / "report.json").is_file()
    assert (candidate / "report.txt").is_file()


def test_identical_captures_pass(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0
    assert "0 differences" in result.stdout
    report = json.loads((candidate / "report.json").read_text(encoding="utf-8"))
    assert report["differenceCount"] == 0


def test_missing_category_data_cannot_be_reported_as_an_identical_boot(
    tmp_path: Path,
) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    reference.mkdir()
    candidate.mkdir()

    result = _run(str(reference), str(candidate))

    assert result.returncode == 1
    assert "unexplained: cmdline :: <capture data>" in result.stdout
    report = json.loads((candidate / "report.json").read_text(encoding="utf-8"))
    assert report["unexplainedCount"] == 10


def test_expected_difference_passes_and_is_written_to_report(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    (reference / "bootconfig.txt").write_text('androidboot.slot_suffix = "_a"\n', encoding="utf-8")
    (candidate / "bootconfig.txt").write_text('androidboot.slot_suffix = "_b"\n', encoding="utf-8")
    _write_expected(
        tmp_path / "expected-differences.yaml",
        _expected_diff("bootconfig", "androidboot.slot_suffix"),
    )

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0
    assert "explained: bootconfig :: androidboot.slot_suffix" in result.stdout
    report = (candidate / "report.txt").read_text(encoding="utf-8")
    assert "The direct boot topology intentionally differs." in report


def test_stale_expected_difference_warns_but_does_not_fail(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    _write_expected(
        tmp_path / "expected-differences.yaml",
        _expected_diff("props", "ro.build.version.sdk"),
    )

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0
    assert "warning: stale expected difference: props :: ro.build.version.sdk" in result.stderr


def test_comparison_normalizes_both_captures_without_modifying_them(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    reference_value = "[ro.serialno]: [SERIAL-REFERENCE]\neth0 aa:bb:cc:dd:ee:ff\n"
    candidate_value = "[ro.serialno]: [SERIAL-CANDIDATE]\neth0 11:22:33:44:55:66\n"
    (reference / "properties.txt").write_text(reference_value, encoding="utf-8")
    (candidate / "properties.txt").write_text(candidate_value, encoding="utf-8")

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0
    assert (reference / "properties.txt").read_text(encoding="utf-8") == reference_value
    assert (candidate / "properties.txt").read_text(encoding="utf-8") == candidate_value


def test_normalize_replaces_serial_mac_host_paths_and_secrets(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    content = (
        "androidboot.serialno=SERIAL-123\n"
        "[ro.serialno]: [SERIAL-123]\n"
        '{"serial_number": "SERIAL-JSON", "api_key": "json-secret", '
        '"access_token": "compound-secret", '
        '"client_secret": "client key with spaces", '
        '"password": "correct horse battery staple"}\n'
        "eth0 aa:bb:cc:dd:ee:ff\n"
        "cmd=/home/alice/cuttlefish/bin/launch_cvd\n"
        "guest_path=/mnt/android-data\n"
        "root_path=/root/guest-state\n"
        "tmp_path=/tmp/guest-cache\n"
        "token=private-value\n"
        "password='correct horse battery staple'\n"
        "[ro.debug.token]: [private-property-value]\n"
    )
    (capture / "properties.txt").write_text(content, encoding="utf-8")
    (capture / "cuttlefish_config.json").write_text(
        '{"image": "/mnt/cuttlefish/build/boot.img", '
        '"runtime": "/var/lib/cuttlefish/runtime", '
        '"socket": "/run/cuttlefish/control.sock", '
        '"build": "/srv/android/build", '
        '"checkout": "/usr/local/google/home/builder/aosp"}\n',
        encoding="utf-8",
    )
    (capture / "logcat.txt.gz").write_bytes(gzip.compress(content.encode("utf-8")))

    result = _run("normalize", str(capture))

    assert result.returncode == 0, result.stderr
    normalized = (capture / "properties.txt").read_text(encoding="utf-8")
    assert "SERIAL-123" not in normalized
    assert "SERIAL-JSON" not in normalized
    assert "json-secret" not in normalized
    assert "compound-secret" not in normalized
    assert "client key with spaces" not in normalized
    assert "correct horse battery staple" not in normalized
    json_line = next(line for line in normalized.splitlines() if line.startswith("{"))
    normalized_json = json.loads(json_line)
    assert normalized_json["api_key"] == "<REDACTED>"
    assert normalized_json["access_token"] == "<REDACTED>"
    assert normalized_json["client_secret"] == "<REDACTED>"
    assert normalized_json["password"] == "<REDACTED>"
    assert "aa:bb:cc:dd:ee:ff" not in normalized
    assert "/home/alice" not in normalized
    assert "/root/guest-state" not in normalized
    assert "/tmp/guest-cache" not in normalized
    assert "/mnt/android-data" in normalized
    assert "/mnt/cuttlefish" not in (capture / "cuttlefish_config.json").read_text(encoding="utf-8")
    host_config = (capture / "cuttlefish_config.json").read_text(encoding="utf-8")
    assert "/var/lib/cuttlefish" not in host_config
    assert "/run/cuttlefish" not in host_config
    assert "/srv/android" not in host_config
    assert "/usr/local/google/home" not in host_config
    assert "private-value" not in normalized
    assert "private-property-value" not in normalized
    compressed = gzip.decompress((capture / "logcat.txt.gz").read_bytes()).decode("utf-8")
    assert "SERIAL-123" not in compressed
    assert "aa:bb:cc:dd:ee:ff" not in compressed


def test_normalize_rejects_gzip_expansion_above_the_size_limit(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    oversized = b"x" * (64 * 1024 * 1024 + 1)
    (capture / "logcat.txt.gz").write_bytes(gzip.compress(oversized))

    result = _run("normalize", str(capture))

    assert result.returncode == 2
    assert "gzip output exceeds the 64 MiB limit" in result.stderr
    assert "Traceback" not in result.stderr


def test_normalize_rejects_oversized_gzip_input_before_reading_it_all(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    with (capture / "logcat.txt.gz").open("wb") as stream:
        stream.truncate(64 * 1024 * 1024 + 1)

    result = _run("normalize", str(capture))

    assert result.returncode == 2
    assert "gzip input exceeds the 64 MiB limit" in result.stderr


def test_comparison_replaces_report_symlinks_without_writing_through_them(
    tmp_path: Path,
) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    report_directory = tmp_path / "reports"
    _seed_category_files(reference, candidate)
    report_directory.mkdir()
    outside_json = tmp_path / "outside.json"
    outside_text = tmp_path / "outside.txt"
    outside_json.write_text("keep json\n", encoding="utf-8")
    outside_text.write_text("keep text\n", encoding="utf-8")
    (report_directory / "report.json").symlink_to(outside_json)
    (report_directory / "report.txt").symlink_to(outside_text)

    result = _run(
        str(reference),
        str(candidate),
        "--report-dir",
        str(report_directory),
    )

    assert result.returncode == 0, result.stderr
    assert outside_json.read_text(encoding="utf-8") == "keep json\n"
    assert outside_text.read_text(encoding="utf-8") == "keep text\n"
    assert not (report_directory / "report.json").is_symlink()
    assert not (report_directory / "report.txt").is_symlink()
    assert json.loads((report_directory / "report.json").read_text(encoding="utf-8"))


def test_normalize_rejects_symlinks_without_following_them(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    outside = tmp_path / "outside.txt"
    outside.write_text("serial=should-not-be-read\n", encoding="utf-8")
    (capture / "linked.txt").symlink_to(outside)

    result = _run("normalize", str(capture))

    assert result.returncode == 2
    assert "symbolic link" in result.stderr
    assert outside.read_text(encoding="utf-8") == "serial=should-not-be-read\n"


def test_invalid_utf8_rules_fail_with_a_user_facing_error(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    rules = tmp_path / "normalize.yaml"
    rules.write_bytes(b"\xff")

    result = _run("normalize", str(capture), "--rules", str(rules))

    assert result.returncode == 2
    assert "not valid UTF-8" in result.stderr
    assert "Traceback" not in result.stderr
