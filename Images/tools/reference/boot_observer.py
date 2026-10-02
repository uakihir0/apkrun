"""Record bounded Cuttlefish Android-guest memory and ADB boot observations."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

START_EVENT_MARKER = b"Start event (5) received."
LAUNCHER_SOURCE = re.compile(rb"^([A-Za-z0-9_.-]+)\(([0-9]+)\)")
SNAPSHOT_TRUNCATION_MARKER = (
    b"[APKRun snapshot truncated; showing the final part of the host log.]\n"
)
MAX_LOG_BYTES = 64 * 1024 * 1024
SAMPLE_INTERVAL_SECONDS = 5.0
ADB_INTERVAL_SECONDS = 15.0
ADB_COMMAND_TIMEOUT_SECONDS = 2.0
# Starting an Android shell can be slower than checking its ADB transport.
ADB_GETPROP_TIMEOUT_SECONDS = 10.0
ADB_SERVER_START_TIMEOUT_SECONDS = 3.0
ADB_CLEANUP_RESERVE_SECONDS = 15.0
ADB_SERVER_SOCKET_LIMIT = 107
ADB_SERVER_EXEC_SCRIPT = """
import ctypes
import os
import signal
import sys

parent_pid = int(sys.argv[1])
adb_path = sys.argv[2]
if os.getppid() != parent_pid:
    os._exit(125)
libc = ctypes.CDLL(None, use_errno=True)
libc.prctl.argtypes = [
    ctypes.c_int,
    ctypes.c_ulong,
    ctypes.c_ulong,
    ctypes.c_ulong,
    ctypes.c_ulong,
]
libc.prctl.restype = ctypes.c_int
if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
    os._exit(125)
if os.getppid() != parent_pid:
    os.kill(os.getpid(), signal.SIGKILL)
