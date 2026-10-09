#!/usr/bin/env python3
"""Normalize Cuttlefish captures and compare reference boots with VZ captures."""

from __future__ import annotations

import argparse
import fnmatch
import gzip
import io
import ipaddress
import json
import os
import re
import socket
import stat
import sys
import tempfile
import time
from collections import defaultdict
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from typing import Any

if sys.version_info < (3, 12):  # noqa: UP036
    print("compare_boot.py requires Python 3.12; activate Images/tools/.venv.", file=sys.stderr)
    sys.exit(2)

RULES_PATH = Path(__file__).with_name("normalize.yaml")
# The launcher capture holds these categories. A candidate with data where the reference has none
# is a
# difference, not a category to skip (#014 step 5).
REFERENCE_HELD_CATEGORIES = frozenset({"bootconfig", "cmdline"})
CATEGORIES = (
    "cmdline",
    "bootconfig",
    "props",
    "block devices",
    "mounts",
    "modules",
    "HALs",
    "hvc users",
    "network",
    "SELinux",
)
FILE_CATEGORIES = {
    "cmdline.txt": "cmdline",
    "bootconfig.txt": "bootconfig",
    "internal-bootconfig.txt": "bootconfig",
    # The launcher's kernel log holds the reference command line; only its "Kernel command
    # line:" line counts.
    "kernel.log": "cmdline",
    "properties.txt": "props",
    "block-by-name.txt": "block devices",
    "block-sysfs.txt": "block devices",
    "block-sizes.txt": "block devices",
    "mounts.txt": "mounts",
    "fstab.txt": "mounts",
    "modules.txt": "modules",
    "first-stage-init.txt": "modules",
    "lshal.txt": "HALs",
    "services.txt": "HALs",
    "apex.txt": "HALs",
    "features.txt": "HALs",
    "audio-cards.txt": "HALs",
    "hvc-devices.txt": "hvc users",
    "hvc-users.txt": "hvc users",
    "ip-addr.txt": "network",
    "ip-route.txt": "network",
    "ip-link.txt": "network",
    "connectivity.txt": "network",
    "selinux-mode.txt": "SELinux",
    "avc-denials.txt": "SELinux",
}
TEXT_SUFFIXES = {".txt", ".log", ".json", ".yaml", ".yml", ".cfg", ".conf", ".csv"}
MAX_RULES_SIZE = 1024 * 1024
MAX_PLAIN_CAPTURE_SIZE = 64 * 1024 * 1024
MAX_GZIP_COMPRESSED_SIZE = 64 * 1024 * 1024
MAX_GZIP_UNCOMPRESSED_SIZE = 64 * 1024 * 1024
STARTED_COMMAND_LOGS = frozenset(
    {
        "crosvm-command-line.txt",
        "assemble_cvd.log",
        "kernel.log",
        "launcher.log",
        "launch-cvd-console.log",
    }
)
JSON_PATH_FILES = frozenset({"cuttlefish_config.json", "composite-disk-specs.json", "host.json"})
HOST_PATH_ROOTS = (
    "/usr/local/google/home",
    "/var/cache",
    "/var/lib",
    "/var/log",
    "/var/run",
    "/var/tmp",
    "/private/tmp",
    "/workspaces",
    "/workspace",
    "/Users",
    "/home",
    "/root",
    "/mnt",
    "/opt",
    "/run",
    "/srv",
    "/tmp",
)
DIAGNOSTIC_PREFIXES = (
    "error: permission denied",
    "error: operation not permitted",
    "error: no such file",
    "error: failed to",
    "error: unable to",
    "error: cannot",
    "permission denied",
    "operation not permitted",
    "no such file",
    "not found",
    "could not",
    "unable",
    "cannot",
    "unsupported",
    "failed to",
    "failure",
    "warning",
    "fatal",
    "unknown",
    "invalid",
    "timed out",
    "timeout",
    "denied",
)
SAFE_DIAGNOSTIC_CONTEXT_WORDS = frozenset({"see"})
CVD_STARTED_COMMAND = re.compile(r"^.*?command\.cc:\d+\] Started \(pid: \d+\):")
SHORT_OPTION_BUNDLE = re.compile(r"-[A-Za-z]{1,3}(?:=[^\s]*)?\Z")
REPLACEMENT_GROUP_REFERENCE = re.compile(r"\\g<([^>]+)>|\\([1-9][0-9]*)")
TEXT_LINE_BREAK = re.compile(r"\r\n|[\n\r\v\f\x1c-\x1e\x85\u2028\u2029]")
JSON_STRING_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"')
IPV6_ADDRESS_CANDIDATE = re.compile(
    r"(?<![0-9A-Fa-f:.])"
    r"(?:[0-9A-Fa-f]{0,4}:){2,7}"
    r"(?:[0-9A-Fa-f]{0,4}|[0-9]{1,3}(?:\.[0-9]{1,3}){3})"
    r"(?![0-9A-Fa-f:.])"
)
COMMAND_LINE_TOKEN = re.compile(r"\S+")
PRIVATE_KEY_BOUNDARY = re.compile(
    r"-----BEGIN [A-Z0-9 ]{0,64}PRIVATE KEY-----|-----END [A-Z0-9 ]{0,64}PRIVATE KEY-----"
)
MAX_CAPTURE_RECORDS = 100_000
MAX_CAPTURE_RECORD_BYTES = 64 * 1024 * 1024
MAX_CAPTURE_ENTRIES = 100_000
NormalizationRule = tuple[re.Pattern[str], str, tuple[str, ...] | None]


class CaptureToolError(Exception):
    """A user-facing capture or comparison error."""


