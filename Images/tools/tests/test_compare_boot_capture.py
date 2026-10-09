"""Tests for the VZ capture over the serial shell and the bootconfig records of compare_boot."""

from __future__ import annotations

import gzip
import importlib.util
import re
import socket
import sys
import tempfile
import threading
from pathlib import Path
from types import ModuleType

import pytest

TOOL = Path(__file__).parents[1] / "reference/compare_boot.py"
TOOL_SPEC = importlib.util.spec_from_file_location("compare_boot_capture_module", TOOL)
assert TOOL_SPEC is not None
assert TOOL_SPEC.loader is not None
compare_boot: ModuleType = importlib.util.module_from_spec(TOOL_SPEC)
sys.modules[TOOL_SPEC.name] = compare_boot
TOOL_SPEC.loader.exec_module(compare_boot)


class FakeShell:
    """Stands in for the hvc1 socket: runs each command from a table and answers its sentinel.

    Each reply is `(output, status)`. A silent shell never answers, which models a stuck command.
    """

    def __init__(
        self, directory: Path, replies: dict[str, tuple[str, int]], *, silent: bool = False
    ) -> None:
        self.path = directory / "hvc1.sock"
        self.received: list[str] = []
        self._replies = replies
        self._silent = silent
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(str(self.path))
        self._server.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> FakeShell:
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._server.close()
        self._thread.join(timeout=5)

    def _serve(self) -> None:
        try:
            connection, _ = self._server.accept()
        except OSError:
            return
        with connection:
            pending = b""
            while True:
                try:
                    chunk = connection.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if self._silent:
                        continue
                    text = line.decode()
                    command, _, tail = text.partition("; echo ")
                    self.received.append(command)
                    sentinel = tail.split(" ", 1)[0]
                    output, status = self._replies.get(command, ("", 0))
                    try:
                        connection.sendall(f"{output}{sentinel} {status}\r\n".encode())
                    except OSError:
                        return


def _short_directory() -> Path:
    # A socket path must fit in sockaddr_un, so the temporary directory stays short.
    return Path(tempfile.mkdtemp(prefix="apkrun-cv-", dir="/tmp"))


def _commands(path: Path, lines: list[str]) -> Path:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def test_capture_writes_each_output_gzip_and_the_statuses(tmp_path: Path) -> None:
    directory = _short_directory()
    commands = _commands(
        directory / "guest-capture.txt",
        [
            "# comments and blank lines are skipped",
            "",
            "cmdline.txt\tcat /proc/cmdline",
            "logcat.txt.gz\tlogcat -d -b all",
            "avc-denials.txt\tgrep avc /dev/null",
        ],
    )
    replies = {
        "stty -echo": ("", 0),
        "cat /proc/cmdline": ("console=hvc0\r\n", 0),
        "logcat -d -b all": ("line one\r\nline two\r\n", 0),
        "grep avc /dev/null": ("", 1),
        "stty echo": ("", 0),
    }
    output = tmp_path / "vz-capture"

    with FakeShell(directory, replies) as shell:
        count = compare_boot.capture_vz(shell.path, output, commands_path=commands, timeout=5)

    assert count == 3
    assert (output / "cmdline.txt").read_text(encoding="utf-8") == "console=hvc0\n"
    assert gzip.decompress((output / "logcat.txt.gz").read_bytes()) == b"line one\nline two\n"
    assert (output / "avc-denials.txt").read_text(encoding="utf-8") == ""
    assert (output / "capture-status.txt").read_text(encoding="utf-8") == (
        "cmdline.txt\t0\nlogcat.txt.gz\t0\navc-denials.txt\t1\n"
    )
    assert shell.received[0] == "stty -echo"
    assert shell.received[-1] == "stty echo"


def test_capture_turns_the_shell_echo_off_before_the_commands(tmp_path: Path) -> None:
    directory = _short_directory()
    commands = _commands(directory / "guest-capture.txt", ["mounts.txt\tcat /proc/mounts"])

    with FakeShell(directory, {"cat /proc/mounts": ("rootfs / erofs ro 0 0\n", 0)}) as shell:
        compare_boot.capture_vz(shell.path, tmp_path / "out", commands_path=commands, timeout=5)

    assert shell.received[:2] == ["stty -echo", "cat /proc/mounts"]


