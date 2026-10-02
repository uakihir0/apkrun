from __future__ import annotations

import hashlib
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

requires_linux_renameat2 = pytest.mark.skipif(
    sys.platform != "linux",
    reason="workspace cleanup uses Linux renameat2",
)


def _create_generated_workspace(
    tmp_path: Path,
    name: str = "gpu-none-console-on.test123",
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


def _git_blob_id(contents: bytes) -> str:
    return hashlib.sha1(
        f"blob {len(contents)}\0".encode("ascii") + contents
    ).hexdigest()


def test_verified_experiment_support_executes_the_hashed_snapshot(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    experiment_tools = tmp_path / "experiment-tools"
    experiment_tools.mkdir()
    support_script = experiment_tools / "experiment_support.py"
    source = (
        "from pathlib import Path\n"
        "import sys\n"
        "Path(__file__).write_text('raise SystemExit(99)\\n', encoding='utf-8')\n"
        "Path(sys.argv[1]).write_text('snapshot executed\\n', encoding='utf-8')\n"
    )
    support_script.write_text(source, encoding="utf-8")
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "experimentSources": {
                    "experiment_support.py": hashlib.sha256(
                        source.encode("utf-8")
                    ).hexdigest()
                }
            }
        ),
        encoding="utf-8",
    )
    marker = tmp_path / "executed.txt"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_tools)!r}
