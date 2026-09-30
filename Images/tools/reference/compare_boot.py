#!/usr/bin/env python3
"""Normalize Cuttlefish captures and compare reference boots with VZ captures."""

from __future__ import annotations

import argparse
import fnmatch
import gzip
import io
import json
import os
import re
import stat
import sys
import tempfile
from collections import defaultdict
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

if sys.version_info < (3, 12):  # noqa: UP036
    print("compare_boot.py requires Python 3.12; activate Images/tools/.venv.", file=sys.stderr)
    sys.exit(2)

RULES_PATH = Path(__file__).with_name("normalize.yaml")
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
MAX_GZIP_COMPRESSED_SIZE = 64 * 1024 * 1024
MAX_GZIP_UNCOMPRESSED_SIZE = 64 * 1024 * 1024
NormalizationRule = tuple[re.Pattern[str], str, tuple[str, ...] | None]


class CaptureToolError(Exception):
    """A user-facing capture or comparison error."""


def _read_json_yaml_subset(path: Path) -> object:
    """Read the documented JSON-compatible YAML subset without extra packages."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise CaptureToolError(f"cannot read {path}: {error}") from None
    except UnicodeDecodeError:
        raise CaptureToolError(f"{path} is not valid UTF-8.") from None
    if len(raw.encode("utf-8")) > MAX_RULES_SIZE:
        raise CaptureToolError(f"{path} exceeds the 1 MiB configuration limit.")
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
    return path.suffix.lower() in TEXT_SUFFIXES or path.name.endswith(".gz")


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
            return stream.read()
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
    for pattern, replacement, filenames in substitutions:
        if filenames is not None and not any(
            fnmatch.fnmatch(Path(relative_path).name, filename) for filename in filenames
        ):
            continue
        text = pattern.sub(replacement, text)
    encoded = text.encode("utf-8")
    return gzip.compress(encoded, mtime=0) if was_gzip else encoded


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
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise CaptureToolError(f"capture contains a symbolic link: {path}")
        if not path.is_file() or not _is_normalizable(path):
            continue
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
    return changed


def _read_capture_text(
    path: Path,
    relative_path: str,
    substitutions: Sequence[NormalizationRule] = (),
) -> list[str]:
    try:
        content = _read_capture_bytes(path)
        plain = _read_gzip_bounded(content, path) if path.name.endswith(".gz") else content
        text = plain.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise CaptureToolError(f"cannot read capture artifact {path}: {error}") from None
    for pattern, replacement, filenames in substitutions:
        if filenames is not None and not any(
            fnmatch.fnmatch(Path(relative_path).name, filename) for filename in filenames
        ):
            continue
        text = pattern.sub(replacement, text)
    return text.splitlines()


def _category_records(
    directory: Path,
    category: str,
    substitutions: Sequence[NormalizationRule],
) -> dict[str, str]:
    records: dict[str, str] = {}
    occurrences: defaultdict[str, int] = defaultdict(int)
    for path in sorted(directory.rglob("*")):
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
            if category == "cmdline":
                for token_index, token in enumerate(line.split(), start=1):
                    key, separator, value = token.partition("=")
                    if not separator:
                        key, value = f"arg[{token_index}]", token
                    occurrences[key] += 1
                    if occurrences[key] > 1:
                        key = f"{key}#{occurrences[key]}"
                    records[key] = value
                continue
            key, value = _record_key(category, relative, line, line_number)
            occurrences[key] += 1
            if occurrences[key] > 1:
                key = f"{key}#{occurrences[key]}"
            records[key] = value
    return records


def _record_key(category: str, relative: str, line: str, line_number: int) -> tuple[str, str]:
    """Extract stable keys from common Android output formats."""
    if category == "props":
        match = re.match(r"^\[([^\]]+)\]: \[(.*)\]$", line)
        if match:
            return match.group(1), match.group(2)
    if category == "bootconfig":
        match = re.match(r"^\s*([^\s=]+)\s*=\s*(.*?)\s*$", line)
        if match:
            return match.group(1), match.group(2)
    fields = line.split()
    if category == "block devices":
        if relative.endswith("block-by-name.txt") and " -> " in line:
            left, value = line.split(" -> ", 1)
            return f"{relative}:{left.strip()}", value.strip()
        if relative.endswith("block-sysfs.txt") and " -> " in line:
            left, value = line.split(" -> ", 1)
            return f"{relative}:{left.strip()}", value.strip()
        if fields:
            return f"{relative}:{fields[0]}", " ".join(fields[1:])
    if category == "mounts":
        if len(fields) >= 2:
            return f"{relative}:{fields[1]}", line
    if category == "modules" and fields:
        return f"{relative}:{fields[0]}", line
    if category == "HALs":
        service = re.match(r"^\s*\d+\s+([^:]+):", line)
        if service:
            return f"{relative}:{service.group(1).strip()}", line
        if fields:
            return f"{relative}:{fields[0]}", line
    if category == "hvc users":
        holder = re.match(r"^\s*(.*?)\s+fd=(\d+)\s+->\s+(\S+)", line)
        if holder:
            return f"{relative}:{holder.group(1)}:fd{holder.group(2)}", holder.group(3)
        if fields:
            return f"{relative}:{fields[0]}", line
    if category == "network":
        interface = re.match(r"^\s*\d+:\s+([^:]+):", line)
        if interface:
            return f"{relative}:{interface.group(1)}", line
        if fields:
            return f"{relative}:{fields[0]}", line
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
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    expected_by_key = {(entry["category"], entry["key"]): entry for entry in expected_entries}
    used_expected: set[tuple[str, str]] = set()
    differences: list[dict[str, Any]] = []
    for category in CATEGORIES:
        before = _category_records(reference, category, substitutions)
        after = _category_records(candidate, category, substitutions)
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
    return differences, stale


def _write_report(
    report_directory: Path,
    reference: Path,
    candidate: Path,
    differences: Sequence[Mapping[str, Any]],
    stale: Sequence[Mapping[str, str]],
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
    differences, stale = _compare(reference, candidate, expected, substitutions)
    output_directory = report_directory or candidate
    _write_report(output_directory, reference, candidate, differences, stale)

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


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    arguments = parser.parse_args(argv)
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
