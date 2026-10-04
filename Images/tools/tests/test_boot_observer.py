from __future__ import annotations

import importlib.util
import json
import os
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
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


@pytest.fixture(autouse=True)
def _cleanup_managed_cvd_test_directories(tmp_path: Path) -> Iterator[None]:
    yield
    marker = tmp_path / ".apkrun-cvd-test-runs"
    if not marker.exists():
        return
    managed_root = Path("/var/tmp/cvd")
    for line in marker.read_text(encoding="utf-8").splitlines():
        run_root = Path(line)
        if run_root.parent.parent == managed_root and run_root.parent.name == str(os.getuid()):
            shutil.rmtree(run_root, ignore_errors=True)


def _managed_instance_path(
    tmp_path: Path,
    name: str = "cvd-1",
    *,
    home_path: Path | None = None,
) -> Path:
    managed_root = Path("/var/tmp/cvd")
    user_root = managed_root / str(os.getuid())
    user_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    run_root = Path(tempfile.mkdtemp(prefix="apkrun-observer.", dir=user_root))
    private_home = home_path or tmp_path / "cvd-home"
    private_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    (run_root / "home").symlink_to(private_home, target_is_directory=True)
    canonical_instance = private_home / "cuttlefish" / "instances" / name
    canonical_instance.mkdir(parents=True, exist_ok=True)
    marker = tmp_path / ".apkrun-cvd-test-runs"
    with marker.open("a", encoding="utf-8") as stream:
        stream.write(f"{run_root}\n")
    return run_root / "home" / "cuttlefish" / "instances" / name


def _fake_proc_process(
    proc_root: Path,
    pid: int,
    executable: Path,
    *,
    process_name: str | None = None,
    start_time: int = 12345,
    parent_pid: int = 0,
    instance_path: Path | None = None,
    staged_crosvm_target: Path | None = None,
    staged_crosvm_name: str = "crosvm",
    command_line_executable: Path | None = None,
) -> None:
    process = proc_root / str(pid)
    process.mkdir(parents=True)
    runtime_executable = executable
    if instance_path is not None:
        runtime_executable = (
            instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / staged_crosvm_name
        )
        runtime_executable.parent.mkdir(parents=True, exist_ok=True)
        if not runtime_executable.exists():
            runtime_executable.symlink_to((staged_crosvm_target or executable).resolve(strict=True))
    (process / "exe").symlink_to(executable.resolve(strict=True))
    command_line = [os.fsencode(command_line_executable or runtime_executable)]
    if process_name is not None:
        command_line.append(f"--process_name={process_name}".encode("ascii"))
    if instance_path is not None:
        command_line.append(f"--socket={instance_path}/internal/vsock.sock".encode())
    (process / "cmdline").write_bytes(b"\0".join(command_line) + b"\0")
    (process / "stat").write_bytes(
        f"{pid} (crosvm worker) S {parent_pid} ".encode("ascii")
        + b"0 " * 17
        + f"{start_time}\n".encode("ascii")
    )
    (process / "status").write_bytes(b"Name:\tcrosvm\nVmRSS:\t987654 kB\nRssShmem:\t1234 kB\n")


def _fake_proc_restarter(
    proc_root: Path,
    pid: int,
    executable: Path,
    *,
    children: tuple[int, ...],
    instance_path: Path,
    android: bool = True,
    requested_crosvm_name: str = "crosvm",
) -> None:
    process = proc_root / str(pid)
    process.mkdir(parents=True)
    (process / "exe").symlink_to(executable)
    crosvm_executable = (
        instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / requested_crosvm_name
    )
    serial = (
        (
            "hardware=virtio-console,num=1,type=file,"
            f"path={instance_path}/internal/kernel-log-pipe,console=true"
        ).encode()
        if android
        else f"hardware=serial,path={instance_path}/logs/crosvm_openwrt.log".encode()
    )
    (process / "cmdline").write_bytes(
        b"process_restarter\0"
        + f"--block=path={instance_path}/disk.img".encode()
        + b"\0--\0"
        + os.fsencode(crosvm_executable)
        + b"\0--extended-status\0run\0--serial\0"
        + serial
        + b"\0"
    )
    (process / "stat").write_bytes(
        f"{pid} (process_restarter) S ".encode("ascii") + b"0 " * 18 + b"12345\n"
    )
    task = process / "task" / str(pid)
    task.mkdir(parents=True)
    (task / "children").write_text(
        " ".join(str(child) for child in children),
        encoding="ascii",
    )


def _write_crosvm_launcher_identity(launcher_log: Path, restarter_pid: int) -> None:
    launcher_log.write_bytes(
        b"run_cvd(500)  D Started (pid: 499): /private/cuttlefish home/log_tee\n"
        b"run_cvd(500)  D --process_name=crosvm\n"
        + f"process_restarter({restarter_pid})  D Starting Android crosvm\n".encode("ascii")
    )


def _observer(
    tmp_path: Path,
    *,
    proc_root: Path,
    home_path: Path | None = None,
    runtime_target: Path | None = None,
    runtime_link_ready: bool = True,
    sample_interval: float = 5.0,
    adb_interval: float = 15.0,
    background_sampling: bool = False,
    crosvm_path: Path | None = None,
    crosvm_executable_path: Path | None = None,
) -> tuple[BootObserver, Path, Path]:
    home = home_path or tmp_path / "cvd-home"
    home.mkdir(mode=0o700, exist_ok=True)
    instance_path = runtime_target or _managed_instance_path(tmp_path, home_path=home)
    instance_path.mkdir(parents=True, exist_ok=True)
    instance_path_link = home / "cuttlefish_runtime"
    if runtime_link_ready:
        instance_path_link.symlink_to(instance_path)
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
        instance_path=instance_path_link,
        launcher_log=log_directory / "launcher.log",
        kernel_log=log_directory / "kernel.log",
        output_path=output,
        adb_path=adb,
        adb_port=6520,
        crosvm_path=crosvm if crosvm_path is None else crosvm_path,
        crosvm_executable_path=crosvm_executable_path,
        proc_root=proc_root,
        sample_interval=sample_interval,
        adb_interval=adb_interval,
        background_sampling=background_sampling,
    )
    return observer, output, log_directory / "launcher.log"


def _promote_kernel_log_snapshot(
    observer: BootObserver,
    kernel_log: Path,
    content: bytes,
    marker: tuple[int, int, int, int],
) -> None:
    pending_snapshot = kernel_log.with_name(".kernel.log.pending")
    pending_snapshot.write_bytes(content)
    observer.promote_kernel_log_snapshot(pending_snapshot, kernel_log, marker)


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


def test_blocked_system_server_mprotect_trace_is_recognized_from_bounded_log_tail() -> None:
    blocked_trace = (
        b"[ 3247.399947][ T4408] task:system_server   state:D stack:0 pid:4364 tgid:4364\n"
        b"[ 3247.453943][ T4408] Call trace:\n"
        b"[ 3247.499170][ T4408]  __switch_to+0x144/0x2bc\n"
        b"[ 3247.560638][ T4408]  rwsem_down_write_slowpath+0x3b8/0xa28\n"
        b"[ 3247.562507][ T4408]  do_mprotect_pkey+0xd8/0x624\n"
    )
    assert OBSERVER_MODULE.find_blocked_system_server_mprotect_uptime(blocked_trace) == 3247.399947
    assert (
        OBSERVER_MODULE.find_blocked_system_server_mprotect_uptime(
            blocked_trace.replace(b"state:D", b"state:S")
        )
        is None
    )
    assert (
        OBSERVER_MODULE.find_blocked_system_server_mprotect_uptime(
            blocked_trace.replace(b"do_mprotect_pkey", b"do_mmap")
        )
        is None
    )
    assert (
        OBSERVER_MODULE.find_blocked_system_server_mprotect_uptime(
            b"[ 1.000000][ T1] task:other state:D pid:2\n"
            b"[ 1.100000][ T1] do_mprotect_pkey+0x10/0x20\n"
        )
        is None
    )


def test_system_server_thread_snapshot_parser_strips_identifiers_and_addresses() -> None:
    output = (
        b"P\n"
        b"T\tD\trwsem_down_write_slowpath\n"
        b"F\t[<ffff000012345678>] do_mprotect_pkey+0xd8/0x624\n"
        b"F\t[<ffff000087654321>] down_write_killable+0x94/0x180\n"
        b"E\n"
        b"T\tS\tep_poll\n"
        b"F\t[<0>] do_epoll_wait+0x40/0x80\n"
        b"E\n"
    )
    parsed = OBSERVER_MODULE.parse_system_server_thread_snapshot(output)
    assert parsed == {
        "processCount": 1,
        "threadCount": 2,
        "stateCounts": {"D": 1, "S": 1},
        "threads": [
            {
                "state": "D",
                "waitChannel": "rwsem_down_write_slowpath",
                "kernelFrames": ["do_mprotect_pkey", "down_write_killable"],
            },
            {
                "state": "S",
                "waitChannel": "ep_poll",
                "kernelFrames": ["do_epoll_wait"],
            },
        ],
    }
    serialized = json.dumps(parsed, sort_keys=True)
    assert "4364" not in serialized
    assert "ffff0000" not in serialized


def test_system_server_thread_shell_script_is_valid_shell() -> None:
    result = subprocess.run(
        ["sh", "-n", "-c", OBSERVER_MODULE.SYSTEM_SERVER_THREAD_SHELL_SCRIPT],
        capture_output=True,
        check=False,
        timeout=3,
    )
    assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")


def test_adb_shell_probe_command_is_valid_shell() -> None:
    result = subprocess.run(
        ["sh", "-n", "-c", OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND],
        capture_output=True,
        check=False,
        timeout=3,
    )
    assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")