host_identity={str(host_identity)!r}
source "$script_dir/capture-lifecycle.sh"
run_verified_experiment_support {str(marker)!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert marker.read_text(encoding="utf-8") == "snapshot executed\n"
    assert "raise SystemExit(99)" in support_script.read_text(encoding="utf-8")


def test_committed_experiment_support_rejects_copy_then_restore_race(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    repo_root = tmp_path / "repository"
    support_relative = Path(
        "Experiments/cuttlefish-boot-diagnosis/experiment_support.py"
    )
    support_path = repo_root / support_relative
    support_path.parent.mkdir(parents=True)
    trusted_source = (
        "from pathlib import Path\n"
        "import sys\n"
        "Path(sys.argv[1]).write_text('trusted source ran\\n', encoding='utf-8')\n"
    )
    transient_source = (
        "from pathlib import Path\n"
        "import sys\n"
        "Path(sys.argv[1]).write_text('transient source ran\\n', encoding='utf-8')\n"
    )
    support_path.write_text(trusted_source, encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
    subprocess.run(["git", "add", "."], cwd=repo_root, check=True)
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
            "pin experiment support",
        ],
        cwd=repo_root,
        check=True,
    )
    experiment_tools = tmp_path / "experiment-tools"
    experiment_tools.mkdir()
    private_copy = experiment_tools / "experiment_support.py"
    support_path.write_text(transient_source, encoding="utf-8")
    private_copy.write_bytes(support_path.read_bytes())
    support_path.write_text(trusted_source, encoding="utf-8")
    marker = tmp_path / "source-ran.txt"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
repo_root={str(repo_root)!r}
experiment_tools={str(experiment_tools)!r}
source "$script_dir/capture-lifecycle.sh"
if run_committed_experiment_support {str(marker)!r}; then
  exit 29
fi
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert (
        "private experiment-support copy differs from committed HEAD" in result.stderr
    )
    assert not marker.exists()


def test_committed_capture_bounded_executes_only_committed_helper_copies(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    repo_root = tmp_path / "repository"
    tool_relative_root = Path("Experiments/cuttlefish-boot-diagnosis")
    source_root = repo_root / tool_relative_root
    source_root.mkdir(parents=True)
    (source_root / "capture_processes.py").write_text(
        "VALUE = 'committed dependency'\n",
        encoding="utf-8",
    )
    (source_root / "capture_bounded.py").write_text(
        "from pathlib import Path\n"
        "import sys\n"
        "import capture_processes\n"
        "Path(sys.argv[1]).write_text(capture_processes.VALUE, encoding='utf-8')\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
    subprocess.run(["git", "add", "."], cwd=repo_root, check=True)
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
            "pin bounded capture helpers",
        ],
        cwd=repo_root,
        check=True,
    )
    tool_root = tmp_path / "private-tools"
    tool_root.mkdir()
    shutil.copyfile(
        source_root / "capture_bounded.py", tool_root / "capture_bounded.py"
    )
    shutil.copyfile(
        source_root / "capture_processes.py",
        tool_root / "capture_processes.py",
    )
    marker = tmp_path / "bounded-ran.txt"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
repo_root={str(repo_root)!r}
experiment_tools={str(tool_root)!r}
source "$script_dir/capture-lifecycle.sh"
run_committed_capture_bounded {str(marker)!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert marker.read_text(encoding="utf-8") == "committed dependency"

    (tool_root / "capture_bounded.py").write_text(
        "raise SystemExit('transient replacement ran')\n",
        encoding="utf-8",
    )
    rejected_marker = tmp_path / "replacement-ran.txt"
    rejected_script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
repo_root={str(repo_root)!r}
experiment_tools={str(tool_root)!r}
source "$script_dir/capture-lifecycle.sh"
if run_committed_capture_bounded {str(rejected_marker)!r}; then
  exit 29
fi
"""
    rejected = subprocess.run(
        ["bash", "-c", rejected_script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert rejected.returncode == 0, rejected.stderr
    assert "private capture_bounded.py copy differs from committed HEAD" in (
        rejected.stderr
    )
    assert not rejected_marker.exists()


@pytest.mark.skipif(
    sys.platform != "linux", reason="normalization rules use sealed memfd"
)
def test_verified_compare_boot_executes_hashed_code_with_sealed_rules(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    tool_destination = tmp_path / "reference-tools"
    tool_destination.mkdir()
    compare_path = tool_destination / "compare_boot.py"
    compare_source = (
        "from pathlib import Path\n"
        "import sys\n"
        "record = Path(sys.argv[2])\n"
        "rules = Path(sys.argv[sys.argv.index('--rules') + 1])\n"
        "contents = rules.read_text(encoding='utf-8')\n"
        "try:\n"
        "    rules.write_text('changed rules', encoding='utf-8')\n"
        "except OSError:\n"
        "    pass\n"
        "else:\n"
        "    raise SystemExit(29)\n"
        "Path(__file__).write_text('raise SystemExit(99)\\n', encoding='utf-8')\n"
        "(record / 'rules.snapshot').write_text(contents, encoding='utf-8')\n"
    )
    compare_path.write_text(compare_source, encoding="utf-8")
    rules_path = tool_destination / "normalize.yaml"
    rules_path.write_text("verified normalization rules\n", encoding="utf-8")
    capture_record = tmp_path / "capture"
    capture_record.mkdir()
    host_identity = tmp_path / "host-identity.json"
    host_identity.write_text(
        json.dumps(
            {
                "observedToolBlobs": {
                    "Images/tools/reference/compare_boot.py": _git_blob_id(
                        compare_source.encode("utf-8")
                    ),
                    "Images/tools/reference/normalize.yaml": _git_blob_id(
                        rules_path.read_bytes()
                    ),
                }
            }
        ),
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
tool_destination={str(tool_destination)!r}
host_identity={str(host_identity)!r}
source "$script_dir/capture-lifecycle.sh"
run_verified_compare_boot {str(compare_path)!r} {str(capture_record)!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert (capture_record / "rules.snapshot").read_text(encoding="utf-8") == (
        "verified normalization rules\n"
    )
    assert rules_path.read_text(encoding="utf-8") == "verified normalization rules\n"


@requires_linux_renameat2
def test_failed_record_scrubs_raw_logcat_and_retains_diagnostic_metadata(
    tmp_path: Path,
    request: pytest.FixtureRequest,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    capture_root = work_root / "Images/reference/16373615/default"
    adb_log_root = work_root / "adb-live"
    physical_tmp = Path(os.path.realpath("/tmp"))
    for _ in range(10):
        candidate_root = physical_tmp / f"x.{secrets.token_hex(3)}"
        try:
            candidate_root.mkdir(mode=0o700)
        except FileExistsError:
            continue
        short_cvd_root = candidate_root
        break
    else:
        raise RuntimeError("could not create a short temporary HOME fixture")
    request.addfinalizer(lambda: shutil.rmtree(short_cvd_root, ignore_errors=True))
    capture_root.mkdir(parents=True)
    adb_log_root.mkdir()
    short_cvd_root.chmod(0o700)
    short_cvd_home_tmpdir = short_cvd_root / "t"
    short_cvd_home_tmpdir.mkdir(mode=0o700)
    (short_cvd_root / ".apkrun-cvd-short-home").write_text(
        f"APKRun Cuttlefish short HOME v1\n{ownership_token}\n{work_root}\n"
        f"{short_cvd_root}\n",
        encoding="utf-8",
    )
    (short_cvd_root / ".apkrun-cvd-short-home").chmod(0o600)
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
    host_dir = tmp_path / "cuttlefish"
    (host_dir / "bin").mkdir(parents=True)
    (host_dir / "bin/cvd").write_text("Cuttlefish executable fixture\n")
    state_root = tmp_path / "cvd-state"
    state_root.mkdir()
    socket_metrics = work_root / "capture-socket-paths.json"
    socket_metrics.write_text(
        '{"capacityBytes":108,"terminatingNulBytes":1,"socketCount":0,'
        '"maxEncodedPathBytes":0,"maxSunPathBytesIncludingNul":0}\n',
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
tmp_root="$work_root/tmp"
adb_log_root={str(adb_log_root)!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
CVD_HOST_DIR={str(host_dir)!r}
cvd_state_dir={str(state_root)!r}
capture_socket_metrics={str(socket_metrics)!r}
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
test ! -e "$short_cvd_root"
test -d "$tmp_root"
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
    result_path = data_root / ("results/gpu-none-console-on-20261001T000000Z-1234")
    capture_record.mkdir(parents=True)
    adb_log_root.mkdir()
    tmp_root.mkdir()
    (capture_record / "host.json").write_text(
        '{"buildId":"16373615"}\n', encoding="utf-8"
    )
    (capture_record / "cuttlefish_config.json").write_text(
        (
                '{"instances":{"1":{"gpu_mode":"none",'
                '"enable_gpu_vhost_user":false,"cpus":4,"memory_mb":4096,'
                '"console":true,"pause_in_bootloader":false}}}\n'
        ),
        encoding="utf-8",
    )
    (capture_record / "experiment.json").write_text(
        (
            '{"experiment":"cuttlefish-gpu-none-console-on-boot-diagnosis",'
            '"gpuMode":"none","gpuModeSlug":"none",'
            '"consoleEnabled":true,"consoleModeSlug":"on",'
            '"pauseInBootloader":false}\n'
        ),
        encoding="utf-8",
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
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
baseline_record="$repo_root/Images/reference/16373615/incomplete/default-20261001T120904-49816"
host_identity="$work_root/host-identity.json"
tool_destination="$work_root/Images/tools/reference"
canonical_capture_copy="$work_root/capture.sh.unpatched"
manifest_destination="$work_root/Images/manifests/16373615"
experiment_tools="$work_root/experiment-tools"
capture_script="$tool_destination/capture.sh"
source "$script_dir/capture-lifecycle.sh"
run_verified_experiment_support() {{
  if [ "$1" = verify-tool-copy ]; then
    return 0
  fi
  python3 "$script_dir/experiment_support.py" "$@"
}}
run_verified_compare_boot() {{ python3 "$1" normalize "$2"; }}
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


@requires_linux_renameat2
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
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
baseline_record="$repo_root/Images/reference/16373615/incomplete/default-20261001T120904-49816"
host_identity="$work_root/host-identity.json"
tool_destination="$work_root/Images/tools/reference"
canonical_capture_copy="$work_root/capture.sh.unpatched"
manifest_destination="$work_root/Images/manifests/16373615"
experiment_tools="$work_root/experiment-tools"
capture_script="$tool_destination/capture.sh"
source "$script_dir/capture-lifecycle.sh"
run_verified_experiment_support() {{ return 0; }}
run_verified_compare_boot() {{ python3 "$1" normalize "$2"; }}
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
    result_path = data_root / ("results/gpu-none-console-on-20261001T000001Z-1235")
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
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
baseline_record="$repo_root/Images/reference/16373615/incomplete/default-20261001T120904-49816"
host_identity="$work_root/host-identity.json"
tool_destination="$work_root/Images/tools/reference"
canonical_capture_copy="$work_root/capture.sh.unpatched"
manifest_destination="$work_root/Images/manifests/16373615"
experiment_tools="$work_root/experiment-tools"
capture_script="$tool_destination/capture.sh"
source "$script_dir/capture-lifecycle.sh"
run_verified_experiment_support() {{
  if [ "$1" = verify-tool-copy ]; then
    return 0
  fi
  python3 "$script_dir/experiment_support.py" "$@"
}}
run_verified_compare_boot() {{ python3 "$1" normalize "$2"; }}
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


@requires_linux_renameat2
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
tmp_root="$work_root/tmp"
mkdir -p "$tmp_root"
short_cvd_root=
short_cvd_home_tmpdir=
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


@requires_linux_renameat2
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


@requires_linux_renameat2
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


def _create_short_cvd_root(
    root: Path, work_root: Path, ownership_token: str = "a" * 64
) -> Path:
    root.mkdir(mode=0o700)
    root.chmod(0o700)
    short_cvd_home_tmpdir = root / "t"
    short_cvd_home_tmpdir.mkdir(mode=0o700)
    short_cvd_home_tmpdir.chmod(0o700)
    marker = root / ".apkrun-cvd-short-home"
    marker.write_text(
        f"APKRun Cuttlefish short HOME v1\n{ownership_token}\n{work_root}\n{root}\n",
        encoding="utf-8",
    )
    marker.chmod(0o600)
    return short_cvd_home_tmpdir


@pytest.mark.skipif(
    sys.platform != "linux", reason="process audit requires Linux /proc"
)
def test_short_cvd_home_root_uses_a_physical_path_under_tmp(tmp_path: Path) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root = tmp_path / "diagnostics"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
workspace_token={"b" * 64!r}
python3 "$script_dir/experiment_support.py" prepare-data-root --data-root "$data_root"
work_root="$data_root/work/gpu-none.test123"
mkdir -m 700 "$work_root"
printf 'APKRun Cuttlefish boot diagnosis v1\\n%s\\n%s\\n' \\
  "$workspace_token" "$work_root" > "$work_root/.apkrun-cuttlefish-workspace"
chmod 600 "$work_root/.apkrun-cuttlefish-workspace"
cvd_state_dir="$data_root/cvd-state"
mkdir -m 700 "$cvd_state_dir"
CVD_HOST_DIR="$data_root/cuttlefish"
mkdir -p "$CVD_HOST_DIR/bin"
: > "$CVD_HOST_DIR/bin/cvd"
capture_socket_metrics="$work_root/capture-socket-paths.json"
printf '{{"capacityBytes":108,"terminatingNulBytes":1,"socketCount":0,"maxEncodedPathBytes":0,"maxSunPathBytesIncludingNul":0}}\\n' \\
  > "$capture_socket_metrics"
short_cvd_root=
short_cvd_home_tmpdir=
source "$script_dir/capture-lifecycle.sh"
create_short_cvd_home_root
test -d "$short_cvd_root"
test ! -L "$short_cvd_root"
test "$short_cvd_home_tmpdir" = "$short_cvd_root/t"
test -d "$short_cvd_home_tmpdir"
test ! -L "$short_cvd_home_tmpdir"
physical_short_root=$(python3 - "$short_cvd_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)
test "$physical_short_root" = "$short_cvd_root"
remove_short_cvd_root
test ! -e "$short_cvd_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr


@requires_linux_renameat2
def test_short_cvd_root_removes_only_marked_stopped_runtime(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root = tmp_path / "diagnostics"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
workspace_token={"e" * 64!r}
python3 "$script_dir/experiment_support.py" prepare-data-root --data-root "$data_root"
work_root="$data_root/work/gpu-none.test123"
mkdir -m 700 "$work_root"
printf 'APKRun Cuttlefish boot diagnosis v1\\n%s\\n%s\\n' \\
  "$workspace_token" "$work_root" > "$work_root/.apkrun-cuttlefish-workspace"
chmod 600 "$work_root/.apkrun-cuttlefish-workspace"
cvd_state_dir="$data_root/cvd-state"
mkdir -m 700 "$cvd_state_dir"
CVD_HOST_DIR="$data_root/cuttlefish"
mkdir -p "$CVD_HOST_DIR/bin"
: > "$CVD_HOST_DIR/bin/cvd"
export CVD_HOST_DIR
capture_socket_metrics="$work_root/capture-socket-paths.json"
cat > "$capture_socket_metrics" <<'JSON'
{{"capacityBytes":108,"terminatingNulBytes":1,"socketCount":0,"maxEncodedPathBytes":0,"maxSunPathBytesIncludingNul":0}}
JSON
outside_file="$data_root/outside.txt"
printf 'preserve\\n' > "$outside_file"
short_cvd_root=$(mktemp -d /tmp/x.XXXXXX)
chmod 700 "$short_cvd_root"
short_cvd_home_tmpdir="$short_cvd_root/t"
mkdir -m 700 "$short_cvd_home_tmpdir"
mkdir -p "$short_cvd_home_tmpdir/cf_avd_501/cvd-1"
printf 'generated runtime\\n' > "$short_cvd_home_tmpdir/cf_avd_501/cvd-1/runtime"
ln -s "$outside_file" "$short_cvd_home_tmpdir/outside-link"
printf 'APKRun Cuttlefish short HOME v1\\n%s\\n%s\\n%s\\n' \\
  "$workspace_token" "$work_root" "$short_cvd_root" \\
  > "$short_cvd_root/.apkrun-cvd-short-home"
chmod 600 "$short_cvd_root/.apkrun-cvd-short-home"
short_cvd_fleet_home=
source "$script_dir/capture-lifecycle.sh"
require_no_crosvm() {{ return 0; }}
private_cvd_processes_are_clean() {{ return 0; }}
remove_short_cvd_root
test -z "$short_cvd_root"
test ! -e "$short_cvd_root"
test "$(cat "$outside_file")" = preserve
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr


@requires_linux_renameat2
def test_process_group_signal_during_short_root_quarantine_finishes_removal(
    tmp_path: Path,
    request: pytest.FixtureRequest,
) -> None:
    experiment_root = Path(__file__).parents[1]
    data_root, work_root, ownership_token = _create_generated_workspace(tmp_path)
    physical_tmp = Path(os.path.realpath("/tmp"))
    for _ in range(10):
        candidate_root = physical_tmp / f"x.{secrets.token_hex(3)}"
        if candidate_root.exists():
            continue
        short_cvd_root = candidate_root
        break
    else:
        raise RuntimeError("could not allocate a short HOME deletion fixture")
    short_cvd_home_tmpdir = _create_short_cvd_root(
        short_cvd_root,
        work_root,
        ownership_token,
    )
    request.addfinalizer(lambda: shutil.rmtree(short_cvd_root, ignore_errors=True))
    state_root = data_root / "cvd-state"
    state_root.mkdir(mode=0o700)
    host_dir = data_root / "cuttlefish"
    (host_dir / "bin").mkdir(parents=True)
    (host_dir / "bin/cvd").write_text("Cuttlefish fixture\n", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    real_python = shutil.which("python3")
    assert real_python is not None
    ready_marker = tmp_path / "quarantine-ready"
    hook_script = tmp_path / "pause_before_quarantine_rmdir.py"
    hook_script.write_text(
        """from __future__ import annotations

import os
import runpy
import sys
import time
from pathlib import Path

support_script = Path(sys.argv[1])
support_arguments = sys.argv[2:]
ready_marker = Path(os.environ["APKRUN_TEST_QUARANTINE_READY"])
real_rmdir = os.rmdir

def pause_quarantine_removal(
    path: str | bytes,
    *args: object,
    **kwargs: object,
) -> None:
    if (
        isinstance(path, str)
        and path.startswith(".apkrun-quarantine-")
        and not ready_marker.exists()
    ):
        ready_marker.write_text(path, encoding="utf-8")
        time.sleep(0.5)
    real_rmdir(path, *args, **kwargs)

os.rmdir = pause_quarantine_removal
sys.argv = [str(support_script), *support_arguments]
runpy.run_path(str(support_script), run_name="__main__")
""",
        encoding="utf-8",
    )
    python_wrapper = fake_bin / "python3"
    python_wrapper.write_text(
        f"""#!/bin/sh
if [ "$2" = discard-short-cvd-root ]; then
  exec {real_python!r} {str(hook_script)!r} "$@"
fi
exec {real_python!r} "$@"
""",
        encoding="utf-8",
    )
    python_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_QUARANTINE_READY"] = str(ready_marker)
    script = f"""
set -u
script_dir={str(experiment_root)!r}
data_root={str(data_root)!r}
work_root={str(work_root)!r}
workspace_token={ownership_token!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
short_cvd_fleet_home=
cvd_state_dir={str(state_root)!r}
CVD_HOST_DIR={str(host_dir)!r}
capture_socket_metrics="$work_root/capture-socket-paths.json"
capture_process_starting_role=
capture_process_starting_released=0
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
require_no_crosvm() {{ return 0; }}
private_cvd_processes_are_clean() {{ return 0; }}
handle_signal() {{
  if _capture_process_note_startup_signal TERM 143; then
    return 0
  fi
  exit 143
}}
trap 'handle_signal' TERM
remove_short_cvd_root
exit 34
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not ready_marker.exists():
            if process.poll() is not None:
                pytest.fail("short HOME removal ended before the signal")
            time.sleep(0.005)
        if not ready_marker.exists():
            pytest.fail("could not observe the quarantined short HOME")
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == 143, stderr
    assert not stdout
    assert not short_cvd_root.exists()


def test_short_cvd_fleet_home_is_private_and_removable(tmp_path: Path) -> None:
    experiment_root = Path(__file__).parents[1]
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    short_cvd_root = tmp_path / "x.abcdef"
    short_cvd_home_tmpdir = _create_short_cvd_root(
        short_cvd_root, workspace_root, "c" * 64
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
work_root={str(workspace_root)!r}
workspace_token={"c" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
short_cvd_fleet_home=
source "$script_dir/capture-lifecycle.sh"
create_short_cvd_fleet_home
fleet_home_path="$short_cvd_fleet_home"
test -d "$fleet_home_path"
test ! -L "$fleet_home_path"
test "$fleet_home_path" = "$short_cvd_home_tmpdir"/p.*
printf 'private preflight data\\n' > "$fleet_home_path/cache"
query_crosvm_processes() {{ return 0; }}
private_cvd_processes_are_clean() {{ return 0; }}
remove_short_cvd_fleet_home
test -z "$short_cvd_fleet_home"
test ! -e "$fleet_home_path"
test -d "$short_cvd_home_tmpdir"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("phase", "signum", "exit_status"),
    [
        ("mktemp", signal.SIGINT, 130),
        ("python", signal.SIGTERM, 143),
        ("chmod", signal.SIGINT, 130),
    ],
)
def test_process_group_signal_during_fleet_home_startup_rolls_back_safely(
    tmp_path: Path,
    phase: str,
    signum: signal.Signals,
    exit_status: int,
) -> None:
    experiment_root = Path(__file__).parents[1]
    real_mktemp = shutil.which("mktemp")
    real_python = shutil.which("python3")
    real_chmod = shutil.which("chmod")
    assert real_mktemp is not None
    assert real_python is not None
    assert real_chmod is not None
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    short_cvd_root = tmp_path / "x.abcdef"
    short_cvd_home_tmpdir = _create_short_cvd_root(
        short_cvd_root,
        workspace_root,
        "c" * 64,
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    created_marker = tmp_path / "created"
    phase_marker = tmp_path / "phase-ready"
    mktemp_sleep = "sleep 0.5" if phase == "mktemp" else ":"
    (fake_bin / "mktemp").write_text(
        f"""#!/bin/sh
directory=$({real_mktemp!r} "$@") || exit $?
printf '%s\\n' "$directory" > {str(created_marker)!r}
{mktemp_sleep}
printf '%s\\n' "$directory"
""",
        encoding="utf-8",
    )
    (fake_bin / "mktemp").chmod(0o755)
    if phase == "python":
        command_wrapper = fake_bin / "python3"
        command = real_python
        trigger = '[ "$1" = - ]'
    elif phase == "chmod":
        command_wrapper = fake_bin / "chmod"
        command = real_chmod
        trigger = "[ ! -e " + repr(str(phase_marker)) + " ]"
    else:
        command_wrapper = None
        command = ""
        trigger = ""
    if command_wrapper is not None:
        command_wrapper.write_text(
            f"""#!/bin/sh
if {trigger}; then
  : > {str(phase_marker)!r}
  sleep 0.5
fi
exec {command!r} "$@"
""",
            encoding="utf-8",
        )
        command_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_SIGNAL_NAME"] = (
        "TERM" if signum == signal.SIGTERM else "INT"
    )
    script = f"""
set -u
script_dir={str(experiment_root)!r}
work_root={str(workspace_root)!r}
workspace_token={"c" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
short_cvd_fleet_home=
capture_process_starting_role=fleet_home
capture_process_starting_released=1
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  local signal_name=$1 exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  rollback_short_cvd_fleet_home
  exit "$exit_status"
}}
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 130' INT
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 143' TERM
if create_short_cvd_fleet_home; then
  :
else
  exit 35
fi
capture_process_starting_role=
_capture_process_complete_startup_signal fleet_home
capture_process_starting_released=0
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    created_home: Path | None = None
    try:
        ready_path = created_marker if phase == "mktemp" else phase_marker
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not ready_path.exists():
            if process.poll() is not None:
                pytest.fail(f"fleet HOME {phase} step ended before the signal")
            time.sleep(0.005)
        if not ready_path.exists() or not created_marker.exists():
            pytest.fail(f"could not observe fleet HOME {phase} initialization")
        created_home = Path(created_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signum)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == exit_status, stderr
    assert not stdout
    assert created_home is not None
    assert not created_home.exists()


def test_short_cvd_fleet_home_is_preserved_while_a_host_process_uses_it(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    short_cvd_root = tmp_path / "x.abcdef"
    short_cvd_home_tmpdir = _create_short_cvd_root(
        short_cvd_root, workspace_root, "d" * 64
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
work_root={str(workspace_root)!r}
workspace_token={"d" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
short_cvd_fleet_home=
source "$script_dir/capture-lifecycle.sh"
create_short_cvd_fleet_home
fleet_home_path="$short_cvd_fleet_home"
query_crosvm_processes() {{ return 0; }}
private_cvd_processes_are_clean() {{ return 1; }}
if remove_short_cvd_fleet_home; then
  exit 91
fi
test -d "$fleet_home_path"
test "$short_cvd_fleet_home" = "$fleet_home_path"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "preserving it" in result.stderr


def test_process_group_signal_during_fleet_home_removal_finishes_cleanup(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    short_cvd_root = tmp_path / "x.abcdef"
    short_cvd_home_tmpdir = _create_short_cvd_root(
        short_cvd_root,
        workspace_root,
        "f" * 64,
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    real_rm = shutil.which("rm")
    assert real_rm is not None
    ready_marker = tmp_path / "rm-ready"
    rm_wrapper = fake_bin / "rm"
    rm_wrapper.write_text(
        f"""#!/bin/sh
if [ "$2" = -- ] && [ "$3" = "$APKRUN_TEST_FLEET_HOME" ]; then
  {real_rm!r} -f "$APKRUN_TEST_FLEET_HOME/.apkrun-cvd-fleet-home"
  printf '%s\\n' "$APKRUN_TEST_FLEET_HOME" > {str(ready_marker)!r}
  sleep 0.5
fi
exec {real_rm!r} "$@"
""",
        encoding="utf-8",
    )
    rm_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    script = f"""
set -u
script_dir={str(experiment_root)!r}
work_root={str(workspace_root)!r}
workspace_token={"f" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
short_cvd_fleet_home=
capture_process_starting_role=
capture_process_starting_released=0
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  if _capture_process_note_startup_signal TERM 143; then
    return 0
  fi
  exit 143
}}
trap 'handle_signal' TERM
create_short_cvd_fleet_home
export APKRUN_TEST_FLEET_HOME="$short_cvd_fleet_home"
query_crosvm_processes() {{ return 0; }}
private_cvd_processes_are_clean() {{ return 0; }}
remove_short_cvd_fleet_home
exit 34
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not ready_marker.exists():
            if process.poll() is not None:
                pytest.fail("fleet HOME removal ended before the signal")
            time.sleep(0.005)
        if not ready_marker.exists():
            pytest.fail("could not observe partial fleet HOME removal")
        fleet_home = Path(ready_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == 143, stderr
    assert not stdout
    assert not fleet_home.exists()


def test_gpu_none_runner_uses_short_home_for_fleet_and_capture() -> None:
    experiment_root = Path(__file__).parents[1]
    runner_path = experiment_root / "capture-gpu-none.sh"
    runner = runner_path.read_text(encoding="utf-8")
    lifecycle = (experiment_root / "capture-lifecycle.sh").read_text(encoding="utf-8")

    assert 'HOME=$short_cvd_fleet_home" "TMPDIR=$short_cvd_fleet_home' in runner
    assert '"HOME=$short_cvd_home_tmpdir" "TMPDIR=$short_cvd_home_tmpdir"' in runner
    assert "--drain-after-limit --max-bytes 65536" in runner
    assert "capture-supervisor-stderr.log" in runner
    assert "capture-supervisor-stderr.fifo" in runner
    assert "capture-supervisor-stderr-start.fifo" in runner
    assert "signal-process-broker" in runner
    assert "capture-supervisor-stderr-control.fifo" in runner
    assert "capture_run_interrupted=" in runner
    assert 'if [ -e "$capture_run_interrupted" ]' in runner
    assert "Capture supervisor exited with status" in runner
    assert '--capture-exit-code "$capture_child_exit_code"' in runner
    assert "start_pinned_capture_process adb_server" in runner
    assert "start_pinned_capture_process capture_child" in runner
    assert '--tool-copy-root "$tool_destination"' in runner
    assert '--canonical-capture-copy "$canonical_capture_copy"' in runner
    assert '--baseline-record "$baseline_record"' in runner
    assert runner.index(" verify-host \\\n") < runner.index(" verify-tool-copy \\\n")
    assert runner.index(" verify-tool-copy \\\n") < runner.index(
        "start_pinned_capture_process adb_server"
    )
    assert "run_committed_experiment_support verify-host" in runner
    assert "run_committed_experiment_support \\\n  patch-capture" in runner
    assert "APKRUN_CAPTURE_SCRIPT_DIR=$tool_destination" in runner
    assert "timeout --signal=TERM 900" in runner
    assert "deadline = time.monotonic() + 900" in runner
    assert "arguments[index + 1] = str(remaining_seconds)" in runner
    assert '--verified-script "$capture_script"' in runner
    assert '--host-identity "$host_identity"' in runner
    assert "hashlib.sha256(committed_source).hexdigest() != expected" in runner
    assert "run_committed_capture_bounded \\\n" in runner
    assert '--tool-copy-root "$tool_destination" \\' in runner
    assert runner.index("trap cleanup EXIT") < runner.index(
        "work_root=$(trap '' HUP INT TERM; mktemp -d"
    )
    assert runner.index("trap cleanup EXIT") < runner.index(
        "adb_socket_dir=$(trap '' HUP INT TERM; mktemp -d"
    )
    assert "adb_socket_dir=$(trap '' HUP INT TERM; mktemp -d /tmp/apkrun-adb." in runner
    experiment_tool_copy = runner.split(
        'cp "$script_dir/capture-gpu-none.sh"',
        1,
    )[1].split('"$experiment_tools/"', 1)[0]
    assert '"$script_dir/capture_processes.py"' in experiment_tool_copy
    assert (
        'cp "$experiment_tools/capture_bounded.py" \\\n'
        '  "$experiment_tools/capture_processes.py" "$tool_destination/"' in runner
    )
    assert 'kill -TERM "$adb_server_pid"' not in runner
    assert 'kill -s "$signal_name" "$capture_child_pid"' not in runner
    assert "--exited-file" in runner
    assert "--stopped-file" in runner
    assert "start_pinned_capture_process()" in lifecycle
    assert "stop_pinned_capture_process()" in lifecycle
    assert "_capture_process_abort_start()" in lifecycle
    assert '_capture_process_abort_start "$role"' in lifecycle
    assert "printf 'CONT\\n' >&\"$control_fd\"" in lifecycle
    assert 'kill -TERM "$broker_pid"' not in lifecycle
    assert 'kill -KILL "$broker_pid"' not in lifecycle
    assert 'kill -CONT "$target_pid"' not in lifecycle
    assert "_capture_close_extra_descriptors()" in lifecycle
    assert "_capture_close_extra_descriptors || exit 125" in lifecycle
    assert (
        'start_pinned_capture_process watcher - - bash -c "$watcher_script"' in runner
    )
    assert (
        "(\n"
        "  _capture_close_extra_descriptors || exit 125\n"
        '  IFS= read -r _ < "$capture_supervisor_stderr_start_fifo"'
    ) in runner
    assert (
        "(\n"
        "  _capture_close_extra_descriptors || exit 125\n"
        '  exec python3 "$experiment_tools/experiment_support.py" '
        "signal-process-broker"
    ) in runner
    assert "printf 'start\\n' >&\"$start_fd\"" in lifecycle
    assert 'handle_signal "$signal_name" "$exit_status"' in lifecycle
    assert "adb_server_started=1" in lifecycle
    assert lifecycle.index("adb_server_started=1") < lifecycle.index(
        "capture_process_starting_role="
    )
    watcher_shutdown = runner.split("stop_watcher() {", 1)[1].split("\n}", 1)[0]
    assert watcher_shutdown.index(
        "printf 'done\\n' > \"$done_marker\""
    ) < watcher_shutdown.index('if [ -n "$watcher_pid" ]')
    assert "stop_pinned_capture_process watcher TERM" in watcher_shutdown
    assert "start_pinned_capture_process watcher" in runner
    assert "declare -f" in runner
    assert "check_bounded_cleanup capture_adb_control_output watch_adb" in runner
    assert "watcher_stop_failed=1" in watcher_shutdown
    assert "capture_process_starting_role=$role" in lifecycle
    assert "capture_process_starting_role=workspace" in runner
    watcher_shutdown_start = runner.index(': > "$done_marker"\n')
    watcher_wait = runner.index(
        'wait "$watcher_pid" || watcher_status=$?',
        watcher_shutdown_start,
    )
    watcher_finish = runner.index(
        "if ! stop_pinned_capture_process watcher TERM 5 3",
        watcher_wait,
    )
    watcher_clear = runner.index("watcher_pid=", watcher_finish)
    assert watcher_wait < watcher_finish < watcher_clear
    assert "short_cvd_root=$(trap '' HUP INT TERM; mktemp -d" in lifecycle
    assert "capture_process_starting_role=fleet_home" in runner
    assert runner.index("capture_process_starting_role=fleet_home") < runner.index(
        "create_short_cvd_fleet_home"
    )
    assert "rollback_short_cvd_home_root()" in lifecycle
    assert "rollback_short_cvd_fleet_home()" in lifecycle
    assert "audit-unix-sockets" in lifecycle
    assert "run_committed_experiment_support()" in lifecycle
    assert "run_committed_capture_bounded()" in lifecycle
    assert "run_verified_experiment_support()" in lifecycle
    assert "F_SEAL_WRITE" in lifecycle
    assert "run_verified_compare_boot" in lifecycle
    assert 'python3 "$script_dir/experiment_support.py" publish-record' not in lifecycle
    assert "trap '' HUP INT TERM; rm -rf -- \"$short_cvd_fleet_home\"" in lifecycle
    assert (
        "trap '' HUP INT TERM; python3 \"$script_dir/experiment_support.py\" "
        "discard-short-cvd-root"
    ) in lifecycle
    assert (
        'start_pinned_capture_process watcher - - bash -c "$watcher_script"' in runner
    )
    signal_handler = runner.split("handle_signal() {", 1)[1].split("\n}", 1)[0]
    assert 'rm -rf "$adb_socket_dir"' in signal_handler
    assert "_capture_process_reap_broker()" in lifecycle
    assert (
        "Capture process broker did not exit after publishing its stopped record; preserving its workspace."
        in lifecycle
    )
    assert "audit-unix-sockets" in runner
    assert "--fleet-socket-metrics" in runner
    root_removal = lifecycle.split("remove_short_cvd_root() {", 1)[1].split(
        "\n}",
        1,
    )[0]
    assert "discard-short-cvd-root" in root_removal
    assert "_capture_process_complete_startup_signal short_home_cleanup" in root_removal
    assert 'rmdir "$short_cvd_home_tmpdir"' not in root_removal
    reader_shutdown = runner.split(
        "stop_capture_supervisor_stderr_reader() {",
        1,
    )[1].split("\n}", 1)[0]
    assert "seq 1 5" in reader_shutdown
    assert "printf '%s\\n' \"$signal_name\" >&7" in reader_shutdown
    assert "capture_supervisor_stderr_signal_broker_ready" in reader_shutdown
    assert "capture_supervisor_stderr_exited" in reader_shutdown
    assert 'kill -s "$signal_name"' not in reader_shutdown
    for function_name in ("cleanup", "handle_signal"):
        function_body = runner.split(f"{function_name}() {{", 1)[1].split(
            "\n}",
            1,
        )[0]
        assert "stop_capture_supervisor_stderr_reader" in function_body
        assert function_body.index("remove_short_cvd_fleet_home") < function_body.index(
            "remove_short_cvd_root"
        )
        assert function_body.index("remove_short_cvd_root") < function_body.index(
            "cvd_is_clean"
        )
        if function_name == "handle_signal":
            assert "trap - EXIT" in function_body


def test_signal_cleanup_removes_the_private_adb_socket_directory(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    runner = (experiment_root / "capture-gpu-none.sh").read_text(encoding="utf-8")
    signal_handler = runner.split("handle_signal() {", 1)[1].split("\n}", 1)[0]
    socket_directory = tmp_path / "adb-socket"
    socket_directory.mkdir(mode=0o700)
    (socket_directory / "server.sock").touch()
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
adb_socket_dir={str(socket_directory)!r}
adb_server_started=1
capture_process_starting_role=
capture_process_startup_signal_exit_status=
capture_child_pid=
capture_supervisor_stderr_start_gate_open=0
capture_supervisor_stderr_fifo_guard_open=0
capture_supervisor_stderr_pid=
watcher_pid=
watcher_stop_failed=0
short_cvd_root=
source "$script_dir/capture-lifecycle.sh"
preserve_work() {{ :; }}
release_capture_supervisor_stderr_start_gate() {{ :; }}
stop_capture_supervisor_stderr_reader() {{ :; }}
stop_capture_supervisor_stderr_signal_broker() {{ :; }}
stop_watcher() {{ :; }}
scrub_raw_logcat() {{ :; }}
remove_short_cvd_root() {{ :; }}
cvd_is_clean() {{ return 0; }}
stop_adb_server() {{ adb_server_started=0; }}
handle_signal() {{{signal_handler}
}}
handle_signal INT 130
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 130, result.stderr
    assert not socket_directory.exists()


@pytest.mark.parametrize(
    ("signal_name", "signum"),
    [("INT", signal.SIGINT), ("TERM", signal.SIGTERM)],
)
def test_process_group_signal_during_socket_directory_creation_is_cleaned(
    tmp_path: Path,
    signal_name: str,
    signum: signal.Signals,
) -> None:
    real_mktemp = shutil.which("mktemp")
    assert real_mktemp is not None
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    created_marker = tmp_path / "created"
    result_path = tmp_path / "result"
    mktemp_wrapper = fake_bin / "mktemp"
    mktemp_wrapper.write_text(
        f"""#!/bin/sh
directory=$({real_mktemp!r} "$@") || exit $?
printf '%s\\n' "$directory" > {str(created_marker)!r}
sleep 0.5
printf '%s\\n' "$directory"
""",
        encoding="utf-8",
    )
    mktemp_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_SIGNAL_NAME"] = signal_name
    script = f"""
set -u
adb_socket_dir=
cleanup() {{
  trap - "$APKRUN_TEST_SIGNAL_NAME"
  if [ -n "$adb_socket_dir" ]; then
    rm -rf "$adb_socket_dir"
  fi
}}
trap cleanup "$APKRUN_TEST_SIGNAL_NAME"
adb_socket_dir=$(trap '' HUP INT TERM; mktemp -d /tmp/apkrun-adb.XXXXXX)
printf '%s\\n' "$adb_socket_dir" > {str(result_path)!r}
test ! -e "$adb_socket_dir"
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    created_directory: Path | None = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not created_marker.exists():
            if process.poll() is not None:
                pytest.fail("socket directory creation ended before the signal")
            time.sleep(0.005)
        if not created_marker.exists():
            pytest.fail("could not observe socket directory creation")
        created_directory = Path(created_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signum)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == 0, stderr
    assert not stdout
    assert created_directory is not None
    assert result_path.read_text(encoding="utf-8").strip() == str(created_directory)
    assert not created_directory.exists()


@pytest.mark.parametrize(
    ("signal_name", "signum", "exit_status"),
    [("INT", signal.SIGINT, 130), ("TERM", signal.SIGTERM, 143)],
)
def test_process_group_signal_during_workspace_creation_is_cleaned(
    tmp_path: Path,
    signal_name: str,
    signum: signal.Signals,
    exit_status: int,
) -> None:
    experiment_root = Path(__file__).parents[1]
    real_mktemp = shutil.which("mktemp")
    assert real_mktemp is not None
    work_parent = tmp_path / "work"
    work_parent.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    created_marker = tmp_path / "created"
    mktemp_wrapper = fake_bin / "mktemp"
    mktemp_wrapper.write_text(
        f"""#!/bin/sh
directory=$({real_mktemp!r} "$@") || exit $?
printf '%s\\n' "$directory" > {str(created_marker)!r}
sleep 0.5
printf '%s\\n' "$directory"
""",
        encoding="utf-8",
    )
    mktemp_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_SIGNAL_NAME"] = signal_name
    script = f"""
set -u
script_dir={str(experiment_root)!r}
work_parent={str(work_parent)!r}
work_root=
workspace_token={"0123456789abcdef" * 4!r}
capture_process_starting_role=workspace
capture_process_starting_released=1
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  local signal_name=$1 exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  if [ -n "$work_root" ]; then
    rm -rf -- "$work_root"
  fi
  exit "$exit_status"
}}
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 130' INT
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 143' TERM
work_root=$(trap '' HUP INT TERM; mktemp -d "$work_parent/gpu-none.XXXXXX")
printf 'marker\\n' > "$work_root/.apkrun-cuttlefish-workspace"
capture_process_starting_role=
_capture_process_complete_startup_signal workspace
capture_process_starting_released=0
printf '%s\\n' "$work_root" > {str(tmp_path / "result")!r}
test ! -e "$work_root"
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not created_marker.exists():
            if process.poll() is not None:
                pytest.fail("workspace creation ended before the signal")
            time.sleep(0.005)
        if not created_marker.exists():
            pytest.fail("could not observe workspace creation")
        created_directory = Path(created_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signum)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == exit_status, stderr
    assert not stdout
    assert created_directory is not None
    assert not created_directory.exists()


@pytest.mark.parametrize(
    ("signal_name", "signum", "exit_status"),
    [("INT", signal.SIGINT, 130), ("TERM", signal.SIGTERM, 143)],
)
def test_process_group_signal_during_short_cvd_root_creation_is_cleaned(
    tmp_path: Path,
    signal_name: str,
    signum: signal.Signals,
    exit_status: int,
) -> None:
    experiment_root = Path(__file__).parents[1]
    real_mktemp = shutil.which("mktemp")
    assert real_mktemp is not None
    work_root = tmp_path / "workspace"
    work_root.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    created_marker = tmp_path / "created"
    mktemp_wrapper = fake_bin / "mktemp"
    mktemp_wrapper.write_text(
        f"""#!/bin/sh
directory=$({real_mktemp!r} "$@") || exit $?
printf '%s\\n' "$directory" > {str(created_marker)!r}
sleep 0.5
printf '%s\\n' "$directory"
""",
        encoding="utf-8",
    )
    mktemp_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_SIGNAL_NAME"] = signal_name
    script = f"""
set -u
script_dir={str(experiment_root)!r}
work_root={str(work_root)!r}
workspace_token={"0123456789abcdef" * 4!r}
short_cvd_root=
short_cvd_home_tmpdir=
short_cvd_fleet_home=
capture_process_starting_role=workspace
capture_process_starting_released=1
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  local signal_name=$1 exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  rollback_short_cvd_home_root
  exit "$exit_status"
}}
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 130' INT
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 143' TERM
if create_short_cvd_home_root; then
  :
else
  exit 35
fi
capture_process_starting_role=
_capture_process_complete_startup_signal short_cvd_root
capture_process_starting_released=0
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    created_directory: Path | None = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not created_marker.exists():
            if process.poll() is not None:
                pytest.fail("short Cuttlefish root creation ended before the signal")
            time.sleep(0.005)
        if not created_marker.exists():
            pytest.fail("could not observe short Cuttlefish root creation")
        created_directory = Path(created_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signum)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        root_remains = created_directory is not None and created_directory.exists()

    assert process.returncode == exit_status, stderr
    assert not stdout
    assert created_directory is not None
    assert not root_remains


@pytest.mark.parametrize(
    ("phase", "signum", "exit_status"),
    [
        ("python", signal.SIGTERM, 143),
        ("chmod", signal.SIGINT, 130),
    ],
)
def test_process_group_signal_during_short_home_initialization_rolls_back_safely(
    tmp_path: Path,
    phase: str,
    signum: signal.Signals,
    exit_status: int,
) -> None:
    experiment_root = Path(__file__).parents[1]
    real_mktemp = shutil.which("mktemp")
    real_python = shutil.which("python3")
    real_chmod = shutil.which("chmod")
    assert real_mktemp is not None
    assert real_python is not None
    assert real_chmod is not None
    work_root = tmp_path / "workspace"
    work_root.mkdir(mode=0o700)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    created_marker = tmp_path / "created"
    phase_marker = tmp_path / "phase-ready"
    (fake_bin / "mktemp").write_text(
        f"""#!/bin/sh
directory=$({real_mktemp!r} "$@") || exit $?
printf '%s\\n' "$directory" > {str(created_marker)!r}
printf '%s\\n' "$directory"
""",
        encoding="utf-8",
    )
    (fake_bin / "mktemp").chmod(0o755)
    if phase == "python":
        command_wrapper = fake_bin / "python3"
        command = real_python
        trigger = '[ "$1" = - ]'
    else:
        command_wrapper = fake_bin / "chmod"
        command = real_chmod
        trigger = "true"
    command_wrapper.write_text(
        f"""#!/bin/sh
if {trigger}; then
  : > {str(phase_marker)!r}
  sleep 0.5
fi
exec {command!r} "$@"
""",
        encoding="utf-8",
    )
    command_wrapper.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["APKRUN_TEST_SIGNAL_NAME"] = (
        "TERM" if signum == signal.SIGTERM else "INT"
    )
    script = f"""
set -u
script_dir={str(experiment_root)!r}
work_root={str(work_root)!r}
workspace_token={"fedcba9876543210" * 4!r}
short_cvd_root=
short_cvd_home_tmpdir=
short_cvd_fleet_home=
capture_process_starting_role=workspace
capture_process_starting_released=1
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  local signal_name=$1 exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  rollback_short_cvd_home_root
  exit "$exit_status"
}}
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 130' INT
trap 'handle_signal "$APKRUN_TEST_SIGNAL_NAME" 143' TERM
if create_short_cvd_home_root; then
  :
else
  exit 35
fi
capture_process_starting_role=
_capture_process_complete_startup_signal short_cvd_root
capture_process_starting_released=0
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
        start_new_session=True,
    )
    created_directory: Path | None = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not phase_marker.exists():
            if process.poll() is not None:
                pytest.fail(f"short HOME {phase} step ended before the signal")
            time.sleep(0.005)
        if not phase_marker.exists() or not created_marker.exists():
            pytest.fail(f"could not observe short HOME {phase} initialization")
        created_directory = Path(created_marker.read_text(encoding="utf-8").strip())
        os.killpg(process.pid, signum)
        stdout, stderr = process.communicate(timeout=4)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == exit_status, stderr
    assert not stdout
    assert created_directory is not None
    assert not created_directory.exists()


