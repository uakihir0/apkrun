from __future__ import annotations

import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import capture_processes


def test_child_exit_observation_keeps_group_leader_waitable() -> None:
    process = subprocess.Popen(
        [sys.executable, "-c", "pass"],
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if capture_processes.child_exit_observed_without_reaping(process):
                break
            time.sleep(0.01)
        else:
            pytest.fail("child did not exit within the test deadline")

        assert process.returncode is None
        assert capture_processes.child_exit_observed_without_reaping(process)
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGKILL,
        )
        assert process.wait(timeout=5) == 0
    finally:
        if process.returncode is None:
            capture_processes.signal_process_group_while_child_is_pinned(
                process,
                signal.SIGKILL,
            )
            process.wait(timeout=5)


def test_process_group_signal_refuses_a_reaped_leader() -> None:
    process = subprocess.Popen(
        [sys.executable, "-c", "pass"],
        start_new_session=True,
    )
    assert process.wait(timeout=5) == 0

    with pytest.raises(RuntimeError, match="after reaping"):
        capture_processes.signal_process_group_while_child_is_pinned(
            process,
            signal.SIGKILL,
        )