@pytest.mark.parametrize(
    (
        "check_output",
        "check_status",
        "list_output",
        "list_status",
        "pidof_output",
        "pidof_status",
        "expected",
    ),
    (
        (
            "Service activity: found\n",
            0,
            "Found 2 services:\n"
            "0 activity: [android.app.IActivityManager]\n"
            "1 package: [android.content.pm.IPackageManager]\n",
            0,
            "593\n",
            0,
            ("found", "found", "present"),
        ),
        (
            "Service activity: not found\n",
            0,
            "Found 1 services:\n0 package: [android.content.pm.IPackageManager]\n",
            0,
            "",
            1,
            ("notFound", "notFound", "notPresent"),
        ),
        (
            "Malformed activity was found somewhere\n",
            0,
            "malformed service listing\n",
            0,
            "",
            127,
            ("unknown", "unknown", "unknown"),
        ),
        (
            "Service activity: not found\n",
            0,
            "Found 1 services:\n0 package: garbage\n",
            0,
            "",
            1,
            ("notFound", "unknown", "notPresent"),
        ),
        (
            "Service activity: not found\n",
            0,
            "Found 1 services:\n0 activity: garbage\n",
            0,
            "",
            1,
            ("notFound", "unknown", "notPresent"),
        ),
        (
            "Service activity: not found\n",
            0,
            "Found 1 services:\n0 activity: []\n",
            0,
            "",
            1,
            ("notFound", "unknown", "notPresent"),
        ),
        (
            "Service activity: not found\n",
            0,
            "",
            0,
            "",
            1,
            ("notFound", "unknown", "notPresent"),
        ),
        (
            "Service activity: found\n",
            0,
            "Found 2 services:\n0 activity: [android.app.IActivityManager]\n",
            0,
            "",
            1,
            ("found", "unknown", "notPresent"),
        ),
    ),
)
def test_adb_shell_probe_command_keeps_only_allowlisted_diagnostics(
    tmp_path: Path,
    check_output: str,
    check_status: int,
    list_output: str,
    list_status: int,
    pidof_output: str,
    pidof_status: int,
    expected: tuple[str, str, str],
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    service = fake_bin / "service"
    service.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "if sys.argv[1:3] == ['check', 'activity']:\n"
        "    key = 'FAKE_CHECK'\n"
        "    status_key = 'FAKE_CHECK_STATUS'\n"
        "elif sys.argv[1:] == ['list']:\n"
        "    key = 'FAKE_LIST'\n"
        "    status_key = 'FAKE_LIST_STATUS'\n"
        "else:\n"
        "    raise SystemExit(64)\n"
        "sys.stdout.write(os.environ[key])\n"
        "raise SystemExit(int(os.environ[status_key]))\n",
        encoding="ascii",
    )
    service.chmod(0o700)
    pidof = fake_bin / "pidof"
    pidof.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "sys.stdout.write(os.environ['FAKE_PIDOF'])\n"
        "raise SystemExit(int(os.environ['FAKE_PIDOF_STATUS']))\n",
        encoding="ascii",
    )
    pidof.chmod(0o700)
    environment = os.environ.copy()
    environment["PATH"] = str(fake_bin) + os.pathsep + os.defpath
    environment["FAKE_CHECK"] = check_output
    environment["FAKE_CHECK_STATUS"] = str(check_status)
    environment["FAKE_LIST"] = list_output
    environment["FAKE_LIST_STATUS"] = str(list_status)
    environment["FAKE_PIDOF"] = pidof_output
    environment["FAKE_PIDOF_STATUS"] = str(pidof_status)

    result = subprocess.run(
        ["/bin/sh", "-c", OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        check=False,
        timeout=3,
    )

    assert result.returncode == 0
    assert result.stdout == (
        "APKRun shell ready\n"
        f"activity_service_check={expected[0]}\n"
        f"activity_service_listed={expected[1]}\n"
        f"system_server_process={expected[2]}\n"
    ).encode("ascii")
    assert "593" not in result.stdout.decode("ascii")
    assert "android.app.IActivityManager" not in result.stdout.decode("ascii")
    assert "package:" not in result.stdout.decode("ascii")


@pytest.mark.parametrize(
    ("output", "expected"),
    (
        (
            b"activity_service_check=found\n"
            b"activity_service_listed=notFound\n"
            b"system_server_process=present\n",
            ("found", "notFound", "present"),
        ),
        (
            b"activity_service_check=notFound\r\n"
            b"activity_service_listed=unknown\r\n"
            b"system_server_process=notPresent\r\n",
            ("notFound", "unknown", "notPresent"),
        ),
        (
            b"activity_service_check=found\nactivity_service_listed=notF",
            None,
        ),
        (b"activity_service_listed=found\n", None),
        (b"activity_service_check=found\nunexpected=593\n", None),
        (
            b"activity_service_check=found\n"
            b"activity_service_listed=found\n"
            b"system_server_process=present\npid=593\n",
            None,
        ),
        (b"activity_service_check=found\xff\n", None),
    ),
)
def test_parse_adb_shell_probe_diagnostics_is_strict_and_pid_free(
    output: bytes,
    expected: tuple[str | None, str | None, str | None] | None,
) -> None:
    assert OBSERVER_MODULE.parse_adb_shell_probe_diagnostics(output) == expected


def test_parse_adb_shell_probe_requires_timeout_for_partial_reply() -> None:
    partial_output = b"activity_service_check=found\nactivity_service_listed=notF"

    assert OBSERVER_MODULE.parse_adb_shell_probe_diagnostics(partial_output) is None
    assert OBSERVER_MODULE.parse_adb_shell_probe_diagnostics(
        partial_output,
        allow_partial_output=True,
    ) == ("found", None, None)


@pytest.mark.parametrize("missing_file", (None, "status", "wchan", "stack"))
def test_system_server_thread_shell_script_rejects_partial_proc_reads(
    tmp_path: Path,
    missing_file: str | None,
) -> None:
    proc_root = tmp_path / "proc"
    task = proc_root / "123" / "task" / "456"
    task.mkdir(parents=True)
    (proc_root / "123" / "comm").write_text("system_server\n", encoding="ascii")
    if missing_file != "status":
        (task / "status").write_text(
            "Name:\tsystem_server\nState:\tD (disk sleep)\n",
            encoding="ascii",
        )
    if missing_file != "wchan":
        (task / "wchan").write_text("rwsem_down_write_slowpath\n", encoding="ascii")
    if missing_file != "stack":
        (task / "stack").write_text(
            "[<ffff000012345678>] do_mprotect_pkey+0xd8/0x624\n",
            encoding="ascii",
        )
    script = OBSERVER_MODULE.SYSTEM_SERVER_THREAD_SHELL_SCRIPT.replace(
        "/proc",
        shlex.quote(str(proc_root)),
        1,
    )

    result = subprocess.run(
        ["sh", "-c", script],
        capture_output=True,
        check=False,
        timeout=3,
    )

    if missing_file is None:
        assert result.returncode == 0
        assert OBSERVER_MODULE.parse_system_server_thread_snapshot(result.stdout) is not None
    else:
        assert result.returncode != 0
        assert result.stdout.endswith(b"X\n")
        assert OBSERVER_MODULE.parse_system_server_thread_snapshot(result.stdout) is None


@pytest.mark.parametrize(
    "output",
    (
        b"",
        b"P\nT\tD\twchan\n",
        b"P\nT\tD\twchan\nE",
        b"P\n",
        b"N\nP\n",
        b"P\nT\tinvalid\twchan\nE\n",
        b"P\nT\tU\twchan\nE\n",
        b"P\nT\tS\tbad/wchan\nE\n",
        b"P\nT\tS\twchan\nF\t" + b"frame\n" * 33 + b"E\n",
        b"P\nX\n",
        b"P\nT\tD\twchan\nE\nX\n",
    ),
)
def test_system_server_thread_snapshot_parser_rejects_incomplete_or_invalid_records(
    output: bytes,
) -> None:
    assert OBSERVER_MODULE.parse_system_server_thread_snapshot(output) is None


def test_boot_observer_records_blocked_system_server_trigger_without_raw_log_data(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    kernel_log.write_bytes(
        b"[ 99.100000][ T42] task:system_server state:D stack:0 pid:12345 tgid:12345\n"
    )
    try:
        observer.sample(now=0)
        with kernel_log.open("ab") as stream:
            stream.write(
                b"[ 99.200000][ T42] Call trace:\n[ 99.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
            )
        observer.sample(now=1)
        observer.sample(now=2)
    finally:
        observer.close()

    records = _read_records(output)
    trigger = next(
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    )
    assert trigger["guestUptimeSeconds"] == 99.1
    skipped = next(
        record for record in records if record["event"] == "system_server_thread_snapshot"
    )
    assert skipped["attempted"] is False
    assert skipped["reason"] == "observer_stopped_before_device_probe"
    serialized = output.read_text(encoding="ascii")
    assert "12345" not in serialized
    assert "do_mprotect_pkey+0x10" not in serialized


def test_boot_observer_scans_all_new_bytes_before_trimming_the_log_excerpt(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    kernel_log.write_bytes(b"initial log\n")
    blocked_trace = (
        b"[ 101.100000][ T42] task:system_server state:D stack:0 pid:123 tgid:123\n"
        b"[ 101.200000][ T42] Call trace:\n"
        b"[ 101.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
    )

    try:
        observer.sample(now=0)
        with kernel_log.open("ab") as stream:
            stream.write(blocked_trace + b"x" * (300 * 1024))
        observer.sample(now=1)
    finally:
        observer.close()

    records = _read_records(output)
    trigger = next(
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    )
    assert trigger["guestUptimeSeconds"] == 101.1


@pytest.mark.parametrize("mutation", ("atomic_replace", "in_place_rewrite", "truncate_regrowth"))
def test_boot_observer_detects_kernel_log_replacement_and_rescans(
    tmp_path: Path,
    mutation: str,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    prefix = b"P" * 5000 + b"\n"
    old_middle = b"A" * 10000
    suffix = b"S" * 5000
    original = prefix + old_middle + suffix
    blocked_trace = (
        b"[ 202.100000][ T42] task:system_server state:D stack:0 pid:123 tgid:123\n"
        b"[ 202.200000][ T42] Call trace:\n"
        b"[ 202.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
    )
    new_middle = blocked_trace + b"B" * (len(old_middle) - len(blocked_trace))
    replacement = prefix + new_middle + suffix
    kernel_log.write_bytes(original)

    try:
        observer.sample(now=0)
        old_stat = kernel_log.stat()
        if mutation == "atomic_replace":
            temporary = kernel_log.with_suffix(".replacement")
            temporary.write_bytes(replacement)
            os.utime(
                temporary,
                ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns + 1_000_000),
            )
            os.replace(temporary, kernel_log)
        elif mutation == "in_place_rewrite":
            with kernel_log.open("r+b") as stream:
                stream.seek(len(prefix))
                stream.write(new_middle)
            new_stat = kernel_log.stat()
            os.utime(
                kernel_log,
                ns=(new_stat.st_atime_ns, old_stat.st_mtime_ns + 1_000_000),
            )
        else:
            kernel_log.write_bytes(replacement)
            new_stat = kernel_log.stat()
            os.utime(
                kernel_log,
                ns=(new_stat.st_atime_ns, old_stat.st_mtime_ns + 1_000_000),
            )
        observer.sample(now=1)
    finally:
        observer.close()

    records = _read_records(output)
    assert any(record["event"] == "kernel_log_replaced_observation_gap" for record in records)
    trigger = next(
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    )
    assert trigger["guestUptimeSeconds"] == 202.1


def test_boot_observer_tracks_stable_source_marker_growth_across_promotions(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    original = b"initial kernel log\n"
    source_device = 77
    source_inode = 88
    _promote_kernel_log_snapshot(
        observer,
        kernel_log,
        original,
        (source_device, source_inode, len(original), 100),
    )
    blocked_trace = (
        b"[ 303.100000][ T42] task:system_server state:D stack:0 pid:123 tgid:123\n"
        b"[ 303.200000][ T42] Call trace:\n"
        b"[ 303.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
    )

    try:
        observer.sample(now=0)
        updated = original + blocked_trace
        _promote_kernel_log_snapshot(
            observer,
            kernel_log,
            updated,
            (source_device, source_inode, len(updated), 101),
        )
        observer.sample(now=1)
    finally:
        observer.close()

    records = _read_records(output)
    assert not any(record["event"] == "kernel_log_replaced_observation_gap" for record in records)
    trigger = next(
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    )
    assert trigger["guestUptimeSeconds"] == 303.1


@pytest.mark.parametrize("mutation", ("inode_replacement", "truncation", "same_size_update"))
def test_boot_observer_source_marker_discontinuities_reset_and_rescan(
    tmp_path: Path,
    mutation: str,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    prefix = b"P" * 5000 + b"\n"
    old_middle = b"A" * 10000
    suffix = b"S" * 5000
    original = prefix + old_middle + suffix
    source_device = 77
    source_inode = 88
    _promote_kernel_log_snapshot(
        observer,
        kernel_log,
        original,
        (source_device, source_inode, len(original), 100),
    )
    blocked_trace = (
        b"[ 304.100000][ T42] task:system_server state:D stack:0 pid:123 tgid:123\n"
        b"[ 304.200000][ T42] Call trace:\n"
        b"[ 304.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
    )
    new_middle = blocked_trace + b"B" * (len(old_middle) - len(blocked_trace))
    if mutation == "truncation":
        replacement = b"short log\n" + blocked_trace
        replacement_marker = (source_device, source_inode, len(replacement), 101)
    else:
        replacement = prefix + new_middle + suffix
        replacement_marker = (
            source_device,
            source_inode + (mutation == "inode_replacement"),
            len(replacement),
            101,
        )

    try:
        observer.sample(now=0)
        _promote_kernel_log_snapshot(
            observer,
            kernel_log,
            replacement,
            replacement_marker,
        )
        observer.sample(now=1)
    finally:
        observer.close()

    records = _read_records(output)
    assert any(record["event"] == "kernel_log_replaced_observation_gap" for record in records)
    trigger = next(
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    )
    assert trigger["guestUptimeSeconds"] == 304.1


@pytest.mark.parametrize(("trace_at_end", "expected_match"), ((True, True), (False, False)))
def test_boot_observer_source_marker_catchup_limit_records_gap(
    tmp_path: Path,
    trace_at_end: bool,
    expected_match: bool,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    kernel_log = output.parent / ".live-cvd-logs" / "kernel.log"
    original = b"initial kernel log\n"
    source_device = 77
    source_inode = 88
    _promote_kernel_log_snapshot(
        observer,
        kernel_log,
        original,
        (source_device, source_inode, len(original), 100),
    )
    blocked_trace = (
        b"[ 305.100000][ T42] task:system_server state:D stack:0 pid:123 tgid:123\n"
        b"[ 305.200000][ T42] Call trace:\n"
        b"[ 305.300000][ T42] do_mprotect_pkey+0x10/0x20\n"
    )
    large_append = b"x" * (OBSERVER_MODULE.SYSTEM_SERVER_BLOCKED_LOG_SCAN_LIMIT_BYTES + 1) + b"\n"
    appended = large_append + blocked_trace if trace_at_end else blocked_trace + large_append
    updated = original + appended

    try:
        observer.sample(now=0)
        _promote_kernel_log_snapshot(
            observer,
            kernel_log,
            updated,
            (source_device, source_inode, len(updated), 101),
        )
        observer.sample(now=1)
    finally:
        observer.close()

    records = _read_records(output)
    gap = next(record for record in records if record["event"] == "kernel_log_scan_gap")
    expected_skipped = max(
        0,
        len(updated) - OBSERVER_MODULE.SYSTEM_SERVER_BLOCKED_LOG_TAIL_BYTES - len(original),
    )
    assert gap["skippedBytes"] == expected_skipped
    matches = [
        record
        for record in records
        if record["event"] == "system_server_mprotect_blocked_state_observed"
    ]
    assert bool(matches) is expected_match
    if expected_match:
        assert matches[0]["guestUptimeSeconds"] == 305.1


@pytest.mark.parametrize(
    ("snapshot_timed_out", "snapshot_exit_code", "snapshot_response", "expected_parsed"),
    (
        (
            False,
            0,
            b"P\nT\tD\trwsem_down_write_slowpath\n"
            b"F\t[<ffff12345678>] do_mprotect_pkey+0x10/0x20\nE\n",
            True,
        ),
        (True, None, b"", False),
        (False, 7, b"", False),
        (
            False,
            0,
            b"P\nT\tD\trwsem_down_write_slowpath\n"
            b"F\t[<ffff12345678>] do_mprotect_pkey+0x10/0x20\nE\nX\n",
            False,
        ),
    ),
)
def test_boot_observer_captures_system_server_threads_once_after_blocked_mprotect(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    snapshot_timed_out: bool,
    snapshot_exit_code: int | None,
    snapshot_response: bytes,
    expected_parsed: bool,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer._system_server_mprotect_guest_uptime = 99.1
    observer._shell_probe_attempted = True
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    calls: list[list[str]] = []

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline
        calls.append(command)
        if "connect" in command:
            return 0, b"", False, True, False, True, False
        if command[-1:] == ["get-state"]:
            return 0, b"device\n", False, True, False, True, False
        if command[-5:] == [
            "su",
            "0",
            "sh",
            "-c",
            OBSERVER_MODULE.SYSTEM_SERVER_THREAD_SHELL_SCRIPT,
        ]:
            assert timeout_seconds == OBSERVER_MODULE.SYSTEM_SERVER_THREAD_TIMEOUT_SECONDS
            assert max_output_bytes == OBSERVER_MODULE.SYSTEM_SERVER_THREAD_MAX_OUTPUT_BYTES
            return (
                snapshot_exit_code,
                snapshot_response,
                snapshot_timed_out,
                True,
                False,
                True,
                False,
            )
        if command[-3:] == ["sh", "-c", OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND]:
            return (
                0,
                b"boot_completed=0\nboot_completed_status=0\n"
                b"system_server=1\nsystem_server_status=0\n",
                False,
                True,
                False,
                True,
                False,
            )
        raise AssertionError(f"unexpected adb command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        for _ in range(2):
            assert observer._record_adb_poll(
                "localfilesystem:/tmp/adb.sock",
                "127.0.0.1:6520",
                LiveServer(),  # type: ignore[arg-type]
                socket_path,
                time.monotonic() + 30,
            )
    finally:
        observer.close()
        adb_socket.close()

    records = _read_records(output)
    snapshots = [record for record in records if record["event"] == "system_server_thread_snapshot"]
    assert len(snapshots) == 1
    snapshot = snapshots[0]
    assert snapshot["triggerGuestUptimeSeconds"] == 99.1
    assert snapshot["attempted"] is True
    assert snapshot["exitCode"] == snapshot_exit_code
    assert snapshot["timedOut"] is snapshot_timed_out
    assert snapshot["parsed"] is expected_parsed
    if expected_parsed:
        assert snapshot["stateCounts"] == {"D": 1}
        assert snapshot["threads"][0]["kernelFrames"] == ["do_mprotect_pkey"]
    polls = [record for record in records if record["event"] == "adb_poll"]
    assert len(polls) == 2
    assert polls[0]["systemServerThreadSnapshotAttempted"] is True
    assert polls[0]["systemServerThreadSnapshotParsed"] is expected_parsed
    assert polls[0]["commandTimedOut"] is snapshot_timed_out
    assert polls[1]["systemServerThreadSnapshotAttempted"] is False
    assert (
        sum(
            command[-5:]
            == [
                "su",
                "0",
                "sh",
                "-c",
                OBSERVER_MODULE.SYSTEM_SERVER_THREAD_SHELL_SCRIPT,
            ]
            for command in calls
        )
        == 1
    )
    serialized = output.read_text(encoding="ascii")
    assert "ffff12345678" not in serialized
    assert "4364" not in serialized
    assert "do_mprotect_pkey+0x10" not in serialized


def test_boot_observer_samples_only_the_launcher_identified_android_crosvm(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "usr" / "lib" / "cuttlefish-common" / "bin" / "crosvm"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
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
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=411,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(412,),
        instance_path=observer.instance_path,
        android=False,
    )
    _fake_proc_restarter(
        proc_root,
        411,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(
        b"run_cvd(500)  D Started (pid: 498): /private/log_tee\n"
        b"run_cvd(500)  D --process_name=openwrt\n"
        b"process_restarter(410)  D Starting OpenWrt crosvm\n"
        b"run_cvd(500)  D Started (pid: 499): /private/cuttlefish home/log_tee\n"
        b"process_restarter(411)  D Started (pid: 413): /private/crosvm\n"
        b"run_cvd(500)  D --process_name=crosvm\n"
        b"process_restarter(411)  D Starting Android crosvm\n"
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
    staged_crosvm = (
        observer.instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / "crosvm"
    )
    assert staged_crosvm.is_symlink()
    assert staged_crosvm.resolve() == executable.resolve()


def test_boot_observer_tracks_launcher_command_and_fexecve_executable_separately(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    diagnostic_dir = tmp_path / "diagnostic"
    diagnostic_dir.mkdir()
    launcher = diagnostic_dir / "crosvm-built-virgl-launcher"
    launcher.write_bytes(b"diagnostic static launcher")
    launcher.chmod(0o700)
    executable = diagnostic_dir / "crosvm"
    executable.write_bytes(b"feature-enabled crosvm executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
        crosvm_path=launcher,
        crosvm_executable_path=executable,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        process_name="crosvm",
        parent_pid=410,
        instance_path=observer.instance_path,
        staged_crosvm_target=launcher,
        staged_crosvm_name=launcher.name,
        command_line_executable=executable,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
        requested_crosvm_name=launcher.name,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

    observer.start()
    observer.sample(now=0)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["pid"] == 413
    assert memory[0]["vmRssKiB"] == 987654
    staged_launcher = (
        observer.instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / launcher.name
    )
    assert staged_launcher.is_symlink()
    assert staged_launcher.resolve() == launcher.resolve()


def test_boot_observer_preserves_staged_basename_for_symlinked_crosvm_override(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    diagnostic_dir = tmp_path / "diagnostic"
    diagnostic_dir.mkdir()
    executable = diagnostic_dir / "crosvm"
    executable.write_bytes(b"diagnostic crosvm executable")
    executable.chmod(0o700)
    command_alias = diagnostic_dir / "crosvm-diagnostic-alias"
    command_alias.symlink_to(executable)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
        crosvm_path=command_alias,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        process_name="crosvm",
        parent_pid=410,
        instance_path=observer.instance_path,
        staged_crosvm_target=command_alias,
        staged_crosvm_name=command_alias.name,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
        requested_crosvm_name=command_alias.name,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

    observer.start()
    observer.sample(now=0)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["pid"] == 413
    staged_command = (
        observer.instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / command_alias.name
    )
    assert staged_command.is_symlink()
    assert staged_command.resolve() == executable.resolve()


def test_boot_observer_rejects_staged_crosvm_link_to_different_same_name_executable(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "installed" / "crosvm"
    executable.parent.mkdir()
    executable.write_bytes(b"installed crosvm executable")
    executable.chmod(0o700)
    staged_target = tmp_path / "other-install" / "crosvm"
    staged_target.parent.mkdir()
    staged_target.write_bytes(b"different crosvm executable")
    staged_target.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
        staged_crosvm_target=staged_target,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

    observer.start()
    observer.sample(now=0)
    observer.close()

    staged_crosvm = (
        observer.instance_path.parents[3] / "artifacts" / "host_tools" / "bin" / "crosvm"
    )
    assert staged_crosvm.is_symlink()
    assert staged_crosvm.resolve() == staged_target.resolve()
    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["identity"] == "unavailable"
    assert memory[0]["candidateCount"] == 0


def test_boot_observer_rejects_child_pid_reused_by_another_parent_before_first_sample(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)
    read_crosvm_memory = observer._read_crosvm_memory

    def replace_child_before_sampling(
        pid: int,
        expected_start_time: bytes | None,
        *,
        parent_pid: int,
        parent_start_time: bytes,
    ) -> tuple[dict[str, object], bytes] | None:
        child = proc_root / str(pid)
        shutil.rmtree(child)
        _fake_proc_process(
            proc_root,
            pid,
            executable,
            start_time=54321,
            parent_pid=999,
            instance_path=observer.instance_path,
        )
        return read_crosvm_memory(
            pid,
            expected_start_time,
            parent_pid=parent_pid,
            parent_start_time=parent_start_time,
        )

    monkeypatch.setattr(observer, "_read_crosvm_memory", replace_child_before_sampling)
    observer.start()
    observer.sample(now=0)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["identity"] == "unavailable"
    assert memory[0]["candidateCount"] == 0


def test_boot_observer_rejects_reused_launcher_pid_between_samples(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
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
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

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


def test_boot_observer_rejects_reused_restarter_pid_between_samples(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

    observer.start()
    observer.sample(now=0)
    restarter_stat = proc_root / "410" / "stat"
    restarter_stat.write_bytes(b"410 (process_restarter) S " + b"0 " * 18 + b"54321\n")
    observer.sample(now=2)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 2
    assert memory[0]["pid"] == 413
    assert memory[1]["identity"] == "unavailable"
    assert memory[1]["candidateCount"] == 0


def test_boot_observer_keeps_restarter_pid_generation_across_atomic_log_updates(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

    observer.start()
    observer.sample(now=0)
    replacement = launcher_log.with_name("launcher.next")
    replacement.write_bytes(launcher_log.read_bytes() + b"ordinary log append\n")
    os.replace(replacement, launcher_log)
    (proc_root / "410" / "stat").write_bytes(
        b"410 (process_restarter) S " + b"0 " * 18 + b"54321\n"
    )
    observer.sample(now=2)
    observer.close()

    records = _read_records(output)
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(memory) == 2
    assert memory[0]["pid"] == 413
    assert memory[1]["identity"] == "unavailable"
    assert not any(record["event"] == "launcher_log_replaced_observation_gap" for record in records)


def test_boot_observer_selects_android_after_interleaved_openwrt_restarter(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
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
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_process(
        proc_root,
        413,
        executable,
        parent_pid=411,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(412,),
        instance_path=observer.instance_path,
        android=False,
    )
    _fake_proc_restarter(
        proc_root,
        411,
        restarter_executable,
        children=(413,),
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(
        b"run_cvd(500)  D Started (pid: 499): /private/cuttlefish home/log_tee\n"
        b"process_restarter(410)  D Started (pid: 412): /private/crosvm\n"
        b"run_cvd(500)  D --process_name=crosvm\n"
        b"process_restarter(410)  D --serial Android kernel-log-pipe\n"
        b"process_restarter(411)  D --serial OpenWrt crosvm_openwrt\n"
    )

    observer.start()
    observer.sample(now=0)
    observer.close()

    memory = [record for record in _read_records(output) if record["event"] == "crosvm_memory"]
    assert len(memory) == 1
    assert memory[0]["pid"] == 413


def test_boot_observer_rejects_same_name_crosvm_from_another_private_instance(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    other_instance = _managed_instance_path(tmp_path, name="cvd-1")
    _fake_proc_process(
        proc_root,
        414,
        executable,
        parent_pid=410,
        instance_path=other_instance,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(414,),
        instance_path=other_instance,
    )
    _write_crosvm_launcher_identity(launcher_log, 410)

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
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        415,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(415,),
        instance_path=observer.instance_path,
    )
    launcher_log.write_bytes(
        b"run_cvd(500)  D Started (pid: 499): /private/log_tee\n"
        b"run_cvd(500)  D --process_name=crosvm\n"
        b"process_restarter(410)  D Starting Android crosvm\n"
        b"Start event (5) received.\n"
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


def test_boot_observer_detects_same_prefix_log_truncation_and_regrowth(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        sample_interval=1,
    )
    _fake_proc_process(
        proc_root,
        415,
        executable,
        parent_pid=410,
        instance_path=observer.instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        410,
        restarter_executable,
        children=(415,),
        instance_path=observer.instance_path,
    )
    shared_prefix = b"p" * 4095 + b"\n"
    identity = (
        b"run_cvd(500)  D Started (pid: 499): /private/log_tee\n"
        b"run_cvd(500)  D --process_name=crosvm\n"
        b"process_restarter(410)  D Starting Android crosvm\n"
    )
    launcher_log.write_bytes((shared_prefix + identity).ljust(8192, b"a"))

    observer.start()
    observer.sample(now=0)
    launcher_log.write_bytes((shared_prefix + b"replacement log\n").ljust(8192, b"b"))
    observer.sample(now=2)
    observer.close()

    records = _read_records(output)
    gaps = [
        record for record in records if record["event"] == "launcher_log_replaced_observation_gap"
    ]
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(gaps) == 1
    assert gaps[0]["discardedCandidateCount"] == 1
    assert memory[0]["pid"] == 415
    assert memory[1]["identity"] == "unavailable"


def test_boot_observer_records_unresolved_runtime_link(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    missing_target = tmp_path / "managed" / "home" / "cuttlefish" / "instances" / "cvd-1"
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        runtime_target=missing_target,
        runtime_link_ready=False,
    )

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert any(record["event"] == "instance_path_discovery_pending" for record in records)
    assert any(
        record["event"] == "instance_path_discovery_failed"
        and record["reason"] == "runtime_link_never_resolved"
        for record in records
    )


def test_boot_observer_rejects_instance_suffix_outside_cuttlefish_managed_root(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    untrusted_target = tmp_path / "managed" / "home" / "cuttlefish" / "instances" / "cvd-1"
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        runtime_target=untrusted_target,
    )

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert not any(record["event"] == "instance_path_discovered" for record in records)
    assert any(
        record["event"] == "instance_path_discovery_failed"
        and record["reason"] == "runtime_link_never_resolved"
        for record in records
    )


def test_boot_observer_rejects_instance_that_does_not_match_adb_port(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        runtime_target=_managed_instance_path(tmp_path, name="cvd-2"),
    )

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert not any(record["event"] == "instance_path_discovered" for record in records)
    assert any(
        record["event"] == "instance_path_discovery_failed"
        and record["reason"] == "runtime_link_never_resolved"
        for record in records
    )


@pytest.mark.parametrize("redirect_component", ("home", "instances"))
def test_boot_observer_rejects_managed_path_symlink_redirects(
    tmp_path: Path,
    redirect_component: str,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)

    if redirect_component == "home":
        managed_home = observer.instance_path.parents[2]
        managed_home.unlink()
        redirected_home = tmp_path / "redirected-home"
        (redirected_home / "cuttlefish" / "instances" / "cvd-1").mkdir(parents=True)
        managed_home.symlink_to(redirected_home, target_is_directory=True)
    else:
        instances = observer.home / "cuttlefish" / "instances"
        shutil.rmtree(instances)
        redirected_instances = tmp_path / "redirected-instances"
        (redirected_instances / "cvd-1").mkdir(parents=True)
        instances.symlink_to(redirected_instances, target_is_directory=True)

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert any(
        record["event"] == "instance_path_changed_observation_gap"
        and record["reason"] == "runtime_link_unavailable"
        for record in records
    )
    assert not any(record["event"] == "crosvm_memory" and "pid" in record for record in records)


def test_boot_observer_rejects_runtime_path_from_a_foreign_uid(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(tmp_path, proc_root=proc_root)
    current_uid = os.getuid()
    monkeypatch.setattr(OBSERVER_MODULE.os, "getuid", lambda: current_uid + 1)

    observer.start()
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    assert any(
        record["event"] == "instance_path_changed_observation_gap"
        and record["reason"] == "runtime_link_unavailable"
        for record in records
    )


def test_boot_observer_discovers_delayed_external_runtime_target(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    instance_path = _managed_instance_path(tmp_path)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        runtime_target=instance_path,
        runtime_link_ready=False,
    )
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)

    observer.start()
    observer.instance_path_link.symlink_to(instance_path)
    _fake_proc_process(
        proc_root,
        513,
        executable,
        parent_pid=512,
        instance_path=instance_path,
    )
    _fake_proc_restarter(
        proc_root,
        512,
        restarter_executable,
        children=(513,),
        instance_path=instance_path,
    )
    _write_crosvm_launcher_identity(launcher_log, 512)
    observer.sample(now=0)
    observer.close()

    records = _read_records(output)
    discovered = [record for record in records if record["event"] == "instance_path_discovered"]
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(discovered) == 1
    assert len(memory) == 1
    assert memory[0]["pid"] == 513
    assert memory[0]["vmRssKiB"] == 987654


def test_boot_observer_starts_adb_observer_before_next_memory_sample(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(tmp_path, proc_root=proc_root)
    adb_started = threading.Event()

    def fake_poll_adb() -> None:
        adb_started.set()

    monkeypatch.setattr(observer, "_poll_adb", fake_poll_adb)
    observer.start()
    observer.sample(now=0)
    assert observer._next_sample == observer.sample_interval

    launcher_log.write_bytes(b"Start event (5) received.\n")
    observer.sample(now=1)
    assert adb_started.wait(timeout=1)
    assert observer._next_sample == observer.sample_interval

    observer.close()
    records = _read_records(output)
    assert sum(record["event"] == "crosvm_memory" for record in records) == 1
    assert sum(record["event"] == "cuttlefish_start_event_5_observed" for record in records) == 1


def test_shutdown_wakeup_is_not_consumed_as_an_urgent_adb_poll(tmp_path: Path) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, _, _ = _observer(tmp_path, proc_root=proc_root)
    observer.start()
    observer._adb_wakeup.set()
    observer._stop_event.set()

    assert observer._consume_adb_wakeup() is False
    assert not observer._adb_wakeup.is_set()

    observer.close()


@pytest.mark.parametrize("replace_target", (False, True))
def test_boot_observer_stops_sampling_if_runtime_link_changes(
    tmp_path: Path,
    replace_target: bool,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    first_instance = _managed_instance_path(tmp_path)
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        runtime_target=first_instance,
    )
    executable = tmp_path / "crosvm"
    executable.write_bytes(b"test executable")
    executable.chmod(0o700)
    restarter_executable = tmp_path / "process_restarter"
    restarter_executable.write_bytes(b"test process_restarter executable")
    restarter_executable.chmod(0o700)
    _fake_proc_process(
        proc_root,
        523,
        executable,
        parent_pid=522,
        instance_path=first_instance,
    )
    _fake_proc_restarter(
        proc_root,
        522,
        restarter_executable,
        children=(523,),
        instance_path=first_instance,
    )
    _write_crosvm_launcher_identity(launcher_log, 522)
    observer.start()
    observer.sample(now=0)

    observer.instance_path_link.unlink()
    if replace_target:
        second_instance = _managed_instance_path(tmp_path)
        observer.instance_path_link.symlink_to(second_instance)
    observer.sample(now=5)
    observer.close()

    records = _read_records(output)
    gaps = [
        record for record in records if record["event"] == "instance_path_changed_observation_gap"
    ]
    memory = [record for record in records if record["event"] == "crosvm_memory"]
    assert len(gaps) == 1
    assert gaps[0]["discardedCandidateCount"] == 1
    assert gaps[0]["reason"] == (
        "runtime_target_changed" if replace_target else "runtime_link_unavailable"
    )
    assert memory[0]["pid"] == 523
    assert memory[1]["identity"] == "unavailable"


@pytest.mark.parametrize("ignore_server_terminate", (False, True))
@pytest.mark.parametrize(
    ("system_server_exit_code", "boot_completed_exit_code"),
    ((0, 0), (7, 0), (0, 7)),
)
def test_boot_observer_uses_private_adb_socket_after_start_event_and_cleans_up(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    ignore_server_terminate: bool,
    system_server_exit_code: int,
    boot_completed_exit_code: int,
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
    fake_getprop_directory = tmp_path / "fake-android-bin"
    fake_getprop_directory.mkdir()
    fake_getprop = fake_getprop_directory / "getprop"
    fake_getprop.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "property_name = sys.argv[-1]\n"
        "if property_name == 'sys.system_server.start_count':\n"
        "    status = int(os.environ['FAKE_SYSTEM_SERVER_EXIT_CODE'])\n"
        "elif property_name == 'sys.boot_completed':\n"
        "    status = int(os.environ['FAKE_BOOT_COMPLETED_EXIT_CODE'])\n"
        "else:\n"
        "    raise SystemExit(64)\n"
        "if status == 0:\n"
        "    print('1')\n"
        "raise SystemExit(status)\n",
        encoding="utf-8",
    )
    fake_getprop.chmod(0o700)
    termination_handler = "signal.SIG_IGN" if ignore_server_terminate else "stop"
    fake_adb.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, signal, socket, subprocess, sys, time\n"
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
        "if args[-3:-1] == ['sh', '-c'] and 'APKRun shell ready' in args[-1] "
        "and 'system_server=' not in args[-1]:\n"
        "    print('APKRun shell ready')\n"
        "    raise SystemExit(0)\n"
        "if args[-3:-1] == ['sh', '-c'] and 'system_server=' in args[-1]:\n"
        "    environment = os.environ.copy()\n"
        "    environment['PATH'] = os.environ['FAKE_GETPROP_DIR'] + "
        "os.pathsep + environment.get('PATH', '')\n"
        "    result = subprocess.run(\n"
        "        ['/bin/sh', '-c', args[-1]],\n"
        "        stdin=subprocess.DEVNULL,\n"
        "        stdout=subprocess.PIPE,\n"
        "        stderr=subprocess.DEVNULL,\n"
        "        env=environment,\n"
        "        check=False,\n"
        "    )\n"
        "    sys.stdout.buffer.write(result.stdout)\n"
        "    raise SystemExit(result.returncode)\n"
        "raise SystemExit(19)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)
    observer.adb_path = fake_adb.resolve(strict=True)
    monkeypatch.setenv("FAKE_ADB_CALLS", str(calls))
    monkeypatch.setenv("FAKE_GETPROP_DIR", str(fake_getprop_directory))
    monkeypatch.setenv("FAKE_SYSTEM_SERVER_EXIT_CODE", str(system_server_exit_code))
    monkeypatch.setenv("FAKE_BOOT_COMPLETED_EXIT_CODE", str(boot_completed_exit_code))
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
        if any(record["shellProbeAttempted"] for record in polls) and any(
            record["getpropAttempted"] for record in polls
        ):
            break
        time.sleep(0.02)
    observer.close()

    records = _read_records(output)
    assert any(record["event"] == "cuttlefish_start_event_5_observed" for record in records)
    polls = [record for record in records if record["event"] == "adb_poll"]
    shell_poll = next(record for record in polls if record["shellProbeAttempted"])
    assert shell_poll["shellProbeMarkerMatched"] is True
    assert shell_poll["getpropAttempted"] is False
    poll = next(record for record in polls if record["getpropAttempted"])
    assert poll["deviceState"] == "device"
    assert poll["getpropExitCode"] == 0
    assert poll["systemServerGetpropExitCode"] == system_server_exit_code
    assert poll["bootCompletedGetpropExitCode"] == boot_completed_exit_code
    assert poll["systemServerStartCount"] == (1 if system_server_exit_code == 0 else None)
    assert poll["systemServerStartCountPresent"] is (True if system_server_exit_code == 0 else None)
    assert poll["sysBootCompleted"] is (True if boot_completed_exit_code == 0 else None)
    assert poll["sysBootCompletedPresent"] is (True if boot_completed_exit_code == 0 else None)
    assert poll["getpropAttempted"] is True
    assert poll["getpropTimedOut"] is False
    assert poll["commandTimedOut"] is False
    assert poll["pollDeadlineReached"] is False
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
    saved_output = output.read_text(encoding="ascii")
    assert str(home) not in saved_output
    assert "system_server=1" not in saved_output
    assert "system_server_status=0" not in saved_output
    assert "boot_completed=1" not in saved_output
    assert "boot_completed_status=0" not in saved_output


def test_close_waits_for_the_full_final_probe_and_server_cleanup_bound(
    tmp_path: Path,
) -> None:
    required_cleanup_timeout = (
        OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS * 2
        + OBSERVER_MODULE.ADB_LOGCAT_TIMEOUT_SECONDS * OBSERVER_MODULE.ADB_LOGCAT_QUERY_COUNT
        + (
            OBSERVER_MODULE.ADB_CLIENT_TERMINATE_SECONDS
            + OBSERVER_MODULE.ADB_CLIENT_KILL_SECONDS * 2
        )
        * OBSERVER_MODULE.ADB_FINAL_PROBE_COMMAND_COUNT
        + OBSERVER_MODULE.ADB_PROBE_WINDOW_MARGIN_SECONDS
        + OBSERVER_MODULE.ADB_SERVER_TERMINATE_SECONDS
        + OBSERVER_MODULE.ADB_SERVER_KILL_SECONDS
    )
    assert OBSERVER_MODULE.ADB_LOGCAT_MINIMUM_WINDOW_SECONDS == required_cleanup_timeout
    assert OBSERVER_MODULE.ADB_LOGCAT_PROBE_RESERVE_SECONDS >= required_cleanup_timeout
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, _, _ = _observer(tmp_path, proc_root=proc_root)

    class ActiveProbeThread:
        def __init__(self) -> None:
            self.wait_timeout: float | None = None
            self.alive = True

        def join(self, timeout: float | None = None) -> None:
            self.wait_timeout = timeout
            self.alive = timeout is None or timeout < required_cleanup_timeout

        def is_alive(self) -> bool:
            return self.alive

    probe_thread = ActiveProbeThread()
    observer._adb_thread = probe_thread  # type: ignore[assignment]

    observer.close()

    assert probe_thread.wait_timeout == OBSERVER_MODULE.ADB_LOGCAT_PROBE_RESERVE_SECONDS
    assert not probe_thread.is_alive()


def test_boot_observer_runs_one_logcat_probe_in_the_final_deadline_window(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_COMMAND_TIMEOUT_SECONDS", 0.1)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_GETPROP_TIMEOUT_SECONDS", 0.2)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_LOGCAT_TIMEOUT_SECONDS", 0.1)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_CLIENT_TERMINATE_SECONDS", 0.05)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_CLIENT_KILL_SECONDS", 0.1)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_SERVER_TERMINATE_SECONDS", 0.5)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_SERVER_KILL_SECONDS", 0.5)
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_PROBE_WINDOW_MARGIN_SECONDS", 0.05)
    minimum_probe_window = (
        OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS * 2
        + OBSERVER_MODULE.ADB_LOGCAT_TIMEOUT_SECONDS * OBSERVER_MODULE.ADB_LOGCAT_QUERY_COUNT
        + (
            OBSERVER_MODULE.ADB_CLIENT_TERMINATE_SECONDS
            + OBSERVER_MODULE.ADB_CLIENT_KILL_SECONDS * 2
        )
        * OBSERVER_MODULE.ADB_FINAL_PROBE_COMMAND_COUNT
        + OBSERVER_MODULE.ADB_SERVER_TERMINATE_SECONDS
        + OBSERVER_MODULE.ADB_SERVER_KILL_SECONDS
        + OBSERVER_MODULE.ADB_PROBE_WINDOW_MARGIN_SECONDS
    )
    monkeypatch.setattr(
        OBSERVER_MODULE,
        "ADB_LOGCAT_MINIMUM_WINDOW_SECONDS",
        minimum_probe_window,
    )
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_CLEANUP_RESERVE_SECONDS", 0.2)
    monkeypatch.setattr(
        OBSERVER_MODULE,
        "ADB_LOGCAT_PROBE_RESERVE_SECONDS",
        minimum_probe_window + 1.0,
    )
    monkeypatch.setattr(OBSERVER_MODULE, "ADB_POLL_FINAL_RESERVE_SECONDS", 0.5)
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, launcher_log = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
        adb_interval=10.0,
    )
    observer.deadline = time.monotonic() + 7
    server_ready = tmp_path / "adb-server-ready"
    server_stopped = tmp_path / "adb-server-stopped"
    server_socket_file = tmp_path / "adb-server-socket"
    calls = tmp_path / "adb-calls.jsonl"
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\n"
        "import json, os, signal, socket, sys, time\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
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
        "    signal.signal(signal.SIGTERM, stop)\n"
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
        "with Path(os.environ['FAKE_ADB_CALLS']).open('a', encoding='utf-8') as stream:\n"
        "    stream.write(json.dumps({'args': args, 'time': time.monotonic()}) + '\\n')\n"
        "endpoint = args[args.index('-L') + 1].removeprefix('localfilesystem:')\n"
        "probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
        "probe.connect(endpoint)\n"
        "probe.close()\n"
        "if 'connect' in args:\n"
        "    raise SystemExit(0)\n"
        "if args[-1:] == ['get-state']:\n"
        "    print('device')\n"
        "    raise SystemExit(0)\n"
        "if args[-3:-1] == ['sh', '-c'] and 'system_server=' in args[-1]:\n"
        "    print('boot_completed=0\\nboot_completed_status=0\\n"
        "system_server=2\\nsystem_server_status=0')\n"
        "    raise SystemExit(0)\n"
        "if 'logcat' in args:\n"
        "    if args[args.index('-b') + 1] == 'events':\n"
        "        print('06-15 12:00:00.000  1000  1000 I am_proc_start: "
        "[987654, 12345, system_server]')\n"
        "    else:\n"
        "        print('06-15 12:00:01.000  1000  1000 W Watchdog: "
        "subject=private-value')\n"
        "    raise SystemExit(0)\n"
        "raise SystemExit(19)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)
    observer.adb_path = fake_adb.resolve(strict=True)
    monkeypatch.setenv("FAKE_ADB_CALLS", str(calls))
    launcher_log.write_bytes(b"Start event (5) received.\n")

    observer.start()
    observer.sample(now=0)
    deadline = time.monotonic() + 8
    try:
        while time.monotonic() < deadline:
            if any(record["event"] == "adb_logcat_summary" for record in _read_records(output)):
                break
            time.sleep(0.02)
    finally:
        observer.close()

    records = _read_records(output)
    summaries = [record for record in records if record["event"] == "adb_logcat_summary"]
    polls = [record for record in records if record["event"] == "adb_poll"]
    assert len(summaries) == 1
    assert len(polls) == 1
    assert summaries[0]["attempted"]
    assert summaries[0]["summary"]["processStartEvents"] == 1
    assert summaries[0]["summary"]["systemServerMentionEvents"] == 1
    assert summaries[0]["androidLogcat"]["summary"]["watchdogMentionLines"] == 1
    assert server_ready.read_text(encoding="ascii") == "ready"
    assert server_stopped.read_text(encoding="ascii") == "stopped"
    assert not Path(server_socket_file.read_text(encoding="ascii")).exists()
    logged_calls = [json.loads(line) for line in calls.read_text().splitlines()]
    logcat_calls = [call for call in logged_calls if "logcat" in call["args"]]
    assert len(logcat_calls) == 2
    assert logcat_calls[0]["args"][logcat_calls[0]["args"].index("-b") + 1] == "events"
    assert logcat_calls[0]["args"][-4:] == ["-v", "descriptive", "-t", "128"]
    assert [
        call["args"][index + 1]
        for call in (logcat_calls[1],)
        for index, argument in enumerate(call["args"][:-1])
        if argument == "-b"
    ] == ["main", "system", "crash"]
    assert logcat_calls[1]["args"][-2:] == ["-t", "128"]
    assert "system_server" not in output.read_text(encoding="utf-8")
    assert "private-value" not in output.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    (
        "scenario",
        "expected_state",
        "expected_getprop_attempted",
        "expected_getprop_timed_out",
        "expected_shell_probe_attempted",
        "expected_shell_probe_exit_code",
        "expected_shell_probe_timed_out",
        "expected_shell_probe_marker_matched",
        "expected_command_timed_out",
        "expected_deadline_reached",
        "expected_call_count",
    ),
    (
        ("deadline_after_connect", None, False, None, False, None, None, None, False, True, 1),
        ("deadline_before_getprop", "device", False, None, False, None, None, None, False, True, 2),
        ("deadline_before_spawn", "device", False, None, False, None, None, None, False, True, 3),
        (
            "getprop_not_attempted_at_deadline",
            "device",
            False,
            None,
            False,
            None,
            None,
            None,
            False,
            True,
            3,
        ),
        ("shell_probe_times_out", "device", False, None, True, None, True, True, True, False, 3),
        ("shell_marker_missing", "device", False, None, True, None, True, False, True, False, 3),
        ("shell_marker_crlf", "device", False, None, True, 0, False, True, False, False, 3),
        ("shell_probe_succeeds", "device", False, None, True, 0, False, True, False, False, 3),
        (
            "getprop_times_out_after_boot_query",
            "device",
            True,
            True,
            False,
            None,
            None,
            None,
            True,
            False,
            3,
        ),
        (
            "system_server_query_failed",
            "device",
            True,
            False,
            False,
            None,
            None,
            None,
            False,
            False,
            3,
        ),
        (
            "boot_completed_query_failed",
            "device",
            True,
            False,
            False,
            None,
            None,
            None,
            False,
            False,
            3,
        ),
        ("getprop_empty_output", "device", True, False, False, None, None, None, False, False, 3),
        (
            "getprop_empty_property_values",
            "device",
            True,
            False,
            False,
            None,
            None,
            None,
            False,
            False,
            3,
        ),
        (
            "getprop_output_truncated",
            "device",
            True,
            False,
            False,
            None,
            None,
            None,
            False,
            False,
            3,
        ),
        (
            "getprop_malformed_output",
            "device",
            True,
            False,
            False,
            None,
            None,
            None,
            False,
            False,
            3,
        ),
        ("connect_not_attempted", "offline", False, None, False, None, None, None, False, False, 2),
        ("connect_times_out", "device", False, None, True, None, True, True, True, False, 3),
        ("offline", "offline", False, None, False, None, None, None, False, False, 2),
        ("getstate_times_out", None, False, None, False, None, None, None, True, False, 2),
        ("getstate_failed", None, False, None, False, None, None, None, False, False, 2),
        ("getstate_empty", None, False, None, False, None, None, None, False, False, 2),
        ("getstate_other", None, False, None, False, None, None, None, False, False, 2),
        ("getstate_probe_error", None, False, None, False, None, None, None, False, False, 2),
    ),
)
def test_boot_observer_distinguishes_shell_probe_and_property_query_results(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    scenario: str,
    expected_state: str | None,
    expected_getprop_attempted: bool,
    expected_getprop_timed_out: bool | None,
    expected_shell_probe_attempted: bool,
    expected_shell_probe_exit_code: int | None,
    expected_shell_probe_timed_out: bool | None,
    expected_shell_probe_marker_matched: bool | None,
    expected_command_timed_out: bool,
    expected_deadline_reached: bool,
    expected_call_count: int,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    if expected_getprop_attempted or scenario == "getprop_not_attempted_at_deadline":
        observer._shell_probe_attempted = True
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    calls: list[list[str]] = []
    timeouts: list[float] = []
    output_limits: list[int] = []
    launched_commands: list[list[str]] = []
    property_outputs = {
        "system_server_query_failed": (
            "boot_completed=0\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=7"
        ),
        "boot_completed_query_failed": (
            "boot_completed=1\nboot_completed_status=7\nsystem_server=2\nsystem_server_status=0"
        ),
        "getprop_empty_output": "",
        "getprop_empty_property_values": (
            "boot_completed=\nboot_completed_status=0\nsystem_server=\nsystem_server_status=0"
        ),
        "getprop_malformed_output": "unexpected property response\n",
    }
    timeout_property_output = (
        "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_stat"
    )

    class FakeClock:
        current = 0.0

        def monotonic(self) -> float:
            return self.current

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    clock = FakeClock()
    monkeypatch.setattr(OBSERVER_MODULE, "time", clock)

    def bounded_result(
        exit_code: int | None,
        output: str = "",
        *,
        timed_out: bool = False,
        attempted: bool = True,
        truncated: bool = False,
        probe_error: bool = False,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        return exit_code, output.encode(), timed_out, attempted, truncated, True, probe_error

    def fake_run_adb(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment
        calls.append(command)
        timeouts.append(timeout_seconds)
        output_limits.append(max_output_bytes)
        if "connect" in command:
            if scenario == "connect_not_attempted":
                return bounded_result(None, attempted=False)
            if scenario == "connect_times_out":
                return bounded_result(None, timed_out=True)
            launched_commands.append(command)
            if scenario == "deadline_after_connect":
                clock.current = deadline
            return bounded_result(0)
        if command[-1:] == ["get-state"]:
            if scenario == "deadline_before_getprop":
                clock.current = deadline
            if scenario in {"connect_not_attempted", "offline"}:
                launched_commands.append(command)
                return bounded_result(0, "offline")
            if scenario == "getstate_times_out":
                launched_commands.append(command)
                return bounded_result(None, timed_out=True)
            if scenario == "getstate_probe_error":
                launched_commands.append(command)
                return bounded_result(0, "device", probe_error=True)
            if scenario == "getstate_failed":
                launched_commands.append(command)
                return bounded_result(19, "private-device-name")
            if scenario == "getstate_empty":
                launched_commands.append(command)
                return bounded_result(0)
            if scenario == "getstate_other":
                launched_commands.append(command)
                return bounded_result(0, "private-device-name")
            launched_commands.append(command)
            return bounded_result(0, "device")
        if command[-3:] == [
            "sh",
            "-c",
            OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND,
        ]:
            if scenario == "deadline_before_spawn":
                clock.current = deadline
                return bounded_result(None, attempted=False)
            launched_commands.append(command)
            if scenario == "shell_marker_crlf":
                return bounded_result(
                    0,
                    (
                        OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER.decode()
                        + "\r\n"
                        + "activity_service_check=notFound\r\n"
                        + "activity_service_listed=found\r\n"
                        + "system_server_process=present\r\n"
                    ),
                )
            if scenario == "shell_probe_succeeds":
                return bounded_result(
                    0,
                    (
                        OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER.decode()
                        + "\n"
                        + "activity_service_check=found\n"
                        + "activity_service_listed=found\n"
                        + "system_server_process=present\n"
                    ),
                )
            if scenario == "shell_marker_missing":
                return bounded_result(None, timed_out=True)
            if scenario in {"shell_probe_times_out", "connect_times_out"}:
                return bounded_result(
                    None,
                    OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER.decode()
                    + "\nactivity_service_check=notFound\n"
                    + "activity_service_listed=notF",
                    timed_out=True,
                )
            raise AssertionError(f"unexpected shell probe scenario: {scenario}")
        if command[-3:] == [
            "sh",
            "-c",
            OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND,
        ]:
            if scenario == "getprop_not_attempted_at_deadline":
                clock.current = deadline
                return bounded_result(None, attempted=False)
            launched_commands.append(command)
            if scenario == "getprop_times_out_after_boot_query":
                return bounded_result(None, timeout_property_output, timed_out=True)
            if scenario == "getprop_output_truncated":
                return bounded_result(
                    0,
                    "boot_completed=1\nboot_completed_status=0\n"
                    "system_server=2\nsystem_server_status=0\n",
                    truncated=True,
                )
            if scenario in property_outputs:
                return bounded_result(0, property_outputs[scenario])
            raise AssertionError(f"unexpected property query scenario: {scenario}")
        raise AssertionError(f"unexpected adb command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_adb)
    try:
        assert observer._record_adb_poll(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            10.0,
        )
    finally:
        observer.close()
        adb_socket.close()

    poll_records = [record for record in _read_records(output) if record["event"] == "adb_poll"]
    assert len(poll_records) == 1
    poll = poll_records[0]
    assert poll["connectExitCode"] is (
        None if scenario in {"connect_not_attempted", "connect_times_out"} else 0
    )
    assert poll["deviceState"] == expected_state
    assert poll["connectAttempted"] is (scenario != "connect_not_attempted")
    assert poll["connectTimedOut"] is (
        True
        if scenario == "connect_times_out"
        else None
        if scenario == "connect_not_attempted"
        else False
    )
    assert poll["getStateAttempted"] is (scenario != "deadline_after_connect")
    assert poll["getStateExitCode"] is (
        None
        if scenario in {"deadline_after_connect", "getstate_times_out"}
        else 19
        if scenario == "getstate_failed"
        else 0
    )
    assert poll["getStateTimedOut"] is (
        None if scenario == "deadline_after_connect" else scenario == "getstate_times_out"
    )
    assert (
        poll["getStateResult"]
        == {
            "deadline_after_connect": "notAttempted",
            "deadline_before_getprop": "device",
            "deadline_before_spawn": "device",
            "getprop_not_attempted_at_deadline": "device",
            "shell_probe_times_out": "device",
            "shell_marker_missing": "device",
            "shell_marker_crlf": "device",
            "shell_probe_succeeds": "device",
            "getprop_times_out_after_boot_query": "device",
            "system_server_query_failed": "device",
            "boot_completed_query_failed": "device",
            "getprop_empty_output": "device",
            "getprop_empty_property_values": "device",
            "getprop_output_truncated": "device",
            "getprop_malformed_output": "device",
            "connect_not_attempted": "offline",
            "connect_times_out": "device",
            "offline": "offline",
            "getstate_times_out": "timedOut",
            "getstate_failed": "commandFailed",
            "getstate_empty": "empty",
            "getstate_other": "other",
            "getstate_probe_error": "probeError",
        }[scenario]
    )
    assert poll["getpropAttempted"] is expected_getprop_attempted
    assert poll["getpropTimedOut"] is expected_getprop_timed_out
    assert poll["shellProbeAttempted"] is expected_shell_probe_attempted
    assert poll["shellProbeExitCode"] == expected_shell_probe_exit_code
    assert poll["shellProbeTimedOut"] is expected_shell_probe_timed_out
    assert poll["shellProbeMarkerMatched"] is expected_shell_probe_marker_matched
    expected_shell_diagnostics = {
        "shell_marker_crlf": ("notFound", "found", "present"),
        "shell_probe_succeeds": ("found", "found", "present"),
        "shell_probe_times_out": ("notFound", None, None),
        "connect_times_out": ("notFound", None, None),
    }.get(scenario, (None, None, None))
    expected_shell_diagnostics_parsed = (
        True
        if scenario
        in {
            "shell_marker_crlf",
            "shell_probe_succeeds",
            "shell_probe_times_out",
            "connect_times_out",
        }
        else False
        if expected_shell_probe_attempted
        else None
    )
    assert poll["shellProbeDiagnosticsParsed"] is expected_shell_diagnostics_parsed
    assert poll["activityServiceCheck"] == expected_shell_diagnostics[0]
    assert poll["activityServiceListed"] == expected_shell_diagnostics[1]
    assert poll["systemServerProcess"] == expected_shell_diagnostics[2]
    if scenario in property_outputs:
        expected_output = property_outputs[scenario].encode()
        assert poll["getpropOutputBytes"] == len(expected_output)
        assert poll["getpropOutputParsed"] is (
            scenario not in {"getprop_empty_output", "getprop_malformed_output"}
        )
        logged_output = output.read_text(encoding="utf-8")
        assert "unexpected property response" not in logged_output
        assert "boot_completed=" not in logged_output
    elif scenario == "getprop_output_truncated":
        expected_output = (
            b"boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0\n"
        )
        assert poll["getpropOutputBytes"] == len(expected_output)
        assert poll["getpropOutputParsed"] is None
        assert poll["getpropTruncated"] is True
        assert "boot_completed=" not in output.read_text(encoding="utf-8")
    elif scenario == "getprop_times_out_after_boot_query":
        assert poll["getpropOutputBytes"] == len(timeout_property_output.encode())
        assert poll["getpropOutputParsed"] is True
        assert "boot_completed=" not in output.read_text(encoding="utf-8")
    else:
        assert poll["getpropOutputBytes"] is None
        assert poll["getpropOutputParsed"] is None
    if scenario == "system_server_query_failed":
        assert poll["getpropExitCode"] == 0
        assert poll["systemServerGetpropExitCode"] == 7
        assert poll["bootCompletedGetpropExitCode"] == 0
        assert poll["systemServerStartCount"] is None
        assert poll["systemServerStartCountPresent"] is None
        assert poll["sysBootCompleted"] is False
        assert poll["sysBootCompletedPresent"] is True
    elif scenario == "boot_completed_query_failed":
        assert poll["getpropExitCode"] == 0
        assert poll["systemServerGetpropExitCode"] == 0
        assert poll["bootCompletedGetpropExitCode"] == 7
        assert poll["systemServerStartCount"] == 2
        assert poll["systemServerStartCountPresent"] is True
        assert poll["sysBootCompleted"] is None
        assert poll["sysBootCompletedPresent"] is None
    elif scenario == "getprop_times_out_after_boot_query":
        assert poll["getpropExitCode"] is None
        assert poll["systemServerGetpropExitCode"] is None
        assert poll["bootCompletedGetpropExitCode"] == 0
        assert poll["systemServerStartCount"] is None
        assert poll["systemServerStartCountPresent"] is None
        assert poll["sysBootCompleted"] is True
        assert poll["sysBootCompletedPresent"] is True
    elif scenario == "getprop_empty_property_values":
        assert poll["getpropExitCode"] == 0
        assert poll["systemServerGetpropExitCode"] == 0
        assert poll["bootCompletedGetpropExitCode"] == 0
        assert poll["systemServerStartCount"] is None
        assert poll["systemServerStartCountPresent"] is False
        assert poll["sysBootCompleted"] is None
        assert poll["sysBootCompletedPresent"] is False
    elif scenario in {
        "getprop_empty_output",
        "getprop_output_truncated",
        "getprop_malformed_output",
    }:
        assert poll["getpropExitCode"] == 0
        assert poll["systemServerGetpropExitCode"] is None
        assert poll["bootCompletedGetpropExitCode"] is None
        assert poll["systemServerStartCount"] is None
        assert poll["systemServerStartCountPresent"] is None
        assert poll["sysBootCompleted"] is None
        assert poll["sysBootCompletedPresent"] is None
    else:
        assert poll["getpropExitCode"] is None
        assert poll["systemServerGetpropExitCode"] is None
        assert poll["bootCompletedGetpropExitCode"] is None
        assert poll["systemServerStartCount"] is None
        assert poll["systemServerStartCountPresent"] is None
        assert poll["sysBootCompleted"] is None
        assert poll["sysBootCompletedPresent"] is None
    assert poll["commandTimedOut"] is expected_command_timed_out
    assert poll["pollDeadlineReached"] is expected_deadline_reached
    if scenario in {"getstate_failed", "getstate_other"}:
        assert "private-device-name" not in output.read_text(encoding="ascii")
    assert OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER.decode("ascii") not in output.read_text(
        encoding="ascii"
    )
    assert "593" not in output.read_text(encoding="ascii")
    assert len(calls) == expected_call_count
    assert output_limits == [OBSERVER_MODULE.ADB_COMMAND_MAX_OUTPUT_BYTES] * expected_call_count
    assert timeouts[:2] == [OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS] * min(
        expected_call_count,
        2,
    )
    if expected_call_count >= 3:
        assert timeouts[2] == OBSERVER_MODULE.ADB_GETPROP_TIMEOUT_SECONDS
    expected_shell_command = (
        OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND
        if expected_shell_probe_attempted
        else OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND
        if expected_getprop_attempted
        else None
    )
    shell_commands = [command[-3:] for command in launched_commands if command[-3:-2] == ["sh"]]
    assert (
        any(command == ["sh", "-c", expected_shell_command] for command in shell_commands)
        if expected_shell_command is not None
        else not shell_commands
    )


def test_boot_observer_backs_off_timed_out_guest_property_queries(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer._shell_probe_attempted = True
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    property_calls = 0

    class FakeClock:
        current = 0.0

        def monotonic(self) -> float:
            return self.current

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    clock = FakeClock()
    monkeypatch.setattr(OBSERVER_MODULE, "time", clock)

    def bounded_result(
        exit_code: int | None,
        output_text: str = "",
        *,
        timed_out: bool = False,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        return exit_code, output_text.encode(), timed_out, True, False, True, False

    def fake_run_adb(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline, timeout_seconds, max_output_bytes
        nonlocal property_calls
        if "connect" in command:
            return bounded_result(0)
        if command[-1:] == ["get-state"]:
            return bounded_result(0, "device")
        if command[-1:] == [OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND]:
            property_calls += 1
            if property_calls <= 3:
                return bounded_result(None, timed_out=True)
            return bounded_result(
                0,
                "boot_completed=0\nboot_completed_status=0\n"
                "system_server=1\nsystem_server_status=0\n",
            )
        raise AssertionError(f"unexpected adb command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_adb)

    def poll_at(timestamp: float) -> dict[str, object]:
        clock.current = timestamp
        assert observer._record_adb_poll(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            1_000.0,
        )
        record = _read_records(output)[-1]
        assert record["connectAttempted"] is True
        assert record["getStateAttempted"] is True
        return record

    try:
        first_timeout = poll_at(0.0)
        first_deferred = poll_at(15.0)
        second_timeout = poll_at(30.0)
        second_deferred = poll_at(45.0)
        third_deferred = poll_at(60.0)
        fourth_deferred = poll_at(75.0)
        third_timeout = poll_at(90.0)
        fifth_deferred = poll_at(105.0)
        recovered = poll_at(150.0)
        regular_poll = poll_at(165.0)
    finally:
        observer.close()
        adb_socket.close()

    assert first_timeout["getpropAttempted"] is True
    assert first_timeout["getpropTimedOut"] is True
    assert first_timeout["getpropRetryInSeconds"] == 30
    assert first_deferred["getpropAttempted"] is False
    assert first_deferred["getpropTimedOut"] is None
    assert first_deferred["getpropRetryInSeconds"] == 15
    assert second_timeout["getpropTimedOut"] is True
    assert second_timeout["getpropRetryInSeconds"] == 60
    assert second_deferred["getpropRetryInSeconds"] == 45
    assert third_deferred["getpropRetryInSeconds"] == 30
    assert fourth_deferred["getpropRetryInSeconds"] == 15
    assert third_timeout["getpropTimedOut"] is True
    assert third_timeout["getpropRetryInSeconds"] == 60
    assert fifth_deferred["getpropRetryInSeconds"] == 45
    assert recovered["getpropAttempted"] is True
    assert recovered["getpropTimedOut"] is False
    assert recovered["getpropRetryInSeconds"] is None
    assert regular_poll["getpropAttempted"] is True
    assert property_calls == 5


@pytest.mark.parametrize(
    ("probe_outcome", "expected_marker_match", "expected_exit_code", "expected_timed_out"),
    (
        ("success", True, 0, False),
        ("timeout_with_marker", True, None, True),
        ("timeout_without_marker", False, None, True),
        ("exit_without_marker", False, 0, False),
    ),
)
def test_regular_adb_shell_marker_probe_runs_only_once(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    probe_outcome: str,
    expected_marker_match: bool,
    expected_exit_code: int | None,
    expected_timed_out: bool,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    calls: list[list[str]] = []
    shell_probe_client_calls = 0
    shell_probe_launches = 0

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline, timeout_seconds, max_output_bytes
        calls.append(command)
        if "connect" in command:
            return 0, b"", False, True, False, True, False
        if command[-1:] == ["get-state"]:
            return 0, b"device\n", False, True, False, True, False
        if command[-3:] == ["sh", "-c", OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND]:
            nonlocal shell_probe_client_calls, shell_probe_launches
            shell_probe_client_calls += 1
            if shell_probe_client_calls == 1:
                return None, b"", False, False, False, True, False
            shell_probe_launches += 1
            if probe_outcome in {"success", "timeout_with_marker"}:
                return (
                    0 if probe_outcome == "success" else None,
                    OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER + b"\n",
                    probe_outcome == "timeout_with_marker",
                    True,
                    False,
                    True,
                    False,
                )
            return (
                0 if probe_outcome == "exit_without_marker" else None,
                b"" if probe_outcome == "exit_without_marker" else b" ",
                probe_outcome == "timeout_without_marker",
                True,
                False,
                True,
                False,
            )
        if command[-3:] == [
            "sh",
            "-c",
            OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND,
        ]:
            return (
                0,
                b"boot_completed=1\nboot_completed_status=0\n"
                b"system_server=2\nsystem_server_status=0",
                False,
                True,
                False,
                True,
                False,
            )
        raise AssertionError(f"unexpected adb command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        for _ in range(3):
            assert observer._record_adb_poll(
                "localfilesystem:/tmp/adb.sock",
                "127.0.0.1:6520",
                LiveServer(),  # type: ignore[arg-type]
                socket_path,
                time.monotonic() + 5,
            )
    finally:
        observer.close()
        adb_socket.close()

    polls = [record for record in _read_records(output) if record["event"] == "adb_poll"]
    assert [poll["shellProbeAttempted"] for poll in polls] == [False, True, False]
    assert [poll["shellProbeMarkerMatched"] for poll in polls] == [
        None,
        expected_marker_match,
        None,
    ]
    assert [poll["getpropAttempted"] for poll in polls] == [False, False, True]
    assert polls[0]["getpropExitCode"] is None
    assert polls[1]["getpropExitCode"] is None
    assert polls[1]["shellProbeExitCode"] == expected_exit_code
    assert polls[1]["shellProbeTimedOut"] is expected_timed_out
    assert polls[2]["sysBootCompleted"] is True
    assert shell_probe_client_calls == 2
    assert shell_probe_launches == 1
    assert (
        sum(
            command[-3:] == ["sh", "-c", OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND]
            for command in calls
        )
        == 2
    )


@pytest.mark.parametrize(
    ("failed_stage", "expected_call_count"),
    (
        ("connect", 1),
        ("get-state", 2),
        ("shellProbe", 3),
        ("getprop", 3),
    ),
)
def test_regular_adb_poll_fails_closed_when_client_cleanup_is_unverified(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    failed_stage: str,
    expected_call_count: int,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    if failed_stage == "getprop":
        observer._shell_probe_attempted = True
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    calls: list[list[str]] = []

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline, timeout_seconds, max_output_bytes
        calls.append(command)
        stage = (
            "connect"
            if "connect" in command
            else "get-state"
            if command[-1:] == ["get-state"]
            else "shellProbe"
            if command[-3:] == ["sh", "-c", OBSERVER_MODULE.ADB_SHELL_PROBE_COMMAND]
            else "getprop"
        )
        output_bytes = (
            b"boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0"
            if stage == "getprop"
            else OBSERVER_MODULE.ADB_SHELL_PROBE_MARKER + b"\n"
            if stage == "shellProbe"
            else b"device\n"
            if stage == "get-state"
            else b""
        )
        return 0, output_bytes, False, True, False, stage != failed_stage, False

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        assert observer._record_adb_poll(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            time.monotonic() + 5,
        )
        with pytest.raises(OSError, match="did not complete child cleanup"):
            observer.close()
    finally:
        if not observer._closed:
            observer.close()
        adb_socket.close()

    poll = next(record for record in _read_records(output) if record["event"] == "adb_poll")
    cleanup_fields = {
        "connect": "connectCleanupComplete",
        "get-state": "getStateCleanupComplete",
        "shellProbe": "shellProbeCleanupComplete",
        "getprop": "getpropCleanupComplete",
    }
    assert len(calls) == expected_call_count
    assert poll["cleanupComplete"] is False
    assert poll[cleanup_fields[failed_stage]] is False
    assert poll["sysBootCompleted"] is None


def test_regular_adb_poll_does_not_parse_truncated_property_output(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer._shell_probe_attempted = True
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int | None, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline, timeout_seconds, max_output_bytes
        if "connect" in command:
            return 0, b"", False, True, False, True, False
        if command[-1:] == ["get-state"]:
            return 0, b"device\n", False, True, False, True, False
        return (
            0,
            b"boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0",
            False,
            True,
            True,
            True,
            False,
        )

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        assert observer._record_adb_poll(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            time.monotonic() + 5,
        )
    finally:
        observer.close()
        adb_socket.close()

    poll = next(record for record in _read_records(output) if record["event"] == "adb_poll")
    assert poll["getpropTruncated"] is True
    assert poll["getpropCleanupComplete"] is True
    assert poll["sysBootCompleted"] is None
    assert poll["systemServerStartCount"] is None


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
            str(observer.instance_path_link),
            str(launcher_log),
            str(output),
            str(observer.adb_path),
            str(observer.crosvm_command_path),
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

    result = BootObserver._run_adb_bounded(
        [str(fake_adb), "get-state"],
        {},
        time.monotonic() - 1,
        timeout_seconds=OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS,
        max_output_bytes=OBSERVER_MODULE.ADB_COMMAND_MAX_OUTPUT_BYTES,
    )

    assert result == (None, b"", False, False, False, True, False)
    assert not marker.exists()


def test_adb_poll_reserve_covers_command_and_process_group_cleanup_bounds() -> None:
    cleanup_timeout = (
        OBSERVER_MODULE.ADB_CLIENT_TERMINATE_SECONDS + OBSERVER_MODULE.ADB_CLIENT_KILL_SECONDS * 2
    )
    expected_reserve = (
        OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS * 2
        + OBSERVER_MODULE.ADB_GETPROP_TIMEOUT_SECONDS
        + OBSERVER_MODULE.SYSTEM_SERVER_THREAD_TIMEOUT_SECONDS
        + cleanup_timeout * 4
        + 4.0
    )

    assert OBSERVER_MODULE.ADB_POLL_FINAL_RESERVE_SECONDS == expected_reserve


@pytest.mark.parametrize(
    ("suffix", "timed_out", "expected_properties"),
    (
        ("\r", False, (None, None, True, True, None, 0)),
        ("\n\n", False, (None, None, None, None, None, None)),
        ("\r", True, (None, None, True, True, None, 0)),
        ("\n\n", True, (None, None, None, None, None, None)),
    ),
)
def test_boot_observer_preserves_adb_property_reply_framing(
    suffix: str,
    timed_out: bool,
    expected_properties: tuple[
        int | None, bool | None, bool | None, bool | None, int | None, int | None
    ],
) -> None:
    raw_output = (
        "boot_completed=1\nboot_completed_status=0\n"
        "system_server=2\nsystem_server_status=0" + suffix
    )

    assert (
        OBSERVER_MODULE.parse_boot_properties(
            raw_output,
            allow_truncated_tail=timed_out,
        )
        == expected_properties
    )


def test_boot_observer_preserves_partial_boot_properties_on_timeout() -> None:
    raw_output = "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_stat"
    assert OBSERVER_MODULE.parse_boot_properties(raw_output) == (
        None,
        None,
        None,
        None,
        None,
        None,
    )
    assert OBSERVER_MODULE.parse_boot_properties(
        raw_output,
        allow_truncated_tail=True,
    ) == (
        None,
        None,
        True,
        True,
        None,
        0,
    )


def test_boot_property_shell_query_sanitizes_multiline_property_values(
    tmp_path: Path,
) -> None:
    fake_getprop_directory = tmp_path / "fake-android-bin"
    fake_getprop_directory.mkdir()
    fake_getprop = fake_getprop_directory / "getprop"
    fake_getprop.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "if sys.argv[-1] == 'sys.system_server.start_count':\n"
        "    print('2\\nsystem_server_status=0\\nboot_completed=1\\n"
        "boot_completed_status=0')\n"
        "elif sys.argv[-1] == 'sys.boot_completed':\n"
        "    sys.stdout.write('0\\r\\n')\n"
        "else:\n"
        "    raise SystemExit(64)\n",
        encoding="utf-8",
    )
    fake_getprop.chmod(0o700)
    environment = os.environ.copy()
    environment["PATH"] = str(fake_getprop_directory) + os.pathsep + environment.get("PATH", "")

    result = subprocess.run(
        ["/bin/sh", "-c", OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        check=False,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout == (
        "boot_completed=invalid\n"
        "boot_completed_status=0\n"
        "system_server=invalid\n"
        "system_server_status=0\n"
    )
    assert OBSERVER_MODULE.parse_boot_properties(result.stdout) == (
        None,
        True,
        None,
        True,
        0,
        0,
    )


def test_boot_property_shell_emits_boot_completion_before_server_query(
    tmp_path: Path,
) -> None:
    fake_getprop_directory = tmp_path / "fake-android-bin"
    fake_getprop_directory.mkdir()
    server_query_started = tmp_path / "server-query-started"
    fake_getprop = fake_getprop_directory / "getprop"
    fake_getprop.write_text(
        f"#!{sys.executable}\n"
        "import os, sys, time\n"
        "from pathlib import Path\n"
        "if sys.argv[-1] == 'sys.boot_completed':\n"
        "    print('1')\n"
        "elif sys.argv[-1] == 'sys.system_server.start_count':\n"
        "    Path(os.environ['SERVER_QUERY_STARTED']).write_text('started')\n"
        "    time.sleep(30)\n"
        "else:\n"
        "    raise SystemExit(64)\n",
        encoding="utf-8",
    )
    fake_getprop.chmod(0o700)
    environment = os.environ.copy()
    environment["PATH"] = str(fake_getprop_directory) + os.pathsep + environment.get("PATH", "")
    environment["SERVER_QUERY_STARTED"] = str(server_query_started)
    process = subprocess.Popen(
        ["/bin/sh", "-c", OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not server_query_started.exists():
            time.sleep(0.01)
        assert server_query_started.exists()
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        stdout, _ = process.communicate(timeout=2)

    assert stdout == b"boot_completed=1\nboot_completed_status=0\n"
    assert OBSERVER_MODULE.parse_boot_properties(stdout.decode("ascii")) == (
        None,
        None,
        True,
        True,
        None,
        0,
    )


def test_boot_property_shell_query_rejects_property_value_ending_in_newline(
    tmp_path: Path,
) -> None:
    fake_getprop_directory = tmp_path / "fake-android-bin"
    fake_getprop_directory.mkdir()
    fake_getprop = fake_getprop_directory / "getprop"
    fake_getprop.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "if sys.argv[-1] == 'sys.system_server.start_count':\n"
        "    sys.stdout.write('2\\n')\n"
        "elif sys.argv[-1] == 'sys.boot_completed':\n"
        "    sys.stdout.write('1\\n\\n')\n"
        "else:\n"
        "    raise SystemExit(64)\n",
        encoding="utf-8",
    )
    fake_getprop.chmod(0o700)
    environment = os.environ.copy()
    environment["PATH"] = str(fake_getprop_directory) + os.pathsep + environment.get("PATH", "")

    result = subprocess.run(
        ["/bin/sh", "-c", OBSERVER_MODULE.BOOT_PROPERTIES_SHELL_COMMAND],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        check=False,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout == (
        "boot_completed=invalid\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0\n"
    )
    assert OBSERVER_MODULE.parse_boot_properties(result.stdout) == (
        2,
        True,
        None,
        True,
        0,
        0,
    )


def test_summarize_logcat_events_counts_only_selected_event_tags() -> None:
    output = (
        b"06-15 12:00:00.000  1000  1000 I am_proc_start: "
        b"[987654, 12345, 12345, 1000, system_server]\n"
        b"06-15 12:00:01.000  1000  1000 I am_proc_died: "
        b"[987654, 12345, system_server]\n"
        b"06-15 12:00:02.000  1000  1000 I am_proc_crashed: "
        b"[765432, com.private.app]\n"
        b"06-15 12:00:03.000  1000  1000 I am_anr: [765432, com.private.app]\n"
        b"06-15 12:00:04.000  1000  1000 I am_kill: [4321, zygote64]\n"
        b"06-15 12:00:05.000  1000  1000 I unrelated_event: [system_server]\n"
    )

    assert OBSERVER_MODULE.summarize_logcat_events(output) == {
        "recognizedEvents": 5,
        "processStartEvents": 1,
        "processExitEvents": 2,
        "processCrashEvents": 1,
        "anrEvents": 1,
        "systemServerMentionEvents": 2,
        "systemServerMentionStartEvents": 1,
        "systemServerMentionExitEvents": 1,
        "systemServerMentionCrashEvents": 0,
        "systemServerMentionAnrEvents": 0,
        "systemServerMentionKillEvents": 0,
        "zygoteMentionEvents": 1,
        "zygoteMentionStartEvents": 0,
        "zygoteMentionExitEvents": 0,
        "zygoteMentionCrashEvents": 0,
        "zygoteMentionAnrEvents": 0,
        "zygoteMentionKillEvents": 1,
    }


def test_summarize_android_logcat_counts_fixed_markers_without_retaining_text() -> None:
    output = (
        b"06-15 12:00:00.000  1000  1000 E AndroidRuntime: "
        b"FATAL EXCEPTION: main package=com.private.app system_server\n"
        b"06-15 12:00:01.000  1000  1000 F libc: Fatal signal 11 (SIGSEGV)\n"
        b"06-15 12:00:02.000  1000  1000 E ActivityManager: ANR in com.private.app\n"
        b"06-15 12:00:03.000  1000  1000 W Watchdog: subject=private-value\n"
        b"06-15 12:00:04.000  1000  1000 I ActivityManager: zygote64 is ready\n"
    )

    summary = OBSERVER_MODULE.summarize_android_logcat(output)

    assert summary == {
        "fatalExceptionLines": 1,
        "fatalSignalLines": 1,
        "anrTextLines": 1,
        "watchdogMentionLines": 1,
        "systemServerMentionLines": 1,
        "zygoteMentionLines": 1,
    }
    assert all(isinstance(value, int) for value in summary.values())


@pytest.mark.parametrize(
    (
        "output",
        "expected_count",
        "expected_start_count_present",
        "expected_boot_completed",
        "expected_boot_completed_present",
        "expected_system_server_exit_code",
        "expected_boot_completed_exit_code",
    ),
    (
        (
            "boot_completed=0\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0",
            2,
            True,
            False,
            True,
            0,
            0,
        ),
        (
            "boot_completed=\nboot_completed_status=0\nsystem_server=\nsystem_server_status=0",
            None,
            False,
            None,
            False,
            0,
            0,
        ),
        (
            "boot_completed=invalid\r\nboot_completed_status=0\n"
            "system_server=invalid\r\nsystem_server_status=0",
            None,
            True,
            None,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\r\nboot_completed_status=0\r\n"
            "system_server=2\r\nsystem_server_status=0\r\n",
            2,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0\r",
            None,
            None,
            True,
            True,
            None,
            0,
        ),
        (
            "system_server_status=0\nboot_completed=unexpected\nboot_completed_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\n"
            "system_server=2\nunexpected output\nsystem_server_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "system_server_status=0\nboot_completed_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0\n",
            2,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=",
            None,
            None,
            True,
            True,
            None,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\n"
            "system_server=2147483648\nsystem_server_status=0",
            None,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=１\nsystem_server_status=0",
            None,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=abc\nsystem_server_status=0",
            None,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=1\nsystem_server=2\nsystem_server_status=0",
            2,
            True,
            None,
            None,
            0,
            1,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=0",
            2,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=1\nsystem_server_status=0",
            1,
            True,
            True,
            True,
            0,
            0,
        ),
        (
            "system_server=1\nsystem_server=2\nsystem_server_status=0\n"
            "boot_completed=1\nboot_completed_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "boot_completed=0\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=7",
            None,
            None,
            False,
            True,
            7,
            0,
        ),
        (
            "boot_completed=1\nboot_completed_status=7\nsystem_server=2\nsystem_server_status=0",
            2,
            True,
            None,
            None,
            0,
            7,
        ),
        (
            "boot_completed=1\nboot_completed_status=0\nsystem_server=2\nsystem_server_status=256",
            None,
            None,
            True,
            True,
            None,
            0,
        ),
        (
            "system_server=2\nsystem_server_status=0\n"
            "system_server_status=7\nboot_completed=1\nboot_completed_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "boot_completed=1\nsystem_server_status=0\nboot_completed_status=0\n"
            "system_server_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "system_server_status=0\nboot_completed=0\nboot_completed=1\nboot_completed_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
        (
            "system_server=2\nboot_completed=1\nboot_completed_status=0\nsystem_server_status=0",
            None,
            None,
            None,
            None,
            None,
            None,
        ),
    ),
)
def test_parse_boot_properties_keeps_only_bounded_allowlisted_values(
    output: str,
    expected_count: int | None,
    expected_start_count_present: bool | None,
    expected_boot_completed: bool | None,
    expected_boot_completed_present: bool | None,
    expected_system_server_exit_code: int | None,
    expected_boot_completed_exit_code: int | None,
) -> None:
    assert OBSERVER_MODULE.parse_boot_properties(output) == (
        expected_count,
        expected_start_count_present,
        expected_boot_completed,
        expected_boot_completed_present,
        expected_system_server_exit_code,
        expected_boot_completed_exit_code,
    )


def test_bounded_adb_logcat_caps_stdout_and_reaps_the_client(tmp_path: Path) -> None:
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\nimport os\nwhile True:\n    os.write(1, b'x' * 4096)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)

    exit_code, output, timed_out, attempted, truncated, cleanup_complete, probe_error = (
        BootObserver._run_adb_bounded(
            [str(fake_adb)],
            {},
            time.monotonic() + 5,
            timeout_seconds=2,
            max_output_bytes=1024,
        )
    )

    assert exit_code is not None
    assert output == b"x" * 1024
    assert not timed_out
    assert attempted
    assert truncated
    assert cleanup_complete
    assert not probe_error


def test_bounded_adb_logcat_terminates_a_timed_out_client(tmp_path: Path) -> None:
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\n"
        "import signal, time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "time.sleep(30)\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)

    started = time.monotonic()
    exit_code, output, timed_out, attempted, truncated, cleanup_complete, probe_error = (
        BootObserver._run_adb_bounded(
            [str(fake_adb)],
            {},
            started + 5,
            timeout_seconds=0.1,
            max_output_bytes=1024,
        )
    )

    assert exit_code is not None
    assert output == b""
    assert timed_out
    assert attempted
    assert not truncated
    assert cleanup_complete
    assert not probe_error
    assert time.monotonic() - started < 3


def test_bounded_adb_logcat_reaps_descendant_holding_stdout_open(tmp_path: Path) -> None:
    child_pid_file = tmp_path / "child.pid"
    fake_adb = tmp_path / "fake-adb"
    fake_adb.write_text(
        f"#!{sys.executable}\n"
        "import subprocess, sys\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([\n"
        "    sys.executable, '-c',\n"
        "    'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "time.sleep(30)',\n"
        "])\n"
        f"Path({str(child_pid_file)!r}).write_text(str(child.pid), encoding='ascii')\n",
        encoding="utf-8",
    )
    fake_adb.chmod(0o700)

    exit_code, output, timed_out, attempted, truncated, cleanup_complete, probe_error = (
        BootObserver._run_adb_bounded(
            [str(fake_adb)],
            {},
            time.monotonic() + 5,
            timeout_seconds=0.75,
            max_output_bytes=1024,
        )
    )

    assert exit_code == 0
    assert output == b""
    assert timed_out
    assert attempted
    assert not truncated
    assert cleanup_complete
    assert not probe_error
    child_pid = int(child_pid_file.read_text(encoding="ascii"))
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        try:
            os.kill(child_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        pytest.fail("logcat descendant survived bounded ADB cleanup")


def test_final_logcat_summary_is_one_shot_and_does_not_store_event_payloads(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output_path, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    bounded_calls: list[list[str]] = []
    event_output = (
        b"06-15 12:00:00.000  1000  1000 I am_proc_died: "
        b"[987654, 12345, system_server]\n"
        b"06-15 12:00:01.000  1000  1000 I am_proc_crashed: "
        b"[765432, com.private.app]\n"
        b"06-15 12:00:02.000  1000  1000 I am_proc_start: "
        b"[4321, zygote64]\n"
    )
    android_output = (
        b"06-15 12:00:03.000  1000  1000 I am_proc_start: "
        b"[4321, 987654, com.private.app]\n"
        b"06-15 12:00:04.000  1000  1000 E AndroidRuntime: "
        b"FATAL EXCEPTION: main package=com.private.app\n"
        b"06-15 12:00:05.000  1000  1000 W Watchdog: subject=private-value\n"
    )

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline
        bounded_calls.append(command)
        if "connect" in command:
            assert timeout_seconds == OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS
            assert max_output_bytes == OBSERVER_MODULE.ADB_COMMAND_MAX_OUTPUT_BYTES
            return 0, b"connected", False, True, False, True, False
        if command[-1:] == ["get-state"]:
            assert timeout_seconds == OBSERVER_MODULE.ADB_COMMAND_TIMEOUT_SECONDS
            assert max_output_bytes == OBSERVER_MODULE.ADB_COMMAND_MAX_OUTPUT_BYTES
            return 0, b"device\n", False, True, False, True, False
        if "logcat" in command and "events" in command:
            assert timeout_seconds == OBSERVER_MODULE.ADB_LOGCAT_TIMEOUT_SECONDS
            assert max_output_bytes == OBSERVER_MODULE.ADB_LOGCAT_MAX_BYTES
            return 0, event_output, False, True, False, True, False
        if "logcat" in command and "main" in command:
            assert timeout_seconds == OBSERVER_MODULE.ADB_LOGCAT_TIMEOUT_SECONDS
            assert max_output_bytes == OBSERVER_MODULE.ADB_LOGCAT_MAX_BYTES
            return 0, android_output, False, True, False, True, False
        raise AssertionError(f"unexpected ADB command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        for _ in range(2):
            observer._record_final_logcat_summary(
                "localfilesystem:/tmp/adb.sock",
                "127.0.0.1:6520",
                {},
                LiveServer(),  # type: ignore[arg-type]
                socket_path,
                time.monotonic() + 60,
            )
    finally:
        observer.close()
        adb_socket.close()

    records = [
        record for record in _read_records(output_path) if record["event"] == "adb_logcat_summary"
    ]
    assert len(bounded_calls) == 4
    assert "connect" in bounded_calls[0]
    assert bounded_calls[1][-1:] == ["get-state"]
    assert "events" in bounded_calls[2]
    assert "main" in bounded_calls[3]
    assert len(records) == 1
    record = records[0]
    assert record["attempted"]
    assert record["deviceState"] == "device"
    assert record["connectCleanupComplete"] is True
    assert record["getStateCleanupComplete"] is True
    assert record["cleanupComplete"] is True
    assert record["capturedBytes"] == len(event_output)
    assert record["androidLogcat"]["attempted"]
    assert record["androidLogcat"]["capturedBytes"] == len(android_output)
    assert record["androidLogcat"]["summary"] == {
        "fatalExceptionLines": 1,
        "fatalSignalLines": 0,
        "anrTextLines": 0,
        "watchdogMentionLines": 1,
        "systemServerMentionLines": 0,
        "zygoteMentionLines": 0,
    }
    assert record["summary"] == {
        "recognizedEvents": 3,
        "processStartEvents": 1,
        "processExitEvents": 1,
        "processCrashEvents": 1,
        "anrEvents": 0,
        "systemServerMentionEvents": 1,
        "systemServerMentionStartEvents": 0,
        "systemServerMentionExitEvents": 1,
        "systemServerMentionCrashEvents": 0,
        "systemServerMentionAnrEvents": 0,
        "systemServerMentionKillEvents": 0,
        "zygoteMentionEvents": 1,
        "zygoteMentionStartEvents": 1,
        "zygoteMentionExitEvents": 0,
        "zygoteMentionCrashEvents": 0,
        "zygoteMentionAnrEvents": 0,
        "zygoteMentionKillEvents": 0,
    }
    saved_output = output_path.read_text(encoding="utf-8")
    assert "system_server" not in saved_output
    assert "zygote64" not in saved_output
    assert "com.private.app" not in saved_output
    assert "connected" not in saved_output
    assert "987654" not in saved_output
    assert "12345" not in saved_output
    assert "FATAL EXCEPTION" not in saved_output
    assert "private-value" not in saved_output
    assert "06-15 12:00" not in saved_output


def test_final_logcat_summary_skips_guest_when_adb_is_offline(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output_path, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))
    bounded_calls: list[list[str]] = []

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline
        bounded_calls.append(command)
        if "connect" in command:
            return 0, b"", False, True, False, True, False
        if command[-1:] == ["get-state"]:
            return 0, b"offline\n", False, True, False, True, False
        raise AssertionError("logcat must not run when the guest is offline")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        observer._record_final_logcat_summary(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            {},
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            time.monotonic() + 60,
        )
    finally:
        observer.close()
        adb_socket.close()

    records = [
        record for record in _read_records(output_path) if record["event"] == "adb_logcat_summary"
    ]
    assert len(bounded_calls) == 2
    assert "connect" in bounded_calls[0]
    assert bounded_calls[1][-1:] == ["get-state"]
    assert len(records) == 1
    assert not records[0]["attempted"]
    assert records[0]["deviceState"] == "offline"
    assert records[0]["reason"] == "device_unavailable"


@pytest.mark.parametrize(
    "failed_command",
    ["connect", "get-state", "logcat", "android_logcat"],
)
def test_final_probe_fails_close_when_client_cleanup_is_unverified(
    tmp_path: Path,
    short_private_home: Path,
    monkeypatch: pytest.MonkeyPatch,
    failed_command: str,
) -> None:
    proc_root = tmp_path / "proc"
    proc_root.mkdir()
    observer, output_path, _ = _observer(
        tmp_path,
        proc_root=proc_root,
        home_path=short_private_home,
    )
    observer.start()
    socket_path = short_private_home.parent / "adb.sock"
    adb_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    adb_socket.bind(str(socket_path))

    class LiveServer:
        @staticmethod
        def poll() -> None:
            return None

    def fake_run_bounded(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float,
        max_output_bytes: int,
    ) -> tuple[int, bytes, bool, bool, bool, bool, bool]:
        del environment, deadline, timeout_seconds
        del max_output_bytes
        if "connect" in command:
            return 0, b"", False, True, False, failed_command != "connect", False
        if command[-1:] == ["get-state"]:
            return 0, b"device\n", False, True, False, failed_command != "get-state", False
        if "logcat" in command and "events" in command:
            return 0, b"", False, True, False, failed_command != "logcat", False
        if "logcat" in command and "main" in command:
            return 0, b"", False, True, False, failed_command != "android_logcat", False
        raise AssertionError(f"unexpected ADB command: {command!r}")

    monkeypatch.setattr(observer, "_run_adb_bounded", fake_run_bounded)
    try:
        observer._record_final_logcat_summary(
            "localfilesystem:/tmp/adb.sock",
            "127.0.0.1:6520",
            {},
            LiveServer(),  # type: ignore[arg-type]
            socket_path,
            time.monotonic() + 60,
        )
        with pytest.raises(OSError, match="did not complete child cleanup"):
            observer.close()
    finally:
        if not observer._closed:
            observer.close()
        adb_socket.close()

    records = [
        record for record in _read_records(output_path) if record["event"] == "adb_logcat_summary"
    ]
    assert len(records) == 1
    assert records[0]["cleanupComplete"] is False


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


@pytest.mark.parametrize(
    ("scheduled_poll", "after_poll", "expected_next_poll"),
    [
        (100.0, 102.0, 115.0),
        (100.0, 117.0, 130.0),
        (100.0, 132.0, 145.0),
        (100.0, 130.0, 145.0),
    ],
)
def test_adb_poll_schedule_skips_missed_slots_without_drifting(
    scheduled_poll: float,
    after_poll: float,
    expected_next_poll: float,
) -> None:
    assert (
        OBSERVER_MODULE._next_adb_poll_time(scheduled_poll, after_poll, 15.0) == expected_next_poll
    )
