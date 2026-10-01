"""Synthetic tests for reference boot normalization and comparison."""

from __future__ import annotations

import gzip
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

TOOL = Path(__file__).parents[1] / "reference/compare_boot.py"
ROOT = Path(__file__).parents[3]
TOOL_SPEC = importlib.util.spec_from_file_location("compare_boot_test_module", TOOL)
assert TOOL_SPEC is not None
assert TOOL_SPEC.loader is not None
compare_boot = importlib.util.module_from_spec(TOOL_SPEC)
TOOL_SPEC.loader.exec_module(compare_boot)
assert isinstance(compare_boot, ModuleType)

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


def _run(*arguments: str, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["TMPDIR"] = "/tmp"
    return subprocess.run(
        [sys.executable, str(TOOL), *arguments],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
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


def test_comparison_redacts_private_keys_without_modifying_captures(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    reference_key = "-----BEGIN PRIVATE KEY-----\nreference-secret\n-----END PRIVATE KEY-----\n"
    candidate_key = "-----BEGIN PRIVATE KEY-----\ncandidate-secret\n-----END PRIVATE KEY-----\n"
    (reference / "properties.txt").write_text(reference_key, encoding="utf-8")
    (candidate / "properties.txt").write_text(candidate_key, encoding="utf-8")

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0, result.stderr
    assert "0 differences" in result.stdout
    assert (reference / "properties.txt").read_text(encoding="utf-8") == reference_key
    assert (candidate / "properties.txt").read_text(encoding="utf-8") == candidate_key
    assert "reference-secret" not in (candidate / "report.json").read_text(encoding="utf-8")
    assert "candidate-secret" not in (candidate / "report.txt").read_text(encoding="utf-8")


def test_comparison_streams_newline_dense_property_files(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    blank_lines = "\n" * 500_000 + "[ro.build.version.sdk]: [37]\n"
    (reference / "properties.txt").write_text(blank_lines, encoding="utf-8")
    (candidate / "properties.txt").write_text(blank_lines, encoding="utf-8")

    result = _run(str(reference), str(candidate))

    assert result.returncode == 0, result.stderr
    assert "0 differences" in result.stdout


def test_comparison_rejects_capture_data_above_the_record_limit(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _seed_category_files(reference, candidate)
    records = "".join(f"[ro.synthetic.property.{index}]: [value]\n" for index in range(100_001))
    (reference / "properties.txt").write_text(records, encoding="utf-8")

    result = _run(str(reference), str(candidate))

    assert result.returncode == 2
    assert "capture comparison data exceeds the 100000-record limit" in result.stderr


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
        json.dumps(
            {
                "image": "/mnt/cuttlefish/build/boot.img",
                "runtime": "/var/lib/cuttlefish/runtime",
                "socket": "/run/cuttlefish/control.sock",
                "build": "/srv/android/build",
                "checkout": "/usr/local/google/home/builder/aosp",
                "runtime_with_spaces": "-u/tmp/private workspace/cvd",
                "escaped_runtime": '-u/home/alice/private" workspace/cvd',
            }
        )
        + "\n",
        encoding="utf-8",
    )
    (capture / "launcher.log").write_text(
        "cvd --output_dir=/var/tmp/cvd/host-501 -o/var/tmp/cvd/host-501/logs "
        "-u/tmp/cf_env_501/home/cuttlefish/instances/cvd-1 "
        "-u/home/lima.guest/.cache/cuttlefish -u/run/user/501/cvd "
        "-u/var/cache/cuttlefish/host\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48127): cvd -u/tmp/private workspace/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48128): cvd -u/tmp/private build workspace/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48130): cvd -u/tmp/private -workspace/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48131): cvd -u/tmp/private -x/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48135): cvd -u/tmp/private --workspace/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48136): cvd -u/tmp/private workspace\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48132): cvd -u/tmp/private -v "
        "permission denied; see /var/log/launcher.log\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48133): cvd -u/tmp/private -vv "
        "permission denied; see /var/log/launcher.log\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48137): cvd -u/tmp/private -v=1 "
        "permission denied; see /var/log/launcher.log\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48139): cvd -u/tmp/private -v "
        "operation not permitted; see /var/log/launcher.log\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48140): cvd -u/tmp/private -v error.log\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48145): cvd -u/tmp/private -v "
        "error. secret-project-name/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48146): cvd -u/tmp/private -v "
        "permission denied secret-project-name\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48141): cvd -u/tmp/private "
        "workspace/command.cc:9] Started (pid: 9): workspace/cvd\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48142): cvd -u/tmp/private -v "
        "operation not permitted\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48143): cvd -u/tmp/private -v "
        "operation not permitted.\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48144): cvd -u/tmp/private -v error:private\n"
        'cvd -u"/home/lima.guest/private workspace/cvd"\n'
        + r'cvd -u"/home/alice/escaped-quote-secret\" workspace/cvd"'
        + "\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48129): cvd -u/run/user/501/private\\ workspace/cvd\n"
        "failed to open /tmp/cvd/boot.img permission denied\n"
        "cvd -u/tmp/cvd/boot.img permission denied\n"
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:325] cvd -u/tmp/cvd/boot.img permission denied; "
        "see /var/log/launcher.log\n",
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
    assert "workspace/cvd" not in host_config
    assert json.loads(host_config)["runtime_with_spaces"] == "-u<HOST_PATH>"
    assert json.loads(host_config)["escaped_runtime"] == "-u<HOST_PATH>"
    launcher_log = (capture / "launcher.log").read_text(encoding="utf-8")
    assert "-o<HOST_TEMP_PATH>" in launcher_log
    assert "-u<HOST_TEMP_PATH>" in launcher_log
    assert "-u<HOST_HOME_PATH>" in launcher_log
    assert "-u<HOST_PATH>" in launcher_log
    assert "-u<HOST_PATH_WITH_SPACES>" in launcher_log
    assert "/var/tmp/cvd/" not in launcher_log
    assert "/tmp/cf_env_501/" not in launcher_log
    assert "/home/lima.guest/" not in launcher_log
    assert "escaped-quote-secret" not in launcher_log
    assert "/run/user/501/" not in launcher_log
    assert "/var/cache/cuttlefish/" not in launcher_log
    assert "workspace/cvd" not in launcher_log
    assert "-x/cvd" not in launcher_log
    assert "--workspace/cvd" not in launcher_log
    assert "error.log" not in launcher_log
    assert "secret-project-name/cvd" not in launcher_log
    assert "workspace/command.cc" not in launcher_log
    assert "error:private" not in launcher_log
    assert launcher_log.count("permission denied") == 6
    assert launcher_log.count("permission denied; see <HOST_PATH>") == 4
    assert "operation not permitted; see <HOST_PATH>" in launcher_log
    assert launcher_log.count("operation not permitted") == 3
    assert "private-value" not in normalized
    assert "private-property-value" not in normalized
    compressed = gzip.decompress((capture / "logcat.txt.gz").read_bytes()).decode("utf-8")
    assert "SERIAL-123" not in compressed
    assert "aa:bb:cc:dd:ee:ff" not in compressed


def test_normalize_handles_long_ambiguous_started_record(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    command = (
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48134): cvd -u/tmp/private "
        f"{'directory ' * 100_000}\n"
    )
    (capture / "launcher.log").write_text(command, encoding="utf-8")

    result = _run("normalize", str(capture), timeout=10)

    assert result.returncode == 0, result.stderr
    normalized = (capture / "launcher.log").read_text(encoding="utf-8")
    assert "/tmp/private" not in normalized
    assert "-u<HOST_PATH_WITH_SPACES>\n" in normalized


def test_normalize_handles_unterminated_quoted_path_with_many_backslashes(
    tmp_path: Path,
) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    (capture / "launcher.log").write_text(
        'cvd -u"/tmp/private' + ("\\" * 80) + "'\n",
        encoding="utf-8",
    )

    result = _run("normalize", str(capture), timeout=5)

    assert result.returncode == 0, result.stderr
    normalized = (capture / "launcher.log").read_text(encoding="utf-8")
    assert "/tmp/private" not in normalized


def test_normalize_redacts_private_key_blocks_with_many_begin_markers(
    tmp_path: Path,
) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    begins = "-----BEGIN PRIVATE KEY-----\n" * 20_000
    (capture / "properties.txt").write_text(
        f"{begins}private-key-payload\n-----END PRIVATE KEY-----\n",
        encoding="utf-8",
    )

    result = _run("normalize", str(capture), timeout=10)

    assert result.returncode == 0, result.stderr
    normalized = (capture / "properties.txt").read_text(encoding="utf-8")
    assert "private-key-payload" not in normalized
    assert normalized.count("<REDACTED_PRIVATE_KEY>") == 1


@pytest.mark.parametrize("line_ending", ("\n", "\r"))
def test_normalize_streams_newline_dense_logs_and_preserves_assignment_diagnostics(
    tmp_path: Path, line_ending: str
) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    command = (
        "assemble_cvd(48124) D 10-01 09:00:00 48124 48124 "
        "command.cc:323] Started (pid: 48138): cvd -u/tmp/private -v=1 "
        f"permission denied; see /var/log/launcher.log{line_ending}"
    )
    lines = f"ordinary diagnostic{line_ending}" * 100_000
    (capture / "launcher.log").write_text(command + lines, encoding="utf-8")

    result = _run("normalize", str(capture), timeout=10)

    assert result.returncode == 0, result.stderr
    normalized = (capture / "launcher.log").read_bytes().decode("utf-8")
    assert "/tmp/private" not in normalized
    assert "permission denied; see <HOST_PATH>" in normalized
    assert normalized.count(f"ordinary diagnostic{line_ending}") == 100_000


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


def test_normalize_rejects_oversized_plain_log_before_reading_it_all(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    with (capture / "kernel.log").open("wb") as stream:
        stream.truncate(64 * 1024 * 1024 + 1)

    result = _run("normalize", str(capture))

    assert result.returncode == 2
    assert "file exceeds the 64 MiB limit" in result.stderr


def test_normalize_bounds_configuration_reads(tmp_path: Path) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    rules = tmp_path / "oversized-rules.yaml"
    with rules.open("wb") as stream:
        stream.truncate(1024 * 1024 + 1)

    result = _run("normalize", str(capture), "--rules", str(rules), timeout=5)

    assert result.returncode == 2
    assert "exceeds the 1 MiB configuration limit" in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires POSIX FIFOs")
@pytest.mark.parametrize("input_kind", ("rules", "expected"))
def test_configuration_fifo_is_rejected_without_waiting_for_a_writer(
    tmp_path: Path, input_kind: str
) -> None:
    fifo = tmp_path / "input.yaml"
    os.mkfifo(fifo)
    if input_kind == "rules":
        capture = tmp_path / "capture"
        capture.mkdir()
        result = _run("normalize", str(capture), "--rules", str(fifo), timeout=2)
    else:
        reference = tmp_path / "reference"
        candidate = tmp_path / "candidate"
        _seed_category_files(reference, candidate)
        result = _run(
            str(reference),
            str(candidate),
            "--expected",
            str(fifo),
            timeout=2,
        )

    assert result.returncode == 2
    assert "must be a regular file" in result.stderr
    assert "Traceback" not in result.stderr


def test_capture_tree_rejects_too_many_entries_before_category_scans(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    capture = tmp_path / "capture"
    (capture / "nested").mkdir(parents=True)
    (capture / "nested" / "one.txt").touch()
    (capture / "nested" / "two.txt").touch()
    (capture / "three.txt").touch()
    monkeypatch.setattr(compare_boot, "MAX_CAPTURE_ENTRIES", 3)

    with pytest.raises(compare_boot.CaptureToolError, match="3-entry traversal limit"):
        compare_boot._bounded_capture_paths(capture)


@pytest.mark.parametrize("filename", ("properties.txt", "logcat.txt.gz"))
def test_normalize_rejects_expanded_output_above_the_size_limit(
    tmp_path: Path, filename: str
) -> None:
    capture = tmp_path / "capture"
    capture.mkdir()
    rules = tmp_path / "normalize.yaml"
    rules.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "substitutions": [{"pattern": "x", "replacement": "x" * 1_000_000}],
            }
        ),
        encoding="utf-8",
    )
    original = b"x" * 68
    source = gzip.compress(original) if filename.endswith(".gz") else original
    artifact = capture / filename
    artifact.write_bytes(source)

    result = _run("normalize", str(capture), "--rules", str(rules))

    assert result.returncode == 2
    assert "normalized output exceeds the 64 MiB limit" in result.stderr
    assert artifact.read_bytes() == source


def test_comparison_rejects_normalized_output_above_the_size_limit(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    reference.mkdir()
    candidate.mkdir()
    rules = tmp_path / "normalize.yaml"
    rules.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "substitutions": [{"pattern": "x", "replacement": "x" * 1_000_000}],
            }
        ),
        encoding="utf-8",
    )
    original = "x" * 68
    (reference / "properties.txt").write_text(original, encoding="utf-8")
    (candidate / "properties.txt").write_text(original, encoding="utf-8")

    result = _run(str(reference), str(candidate), "--rules", str(rules))

    assert result.returncode == 2
    assert "cannot compare" in result.stderr
    assert "normalized output exceeds the 64 MiB limit" in result.stderr
    assert (reference / "properties.txt").read_text(encoding="utf-8") == original


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