def test_adb_server_started_is_set_before_startup_signal_handoff(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
capture_process_starting_role=adb_server
capture_process_starting_released=1
capture_process_startup_signal_name=INT
capture_process_startup_signal_exit_status=130
adb_server_started=0
source "$script_dir/capture-lifecycle.sh"
handle_signal() {{
  test "$adb_server_started" -eq 1
  test -z "$capture_process_starting_role"
  exit "$2"
}}
_capture_process_complete_startup_signal adb_server
exit 33
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 130, result.stderr


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="direct child cleanup uses Linux /proc process states",
)
def test_watcher_stop_marker_failure_stops_its_pinned_child(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    runner = (experiment_root / "capture-gpu-none.sh").read_text(encoding="utf-8")
    stop_watcher = runner.split("stop_watcher() {", 1)[1].split("\n}", 1)[0]
    ready_marker = tmp_path / "pinned-watcher-ready"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools=$script_dir
work_root={str(tmp_path)!r}
done_marker=/proc/apkrun-capture-stop-marker
watcher_stop_failed=0
watcher_pid=
watcher_start_time=
watcher_signal_broker_pid=
watcher_control_fd=
watcher_start_fd=
watcher_start_fifo=
watcher_control_fifo=
watcher_signal_broker_ready_file=
watcher_signal_broker_exit_file=
watcher_signal_broker_stopped_file=
capture_process_starting_role=
capture_process_starting_released=0
keep_work=0
source "$script_dir/capture-lifecycle.sh"
preserve_work() {{ keep_work=1; }}
stop_watcher() {{{stop_watcher}
}}
start_pinned_capture_process watcher - - python3 -c \
  'import pathlib, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text("ready"); time.sleep(30)' \
  {str(ready_marker)!r}
while [ ! -f {str(ready_marker)!r} ]; do sleep 0.01; done
test_pid=$watcher_pid
if stop_watcher; then
  exit 31
fi
test "$watcher_stop_failed" -eq 1
test "$keep_work" -eq 1
test -z "$watcher_pid"
test "$(_capture_process_state "$test_pid")" = missing
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=12,
    )

    assert result.returncode == 0, result.stderr
    assert "Could not signal the logcat watcher" in result.stderr


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="normal watcher shutdown verifies Linux pidfd broker lifecycle",
)
def test_normal_watcher_shutdown_preserves_work_when_broker_finalization_fails(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    runner = (experiment_root / "capture-gpu-none.sh").read_text(encoding="utf-8")
    normal_watcher_shutdown = (
        ': > "$done_marker"\n'
        + runner.split(
            ': > "$done_marker"\n',
            1,
        )[1].split('\nrm -f "$capture_supervisor_stderr_fifo"', 1)[0]
    )
    done_marker = tmp_path / "watcher-done"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools=$script_dir
work_root={str(tmp_path)!r}
done_marker={str(done_marker)!r}
watcher_status=0
watcher_pid=
watcher_start_time=
watcher_signal_broker_pid=
watcher_control_fd=
watcher_start_fd=
watcher_start_fifo=
watcher_control_fifo=
watcher_signal_broker_ready_file=
watcher_signal_broker_exit_file=
watcher_signal_broker_stopped_file=
capture_supervisor_stderr_fifo={str(tmp_path / "stderr.fifo")!r}
capture_supervisor_stderr_control_fifo={str(tmp_path / "stderr-control.fifo")!r}
adb_cleanup_failure_marker={str(tmp_path / "incomplete-cleanup")!r}
broker_finish_attempted=0
keep_work=0
source "$script_dir/capture-lifecycle.sh"
preserve_work() {{ keep_work=1; }}
eval "$(declare -f _capture_process_finish_broker | sed '1s/_capture_process_finish_broker/_capture_process_finish_broker_impl/')"
_capture_process_finish_broker() {{
  broker_finish_attempted=1
  _capture_process_finish_broker_impl "$@"
  return 1
}}
start_pinned_capture_process watcher - - bash -c \
  'while [ ! -e "$1" ]; do sleep 0.01; done' _ "$done_marker"
{normal_watcher_shutdown}
test "$watcher_status" -eq 1
test "$broker_finish_attempted" -eq 1
test "$keep_work" -eq 1
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )

    assert result.returncode == 0, result.stderr


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="broker cleanup uses Linux /proc process states",
)
def test_broker_reaping_preserves_an_unpinned_live_child(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    release_marker = tmp_path / "release-unpinned-child"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
source "$script_dir/capture-lifecycle.sh"
python3 -c 'import signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
marker = Path(sys.argv[1])
while not marker.exists():
    time.sleep(0.01)' {str(release_marker)!r} &
broker_pid=$!
test_pid=$broker_pid
if _capture_process_reap_broker "$broker_pid"; then
  exit 32
fi
test "$(_capture_process_state "$test_pid")" = S
: > {str(release_marker)!r}
wait "$test_pid"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=8,
    )

    assert result.returncode == 0, result.stderr
    assert (
        "did not exit after publishing its stopped record; preserving its workspace"
        in result.stderr
    )


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="pinned capture process supervision requires Linux pidfds",
)
def test_pinned_capture_process_helper_stops_child_without_numeric_pid_signals(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    work_root = tmp_path / "private-work"
    work_root.mkdir(mode=0o700)
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_root)!r}
work_root={str(work_root)!r}
capture_child_pid=
capture_child_start_time=
capture_child_signal_broker_pid=
capture_child_control_fd=
capture_child_start_fd=
capture_child_start_fifo=
capture_child_control_fifo=
capture_child_signal_broker_ready_file=
capture_child_signal_broker_exit_file=
capture_child_signal_broker_stopped_file=
source "$script_dir/capture-lifecycle.sh"
start_pinned_capture_process capture_child /dev/null /dev/null \
  python3 -c 'import time; time.sleep(30)'