os.execv(adb_path, sys.argv[2:])
"""


def _timestamp_utc() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds")


def _proc_identity(path: Path) -> tuple[int, bytes] | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    closing_parenthesis = raw.rfind(b")")
    if closing_parenthesis < 0:
        return None
    fields = raw[closing_parenthesis + 1 :].split()
    if len(fields) <= 19 or not fields[1].isdigit() or not fields[19].isdigit():
        return None
    return int(fields[1]), fields[19]


def _proc_start_time(path: Path) -> bytes | None:
    identity = _proc_identity(path)
    return None if identity is None else identity[1]


def _proc_memory_status(path: Path) -> tuple[int, int | None] | None:
    try:
        content = path.read_bytes()
    except OSError:
        return None
    values: dict[bytes, int] = {}
    for line in content.splitlines():
        name, separator, value = line.partition(b":")
        if not separator or name not in {b"VmRSS", b"RssShmem"}:
            continue
        fields = value.split()
        if len(fields) != 2 or fields[1] != b"kB" or not fields[0].isdigit():
            return None
        values[name] = int(fields[0])
    if b"VmRSS" not in values:
        return None
    return values[b"VmRSS"], values.get(b"RssShmem")


class BootObserver:
    """Observe the Android crosvm process and probe ADB through a private socket."""

    def __init__(
        self,
        *,
        home: Path,
        instance_path: Path,
        launcher_log: Path,
        output_path: Path,
        adb_path: Path,
        adb_port: int,
        crosvm_path: Path,
        proc_root: Path = Path("/proc"),
        sample_interval: float = SAMPLE_INTERVAL_SECONDS,
        adb_interval: float = ADB_INTERVAL_SECONDS,
        deadline: float | None = None,
        background_sampling: bool = False,
    ) -> None:
        if type(adb_port) is not int or not 1 <= adb_port <= 65_535:
            raise ValueError("ADB port is outside the supported range")
        if sample_interval <= 0 or adb_interval <= 0:
            raise ValueError("observer intervals must be positive")
        self.home = home.resolve(strict=True)
        try:
            link_parent = Path(os.path.abspath(instance_path)).parent.resolve(strict=True)
        except OSError:
            raise ValueError("Cuttlefish runtime link parent must exist") from None
        if link_parent != self.home or Path(instance_path).name != "cuttlefish_runtime":
            raise ValueError("Cuttlefish runtime link must be beneath its private HOME") from None
        self.instance_path_link = self.home / "cuttlefish_runtime"
        self.instance_path = self.instance_path_link
        self._instance_path_bytes: bytes | None = None
        self._instance_path_event_recorded = False
        self._instance_path_conflicted = False
        self.launcher_log = launcher_log
        self.output_path = output_path
        self.adb_path = adb_path.resolve(strict=True)
        self.adb_port = adb_port
        self.crosvm_path = crosvm_path.resolve(strict=True)
        self.proc_root = proc_root
        self.sample_interval = sample_interval
        self.adb_interval = adb_interval
        self.deadline = deadline
        self.background_sampling = background_sampling
        self._output_fd: int | None = None
        self._output_lock = threading.Lock()
        self._sample_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._sample_thread: threading.Thread | None = None
        self._adb_thread: threading.Thread | None = None
        self._adb_server_process: subprocess.Popen[bytes] | None = None
        self._launcher_offset = 0
        self._launcher_prefix: bytes | None = None
        self._launcher_tail = b""
        self._launcher_truncated = False
        self._launcher_fragment = bytearray()
        self._crosvm_restarter_pids: set[int] = set()
        self._crosvm_restarter_start_times: dict[int, bytes] = {}
        self._crosvm_start_times: dict[int, bytes] = {}
        self._start_event_observed = False
        self._next_sample = 0.0
        self._closed = False
        self._refresh_instance_path(emit_event=False)

    def start(self) -> None:
        if self._output_fd is not None:
            raise RuntimeError("boot observer has already started")
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_APPEND
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        self._output_fd = os.open(self.output_path, flags, 0o600)
        self._record({"event": "observer_started"})
        if not self._refresh_instance_path():
            self._record(
                {
                    "event": "instance_path_discovery_pending",
                    "reason": "runtime_link_not_ready",
                }
            )
        if self.background_sampling:
            self._sample_thread = threading.Thread(
                target=self._sample_loop,
                name="apkrun-crosvm-memory-observer",
                daemon=True,
            )
            self._sample_thread.start()

    def sample(self, now: float | None = None) -> None:
        with self._sample_lock:
            self._sample(now)

    def _sample(self, now: float | None) -> None:
        if self._output_fd is None or self._closed:
            raise RuntimeError("boot observer is not running")
        self._refresh_launcher_log()
        self._refresh_instance_path()
        observed_at = time.monotonic() if now is None else now
        if observed_at < self._next_sample:
            return
        if self._next_sample == 0:
            self._next_sample = observed_at + self.sample_interval
        else:
            self._next_sample += self.sample_interval
            while self._next_sample <= observed_at:
                self._next_sample += self.sample_interval
        candidate_owners: dict[int, tuple[int, bytes]] = {}
        ambiguous_candidate_pids: set[int] = set()
        for restarter_pid in sorted(self._crosvm_restarter_pids):
            identity = self._read_restarter_children(
                restarter_pid,
                self._crosvm_restarter_start_times.get(restarter_pid),
            )
            if identity is None:
                continue
            children, start_time = identity
            self._crosvm_restarter_start_times.setdefault(restarter_pid, start_time)
            for child_pid in children:
                previous_owner = candidate_owners.get(child_pid)
                if previous_owner is not None and previous_owner[0] != restarter_pid:
                    ambiguous_candidate_pids.add(child_pid)
                else:
                    candidate_owners[child_pid] = (restarter_pid, start_time)
        candidate_pids = set(candidate_owners)
        for stale_pid in self._crosvm_start_times.keys() - candidate_pids:
            self._crosvm_start_times.pop(stale_pid, None)
        candidates: list[dict[str, Any]] = []
        for pid in sorted(candidate_pids - ambiguous_candidate_pids):
            restarter_pid, restarter_start_time = candidate_owners[pid]
            identity = self._read_crosvm_memory(
                pid,
                self._crosvm_start_times.get(pid),
                parent_pid=restarter_pid,
                parent_start_time=restarter_start_time,
            )
            if identity is None:
                continue
            sample, start_time = identity
            self._crosvm_start_times.setdefault(pid, start_time)
            candidates.append(sample)
        if not self._refresh_instance_path():
            candidates.clear()
        if len(candidates) == 1:
            self._record({"event": "crosvm_memory", **candidates[0]})
        else:
            self._record(
                {
                    "event": "crosvm_memory",
                    "identity": "ambiguous" if candidates else "unavailable",
                    "candidateCount": len(candidates),
                }
            )
        if (
            self._start_event_observed
            and self._adb_thread is None
            and not self._stop_event.is_set()
        ):
            self._adb_thread = threading.Thread(
                target=self._poll_adb,
                name="apkrun-private-adb-observer",
                daemon=True,
            )
            self._adb_thread.start()

    def _sample_loop(self) -> None:
        next_sample = time.monotonic()
        while not self._stop_event.is_set():
            now = time.monotonic()
            if now < next_sample:
                if self._stop_event.wait(next_sample - now):
                    return
                now = time.monotonic()
            self.sample(now)
            next_sample += self.sample_interval
            now = time.monotonic()
            while next_sample <= now:
                next_sample += self.sample_interval

    def close(self) -> None:
        if self._closed:
            return
        self._stop_event.set()
        if self._sample_thread is not None:
            self._sample_thread.join(timeout=2)
        if self._adb_thread is not None:
            self._adb_thread.join(timeout=12)
            if self._adb_thread.is_alive():
                server = self._adb_server_process
                if server is not None and server.poll() is None:
                    try:
                        server.kill()
                    except OSError:
                        pass
                self._adb_thread.join(timeout=2)
            if self._adb_thread.is_alive():
                raise OSError("private ADB observer did not stop within its cleanup bound")
        if self._sample_thread is not None and self._sample_thread.is_alive():
            raise OSError("crosvm memory observer did not stop within its cleanup bound")
        if self._output_fd is not None:
            self._refresh_instance_path()
            if self._instance_path_bytes is None:
                self._record(
                    {
                        "event": "instance_path_discovery_failed",
                        "reason": (
                            "runtime_link_changed"
                            if self._instance_path_conflicted
                            else "runtime_link_never_resolved"
                        ),
                    }
                )
            self._record({"event": "observer_stopped"})
            os.close(self._output_fd)
            self._output_fd = None
        self._closed = True

    def _record(self, fields: dict[str, Any]) -> None:
        with self._output_lock:
            if self._output_fd is None:
                return
            record = {"timestampUtc": _timestamp_utc(), **fields}
            encoded = (json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n").encode(
                "ascii"
            )
            pending = memoryview(encoded)
            while pending:
                written = os.write(self._output_fd, pending)
                if written <= 0:
                    raise OSError("could not append boot observer record")
                pending = pending[written:]

    def _clear_launcher_identity(self) -> None:
        self._launcher_fragment.clear()
        self._crosvm_restarter_pids.clear()
        self._crosvm_restarter_start_times.clear()
        self._crosvm_start_times.clear()

    def _resolve_instance_path(self) -> Path | None:
        if not self.instance_path_link.is_symlink():
            return None
        try:
            link_target = os.readlink(self.instance_path_link)
        except OSError:
            return None
        target = Path(link_target)
        managed_root = Path("/var/tmp/cvd")
        instance_match = re.fullmatch(r"cvd-([0-9]+)", target.name)
        if (
            not target.is_absolute()
            or ".." in target.parts
            or not target.is_dir()
            or target.parent.name != "instances"
            or target.parent.parent.name != "cuttlefish"
            or target.parent.parent.parent.name != "home"
            or len(target.parents) < 6
            or target.parents[5] != managed_root
            or target.parents[4].name != str(os.getuid())
            or instance_match is None
            or 6520 + int(instance_match.group(1)) - 1 != self.adb_port
        ):
            return None
        try:
            resolved_target = target.resolve(strict=True)
        except (OSError, RuntimeError):
            return None
        if (
            not resolved_target.is_dir()
            or not resolved_target.is_relative_to(self.home)
            or resolved_target.relative_to(self.home).parts
            != ("cuttlefish", "instances", target.name)
        ):
            return None
        return target

    def _runtime_crosvm_path(self) -> Path | None:
        if self._instance_path_bytes is None:
            return None
        return (
            self.instance_path.parents[3]
            / "artifacts"
            / "host_tools"
            / "bin"
            / self.crosvm_path.name
        )

    def _refresh_instance_path(self, *, emit_event: bool = True) -> bool:
        if self._instance_path_conflicted:
            return False
        resolved = self._resolve_instance_path()
        if resolved is None:
            if self._instance_path_bytes is not None:
                self._instance_path_conflicted = True
                discarded = len(self._crosvm_restarter_pids)
                self._clear_launcher_identity()
                self._instance_path_bytes = None
                self._record(
                    {
                        "event": "instance_path_changed_observation_gap",
                        "reason": "runtime_link_unavailable",
                        "discardedCandidateCount": discarded,
                    }
                )
            return False
        resolved_bytes = os.fsencode(resolved)
        if self._instance_path_bytes is not None:
            if resolved_bytes != self._instance_path_bytes:
                discarded = len(self._crosvm_restarter_pids)
                self._instance_path_bytes = None
                self._record(
                    {
                        "event": "instance_path_changed_observation_gap",
                        "reason": "runtime_target_changed",
                        "discardedCandidateCount": discarded,
                    }
                )
                self._clear_launcher_identity()
                self._instance_path_conflicted = True
                return False
            if emit_event and not self._instance_path_event_recorded:
                self._record({"event": "instance_path_discovered"})
                self._instance_path_event_recorded = True
            return True
        self.instance_path = resolved
        self._instance_path_bytes = resolved_bytes
        if emit_event:
            self._record({"event": "instance_path_discovered"})
            self._instance_path_event_recorded = True
        return True

    def _refresh_launcher_log(self) -> None:
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        try:
            descriptor = os.open(self.launcher_log, flags)
        except FileNotFoundError:
            return
        except OSError:
            return
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_LOG_BYTES:
                return
            current_prefix = os.pread(descriptor, min(metadata.st_size, 4096), 0)
            if current_prefix.startswith(SNAPSHOT_TRUNCATION_MARKER):
                if not self._launcher_truncated:
                    self._record(
                        {
                            "event": "launcher_log_truncated_observation_gap",
                            "discardedCandidateCount": len(self._crosvm_restarter_pids),
                        }
                    )
                self._clear_launcher_identity()
                self._launcher_offset = 0
                self._launcher_prefix = None
                self._launcher_tail = b""
                self._launcher_truncated = True
                return
            self._launcher_truncated = False
            prefix_matches = (
                self._launcher_prefix is None
                or current_prefix[: len(self._launcher_prefix)] == self._launcher_prefix
            )
            tail_matches = True
            if self._launcher_offset and self._launcher_tail:
                tail_start = self._launcher_offset - len(self._launcher_tail)
                current_tail = os.pread(
                    descriptor,
                    len(self._launcher_tail),
                    tail_start,
                )
                tail_matches = current_tail == self._launcher_tail
            replaced = (
                metadata.st_size < self._launcher_offset or not prefix_matches or not tail_matches
            )
            if replaced:
                self._record(
                    {
                        "event": "launcher_log_replaced_observation_gap",
                        "discardedCandidateCount": len(self._crosvm_restarter_pids),
                    }
                )
                self._launcher_offset = 0
                self._launcher_prefix = None
                self._launcher_tail = b""
                self._clear_launcher_identity()
            if self._launcher_prefix is None and current_prefix:
                self._launcher_prefix = current_prefix
            length = metadata.st_size - self._launcher_offset
            if length <= 0:
                return
            chunk = os.pread(descriptor, length, self._launcher_offset)
            self._launcher_offset += len(chunk)
            self._launcher_tail = (self._launcher_tail + chunk)[-4096:]
        finally:
            os.close(descriptor)

        self._launcher_fragment.extend(chunk)
        if START_EVENT_MARKER in self._launcher_fragment:
            if not self._start_event_observed:
                self._start_event_observed = True
                self._record({"event": "cuttlefish_start_event_5_observed"})
        while True:
            newline = self._launcher_fragment.find(b"\n")
            if newline < 0:
                break
            line = bytes(self._launcher_fragment[:newline]).rstrip(b"\r")
            del self._launcher_fragment[: newline + 1]
            source = LAUNCHER_SOURCE.match(line)
            if source is not None and source.group(1) == b"process_restarter":
                self._crosvm_restarter_pids.add(int(source.group(2)))
        if len(self._launcher_fragment) > 65_536:
            self._record(
                {
                    "event": "launcher_log_oversized_line_observation_gap",
                    "discardedCandidateCount": len(self._crosvm_restarter_pids),
                }
            )
            self._launcher_fragment.clear()
            self._clear_launcher_identity()

    def _read_restarter_children(
        self,
        pid: int,
        expected_start_time: bytes | None,
    ) -> tuple[set[int], bytes] | None:
        process = self.proc_root / str(pid)
        before = _proc_start_time(process / "stat")
        if before is None or (expected_start_time is not None and before != expected_start_time):
            return None
        try:
            executable = os.readlink(process / "exe")
            command_line = (process / "cmdline").read_bytes().split(b"\0")
            children = (process / "task" / str(pid) / "children").read_bytes().split()
        except OSError:
            return None
        after = _proc_start_time(process / "stat")
        try:
            separator = command_line.index(b"--")
            requested_crosvm = Path(os.fsdecode(command_line[separator + 1]))
            expected_crosvm = self._runtime_crosvm_path()
            if (
                expected_crosvm is None
                or not requested_crosvm.is_absolute()
                or ".." in requested_crosvm.parts
                or not expected_crosvm.is_file()
            ):
                return None
        except (OSError, ValueError, IndexError):
            return None
        serial_values = [
            command_line[index + 1]
            for index, argument in enumerate(command_line[:-1])
            if argument == b"--serial"
        ]
        serial_values.extend(
            argument.partition(b"=")[2]
            for argument in command_line
            if argument.startswith(b"--serial=")
        )
        if (
            before != after
            or Path(executable).name != "process_restarter"
            or requested_crosvm != expected_crosvm
            or not any(self._argument_matches_instance(argument) for argument in command_line)
            or not any(b"kernel-log-pipe" in value for value in serial_values)
            or any(b"crosvm_openwrt" in argument for argument in command_line)
        ):
            return None
        return {int(child) for child in children if child.isdigit()}, before

    def _read_crosvm_memory(
        self,
        pid: int,
        expected_start_time: bytes | None,
        *,
        parent_pid: int,
        parent_start_time: bytes,
    ) -> tuple[dict[str, Any], bytes] | None:
        process = self.proc_root / str(pid)
        before = _proc_identity(process / "stat")
        if (
            before is None
            or before[0] != parent_pid
            or (expected_start_time is not None and before[1] != expected_start_time)
            or _proc_start_time(self.proc_root / str(parent_pid) / "stat") != parent_start_time
        ):
            return None
        try:
            executable = os.readlink(process / "exe")
            command_line = (process / "cmdline").read_bytes().split(b"\0")
        except OSError:
            return None
        expected_crosvm = self._runtime_crosvm_path()
        if (
            expected_crosvm is None
            or not command_line
            or not any(self._argument_matches_instance(argument) for argument in command_line)
        ):
            return None
        executable_path = Path(executable)
        command_path = Path(os.fsdecode(command_line[0]))
        if (
            not expected_crosvm.is_file()
            or Path(executable).name != self.crosvm_path.name
            or not executable_path.is_absolute()
            or ".." in executable_path.parts
            or not command_path.is_absolute()
            or ".." in command_path.parts
            or command_path != expected_crosvm
        ):
            return None
        try:
            if not os.path.samefile(process / "exe", expected_crosvm):
                return None
        except OSError:
            return None
        memory = _proc_memory_status(process / "status")
        after = _proc_identity(process / "stat")
        if (
            memory is None
            or before != after
            or _proc_start_time(self.proc_root / str(parent_pid) / "stat") != parent_start_time
        ):
            return None
        return (
            {
                "pid": pid,
                "vmRssKiB": memory[0],
                "rssShmemKiB": memory[1],
            },
            before[1],
        )

    def _argument_matches_instance(self, argument: bytes) -> bool:
        if self._instance_path_bytes is None:
            return False
        search_from = 0
        while search_from < len(argument):
            position = argument.find(self._instance_path_bytes, search_from)
            if position < 0:
                return False
            end = position + len(self._instance_path_bytes)
            before = argument[position - 1 : position]
            after = argument[end : end + 1]
            if (not before or before in {b"=", b":", b"/"}) and (
                not after or after in {b"/", b",", b":"}
            ):
                return True
            search_from = position + 1
        return False

    def _adb_environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        for name in (
            "ADB_SERVER_SOCKET",
            "ADB_SERVER_PORT",
            "ADB_VENDOR_KEYS",
            "ANDROID_SERIAL",
        ):
            environment.pop(name, None)
        return environment

    def _poll_adb(self) -> None:
        if self._stop_event.is_set():
            return
        try:
            socket_directory = Path(tempfile.mkdtemp(prefix="apkrun-boot-adb.", dir=self.home))
        except OSError:
            self._record(
                {
                    "event": "adb_observer_unavailable",
                    "reason": "private_socket_directory_creation_failed",
                }
            )
            return
        socket_path = socket_directory / "adb.sock"
        adb_socket = f"localfilesystem:{socket_path}"
        server: subprocess.Popen[bytes] | None = None
        cleanup_complete = True
        adb_deadline = (
            self.deadline - ADB_CLEANUP_RESERVE_SECONDS
            if self.deadline is not None
            else float("inf")
        )
        try:
            if time.monotonic() >= adb_deadline:
                self._record(
                    {
                        "event": "adb_observer_stopped_before_deadline",
                        "reason": "cleanup_reserve",
                    }
                )
                return
            if len(os.fsencode(socket_path)) > ADB_SERVER_SOCKET_LIMIT:
                self._record(
                    {
                        "event": "adb_observer_unavailable",
                        "reason": "private_socket_path_too_long",
                    }
                )
                return
            if (
                socket_directory.is_symlink()
                or not socket_directory.is_dir()
                or stat.S_IMODE(socket_directory.stat().st_mode) != 0o700
            ):
                self._record(
                    {
                        "event": "adb_observer_unavailable",
                        "reason": "private_socket_directory_invalid",
                    }
                )
                return
            if self._stop_event.is_set():
                return
            try:
                adb_command = [
                    str(self.adb_path),
                    "-L",
                    adb_socket,
                    "nodaemon",
                    "server",
                ]
                if sys.platform == "linux":
                    adb_command = [
                        sys.executable,
                        "-c",
                        ADB_SERVER_EXEC_SCRIPT,
                        str(os.getpid()),
                        *adb_command,
                    ]
                server = subprocess.Popen(
                    adb_command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=self._adb_environment(),
                    close_fds=True,
                )
                self._adb_server_process = server
            except OSError:
                self._record({"event": "adb_observer_unavailable", "reason": "server_start_failed"})
                return
            startup_deadline = time.monotonic() + ADB_SERVER_START_TIMEOUT_SECONDS
            while not self._stop_event.is_set() and time.monotonic() < startup_deadline:
                if server.poll() is not None:
                    self._record({"event": "adb_observer_unavailable", "reason": "server_exited"})
                    return
                try:
                    if stat.S_ISSOCK(socket_path.lstat().st_mode):
                        break
                except OSError:
                    pass
                self._stop_event.wait(0.05)
            else:
                if self._stop_event.is_set():
                    return
                self._record(
                    {
                        "event": "adb_observer_unavailable",
                        "reason": "server_start_timed_out",
                    }
                )
                return

            self._record({"event": "private_adb_server_ready"})
            serial = f"127.0.0.1:{self.adb_port}"
            next_poll = time.monotonic()
            cleanup_reserve_reached = False
            while not self._stop_event.is_set():
                now = time.monotonic()
                if now >= adb_deadline:
                    cleanup_reserve_reached = True
                    break
                if now < next_poll:
                    self._stop_event.wait(min(next_poll - now, adb_deadline - now))
                    continue
                if server.poll() is not None or not self._is_socket(socket_path):
                    self._record(
                        {
                            "event": "adb_observer_unavailable",
                            "reason": "server_lost",
                        }
                    )
                    break
                poll_started = time.monotonic()
                if not self._record_adb_poll(
                    adb_socket,
                    serial,
                    server,
                    socket_path,
                    adb_deadline,
                ):
                    self._record(
                        {
                            "event": "adb_observer_unavailable",
                            "reason": "server_lost",
                        }
                    )
                    break
                next_poll = poll_started + self.adb_interval
                after_poll = time.monotonic()
                if next_poll <= after_poll:
                    next_poll = after_poll + self.adb_interval
            if cleanup_reserve_reached:
                self._record(
                    {
                        "event": "adb_observer_stopped_before_deadline",
                        "reason": "cleanup_reserve",
                    }
                )
        finally:
            if server is not None and server.poll() is None:
                try:
                    server.terminate()
                    server.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        server.kill()
                        server.wait(timeout=2)
                    except (OSError, subprocess.TimeoutExpired):
                        if server.poll() is None:
                            cleanup_complete = False
                except OSError:
                    if server.poll() is None:
                        cleanup_complete = False
            if socket_path.exists() or socket_path.is_symlink():
                try:
                    if stat.S_ISSOCK(socket_path.lstat().st_mode):
                        socket_path.unlink()
                    else:
                        cleanup_complete = False
                except OSError:
                    cleanup_complete = False
            try:
                socket_directory.rmdir()
            except FileNotFoundError:
                pass
            except OSError:
                cleanup_complete = False
            if server is not None:
                self._record(
                    {
                        "event": "private_adb_server_stopped",
                        "cleanupComplete": cleanup_complete,
                    }
                )
            if self._adb_server_process is server:
                self._adb_server_process = None

    @staticmethod
    def _is_socket(path: Path) -> bool:
        try:
            return stat.S_ISSOCK(path.lstat().st_mode)
        except OSError:
            return False

    def _record_adb_poll(
        self,
        adb_socket: str,
        serial: str,
        server: subprocess.Popen[bytes],
        socket_path: Path,
        adb_deadline: float,
    ) -> bool:
        if server.poll() is not None or not self._is_socket(socket_path):
            return False
        environment = self._adb_environment()
        connect_code, _, connect_timed_out, _ = self._run_adb(
            [str(self.adb_path), "-L", adb_socket, "connect", serial],
            environment,
            adb_deadline,
        )
        if time.monotonic() >= adb_deadline:
            self._record(
                {
                    "event": "adb_poll",
                    "connectExitCode": connect_code,
                    "deviceState": None,
                    "getpropExitCode": None,
                    "getpropAttempted": False,
                    "getpropTimedOut": None,
                    "sysBootCompleted": None,
                    "commandTimedOut": connect_timed_out,
                    "pollDeadlineReached": True,
                }
            )
            return True
        if server.poll() is not None or not self._is_socket(socket_path):
            return False
        state_code, state_output, state_timed_out, _ = self._run_adb(
            [str(self.adb_path), "-L", adb_socket, "-s", serial, "get-state"],
            environment,
            adb_deadline,
        )
        state = (
            state_output
            if state_code == 0 and state_output in {"device", "offline", "unauthorized"}
            else None
        )
        property_code: int | None = None
        boot_completed: bool | None = None
        property_attempted = False
        property_timed_out: bool | None = None
        property_command_timed_out = False
        if state == "device" and (server.poll() is not None or not self._is_socket(socket_path)):
            return False
        if time.monotonic() >= adb_deadline:
            self._record(
                {
                    "event": "adb_poll",
                    "connectExitCode": connect_code,
                    "deviceState": state,
                    "getpropExitCode": None,
                    "getpropAttempted": False,
                    "getpropTimedOut": None,
                    "sysBootCompleted": None,
                    "commandTimedOut": (connect_timed_out or state_timed_out),
                    "pollDeadlineReached": True,
                }
            )
            return True
        if state == "device":
            (
                property_code,
                property_output,
                property_command_timed_out,
                property_attempted,
            ) = self._run_adb(
                [
                    str(self.adb_path),
                    "-L",
                    adb_socket,
                    "-s",
                    serial,
                    "shell",
                    "getprop",
                    "sys.boot_completed",
                ],
                environment,
                adb_deadline,
                timeout_seconds=ADB_GETPROP_TIMEOUT_SECONDS,
            )
            if property_attempted:
                property_timed_out = property_command_timed_out
            if property_code == 0 and property_output in {"0", "1"}:
                boot_completed = property_output == "1"
        self._record(
            {
                "event": "adb_poll",
                "connectExitCode": connect_code,
                "deviceState": state,
                "getpropExitCode": property_code,
                "getpropAttempted": property_attempted,
                "getpropTimedOut": property_timed_out,
                "sysBootCompleted": boot_completed,
                "commandTimedOut": (
                    connect_timed_out or state_timed_out or property_command_timed_out
                ),
                "pollDeadlineReached": time.monotonic() >= adb_deadline,
            }
        )
        return True

    @staticmethod
    def _run_adb(
        command: list[str],
        environment: dict[str, str],
        deadline: float,
        *,
        timeout_seconds: float = ADB_COMMAND_TIMEOUT_SECONDS,
    ) -> tuple[int | None, str, bool, bool]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, "", False, False
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=environment,
                timeout=min(timeout_seconds, remaining),
                check=False,
            )
        except subprocess.TimeoutExpired:
            return None, "", True, True
        except OSError:
            return None, "", False, False
        output = completed.stdout.decode("utf-8", errors="replace").strip()
        return completed.returncode, output, False, True