class _RecordBudget:
    def __init__(self) -> None:
        self.records = 0
        self.text_bytes = 0


class _BoundedTextBuffer:
    def __init__(self, path: Path, operation: str) -> None:
        self._path = path
        self._operation = operation
        self._buffer = io.StringIO()
        self._size = 0

    def append(self, text: str) -> None:
        size = len(text.encode("utf-8"))
        if self._size + size > MAX_PLAIN_CAPTURE_SIZE:
            raise CaptureToolError(
                f"cannot {self._operation} {self._path}: transformed output exceeds "
                f"the {MAX_PLAIN_CAPTURE_SIZE // (1024 * 1024)} MiB limit."
            )
        self._buffer.write(text)
        self._size += size

    def getvalue(self) -> str:
        return self._buffer.getvalue()


def _read_json_yaml_subset(path: Path) -> object:
    """Read the documented JSON-compatible YAML subset without extra packages."""
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    except OSError as error:
        raise CaptureToolError(f"cannot read {path}: {error}") from None
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise CaptureToolError(f"{path} must be a regular file.")
        stream = os.fdopen(descriptor, "rb")
        descriptor = -1
        with stream:
            raw_bytes = stream.read(MAX_RULES_SIZE + 1)
            if len(raw_bytes) > MAX_RULES_SIZE or stream.read(1):
                raise CaptureToolError(f"{path} exceeds the 1 MiB configuration limit.")
        raw = raw_bytes.decode("utf-8")
    except CaptureToolError:
        raise
    except OSError as error:
        raise CaptureToolError(f"cannot read {path}: {error}") from None
    except UnicodeDecodeError:
        raise CaptureToolError(f"{path} is not valid UTF-8.") from None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    content = "\n".join(line for line in raw.splitlines() if not line.lstrip().startswith("#"))
    try:
        return json.loads(content)
    except json.JSONDecodeError as error:
        raise CaptureToolError(
            f"{path} must use JSON-compatible YAML ({error.msg} at line {error.lineno})."
        ) from None


def _load_substitutions(path: Path) -> list[NormalizationRule]:
    document = _read_json_yaml_subset(path)
    if not isinstance(document, Mapping) or document.get("schemaVersion") != 1:
        raise CaptureToolError(f"{path} has an unsupported normalization schema.")
    values = document.get("substitutions")
    if not isinstance(values, list):
        raise CaptureToolError(f"{path} must contain a substitutions array.")

    substitutions: list[tuple[re.Pattern[str], str]] = []
    for index, value in enumerate(values):
        if not isinstance(value, Mapping):
            raise CaptureToolError(f"{path} substitutions[{index}] must be an object.")
        pattern = value.get("pattern")
        replacement = value.get("replacement")
        if not isinstance(pattern, str) or not isinstance(replacement, str):
            raise CaptureToolError(
                f"{path} substitutions[{index}] needs string pattern and replacement fields."
            )
        file_values = value.get("files")
        if file_values is not None and (
            not isinstance(file_values, list)
            or not all(isinstance(filename, str) and filename for filename in file_values)
        ):
            raise CaptureToolError(f"{path} substitutions[{index}] has an invalid files array.")
        try:
            compiled = re.compile(pattern)
        except re.error as error:
            raise CaptureToolError(f"{path} substitutions[{index}] is invalid: {error}") from None
        substitutions.append(
            (compiled, replacement, tuple(file_values) if file_values is not None else None)
        )
    return substitutions


def _is_normalizable(path: Path) -> bool:
    return (
        path.name == "logcat" or path.suffix.lower() in TEXT_SUFFIXES or path.name.endswith(".gz")
    )


def _read_capture_bytes(path: Path) -> bytes:
    """Read a capture artifact, bounding compressed log input before allocation."""
    try:
        with path.open("rb") as stream:
            if path.name.endswith(".gz"):
                content = stream.read(MAX_GZIP_COMPRESSED_SIZE + 1)
                if len(content) > MAX_GZIP_COMPRESSED_SIZE or stream.read(1):
                    raise CaptureToolError(
                        f"cannot read {path}: gzip input exceeds the "
                        f"{MAX_GZIP_COMPRESSED_SIZE // (1024 * 1024)} MiB limit."
                    )
                return content
            content = stream.read(MAX_PLAIN_CAPTURE_SIZE + 1)
            if len(content) > MAX_PLAIN_CAPTURE_SIZE or stream.read(1):
                raise CaptureToolError(
                    f"cannot read {path}: file exceeds the "
                    f"{MAX_PLAIN_CAPTURE_SIZE // (1024 * 1024)} MiB limit."
                )
            return content
    except CaptureToolError:
        raise
    except OSError as error:
        raise CaptureToolError(f"cannot read {path}: {error}") from None


def _read_gzip_bounded(content: bytes, path: Path) -> bytes:
    """Decompress a capture artifact while enforcing a 64 MiB output limit."""
    output: list[bytes] = []
    total = 0
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(content), mode="rb") as stream:
            while chunk := stream.read(min(1024 * 1024, MAX_GZIP_UNCOMPRESSED_SIZE + 1 - total)):
                total += len(chunk)
                if total > MAX_GZIP_UNCOMPRESSED_SIZE:
                    raise CaptureToolError(
                        f"cannot read {path}: gzip output exceeds the "
                        f"{MAX_GZIP_UNCOMPRESSED_SIZE // (1024 * 1024)} MiB limit."
                    )
                output.append(chunk)
    except CaptureToolError:
        raise
    except (OSError, EOFError) as error:
        raise CaptureToolError(f"cannot read gzip capture artifact {path}: {error}") from None
    return b"".join(output)


