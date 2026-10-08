"""Synthetic tests for the boot-signal summary of reference capture records."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

TOOL = Path(__file__).parents[1] / "reference/boot_signals.py"

KERNEL_LINES = """\
Starting kernel ...

[    0.000000][    T0] Booting Linux on physical CPU 0x0000000000 [0x610f0000]
[    9.680866][    T1] init: init first stage started!
[   82.947406][    T1] init: starting service 'zygote'...
[  353.130169][  T670] VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON
[  269.205503][    T1] init: starting service 'zygote'...
"""


def _record(
    root: Path,
    name: str,
    *,
    kernel: str | None = KERNEL_LINES,
    console: str | None = None,
    launcher: str | None = None,
    host: dict[str, Any] | None = None,
) -> Path:
    record = root / name
    record.mkdir()
    if kernel is not None:
        (record / "kernel.log").write_text(kernel, encoding="utf-8")
    if console is not None:
        (record / "cvd-create-console.log").write_text(console, encoding="utf-8")
    if launcher is not None:
        (record / "launcher.log").write_text(launcher, encoding="utf-8")
    if host is not None:
        (record / "host.json").write_text(json.dumps(host), encoding="utf-8")
    return record


def _run(*records: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(TOOL), *map(str, records)],
        check=False,
        capture_output=True,
        text=True,
    )


def _summary(*records: Path) -> dict[str, Any]:
    result = _run(*records)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_reports_first_uptime_and_repeat_count_for_each_marker(tmp_path: Path) -> None:
    record = _record(
        tmp_path,
        "target-a",
        host={"profile": "target", "selectedGpuMode": "drm_virgl", "schemaVersion": 3},
    )
    kernel = _summary(record)["records"][0]["kernelLog"]
    assert kernel["lastUptimeSeconds"] == 269.205503
    markers = kernel["markers"]
    assert markers["uBootStartingKernel"] == {
        "count": 1,
        "firstLine": 1,
        "firstUptimeSeconds": None,
    }
    assert markers["linuxBooting"]["firstUptimeSeconds"] == 0.0
    assert markers["initFirstStage"]["firstUptimeSeconds"] == 9.680866
    assert markers["zygoteServiceStart"]["count"] == 2
    assert markers["zygoteServiceStart"]["firstUptimeSeconds"] == 82.947406


def test_virtual_device_shapes_are_fixed_tokens_with_key_value_fields(tmp_path: Path) -> None:
    record = _record(tmp_path, "display")
    virtual = _summary(record)["records"][0]["kernelLog"]["virtualDevice"]
    entry = virtual["VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED"]
    assert entry["count"] == 1
    assert entry["firstUptimeSeconds"] == 353.130169
    assert entry["shapes"] == {"VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON": 1}


def test_host_boot_state_lines_count_bare_tokens_and_ignore_prose(tmp_path: Path) -> None:
    record = _record(
        tmp_path,
        "failed",
        kernel=None,
        console="VIRTUAL_DEVICE_BOOT_FAILED\n",
        launcher=(
            "run_cvd(1)  E 10-02 22:44:54 1 1 boot_state_machine.cc:211] "
            "VIRTUAL_DEVICE_BOOT_FAILED\n"
            "note: no VIRTUAL_DEVICE_BOOT_COMPLETED marker was recorded.\n"
        ),
    )
    summary = _summary(record)
    host = summary["records"][0]["hostBootTokens"]
    assert host == {
        "cvd-create-console.log": {"VIRTUAL_DEVICE_BOOT_FAILED": 1},
        "launcher.log": {"VIRTUAL_DEVICE_BOOT_FAILED": 1},
    }
    assert summary["recordsWithBootFailed"] == 1
    assert summary["recordsWithBootCompleted"] == 0
    assert summary["records"][0]["kernelLog"] is None


def test_boot_completed_token_in_kernel_log_is_counted(tmp_path: Path) -> None:
    kernel = "[   12.000000][    T0] VIRTUAL_DEVICE_BOOT_COMPLETED\n"
    summary = _summary(_record(tmp_path, "done", kernel=kernel))
    assert summary["recordsWithBootCompleted"] == 1
    virtual = summary["records"][0]["kernelLog"]["virtualDevice"]
    assert virtual["VIRTUAL_DEVICE_BOOT_COMPLETED"]["firstUptimeSeconds"] == 12.0


def test_groups_are_separated_by_profile_and_selected_mode(tmp_path: Path) -> None:
    first = _record(
        tmp_path,
        "one",
        kernel="[    0.000000][    T0] Booting Linux on physical CPU\n"
        "[   80.000000][    T1] init: starting service 'zygote'...\n",
        host={"profile": "default", "selectedGpuMode": "guest_swiftshader", "schemaVersion": 3},
    )
    second = _record(
        tmp_path,
        "two",
        kernel="[    0.000000][    T0] Booting Linux on physical CPU\n"
        "[  100.000000][    T1] init: starting service 'zygote'...\n",
        host={"profile": "default", "selectedGpuMode": "guest_swiftshader", "schemaVersion": 3},
    )
    third = _record(
        tmp_path,
        "three",
        kernel="[    0.000000][    T0] Booting Linux on physical CPU\n"
        "[  500.000000][    T1] init: starting service 'zygote'...\n",
        host={"profile": "target", "selectedGpuMode": "drm_virgl", "schemaVersion": 3},
    )
    groups = _summary(first, second, third)["summaryByProfileAndSelectedGpuMode"]
    assert groups["default/guest_swiftshader"]["records"] == 2
    assert groups["default/guest_swiftshader"]["zygoteServiceStart"] == {
        "n": 2,
        "medianSeconds": 90.0,
        "minSeconds": 80.0,
        "maxSeconds": 100.0,
    }
    assert groups["target/drm_virgl"]["zygoteServiceStart"]["medianSeconds"] == 500.0


def test_missing_host_json_and_missing_logs_are_reported_as_null(tmp_path: Path) -> None:
    record = _record(tmp_path, "bare", kernel=None)
    summary = _summary(record)["records"][0]
    assert summary["profile"] is None
    assert summary["selectedGpuMode"] is None
    assert summary["kernelLog"] is None
    assert summary["hostBootTokens"] == {"cvd-create-console.log": None, "launcher.log": None}


def test_output_contains_no_host_path_or_raw_line(tmp_path: Path) -> None:
    record = _record(
        tmp_path,
        "private",
        kernel="[    0.000000][    T0] Booting Linux on physical CPU\n"
        "[   10.000000][    T1] serialno=SECRET123 /home/lima/private/path\n",
    )
    result = _run(record)
    assert result.returncode == 0, result.stderr
    assert str(tmp_path) not in result.stdout
    assert "SECRET123" not in result.stdout
    assert "/home/lima" not in result.stdout


def test_rejects_a_regular_file_passed_as_a_record(tmp_path: Path) -> None:
    path = tmp_path / "not-a-record.txt"
    path.write_text("x", encoding="utf-8")
    result = _run(path)
    assert result.returncode == 1
    assert "is not a plain directory" in result.stderr
    assert str(tmp_path) not in result.stderr


def test_rejects_a_symlinked_kernel_log(tmp_path: Path) -> None:
    record = _record(tmp_path, "linked", kernel=None)
    target = tmp_path / "elsewhere.log"
    target.write_text(KERNEL_LINES, encoding="utf-8")
    os.symlink(target, record / "kernel.log")
    result = _run(record)
    assert result.returncode == 1
    assert "without following links" in result.stderr


def test_rejects_an_oversized_kernel_log_without_reading_it(tmp_path: Path) -> None:
    record = _record(tmp_path, "huge", kernel=None)
    sparse = record / "kernel.log"
    sparse.touch()
    os.truncate(sparse, 64 * 1024 * 1024 + 1)
    result = _run(record)
    assert result.returncode == 1
    assert "exceeds" in result.stderr
