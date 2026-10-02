from __future__ import annotations

import errno
import json
import os
import pty
import runpy
import select
import signal
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

HELPER = Path(__file__).parents[1] / "drive_cuttlefish_console.py"
CONSOLE_MODULE = runpy.run_path(str(HELPER))
pytestmark = pytest.mark.skipif(
    sys.platform != "linux",
    reason="the Cuttlefish reference console helper runs on Linux",
)


def _private_home(tmp_path: Path) -> Path:
    home = tmp_path / "cvd-home"
    runtime = home / "cuttlefish_runtime"
    runtime.mkdir(parents=True, mode=0o700)
    (runtime / "console").touch(mode=0o600)
    home.chmod(0o700)
    runtime.chmod(0o700)
    return home


def _screen_stub(tmp_path: Path, body: str) -> Path:
    program = tmp_path / "fake-screen"
    program.write_text(
        f"#!/usr/bin/env python3\nimport os\nimport re\nimport time\n{body}\n",
        encoding="utf-8",
    )
    program.chmod(0o700)
    return program


def _memory_probe_preparation_reader(
    response_line: bytes = b"APKRUN_PROBE_READY",
) -> str:
    preparation_command = CONSOLE_MODULE["MEMORY_PROBE_PREPARATION_COMMAND"]
    return (
        f"preparation_command = os.read(0, 128)\n"
        f"if preparation_command != {preparation_command!r}:\n"
        "    raise SystemExit(17)\n"
        f"preparation_echo = {preparation_command[:-1]!r}\n"
        f"os.write(1, b'=> ' + preparation_echo + b'\\r\\n' + "
        f"{response_line!r} + b'\\r\\n=> ')\n"
    )


def _memory_probe_reader() -> str:
    command_pattern = CONSOLE_MODULE["MEMORY_PROBE_COMMAND_PATTERN"].pattern
    return (
        _memory_probe_preparation_reader()
        + f"probe_command = os.read(0, 128)\n"
        f"probe_command_match = re.fullmatch({command_pattern!r}, probe_command)\n"
        "if probe_command_match is None:\n"
        "    raise SystemExit(18)\n"
        "probe_nonce = probe_command_match.group(1).decode('ascii')\n"
    )


def _memory_probe_response(
    *,
    include_prompt: bool = True,
    include_prompt_prefix: bool = True,
    words: bytes = b"d50b7e20 d53b0023",
    nonce: str | None = None,
) -> str:
    if nonce is None:
        command_expression = "probe_command[:-1]"
        nonce_expression = "probe_nonce.encode('ascii')"
    else:
        _, command = CONSOLE_MODULE["_memory_probe_command"](nonce)
        command_expression = repr(command[:-1])
        nonce_expression = repr(nonce.encode("ascii"))
    prompt = b"=> " if include_prompt else b""
    prompt_prefix = b"=> " if include_prompt_prefix else b""
    return (
        f"response_command = {command_expression}\n"
        f"response_nonce = {nonce_expression}\n"
        f"response_words = {words!r}\n"
        "response_lines = b'\\r\\n'.join(\n"
        "    (line.rstrip(b'\\r') + b' ' + response_nonce)\n"
        "    if line else line\n"
        "    for line in response_words.split(b'\\n')\n"
        ")\n"
        f"payload = {prompt_prefix!r} + response_command + b'\\r\\n' + response_lines"
        f" + b'\\r\\n' + {prompt!r}\n"
        "os.write(1, payload)\n"
    )


def _memory_probe_exchange() -> str:
    return (
        _memory_probe_reader()
        + _memory_probe_response()
        + "boot_command = os.read(0, 32)\n"
        "if b'boot\\r' not in boot_command:\n"
        "    raise SystemExit(19)\n"
    )


def _run_helper(
    home: Path,
    result: Path,
    screen: Path,
    *,
    timeout: int = 2,
    handoff_timeout: int = 1,
    memory_probe_timeout: int = 1,
    output_limit: int = 65_536,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            str(timeout),
            "--handoff-timeout-seconds",
            str(handoff_timeout),
            "--memory-probe-timeout-seconds",
            str(memory_probe_timeout),
            "--max-output-bytes",
            str(output_limit),
            "--screen-program",
            str(screen),
        ],
        capture_output=True,
        text=True,
        timeout=timeout + 5,
        check=False,
    )


def _drive_helper_with_delayed_read(
    home: Path,
    result: Path,
    screen: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    marker: bytes,
    delay_seconds: float,
    timeout_seconds: int,
    handoff_timeout_seconds: int,
    memory_probe_timeout_seconds: int,
) -> tuple[dict[str, object], int]:
    drive_console = CONSOLE_MODULE["drive_console"]
    module_globals = drive_console.__globals__
    original_read = module_globals["_read_available"]
    delayed = False

    def delayed_read(master_fd: int, remaining_bytes: int) -> bytes:
        nonlocal delayed
        chunk = original_read(master_fd, remaining_bytes)
        if not delayed and marker in chunk:
            delayed = True
            time.sleep(delay_seconds)
        return chunk

    monkeypatch.setitem(module_globals, "_read_available", delayed_read)
    summary, status = drive_console(
        home,
        result,
        timeout_seconds=timeout_seconds,
        handoff_timeout_seconds=handoff_timeout_seconds,
        memory_probe_timeout_seconds=memory_probe_timeout_seconds,
        max_output_bytes=65_536,
        screen_program_path=screen,
    )
    assert delayed is True
    return summary, status


