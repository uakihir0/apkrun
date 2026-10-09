"""Validate a runtime image manifest (runtime-image-manifest.md §5, §7.2; #065).

`validate` runs the JSON Schema of §5 first. Only when that passes does it run
the semantic rules S1–S14. Each violation names its rule: `schema` or `S1`…`S14`,
with the JSON pointer of the first problem. ImageCore's
`RuntimeImageManifestRules` reports the same rule names for the same documents,
and both sides check the fixtures in `tests/fixtures/runtime-manifests/`.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schemas/runtime-image-manifest.schema.json"
MAX_MANIFEST_BYTES = 1024 * 1024
SECTOR_BYTES = 512
BACKUP_GPT_SECTORS = 34
_IMAGE_VERSION = re.compile(
    r"^([0-9]{4})\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})-(cf[0-9]{1,20}|ar[0-9]{6})-(arm64)$"
)


@dataclass(frozen=True)
class Violation:
    """One failed check: its rule name, the JSON pointer, and a reason."""

    rule: str
    path: str
    reason: str


def _schema() -> dict[str, Any]:
    loaded = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError("the manifest schema is not an object")
    return loaded


def _pointer(parts: Sequence[object]) -> str:
    return "/" + "/".join(str(part) for part in parts)


def schema_violations(document: object) -> list[Violation]:
    """Return the JSON Schema violations, sorted by pointer (the first one is reported)."""
    validator = Draft202012Validator(_schema())
    errors = sorted(
        validator.iter_errors(document), key=lambda error: _pointer(list(error.absolute_path))
    )
    return [
        Violation("schema", _pointer(list(error.absolute_path)), error.message) for error in errors
    ]


def _triple(text: str) -> tuple[int, int, int]:
    match = _IMAGE_VERSION.fullmatch(text)
    if match is None:
        raise ValueError(f"{text} is not a full image version")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def _short_triple(text: str) -> tuple[int, int, int]:
    year, month, sequence = text.split(".")
    return int(year), int(month), int(sequence)


def _files_by_path(document: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    return {entry["path"]: entry for entry in document["files"]}


def _sdk_floor(sdk: int) -> int:
    return 23 if sdk <= 34 else 24


def semantic_violations(document: Mapping[str, Any]) -> list[Violation]:
    """Return the violations of the semantic rules S1–S14 for a schema-valid document.

    The rules are checked in order, and a document can break several at once, so
    the list can hold more than one violation. The first is the one reported.
    """
    found: list[Violation] = []

    def fail(rule: str, path: str, reason: str) -> None:
        found.append(Violation(rule, path, reason))

    source = document["provenance"]["source"]
    origin = source["origin"]
    image_version = document["imageVersion"]
    base = image_version.split("-")[1]
    expected_base = f"cf{source['buildId']}" if origin == "ci.android.com" else source["buildId"]
    if base != expected_base:
        fail("S1", "/imageVersion", f"base {base} must be {expected_base}")

    if (document["kind"] == "stock") != (origin == "ci.android.com"):
        fail("S2", "/kind", "kind is stock exactly when the origin is ci.android.com")

    files = _files_by_path(document)
    named: dict[str, tuple[int, str | None]] = {}
    boot = document["boot"]
    for key in ("kernel", "ramdisk", "bootconfig", "cmdline"):
        entry = boot[key]
        named[entry["path"]] = (entry["size"], entry["sha256"])
    for disk in document["disks"] + document["templates"]:
        named[disk["path"]] = (disk["logicalSize"], None)
    if "legal" in document:
        notice = document["legal"]["notice"]
        named[notice["path"]] = (notice["size"], notice["sha256"])
    for path in sorted(named):
        size, sha256 = named[path]
        entry = files.get(path)
        if entry is None:
            fail("S3", "/files", f"{path} has no files entry")
        elif entry["size"] != size or (sha256 is not None and entry["sha256"] != sha256):
            fail("S3", "/files", f"{path} differs from its files entry")
    extra = sorted(set(files) - set(named))
    if extra:
        fail("S3", "/files", f"files lists {extra[0]}, which no block names")

    paths = [entry["path"] for entry in document["files"]]
    if paths != sorted(paths, key=lambda text: text.encode("utf-8")) or len(set(paths)) != len(
        paths
    ):
        fail("S4", "/files", "files must be sorted by path with no duplicates")

    labels: set[str] = set()
    identifiers: set[str] = set()
    for group in ("disks", "templates"):
        for index, disk in enumerate(document[group]):
            if disk["identifier"] in identifiers:
                fail("S6", f"/{group}/{index}/identifier", "disk identifiers must be unique")
            identifiers.add(disk["identifier"])
            last_end = 0
            limit = disk["logicalSize"] // SECTOR_BYTES - BACKUP_GPT_SECTORS
            for position, partition in enumerate(disk["partitions"]):
                pointer = f"/{group}/{index}/partitions/{position}"
                first = partition["firstLBA"]
                last = first + partition["size"] // SECTOR_BYTES - 1
                if first < last_end:
                    fail("S5", pointer, "partitions must be ascending and not overlap")
                if last > limit:
                    fail("S5", pointer, "partition ends in the backup GPT area")
                last_end = last + 1
                if partition["label"] in labels:
                    fail("S6", pointer + "/label", "partition labels must be unique")
                labels.add(partition["label"])

    ports = document["consolePorts"]
    names = [port["name"] for port in ports]
    for index, port in enumerate(ports):
        if port["index"] != index:
            fail("S7", f"/consolePorts/{index}/index", "index must equal the array position")
    system = [port for port in ports if port["role"] == "systemConsole"]
    if len(system) != 1 or ports[0]["role"] != "systemConsole":
        fail("S7", "/consolePorts", "exactly one systemConsole port, at index 0")
    if len(set(names)) != len(names):
        fail("S7", "/consolePorts", "port names must be unique")

    for name, profile in document["gpuProfiles"].items():
        unknown = sorted(set(profile["overrides"]) - set(profile["bootconfig"]))
        if unknown:
            fail("S8", f"/gpuProfiles/{name}/overrides", f"{unknown[0]} is not a profile key")

    protocol = document["requirements"]["guestProtocol"]
    if protocol["min"] > protocol["max"]:
        fail("S9", "/requirements/guestProtocol", "min must not exceed max")

    agents = [agent["package"] for agent in document["requirements"]["agents"]]
    if document["kind"] == "stock" and agents:
        fail("S10", "/requirements/agents", "a stock image has no agents")
    if document["kind"] == "apkrun" and not {"io.apkrun.guest", "io.apkrun.store"} <= set(agents):
        fail("S10", "/requirements/agents", "an apkrun image lists the guest and store agents")
    if len(set(agents)) != len(agents):
        fail("S10", "/requirements/agents", "agent packages must be unique")

    userdata = document["userdata"]
    versions = userdata["upgradableFrom"]
    if versions != sorted(versions) or userdata["schemaVersion"] not in versions:
        fail("S11", "/userdata/upgradableFrom", "must ascend and contain the schemaVersion")

    minimum = _short_triple(document["compatibility"]["upgradeFrom"]["minimumImageVersion"])
    if minimum > _triple(image_version):
        fail("S12", "/compatibility/upgradeFrom/minimumImageVersion", "above this image")

    provenance = document["provenance"]
    revisions = [
        provenance["revisions"]["guest"],
        provenance["pinnedManifestSHA256"],
        provenance["builderImageDigest"],
    ]
    if document["kind"] == "apkrun" and any(value is None for value in revisions):
        fail("S13", "/provenance", "an apkrun image records the guest revision and pins")
    if document["kind"] == "stock" and any(value is not None for value in revisions):
        fail("S13", "/provenance", "a stock image records no guest revision or pins")

    android_sdk = provenance["android"]["sdk"]
    if document["guest"]["sdk"] != android_sdk:
        fail("S14", "/guest/sdk", "must equal provenance.android.sdk")
    if document["guest"]["targetSdkFloor"] != _sdk_floor(android_sdk):
        fail("S14", "/guest/targetSdkFloor", "must be 23 for SDK 34 and 24 for SDK 35 and later")

    return found


class _RepeatedKey(ValueError):
    """A JSON object names one key twice (§11). The readers would then disagree on its value."""


def _reject_repeated_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise _RepeatedKey(key)
        result[key] = value
    return result


def _line_break_pointer(value: object, pointer: str = "") -> str | None:
    """The pointer of the first string with a line break, or None.

    The schema patterns are anchored with `$`, which Python's `re` also matches before a
    trailing line feed. ECMA regular expressions do not, and neither does Swift, so such a
    string is refused here instead of being accepted by one reader only.
    """
    if isinstance(value, str):
        return pointer if "\n" in value or "\r" in value else None
    if isinstance(value, dict):
        for key, child in value.items():
            if "\n" in key or "\r" in key:
                return pointer + "/" + key
            found = _line_break_pointer(child, f"{pointer}/{key}")
            if found is not None:
                return found
    if isinstance(value, list):
        for index, child in enumerate(value):
            found = _line_break_pointer(child, f"{pointer}/{index}")
            if found is not None:
                return found
    return None


def validate(document: object) -> list[Violation]:
    """Return every violation: the schema first, then S1–S14 only if the schema holds."""
    if not isinstance(document, dict):
        return [Violation("schema", "", "the manifest must be a JSON object")]
    line_break = _line_break_pointer(document)
    if line_break is not None:
        return [Violation("schema", line_break, "strings must not contain line breaks")]
    schema_errors = schema_violations(document)
    if schema_errors:
        return schema_errors
    return semantic_violations(document)


def load_and_validate(data: bytes) -> list[Violation]:
    """Parse the bytes of `manifest.json` and validate them (size limit first).

    A byte-order mark is refused, because ImageCore refuses it too: the two readers must
    agree on which bytes are a manifest.
    """
    if len(data) > MAX_MANIFEST_BYTES:
        return [Violation("schema", "", "manifest.json is larger than 1 MiB")]
    if data.startswith(b"\xef\xbb\xbf"):
        return [Violation("schema", "", "manifest.json must not start with a byte-order mark")]
    try:
        document = json.loads(data.decode("utf-8"), object_pairs_hook=_reject_repeated_keys)
    except _RepeatedKey as error:
        return [Violation("schema", "", f"manifest.json repeats the key {error}")]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [Violation("schema", "", f"manifest.json does not parse: {error}")]
    return validate(document)