def _transform_text(
    content: bytes,
    path: Path,
    relative_path: str,
    substitutions: Sequence[NormalizationRule],
) -> bytes:
    was_gzip = path.name.endswith(".gz")
    try:
        plain = _read_gzip_bounded(content, path) if was_gzip else content
        text = plain.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CaptureToolError(f"cannot normalize {path}: {error}") from None
    text = _redact_eui64_style_ipv6(text, path, operation="normalize")
    text = _redact_json_host_paths(text, path.name, path, operation="normalize")
    text = _redact_ambiguous_started_host_paths(text, path.name, path, operation="normalize")
    text = _redact_private_key_blocks(text, path, operation="normalize")
    text = _apply_substitutions(text, relative_path, substitutions, operation="normalize")
    encoded = text.encode("utf-8")
    if len(encoded) > MAX_PLAIN_CAPTURE_SIZE:
        raise CaptureToolError(
            f"cannot normalize {path}: normalized output exceeds "
            f"the {MAX_PLAIN_CAPTURE_SIZE // (1024 * 1024)} MiB limit."
        )
    if not was_gzip:
        return encoded
    compressed = gzip.compress(encoded, mtime=0)
    if len(compressed) > MAX_GZIP_COMPRESSED_SIZE:
        raise CaptureToolError(
            f"cannot normalize {path}: normalized gzip exceeds "
            f"the {MAX_GZIP_COMPRESSED_SIZE // (1024 * 1024)} MiB limit."
        )
    return compressed


def _apply_substitutions(
    text: str,
    relative_path: str,
    substitutions: Sequence[NormalizationRule],
    *,
    operation: str,
) -> str:
    path = Path(relative_path)
    for pattern, replacement, filenames in substitutions:
        if filenames is not None and not any(
            fnmatch.fnmatch(path.name, filename) for filename in filenames
        ):
            continue
        _ensure_substitution_fits(pattern, replacement, text, path, operation=operation)
        text = pattern.sub(replacement, text)
    return text


def _redact_eui64_style_ipv6(text: str, path: Path, *, operation: str) -> str:
    output = _BoundedTextBuffer(path, operation)
    cursor = 0
    changed = False
    for candidate in IPV6_ADDRESS_CANDIDATE.finditer(text):
        try:
            address = ipaddress.IPv6Address(candidate.group())
        except ipaddress.AddressValueError:
            continue
        if address.packed[11:13] != b"\xff\xfe":
            continue
        output.append(text[cursor : candidate.start()])
        output.append("<EUI64_STYLE_IPV6>")
        cursor = candidate.end()
        changed = True
    if not changed:
        return text
    output.append(text[cursor:])
    return output.getvalue()


def _ensure_substitution_fits(
    pattern: re.Pattern[str],
    replacement: str,
    text: str,
    path: Path,
    *,
    operation: str,
) -> None:
    projected_bytes = len(text.encode("utf-8"))
    references = tuple(REPLACEMENT_GROUP_REFERENCE.finditer(replacement))
    template_bytes = len(replacement.encode("utf-8"))
    if projected_bytes <= MAX_PLAIN_CAPTURE_SIZE:
        for match in pattern.finditer(text):
            replacement_bytes = template_bytes
            for reference in references:
                group_reference = reference.group(1) or reference.group(2)
                group: str | int = (
                    int(group_reference) if group_reference.isdecimal() else group_reference
                )
                try:
                    group_value = match.group(group)
                except (IndexError, KeyError):
                    continue
                if group_value is not None:
                    replacement_bytes += len(group_value.encode("utf-8"))
            projected_bytes += replacement_bytes - len(match.group(0).encode("utf-8"))
            if projected_bytes > MAX_PLAIN_CAPTURE_SIZE:
                break
    if projected_bytes > MAX_PLAIN_CAPTURE_SIZE:
        raise CaptureToolError(
            f"cannot {operation} {path}: normalized output exceeds "
            f"the {MAX_PLAIN_CAPTURE_SIZE // (1024 * 1024)} MiB limit."
        )


def _redact_json_host_paths(
    text: str,
    filename: str,
    path: Path,
    *,
    operation: str,
) -> str:
    if filename not in JSON_PATH_FILES:
        return text

    output = _BoundedTextBuffer(path, operation)
    cursor = 0
    for token in JSON_STRING_TOKEN.finditer(text):
        output.append(text[cursor : token.start()])
        original = token.group()
        try:
            value = json.loads(original)
        except json.JSONDecodeError:
            output.append(original)
        else:
            normalized = _redact_json_host_path_value(value)
            output.append(
                json.dumps(normalized, ensure_ascii=True) if normalized != value else original
            )
        cursor = token.end()
    output.append(text[cursor:])
    return output.getvalue()


def _redact_json_host_path_value(value: str) -> str:
    for path_start, character in enumerate(value):
        if character != "/":
            continue
        root_end = _host_path_root_end(value, path_start)
        if root_end is None:
            continue
        prefix_end = path_start
        if (
            path_start >= 2
            and value[path_start - 2] == "-"
            and value[path_start - 1].isascii()
            and value[path_start - 1].isalpha()
        ):
            prefix_end = path_start - 2
        return f"{value[:prefix_end]}{value[prefix_end:path_start]}<HOST_PATH>"
    return value


def _redact_private_key_blocks(text: str, path: Path, *, operation: str) -> str:
    """Redact complete PEM private-key blocks in one linear marker scan."""
    output: _BoundedTextBuffer | None = None
    cursor = 0
    block_start: int | None = None
    for marker in PRIVATE_KEY_BOUNDARY.finditer(text):
        if marker.group().startswith("-----BEGIN "):
            if block_start is None:
                block_start = marker.start()
        elif block_start is not None:
            if output is None:
                output = _BoundedTextBuffer(path, operation)
            output.append(text[cursor:block_start])
            output.append("<REDACTED_PRIVATE_KEY>")
            cursor = marker.end()
            block_start = None
    if output is None:
        return text
    output.append(text[cursor:])
    return output.getvalue()


