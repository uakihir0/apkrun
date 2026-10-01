from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import experiment_support

REFERENCE_HOST = {
    "hostKind": "linux-apple",
    "os": "Ubuntu 24.04.4 LTS",
    "kernel": "Linux 6.8.0-134-generic aarch64 GNU/Linux",
    "architecture": "aarch64",
    "cpuCount": 8,
    "nestedVirtualization": "on",
}


def _use_reference_host(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        experiment_support,
        "_current_host_fingerprint",
        lambda: dict(REFERENCE_HOST),
    )


def _make_baseline_repository(root: Path) -> tuple[Path, Path, Path, Path]:
    baseline = root / experiment_support.BASELINE_RELATIVE
    baseline.mkdir(parents=True)
    (baseline / "host.json").write_text(
        json.dumps(
            {
                "buildId": "16373615",
                "profile": "default",
                "cvdPackageVersion": "1.57.0",
                **REFERENCE_HOST,
                "cvdInstanceNumber": 1,
            }
        ),
        encoding="utf-8",
    )
    (baseline / "cuttlefish_config.json").write_text(
        json.dumps(
            {
                "instances": {
                    "1": {
                        "gpu_mode": "guest_swiftshader",
                        "cpus": 4,
                        "memory_mb": 4096,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (baseline / "cvd-create-console.log").write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n",
        encoding="utf-8",
    )
    for relative in experiment_support.TOOL_PATHS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"pinned source: {relative}\n", encoding="utf-8")
    experiment_root = root / "Experiments/cuttlefish-boot-diagnosis"
    experiment_root.mkdir(parents=True)
    for name in experiment_support.EXPERIMENT_TOOL_NAMES:
        (experiment_root / name).write_text(
            f"experiment source: {name}\n",
            encoding="utf-8",
        )
    patched_capture = root / "private-capture.sh"
    patched_capture.write_text("private patched capture\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=APKRun Test",
            "-c",
            "user.email=apkrun-test@example.invalid",
            "commit",
            "-q",
            "-m",
            "baseline fixture",
        ],
        cwd=root,
        check=True,
    )
    return root, baseline, experiment_root, patched_capture


def test_parse_fleet_report_requires_empty_fleet_and_identity() -> None:
    report = (
        "cvd(57044) I version: 1.57.0 | "
        "VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n'
    )

    assert experiment_support.parse_fleet_report(report) == {
        "packageVersion": "1.57.0",
        "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
    }


def test_parse_fleet_report_rejects_running_groups() -> None:
    report = (
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [{"name": "unexpected"}] }\n'
    )

    with pytest.raises(ValueError, match="must be empty"):
        experiment_support.parse_fleet_report(report)


def test_parse_fleet_report_rejects_unexpected_trailing_content() -> None:
    report = (
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n'
        "unexpected trailing output\n"
    )

    with pytest.raises(ValueError, match="unexpected trailing content"):
        experiment_support.parse_fleet_report(report)


def test_private_capture_patch_changes_only_gpu_adb_and_logcat_capture(
    tmp_path: Path,
) -> None:
    repo_root = Path(__file__).parents[3]
    source = repo_root / "Images/tools/reference/capture.sh"
    private_copy = tmp_path / "capture.sh"
    private_copy.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")

    experiment_support.patch_capture_script(private_copy)
    patched = private_copy.read_text(encoding="utf-8")

    subprocess.run(["bash", "-n", str(private_copy)], check=True)
    assert 'PATH="$APKRUN_DIAGNOSTIC_ADB_SHIM_DIR:$CVD_HOST_DIR/bin:$PATH"' in patched
    assert (
        "create_cvd_group_with_common_options --gpu_mode=none --cpus 4 --memory_mb 4096"
        in patched
    )
    assert "--timeout-seconds 30 --max-bytes 8388608" in patched
    assert '--output "$raw_log"' in patched
    assert "--max-bytes 1048576" in patched
    assert "--stdin --max-bytes 8388608" in patched
    assert "capture_adb_value 4096 10 adb devices" in patched
    assert "capture_adb_value 256 10 adb -s" in patched
    assert "record_adb_helper_cleanup" in patched
    assert "adb-helper-cleanup-incomplete.json" in patched
    assert 'capture_adb_value 4096 10 adb connect "127.0.0.1:$adb_port"' in patched
    assert 'capture_adb_value 4096 10 adb -s "$adb_serial" wait-for-device' in patched
    assert "run_with_boot_deadline adb" not in patched
    assert "--fail-on-truncate --output" in patched
    assert "set -euo pipefail" in patched
    assert patched.count("--gpu_mode=none") == 1
    assert (
        "default)\n      create_cvd_group_with_common_options --cpus 4 --memory_mb 4096"
        not in patched
    )


def test_baseline_must_use_the_expected_gpu_and_vm_shape(tmp_path: Path) -> None:
    _, baseline, _, _ = _make_baseline_repository(tmp_path)
    document = json.loads(
        (baseline / "cuttlefish_config.json").read_text(encoding="utf-8")
    )
    document["instances"]["1"]["gpu_mode"] = "none"
    (baseline / "cuttlefish_config.json").write_text(
        json.dumps(document),
        encoding="utf-8",
    )

    with pytest.raises(
        ValueError, match="baseline configuration has unexpected gpu_mode"
    ):
        experiment_support.validate_baseline_configuration(baseline)


def test_host_preflight_checks_tool_blobs_and_cvd_revision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )
    report = experiment_support.verify_host(
        repo_root, baseline, fleet_report, experiment_root, patched_capture
    )

    assert report["baselineCvd"] == report["observedCvd"]
    assert report["baselineHost"] == report["observedHost"]
    assert report["gpuMode"] == "none"
    assert report["cpuCount"] == 4
    assert len(report["toolBlobs"]) == len(experiment_support.TOOL_PATHS)
    assert (
        len(report["experimentSources"])
        == len(experiment_support.EXPERIMENT_TOOL_NAMES) + 1
    )


