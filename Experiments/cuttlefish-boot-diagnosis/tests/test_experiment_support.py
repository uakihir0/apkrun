from __future__ import annotations

import errno
import json
import os
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


def _mark_generated_workspace(work_root: Path, ownership_token: str) -> None:
    experiment_support.prepare_private_data_root(work_root.parent.parent)
    os.chmod(work_root, 0o700)
    marker = f"APKRun Cuttlefish boot diagnosis v1\n{ownership_token}\n{work_root}\n"
    (work_root / ".apkrun-cuttlefish-workspace").write_text(
        marker,
        encoding="utf-8",
    )


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


def test_prepare_private_data_root_locks_custom_directories_and_rejects_shared_parent(
    tmp_path: Path,
) -> None:
    safe_parent = tmp_path / "safe-parent"
    safe_parent.mkdir(mode=0o700)
    data_root = safe_parent / "diagnostics"
    data_root.mkdir(mode=0o777)
    (data_root / "work").mkdir(mode=0o777)
    (data_root / "results").mkdir(mode=0o777)

    experiment_support.prepare_private_data_root(data_root)

    for path in (data_root, data_root / "work", data_root / "results"):
        assert path.stat().st_uid == os.getuid()
        assert path.stat().st_mode & 0o777 == 0o700

    unsafe_parent = tmp_path / "shared-parent"
    unsafe_parent.mkdir(mode=0o777)
    unsafe_root = unsafe_parent / "diagnostics"
    with pytest.raises(ValueError, match="writable parent"):
        experiment_support.prepare_private_data_root(unsafe_root)
    assert not unsafe_root.exists()
    os.chmod(unsafe_parent, 0o700)


def test_prepare_data_root_prints_a_canonical_path_for_workspace_markers(
    tmp_path: Path,
) -> None:
    canonical_root = tmp_path / "diagnostics"
    requested_root = f"{tmp_path}//diagnostics/./"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(experiment_support.__file__)),
            "prepare-data-root",
            "--print-canonical",
            "--data-root",
            requested_root,
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(canonical_root)
    work_root = canonical_root / "work/gpu-none.test123"
    work_root.mkdir(mode=0o700)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    work_descriptor = experiment_support._open_directory_chain(work_root)
    try:
        experiment_support._verify_workspace_marker(
            work_descriptor,
            work_root,
            ownership_token,
        )
    finally:
        os.close(work_descriptor)


@pytest.mark.parametrize("control_character", ["\n", "\u0085"])
def test_prepare_data_root_rejects_paths_with_control_characters(
    tmp_path: Path,
    control_character: str,
) -> None:
    unsafe_root = tmp_path / f"diagnostics{control_character}"

    with pytest.raises(ValueError, match="control characters"):
        experiment_support.prepare_private_data_root(unsafe_root)

    assert not unsafe_root.exists()


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
    assert "start --gpu_mode=none 2>&1" in patched
    assert patched.count("--gpu_mode=none") == 2
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

    config_path = capture_record / "cuttlefish_config.json"
    captured_config = json.loads(config_path.read_text(encoding="utf-8"))
    captured_config["instances"]["1"]["gpu_mode"] = "guest_swiftshader"
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match="captured Cuttlefish configuration has unexpected gpu_mode: "
        r"'guest_swiftshader'",
    ):
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
    captured_config["instances"]["1"]["gpu_mode"] = "none"
    config_path.write_text(json.dumps(captured_config), encoding="utf-8")

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