def _redact_ambiguous_started_host_paths(
    text: str,
    filename: str,
    path: Path,
    *,
    operation: str,
) -> str:
    """Redact ambiguous unquoted host paths in Cuttlefish command records."""
    if filename not in STARTED_COMMAND_LOGS:
        return text

    output = _BoundedTextBuffer(path, operation)
    line_start = 0
    for line_break in TEXT_LINE_BREAK.finditer(text):
        line_end = line_break.end()
        output.append(_redact_started_command_line(text[line_start:line_end]))
        line_start = line_end
    if line_start < len(text):
        output.append(_redact_started_command_line(text[line_start:]))
    return output.getvalue()


def _iter_text_lines(text: str) -> Iterator[str]:
    line_start = 0
    for line_break in TEXT_LINE_BREAK.finditer(text):
        yield text[line_start : line_break.start()]
        line_start = line_break.end()
    if line_start < len(text):
        yield text[line_start:]


def _redact_started_command_line(line: str) -> str:
    started = CVD_STARTED_COMMAND.match(line)
    if started is None:
        return line

    search_from = started.end()
    while search_from < len(line):
        option_index = line.find("-", search_from)
        if option_index < 0 or option_index + 2 >= len(line):
            return line
        if (
            line[option_index + 1].isascii()
            and line[option_index + 1].isalpha()
            and line[option_index + 2] == "/"
            and (option_index == started.end() or line[option_index - 1] in " \t")
        ):
            root_end = _host_path_root_end(line, option_index + 2)
            if root_end is not None:
                component_end = root_end
                while component_end < len(line) and line[component_end] not in " \t\r\n":
                    component_end += 1

                continuation = component_end
                while continuation < len(line) and line[continuation] in " \t":
                    continuation += 1
                if continuation >= len(line) or line[continuation] in "\r\n":
                    return line

                next_component_end = continuation
                while next_component_end < len(line) and line[next_component_end] not in " \t\r\n":
                    next_component_end += 1
                component = line[continuation:next_component_end]
                remainder = line[next_component_end:].lstrip(" \t")
                if (
                    component == "--" or SHORT_OPTION_BUNDLE.fullmatch(component)
                ) and _starts_with_diagnostic(remainder):
                    return line

                newline = line[len(line.rstrip("\r\n")) :]
                return (
                    f"{line[:option_index]}{line[option_index : option_index + 2]}"
                    f"<HOST_PATH_WITH_SPACES>{newline}"
                )
        search_from = option_index + 1

    return line


def _starts_with_diagnostic(text: str) -> bool:
    candidate = text.lstrip(" \t").casefold()
    for prefix in DIAGNOSTIC_PREFIXES:
        if not candidate.startswith(prefix):
            continue
        remainder = candidate[len(prefix) :]
        if not remainder or remainder.isspace():
            return True
        if remainder.startswith("."):
            if not remainder[1:].strip():
                return True
            continue
        if remainder[0] in ";,!:":
            diagnostic_tail = remainder[1:]
            if diagnostic_tail and not diagnostic_tail[0].isspace():
                continue
        elif remainder[0].isspace():
            diagnostic_tail = remainder
        else:
            continue
        if _diagnostic_tail_has_only_host_paths(diagnostic_tail):
            return True
    return False


def _diagnostic_tail_has_only_host_paths(text: str) -> bool:
    for match in COMMAND_LINE_TOKEN.finditer(text):
        token = match.group()
        if "/" not in token:
            context_word = token.strip("()[]{}<>,;.!?:'\"").casefold()
            if context_word in SAFE_DIAGNOSTIC_CONTEXT_WORDS:
                continue
            if not context_word:
                continue
            return False
        path = token.strip("()[]{}<>,;.!?'\"")
        if len(path) >= 3 and path[0] == "-" and path[1].isascii() and path[1].isalpha():
            path = path[2:]
        if _host_path_root_end(path, 0) is None:
            return False
    return True


def _host_path_root_end(line: str, path_start: int) -> int | None:
    for root in HOST_PATH_ROOTS:
        if line.startswith(root, path_start):
            root_end = path_start + len(root)
            if root_end < len(line) and line[root_end] == "/":
                return root_end
    return None


def _atomic_replace(path: Path, content: bytes) -> None:
    try:
        original_mode = stat.S_IMODE(os.stat(path, follow_symlinks=False).st_mode)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content)
            os.chmod(temporary, original_mode)
            os.replace(temporary, path)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    except OSError as error:
        raise CaptureToolError(f"cannot update {path}: {error}") from None


def normalize_capture(directory: Path, rules_path: Path = RULES_PATH) -> int:
    """Normalize text artifacts in place and return the number changed."""
    if directory.is_symlink():
        raise CaptureToolError(f"capture directory must not be a symbolic link: {directory}")
    if not directory.is_dir():
        raise CaptureToolError(f"capture directory does not exist: {directory}")
    substitutions = _load_substitutions(rules_path)
    changed = 0
    for path in _bounded_capture_paths(directory):
        if path.is_symlink():
            raise CaptureToolError(f"capture contains a symbolic link: {path}")
        if not path.is_file() or not _is_normalizable(path):
            continue
        try:
            before = _read_capture_bytes(path)
            after = _transform_text(
                before,
                path,
                path.relative_to(directory).as_posix(),
                substitutions,
            )
            if before != after:
                _atomic_replace(path, after)
                changed += 1
        except CaptureToolError:
            if path.name not in {"logcat", "host-logcat.txt"}:
                raise
            try:
                path.unlink()
                with (directory / "MISSING.txt").open("a", encoding="utf-8") as missing:
                    missing.write(
                        "host-logcat.txt\toptional host logcat was discarded because it "
                        "could not be safely normalized; this capture is incomplete\n"
                    )
            except OSError:
                raise CaptureToolError(
                    "cannot safely discard an unnormalizable optional host logcat artifact."
                ) from None
            changed += 1
    return changed