def test_capture_refuses_a_path_that_is_not_a_socket(tmp_path: Path) -> None:
    commands = _commands(tmp_path / "commands.txt", ["cmdline.txt\tcat /proc/cmdline"])
    not_a_socket = tmp_path / "hvc1.sock"
    not_a_socket.write_text("", encoding="utf-8")

    with pytest.raises(compare_boot.CaptureToolError, match="is not a socket"):
        compare_boot.capture_vz(not_a_socket, tmp_path / "out", commands_path=commands, timeout=1)


def test_capture_reports_a_missing_socket_as_not_running(tmp_path: Path) -> None:
    commands = _commands(tmp_path / "commands.txt", ["cmdline.txt\tcat /proc/cmdline"])

    with pytest.raises(compare_boot.CaptureToolError, match="no serial shell socket"):
        compare_boot.capture_vz(tmp_path / "missing.sock", tmp_path / "out", commands_path=commands)


def test_capture_times_out_when_the_shell_does_not_answer(tmp_path: Path) -> None:
    directory = _short_directory()
    commands = _commands(directory / "guest-capture.txt", ["cmdline.txt\tcat /proc/cmdline"])

    with FakeShell(directory, {}, silent=True) as shell:
        with pytest.raises(compare_boot.CaptureToolError, match="did not finish"):
            compare_boot.capture_vz(
                shell.path, tmp_path / "out", commands_path=commands, timeout=0.5
            )


def test_capture_rejects_a_command_line_without_an_output_name(tmp_path: Path) -> None:
    commands = _commands(tmp_path / "commands.txt", ["cat /proc/cmdline"])
    with pytest.raises(compare_boot.CaptureToolError, match="TAB"):
        compare_boot._read_guest_commands(commands)


def test_the_reference_command_list_parses() -> None:
    commands = compare_boot._read_guest_commands(compare_boot.GUEST_CAPTURE_PATH)

    names = [name for name, _ in commands]
    assert "cmdline.txt" in names
    assert "bootconfig.txt" in names
    assert len(names) == len(set(names))


@pytest.mark.parametrize(
    ("raw", "value"),
    [
        ('"cutf_cvm";', "cutf_cvm"),
        ('"_a"', "_a"),
        ("1", "1"),
        ("  4096MB  ", "4096MB"),
        ("'quoted'", "quoted"),
        ('"unterminated', '"unterminated'),
    ],
)
def test_bootconfig_values_drop_statement_semicolons_and_quotes(raw: str, value: str) -> None:
    assert compare_boot._bootconfig_value(raw) == value


def test_bootconfig_records_ignore_comments_and_compare_quoted_and_plain_forms(
    tmp_path: Path,
) -> None:
    kernel = tmp_path / "candidate"
    kernel.mkdir()
    (kernel / "bootconfig.txt").write_text(
        "# Parameters from bootloader: console=ttynull\n"
        'androidboot.hardware = "cutf_cvm";\n'
        'androidboot.slot_suffix = "_a";\n',
        encoding="utf-8",
    )
    reference = tmp_path / "reference"
    reference.mkdir()
    (reference / "internal-bootconfig.txt").write_text(
        "androidboot.hardware=cutf_cvm\nandroidboot.slot_suffix=_a\n",
        encoding="utf-8",
    )

    budget = compare_boot._RecordBudget()
    candidate_paths = [kernel / "bootconfig.txt"]
    records = compare_boot._category_records(kernel, "bootconfig", [], budget, candidate_paths)
    reference_records = compare_boot._category_records(
        reference,
        "bootconfig",
        [],
        compare_boot._RecordBudget(),
        [reference / "internal-bootconfig.txt"],
    )

    assert records == {"androidboot.hardware": "cutf_cvm", "androidboot.slot_suffix": "_a"}
    assert records == reference_records
    assert not any(re.match(r"bootconfig\.txt:line", key) for key in records)