test -n "$capture_child_pid"
test -n "$capture_child_signal_broker_pid"
test ! -e "/proc/$capture_child_pid/fd/32"
test ! -e "/proc/$capture_child_signal_broker_pid/fd/32"
stop_pinned_capture_process capture_child TERM 5 3
test -z "$capture_child_pid"
test -z "$capture_child_signal_broker_pid"
test -z "$capture_child_control_fd"
test -z "$(find "$work_root" -mindepth 1 -print -quit)"
"""

    inherited_descriptor = os.open(
        tmp_path / "inherited-descriptor",
        os.O_CREAT | os.O_RDWR,
        0o600,
    )
    if inherited_descriptor != 32:
        os.dup2(inherited_descriptor, 32, inheritable=True)
        os.close(inherited_descriptor)
    try:
        result = subprocess.run(
            ["bash", "-c", script],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
            pass_fds=(32,),
        )
    finally:
        os.close(32)

    assert result.returncode == 0, result.stderr


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="pinned capture process supervision requires Linux pidfds",
)
def test_pinned_capture_process_broker_start_failure_cleans_gated_child(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    work_root = tmp_path / "private-work"
    experiment_tools = tmp_path / "experiment-tools"
    work_root.mkdir(mode=0o700)
    experiment_tools.mkdir(mode=0o700)
    helper = experiment_tools / "experiment_support.py"
    helper.write_text(
        f"""#!/usr/bin/env python3