def _bounded_capture_paths(directory: Path) -> list[Path]:
    paths: list[Path] = []
    for path in directory.rglob("*"):
        if len(paths) >= MAX_CAPTURE_ENTRIES:
            raise CaptureToolError(
                f"capture directory {directory} exceeds the "
                f"{MAX_CAPTURE_ENTRIES}-entry traversal limit."
            )
        if path.is_symlink():
            raise CaptureToolError(f"capture contains a symbolic link: {path}")
        paths.append(path)
    paths.sort()
    return paths


def _capture_category_paths(directory: Path) -> dict[str, list[Path]]:
    paths_by_category: dict[str, list[Path]] = {category: [] for category in CATEGORIES}
    for path in _bounded_capture_paths(directory):
        if not path.is_file():
            continue
        category = FILE_CATEGORIES.get(path.name)
        if category is not None:
            paths_by_category[category].append(path)
    return paths_by_category


def _read_capture_text(
    path: Path,
    relative_path: str,
    substitutions: Sequence[NormalizationRule] = (),
) -> Iterator[str]:
    try:
        content = _read_capture_bytes(path)
        plain = _read_gzip_bounded(content, path) if path.name.endswith(".gz") else content
        text = plain.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise CaptureToolError(f"cannot read capture artifact {path}: {error}") from None
    text = _redact_eui64_style_ipv6(text, path, operation="compare")
    text = _redact_json_host_paths(text, path.name, path, operation="compare")
    text = _redact_ambiguous_started_host_paths(text, path.name, path, operation="compare")
    text = _redact_private_key_blocks(text, path, operation="compare")
    text = _apply_substitutions(text, relative_path, substitutions, operation="compare")
    if len(text.encode("utf-8")) > MAX_PLAIN_CAPTURE_SIZE:
        raise CaptureToolError(
            f"cannot compare {path}: normalized output exceeds "
            f"the {MAX_PLAIN_CAPTURE_SIZE // (1024 * 1024)} MiB limit."
        )
    yield from _iter_text_lines(text)


def _category_records(
    directory: Path,
    category: str,
    substitutions: Sequence[NormalizationRule],
    budget: _RecordBudget,
    paths: Sequence[Path],
) -> dict[str, str]:
    records: dict[str, str] = {}
    occurrences: defaultdict[str, int] = defaultdict(int)

    def add_record(key: str, value: str, source: Path) -> None:
        if budget.records >= MAX_CAPTURE_RECORDS:
            raise CaptureToolError(
                f"cannot compare {source}: capture comparison data exceeds the "
                f"{MAX_CAPTURE_RECORDS}-record limit."
            )
        occurrence = occurrences[key] + 1
        stored_key = key if occurrence == 1 else f"{key}#{occurrence}"
        entry_bytes = len(stored_key.encode("utf-8")) + len(value.encode("utf-8"))
        if budget.text_bytes + entry_bytes > MAX_CAPTURE_RECORD_BYTES:
            raise CaptureToolError(
                f"cannot compare {source}: capture comparison data exceeds the "
                f"{MAX_CAPTURE_RECORD_BYTES // (1024 * 1024)} MiB record-text limit."
            )
        occurrences[key] = occurrence
        budget.records += 1
        budget.text_bytes += entry_bytes
        records[stored_key] = value

    for path in paths:
        if path.is_symlink():
            raise CaptureToolError(f"capture contains a symbolic link: {path}")
        if not path.is_file() or FILE_CATEGORIES.get(path.name) != category:
            continue
        relative = path.relative_to(directory).as_posix()
        for line_number, line in enumerate(
            _read_capture_text(path, relative, substitutions), start=1
        ):
            if not line.strip():
                continue
            if category == "bootconfig" and line.lstrip().startswith("#"):
                # `# Parameters from bootloader:` repeats the command line, which cmdline compares.
                continue
            if category == "cmdline":
                if path.name == "kernel.log":
                    marker = "Kernel command line:"
                    if marker not in line:
                        continue
                    line = line.split(marker, 1)[1]
                for token_index, match in enumerate(COMMAND_LINE_TOKEN.finditer(line), start=1):
                    token = match.group()
                    key, separator, value = token.partition("=")
                    if not separator:
                        key, value = f"arg[{token_index}]", token
                    add_record(key, value, path)
                continue
            key, value = _record_key(category, relative, line, line_number)
            add_record(key, value, path)
    return records


