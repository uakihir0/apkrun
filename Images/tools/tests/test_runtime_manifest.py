"""Tests for the manifest schema and rules S1–S14 (runtime-image-manifest.md §5, §7; #66)."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from apkrun_image.runtime_manifest import load_and_validate

TESTS = Path(__file__).parent
REPOSITORY = TESTS.parents[2]
FIXTURES = TESTS / "fixtures/runtime-manifests"
VALID = sorted((FIXTURES / "valid").glob("*.json"))
INVALID = sorted((FIXTURES / "invalid").glob("*.json"))
SCHEMA = TESTS.parent / "schemas/runtime-image-manifest.schema.json"
DOCUMENT = REPOSITORY / "docs/03-reference/runtime-image-manifest.md"


@pytest.mark.parametrize("path", VALID, ids=lambda path: path.name)
def test_valid_fixtures_pass_the_schema_and_every_rule(path: Path) -> None:
    assert load_and_validate(path.read_bytes()) == []


@pytest.mark.parametrize("path", INVALID, ids=lambda path: path.stem)
def test_invalid_fixtures_fail_with_the_rule_they_name(path: Path) -> None:
    expected = (path.parent / f"{path.stem}.expected.txt").read_text(encoding="ascii").strip()
    violations = load_and_validate(path.read_bytes())
    assert violations, "an invalid fixture must fail"
    assert violations[0].rule == expected, violations


def test_the_committed_schema_is_the_block_in_the_reference_document() -> None:
    text = DOCUMENT.read_text(encoding="utf-8")
    section = text.split("## 5. JSON Schema", 1)[1]
    block = re.search(r"```json\n(.*?)\n```", section, re.S)
    assert block is not None
    assert SCHEMA.read_text(encoding="utf-8") == block.group(1) + "\n"


def test_a_document_that_is_not_json_is_a_schema_failure() -> None:
    violations = load_and_validate(b"{not json")
    assert [violation.rule for violation in violations] == ["schema"]


def test_an_oversized_manifest_is_refused_before_parsing() -> None:
    violations = load_and_validate(b" " * (1024 * 1024 + 1))
    assert [violation.rule for violation in violations] == ["schema"]
    assert "1 MiB" in violations[0].reason


def test_the_first_valid_fixture_is_the_documented_example() -> None:
    document = json.loads((FIXTURES / "valid/stock-cf16373615.json").read_text(encoding="utf-8"))
    assert document["imageVersion"] == "2026.10.0-cf16373615-arm64"
    assert document["kind"] == "stock"
    assert len(document["consolePorts"]) == 20


def test_composed_apkrun_fixture_retains_the_stock_source_and_hashes_inputs() -> None:
    path = FIXTURES / "valid/apkrun-composed-cf16373615.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    assert load_and_validate(path.read_bytes()) == []
    assert document["kind"] == "apkrun"
    assert document["provenance"]["source"]["origin"] == "ci.android.com"
    assert document["provenance"]["composition"]["sourceManifest"]["sha256"] == "4" * 64
    assert [entry["path"] for entry in document["provenance"]["composition"]["productInputs"]] == [
        "Guest/product/compose.json",
        "Guest/product/init/apkrun.rc",
        "Guest/product/prebuilt/ApkRunGuest.apk",
        "Guest/product/prebuilt/ApkRunGuest.json",
        "Guest/product/prebuilt/ApkRunStore.apk",
        "Guest/product/prebuilt/ApkRunStore.json",
    ]
    assert document["requirements"]["agents"] == [
        {"package": "io.apkrun.guest", "versionCode": 12},
        {"package": "io.apkrun.store", "versionCode": 12},
    ]


def test_pre_store_composed_apkrun_manifest_remains_valid() -> None:
    document = json.loads(
        (FIXTURES / "valid/apkrun-composed-cf16373615.json").read_text(encoding="utf-8")
    )
    product_inputs = document["provenance"]["composition"]["productInputs"]
    document["provenance"]["composition"]["productInputs"] = [
        item
        for item in product_inputs
        if item["path"]
        not in {
            "Guest/product/prebuilt/ApkRunStore.apk",
            "Guest/product/prebuilt/ApkRunStore.json",
        }
    ]
    document["requirements"]["agents"] = [{"package": "io.apkrun.guest", "versionCode": 12}]

    assert load_and_validate(json.dumps(document).encode("utf-8")) == []


def test_composed_store_agent_requires_both_apk_and_metadata_inputs() -> None:
    document = json.loads(
        (FIXTURES / "valid/apkrun-composed-cf16373615.json").read_text(encoding="utf-8")
    )
    document["provenance"]["composition"]["productInputs"] = [
        item
        for item in document["provenance"]["composition"]["productInputs"]
        if item["path"] != "Guest/product/prebuilt/ApkRunStore.apk"
    ]

    violations = load_and_validate(json.dumps(document).encode("utf-8"))

    assert violations
    assert violations[0].rule == "S10"