import os
import sys
sys.path.insert(0, {str(experiment_root)!r})
import experiment_support
if sys.argv[1] == "signal-process-broker":
    def unavailable_pidfd(*_arguments):
        raise OSError("pidfd unavailable")
    os.pidfd_open = unavailable_pidfd
raise SystemExit(experiment_support.main())
""",
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_tools)!r}
work_root={str(work_root)!r}
capture_child_pid=
capture_child_start_time=
capture_child_signal_broker_pid=
capture_child_control_fd=
capture_child_start_fd=
capture_child_start_fifo=
capture_child_control_fifo=
capture_child_signal_broker_ready_file=
capture_child_signal_broker_exit_file=
capture_child_signal_broker_stopped_file=
source "$script_dir/capture-lifecycle.sh"
if start_pinned_capture_process capture_child /dev/null /dev/null \
  python3 -c 'import time; time.sleep(30)'; then
  exit 2
fi
test -z "$capture_child_pid"
test -z "$capture_child_signal_broker_pid"
test -z "$capture_child_control_fd"
test -z "$(find "$work_root" -mindepth 1 -print -quit)"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )

    assert result.returncode == 0, result.stderr
    assert "refusing to start it" in result.stderr
    assert "exited during startup" in result.stderr


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="startup signal handling requires Linux pidfds",
)
def test_pinned_capture_start_aborts_gated_child_when_interrupted(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    work_root = tmp_path / "private-work"
    experiment_tools = tmp_path / "experiment-tools"
    work_root.mkdir(mode=0o700)
    experiment_tools.mkdir(mode=0o700)
    broker_started = tmp_path / "broker-started"
    helper = experiment_tools / "experiment_support.py"
    helper.write_text(
        f"""#!/usr/bin/env python3