def _bootconfig_value(text: str) -> str:
    """Return a bootconfig value without its statement semicolon or its quotes."""
    value = text.strip().removesuffix(";").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _record_key(category: str, relative: str, line: str, line_number: int) -> tuple[str, str]:
    """Extract stable keys from common Android output formats."""
    if category == "props":
        match = re.match(r"^\[([^\]]+)\]: \[(.*)\]$", line)
        if match:
            return match.group(1), match.group(2)
    if category == "bootconfig":
        match = re.match(r"^\s*([^\s=]+)\s*=\s*(.*?)\s*$", line)
        if match:
            return match.group(1), _bootconfig_value(match.group(2))
    fields = COMMAND_LINE_TOKEN.finditer(line)
    first = next(fields, None)
    second = next(fields, None)
    first_value = first.group() if first is not None else None
    second_value = second.group() if second is not None else None
    if category == "block devices":
        if relative.endswith("block-by-name.txt") and " -> " in line:
            left, value = line.split(" -> ", 1)
            return f"{relative}:{left.strip()}", value.strip()
        if relative.endswith("block-sysfs.txt") and " -> " in line:
            left, value = line.split(" -> ", 1)
            return f"{relative}:{left.strip()}", value.strip()
        if first is not None:
            tail = re.sub(r"\s+", " ", line[first.end() :]).strip()
            return f"{relative}:{first_value}", tail
    if category == "mounts":
        if second_value is not None:
            return f"{relative}:{second_value}", line
    if category == "modules" and first_value is not None:
        return f"{relative}:{first_value}", line
    if category == "HALs":
        service = re.match(r"^\s*\d+\s+([^:]+):", line)
        if service:
            return f"{relative}:{service.group(1).strip()}", line
        if first_value is not None:
            return f"{relative}:{first_value}", line
    if category == "hvc users":
        holder = re.match(r"^\s*(.*?)\s+fd=(\d+)\s+->\s+(\S+)", line)
        if holder:
            return f"{relative}:{holder.group(1)}:fd{holder.group(2)}", holder.group(3)
        if first_value is not None:
            return f"{relative}:{first_value}", line
    if category == "network":
        interface = re.match(r"^\s*\d+:\s+([^:]+):", line)
        if interface:
            return f"{relative}:{interface.group(1)}", line
        if first_value is not None:
            return f"{relative}:{first_value}", line
    if category == "SELinux":
        if relative.endswith("selinux-mode.txt"):
            return "getenforce", line.strip()
        if "avc: denied" in line:
            permission = re.search(r"avc: denied\s+(\{[^}]*\})", line)
            source = re.search(r"\bscontext=([^\s]+)", line)
            target = re.search(r"\btcontext=([^\s]+)", line)
            object_class = re.search(r"\btclass=([^\s]+)", line)
            command = re.search(r'\bcomm="([^"]*)"', line)
            identity = ":".join(
                match.group(1) if match else "unknown"
                for match in (permission, source, target, object_class, command)
            )
            return f"{relative}:{identity}", line
    return f"{relative}:line:{line_number}", line


