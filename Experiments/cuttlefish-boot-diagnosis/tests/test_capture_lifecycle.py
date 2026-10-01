from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest


def _create_generated_workspace(
    tmp_path: Path,
    name: str = "gpu-none.test123",
) -> tuple[Path, Path, str]:
    data_root = tmp_path / "diagnostics"
    work_parent = data_root / "work"
    results_root = data_root / "results"
    data_root.mkdir(mode=0o700)
    work_parent.mkdir(mode=0o700)
    results_root.mkdir(mode=0o700)
    work_root = work_parent / name
    work_root.mkdir(mode=0o700)
    ownership_token = "0123456789abcdef" * 4
    marker = f"APKRun Cuttlefish boot diagnosis v1\n{ownership_token}\n{work_root}\n"
    (work_root / ".apkrun-cuttlefish-workspace").write_text(
        marker,
        encoding="utf-8",
    )
    return data_root, work_root, ownership_token


def test_failed_record_scrubs_raw_logcat_and_retains_diagnostic_metadata(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    (capture_root / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    (capture_root / "cuttlefish_config.json").write_text(
        '{"instances":{"1":{"gpu_mode":"guest_swiftshader"}}}\n',
        encoding="utf-8",
    )
    (capture_root / "logcat.txt.gz").write_bytes(b"private guest log")
    (capture_root / ".logcat.raw").write_bytes(b"partial guest log")
    (adb_log_root / "logcat-001.txt").write_text("private live log\n", encoding="utf-8")
    (adb_log_root / ".logcat-002.txt").write_text(
        "partial live log\n", encoding="utf-8"
    )
    (adb_log_root / "adb-state.txt").write_text(
        "2026-10-01T00:00:00Z\tadb=offline\n",
        encoding="utf-8",
    )
    (work_root / "host-identity.json").write_text(
        '{"schemaVersion":1}\n', encoding="utf-8"
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root="$work_root/tmp"
adb_log_root={str(adb_log_root)!r}
keep_work=0
mkdir -p "$tmp_root"
source "$script_dir/capture-lifecycle.sh"
if record_or_preserve bash -c 'exit 19'; then
  exit 23
fi
test "$keep_work" -eq 1
test -f "$work_root/Images/reference/16373615/default/host.json"
test -f "$work_root/Images/reference/16373615/default/cuttlefish_config.json"
test -f "$work_root/host-identity.json"
test -f "$adb_log_root/adb-state.txt"
test ! -e "$work_root/Images/reference/16373615/default/logcat.txt.gz"
test ! -e "$work_root/Images/reference/16373615/default/.logcat.raw"
test ! -e "$adb_log_root/logcat-001.txt"
test ! -e "$adb_log_root/.logcat-002.txt"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "failed experiment validation" in result.stderr
    assert "Private diagnostic workspace retained" in result.stderr


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_final_publication_gate_scrubs_logs_created_during_normalization(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_record = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    result_path = data_root / "results/gpu-none-20261001T000000Z-1234"
    capture_record.mkdir(parents=True)
    adb_log_root.mkdir()
    tmp_root.mkdir()
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    normalize_tool = tmp_path / "normalize.py"
    normalize_tool.write_text(
        """from pathlib import Path
import sys

record = Path(sys.argv[-1])
work_root = record.parents[3]
(record / "logcat.txt.gz").write_bytes(b"private guest log")
(record / ".logcat.raw").write_bytes(b"partial guest log")
(work_root / "adb-live" / "logcat-001.txt").write_text("private live log\\n")
(work_root / "adb-live" / ".logcat-002.txt").write_text("partial live log\\n")
""",
        encoding="utf-8",
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ("find", "ps"):
        fake_tool = fake_bin / name
        fake_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_tool.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root="$work_root/tmp"
adb_log_root={str(adb_log_root)!r}
adb_server_started=0
keep_work=0
source "$script_dir/capture-lifecycle.sh"
publish_capture_record {str(capture_record)!r} {str(normalize_tool)!r} {str(result_path)!r}
test -f {str(result_path / "host.json")!r}
test ! -e {str(result_path / "logcat.txt.gz")!r}
test ! -e {str(result_path / ".logcat.raw")!r}
test ! -e {str(adb_log_root / "logcat-001.txt")!r}
test ! -e {str(adb_log_root / ".logcat-002.txt")!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert result_path.is_dir()


def test_final_publication_gate_rejects_symlinked_adb_output(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_record = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    capture_record.mkdir(parents=True)
    adb_log_root.mkdir()
    tmp_root.mkdir()
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    normalize_tool = tmp_path / "normalize.py"
    normalize_tool.write_text(
        """from pathlib import Path
import sys

record = Path(sys.argv[-1])
work_root = record.parents[3]
external = work_root / "external"
external.mkdir()
(external / "logcat-001.txt").write_text("private live log\\n")
(work_root / "adb-live" / "nested-output").symlink_to(external, target_is_directory=True)
""",
        encoding="utf-8",
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ("find", "ps"):
        fake_tool = fake_bin / name
        fake_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_tool.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root={str(tmp_root)!r}
adb_log_root={str(adb_log_root)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if normalize_and_scrub_for_publication {str(capture_record)!r} {str(normalize_tool)!r}; then
  exit 23
fi
preserve_work
test "$keep_work" -eq 0
test ! -e "$work_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "nested or symlink entry" in result.stderr


@pytest.mark.skipif(sys.platform != "linux", reason="publication uses Linux renameat2")
def test_publish_capture_record_keeps_result_private_when_scrub_fails(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_record = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    result_path = data_root / "results/gpu-none-20261001T000001Z-1235"
    capture_record.mkdir(parents=True)
    adb_log_root.mkdir()
    tmp_root.mkdir()
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    external_log_dir = tmp_path / "external-live"
    external_log_dir.mkdir()
    external_log = external_log_dir / "logcat-001.txt"
    external_log.write_text("private live log\n", encoding="utf-8")
    normalize_tool = tmp_path / "normalize.py"
    normalize_tool.write_text(
        f"""from pathlib import Path
import sys

record = Path(sys.argv[-1])
work_root = record.parents[3]
(work_root / "adb-live" / "nested-output").symlink_to(
    {str(external_log_dir)!r}, target_is_directory=True
)
""",
        encoding="utf-8",
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ("find", "ps"):
        fake_tool = fake_bin / name
        fake_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_tool.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root={str(tmp_root)!r}
adb_log_root={str(adb_log_root)!r}
adb_server_started=0
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if publish_capture_record {str(capture_record)!r} {str(normalize_tool)!r} {str(result_path)!r}; then
  exit 23
fi
test ! -e {str(result_path)!r}
preserve_work
test "$keep_work" -eq 0
test ! -e "$work_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "refusing publication" in result.stderr
    assert external_log.read_text(encoding="utf-8") == "private live log\n"


def test_require_no_crosvm_fails_closed_and_rejects_existing_process(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text(
        """#!/bin/sh
case "$APKRUN_TEST_PS_MODE" in
  failure) exit 2 ;;
  running) printf ' 4242\\n' ;;
  empty)
    if [ "$2" = "-C" ]; then
      exit 1
    fi
    printf ' 123\\n'
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_ps.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
source "$script_dir/capture-lifecycle.sh"
case "$APKRUN_TEST_PS_MODE" in
  failure|running)
    if require_no_crosvm; then
      exit 23
    fi
    ;;
  empty)
    require_no_crosvm
    tmp_root=$(mktemp -d)
    cvd_is_clean
    rmdir "$tmp_root"
    ;;
esac
"""

    for mode in ("failure", "running", "empty"):
        environment["APKRUN_TEST_PS_MODE"] = mode
        result = subprocess.run(
            ["bash", "-c", script],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        assert result.returncode == 0, f"{mode}: {result.stderr}"
        if mode == "failure":
            assert "Could not verify" in result.stderr
        if mode == "running":
            assert "already running" in result.stderr


def test_clean_host_uses_python_workspace_removal_after_scrub_failure(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    (work_root / "tmp").mkdir()
    (capture_root / "logcat.txt.gz").write_bytes(b"private guest log")
    external_log_dir = tmp_path / "external-log"
    external_log_dir.mkdir()
    (capture_root / "linked-output").symlink_to(
        external_log_dir,
        target_is_directory=True,
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_ps.chmod(0o755)
    fake_find = fake_bin / "find"
    fake_find.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_find.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root="$work_root/tmp"
adb_log_root={str(adb_log_root)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if record_or_preserve bash -c 'exit 19'; then
  exit 23
fi
test "$keep_work" -eq 0
test ! -e "$work_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "failed experiment validation" in result.stderr
    assert "manual cleanup is required" not in result.stderr


def test_exit_cleanup_retains_workspace_after_both_safe_deletion_attempts_fail(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    calls_path = tmp_path / "discard-attempts.txt"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_python = fake_bin / "python3"
    fake_python.write_text(
        """#!/bin/sh
case " $* " in
  *" discard-workspace "*)
    printf 'attempt\\n' >> "$APKRUN_TEST_DISCARD_CALLS"
    exit 1
    ;;
esac
exec "$APKRUN_TEST_REAL_PYTHON" "$@"
""",
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_DISCARD_CALLS"] = str(calls_path)
    environment["APKRUN_TEST_REAL_PYTHON"] = sys.executable
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
cleanup_generated_workspace
test "$keep_work" -eq 1
test -f "$work_root/.apkrun-cuttlefish-workspace"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert calls_path.read_text(encoding="utf-8").splitlines() == [
        "attempt",
        "attempt",
    ]
    assert "retained for manual cleanup" in result.stderr


def test_cuttlefish_cleanup_check_fails_closed_on_inspection_errors(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    tmp_root = tmp_path / "private-work/tmp"
    tmp_root.mkdir(parents=True)

    for failing_tool in ("find", "ps"):
        fake_bin = tmp_path / f"bin-{failing_tool}"
        fake_bin.mkdir()
        fake_find = fake_bin / "find"
        fake_find.write_text(
            "#!/bin/sh\n" + ("exit 1\n" if failing_tool == "find" else "exit 0\n"),
            encoding="utf-8",
        )
        fake_find.chmod(0o755)
        fake_ps = fake_bin / "ps"
        fake_ps.write_text(
            "#!/bin/sh\n" + ("exit 1\n" if failing_tool == "ps" else "exit 0\n"),
            encoding="utf-8",
        )
        fake_ps.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
        script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
tmp_root={str(tmp_root)!r}
work_root={str(tmp_path / "private-work")!r}
adb_log_root="$work_root/adb-live"
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if cvd_is_clean; then
  exit 23
fi
"""

        result = subprocess.run(
            ["bash", "-c", script],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        assert result.returncode == 0, f"{failing_tool}: {result.stderr}"


def test_scrub_failure_removes_capture_outputs_but_keeps_live_cvd_state(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    runtime_home = tmp_root / "apkrun-cvd-home.default.test"
    runtime_home.mkdir(parents=True)
    (capture_root / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    (adb_log_root / "logcat-001.txt").write_text("private live log\n", encoding="utf-8")
    (work_root / "host-identity.json").write_text(
        '{"schemaVersion":1}\n', encoding="utf-8"
    )
    external_log_dir = tmp_path / "external-log"
    external_log_dir.mkdir()
    external_log = external_log_dir / "logcat.txt.gz"
    external_log.write_bytes(b"external raw log")
    (capture_root / "linked-output").symlink_to(
        external_log_dir, target_is_directory=True
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\nprintf '4242\\n'\n", encoding="utf-8")
    fake_ps.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root={str(tmp_root)!r}
adb_log_root={str(adb_log_root)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if record_or_preserve bash -c 'exit 19'; then
  exit 23
fi
test "$keep_work" -eq 1
test -d "$tmp_root/apkrun-cvd-home.default.test"
test -f "$work_root/host-identity.json"
test ! -e "$work_root/Images/reference/16373615"
test ! -e "$adb_log_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "symlink directory" in result.stderr
    assert "retaining its runtime state" in result.stderr
    assert external_log.read_bytes() == b"external raw log"


def test_active_cvd_cleanup_uses_symlink_safe_python_tree_removal(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(
        tmp_path,
        "gpu-none.test456",
    )
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    (tmp_root / "apkrun-cvd-home.default.test").mkdir(parents=True)
    (capture_root / "logcat.txt.gz").write_bytes(b"private guest log")
    (adb_log_root / "logcat-001.txt").write_text("private live log\n", encoding="utf-8")
    external_log_dir = tmp_path / "external-log"
    external_log_dir.mkdir()
    (external_log_dir / "logcat.txt.gz").write_bytes(b"external raw log")
    (capture_root / "linked-output").symlink_to(
        external_log_dir,
        target_is_directory=True,
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\nprintf '4242\\n'\n", encoding="utf-8")
    fake_ps.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root={str(tmp_root)!r}
adb_log_root={str(adb_log_root)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if record_or_preserve bash -c 'exit 19'; then
  exit 23
fi
test "$keep_work" -eq 1
test -d "$tmp_root/apkrun-cvd-home.default.test"
test -e "$work_root"
test ! -e "$work_root/Images/reference/16373615"
test ! -e "$adb_log_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "retaining its runtime state" in result.stderr


def test_scrubber_rejects_symlinked_live_adb_directory(tmp_path: Path) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    external_log_dir = tmp_path / "external-live"
    external_log_dir.mkdir()
    external_log = external_log_dir / "logcat-001.txt"
    external_log.write_text("private external live log\n", encoding="utf-8")
    (adb_log_root / "nested-output").symlink_to(
        external_log_dir, target_is_directory=True
    )

    result = subprocess.run(
        [
            sys.executable,
            str(experiment_root / "experiment_support.py"),
            "scrub-logcat",
            "--work-root",
            str(work_root),
            "--adb-log-root",
            str(adb_log_root),
            "--data-root",
            str(data_root),
            "--ownership-token",
            ownership_token,
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "nested or symlink entry" in result.stderr
    assert external_log.read_text(encoding="utf-8") == "private external live log\n"


def test_active_cvd_runtime_is_kept_when_all_log_removal_paths_fail(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    tmp_root = work_root / "tmp"
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    (tmp_root / "apkrun-cvd-home.default.test").mkdir(parents=True)
    (capture_root / "logcat.txt.gz").write_bytes(b"private guest log")
    (adb_log_root / "logcat-001.txt").write_text("private live log\n", encoding="utf-8")
    external_log_dir = tmp_path / "external-log"
    external_log_dir.mkdir()
    (capture_root / "linked-output").symlink_to(
        external_log_dir,
        target_is_directory=True,
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\nprintf '4242\\n'\n", encoding="utf-8")
    fake_ps.chmod(0o755)
    fake_rm = fake_bin / "rm"
    fake_rm.write_text(
        """#!/bin/sh
case " $* " in
  *"$APKRUN_TEST_WORK_ROOT/Images/reference/16373615"*)
    exit 1
    ;;
  *"$APKRUN_TEST_WORK_ROOT/adb-live"*)
    exit 1
    ;;
esac
exec /bin/rm "$@"
""",
        encoding="utf-8",
    )
    fake_rm.chmod(0o755)
    fake_python = fake_bin / "python3"
    fake_python.write_text(
        """#!/bin/sh
case " $* " in
  *" discard-logcat-trees "*)
    exit 1
    ;;
esac
exec "$APKRUN_TEST_REAL_PYTHON" "$@"
""",
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_WORK_ROOT"] = str(work_root)
    environment["APKRUN_TEST_REAL_PYTHON"] = sys.executable
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root={str(tmp_root)!r}
adb_log_root={str(adb_log_root)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
if record_or_preserve bash -c 'exit 19'; then
  exit 23
fi
test "$keep_work" -eq 1
test -d "$tmp_root/apkrun-cvd-home.default.test"
test -e "$work_root"
test -e "$work_root/Images/reference/16373615/default/logcat.txt.gz"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.returncode == 0, result.stderr
    assert "preserving its runtime" in result.stderr
    assert "manual cleanup" in result.stderr
