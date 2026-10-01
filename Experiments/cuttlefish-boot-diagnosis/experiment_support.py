#!/usr/bin/env python3
"""Validate the isolated Cuttlefish GPU-mode comparison and record provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

BASELINE_RELATIVE = Path(
    "Images/reference/16373615/incomplete/default-20261001T120904-49816"
)
TOOL_PATHS = (
    Path("Images/tools/reference/capture.sh"),
    Path("Images/tools/reference/capture_cvd_start.py"),
    Path("Images/tools/reference/compare_boot.py"),
    Path("Images/tools/reference/normalize.yaml"),
    Path("Images/tools/reference/guest-capture.txt"),
    Path("Images/manifests/16373615/android-image.json"),
)
EXPERIMENT_TOOL_NAMES = (
    "capture-gpu-none.sh",
    "capture_bounded.py",
    "experiment_support.py",
    "run_capture.py",
    "summarize_logcat.py",
)
HOST_FACT_FIELDS = (
    "hostKind",
    "os",
    "kernel",
    "architecture",
    "cpuCount",
    "nestedVirtualization",
)
VCS_PATTERN = re.compile(r"\bVCS:\s*([0-9a-f]{40})\b", re.IGNORECASE)
VERSION_PATTERN = re.compile(
    r"\bversion:\s*([0-9][0-9A-Za-z._-]*)\s*\|\s*VCS:\s*([0-9a-f]{40})\b",
    re.IGNORECASE,
)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON file {path.name}") from error
    if not isinstance(document, dict):
        raise TypeError(f"JSON file {path.name} must contain an object")
    return document


def _baseline_host_fingerprint(host: dict[str, Any]) -> dict[str, Any]:
    fingerprint = {field: host.get(field) for field in HOST_FACT_FIELDS}
    if (
        not all(
            isinstance(fingerprint[field], str)
            for field in HOST_FACT_FIELDS
            if field != "cpuCount"
        )
        or type(fingerprint["cpuCount"]) is not int
        or fingerprint["cpuCount"] < 1
    ):
        raise ValueError("committed baseline is missing valid reference-host details")
    if type(host.get("cvdInstanceNumber")) is not int:
        raise ValueError("committed baseline is missing its Cuttlefish instance number")
    fingerprint["cvdInstanceNumber"] = host["cvdInstanceNumber"]
    if fingerprint["cvdInstanceNumber"] != 1:
        raise ValueError("the pinned baseline must use Cuttlefish instance 1")
    return fingerprint


def _current_host_fingerprint() -> dict[str, Any]:
    try:
        kernel_result = subprocess.run(
            ["uname", "-srmo"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        cpu_count = os.sysconf("SC_NPROCESSORS_ONLN")
        os_name = platform.freedesktop_os_release().get("PRETTY_NAME", "Linux")
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise ValueError(
            "could not identify the current Cuttlefish reference host"
        ) from error
    if kernel_result.returncode != 0 or not kernel_result.stdout.strip():
        raise ValueError("could not identify the current Linux kernel")
    try:
        virtualization_result = subprocess.run(
            ["systemd-detect-virt", "--vm"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        virtualization = (
            virtualization_result.stdout.strip()
            if virtualization_result.returncode == 0
            else ""
        )
    except (OSError, subprocess.TimeoutExpired):
        virtualization = ""
    if virtualization in {"", "none"}:
        host_kind = "linux"
        nested_virtualization = "off"
    else:
        host_kind = f"linux-{virtualization}"
        kvm_device = Path("/dev/kvm")
        nested_virtualization = (
            "on"
            if kvm_device.is_char_device() and os.access(kvm_device, os.R_OK | os.W_OK)
            else "off"
        )
    if type(cpu_count) is not int or cpu_count < 1:
        raise ValueError("current reference-host CPU count is invalid")
    return {
        "hostKind": host_kind,
        "os": os_name,
        "kernel": kernel_result.stdout.strip(),
        "architecture": platform.machine(),
        "cpuCount": cpu_count,
        "nestedVirtualization": nested_virtualization,
    }


def _git(repo_root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(
            f"git {arguments[0]} failed while verifying capture provenance"
        )
    return result.stdout.strip()


def _git_blob_text(repo_root: Path, revision: str) -> str:
    result = subprocess.run(
        ["git", "show", revision],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError("git show failed while verifying the committed baseline")
    return result.stdout


def _baseline_commit(repo_root: Path, baseline_record: Path) -> str:
    baseline_host = baseline_record / "host.json"
    try:
        relative = baseline_host.relative_to(repo_root)
    except ValueError as error:
        raise ValueError("baseline record must be inside the repository") from error
    commit = _git(
        repo_root,
        "log",
        "-1",
        "--format=%H",
        "--",
        relative.as_posix(),
    )
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("could not identify the committed baseline record revision")
    return commit


def _verify_tool_revisions(
    repo_root: Path,
    baseline_record: Path,
) -> tuple[str, dict[str, str]]:
    commit = _baseline_commit(repo_root, baseline_record)
    blobs: dict[str, str] = {}
    for path in TOOL_PATHS:
        baseline_blob = _git(repo_root, "rev-parse", f"{commit}:{path.as_posix()}")
        current_blob = _git(repo_root, "hash-object", "--", path.as_posix())
        if not re.fullmatch(r"[0-9a-f]{40}", baseline_blob):
            raise ValueError(f"baseline is missing tracked tool {path.as_posix()}")
        if current_blob != baseline_blob:
            raise ValueError(
                f"capture tool differs from the baseline revision: {path.as_posix()}"
            )
        blobs[path.as_posix()] = current_blob
    return commit, blobs


def _experiment_source_hashes(
    experiment_root: Path,
    patched_capture: Path,
) -> dict[str, str]:
    sources: dict[str, str] = {}
    for name in EXPERIMENT_TOOL_NAMES:
        path = experiment_root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"experiment source is missing or unsafe: {name}")
        sources[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if patched_capture.is_symlink() or not patched_capture.is_file():
        raise ValueError("patched capture script is missing or unsafe")
    sources["patched-capture.sh"] = hashlib.sha256(
        patched_capture.read_bytes()
    ).hexdigest()
    return sources


def _capture_statuses(status_root: Path) -> dict[str, Any]:
    if status_root.is_symlink() or not status_root.is_dir():
        raise ValueError("capture status directory must be a real directory")
    status_files = sorted(status_root.glob("*.json"))
    if len(status_files) > 100:
        raise ValueError("too many bounded capture status records")
    files: dict[str, dict[str, int | bool | None]] = {}
    for path in status_files:
        if path.is_symlink() or not re.fullmatch(r"[A-Za-z0-9_.-]+", path.stem):
            raise ValueError("capture status file has an unsafe name")
        status = _read_json(path)
        bytes_written = status.get("bytesWritten")
        truncated = status.get("truncated")
        timed_out = status.get("timedOut")
        child_exit = status.get("childExitCode")
        signal_number = status.get("signal")
        cleanup_complete = status.get("cleanupComplete")
        if (
            type(bytes_written) is not int
            or bytes_written < 0
            or not isinstance(truncated, bool)
            or not isinstance(timed_out, bool)
            or (child_exit is not None and type(child_exit) is not int)
            or (signal_number is not None and type(signal_number) is not int)
            or not isinstance(cleanup_complete, bool)
        ):
            raise ValueError(f"capture status has invalid fields: {path.name}")
        if not cleanup_complete:
            raise ValueError(
                f"capture process group cleanup is incomplete: {path.name}"
            )
        files[path.stem] = {
            "bytesWritten": bytes_written,
            "truncated": truncated,
            "timedOut": timed_out,
            "childExitCode": child_exit,
            "signal": signal_number,
            "cleanupComplete": cleanup_complete,
        }
    aggregate_bytes = sum(record["bytesWritten"] for record in files.values())
    if aggregate_bytes > 64 * 1024 * 1024:
        raise ValueError("aggregate bounded capture output exceeds 64 MiB")
    return {
        "aggregateBytes": aggregate_bytes,
        "files": files,
        "truncatedFiles": sorted(
            name for name, record in files.items() if record["truncated"]
        ),
        "timedOutFiles": sorted(
            name for name, record in files.items() if record["timedOut"]
        ),
    }


def _gpu_configuration(record: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    host = _read_json(record / "host.json")
    config = _read_json(record / "cuttlefish_config.json")
    return host, _single_instance(config)


def _single_instance(config: dict[str, Any]) -> dict[str, Any]:
    instances = config.get("instances")
    if not isinstance(instances, dict) or len(instances) != 1:
        raise ValueError("capture must contain exactly one Cuttlefish Android instance")
    instance = next(iter(instances.values()))
    if not isinstance(instance, dict):
        raise TypeError("Cuttlefish instance configuration must be an object")
    return instance


def validate_baseline_configuration(baseline_record: Path) -> dict[str, Any]:
    host, instance = _gpu_configuration(baseline_record)
    if host.get("buildId") != "16373615" or host.get("profile") != "default":
        raise ValueError("baseline must be the pinned build 16373615 default capture")
    _baseline_host_fingerprint(host)
    expected = {
        "gpu_mode": "guest_swiftshader",
        "cpus": 4,
        "memory_mb": 4096,
    }
    for key, value in expected.items():
        if instance.get(key) != value:
            raise ValueError(f"baseline configuration has unexpected {key}")
    return host


def parse_fleet_report(report: str) -> dict[str, str]:
    banner = VERSION_PATTERN.search(report)
    if banner is None:
        raise ValueError(
            "Cuttlefish fleet output did not include a version and VCS banner"
        )
    opening = report.find("{")
    if opening < 0:
        raise ValueError("Cuttlefish fleet output did not include its group list")
    try:
        payload = report[opening:]
        fleet, end = json.JSONDecoder().raw_decode(payload)
    except json.JSONDecodeError as error:
        raise ValueError("Cuttlefish fleet output contained invalid JSON") from error
    if payload[end:].strip():
        raise ValueError(
            "Cuttlefish fleet output contained unexpected trailing content"
        )
    groups = fleet.get("groups") if isinstance(fleet, dict) else None
    if groups != []:
        raise ValueError("Cuttlefish fleet must be empty before the experiment")
    return {
        "packageVersion": banner.group(1),
        "vcsRevision": banner.group(2).lower(),
    }


def _committed_baseline(
    repo_root: Path,
    baseline_record: Path,
    commit: str,
) -> tuple[dict[str, Any], dict[str, Any], str]:
    relative_record = baseline_record.relative_to(repo_root)
    contents: dict[str, str] = {}
    for filename in ("host.json", "cuttlefish_config.json", "cvd-create-console.log"):
        relative = (relative_record / filename).as_posix()
        committed = _git_blob_text(repo_root, f"{commit}:{relative}")
        try:
            working = (baseline_record / filename).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise ValueError(f"baseline file is unavailable: {filename}") from error
        if working != committed:
            raise ValueError(
                f"baseline file differs from its committed revision: {filename}"
            )
        contents[filename] = committed
    try:
        host = json.loads(contents["host.json"])
        config = json.loads(contents["cuttlefish_config.json"])
    except json.JSONDecodeError as error:
        raise ValueError("committed baseline contains invalid JSON") from error
    if not isinstance(host, dict) or not isinstance(config, dict):
        raise TypeError("committed baseline JSON files must contain objects")
    instance = _single_instance(config)
    if host.get("buildId") != "16373615" or host.get("profile") != "default":
        raise ValueError("baseline must be the pinned build 16373615 default capture")
    expected = {"gpu_mode": "guest_swiftshader", "cpus": 4, "memory_mb": 4096}
    for key, value in expected.items():
        if instance.get(key) != value:
            raise ValueError(f"baseline configuration has unexpected {key}")
    return host, instance, contents["cvd-create-console.log"]


def patch_capture_script(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError("private capture script must be a regular file")
    source = path.read_text(encoding="utf-8")
    replacements = (
        ("#!/bin/sh\n", "#!/usr/bin/env bash\n"),
        ("set -eu\n", "set -euo pipefail\n"),
        (
            'PATH="$CVD_HOST_DIR/bin:$PATH"',
            'PATH="$APKRUN_DIAGNOSTIC_ADB_SHIM_DIR:$CVD_HOST_DIR/bin:$PATH"',
        ),
        (
            ('capture_adb() {\n  HOME="$cvd_home" APKRUN_CAPTURE_PID=$$ adb "$@"\n}\n'),
            (
                "capture_adb() {\n"
                '  HOME="$cvd_home" APKRUN_CAPTURE_PID=$$ adb "$@"\n'
                "}\n"
                "\n"
                "record_adb_helper_cleanup() {\n"
                "  local status_path=$1\n"
                '  local marker="$APKRUN_EXPERIMENT_STATUS_ROOT/adb-helper-cleanup-incomplete.json"\n'
                '  if [ -f "$status_path" ] && [ ! -L "$status_path" ] \\\n'
                '    && grep -Fq \'"cleanupComplete": true\' "$status_path"; then\n'
                "    return 0\n"
                "  fi\n"
                '  printf \'%s\\n\' \'{"schemaVersion":1,"bytesWritten":0,"truncated":false,"timedOut":false,"childExitCode":null,"signal":null,"cleanupComplete":false}\' \\\n'
                '    > "$marker" || return 1\n'
                "  return 1\n"
                "}\n"
                "\n"
                "capture_adb_value() {\n"
                "  local maximum_bytes=$1 command_timeout=$2\n"
                "  shift 2\n"
                '  local token="${BASHPID:-$$}-$RANDOM"\n'
                '  local output_path="$TMPDIR/.apkrun-adb-$token"\n'
                '  local status_path="$TMPDIR/.apkrun-adb-$token.json"\n'
                "  local command_status=0 command_now command_remaining\n"
                "  command_now=$(date +%s)\n"
                "  command_remaining=$((boot_timeout_deadline - command_now))\n"
                '  if [ "$command_remaining" -le 0 ]; then\n'
                "    boot_deadline_expired=1\n"
                "    return 124\n"
                "  fi\n"
                '  if [ "$command_timeout" -gt "$command_remaining" ]; then\n'
                "    command_timeout=$command_remaining\n"
                "  fi\n"
                '  if python3 "$script_dir/capture_bounded.py" \\\n'
                '    --timeout-seconds "$command_timeout" --max-bytes "$maximum_bytes" \\\n'
                '    --fail-on-truncate --output "$output_path" --status "$status_path" -- \\\n'
                '    env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb "$@"; then\n'
                '    if cat "$output_path"; then\n'
                "      :\n"
                "    else\n"
                "      command_status=$?\n"
                "    fi\n"
                "  else\n"
                "    command_status=$?\n"
                "  fi\n"
                '  if ! record_adb_helper_cleanup "$status_path"; then\n'
                "    command_status=1\n"
                "  fi\n"
                '  rm -f "$output_path" "$status_path"\n'
                '  return "$command_status"\n'
                "}\n"
            ),
        ),
        (
            (
                "adb_preflight_timeout_seconds=10\n"
                "if adb_device_list=$(timeout --kill-after=2s "
                '"$adb_preflight_timeout_seconds" adb devices); then\n'
                "  :\n"
                "else\n"
                "  printf 'ADB did not respond during the %s-second preflight; check the ADB server and retry.\\n' \\\n"
                '    "$adb_preflight_timeout_seconds" >&2\n'
                "  exit 1\n"
                "fi"
            ),
            (
                "adb_preflight_timeout_seconds=10\n"
                'adb_preflight_token="${BASHPID:-$$}-$RANDOM"\n'
                'adb_preflight_output="$TMPDIR/.apkrun-adb-preflight-$adb_preflight_token"\n'
                'adb_preflight_status="$adb_preflight_output.json"\n'
                "adb_preflight_status_code=0\n"
                'if python3 "$script_dir/capture_bounded.py" \\\n'
                '  --timeout-seconds "$adb_preflight_timeout_seconds" --max-bytes 4096 \\\n'
                '  --fail-on-truncate --output "$adb_preflight_output" \\\n'
                '  --status "$adb_preflight_status" -- \\\n'
                '  env "APKRUN_CAPTURE_PID=$$" adb devices; then\n'
                '  if adb_device_list=$(cat "$adb_preflight_output"); then\n'
                "    :\n"
                "  else\n"
                "    adb_preflight_status_code=$?\n"
                "  fi\n"
                "else\n"
                "  adb_preflight_status_code=$?\n"
                "fi\n"
                'if [ ! -f "$adb_preflight_status" ] || [ -L "$adb_preflight_status" ] \\\n'
                '  || ! grep -Fq \'"cleanupComplete": true\' "$adb_preflight_status"; then\n'
                '  printf \'%s\\n\' \'{"schemaVersion":1,"bytesWritten":0,"truncated":false,"timedOut":false,"childExitCode":null,"signal":null,"cleanupComplete":false}\' \\\n'
                '    > "$APKRUN_EXPERIMENT_STATUS_ROOT/adb-helper-cleanup-incomplete.json" \\\n'
                "    || adb_preflight_status_code=1\n"
                "fi\n"
                'rm -f "$adb_preflight_output" "$adb_preflight_status"\n'
                'if [ "$adb_preflight_status_code" -ne 0 ]; then\n'
                "  printf 'ADB did not respond during the %s-second preflight; check the ADB server and retry.\\n' \\\n"
                '    "$adb_preflight_timeout_seconds" >&2\n'
                "  exit 1\n"
                "fi"
            ),
        ),
        (
            (
                "default)\n"
                "      create_cvd_group_with_common_options --cpus 4 --memory_mb 4096\n"
                "      ;;"
            ),
            (
                "default)\n"
                "      create_cvd_group_with_common_options --gpu_mode=none --cpus 4 --memory_mb 4096\n"
                "      ;;"
            ),
        ),
        (
            (
                '          if capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \\\n'
                '            > "$raw_log" 2>/dev/null; then'
            ),
            (
                '          if python3 "$script_dir/capture_bounded.py" \\\n'
                "            --timeout-seconds 30 --max-bytes 8388608 \\\n"
                '            --output "$raw_log" \\\n'
                '            --status "$APKRUN_EXPERIMENT_STATUS_ROOT/guest-logcat.json" -- \\\n'
                '            env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb \\\n'
                '              -s "$adb_serial" exec-out sh -c "$guest_command"; then'
            ),
        ),
        (
            (
                '        elif ! capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \\\n'
                '          > "$stage/$output_file" 2>/dev/null; then'
            ),
            (
                '        elif ! python3 "$script_dir/capture_bounded.py" \\\n'
                "          --timeout-seconds 30 --max-bytes 1048576 \\\n"
                '          --output "$stage/$output_file" \\\n'
                '          --status "$APKRUN_EXPERIMENT_STATUS_ROOT/guest-${output_file}.json" -- \\\n'
                '          env "HOME=$cvd_home" "APKRUN_CAPTURE_PID=$$" adb \\\n'
                '            -s "$adb_serial" exec-out sh -c "$guest_command"; then'
            ),
        ),
        (
            (
                'if ! launch_profile > "$stage/cvd-create-console.log" 2>&1 \\\n'
                '  || ! run_cvd_command_with_live_logs cvd "--group_name=$cvd_group_name" start \\\n'
                '    >> "$stage/cvd-create-console.log" 2>&1; then'
            ),
            (
                ': > "$stage/cvd-create-console.log"\n'
                "cvd_command_failed=0\n"
                'if ! launch_profile 2>&1 | python3 "$script_dir/capture_bounded.py" \\\n'
                '  --stdin --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
                '  --status "$APKRUN_EXPERIMENT_STATUS_ROOT/cvd-create.json" --append; then\n'
                "  cvd_command_failed=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -eq 0 ] \\\n'
                '  && ! run_cvd_command_with_live_logs cvd "--group_name=$cvd_group_name" start 2>&1 \\\n'
                '    | python3 "$script_dir/capture_bounded.py" \\\n'
                '      --stdin --max-bytes 8388608 --output "$stage/cvd-create-console.log" \\\n'
                '      --status "$APKRUN_EXPERIMENT_STATUS_ROOT/cvd-start.json" --append; then\n'
                "  cvd_command_failed=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -ne 0 ]; then'
            ),
        ),
        (
            (
                '  HOME="$cvd_home" timeout --kill-after=2s 10 \\\n'
                '    adb disconnect "127.0.0.1:$adb_port" >/dev/null 2>&1 || true\n'
            ),
            (
                '  capture_adb_value 4096 10 adb disconnect "127.0.0.1:$adb_port" \\\n'
                "    >/dev/null 2>&1 || true\n"
            ),
        ),
        (
            (
                '    run_with_boot_deadline adb connect "127.0.0.1:$adb_port" \\\n'
                "      >/dev/null 2>&1 || true"
            ),
            (
                '    capture_adb_value 4096 10 adb connect "127.0.0.1:$adb_port" \\\n'
                "      >/dev/null 2>&1 || true"
            ),
        ),
        (
            "if adb_devices=$(run_with_boot_deadline adb devices 2>/dev/null); then",
            "if adb_devices=$(capture_adb_value 4096 10 adb devices 2>/dev/null); then",
        ),
        (
            (
                'if boot_state=$(run_with_boot_deadline adb -s "$adb_serial" \\\n'
                "        shell getprop sys.boot_completed 2>/dev/null); then"
            ),
            (
                'if boot_state=$(capture_adb_value 256 10 adb -s "$adb_serial" \\\n'
                "        shell getprop sys.boot_completed 2>/dev/null); then"
            ),
        ),
        (
            (
                '    if ! run_with_boot_deadline adb -s "$adb_serial" wait-for-device \\\n'
                "      >/dev/null 2>&1; then"
            ),
            (
                '    if ! capture_adb_value 4096 10 adb -s "$adb_serial" wait-for-device \\\n'
                "      >/dev/null 2>&1; then"
            ),
        ),
        (
            (
                'if [ "$cvd_command_failed" -ne 0 ]; then\n'
                '  if [ "$boot_deadline_expired" -eq 1 ]; then'
            ),
            (
                'if [ "$cvd_command_failed" -ne 0 ] \\\n'
                '  && [ "$(date +%s)" -ge "$boot_timeout_deadline" ]; then\n'
                "  boot_deadline_expired=1\n"
                "fi\n"
                'if [ "$cvd_command_failed" -ne 0 ]; then\n'
                '  if [ "$boot_deadline_expired" -eq 1 ]; then'
            ),
        ),
    )
    for old, new in replacements:
        if source.count(old) != 1:
            raise ValueError(
                "private capture script no longer matches the reviewed baseline"
            )
        source = source.replace(old, new)
    path.write_text(source, encoding="utf-8")


def verify_host(
    repo_root: Path,
    baseline_record: Path,
    fleet_report_path: Path,
    experiment_root: Path,
    patched_capture: Path,
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    baseline_record = baseline_record.resolve()
    commit = _baseline_commit(repo_root, baseline_record)
    baseline, _, baseline_console = _committed_baseline(
        repo_root,
        baseline_record,
        commit,
    )
    revision = VCS_PATTERN.search(baseline_console)
    version = baseline.get("cvdPackageVersion")
    if not isinstance(version, str) or revision is None:
        raise ValueError("committed baseline does not identify Cuttlefish")
    baseline_host = _baseline_host_fingerprint(baseline)
    observed_host = _current_host_fingerprint()
    if observed_host != {key: baseline_host[key] for key in HOST_FACT_FIELDS}:
        raise ValueError(
            "current Linux host differs from the pinned baseline host conditions"
        )
    observed_host["cvdInstanceNumber"] = baseline_host["cvdInstanceNumber"]
    expected_identity = {
        "packageVersion": version,
        "vcsRevision": revision.group(1).lower(),
    }
    try:
        report = fleet_report_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("cannot read the private Cuttlefish fleet report") from error
    observed_identity = parse_fleet_report(report)
    if observed_identity != expected_identity:
        raise ValueError(
            "installed Cuttlefish version or VCS revision differs from baseline"
        )
    _, blobs = _verify_tool_revisions(repo_root, baseline_record)
    experiment_sources = _experiment_source_hashes(experiment_root, patched_capture)
    return {
        "schemaVersion": 1,
        "baselineRecord": BASELINE_RELATIVE.as_posix(),
        "baselineCvd": expected_identity,
        "observedCvd": observed_identity,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": commit,
        "toolBlobs": blobs,
        "experimentSources": experiment_sources,
        "baselineGpuMode": "guest_swiftshader",
        "gpuMode": "none",
        "cpuCount": 4,
        "memoryMb": 4096,
        "buildId": baseline["buildId"],
    }


def build_experiment_record(
    capture_record: Path,
    host_identity_path: Path,
    logcat_summary_path: Path,
    adb_state_path: Path,
    capture_exit_code: int,
    adb_endpoint: str,
    capture_status_root: Path,
    capture_run_status_path: Path,
) -> dict[str, Any]:
    host, instance = _gpu_configuration(capture_record)
    host_identity = _read_json(host_identity_path)
    logcat_summary = _read_json(logcat_summary_path)
    capture_run_status = _read_json(capture_run_status_path)
    baseline_cvd = host_identity.get("baselineCvd")
    observed_cvd = host_identity.get("observedCvd")
    baseline_host = host_identity.get("baselineHost")
    observed_host = host_identity.get("observedHost")
    if not isinstance(baseline_cvd, dict):
        raise TypeError("verified baseline Cuttlefish identity is missing")
    if not isinstance(observed_cvd, dict):
        raise TypeError("verified Cuttlefish host identity is missing")
    if observed_cvd != baseline_cvd:
        raise ValueError(
            "observed Cuttlefish identity differs from the pinned baseline"
        )
    if not isinstance(baseline_host, dict) or not isinstance(observed_host, dict):
        raise TypeError("verified baseline host conditions are missing")
    if baseline_host != observed_host:
        raise ValueError("verified reference host differs from the pinned baseline")
    captured_host = {
        field: host.get(field) for field in (*HOST_FACT_FIELDS, "cvdInstanceNumber")
    }
    if captured_host != observed_host:
        raise ValueError("captured reference host differs from the verified host")
    if (
        capture_run_status.get("timedOut") is not False
        or capture_run_status.get("signal") is not None
        or capture_run_status.get("childExitCode") != capture_exit_code
        or capture_run_status.get("cleanupComplete") is not True
    ):
        raise ValueError("capture runner did not finish within its verified deadline")
    console_path = capture_record / "cvd-create-console.log"
    try:
        console_text = console_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError("capture Cuttlefish console log is unavailable") from error
    capture_banner = VERSION_PATTERN.search(console_text)
    if (
        capture_banner is None
        or {
            "packageVersion": capture_banner.group(1),
            "vcsRevision": capture_banner.group(2).lower(),
        }
        != observed_cvd
    ):
        raise ValueError("capture Cuttlefish identity differs from preflight")
    if host.get("buildId") != host_identity.get("buildId"):
        raise ValueError("captured Android build differs from the verified baseline")
    if host.get("profile") != "default":
        raise ValueError("diagnostic capture did not use the default capture profile")
    if host.get("cvdPackageVersion") != baseline_cvd.get("packageVersion"):
        raise ValueError("capture metadata records an unexpected Cuttlefish version")
    expected = {"gpu_mode": "none", "cpus": 4, "memory_mb": 4096}
    for key, value in expected.items():
        if instance.get(key) != value:
            raise ValueError(f"captured Cuttlefish configuration has unexpected {key}")
    if not re.fullmatch(r"127\.0\.0\.1:[0-9]{1,5}", adb_endpoint):
        raise ValueError("ADB endpoint must be a loopback address and TCP port")
    if adb_state_path.is_symlink() or not adb_state_path.is_file():
        raise ValueError("ADB state record must be a regular file")
    state_sample_count = sum(
        1 for line in adb_state_path.read_text(encoding="utf-8").splitlines() if line
    )
    if not all(isinstance(value, (int, bool)) for value in logcat_summary.values()):
        raise ValueError("logcat summary contains unexpected non-numeric data")
    bounded_capture = _capture_statuses(capture_status_root)
    guest_logcat = bounded_capture["files"].get(
        "guest-logcat",
        {
            "bytesWritten": 0,
            "truncated": False,
            "timedOut": False,
            "childExitCode": None,
            "signal": None,
            "cleanupComplete": True,
        },
    )
    guest_logcat["captured"] = "guest-logcat" in bounded_capture["files"]
    return {
        "schemaVersion": 1,
        "experiment": "cuttlefish-gpu-none-boot-diagnosis",
        "baselineRecord": host_identity["baselineRecord"],
        "buildId": host_identity["buildId"],
        "baselineCvd": baseline_cvd,
        "observedCvd": observed_cvd,
        "baselineHost": baseline_host,
        "observedHost": observed_host,
        "baselineToolCommit": host_identity["baselineToolCommit"],
        "toolBlobs": host_identity["toolBlobs"],
        "experimentSources": host_identity["experimentSources"],
        "captureExitCode": capture_exit_code,
        "captureRun": capture_run_status,
        "bootTimeoutSeconds": 600,
        "runnerDeadlineSeconds": 900,
        "gpuMode": "none",
        "cpuCount": 4,
        "memoryMb": 4096,
        "adbEndpoint": adb_endpoint,
        "adbServerTransport": "localfilesystem",
        "adbStateSampleCount": state_sample_count,
        "logcat": logcat_summary,
        "boundedCapture": bounded_capture,
        "guestLogcatCapture": guest_logcat,
        "rawLogcatRetained": False,
    }


def _atomic_json(path: Path, document: dict[str, Any]) -> None:
    if path.is_symlink():
        raise ValueError("JSON destination must not be a symlink")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    host_parser = subparsers.add_parser("verify-host")
    host_parser.add_argument("--repo-root", type=Path, required=True)
    host_parser.add_argument("--baseline-record", type=Path, required=True)
    host_parser.add_argument("--fleet-report", type=Path, required=True)
    host_parser.add_argument("--experiment-root", type=Path, required=True)
    host_parser.add_argument("--patched-capture", type=Path, required=True)
    host_parser.add_argument("--output", type=Path, required=True)

    patch_parser = subparsers.add_parser("patch-capture")
    patch_parser.add_argument("--path", type=Path, required=True)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--capture-record", type=Path, required=True)
    record_parser.add_argument("--host-identity", type=Path, required=True)
    record_parser.add_argument("--logcat-summary", type=Path, required=True)
    record_parser.add_argument("--adb-state", type=Path, required=True)
    record_parser.add_argument("--capture-exit-code", type=int, required=True)
    record_parser.add_argument("--adb-endpoint", required=True)
    record_parser.add_argument("--capture-status-root", type=Path, required=True)
    record_parser.add_argument("--capture-run-status", type=Path, required=True)
    record_parser.add_argument("--output", type=Path, required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "patch-capture":
            patch_capture_script(arguments.path)
            return 0
        if arguments.command == "verify-host":
            document = verify_host(
                arguments.repo_root.resolve(),
                arguments.baseline_record,
                arguments.fleet_report,
                arguments.experiment_root,
                arguments.patched_capture,
            )
        else:
            document = build_experiment_record(
                arguments.capture_record,
                arguments.host_identity,
                arguments.logcat_summary,
                arguments.adb_state,
                arguments.capture_exit_code,
                arguments.adb_endpoint,
                arguments.capture_status_root,
                arguments.capture_run_status,
            )
        _atomic_json(arguments.output, document)
    except (OSError, TypeError, ValueError, KeyError) as error:
        parser.exit(1, f"experiment_support: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