def test_host_preflight_rejects_changed_capture_tool(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    (repo_root / experiment_support.TOOL_PATHS[0]).write_text(
        "changed after the baseline\n",
        encoding="utf-8",
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from the baseline"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_cvd_revision_drift(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 0000000000000000000000000000000000000000\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from baseline"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_working_tree_baseline_tampering(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _use_reference_host(monkeypatch)
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    host_path = baseline / "host.json"
    host = json.loads(host_path.read_text(encoding="utf-8"))
    host["cvdPackageVersion"] = "9.99.0"
    host_path.write_text(json.dumps(host), encoding="utf-8")
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 9.99.0 | "
        "VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="differs from its committed revision"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_host_preflight_rejects_different_host_conditions(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    changed_host = dict(REFERENCE_HOST)
    changed_host["kernel"] = "Linux 6.8.1 aarch64 GNU/Linux"
    monkeypatch.setattr(
        experiment_support,
        "_current_host_fingerprint",
        lambda: changed_host,
    )
    repo_root, baseline, experiment_root, patched_capture = _make_baseline_repository(
        tmp_path
    )
    fleet_report = tmp_path / "fleet-report.txt"
    fleet_report.write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n"
        '{ "groups": [] }\n',
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="host differs from the pinned baseline"):
        experiment_support.verify_host(
            repo_root, baseline, fleet_report, experiment_root, patched_capture
        )


def test_experiment_record_validates_actual_gpu_mode_and_keeps_only_summary(
    tmp_path: Path,
) -> None:
    _make_baseline_repository(tmp_path / "repository")
    capture_record = tmp_path / "capture"
    capture_record.mkdir()
    (capture_record / "host.json").write_text(
        json.dumps(
            {
                "buildId": "16373615",
                "profile": "default",
                "cvdPackageVersion": "1.57.0",
                **REFERENCE_HOST,
                "cvdInstanceNumber": 1,
            }
        ),
        encoding="utf-8",
    )
    (capture_record / "cuttlefish_config.json").write_text(
        json.dumps(
            {"instances": {"1": {"gpu_mode": "none", "cpus": 4, "memory_mb": 4096}}}
        ),
        encoding="utf-8",
    )
    (capture_record / "cvd-create-console.log").write_text(
        "version: 1.57.0 | VCS: 9bb9c72329cedcb436bb75afc05c24d73fbcdf5d\n",
        encoding="utf-8",
    )
    capture_status_root = tmp_path / "capture-status"
    capture_status_root.mkdir()
    (capture_status_root / "guest-logcat.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 4096,
                "truncated": True,
                "timedOut": False,
                "childExitCode": -15,
                "signal": None,
                "cleanupComplete": True,
            }
        ),
        encoding="utf-8",
    )
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "baselineRecord": "Images/reference/16373615/incomplete/example",
                "buildId": "16373615",
                "baselineHost": {
                    **REFERENCE_HOST,
                    "cvdInstanceNumber": 1,
                },
                "observedHost": {
                    **REFERENCE_HOST,
                    "cvdInstanceNumber": 1,
                },
                "baselineCvd": {
                    "packageVersion": "1.57.0",
                    "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
                },
                "observedCvd": {
                    "packageVersion": "1.57.0",
                    "vcsRevision": "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d",
                },
                "baselineToolCommit": "1" * 40,
                "toolBlobs": {"capture.sh": "2" * 40},
                "experimentSources": {"patched-capture.sh": "3" * 64},
            }
        ),
        encoding="utf-8",
    )
    summary = tmp_path / "summary.json"
    summary.write_text(
        json.dumps({"schemaVersion": 1, "lineCount": 12, "systemServerLines": 0}),
        encoding="utf-8",
    )
    adb_state = tmp_path / "adb-state.txt"
    adb_state.write_text("2026-10-01T00:00:00Z\tadb=offline\n", encoding="utf-8")
    capture_run_status = tmp_path / "capture-run-status.json"
    capture_run_status.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "childExitCode": 1,
                "timedOut": False,
                "signal": None,
                "cleanupComplete": True,
            }
        ),
        encoding="utf-8",
    )

    record = experiment_support.build_experiment_record(
        capture_record,
        host_identity,
        summary,
        adb_state,
        1,
        "127.0.0.1:6520",
        capture_status_root,
        capture_run_status,
    )

    assert record["gpuMode"] == "none"
    assert (
        record["observedCvd"]["vcsRevision"]
        == "9bb9c72329cedcb436bb75afc05c24d73fbcdf5d"
    )
    assert record["guestLogcatCapture"]["truncated"] is True
    assert record["rawLogcatRetained"] is False
    assert record["boundedCapture"]["aggregateBytes"] == 4096
    assert record["adbServerTransport"] == "localfilesystem"
    assert "patched-capture.sh" in record["experimentSources"]
    assert "logcat.txt.gz" not in json.dumps(record)

    incomplete_cleanup = capture_status_root / "adb-helper-cleanup-incomplete.json"
    incomplete_cleanup.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 0,
                "truncated": False,
                "timedOut": False,
                "childExitCode": None,
                "signal": None,
                "cleanupComplete": False,
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="cleanup is incomplete"):
        experiment_support.build_experiment_record(
            capture_record,
            host_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
        )
    incomplete_cleanup.unlink()

    host_identity_doc = json.loads(host_identity.read_text(encoding="utf-8"))
    host_identity_doc["observedCvd"]["vcsRevision"] = "0" * 40
    altered_identity = tmp_path / "altered-host-identity.json"
    altered_identity.write_text(json.dumps(host_identity_doc), encoding="utf-8")
    with pytest.raises(ValueError, match="differs from the pinned baseline"):
        experiment_support.build_experiment_record(
            capture_record,
            altered_identity,
            summary,
            adb_state,
            1,
            "127.0.0.1:6520",
            capture_status_root,
            capture_run_status,
        )
