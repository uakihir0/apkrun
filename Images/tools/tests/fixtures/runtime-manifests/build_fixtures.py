"""Write the runtime manifest fixtures that Python and Swift both check (#065).

Run from `Images/tools`:

    python3 tests/fixtures/runtime-manifests/build_fixtures.py

The valid stock fixture is the §4.1 example of runtime-image-manifest.md, read
from the document, so the document and the fixture cannot drift apart. The other
valid fixtures and every invalid fixture are edits of it. Each invalid fixture
breaks exactly one rule, and its `.expected.txt` names that rule (`schema` or
`S1`…`S14`), so both readers must report the same first failure.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[4]
DOCUMENT = REPOSITORY / "docs/03-reference/runtime-image-manifest.md"
VALID = HERE / "valid"
INVALID = HERE / "invalid"

Document = dict[str, Any]


def example_from_document() -> Document:
    text = DOCUMENT.read_text(encoding="utf-8")
    section = text.split("### 4.1 Complete example", 1)[1]
    match = re.search(r"```json\n(.*?)\n```", section, re.S)
    if match is None:
        raise SystemExit("runtime-image-manifest.md §4.1 has no JSON example")
    loaded = json.loads(match.group(1))
    if not isinstance(loaded, dict):
        raise SystemExit("the §4.1 example is not an object")
    return loaded


def apkrun_variant(stock: Document) -> Document:
    document = copy.deepcopy(stock)
    document["imageVersion"] = "2026.10.0-ar000123-arm64"
    document["kind"] = "apkrun"
    source = document["provenance"]["source"]
    source["origin"] = "apkrun-builder"
    source["buildId"] = "ar000123"
    source["branch"] = "apkrun-product"
    document["provenance"]["revisions"]["guest"] = "f" * 40
    document["provenance"]["pinnedManifestSHA256"] = "2" * 64
    document["provenance"]["builderImageDigest"] = "sha256:" + "3" * 64
    document["requirements"] = {
        "minimumRuntimeVersion": "1.1.0",
        "guestProtocol": {"min": 1, "max": 1},
        "agents": [
            {"package": "io.apkrun.guest", "versionCode": 12},
            {"package": "io.apkrun.store", "versionCode": 12},
        ],
    }
    return document


def with_legal(stock: Document) -> Document:
    document = copy.deepcopy(stock)
    notice = {"path": "legal/notice.html", "size": 4096, "sha256": "4" * 64}
    document["legal"] = {"notice": notice}
    document["files"].append(notice)
    document["files"].sort(key=lambda entry: entry["path"])
    return document


def mutate_size(document: Document, path: str, size: int) -> None:
    entry = next(item for item in document["files"] if item["path"] == path)
    entry["size"] = size


def _unknown_top(d: Document) -> None:
    d["extra"] = 1


def _missing_ports(d: Document) -> None:
    del d["consolePorts"]


def _bad_image_version(d: Document) -> None:
    d["imageVersion"] = "2026.10.0-cf16373615"


def _nested_unknown(d: Document) -> None:
    d["provenance"]["android"]["extra"] = "x"


def _uppercase_hash(d: Document) -> None:
    d["files"][0]["sha256"] = d["files"][0]["sha256"].upper()


def _page_size(d: Document) -> None:
    d["boot"]["kernelPageSize"] = 8192


def _size_as_string(d: Document) -> None:
    d["files"][0]["size"] = "123"


def _base_mismatch(d: Document) -> None:
    d["imageVersion"] = "2026.10.0-cf16373616-arm64"


def _kind_mismatch(d: Document) -> None:
    d["kind"] = "apkrun"


def _missing_file_entry(d: Document) -> None:
    d["files"] = [item for item in d["files"] if item["path"] != "boot/kernel"]


def _size_mismatch(d: Document) -> None:
    mutate_size(d, "disks/os.img", d["disks"][0]["logicalSize"] + 512)


def _extra_file(d: Document) -> None:
    d["files"].append({"path": "boot/extra", "size": 1, "sha256": "5" * 64})
    d["files"].sort(key=lambda entry: entry["path"])


def _unsorted(d: Document) -> None:
    d["files"][0], d["files"][1] = d["files"][1], d["files"][0]


def _overlap(d: Document) -> None:
    super_partition = next(p for p in d["disks"][0]["partitions"] if p["label"] == "super")
    super_partition["firstLBA"] = 282624


def _past_backup_gpt(d: Document) -> None:
    custom = next(p for p in d["disks"][0]["partitions"] if p["label"] == "custom")
    custom["size"] *= 2


def _duplicate_label(d: Document) -> None:
    frp = next(p for p in d["templates"][0]["partitions"] if p["label"] == "frp")
    frp["label"] = "boot_a"


def _duplicate_identifier(d: Document) -> None:
    d["templates"][0]["identifier"] = d["disks"][0]["identifier"]


def _port_index(d: Document) -> None:
    d["consolePorts"][3]["index"] = 4


def _two_system_consoles(d: Document) -> None:
    d["consolePorts"][1]["role"] = "systemConsole"


def _unknown_override(d: Document) -> None:
    d["gpuProfiles"]["drmVirgl"]["overrides"] = ["androidboot.not.set"]


def _protocol_range(d: Document) -> None:
    d["requirements"]["guestProtocol"] = {"min": 2, "max": 1}


def _stock_agent(d: Document) -> None:
    d["requirements"]["agents"] = [{"package": "io.apkrun.guest", "versionCode": 12}]


def _userdata_not_contained(d: Document) -> None:
    d["userdata"] = {"schemaVersion": 2, "upgradableFrom": [1]}


def _minimum_above_image(d: Document) -> None:
    d["compatibility"]["upgradeFrom"]["minimumImageVersion"] = "2026.11.0"


def _stock_guest_revision(d: Document) -> None:
    d["provenance"]["revisions"]["guest"] = "a" * 40


def _sdk_mismatch(d: Document) -> None:
    d["guest"]["sdk"] = 36


def _sdk_floor(d: Document) -> None:
    d["guest"]["targetSdkFloor"] = 23


def _trailing_line_break(d: Document) -> None:
    d["provenance"]["revisions"]["imagesTools"] = d["provenance"]["revisions"]["imagesTools"] + "\n"


def _legal_null(d: Document) -> None:
    d["legal"] = None


def _strategy_null(d: Document) -> None:
    d["disks"][0]["userdataStrategy"] = None


def _first_lba_overflow(d: Document) -> None:
    custom = next(p for p in d["disks"][0]["partitions"] if p["label"] == "custom")
    custom["firstLBA"] = 2**64 - 2048


INVALID_CASES: tuple[tuple[str, str, Callable[[Document], None]], ...] = (
    ("schema-unknown-top-level-field", "schema", _unknown_top),
    ("schema-missing-console-ports", "schema", _missing_ports),
    ("schema-image-version-without-architecture", "schema", _bad_image_version),
    ("schema-unknown-nested-field", "schema", _nested_unknown),
    ("schema-uppercase-hash", "schema", _uppercase_hash),
    ("schema-kernel-page-size", "schema", _page_size),
    ("schema-size-as-string", "schema", _size_as_string),
    ("s1-base-mismatch", "S1", _base_mismatch),
    ("s2-kind-origin-mismatch", "S2", _kind_mismatch),
    ("s3-missing-file-entry", "S3", _missing_file_entry),
    ("s3-size-mismatch", "S3", _size_mismatch),
    ("s3-extra-file-entry", "S3", _extra_file),
    ("s4-unsorted-files", "S4", _unsorted),
    ("s5-partition-overlap", "S5", _overlap),
    ("s5-partition-past-backup-gpt", "S5", _past_backup_gpt),
    ("s6-duplicate-partition-label", "S6", _duplicate_label),
    ("s6-duplicate-disk-identifier", "S6", _duplicate_identifier),
    ("s7-port-index-not-position", "S7", _port_index),
    ("s7-two-system-consoles", "S7", _two_system_consoles),
    ("s8-override-not-in-profile", "S8", _unknown_override),
    ("s9-protocol-range-reversed", "S9", _protocol_range),
    ("s10-stock-with-agent", "S10", _stock_agent),
    ("s11-upgradable-without-schema", "S11", _userdata_not_contained),
    ("s12-minimum-above-image", "S12", _minimum_above_image),
    ("s13-stock-with-guest-revision", "S13", _stock_guest_revision),
    ("s14-sdk-mismatch", "S14", _sdk_mismatch),
    ("s14-target-sdk-floor", "S14", _sdk_floor),
    ("schema-trailing-line-break", "schema", _trailing_line_break),
    ("schema-legal-null", "schema", _legal_null),
    ("schema-userdata-strategy-null", "schema", _strategy_null),
    ("s5-first-lba-beyond-the-disk", "S5", _first_lba_overflow),
)


def write_json(path: Path, document: Document) -> None:
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    stock = example_from_document()
    VALID.mkdir(parents=True, exist_ok=True)
    INVALID.mkdir(parents=True, exist_ok=True)
    write_json(VALID / "stock-cf16373615.json", stock)
    write_json(VALID / "stock-with-legal-notice.json", with_legal(stock))
    write_json(VALID / "apkrun-ar000123.json", apkrun_variant(stock))
    for name, rule, mutate in INVALID_CASES:
        document = copy.deepcopy(stock)
        mutate(document)
        write_json(INVALID / f"{name}.json", document)
        (INVALID / f"{name}.expected.txt").write_text(rule + "\n", encoding="ascii")
    # Two invalid files are not JSON values but bytes: a repeated key, and a byte-order mark.
    text = json.dumps(stock, indent=2, sort_keys=True) + "\n"
    repeated = text.replace('"kind": "stock"', '"kind": "stock", "kind": "apkrun"', 1)
    assert repeated != text
    (INVALID / "schema-repeated-key.json").write_text(repeated, encoding="utf-8")
    (INVALID / "schema-repeated-key.expected.txt").write_text("schema\n", encoding="ascii")
    (INVALID / "schema-byte-order-mark.json").write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
    (INVALID / "schema-byte-order-mark.expected.txt").write_text("schema\n", encoding="ascii")
    print(f"wrote {len(INVALID_CASES) + 2} invalid and 3 valid manifest fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
