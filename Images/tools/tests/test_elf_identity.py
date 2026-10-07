from __future__ import annotations

import hashlib
import importlib.util
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import BinaryIO

import pytest

IDENTITY_PATH = Path(__file__).parents[1] / "reference" / "elf_identity.py"
VIRGL_PREFLIGHT_PATH = Path(__file__).parents[1] / "reference" / "check_virgl_crosvm.py"
IDENTITY_SPEC = importlib.util.spec_from_file_location("elf_identity", IDENTITY_PATH)
assert IDENTITY_SPEC is not None
assert IDENTITY_SPEC.loader is not None
IDENTITY_MODULE = importlib.util.module_from_spec(IDENTITY_SPEC)
IDENTITY_SPEC.loader.exec_module(IDENTITY_MODULE)


def _note(
    build_id: bytes | None,
    *,
    endian: str = "<",
    name: bytes = b"GNU\0",
) -> bytes:
    if build_id is None:
        return b""
    name_padding = bytes((-len(name)) % 4)
    description_padding = bytes((-len(build_id)) % 4)
    return (
        struct.pack(endian + "III", len(name), len(build_id), 3)
        + name
        + name_padding
        + build_id
        + description_padding
    )


def _elf64(build_id: bytes | None, *, endian: str = "<") -> bytes:
    notes = _note(build_id, endian=endian)
    encoding = 1 if endian == "<" else 2
    ident = b"\x7fELF" + bytes((2, encoding, 1)) + bytes(9)
    header = struct.pack(
        endian + "HHIQQQIHHHHHH",
        2,
        183,
        1,
        0,
        64,
        0,
        0,
        64,
        56,
        1,
        0,
        0,
        0,
    )
    note_offset = 120
    program_header = struct.pack(
        endian + "IIQQQQQQ",
        4,
        4,
        note_offset,
        0,
        0,
        len(notes),
        len(notes),
        4,
    )
    return ident + header + program_header + notes


def _elf32(build_id: bytes, *, endian: str = "<") -> bytes:
    notes = _note(build_id, endian=endian)
    encoding = 1 if endian == "<" else 2
    ident = b"\x7fELF" + bytes((1, encoding, 1)) + bytes(9)
    header = struct.pack(
        endian + "HHIIIIIHHHHHH",
        2,
        40,
        1,
        0,
        52,
        0,
        0,
        52,
        32,
        1,
        0,
        0,
        0,
    )
    note_offset = 84
    program_header = struct.pack(
        endian + "IIIIIIII",
        4,
        note_offset,
        0,
        0,
        len(notes),
        len(notes),
        4,
        4,
    )
    return ident + header + program_header + notes


@pytest.mark.parametrize(
    ("contents", "build_id"),
    (
        (_elf64(bytes.fromhex("0123456789abcdef")), "0123456789abcdef"),
        (
            _elf64(bytes.fromhex("00112233445566778899aabbccddeeff"), endian=">"),
            "00112233445566778899aabbccddeeff",
        ),
        (_elf32(bytes.fromhex("fedcba9876543210")), "fedcba9876543210"),
        (_elf32(bytes.fromhex("abcdef0123456789"), endian=">"), "abcdef0123456789"),
    ),
)
def test_identify_reads_gnu_build_ids_from_32_and_64_bit_elf(
    tmp_path: Path,
    contents: bytes,
    build_id: str,
) -> None:
    path = tmp_path / "binary"
    path.write_bytes(contents)

    identity = IDENTITY_MODULE.identify(path)

    assert identity == {
        "status": "identified",
        "sha256": hashlib.sha256(contents).hexdigest(),
        "elfBuildId": build_id,
    }


def test_identify_hashes_non_elf_without_claiming_an_elf_build_id(tmp_path: Path) -> None:
    path = tmp_path / "script"
    contents = b"#!/bin/sh\nexit 0\n"
    path.write_bytes(contents)

    assert IDENTITY_MODULE.identify(path) == {
        "status": "not_elf",
        "sha256": hashlib.sha256(contents).hexdigest(),
        "elfBuildId": None,
    }