def test_console_helper_sends_boot_only_at_prompt_and_observes_handoff(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'\\x1b=\\x1b(B\\xc4\\x9d\\nU-Boot 2025.01 (test)\\n=> ')\n"
        + _memory_probe_exchange()
        + "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["schemaVersion"] == 6
    assert summary["consoleEndpointFound"] is True
    assert summary["screenStarted"] is True
    assert summary["uBootBannerObserved"] is True
    assert summary["promptObserved"] is True
    assert summary["memoryProbePreparationCommandAttempted"] is True
    assert summary["memoryProbePreparationCommandSent"] is True
    assert summary["memoryProbePreparationCommandEchoObserved"] is True
    assert summary["memoryProbePreparationResponsePromptObserved"] is True
    assert summary["memoryProbeVariablesCleared"] is True
    assert summary["memoryProbePreparationRejected"] is False
    assert summary["memoryProbeCommandAttempted"] is True
    assert summary["memoryProbeCommandSent"] is True
    assert summary["memoryProbeCommandEchoObserved"] is True
    assert summary["memoryProbeResponsePromptObserved"] is True
    assert summary["memoryProbeResponseObserved"] is True
    assert summary["memoryProbeResponseRejected"] is False
    assert summary["memoryProbeTimedOut"] is False
    assert summary["wordAtObservedPc"] == 0xD50B7E20
    assert summary["wordBeforeObservedPc"] == 0xD53B0023
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["cleanupComplete"] is True
    assert summary["exitCode"] == 0
    summary_text = result.read_text(encoding="utf-8")
    assert "ethaddr" not in summary_text
    assert "transcript" not in summary_text