def _load_expected_differences(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    document = _read_json_yaml_subset(path)
    if not isinstance(document, list):
        raise CaptureToolError(f"{path} must contain an array of expected differences.")
    entries: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for index, entry in enumerate(document):
        if not isinstance(entry, Mapping):
            raise CaptureToolError(f"{path} entry {index} must be an object.")
        category, key, reason, design = (
            entry.get("category"),
            entry.get("key"),
            entry.get("reason"),
            entry.get("design"),
        )
        if category not in CATEGORIES or not all(
            isinstance(value, str) and value.strip() for value in (key, reason, design)
        ):
            raise CaptureToolError(
                f"{path} entry {index} needs a known category, key, reason, and design."
            )
        identity = (category, key)
        if identity in seen:
            raise CaptureToolError(f"{path} contains a duplicate category/key entry: {identity}.")
        seen.add(identity)
        entries.append({"category": category, "key": key, "reason": reason, "design": design})
    return entries


def _compare(
    reference: Path,
    candidate: Path,
    expected_entries: Sequence[Mapping[str, str]],
    substitutions: Sequence[NormalizationRule],
) -> tuple[list[dict[str, Any]], list[dict[str, str]], list[str]]:
    expected_by_key = {(entry["category"], entry["key"]): entry for entry in expected_entries}
    used_expected: set[tuple[str, str]] = set()
    differences: list[dict[str, Any]] = []
    not_compared: list[str] = []
    reference_budget = _RecordBudget()
    candidate_budget = _RecordBudget()
    reference_paths = _capture_category_paths(reference)
    candidate_paths = _capture_category_paths(candidate)
    for category in CATEGORIES:
        before = _category_records(
            reference, category, substitutions, reference_budget, reference_paths[category]
        )
        after = _category_records(
            candidate, category, substitutions, candidate_budget, candidate_paths[category]
        )
        if not before and after and category not in REFERENCE_HELD_CATEGORIES:
            # The launcher capture holds no booted data for this category (IR-305, IR-367).
            not_compared.append(category)
            continue
        if not before or not after:
            differences.append(
                {
                    "category": category,
                    "key": "<capture data>",
                    "reference": "<no category data>" if not before else "<present>",
                    "candidate": "<no category data>" if not after else "<present>",
                    "expected": None,
                }
            )
            continue
        for key in sorted(before.keys() | after.keys()):
            if before.get(key) == after.get(key):
                continue
            identity = (category, key)
            expected = expected_by_key.get(identity)
            if expected is not None:
                used_expected.add(identity)
            differences.append(
                {
                    "category": category,
                    "key": key,
                    "reference": before.get(key, "<missing>"),
                    "candidate": after.get(key, "<missing>"),
                    "expected": dict(expected) if expected is not None else None,
                }
            )
    stale = [
        dict(entry)
        for entry in expected_entries
        if (entry["category"], entry["key"]) not in used_expected
    ]
    return differences, stale, not_compared


def _write_report(
    report_directory: Path,
    reference: Path,
    candidate: Path,
    differences: Sequence[Mapping[str, Any]],
    stale: Sequence[Mapping[str, str]],
    not_compared: Sequence[str] = (),
) -> None:
    unexplained = [item for item in differences if item["expected"] is None]
    document = {
        "schemaVersion": 1,
        "reference": reference.name,
        "candidate": candidate.name,
        "differenceCount": len(differences),
        "unexplainedCount": len(unexplained),
        "differences": list(differences),
        "staleExpectedDifferences": list(stale),
        "notComparedCategories": sorted(not_compared),
    }
    try:
        report_directory.mkdir(parents=True, exist_ok=True)
        if report_directory.is_symlink():
            raise CaptureToolError(
                f"report directory must not be a symbolic link: {report_directory}"
            )
        json_path = report_directory / "report.json"
        text_path = report_directory / "report.txt"
        json_content = (
            json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        lines = [
            "APKRun reference boot comparison",
            f"Reference: {reference.name}",
            f"Candidate: {candidate.name}",
            (
                f"Differences: {len(differences)} "
                f"({len(unexplained)} unexplained, {len(differences) - len(unexplained)} explained)"
            ),
        ]
        for item in differences:
            state = "unexplained" if item["expected"] is None else "explained"
            lines.append(f"[{state}] {item['category']} :: {item['key']}")
            lines.append(f"  reference: {item['reference']}")
            lines.append(f"  candidate: {item['candidate']}")
            if item["expected"] is not None:
                lines.append(f"  reason: {item['expected']['reason']}")
                lines.append(f"  design: {item['expected']['design']}")
        for item in stale:
            lines.append(
                f"[warning] stale expected difference: {item['category']} :: {item['key']}"
            )
        _atomic_replace_report(json_path, json_content)
        _atomic_replace_report(text_path, ("\n".join(lines) + "\n").encode("utf-8"))
    except CaptureToolError:
        raise
    except OSError as error:
        raise CaptureToolError(f"cannot write comparison reports: {error}") from None


def _atomic_replace_report(path: Path, content: bytes) -> None:
    """Replace a report entry atomically without following an existing symlink."""
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def compare_captures(
    reference: Path,
    candidate: Path,
    *,
    expected_path: Path | None = None,
    report_directory: Path | None = None,
    rules_path: Path = RULES_PATH,
) -> int:
    """Compare ten documented boot categories and write JSON/text reports."""
    if not reference.is_dir():
        raise CaptureToolError(f"reference capture directory does not exist: {reference}")
    if not candidate.is_dir():
        raise CaptureToolError(f"candidate capture directory does not exist: {candidate}")
    expected_file = expected_path or reference.parent / "expected-differences.yaml"
    expected = _load_expected_differences(expected_file)
    substitutions = _load_substitutions(rules_path)
    differences, stale, not_compared = _compare(reference, candidate, expected, substitutions)
    output_directory = report_directory or candidate
    _write_report(output_directory, reference, candidate, differences, stale, not_compared)
    for category in not_compared:
        print(f"not compared: {category} (the reference holds no booted data)")

    unexplained = [item for item in differences if item["expected"] is None]
    for item in unexplained:
        print(f"unexplained: {item['category']} :: {item['key']}")
    for item in differences:
        if item["expected"] is not None:
            print(f"explained: {item['category']} :: {item['key']}")
    for item in stale:
        print(
            f"warning: stale expected difference: {item['category']} :: {item['key']}",
            file=sys.stderr,
        )
    print(
        f"Compared {len(CATEGORIES)} categories; {len(differences)} differences "
        f"({len(unexplained)} unexplained). Reports: "
        f"{output_directory / 'report.json'} and {output_directory / 'report.txt'}"
    )
    return 1 if unexplained else 0


GUEST_CAPTURE_PATH = Path(__file__).with_name("guest-capture.txt")
SHELL_COMMAND_TIMEOUT_SECONDS = 60.0
SHELL_READ_BYTES = 65_536
MAX_SHELL_CAPTURE_BYTES = 64 * 1024 * 1024


def _read_guest_commands(path: Path) -> list[tuple[str, str]]:
    """Read `<output file>\\t<guest command>` lines, skipping blanks and `#` comments."""
    commands: list[tuple[str, str]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise CaptureToolError(f"cannot read the guest command list {path}: {error}") from None
    for line_number, raw in enumerate(lines, start=1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        name, separator, command = raw.partition("\t")
        if not separator or not command.strip() or Path(name).name != name or not name:
            raise CaptureToolError(
                f"{path}:{line_number} must be '<output file>' TAB '<guest command>'."
            )
        commands.append((name, command.strip()))
    return commands


_SHELL_PROMPT = "console:/ $ "


def _without_shell_echo(body: str) -> str:
    """Drop the shell's echo of the command from a reply, and the prompt in front of the output.

    The echo line carries the sentinel text, and command output never does. The prompt is only text
    in front of the first output line, so the output after it is kept.
    """
    kept: list[str] = []
    for line in body.split("\n"):
        if line.startswith(_SHELL_PROMPT):
            line = line[len(_SHELL_PROMPT) :]
        if "__APKRUN_END_" in line:
            continue
        kept.append(line)
    return "\n".join(kept)


class _ShellSession:
    """Run guest commands one at a time over the serial shell, reading to each sentinel."""

    def __init__(self, connection: socket.socket) -> None:
        self._connection = connection
        self._pending = b""

    def run(self, command: str, index: int, timeout: float) -> tuple[str, int]:
        sentinel = f"__APKRUN_END_{index}__"
        try:
            self._connection.sendall(f"{command}; echo {sentinel} $?\n".encode())
        except OSError as error:
            raise CaptureToolError(
                f"cannot send `{command}` to the serial shell: {error}"
            ) from None
        # The status line ends in a newline, so a status split across reads (127 as 12) never
        # matches.
        pattern = re.compile(
            rb"^" + re.escape(sentinel.encode()) + rb" (-?\d+)\r?\n", re.MULTILINE
        )
        deadline = time.monotonic() + timeout
        while True:
            match = pattern.search(self._pending)
            if match:
                body = self._pending[: match.start()].decode("utf-8", errors="replace")
                self._pending = self._pending[match.end() :]
                return _without_shell_echo(body), int(match.group(1))
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CaptureToolError(
                    f"the serial shell did not finish `{command}` within {timeout:g} s"
                )
            self._connection.settimeout(remaining)
            try:
                chunk = self._connection.recv(SHELL_READ_BYTES)
            except TimeoutError:
                continue
            except OSError as error:
                raise CaptureToolError(
                    f"the serial shell failed during `{command}`: {error}"
                ) from None
            if not chunk:
                raise CaptureToolError(
                    f"the serial shell closed the connection during `{command}`"
                )
            self._pending += chunk
            if len(self._pending) > MAX_SHELL_CAPTURE_BYTES:
                raise CaptureToolError(
                    f"`{command}` produced more than the capture limit of output"
                )


def _require_socket(path: Path) -> None:
    try:
        mode = os.stat(path, follow_symlinks=False).st_mode
    except OSError as error:
        raise CaptureToolError(f"no serial shell socket at {path}: {error.strerror}") from None
    if not stat.S_ISSOCK(mode):
        raise CaptureToolError(f"{path} is not a socket")


def _write_capture_output(path: Path, content: bytes) -> None:
    """Create or replace one capture file without following a symbolic link."""
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content)
            os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    except OSError as error:
        raise CaptureToolError(f"cannot write {path}: {error}") from None


def capture_vz(
    shell: Path,
    output: Path,
    *,
    commands_path: Path = GUEST_CAPTURE_PATH,
    timeout: float = SHELL_COMMAND_TIMEOUT_SECONDS,
) -> int:
    """Run the reference command list on the VZ serial shell and write one file per output.

    The shell echo is turned off for the capture, so the replies hold only the commands' output.
    Each file's name comes from the command list, and `.gz` names are gzip-compressed. The
    statuses go to `capture-status.txt`. Returns the number of commands run.
    """
    commands = _read_guest_commands(commands_path)
    _require_socket(shell)
    if output.is_symlink():
        raise CaptureToolError(f"capture directory must not be a symbolic link: {output}")
    output.mkdir(parents=True, exist_ok=True)
    statuses: list[str] = []
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        try:
            connection.connect(str(shell))
        except OSError as error:
            raise CaptureToolError(
                f"cannot connect to the serial shell {shell}: {error.strerror}"
            ) from None
        session = _ShellSession(connection)
        _, echo_status = session.run("stty -echo", 0, timeout)
        if echo_status != 0:
            raise CaptureToolError(
                "the serial shell would not turn its echo off; the capture is not clean"
            )
        try:
            for index, (name, command) in enumerate(commands, start=1):
                body, status = session.run(command, index, timeout)
                content = body.replace("\r", "").encode("utf-8")
                if name.endswith(".gz"):
                    content = gzip.compress(content, mtime=0)
                _write_capture_output(output / name, content)
                statuses.append(f"{name}\t{status}")
        finally:
            try:
                session.run("stty echo", 0, timeout)
            except CaptureToolError:
                pass
    status_text = "\n".join(statuses) + "\n"
    _write_capture_output(output / "capture-status.txt", status_text.encode())
    return len(commands)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Normalize a Cuttlefish capture or compare two boot captures."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="normalize directory, or reference and candidate",
    )
    parser.add_argument("--rules", type=Path, default=RULES_PATH, help="normalization rules file")
    parser.add_argument("--expected", type=Path, help="expected-differences YAML subset")
    parser.add_argument("--report-dir", type=Path, help="directory for report.json and report.txt")
    return parser


def _capture_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="compare_boot.py capture-vz",
        description="Run the reference guest commands on the VZ serial shell and save the output.",
    )
    parser.add_argument(
        "--shell", required=True, type=Path, help="the hvc1 socket of `apkrun dev boot`"
    )
    parser.add_argument("--out", required=True, type=Path, help="directory for the capture files")
    parser.add_argument(
        "--commands", type=Path, default=GUEST_CAPTURE_PATH, help="guest command list"
    )
    parser.add_argument(
        "--timeout", type=float, default=SHELL_COMMAND_TIMEOUT_SECONDS, help="seconds per command"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments_list = list(sys.argv[1:] if argv is None else argv)
    if arguments_list and arguments_list[0] == "capture-vz":
        capture_arguments = _capture_parser().parse_args(arguments_list[1:])
        try:
            count = capture_vz(
                capture_arguments.shell,
                capture_arguments.out,
                commands_path=capture_arguments.commands,
                timeout=capture_arguments.timeout,
            )
        except CaptureToolError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        print(f"Captured {count} guest outputs into {capture_arguments.out}.")
        return 0
    parser = _build_parser()
    arguments = parser.parse_args(arguments_list)
    try:
        if len(arguments.paths) == 2 and str(arguments.paths[0]) == "normalize":
            count = normalize_capture(arguments.paths[1], arguments.rules)
            print(f"Normalized {count} files in {arguments.paths[1]}.")
            return 0
        if len(arguments.paths) != 2:
            parser.error("use 'normalize <directory>' or '<reference> <candidate>'.")
        return compare_captures(
            arguments.paths[0],
            arguments.paths[1],
            expected_path=arguments.expected,
            report_directory=arguments.report_dir,
            rules_path=arguments.rules,
        )
    except CaptureToolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