def test_identify_distinguishes_elf_without_a_build_id(tmp_path: Path) -> None:
    path = tmp_path / "no-build-id"
    contents = _elf64(None)
    path.write_bytes(contents)

    assert IDENTITY_MODULE.identify(path) == {
        "status": "build_id_missing",
        "sha256": hashlib.sha256(contents).hexdigest(),
        "elfBuildId": None,
    }


@pytest.mark.parametrize(
    ("contents", "expected_status"),
    (
        (b"", "not_elf"),
        (b"\x7fELF", "invalid_elf"),
        (_elf64(None)[:90], "invalid_elf"),
    ),
)
def test_identify_classifies_short_and_truncated_inputs(
    tmp_path: Path,
    contents: bytes,
    expected_status: str,
) -> None:
    path = tmp_path / "truncated"
    path.write_bytes(contents)

    identity = IDENTITY_MODULE.identify(path)

    assert identity["status"] == expected_status
    assert identity["sha256"] == hashlib.sha256(contents).hexdigest()
    assert identity["elfBuildId"] is None


def test_identify_rejects_a_file_changed_during_inspection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    path = tmp_path / "changing"
    contents = _elf64(bytes.fromhex("0123456789abcdef"))
    path.write_bytes(contents)

    def mutate_during_inspection(_stream: BinaryIO, _file_size: int) -> str:
        path.write_bytes(contents + b"\0")
        return "0123456789abcdef"

    monkeypatch.setattr(IDENTITY_MODULE, "_parse_build_id", mutate_during_inspection)
    identity = IDENTITY_MODULE.identify(path)

    assert identity == {
        "status": "changed_during_read",
        "sha256": None,
        "elfBuildId": None,
    }


def test_identify_rejects_out_of_bounds_note_segments(tmp_path: Path) -> None:
    contents = bytearray(_elf64(None))
    program_header = struct.pack("<IIQQQQQQ", 4, 4, len(contents) + 1, 0, 0, 1, 1, 4)
    contents[64:120] = program_header
    path = tmp_path / "out-of-bounds"
    path.write_bytes(contents)

    assert IDENTITY_MODULE.identify(path)["status"] == "invalid_elf"


def test_identify_does_not_open_non_regular_paths(tmp_path: Path) -> None:
    directory = tmp_path / "directory"
    directory.mkdir()

    assert IDENTITY_MODULE.identify(directory) == {
        "status": "unavailable",
        "sha256": None,
        "elfBuildId": None,
    }


def test_identify_missing_path_has_no_path_dependent_error_text(tmp_path: Path) -> None:
    missing = tmp_path / "private-host-root" / "missing"

    identity = IDENTITY_MODULE.identify(missing)

    assert identity == {
        "status": "unavailable",
        "sha256": None,
        "elfBuildId": None,
    }
    assert str(tmp_path) not in str(identity)