def test_console_helper_distinguishes_screen_terminal_controls_from_text(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen_initialization = (
        b"\x1b[r\x1b[m\x1b[2J\x1b[H\x1b[?7h\x1b[?1;4;6l\x1b[?1049h"
        b"\x1b[22;0;0t\x1b[4l\x1b[?1h\x1b=\x1b[0m\x1b(B"
        b"\x1b[1;24r\x1b[H\x1b[2J\x1b[H\x1b[2J"
    )
    assert len(screen_initialization) == 83
    screen = _screen_stub(
        tmp_path,
        f"os.write(1, {screen_initialization!r})\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["outputBytesObserved"] == 83
    assert summary["escapeStrippedBytesObserved"] == 0
    assert summary["escapeSequenceIncomplete"] is False
    assert summary["uBootBannerObserved"] is False
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


def test_console_helper_reports_unterminated_escape_sequence_and_discards_tail(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'\\x1b]0;U-Boot 2025.01\\n=> ')\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["outputBytesObserved"] > 0
    assert summary["escapeStrippedBytesObserved"] == 0
    assert summary["escapeSequenceIncomplete"] is True
    assert summary["uBootBannerObserved"] is False
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True
    assert stat.S_IMODE(result.stat().st_mode) == 0o600


def test_console_helper_ignores_kernel_marker_received_before_boot(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'Starting kernel ...\\nU-Boot 2025.01 (test)\\n=> ')\n"
        + _memory_probe_exchange()
        + "time.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=3, handoff_timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is False
    assert summary["handoffTimedOut"] is True


def test_console_helper_does_not_boot_after_global_deadline_during_read(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response()
        + "time.sleep(10)",
    )

    summary, status = _drive_helper_with_delayed_read(
        home,
        result,
        screen,
        monkeypatch,
        marker=b"d50b7e20",
        delay_seconds=2.1,
        timeout_seconds=2,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=5,
    )

    assert status == 1
    assert summary["timedOut"] is True
    assert summary["memoryProbeTimedOut"] is False
    assert summary["memoryProbeResponsePromptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["kernelHandoffObserved"] is False


def test_console_helper_checks_global_deadline_inside_boot_sender(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response()
        + "time.sleep(10)",
    )
    drive_console = CONSOLE_MODULE["drive_console"]
    module_globals = drive_console.__globals__
    original_sender = module_globals["_send_console_command_if_not_cancelled"]

    def delayed_sender(
        master_fd: int,
        command: bytes,
        *,
        deadline: float | None = None,
    ) -> tuple[bool, bool]:
        if command == b"boot\r":
            time.sleep(2.1)
        return original_sender(master_fd, command, deadline=deadline)

    monkeypatch.setitem(
        module_globals,
        "_send_console_command_if_not_cancelled",
        delayed_sender,
    )
    summary, status = drive_console(
        home,
        result,
        timeout_seconds=2,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=5,
        max_output_bytes=65_536,
        screen_program_path=screen,
    )

    assert status == 1
    assert summary["timedOut"] is True
    assert summary["memoryProbeTimedOut"] is False
    assert summary["bootCommandSent"] is False
    assert summary["kernelHandoffObserved"] is False


def test_console_helper_checks_global_deadline_inside_memory_probe_sender(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + "time.sleep(10)",
    )
    drive_console = CONSOLE_MODULE["drive_console"]
    module_globals = drive_console.__globals__
    original_sender = module_globals["_send_console_command_if_not_cancelled"]

    def delayed_sender(
        master_fd: int,
        command: bytes,
        *,
        deadline: float | None = None,
    ) -> tuple[bool, bool]:
        if (
            CONSOLE_MODULE["_memory_probe_nonce_from_command"](command)
            is not None
        ):
            time.sleep(2.1)
        return original_sender(master_fd, command, deadline=deadline)

    monkeypatch.setitem(
        module_globals,
        "_send_console_command_if_not_cancelled",
        delayed_sender,
    )
    summary, status = drive_console(
        home,
        result,
        timeout_seconds=2,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=5,
        max_output_bytes=65_536,
        screen_program_path=screen,
    )

    assert status == 1
    assert summary["timedOut"] is True
    assert summary["memoryProbeTimedOut"] is False
    assert summary["memoryProbeCommandSent"] is False
    assert summary["bootCommandSent"] is False
    assert summary["kernelHandoffObserved"] is False


def test_console_helper_probe_deadline_bounds_preparation_command_send(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + "time.sleep(10)",
    )
    drive_console = CONSOLE_MODULE["drive_console"]
    module_globals = drive_console.__globals__
    original_sender = module_globals["_send_console_command_if_not_cancelled"]

    def delayed_sender(
        master_fd: int,
        command: bytes,
        *,
        deadline: float | None = None,
    ) -> tuple[bool, bool]:
        if command == CONSOLE_MODULE["MEMORY_PROBE_PREPARATION_COMMAND"]:
            time.sleep(1.1)
        return original_sender(master_fd, command, deadline=deadline)

    monkeypatch.setitem(
        module_globals,
        "_send_console_command_if_not_cancelled",
        delayed_sender,
    )
    summary, status = drive_console(
        home,
        result,
        timeout_seconds=4,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=1,
        max_output_bytes=65_536,
        screen_program_path=screen,
    )

    assert status == 1
    assert summary["timedOut"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["memoryProbePreparationCommandAttempted"] is True
    assert summary["memoryProbePreparationCommandSent"] is False
    assert summary["memoryProbeCommandAttempted"] is False
    assert summary["bootCommandSent"] is False


def test_console_helper_probe_deadline_bounds_memory_read_command_send(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response()
        + "time.sleep(10)",
    )
    drive_console = CONSOLE_MODULE["drive_console"]
    module_globals = drive_console.__globals__
    original_sender = module_globals["_send_console_command_if_not_cancelled"]

    def delayed_sender(
        master_fd: int,
        command: bytes,
        *,
        deadline: float | None = None,
    ) -> tuple[bool, bool]:
        if (
            CONSOLE_MODULE["_memory_probe_nonce_from_command"](command)
            is not None
        ):
            time.sleep(1.1)
        return original_sender(master_fd, command, deadline=deadline)

    monkeypatch.setitem(
        module_globals,
        "_send_console_command_if_not_cancelled",
        delayed_sender,
    )
    summary, status = drive_console(
        home,
        result,
        timeout_seconds=4,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=1,
        max_output_bytes=65_536,
        screen_program_path=screen,
    )

    assert status == 1
    assert summary["timedOut"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["memoryProbePreparationCommandSent"] is True
    assert summary["memoryProbeVariablesCleared"] is True
    assert summary["memoryProbeCommandAttempted"] is True
    assert summary["memoryProbeCommandSent"] is False
    assert summary["bootCommandSent"] is False


def test_console_helper_does_not_accept_handoff_after_deadline_during_read(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_exchange()
        + "os.write(1, b'\\r\\nStarting kernel ...\\n')\n"
        + "time.sleep(10)",
    )

    summary, status = _drive_helper_with_delayed_read(
        home,
        result,
        screen,
        monkeypatch,
        marker=b"Starting kernel",
        delay_seconds=1.1,
        timeout_seconds=4,
        handoff_timeout_seconds=1,
        memory_probe_timeout_seconds=1,
    )

    assert status == 1
    assert summary["kernelHandoffObserved"] is False
    assert summary["handoffTimedOut"] is True
    assert summary["timedOut"] is False


def test_console_helper_classifies_simultaneous_deadlines_as_handoff_timeout() -> None:
    summary = {
        "kernelHandoffObserved": False,
        "outputTruncated": False,
        "screenExitCode": None,
        "signal": None,
        "bootCommandSent": True,
        "memoryProbeTimedOut": False,
        "handoffTimedOut": False,
        "timedOut": False,
    }

    CONSOLE_MODULE["_record_expired_deadline_flags"](
        summary,
        deadline=10,
        handoff_deadline=10,
        observed_at=10,
    )

    assert summary["handoffTimedOut"] is True
    assert summary["timedOut"] is False


def test_console_helper_bounds_memory_probe_wait_and_never_boots_without_response(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + "time.sleep(10)",
    )

    completed = _run_helper(
        home,
        result,
        screen,
        timeout=3,
        memory_probe_timeout=1,
    )

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbePreparationCommandAttempted"] is True
    assert summary["memoryProbeCommandSent"] is True
    assert summary["memoryProbeCommandAttempted"] is True
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["bootCommandSent"] is False
    assert summary["wordAtObservedPc"] is None
    assert summary["cleanupComplete"] is True


def test_console_helper_rejects_uncleared_probe_variables_and_continues_boot(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_preparation_reader(b"APKRUN_PROBE_READY stale0 stale1")
        + "boot_command = os.read(0, 32)\n"
        "if boot_command != b'boot\\r':\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbePreparationCommandSent"] is True
    assert summary["memoryProbePreparationCommandEchoObserved"] is True
    assert summary["memoryProbePreparationResponsePromptObserved"] is True
    assert summary["memoryProbeVariablesCleared"] is False
    assert summary["memoryProbePreparationRejected"] is True
    assert summary["memoryProbeCommandSent"] is False
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["wordAtObservedPc"] is None
    assert summary["wordBeforeObservedPc"] is None
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True


def test_console_helper_bounds_probe_variable_preparation_wait(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    preparation_command = CONSOLE_MODULE["MEMORY_PROBE_PREPARATION_COMMAND"]
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        f"preparation_command = os.read(0, 128)\n"
        f"if preparation_command != {preparation_command!r}:\n"
        "    raise SystemExit(17)\n"
        "time.sleep(10)",
    )

    completed = _run_helper(
        home,
        result,
        screen,
        timeout=3,
        memory_probe_timeout=1,
    )

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbePreparationCommandSent"] is True
    assert summary["memoryProbePreparationCommandEchoObserved"] is False
    assert summary["memoryProbePreparationResponsePromptObserved"] is False
    assert summary["memoryProbeVariablesCleared"] is False
    assert summary["memoryProbeCommandSent"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["bootCommandSent"] is False


def test_console_helper_ignores_stale_words_before_probe_command(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> \\n"
        "d50b7e20 d53b0023\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response()
        + "boot_command = os.read(0, 32)\n"
        "if b'boot\\r' not in boot_command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeCommandEchoObserved"] is True
    assert summary["memoryProbeResponseObserved"] is True
    assert summary["memoryProbeResponsePromptObserved"] is True
    assert summary["memoryProbeResponseRejected"] is False
    assert summary["wordAtObservedPc"] == 0xD50B7E20
    assert summary["wordBeforeObservedPc"] == 0xD53B0023
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True


def test_console_helper_rejects_delayed_response_from_another_run(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + "os.write(1, b'=> ' + probe_command[:-1] + b'\\r\\n')\n"
        "stale_nonce = b'deadbee' if probe_nonce != 'deadbee' else b'deadbe0'\n"
        "os.write(1, b'd50b7e20 d53b0023 ' + stale_nonce + b'\\r\\n=> ')\n"
        + "boot_command = os.read(0, 32)\n"
        "if b'boot\\r' not in boot_command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeCommandEchoObserved"] is True
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["memoryProbeResponsePromptObserved"] is True
    assert summary["memoryProbeResponseRejected"] is True
    assert summary["wordAtObservedPc"] is None
    assert summary["wordBeforeObservedPc"] is None
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True


def test_memory_probe_command_fits_with_a_seven_character_run_nonce() -> None:
    command_text, command = CONSOLE_MODULE["_memory_probe_command"]("a1b2c3d")

    assert command == f"{command_text}\r".encode("ascii")
    assert command_text.endswith("a1b2c3d")
    assert len("=> ") + len(command_text) == 79
    assert CONSOLE_MODULE["_memory_probe_nonce_from_command"](command) == "a1b2c3d"
    with pytest.raises(ValueError, match="seven safe alphanumeric characters"):
        CONSOLE_MODULE["_memory_probe_command"]("not-hex")


def test_console_helper_never_boots_without_the_probe_response_prompt(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response(include_prompt=False)
        + "time.sleep(10)",
    )

    completed = _run_helper(
        home,
        result,
        screen,
        timeout=3,
        memory_probe_timeout=1,
    )

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeCommandEchoObserved"] is True
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["memoryProbeResponsePromptObserved"] is False
    assert summary["memoryProbeResponseRejected"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["bootCommandSent"] is False


def test_console_helper_rejects_duplicate_instruction_words_but_continues_boot(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response(
            words=b"d50b7e20 d53b0023\nd50b7e20 d53b0023"
        )
        + "boot_command = os.read(0, 32)\n"
        "if b'boot\\r' not in boot_command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(
        home,
        result,
        screen,
        timeout=3,
        memory_probe_timeout=1,
    )

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeCommandEchoObserved"] is True
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["memoryProbeResponsePromptObserved"] is True
    assert summary["memoryProbeResponseRejected"] is True
    assert summary["memoryProbeTimedOut"] is False
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["wordAtObservedPc"] is None


def test_console_helper_discards_prequeued_probe_text_before_probe_command(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "prefix = b'U-Boot 2025.01\\n' + b'x' * (4096 - 19) + b'\\n=> '\n"
        "if len(prefix) != 4096:\n"
        "    raise SystemExit(17)\n"
        "os.write(1, prefix)\n"
        "os.write(1, b'd50b7e20 d53b0023\\n=> ')\n"
        + _memory_probe_reader()
        + _memory_probe_response()
        + "boot_command = os.read(0, 32)\n"
        "if b'boot\\r' not in boot_command:\n"
        "    raise SystemExit(19)\n"
        "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeResponsePromptObserved"] is True
    assert summary["memoryProbeResponseObserved"] is True
    assert summary["wordAtObservedPc"] == 0xD50B7E20
    assert summary["wordBeforeObservedPc"] == 0xD53B0023
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True


def test_console_helper_rejects_memory_probe_response_after_timeout(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n=> ')\n"
        + _memory_probe_reader()
        + "time.sleep(1.2)\n"
        + _memory_probe_response()
        + "time.sleep(1)",
    )

    completed = _run_helper(
        home,
        result,
        screen,
        timeout=4,
        memory_probe_timeout=1,
    )

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["memoryProbeCommandEchoObserved"] is False
    assert summary["memoryProbeResponseObserved"] is False
    assert summary["memoryProbeResponsePromptObserved"] is False
    assert summary["memoryProbeResponseRejected"] is False
    assert summary["memoryProbeTimedOut"] is True
    assert summary["bootCommandSent"] is False


def test_console_output_drain_does_not_claim_quiet_at_deadline() -> None:
    master_fd, slave_fd = pty.openpty()
    stop_writer = threading.Event()

    def write_until_stopped() -> None:
        while not stop_writer.is_set():
            try:
                os.write(slave_fd, b"x")
            except OSError:
                return
            time.sleep(0.02)

    writer = threading.Thread(target=write_until_stopped)
    writer.start()
    try:
        deadline = time.monotonic() + 0.2
        drained, quiet = CONSOLE_MODULE["_drain_console_output"](
            master_fd,
            1024,
            deadline,
        )
    finally:
        stop_writer.set()
        writer.join(timeout=1)
        os.close(master_fd)
        os.close(slave_fd)

    assert drained
    assert quiet is False


def test_memory_probe_parser_rejects_ambiguous_or_malformed_words() -> None:
    parse = CONSOLE_MODULE["_parse_memory_probe_words"]

    assert parse("d50b7e20 d53b0023 a1b2c3d\n", "a1b2c3d") == (
        0xD50B7E20,
        0xD53B0023,
    )
    assert parse("d50b7e20 d53b0023 deadbee\n", "a1b2c3d") == (None, None)
    assert parse(
        "d50b7e20 d53b0023 a1b2c3d\n"
        "d50b7e20 d53b0023 a1b2c3d\n",
        "a1b2c3d",
    ) == (None, None)
    assert parse("d50b7e2 d53b0023 a1b2c3d\n", "a1b2c3d") == (None, None)
    assert parse(
        "read failed\nd50b7e20 d53b0023 a1b2c3d\n",
        "a1b2c3d",
    ) == (
        None,
        None,
    )
    assert parse(
        "d50b7e20 d53b0023 extra a1b2c3d\n",
        "a1b2c3d",
    ) == (None, None)


def test_console_summary_is_not_published_when_atomic_link_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = tmp_path / "bootloader-console-summary.json"

    def fail_link(*_args: object, **_kwargs: object) -> None:
        raise OSError("injected link failure")

    monkeypatch.setattr(os, "link", fail_link)

    with pytest.raises(OSError, match="injected link failure"):
        CONSOLE_MODULE["_write_result"](
            result,
            {"schemaVersion": 1, "exitCode": 0},
        )

    assert not result.exists()
    assert not list(tmp_path.glob(".bootloader-console-summary.json.*"))


def test_console_helper_times_out_without_sending_boot_when_prompt_is_absent(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'no bootloader prompt\\n')\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["kernelHandoffObserved"] is False
    assert summary["timedOut"] is True
    assert summary["cleanupComplete"] is True
    assert summary["screenExitCode"] == -15


def test_console_helper_does_not_report_screen_started_when_exec_fails(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = tmp_path / "screen-with-missing-interpreter"
    screen.write_text("#!/missing/screen/interpreter\n", encoding="ascii")
    screen.chmod(0o700)

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["screenStarted"] is False
    assert summary["screenExitCode"] is None
    assert summary["outputBytesObserved"] == 0
    assert summary["cleanupComplete"] is True


def test_console_helper_reaps_screen_if_startup_wait_raises(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = _private_home(tmp_path)
    screen_pid_path = home / "screen.pid"
    screen = _screen_stub(
        tmp_path,
        "from pathlib import Path\n"
        f"Path({str(screen_pid_path)!r}).write_text(str(os.getpid()), encoding='ascii')\n"
        "time.sleep(10)",
    )
    select_module = CONSOLE_MODULE["select"]
    original_select = select_module.select
    helper_globals = CONSOLE_MODULE["_start_screen"].__globals__
    select_calls = 0
    cleanup_results: list[tuple[int | None, bool, str | None, int | None]] = []
    original_stop = helper_globals["_stop_screen"]

    def fail_first_select(
        *args: object, **kwargs: object
    ) -> tuple[list[int], list[int], list[int]]:
        nonlocal select_calls
        select_calls += 1
        if select_calls == 1:
            raise ValueError("injected readiness wait failure")
        return original_select(*args, **kwargs)

    def record_cleanup(
        pid: int, master_fd: int
    ) -> tuple[int | None, bool, str | None, int | None]:
        result = original_stop(pid, master_fd)
        cleanup_results.append(result)
        return result

    monkeypatch.setattr(select_module, "select", fail_first_select)
    monkeypatch.setitem(helper_globals, "_stop_screen", record_cleanup)

    with pytest.raises(ValueError, match="injected readiness wait failure"):
        CONSOLE_MODULE["_start_screen"](
            screen,
            home / "cuttlefish_runtime/console",
            home,
        )

    assert cleanup_results
    assert cleanup_results[0][1] is True
    if screen_pid_path.exists():
        screen_pid = int(screen_pid_path.read_text(encoding="ascii"))
        with pytest.raises(ProcessLookupError):
            os.kill(screen_pid, 0)


def test_console_helper_records_uboot_banner_without_sending_boot(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot 2025.01\\n')\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["uBootBannerObserved"] is True
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.parametrize(
    "control_string",
    (
        b"\x1b]0;title\x1b\x07",
        b"\x1bPdata\x1b\x9c",
    ),
)
def test_console_helper_observes_banner_after_control_string_terminator(
    tmp_path: Path,
    control_string: bytes,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    output = control_string + b"U-Boot 2025.01\n"
    screen = _screen_stub(
        tmp_path,
        f"os.write(1, {output!r})\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["uBootBannerObserved"] is True
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.parametrize(
    "console_output",
    (
        b"Waiting for U-Boot prompt\n",
        b"U-Boot\n2025.01\n",
        b"\x1bP\nU-Boot 2025.01 (hidden)\x1b\\\n",
        b"\x1b]0;\nU-Boot 2025.01",
        b"\x90\nU-Boot 2025.01 (hidden)\x9c\n",
        b"\x9d0;\nU-Boot 2025.01\x9c",
        b"\x9d0;\xc5\x9c\nU-Boot 2025.01\x9c",
        b"\xf0\x90\x9d0;\nU-Boot 2025.01\x9c",
    ),
)
def test_console_helper_does_not_treat_uboot_mention_as_banner(
    tmp_path: Path,
    console_output: bytes,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        f"os.write(1, {console_output!r})\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["uBootBannerObserved"] is False
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False


def test_console_helper_bounds_output_and_never_sends_boot_without_prompt(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'x' * 4096)\ntime.sleep(10)",
    )

    completed = _run_helper(home, result, screen, output_limit=64)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["outputBytesObserved"] == 64
    assert summary["escapeStrippedBytesObserved"] == 64
    assert summary["outputTruncated"] is True
    assert summary["promptObserved"] is False
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.parametrize("bad_path", ("home", "result"))
def test_console_helper_rejects_symlinked_private_paths(
    tmp_path: Path,
    bad_path: str,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")
    if bad_path == "home":
        target = tmp_path / "home-link"
        target.symlink_to(home, target_is_directory=True)
        home = target
    else:
        existing = tmp_path / "existing-summary"
        existing.write_text("{}", encoding="utf-8")
        result.symlink_to(existing)

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    if bad_path == "home":
        assert not result.exists()
    else:
        assert result.is_symlink()


def test_console_helper_accepts_runtime_symlink_within_home(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    runtime = home / "cuttlefish_runtime"
    private_runtime = home / "private-runtime"
    runtime.rename(private_runtime)
    runtime.symlink_to(private_runtime, target_is_directory=True)
    screen = _screen_stub(
        tmp_path,
        "os.write(1, b'U-Boot\\n=> ')\n"
        + _memory_probe_exchange()
        + "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["exitCode"] == 0


def test_console_helper_rejects_runtime_symlink_outside_home(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")
    runtime = home / "cuttlefish_runtime"
    (runtime / "console").unlink()
    runtime.rmdir()
    outside_runtime = tmp_path / "outside-runtime"
    outside_runtime.mkdir()
    runtime.symlink_to(outside_runtime, target_is_directory=True)

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    assert (
        "private Cuttlefish runtime directory symlink resolves outside its HOME"
        in completed.stderr
    )
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is False
    assert summary["exitCode"] == 1


def test_console_helper_follows_owned_devpts_console_symlink(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    master_fd, slave_fd = pty.openpty()
    console = home / "cuttlefish_runtime/console"
    console.unlink()
    console.symlink_to(os.ttyname(slave_fd))
    screen = _screen_stub(
        tmp_path,
        "import stat\n"
        "import sys\n"
        "if not stat.S_ISCHR(os.stat(sys.argv[-1]).st_mode):\n"
        "    raise SystemExit(20)\n"
        "os.write(1, b'U-Boot\\n=> ')\n"
        + _memory_probe_exchange()
        + "os.write(1, b'\\r\\nStarting kernel ...\\n')",
    )

    try:
        completed = _run_helper(home, result, screen, timeout=1)
    finally:
        os.close(master_fd)
        os.close(slave_fd)

    assert completed.returncode == 0, completed.stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["consoleEndpointFound"] is True
    assert summary["promptObserved"] is True
    assert summary["bootCommandSent"] is True
    assert summary["kernelHandoffObserved"] is True
    assert summary["exitCode"] == 0


def test_console_helper_rejects_group_accessible_home(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    home.chmod(0o750)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(tmp_path, "time.sleep(10)")

    completed = _run_helper(home, result, screen, timeout=1)

    assert completed.returncode == 1
    assert not result.exists()


def test_console_helper_handles_term_and_records_cleanup(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    started = home / "screen-started"
    screen = _screen_stub(
        tmp_path,
        f"Path = __import__('pathlib').Path({str(started)!r})\n"
        "Path.touch()\n"
        "time.sleep(10)",
    )
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            "30",
            "--screen-program",
            str(screen),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 5
    while not started.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert started.exists(), "fake Screen did not start"

    process.terminate()
    _, stderr = process.communicate(timeout=5)

    assert process.returncode == 143, stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["signal"] == 15
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


def test_console_helper_does_not_send_boot_after_cancellation_while_prompt_is_pending(
    tmp_path: Path,
) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    screen = _screen_stub(
        tmp_path,
        "import signal\n"
        "os.kill(os.getppid(), signal.SIGTERM)\n"
        "time.sleep(0.05)\n"
        "os.write(1, b'U-Boot\\n=> ')\n"
        "time.sleep(10)",
    )
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER),
            "--home",
            str(home),
            "--result",
            str(result),
            "--timeout-seconds",
            "30",
            "--screen-program",
            str(screen),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    _, stderr = process.communicate(timeout=5)

    assert process.returncode == 143, stderr
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["signal"] == 15
    assert isinstance(summary["promptObserved"], bool)
    assert summary["bootCommandSent"] is False
    assert summary["cleanupComplete"] is True


@pytest.mark.skipif(
    sys.platform != "linux" or not hasattr(os, "waitid"),
    reason="group cleanup must keep the Screen leader unreaped until verification",
)
def test_console_helper_stops_screen_group_descendants(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    result = tmp_path / "bootloader-console-summary.json"
    term_marker = home / "descendant-term"
    ready_marker = home / "descendant-ready"
    pid_path = home / "descendant.pid"
    child_body = (
        "import signal,time\n"
        "from pathlib import Path\n"
        f"marker = Path({str(term_marker)!r})\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "def stop(_signum, _frame):\n"
        "    marker.write_text('term', encoding='ascii')\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
        "ready.write_text('ready', encoding='ascii')\n"
        "time.sleep(30)\n"
    )
    screen = _screen_stub(
        tmp_path,
        "import subprocess\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([__import__('sys').executable, '-c', "
        f"{child_body!r}])\n"
        f"Path({str(pid_path)!r}).write_text(str(child.pid), encoding='ascii')\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "deadline = time.monotonic() + 2\n"
        "while not ready.exists() and time.monotonic() < deadline:\n"
        "    time.sleep(0.01)\n"
        "if not ready.exists():\n"
        "    raise SystemExit('descendant did not become ready')\n"
        "raise SystemExit(0)",
    )

    completed = _run_helper(home, result, screen, timeout=2)

    assert completed.returncode == 1
    summary = json.loads(result.read_text(encoding="utf-8"))
    assert summary["screenExitCode"] == 0
    assert summary["cleanupComplete"] is True
    assert term_marker.read_text(encoding="ascii") == "term"


def test_screen_cleanup_signals_child_before_its_session_exists() -> None:
    master_fd, slave_fd = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.close(slave_fd)
        while True:
            signal.pause()

    os.close(slave_fd)
    try:
        assert os.getpgid(pid) != pid
        exit_code, cleanup_complete, cleanup_failure, error_number = CONSOLE_MODULE[
            "_stop_screen"
        ](pid, master_fd)
    finally:
        os.close(master_fd)

    assert exit_code == -signal.SIGTERM
    assert cleanup_complete is True, (cleanup_failure, error_number)


def test_screen_cleanup_retries_group_kill_after_session_setup_race(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    master_fd, slave_fd = pty.openpty()
    ready_read_fd, ready_write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.close(slave_fd)
        os.close(ready_read_fd)

        def start_descendant(_signum: int, _frame: object) -> None:
            os.setsid()
            descendant_pid = os.fork()
            if descendant_pid == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.write(
                    ready_write_fd,
                    f"descendant:{os.getpid()}\n".encode("ascii"),
                )
                while True:
                    signal.pause()
            os.write(ready_write_fd, b"leader\n")

        signal.signal(signal.SIGTERM, start_descendant)
        os.write(ready_write_fd, b"armed\n")
        while True:
            signal.pause()

    os.close(slave_fd)
    os.close(ready_write_fd)
    original_killpg = os.killpg
    killpg_sigkill_calls = 0
    race_injected = False

    def inject_session_creation_race(
        process_group: int,
        signum: int,
    ) -> None:
        nonlocal killpg_sigkill_calls, race_injected
        if process_group == pid and signum == signal.SIGKILL:
            killpg_sigkill_calls += 1
            if killpg_sigkill_calls == 1:
                deadline = time.monotonic() + 3
                observed = bytearray()
                while time.monotonic() < deadline:
                    ready, _, _ = select.select(
                        [ready_read_fd],
                        [],
                        [],
                        max(0.0, deadline - time.monotonic()),
                    )
                    if not ready:
                        break
                    observed.extend(os.read(ready_read_fd, 128))
                    if b"descendant:" in observed:
                        race_injected = True
                        raise ProcessLookupError(errno.ESRCH, "injected session race")
                raise AssertionError("Screen child did not create its process group")
        original_killpg(process_group, signum)

    monkeypatch.setattr(os, "killpg", inject_session_creation_race)
    try:
        assert os.getpgid(pid) != pid
        ready, _, _ = select.select([ready_read_fd], [], [], 3)
        assert ready
        assert os.read(ready_read_fd, 128) == b"armed\n"
        exit_code, cleanup_complete, cleanup_failure, error_number = CONSOLE_MODULE[
            "_stop_screen"
        ](pid, master_fd)
        assert race_injected
        assert killpg_sigkill_calls >= 2
        assert exit_code == -signal.SIGKILL
        assert cleanup_complete is True, (cleanup_failure, error_number)
        assert CONSOLE_MODULE["_live_linux_group_descendants"](pid, pid) is False
    finally:
        monkeypatch.setattr(os, "killpg", original_killpg)
        for descriptor in (master_fd, ready_read_fd):
            os.close(descriptor)
        try:
            original_killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


@pytest.mark.skipif(sys.platform != "linux", reason="Linux process groups are required")
def test_screen_group_cleanup_falls_back_without_waitid(tmp_path: Path) -> None:
    home = _private_home(tmp_path)
    term_marker = home / "descendant-term"
    ready_marker = home / "descendant-ready"
    child_body = (
        "import signal,time\n"
        "from pathlib import Path\n"
        f"marker = Path({str(term_marker)!r})\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "def stop(_signum, _frame):\n"
        "    marker.write_text('term', encoding='ascii')\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
        "ready.write_text('ready', encoding='ascii')\n"
        "time.sleep(30)\n"
    )
    screen = _screen_stub(
        tmp_path,
        "import subprocess\n"
        "from pathlib import Path\n"
        "child = subprocess.Popen([__import__('sys').executable, '-c', "
        f"{child_body!r}])\n"
        f"ready = Path({str(ready_marker)!r})\n"
        "deadline = time.monotonic() + 2\n"
        "while not ready.exists() and time.monotonic() < deadline:\n"
        "    time.sleep(0.01)\n"
        "if not ready.exists():\n"
        "    raise SystemExit('descendant did not become ready')\n"
        "raise SystemExit(0)",
    )
    console_os = SimpleNamespace(**{**vars(os), "waitid": None})
    CONSOLE_MODULE["os"] = console_os
    try:
        pid, master_fd = CONSOLE_MODULE["_start_screen"](
            screen,
            home / "cuttlefish_runtime/console",
            home,
        )
        try:
            deadline = time.monotonic() + 2
            while not ready_marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert ready_marker.exists()
            exit_code, cleanup_complete, cleanup_failure, _ = CONSOLE_MODULE[
                "_stop_screen"
            ](pid, master_fd)
        finally:
            os.close(master_fd)
    finally:
        CONSOLE_MODULE["os"] = os

    assert exit_code in (0, -signal.SIGTERM, -signal.SIGKILL)
    assert cleanup_complete is True, cleanup_failure
    assert term_marker.read_text(encoding="ascii") == "term"
