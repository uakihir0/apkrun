from __future__ import annotations

import importlib.util
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

REFERENCE_PATH = Path(__file__).parents[1] / "reference"
OBSERVER_SPEC = importlib.util.spec_from_file_location(
    "boot_observer",
    REFERENCE_PATH / "boot_observer.py",
)
assert OBSERVER_SPEC is not None
assert OBSERVER_SPEC.loader is not None
OBSERVER_MODULE = importlib.util.module_from_spec(OBSERVER_SPEC)
OBSERVER_SPEC.loader.exec_module(OBSERVER_MODULE)
BootObserver = OBSERVER_MODULE.BootObserver


def _fake_proc_process(
    proc_root: Path,
    pid: int,
    executable: Path,
    *,
    process_name: str = "crosvm",
    start_time: int = 12345,
    instance_path: Path | None = None,
) -> None:
    process = proc_root / str(pid)
    process.mkdir(parents=True)
    (process / "exe").symlink_to(executable)
    command_line = [
        b"crosvm",
        f"--process_name={process_name}".encode("ascii"),
    ]
    if instance_path is not None:
        command_line.append(f"--socket={instance_path}/internal/vsock.sock".encode())
    (process / "cmdline").write_bytes(b"\0".join(command_line) + b"\0")
    (process / "stat").write_bytes(
        f"{pid} (crosvm worker) S ".encode("ascii") + b"0 " * 18 + f"{start_time}\n".encode("ascii")
    )
    (process / "status").write_bytes(b"Name:\tcrosvm\nVmRSS:\t987654 kB\nRssShmem:\t1234 kB\n")


def _observer(
    tmp_path: Path,
    *,
    proc_root: Path,
    home_path: Path | None = None,
    sample_interval: float = 5.0,
    adb_interval: float = 15.0,
    background_sampling: bool = False,
) -> tuple[BootObserver, Path, Path]:
    home = home_path or tmp_path / "cvd-home"
    home.mkdir(mode=0o700, exist_ok=True)
    stage = tmp_path / "stage"
    log_directory = stage / ".live-cvd-logs"
    log_directory.mkdir(parents=True, mode=0o700)
    crosvm = tmp_path / "crosvm"
    crosvm.write_bytes(b"test crosvm executable")
    crosvm.chmod(0o700)
    adb = tmp_path / "adb"
    adb.write_bytes(b"test adb executable")
    adb.chmod(0o700)
    output = stage / "boot-observer.jsonl"
    observer = BootObserver(
        home=home,
        instance_path=home / "cuttlefish_runtime" / "instances" / "cvd-1",
        launcher_log=log_directory / "launcher.log",
        output_path=output,
        adb_path=adb,
        adb_port=6520,
        crosvm_path=crosvm,
        proc_root=proc_root,
        sample_interval=sample_interval,
        adb_interval=adb_interval,
        background_sampling=background_sampling,
    )
    return observer, output, log_directory / "launcher.log"


@pytest.fixture
def short_private_home() -> Iterator[Path]:
    root = Path(tempfile.mkdtemp(prefix="apkrun-observer-test.", dir="/tmp"))
    home = root / "cvd-home"
    home.mkdir(mode=0o700)
    try:
        yield home
    finally:
        shutil.rmtree(root, ignore_errors=True)


def _read_records(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="ascii").splitlines() if line]