def _run_virgl_preflight(launch: Path, expected: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VIRGL_PREFLIGHT_PATH),
            "--launch-command",
            str(launch),
            "--expected-executable",
            str(expected),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _run_virgl_verification(
    executable: Path, expected_sha256: str, *, running: bool = False
) -> subprocess.CompletedProcess[str]:
    option = "--running-executable" if running else "--verify-executable"
    return subprocess.run(
        [
            sys.executable,
            str(VIRGL_PREFLIGHT_PATH),
            option,
            str(executable),
            "--expected-sha256",
            expected_sha256,
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def test_virgl_preflight_rejects_the_known_incompatible_expected_crosvm(
    tmp_path: Path,
) -> None:
    launch = tmp_path / "launch-crosvm"
    expected = tmp_path / "expected-crosvm"
    build_id = "d724bf54f045b0ec7dbe14049b0fed9a16e52a23"
    launch.write_text("#!/bin/sh\nexec crosvm\n", encoding="utf-8")
    expected.write_bytes(_elf64(bytes.fromhex(build_id)))

    result = _run_virgl_preflight(launch, expected)

    assert result.returncode == 1
    assert build_id in result.stderr
    assert "known to omit the rutabaga virgl_renderer feature" in result.stderr
    assert str(tmp_path) not in result.stderr


def test_virgl_preflight_rejects_a_known_incompatible_launch_elf(
    tmp_path: Path,
) -> None:
    launch = tmp_path / "launch-crosvm"
    expected = tmp_path / "expected-crosvm"
    build_id = "d724bf54f045b0ec7dbe14049b0fed9a16e52a23"
    launch.write_bytes(_elf64(bytes.fromhex(build_id)))
    expected.write_bytes(_elf64(bytes.fromhex("0123456789abcdef")))

    result = _run_virgl_preflight(launch, expected)

    assert result.returncode == 1
    assert build_id in result.stderr
    assert "launch command Build ID" in result.stderr
    assert "known to omit the rutabaga virgl_renderer feature" in result.stderr
    assert str(tmp_path) not in result.stderr


def test_virgl_preflight_allows_a_launcher_with_a_distinct_expected_crosvm(
    tmp_path: Path,
) -> None:
    launch = tmp_path / "launch-wrapper"
    expected = tmp_path / "expected-crosvm"
    launch.write_text("#!/bin/sh\nexec /opt/diagnostic/crosvm\n", encoding="utf-8")
    launch.chmod(0o755)
    contents = _elf64(bytes.fromhex("0123456789abcdef"))
    expected.write_bytes(contents)

    result = _run_virgl_preflight(launch, expected)

    assert result.returncode == 0
    metadata = json.loads(result.stdout)
    assert metadata["launchCommand"]["status"] == "not_elf"
    assert metadata["expectedCrosvmExecutable"]["status"] == "identified"
    assert metadata["expectedCrosvmExecutable"]["sha256"] == hashlib.sha256(contents).hexdigest()
    assert metadata["virglSupport"] == "uncertified"
    assert "has no recorded Virgl certification" in result.stderr
    assert str(tmp_path) not in result.stdout + result.stderr


@pytest.mark.parametrize(
    "contents",
    (
        b"synthetic crosvm wrapper, not an ELF executable",
        _elf64(None),
    ),
    ids=("non-elf", "missing-build-id"),
)
def test_virgl_preflight_refuses_an_unidentified_expected_crosvm(
    tmp_path: Path,
    contents: bytes,
) -> None:
    launch = tmp_path / "launch-wrapper"
    expected = tmp_path / "expected-crosvm"
    launch.write_text("#!/bin/sh\nexec /opt/diagnostic/crosvm\n", encoding="utf-8")
    expected.write_bytes(contents)

    result = _run_virgl_preflight(launch, expected)

    assert result.returncode == 1
    assert "Cannot verify the expected crosvm executable" in result.stderr
    assert str(tmp_path) not in result.stderr


def test_virgl_preflight_verification_detects_replacement_after_preflight(
    tmp_path: Path,
) -> None:
    executable = tmp_path / "crosvm"
    contents = _elf64(bytes.fromhex("0123456789abcdef"))
    executable.write_bytes(contents)
    expected_sha256 = hashlib.sha256(contents).hexdigest()
    executable.write_bytes(_elf64(bytes.fromhex("fedcba9876543210")))

    result = _run_virgl_verification(executable, expected_sha256)

    assert result.returncode == 1
    assert json.loads(result.stdout)["status"] == "mismatch"
    assert "changed after Virgl preflight" in result.stderr
    assert str(tmp_path) not in result.stdout + result.stderr


def test_running_crosvm_verification_reports_matching_and_mismatching_images(
    tmp_path: Path,
) -> None:
    executable = tmp_path / "crosvm"
    contents = _elf64(bytes.fromhex("0123456789abcdef"))
    executable.write_bytes(contents)
    expected_sha256 = hashlib.sha256(contents).hexdigest()

    matching = _run_virgl_verification(executable, expected_sha256, running=True)
    mismatching = _run_virgl_verification(executable, "0" * 64, running=True)

    assert matching.returncode == 0
    assert json.loads(matching.stdout)["status"] == "verified"
    assert mismatching.returncode == 1
    assert json.loads(mismatching.stdout)["status"] == "mismatch"
    assert "does not match the running process" in mismatching.stderr
    combined_output = matching.stdout + matching.stderr + mismatching.stdout + mismatching.stderr
    assert str(tmp_path) not in combined_output
