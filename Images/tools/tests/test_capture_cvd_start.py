from __future__ import annotations

import argparse
import importlib.util
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

HELPER_PATH = Path(__file__).parents[1] / "reference" / "capture_cvd_start.py"
MODULE_SPEC = importlib.util.spec_from_file_location("capture_cvd_start", HELPER_PATH)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
capture_cvd_start = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(capture_cvd_start)
assert isinstance(capture_cvd_start, ModuleType)


def test_parse_log_listing_keeps_only_selected_absolute_paths() -> None:
    listing = "\n".join(
        (
            "apkrun_default_test:1:kernel.log /private/cvd/instances/cvd-1/kernel.log",
            "launcher.log /private/cvd/instances/cvd-1/launcher.log",
            "assemble_cvd.log /private/cvd/instances/cvd-1/assemble_cvd.log",
            "unknown.log /private/cvd/instances/cvd-1/unknown.log",
            "kernel.log relative/kernel.log",
            "There are no log files available",
        )
    )

    assert capture_cvd_start.parse_log_listing(listing) == {
        "kernel.log": Path("/private/cvd/instances/cvd-1/kernel.log"),
        "launcher.log": Path("/private/cvd/instances/cvd-1/launcher.log"),
        "assemble_cvd.log": Path("/private/cvd/instances/cvd-1/assemble_cvd.log"),
    }


def test_parse_log_listing_preserves_spaces_in_paths() -> None:
    listing = "kernel.log /private/cvd logs/instances/cvd-1/kernel.log"

    assert capture_cvd_start.parse_log_listing(listing) == {
        "kernel.log": Path("/private/cvd logs/instances/cvd-1/kernel.log")
    }


