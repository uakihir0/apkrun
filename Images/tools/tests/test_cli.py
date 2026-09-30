"""Command-line entry-point tests."""

from __future__ import annotations

import pytest

from apkrun_image.__main__ import main


def test_help_lists_initial_commands(capsys: pytest.CaptureFixture[str]) -> None:
    """The package help exposes the commands promised by the tooling layout."""
    with pytest.raises(SystemExit) as exception:
        main(["--help"])

    assert exception.value.code == 0
    output = capsys.readouterr().out
    assert "fetch" in output
    assert "inventory" in output
    assert "inspect" in output
