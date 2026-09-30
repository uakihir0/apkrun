"""Reproducibility checks for the pinned upstream image fixtures."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def test_fixture_builder_produces_identical_outputs(tmp_path: Path) -> None:
    """Two builds have identical checksums, including their deterministic ZIP."""
    script = Path(__file__).parent / "fixtures/build_fixtures.py"
    first = tmp_path / "first"
    second = tmp_path / "second"
    subprocess.run([sys.executable, str(script), "--out", str(first)], check=True)
    subprocess.run([sys.executable, str(script), "--out", str(second)], check=True)

    first_checksums = (first / "SHA256SUMS").read_bytes()
    second_checksums = (second / "SHA256SUMS").read_bytes()
    assert first_checksums == second_checksums