import os
import sys
import signal
import time
sys.path.insert(0, {str(experiment_root)!r})
import experiment_support
if sys.argv[1] == "signal-process-broker":
    arguments = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    os.kill(int(arguments["--pid"]), signal.SIGSTOP)
    with open(os.environ["APKRUN_TEST_TARGET_PID"], "x", encoding="ascii") as target:
        target.write(arguments["--pid"])
    with open(os.environ["APKRUN_TEST_BROKER_STARTED"], "x", encoding="ascii"):
        pass
    time.sleep(1)
raise SystemExit(experiment_support.main())
""",
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_tools)!r}
work_root={str(work_root)!r}
capture_child_pid=
capture_child_start_time=
capture_child_signal_broker_pid=
capture_child_control_fd=
capture_child_start_fd=
capture_child_start_fifo=
capture_child_control_fifo=
capture_child_signal_broker_ready_file=
capture_child_signal_broker_exit_file=
capture_child_signal_broker_stopped_file=
capture_process_starting_role=
capture_process_starting_released=0
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
preserve_work() {{ :; }}
handle_signal() {{
  if _capture_process_note_startup_signal INT 130; then
    return 0
  fi
  exit 130
}}
trap 'handle_signal' INT
trap 'test -z "$(find "$work_root" -mindepth 1 -print -quit)"' EXIT
start_pinned_capture_process capture_child /dev/null /dev/null \
  python3 -c 'import time; time.sleep(30)'
exit 2
    """
    environment = os.environ.copy()
    environment["APKRUN_TEST_BROKER_STARTED"] = str(broker_started)
    target_pid_path = tmp_path / "target-pid"
    environment["APKRUN_TEST_TARGET_PID"] = str(target_pid_path)
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not broker_started.exists():
            if process.poll() is not None:
                pytest.fail("pinned child startup ended before the signal test")
            time.sleep(0.01)
        if not broker_started.exists():
            pytest.fail("could not observe the delayed signal broker")
        os.kill(process.pid, signal.SIGINT)
        stdout, stderr = process.communicate(timeout=15)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == 130, stderr
    assert not stdout
    assert not list(work_root.iterdir())
    target_pid = int(target_pid_path.read_text(encoding="ascii"))
    assert not Path("/proc", str(target_pid)).exists()


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="startup signal handoff requires Linux pidfds",
)
def test_pinned_capture_start_hands_signal_to_normal_cleanup_after_gate_release(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    work_root = tmp_path / "private-work"
    work_root.mkdir(mode=0o700)
    gate_write_started = tmp_path / "gate-write-started"
    normal_handler_called = tmp_path / "normal-handler-called"
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_root)!r}
work_root={str(work_root)!r}
capture_child_pid=
capture_child_start_time=
capture_child_signal_broker_pid=
capture_child_control_fd=
capture_child_start_fd=
capture_child_start_fifo=
capture_child_control_fifo=
capture_child_signal_broker_ready_file=
capture_child_signal_broker_exit_file=
capture_child_signal_broker_stopped_file=
capture_process_starting_role=
capture_process_starting_released=0
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=
interrupted=0
source "$script_dir/capture-lifecycle.sh"
printf() {{
  builtin printf "$@"
  if [ "$#" -eq 1 ] && [ "$1" = 'start\\n' ]; then
    : > {str(gate_write_started)!r}
    sleep 0.25
  fi
}}
handle_signal() {{
  local signal_name=$1 exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  trap '' HUP INT TERM
  trap - EXIT
  : > {str(normal_handler_called)!r}
  stop_pinned_capture_process capture_child "$signal_name" 1 2 || preserve_work
  exit "$exit_status"
}}
preserve_work() {{ :; }}
trap 'handle_signal INT 130' INT
trap 'test -z "$(find "$work_root" -mindepth 1 -print -quit)"' EXIT
start_pinned_capture_process capture_child /dev/null /dev/null \
  python3 -c 'import time; time.sleep(30)'