def test_snapshot_log_is_bounded_and_atomic(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    source_directory = home / "cuttlefish_runtime"
    source_directory.mkdir(parents=True)
    source = source_directory / "kernel.log"
    source.write_bytes(b"0123456789" * 20)
    stage = tmp_path / "stage"
    stage.mkdir()
    destination = stage / "kernel.log"
    monkeypatch.setattr(capture_cvd_start, "MAX_LOG_BYTES", 128)

    marker = capture_cvd_start.snapshot_log(source, destination, home.resolve())

    assert marker is not None
    assert destination.read_bytes().startswith(b"[APKRun snapshot truncated;")
    assert destination.read_bytes().endswith(b"0123456789" * 5)
    assert len(destination.read_bytes()) <= 128
    assert list(stage.iterdir()) == [destination]


def test_snapshot_log_rejects_symlink_and_path_outside_private_home(tmp_path: Path) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    outside = tmp_path / "outside.log"
    outside.write_text("must not be captured\n", encoding="utf-8")
    symlink = home / "kernel.log"
    symlink.symlink_to(outside)
    destination = tmp_path / "stage-kernel.log"

    assert capture_cvd_start.snapshot_log(symlink, destination, home.resolve()) is None
    assert capture_cvd_start.snapshot_log(outside, destination, home.resolve()) is None
    assert not destination.exists()


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires POSIX FIFOs")
def test_snapshot_log_does_not_block_opening_a_fifo(tmp_path: Path) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    fifo = home / "kernel.log"
    os.mkfifo(fifo)
    destination = tmp_path / "stage-kernel.log"

    assert capture_cvd_start.snapshot_log(fifo, destination, home.resolve()) is None
    assert not destination.exists()


def test_snapshot_log_rejects_early_eof_and_keeps_the_last_complete_copy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    source = home / "kernel.log"
    source.write_bytes(b"short")
    destination = tmp_path / "stage-kernel.log"
    destination.write_bytes(b"last complete snapshot")
    fake_stat = SimpleNamespace(
        st_mode=capture_cvd_start.stat.S_IFREG,
        st_size=10,
        st_mtime_ns=1,
    )
    monkeypatch.setattr(capture_cvd_start.os, "fstat", lambda _descriptor: fake_stat)

    assert capture_cvd_start.snapshot_log(source, destination, home.resolve()) is None
    assert destination.read_bytes() == b"last complete snapshot"


def test_snapshot_mode_keeps_existing_snapshot_when_source_is_rejected(
    tmp_path: Path,
) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    stage = tmp_path / "stage"
    stage.mkdir()
    destination = stage / "kernel.log"
    destination.write_text("last live snapshot\n", encoding="utf-8")
    outside = tmp_path / "outside.log"
    outside.write_text("outside private HOME\n", encoding="utf-8")
    arguments = argparse.Namespace(
        home=str(home),
        stage=str(stage),
        snapshot_source=str(outside),
        snapshot_name="kernel.log",
        timeout_seconds=None,
        command=[],
    )

    assert capture_cvd_start.run(arguments) == 1
    assert destination.read_text(encoding="utf-8") == "last live snapshot\n"


def test_snapshot_mode_applies_the_log_size_limit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    source_directory = home / "cuttlefish_runtime"
    source_directory.mkdir(parents=True)
    source = source_directory / "kernel.log"
    source.write_bytes(b"x" * 256)
    stage = tmp_path / "stage"
    stage.mkdir()
    arguments = argparse.Namespace(
        home=str(home),
        stage=str(stage),
        snapshot_source=str(source),
        snapshot_name="kernel.log",
        timeout_seconds=None,
        command=[],
    )
    monkeypatch.setattr(capture_cvd_start, "MAX_LOG_BYTES", 128)

    assert capture_cvd_start.run(arguments) == 0
    contents = (stage / "kernel.log").read_bytes()
    assert len(contents) <= 128
    assert contents.endswith(
        b"x"
        * (128 - len(b"[APKRun snapshot truncated; showing the final part of the host log.]\n"))
    )


def test_collect_logs_snapshots_a_log_before_the_listing_command_exits(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    log_directory = home / "cuttlefish_runtime"
    log_directory.mkdir(parents=True)
    source = log_directory / "kernel.log"
    source.write_text("captured before deletion\n", encoding="utf-8")
    outside = tmp_path / "outside-kernel.log"
    outside.write_text("must not be captured\n", encoding="utf-8")
    stage = tmp_path / "stage"
    stage.mkdir()
    snapshots = stage / ".live-cvd-logs"
    snapshots.mkdir()
    fake_cvd = tmp_path / "cvd"
    fake_cvd.write_text(
        "#!/bin/sh\n"
        "printf 'apkrun_default_test:1:kernel.log %s\\n' \"$APKRUN_TEST_OUTSIDE_LOG_SOURCE\"\n"
        "printf 'apkrun_default_test:1:kernel.log %s\\n' \"$APKRUN_TEST_LOG_SOURCE\"\n"
        "printf 'apkrun_default_test:1:kernel.log %s\\n' \"$APKRUN_TEST_LOG_SOURCE\"\n"
        "sleep 0.2\n"
        'rm -f "$APKRUN_TEST_LOG_SOURCE"\n',
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)
    monkeypatch.setenv("APKRUN_TEST_LOG_SOURCE", str(source))
    monkeypatch.setenv("APKRUN_TEST_OUTSIDE_LOG_SOURCE", str(outside))
    observed: dict[tuple[str, str], tuple[int, int]] = {}
    original_snapshot_log = capture_cvd_start.snapshot_log
    snapshot_calls = 0

    def count_snapshot_calls(
        source_path: Path,
        destination_path: Path,
        home_path: Path,
    ) -> tuple[int, int] | None:
        nonlocal snapshot_calls
        snapshot_calls += 1
        return original_snapshot_log(source_path, destination_path, home_path)

    monkeypatch.setattr(capture_cvd_start, "snapshot_log", count_snapshot_calls)

    capture_cvd_start.collect_logs(
        str(fake_cvd),
        home.resolve(),
        snapshots,
        observed,
        timeout_seconds=3.0,
    )

    assert not source.exists()
    assert snapshot_calls == 1
    assert (snapshots / "kernel.log").read_text(encoding="utf-8") == ("captured before deletion\n")
    assert ("kernel.log", str(source)) in observed


def test_collect_logs_keeps_snapshot_when_listing_times_out_after_source_deletion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    log_directory = home / "cuttlefish_runtime"
    log_directory.mkdir(parents=True)
    source = log_directory / "kernel.log"
    source.write_text("captured before timeout\n", encoding="utf-8")
    stage = tmp_path / "stage"
    stage.mkdir()
    snapshots = stage / ".live-cvd-logs"
    snapshots.mkdir()
    fake_cvd = tmp_path / "cvd"
    fake_cvd.write_text(
        "#!/bin/sh\n"
        "printf 'apkrun_default_test:1:kernel.log %s\\n' \"$APKRUN_TEST_LOG_SOURCE\"\n"
        "sleep 0.1\n"
        'rm -f "$APKRUN_TEST_LOG_SOURCE"\n'
        "trap '' TERM\n"
        "while :; do sleep 1; done\n",
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)
    monkeypatch.setenv("APKRUN_TEST_LOG_SOURCE", str(source))
    observed: dict[tuple[str, str], tuple[int, int]] = {}

    capture_cvd_start.collect_logs(
        str(fake_cvd),
        home.resolve(),
        snapshots,
        observed,
        timeout_seconds=3.0,
    )

    assert not source.exists()
    assert (snapshots / "kernel.log").read_text(encoding="utf-8") == ("captured before timeout\n")
    assert observed == {}


def test_collect_logs_bounds_listing_output_and_terminates_the_process_group(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    stage = tmp_path / "stage"
    stage.mkdir()
    snapshots = stage / ".live-cvd-logs"
    snapshots.mkdir()
    fake_cvd = tmp_path / "cvd"
    pid_file = tmp_path / "cvd.pid"
    fake_cvd.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$$\" > {str(pid_file)!r}\n"
        "printf 'oversized listing payload that never ends\\n'\n"
        "trap '' TERM\n"
        "while :; do sleep 1; done\n",
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)
    monkeypatch.setattr(capture_cvd_start, "MAX_LOG_LISTING_BYTES", 16)
    observed: dict[tuple[str, str], tuple[int, int]] = {}

    capture_cvd_start.collect_logs(
        str(fake_cvd),
        home.resolve(),
        snapshots,
        observed,
        timeout_seconds=3.0,
    )

    assert list(snapshots.iterdir()) == []
    assert observed == {}
    with pytest.raises(ProcessLookupError):
        os.kill(int(pid_file.read_text(encoding="utf-8")), 0)


def test_collect_logs_kills_descendants_after_a_failed_listing_closes_stdout(
    tmp_path: Path,
) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    stage = tmp_path / "stage"
    stage.mkdir()
    snapshots = stage / ".live-cvd-logs"
    snapshots.mkdir()
    child_script = tmp_path / "descendant.py"
    child_pid_file = tmp_path / "descendant.pid"
    child_script.write_text(
        "import os, signal, time\n"
        "from pathlib import Path\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        f"Path({str(child_pid_file)!r}).write_text(str(os.getpid()))\n"
        "while True: time.sleep(1)\n",
        encoding="utf-8",
    )
    fake_cvd = tmp_path / "cvd"
    fake_cvd.write_text(
        "#!/bin/sh\n"
        f"python3 {shlex.quote(str(child_script))} >/dev/null 2>&1 &\n"
        f"while [ ! -f {shlex.quote(str(child_pid_file))} ]; do sleep 0.01; done\n"
        "printf '\\377\\n'\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_cvd.chmod(0o755)

    capture_cvd_start.collect_logs(
        str(fake_cvd),
        home.resolve(),
        snapshots,
        {},
        timeout_seconds=1.0,
    )

    assert child_pid_file.exists()
    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    process_deadline = time.monotonic() + 5
    while time.monotonic() < process_deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        process_state = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(child_pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if process_state.startswith("Z"):
            break
        time.sleep(0.02)
    else:
        pytest.fail("the failed listing left a live descendant behind")


def test_terminate_log_command_does_not_signal_a_reaped_process_group(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = subprocess.Popen([sys.executable, "-c", "pass"])
    process.wait()
    signaled_groups: list[tuple[int, int]] = []
    monkeypatch.setattr(
        capture_cvd_start.os,
        "killpg",
        lambda group, number: signaled_groups.append((group, number)),
    )

    capture_cvd_start._terminate_log_command(process)

    assert signaled_groups == []


def test_terminate_child_kills_grandchildren_after_leader_exits_on_term(
    tmp_path: Path,
) -> None:
    grandchild_script = tmp_path / "grandchild.py"
    grandchild_pid_file = tmp_path / "grandchild.pid"
    grandchild_script.write_text(
        "import os, signal, time\n"
        "from pathlib import Path\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        f"Path({str(grandchild_pid_file)!r}).write_text(str(os.getpid()))\n"
        "while True: time.sleep(1)\n",
        encoding="utf-8",
    )
    parent_script = tmp_path / "parent.py"
    parent_script.write_text(
        "import signal, subprocess, sys, time\n"
        "subprocess.Popen([sys.executable, sys.argv[1]])\n"
        "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
        "while True: time.sleep(1)\n",
        encoding="utf-8",
    )
    process = subprocess.Popen(
        [sys.executable, str(parent_script), str(grandchild_script)],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    pid_deadline = time.monotonic() + 5
    while not grandchild_pid_file.exists() and time.monotonic() < pid_deadline:
        time.sleep(0.02)
    assert grandchild_pid_file.exists()
    grandchild_pid = int(grandchild_pid_file.read_text(encoding="utf-8"))

    capture_cvd_start._terminate_child(process)

    assert process.poll() is not None
    process_deadline = time.monotonic() + 5
    while time.monotonic() < process_deadline:
        try:
            os.kill(grandchild_pid, 0)
        except ProcessLookupError:
            break
        status_file = Path(f"/proc/{grandchild_pid}/stat")
        if status_file.exists():
            state = status_file.read_text(encoding="utf-8").rsplit(")", maxsplit=1)[1].split()[0]
            if state == "Z":
                break
        status = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(grandchild_pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if status.startswith("Z"):
            break
        time.sleep(0.02)
    else:
        pytest.fail("the Cuttlefish process group left a live descendant after shutdown")


def test_invalid_log_listing_does_not_leave_cvd_child_running(tmp_path: Path) -> None:
    home = tmp_path / "private-home"
    home.mkdir()
    stage = tmp_path / "stage"
    stage.mkdir()
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_cvd = fake_bin / "cvd"
    fake_cvd.write_text("#!/bin/sh\nprintf '\\377\\n'\n", encoding="utf-8")
    fake_cvd.chmod(0o755)
    pid_file = tmp_path / "child.pid"
    child_script = tmp_path / "child.py"
    child_script.write_text(
        "import os, time\n"
        "from pathlib import Path\n"
        f"Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
        "while True: time.sleep(1)\n",
        encoding="utf-8",
    )
    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
    environment["HOME"] = str(home)
    command = [
        sys.executable,
        str(HELPER_PATH),
        "--home",
        str(home),
        "--stage",
        str(stage),
        "--timeout-seconds",
        "0.1",
        "--",
        sys.executable,
        str(child_script),
    ]

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
        check=False,
    )

    assert result.returncode == 124
    assert pid_file.exists()
    child_pid = int(pid_file.read_text(encoding="utf-8"))
    with pytest.raises(ProcessLookupError):
        os.kill(child_pid, 0)