def test_workspace_removal_is_limited_to_generated_diagnostic_work(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    experiment_support.prepare_private_data_root(data_root)
    ownership_token = "0123456789abcdef" * 4
    outside_workspace = tmp_path / "important-data"
    outside_workspace.mkdir()
    protected_file = outside_workspace / "keep.txt"
    protected_file.write_text("preserve", encoding="utf-8")

    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.discard_private_workspace(
            outside_workspace,
            data_root,
            ownership_token,
        )

    assert protected_file.read_text(encoding="utf-8") == "preserve"

    unmarked_workspace = data_root / "work/gpu-none.backup"
    unmarked_workspace.mkdir()
    os.chmod(unmarked_workspace, 0o700)
    (unmarked_workspace / ".apkrun-cuttlefish-workspace").write_text(
        "APKRun Cuttlefish boot diagnosis v1\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="ownership marker"):
        experiment_support.discard_private_workspace(
            unmarked_workspace,
            data_root,
            ownership_token,
        )

    assert unmarked_workspace.is_dir()


def test_log_tree_removal_is_limited_to_generated_diagnostic_work(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    experiment_support.prepare_private_data_root(data_root)
    outside_workspace = tmp_path / "important-data"
    capture_root = outside_workspace / "Images/reference/16373615/default"
    adb_log_root = outside_workspace / "adb-live"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir(parents=True)
    protected_capture = capture_root / "logcat.txt.gz"
    protected_live = adb_log_root / "logcat-001.txt"
    protected_capture.write_bytes(b"preserve guest log")
    protected_live.write_text("preserve live log\n", encoding="utf-8")

    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.scrub_raw_logcat(
            outside_workspace,
            adb_log_root,
            data_root,
            "0123456789abcdef" * 4,
        )
    with pytest.raises(ValueError, match="outside the generated"):
        experiment_support.discard_logcat_trees(
            outside_workspace,
            adb_log_root,
            data_root,
            "0123456789abcdef" * 4,
        )

    assert protected_capture.read_bytes() == b"preserve guest log"
    assert protected_live.read_text(encoding="utf-8") == "preserve live log\n"


@pytest.mark.skipif(sys.platform != "linux", reason="race fixture uses /proc/self/fd")
def test_logcat_scrub_does_not_follow_parent_swapped_after_stat(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.test123"
    capture_root = work_root / "Images/reference/16373615"
    capture_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    raw_log = capture_root / "logcat.txt.gz"
    raw_log.write_bytes(b"private guest log")
    external = tmp_path / "external-capture"
    external.mkdir()
    external_log = external / "logcat.txt.gz"
    external_log.write_bytes(b"external data")
    displaced_capture = work_root / "capture-original"
    real_stat = experiment_support._stat_entry_at
    swapped = False

    def swap_after_stat(parent_descriptor: int, name: str) -> os.stat_result:
        nonlocal swapped
        entry_stat = real_stat(parent_descriptor, name)
        if name == "logcat.txt.gz" and not swapped:
            opened_parent = Path(os.readlink(f"/proc/self/fd/{parent_descriptor}"))
            opened_parent.rename(displaced_capture)
            capture_root.symlink_to(external, target_is_directory=True)
            swapped = True
        return entry_stat

    monkeypatch.setattr(experiment_support, "_stat_entry_at", swap_after_stat)
    with pytest.raises(OSError):
        experiment_support.scrub_raw_logcat(
            work_root,
            work_root / "adb-live",
            data_root,
            ownership_token,
        )

    assert swapped
    assert capture_root.is_symlink()
    assert external_log.read_bytes() == b"external data"
    assert not (displaced_capture / "logcat.txt.gz").exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace race fixture is Linux-only"
)
def test_workspace_removal_refuses_replacement_after_marker_validation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    displaced_workspace = tmp_path / "displaced-workspace"
    real_verify = experiment_support._verify_workspace_marker
    verification_count = 0

    def verify_then_replace(
        work_descriptor: int,
        verified_root: Path,
        token: str,
    ) -> None:
        nonlocal verification_count
        real_verify(work_descriptor, verified_root, token)
        verification_count += 1
        if verification_count == 2:
            verified_root.rename(displaced_workspace)
            verified_root.mkdir()
            _mark_generated_workspace(verified_root, token)
            (verified_root / "keep.txt").write_text("preserve", encoding="utf-8")

    monkeypatch.setattr(
        experiment_support,
        "_verify_workspace_marker",
        verify_then_replace,
    )
    with pytest.raises(OSError, match="directory changed"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    assert (displaced_workspace / ".apkrun-cuttlefish-workspace").is_file()
    assert (work_root / "keep.txt").read_text(encoding="utf-8") == "preserve"
    assert (work_root / ".apkrun-cuttlefish-workspace").is_file()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace removal fixture is Linux-only"
)
def test_workspace_removal_keeps_marker_when_partial_cleanup_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    first_file = work_root / "01-delete.txt"
    failing_file = work_root / "02-fail.txt"
    first_file.write_text("delete", encoding="utf-8")
    failing_file.write_text("keep for retry", encoding="utf-8")
    real_unlink = experiment_support._unlink_entry_at

    def fail_after_first_file(
        parent_descriptor: int,
        name: str,
        expected_stat: os.stat_result,
    ) -> None:
        if name == failing_file.name:
            raise OSError(errno.EACCES, "injected cleanup failure", name)
        real_unlink(parent_descriptor, name, expected_stat)

    monkeypatch.setattr(
        experiment_support,
        "_unlink_entry_at",
        fail_after_first_file,
    )
    with pytest.raises(OSError, match="injected cleanup failure"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    marker = work_root / ".apkrun-cuttlefish-workspace"
    assert not first_file.exists()
    assert failing_file.read_text(encoding="utf-8") == "keep for retry"
    assert marker.is_file()

    monkeypatch.setattr(experiment_support, "_unlink_entry_at", real_unlink)
    experiment_support.discard_private_workspace(
        work_root,
        data_root,
        ownership_token,
    )
    assert not work_root.exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="workspace removal fixture is Linux-only"
)
def test_workspace_removal_restores_marker_when_final_rmdir_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    work_root = work_parent / "gpu-none.012345"
    work_root.mkdir(parents=True)
    (data_root / "results").mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    marker = work_root / ".apkrun-cuttlefish-workspace"
    expected_marker = marker.read_bytes()
    real_remove_directory_entry = experiment_support._remove_directory_entry_at

    def fail_final_rmdir(
        parent_descriptor: int,
        name: str,
        expected_stat: os.stat_result,
    ) -> None:
        raise OSError(errno.EBUSY, "injected final rmdir failure", name)

    monkeypatch.setattr(
        experiment_support,
        "_remove_directory_entry_at",
        fail_final_rmdir,
    )
    with pytest.raises(OSError, match="injected final rmdir failure"):
        experiment_support.discard_private_workspace(
            work_root,
            data_root,
            ownership_token,
        )

    assert marker.read_bytes() == expected_marker

    monkeypatch.setattr(
        experiment_support,
        "_remove_directory_entry_at",
        real_remove_directory_entry,
    )
    experiment_support.discard_private_workspace(
        work_root,
        data_root,
        ownership_token,
    )
    assert not work_root.exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="atomic quarantine rename is Linux-only"
)
@pytest.mark.parametrize("directory", [False, True])
def test_removal_refuses_replacement_at_quarantine_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    directory: bool,
) -> None:
    parent = tmp_path / "parent"
    parent.mkdir()
    target = parent / "target"
    displaced = tmp_path / "displaced"
    if directory:
        target.mkdir()
    else:
        target.write_text("original", encoding="utf-8")
    expected_stat = target.stat(follow_symlinks=False)
    parent_descriptor = experiment_support._open_directory_chain(parent)
    real_rename = experiment_support._renameat2_noreplace
    replaced = False

    def replace_at_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
    ) -> None:
        nonlocal replaced
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        if (
            not replaced
            and source_parent == parent
            and source_name == "target"
            and destination_name.startswith(".apkrun-quarantine-")
        ):
            target.rename(displaced)
            if directory:
                target.mkdir()
            else:
                target.write_text("replacement", encoding="utf-8")
            replaced = True
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
        )

    monkeypatch.setattr(
        experiment_support,
        "_renameat2_noreplace",
        replace_at_rename,
    )
    try:
        with pytest.raises(OSError, match="changed during safe removal"):
            if directory:
                experiment_support._remove_directory_entry_at(
                    parent_descriptor,
                    "target",
                    expected_stat,
                )
            else:
                experiment_support._unlink_entry_at(
                    parent_descriptor,
                    "target",
                    expected_stat,
                )
    finally:
        os.close(parent_descriptor)

    assert replaced
    assert displaced.exists()
    assert target.is_dir() if directory else target.read_text() == "replacement"


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_rejects_result_directory_without_nesting_capture(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    result_path = results_root / "gpu-none-20261001T000000Z-1234"
    result_path.mkdir()

    with pytest.raises(FileExistsError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not list(result_path.iterdir())


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_rejects_symlinked_results_parent(
    tmp_path: Path,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    external_results = tmp_path / "external-results"
    external_results.mkdir()
    results_root.rmdir()
    results_root.symlink_to(external_results, target_is_directory=True)
    result_path = results_root / "gpu-none-20261001T000000Z-1234"

    with pytest.raises(OSError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_dir()
    assert not list(external_results.iterdir())


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_rechecks_source_inode_before_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n',
        encoding="utf-8",
    )
    external_record = tmp_path / "external-record"
    external_record.mkdir()
    external_file = external_record / "host.json"
    external_file.write_text("preserve", encoding="utf-8")
    displaced_record = capture_record.parent / "displaced-record"
    result_path = results_root / "gpu-none-20261001T000000Z-1234"
    real_rename = experiment_support._rename_directory_no_replace

    def replace_source_then_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
        expected_source_stat: os.stat_result,
    ) -> None:
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        source_path = source_parent / source_name
        source_path.rename(displaced_record)
        source_path.symlink_to(external_record, target_is_directory=True)
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
            expected_source_stat,
        )

    monkeypatch.setattr(
        experiment_support,
        "_rename_directory_no_replace",
        replace_source_then_rename,
    )
    with pytest.raises(OSError):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert capture_record.is_symlink()
    assert (displaced_record / "host.json").is_file()
    assert external_file.read_text(encoding="utf-8") == "preserve"
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publication_refuses_source_replacement_at_quarantine_rename(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n',
        encoding="utf-8",
    )
    external_record = tmp_path / "external-record"
    external_record.mkdir()
    external_file = external_record / "host.json"
    external_file.write_text("preserve", encoding="utf-8")
    displaced_record = capture_record.parent / "displaced-record"
    result_path = results_root / "gpu-none-20261001T000000Z-1234"
    real_rename = experiment_support._renameat2_noreplace
    replaced = False

    def replace_at_rename(
        source_parent_descriptor: int,
        source_name: str,
        destination_parent_descriptor: int,
        destination_name: str,
    ) -> None:
        nonlocal replaced
        source_parent = Path(os.readlink(f"/proc/self/fd/{source_parent_descriptor}"))
        if (
            not replaced
            and source_parent == capture_record.parent
            and source_name == capture_record.name
            and destination_name.startswith(".apkrun-quarantine-")
        ):
            capture_record.rename(displaced_record)
            capture_record.symlink_to(external_record, target_is_directory=True)
            replaced = True
        real_rename(
            source_parent_descriptor,
            source_name,
            destination_parent_descriptor,
            destination_name,
        )

    monkeypatch.setattr(
        experiment_support,
        "_renameat2_noreplace",
        replace_at_rename,
    )
    with pytest.raises(OSError, match="changed during safe removal"):
        experiment_support.publish_normalized_record(
            capture_record,
            work_root,
            data_root,
            result_path,
            ownership_token,
        )

    assert replaced
    assert capture_record.is_symlink()
    assert (displaced_record / "host.json").is_file()
    assert external_file.read_text(encoding="utf-8") == "preserve"
    assert not result_path.exists()


@pytest.mark.skipif(sys.platform != "linux", reason="descriptor counts use /proc")
def test_publication_closes_descriptors_when_results_open_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    data_root = tmp_path / "diagnostics"
    work_root = data_root / "work/gpu-none.012345"
    results_root = data_root / "results"
    capture_record = work_root / "Images/reference/16373615/default"
    capture_record.mkdir(parents=True)
    results_root.mkdir(parents=True)
    ownership_token = "0123456789abcdef" * 4
    _mark_generated_workspace(work_root, ownership_token)
    result_path = results_root / "gpu-none-20261001T000000Z-1234"
    real_open = experiment_support._open_child_directory
    results_open_count = 0

    def fail_second_results_open(parent_descriptor: int, name: str) -> int:
        nonlocal results_open_count
        if name == "results":
            results_open_count += 1
            if results_open_count % 2 == 0:
                raise OSError(errno.ELOOP, "injected results open failure")
        return real_open(parent_descriptor, name)

    monkeypatch.setattr(
        experiment_support,
        "_open_child_directory",
        fail_second_results_open,
    )
    descriptors_before = len(os.listdir("/proc/self/fd"))
    for _ in range(20):
        with pytest.raises(OSError, match="injected results open failure"):
            experiment_support.publish_normalized_record(
                capture_record,
                work_root,
                data_root,
                result_path,
                ownership_token,
            )
    descriptors_after = len(os.listdir("/proc/self/fd"))

    assert descriptors_after <= descriptors_before + 1