exit 2
"""
    process = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not gate_write_started.exists():
            if process.poll() is not None:
                pytest.fail("pinned child startup ended before gate release")
            time.sleep(0.005)
        if not gate_write_started.exists():
            pytest.fail("could not observe the atomic gate release")
        os.kill(process.pid, signal.SIGINT)
        stdout, stderr = process.communicate(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    assert process.returncode == 130, stderr
    assert not stdout
    assert normal_handler_called.is_file()
    assert not list(work_root.iterdir())


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="startup exit-record verification requires Linux",
)
def test_pinned_capture_start_does_not_block_on_a_dead_gated_child(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    work_root = tmp_path / "private-work"
    experiment_tools = tmp_path / "experiment-tools"
    work_root.mkdir(mode=0o700)
    experiment_tools.mkdir(mode=0o700)
    helper = experiment_tools / "experiment_support.py"
    helper.write_text(
        f"""#!/usr/bin/env python3
import os
import sys
sys.path.insert(0, {str(experiment_root)!r})
import experiment_support
if sys.argv[1] == "signal-process-broker":
    arguments = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    identity = f"{{arguments['--pid']}} {{arguments['--start-time']}}\\n"
    os.kill(int(arguments["--pid"]), 9)
    for option in ("--ready-file", "--exited-file", "--stopped-file"):
        with open(arguments[option], "x", encoding="ascii") as record:
            record.write(identity)
    raise SystemExit(0)