def test_boot_observer_samples_only_the_launcher_identified_android_crosvm(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        412,
        executable,
        process_name="openwrt",
        instance_path=observer.instance_path,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(
        b"Started (pid: 412): /private/crosvm\n"
        b"--process_name=openwrt\n"
        b"Started (pid: 413): /private/crosvm\n"
        b"--process_name=crosvm\n"
    )

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["pid"] == 413
    assert memory[0]["vmRssKiB"] == 987654
    assert memory[0]["rssShmemKiB"] == 1234
    assert isinstance(memory[0]["timestampUtc"], str)
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert "private/crosvm" not in output.read_text(encoding="ascii")


def test_boot_observer_rejects_reused_launcher_pid_between_samples(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    process = proc_root / "413"
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(b"Started (pid: 413): /private/crosvm\n--process_name=crosvm\n")

    observer.start()
    observer.sample(now=0)
    (process / "stat").write_bytes(b"413 (crosvm worker) S " + b"0 " * 18 + b"54321\n")
    observer.sample(now=2)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 2
    assert memory[0]["pid"] == 413
    assert memory[0]["vmRssKiB"] == 987654
    assert memory[1]["identity"] == "unavailable"
    assert memory[1]["candidateCount"] == 0


def test_boot_observer_rejects_same_name_crosvm_from_another_private_instance(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    other_instance = tmp_path / "other-cvd-home" / "cuttlefish_runtime" / "instances" / "cvd-1"
    _fake_proc_process(
        proc_root,
        414,
        executable,
        instance_path=other_instance,
    )
    launcher_log.write_bytes(b"Started (pid: 414): /private/crosvm\n--process_name=crosvm\n")

    observer.start()
    observer.sample(now=0)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["identity"] == "unavailable"
    assert memory[0]["candidateCount"] == 0


def test_boot_observer_clears_crosvm_identity_after_launcher_log_truncation(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        415,
        executable,
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(
        b"Started (pid: 415): /private/crosvm\n--process_name=crosvm\nStart event (5) received.\n"
    )

    observer.start()
    observer.sample(now=0)
    launcher_log.write_bytes(
        OBSERVER_MODULE.SNAPSHOT_TRUNCATION_MARKER + b"retained launcher tail\n"
    )
    observer.sample(now=2)
    observer.close()

    records = _read_records(output)
    gaps = [
        record for record in records if record["event"] == "launcher_log_truncated_observation_gap"
    ]
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(gaps) == 1
    assert gaps[0]["discardedCandidateCount"] == 1
    assert memory[0]["pid"] == 415
    assert memory[1]["identity"] == "unavailable"


@pytest.mark.parametrize("ignore_server_terminate", (False, True))
def test_boot_observer_uses_private_adb_socket_after_start_event_and_cleans_up(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    ignore_server_terminate: bool,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
        sample_interval=0.02,
        adb_interval=1.5,
    )
    home = observer.home
    server_ready = tmp_path / "adb-server-ready"
    server_stopped = tmp_path / "adb-server-stopped"
    server_socket_file = tmp_path / "adb-server-socket"
    calls = tmp_path / "adb-calls.jsonl"
    fake_adb = tmp_path / "fake-adb"
    termination_handler = "signal.SIG_IGN" if ignore_server_terminate else "stop"
    fake_adb.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, signal, socket, sys, time\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "call_log = Path(os.environ['FAKE_ADB_CALLS'])\n"
        "if args[-2:] == ['nodaemon', 'server']:\n"
        "    endpoint = args[args.index('-L') + 1]\n"
        "    socket_path = endpoint.removeprefix('localfilesystem:')\n"
        "    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
        "    listener.bind(socket_path)\n"
        "    listener.listen(8)\n"
        "    listener.settimeout(0.05)\n"
        f"    Path({str(server_ready)!r}).write_text('ready', encoding='ascii')\n"
        f"    Path({str(server_socket_file)!r}).write_text(socket_path, encoding='ascii')\n"
        "    running = True\n"
        "    def stop(_signum, _frame):\n"
        "        global running\n"
        "        running = False\n"
        f"    signal.signal(signal.SIGTERM, {termination_handler})\n"
        "    while running:\n"
        "        try:\n"
        "            connection, _ = listener.accept()\n"
        "        except socket.timeout:\n"
        "            continue\n"
        "        connection.close()\n"
        "    listener.close()\n"
        "    Path(socket_path).unlink(missing_ok=True)\n"
        f"    Path({str(server_stopped)!r}).write_text('stopped', encoding='ascii')\n"
        "    raise SystemExit(0)\n"
        "with call_log.open('a', encoding='utf-8') as stream:\n"
        "    stream.write(json.dumps({'args': args, "
        "'ambientSocket': os.environ.get('ADB_SERVER_SOCKET'), "
        "'ambientVendorKeys': os.environ.get('ADB_VENDOR_KEYS'), "
        "'wallTime': time.time()}) + '\\n')\n"
        "endpoint = args[args.index('-L') + 1].removeprefix('localfilesystem:')\n"
        "probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
        "probe.connect(endpoint)\n"
        "probe.close()\n"
        "time.sleep(float(os.environ.get('FAKE_ADB_CLIENT_DELAY', '0')))\n"
        "if 'connect' in args:\n"
        "    raise SystemExit(0)\n"
        "if args[-1:] == ['get-state']:\n"
        "    print('device')\n"
        "    raise SystemExit(0)\n"
        "if args[-2:] == ['getprop', 'sys.boot_completed']:\n"
        "    print('1')\n"
        "    raise SystemExit(0)\n"
        "raise SystemExit(19)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)
    observer.adb_path = fake_adb.resolve(strict=True)
    monkeypatch.setenv("FAKE_ADB_CALLS", str(calls))
    monkeypatch.setenv("FAKE_ADB_IGNORE_TERMINATE", "1" if ignore_server_terminate else "0")
    monkeypatch.setenv("FAKE_ADB_CLIENT_DELAY", "0.2")
    monkeypatch.setenv("ADB_SERVER_SOCKET", "tcp:localhost:5037")
    monkeypatch.setenv("ADB_VENDOR_KEYS", "/private/host/adbkey")
    launcher_log.write_bytes(b"Start event (5) received. Starting proxy\n")

    observer.start()
    observer.sample(now=0)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        records = _read_records(output)
        polls = [record for record in records if record["event"] == "adb_poll"]
        if len(polls) >= 2 and polls[-1]["sysBootCompleted"] is True:
            break
        time.sleep(0.02)
    observer.close()

    records = _read_records(output)
    assert any(record["event"] == "cuttlefish_start_event_5_observed" for record in records)
    assert any(
        record["event"] == "adb_poll"
        and record["deviceState"] == "device"
        and record["sysBootCompleted"] is True
        for record in records
    )
    assert any(record["event"] == "private_adb_server_ready" for record in records)
    assert any(
        record["event"] == "private_adb_server_stopped" and record["cleanupComplete"] is True
        for record in records
    )
    assert server_ready.read_text(encoding="ascii") == "ready"
    if ignore_server_terminate:
        assert not server_stopped.exists()
    else:
        assert server_stopped.read_text(encoding="ascii") == "stopped"
    assert not Path(server_socket_file.read_text(encoding="ascii")).exists()
    assert not any(path.name.startswith("apkrun-boot-adb.") for path in home.iterdir())
    logged_calls = [json.loads(line) for line in calls.read_text().splitlines()]
    assert logged_calls
    connect_times = [call["wallTime"] for call in logged_calls if "connect" in call["args"]]
    assert len(connect_times) >= 2
    assert 1.2 <= connect_times[1] - connect_times[0] < 2.1
    assert all(
        call["args"][call["args"].index("-L") + 1].startswith("localfilesystem:")
        for call in logged_calls
    )
    assert all(call["ambientSocket"] is None for call in logged_calls)
    assert all(call["ambientVendorKeys"] is None for call in logged_calls)
    assert str(home) not in output.read_text(encoding="ascii")


@pytest.mark.skipif(sys.platform != "linux", reason="requires Linux parent-death signals")
def test_private_adb_server_exits_when_observer_parent_is_killed(
    tmp_path: Path,
    short_private_home: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    home = observer.home
    server_ready = tmp_path / "adb-server-ready"
    server_pid_file = tmp_path / "adb-server-pid"
    socket_path_file = tmp_path / "adb-server-socket"
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\n"
        "import os, signal, socket, sys, time\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "endpoint = args[args.index('-L') + 1]\n"
        "socket_path = endpoint.removeprefix('localfilesystem:')\n"
        "listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
        "listener.bind(socket_path)\n"
        "listener.listen(8)\n"
        "listener.settimeout(0.05)\n"
        f"Path({str(server_pid_file)!r}).write_text(str(os.getpid()), encoding='ascii')\n"
        f"Path({str(server_ready)!r}).write_text('ready', encoding='ascii')\n"
        f"Path({str(socket_path_file)!r}).write_text(socket_path, encoding='ascii')\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "while True:\n"
        "    try:\n"
        "        connection, _ = listener.accept()\n"
        "    except socket.timeout:\n"
        "        continue\n"
        "    connection.close()\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)
    observer.adb_path = fake_adb.resolve(strict=True)
    launcher_log.write_bytes(b"Start event (5) received.\n")
    child_script = (
        "import runpy, sys, time\n"
        "from pathlib import Path\n"
        "values = runpy.run_path(sys.argv[1])\n"
        "Observer = values['BootObserver']\n"
        "observer = Observer(\n"
        "    home=Path(sys.argv[2]),\n"
        "    instance_path=Path(sys.argv[3]),\n"
        "    launcher_log=Path(sys.argv[4]),\n"
        "    output_path=Path(sys.argv[5]),\n"
        "    adb_path=Path(sys.argv[6]),\n"
        "    adb_port=6520,\n"
        "    crosvm_path=Path(sys.argv[7]),\n"
        "    proc_root=Path(sys.argv[8]),\n"
        ")\n"
        "observer.start()\n"
        "observer.sample()\n"
        "while True:\n"
        "    time.sleep(0.05)\n"
    )
    parent = subprocess.Popen(
        [
            sys.executable,
            "-c",
            child_script,
            str(REFERENCE_PATH / "boot_observer.py"),
            str(home),
            str(observer.instance_path),
            str(launcher_log),
            str(output),
            str(observer.adb_path),
            str(observer.crosvm_path),
            str(proc_root),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    server_pid: int | None = None
    try:
        deadline = time.monotonic() + 5
        while not server_ready.exists() and time.monotonic() < deadline:
            if parent.poll() is not None:
                pytest.fail("observer parent exited before its private ADB server started")
            time.sleep(0.02)
        assert server_ready.exists(), "private ADB server did not start"
        server_pid = int(server_pid_file.read_text(encoding="ascii"))
        parent.kill()
        parent.wait(timeout=2)

        deadline = time.monotonic() + 5
        server_proc = Path("/proc") / str(server_pid)
        while time.monotonic() < deadline:
            try:
                stat_fields = server_proc.joinpath("stat").read_text(encoding="ascii")
                command_line = server_proc.joinpath("cmdline").read_bytes()
            except OSError:
                break
            state = stat_fields.rsplit(")", 1)[1].split()[0]
            if state in {"Z", "X"} or fake_adb.as_posix().encode() not in command_line:
                break
            time.sleep(0.02)
        else:
            pytest.fail("private ADB server survived its parent SIGKILL")

        socket_path = Path(socket_path_file.read_text(encoding="ascii"))
        assert socket_path.exists(), "SIGKILL unexpectedly ran ADB socket cleanup"
        shutil.rmtree(home)
        assert not socket_path.exists()
        assert not home.exists()
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait(timeout=2)
        if server_pid is None and server_pid_file.exists():
            server_pid = int(server_pid_file.read_text(encoding="ascii"))
        if server_pid is not None:
            try:
                stat_fields = Path("/proc") / str(server_pid) / "stat"
                command_line = Path("/proc") / str(server_pid) / "cmdline"
                state = stat_fields.read_text(encoding="ascii").rsplit(")", 1)[1].split()[0]
                if (
                    state not in {"Z", "X"}
                    and fake_adb.as_posix().encode() in command_line.read_bytes()
                ):
                    os.kill(server_pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(home, ignore_errors=True)


def test_boot_observer_reserves_time_for_adb_cleanup_before_deadline(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(tmp_path, proc_root=proc_root)
    observer.deadline = time.monotonic() + 10
    launcher_log.write_bytes(b"Start event (5) received.\n")

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert any(
        record["event"] == "adb_observer_stopped_before_deadline"
        and record["reason"] == "cleanup_reserve"
        for record in records
    )
    assert not any(record["event"] == "private_adb_server_ready" for record in records)
    assert not any(
        record["event"] == "private_adb_server_stopped" and record["cleanupComplete"] is False
        for record in records
    )


def test_boot_observer_does_not_start_adb_command_after_cleanup_boundary(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "adb-command-ran"
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        "import sys\n"
        f"Path({str(marker)!r}).write_text('ran', encoding='ascii')\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)

    result = BootObserver._run_adb(
        [str(fake_adb), "get-state"],
        {},
        time.monotonic() - 1,
    )

    assert result == (None, "", True)
    assert not marker.exists()


def test_boot_observer_records_private_socket_directory_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(tmp_path, proc_root=proc_root)

    def reject_directory(*_args: object, **_kwargs: object) -> str:
        raise OSError("synthetic /tmp failure")

    monkeypatch.setattr(OBSERVER_MODULE.tempfile, "mkdtemp", reject_directory)
    launcher_log.write_bytes(b"Start event (5) received.\n")

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert any(
        record["event"] == "adb_observer_unavailable"
        and record["reason"] == "private_socket_directory_creation_failed"
        for record in records
    )
    assert records[-1]["event"] == "observer_stopped"


def test_boot_observer_samples_on_a_background_monotonic_schedule(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=0.02,
        background_sampling=True,
    )

    observer.start()
    time.sleep(0.075)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) >= 3
