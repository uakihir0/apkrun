"""Command-line entry-point tests."""

from __future__ import annotations

import json
import struct
from pathlib import Path

import pytest

from apkrun_image.__main__ import main
from apkrun_image.inspect import main as inspect_main
from apkrun_image.inventory import main as inventory_main


def test_help_lists_initial_commands(capsys: pytest.CaptureFixture[str]) -> None:
    """The package help exposes the commands promised by the tooling layout."""
    assert main(["--help"]) == 0
    output = capsys.readouterr().out
    assert "fetch" in output
    assert "inventory" in output
    assert "inspect" in output


def test_inventory_help_dispatches_to_command_parser(capsys: pytest.CaptureFixture[str]) -> None:
    """Command help reaches its own parser instead of being swallowed globally."""
    with pytest.raises(SystemExit) as exception:
        main(["inventory", "--help"])

    assert exception.value.code == 0
    output = capsys.readouterr().out
    assert "zip archive or unpacked directory" in output
    assert "--out" in output


def test_inventory_module_help_is_available(capsys: pytest.CaptureFixture[str]) -> None:
    """The repository wrapper can invoke the inventory parser directly."""
    with pytest.raises(SystemExit) as exception:
        inventory_main(["--help"])

    assert exception.value.code == 0
    assert "--out" in capsys.readouterr().out


def test_inspect_prints_content_based_image_summary(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The inspect command reports parsed image details without changing input."""
    image = tmp_path / "init_boot.img"
    content = bytearray(4608)
    content[:8] = b"ANDROID!"
    struct.pack_into("<II", content, 8, 0, 1)
    struct.pack_into("<I", content, 20, 1584)
    struct.pack_into("<I", content, 40, 4)
    image.write_bytes(content)

    assert inspect_main([str(image)]) == 0

    output = json.loads(capsys.readouterr().out)
    assert output["kind"] == "bootImage"
    assert output["details"]["bootKind"] == "init_boot"
    assert output["nameMismatch"] is False
    assert image.read_bytes() == content


def test_inspect_reports_missing_input(capsys: pytest.CaptureFixture[str]) -> None:
    """Missing files have an actionable command error instead of a traceback."""
    assert inspect_main(["/tmp/apkrun-no-such-image.img"]) == 2
    assert "not a regular file" in capsys.readouterr().err