raise SystemExit(experiment_support.main())
""",
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
experiment_tools={str(experiment_tools)!r}
work_root={str(work_root)!r}
capture_child_pid=
capture_child_start_time=
capture_child_signal_broker_pid=
capture_child_control_fd=
capture_child_start_fd=
capture_child_start_fifo=
capture_child_control_fifo=
capture_child_signal_broker_ready_file=
capture_child_signal_broker_exit_file=
capture_child_signal_broker_stopped_file=
capture_process_starting_role=
capture_process_starting_released=0
source "$script_dir/capture-lifecycle.sh"
if start_pinned_capture_process capture_child /dev/null /dev/null \
  python3 -c 'import time; time.sleep(30)'; then
  exit 2
fi
test -z "$capture_child_pid"
test -z "$capture_child_signal_broker_pid"
test -z "$(find "$work_root" -mindepth 1 -print -quit)"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    assert "exited before its start gate opened" in result.stderr


def test_short_cvd_root_removal_requires_process_and_state_audit_context(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    short_cvd_root = tmp_path / "apkrun-cvd-short.test123"
    workspace_root = tmp_path / "workspace"
    work_tmp_root = tmp_path / "workspace/tmp"
    workspace_root.mkdir()
    work_tmp_root.mkdir(parents=True)
    short_cvd_home_tmpdir = _create_short_cvd_root(short_cvd_root, workspace_root)
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
work_root={str(workspace_root)!r}
workspace_token={"a" * 64!r}
source "$script_dir/capture-lifecycle.sh"
if remove_short_cvd_root; then
  exit 2
fi
test -n "$short_cvd_root"
test -n "$short_cvd_home_tmpdir"
test -d "$short_cvd_root"
test -d "$short_cvd_home_tmpdir"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert short_cvd_root.is_dir()
    assert short_cvd_home_tmpdir.is_dir()
    assert work_tmp_root.is_dir()


def test_short_cvd_root_removal_refuses_a_replaced_tmp_directory(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    short_cvd_root = tmp_path / "apkrun-cvd-short.test123"
    workspace_root = tmp_path / "workspace"
    external_target = tmp_path / "external"
    workspace_root.mkdir()
    external_target.mkdir()
    short_cvd_home_tmpdir = _create_short_cvd_root(short_cvd_root, workspace_root)
    short_cvd_home_tmpdir.rmdir()
    short_cvd_home_tmpdir.symlink_to(external_target, target_is_directory=True)
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
work_root={str(workspace_root)!r}
workspace_token={"a" * 64!r}
source "$script_dir/capture-lifecycle.sh"
if remove_short_cvd_root; then
  exit 2
fi
test -L "$short_cvd_home_tmpdir"
test -d {str(external_target)!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert short_cvd_root.is_dir()
    assert short_cvd_home_tmpdir.is_symlink()
    assert external_target.is_dir()


def test_workspace_retention_keeps_short_cvd_root_while_cvd_is_active(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    workspace_root = tmp_path / "workspace"
    work_tmp_root = workspace_root / "tmp"
    workspace_root.mkdir()
    work_tmp_root.mkdir()
    short_cvd_root = tmp_path / "apkrun-cvd-short.active"
    short_cvd_home_tmpdir = _create_short_cvd_root(short_cvd_root, workspace_root)
    (short_cvd_home_tmpdir / "apkrun-cvd-home.default.active").mkdir()
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
tmp_root={str(work_tmp_root)!r}
work_root={str(workspace_root)!r}
workspace_token={"a" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
query_crosvm_processes() {{
  printf '1234\\n'
}}
retain_workspace_safely
test "$keep_work" -eq 1
test -d "$short_cvd_home_tmpdir"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "not verified clean" in result.stderr
    assert short_cvd_root.is_dir()
    assert short_cvd_home_tmpdir.is_dir()
    assert work_tmp_root.is_dir()


def test_capture_output_status_reports_truncation(tmp_path: Path) -> None:
    experiment_root = Path(__file__).parents[1]
    status_path = tmp_path / "capture-output.json"
    status_path.write_text(
        '{"schemaVersion":1,"bytesWritten":1048576,"truncated":true,'
        '"timedOut":false,"childExitCode":0,"signal":null,'
        '"cleanupComplete":true}\n',
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
source "$script_dir/capture-lifecycle.sh"
if report_capture_output_status {str(status_path)!r}; then
  exit 2
fi
printf '%s\\n' '{{"schemaVersion":1,"bytesWritten":16,"truncated":false,"timedOut":false,"childExitCode":null,"signal":null,"cleanupComplete":true}}' > {str(status_path)!r}
report_capture_output_status {str(status_path)!r}
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stderr.count("reached its 1 MiB limit") == 1


def test_short_cvd_cleanup_failure_reports_both_private_paths(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    short_cvd_root = tmp_path / "x.abcdef"
    short_cvd_home_tmpdir = _create_short_cvd_root(short_cvd_root, workspace_root)
    marker = short_cvd_root / ".apkrun-cvd-short-home"
    marker.write_text("unexpected marker\n", encoding="utf-8")
    marker.chmod(0o600)
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
work_root={str(workspace_root)!r}
tmp_root="$work_root/tmp"
mkdir -p "$tmp_root"
workspace_token={"a" * 64!r}
short_cvd_root={str(short_cvd_root)!r}
short_cvd_home_tmpdir={str(short_cvd_home_tmpdir)!r}
keep_work=0
source "$script_dir/capture-lifecycle.sh"
query_crosvm_processes() {{ return 0; }}
if discard_workspace_safely; then
  exit 2
fi
test "$keep_work" -eq 1
test -d "$work_root"
test -d "$short_cvd_root"
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert str(workspace_root) in result.stderr
    assert str(short_cvd_root) in result.stderr


def test_capture_output_status_rejects_missing_and_incomplete_status(
    tmp_path: Path,
) -> None:
    experiment_root = Path(__file__).parents[1]
    missing_status = tmp_path / "missing-status.json"
    status_path = tmp_path / "capture-output.json"
    status_path.write_text(
        '{"schemaVersion":1,"bytesWritten":1,"truncated":false,'
        '"timedOut":false,"childExitCode":0,"signal":null,'
        '"cleanupComplete":false}\n',
        encoding="utf-8",
    )
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
source "$script_dir/capture-lifecycle.sh"
if report_capture_output_status {str(missing_status)!r}; then
  exit 2
fi
if report_capture_output_status {str(status_path)!r}; then
  exit 3
fi
printf '%s\\n' '{{"schemaVersion":1,"bytesWritten":1,"truncated":false,"timedOut":false,"signal":null,"cleanupComplete":true}}' > {str(status_path)!r}
if report_capture_output_status {str(status_path)!r}; then
  exit 4
fi
printf '%s\\n' '{{"schemaVersion":1,"bytesWritten":1,"truncated":false,"timedOut":false,"childExitCode":0,"cleanupComplete":true}}' > {str(status_path)!r}
if report_capture_output_status {str(status_path)!r}; then
  exit 5
fi
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "status is missing" in result.stderr
    assert result.stderr.count("status is invalid") == 3


def test_capture_output_status_rejects_symlink(tmp_path: Path) -> None:
    experiment_root = Path(__file__).parents[1]
    external_status = tmp_path / "external-status.json"
    external_status.write_text(
        '{"schemaVersion":1,"bytesWritten":1,"truncated":true,'
        '"timedOut":false,"childExitCode":0,"signal":null,'
        '"cleanupComplete":true}\n',
        encoding="utf-8",
    )
    status_path = tmp_path / "capture-output.json"
    status_path.symlink_to(external_status)
    script = f"""
set -euo pipefail
script_dir={str(experiment_root)!r}
source "$script_dir/capture-lifecycle.sh"
if report_capture_output_status {str(status_path)!r}; then
  exit 2
fi
"""

    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert "not a regular file" in result.stderr
    assert status_path.is_symlink()
    assert external_status.is_file()


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
