"""Comparison test for the pinned real Cuttlefish artifact inventory."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from apkrun_image.inventory import inventory, serialize_inventory

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
BUILD_DIRECTORY = REPOSITORY_ROOT / "Images/work/16373615/download"
ARCHIVE = BUILD_DIRECTORY / "aosp_cf_arm64_only_phone-img-16373615.zip"
MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/inventory.json"


@pytest.mark.skipif(not ARCHIVE.is_file(), reason="pinned Cuttlefish archive is not downloaded")
def test_pinned_archive_matches_committed_inventory() -> None:
    """A local copy of build 16373615 must produce the committed inventory."""
    fetch_records = json.loads((BUILD_DIRECTORY / "fetch.json").read_text(encoding="utf-8"))
    fetched = next(item for item in fetch_records["artifacts"] if item["name"] == ARCHIVE.name)
    expected = json.loads(MANIFEST.read_text(encoding="utf-8"))
    actual = inventory(ARCHIVE)

    assert actual["source"]["size"] == fetched["size"]
    assert actual["source"]["sha256"] == fetched["sha256"]
    assert actual["source"]["branch"] == "aosp-android-latest-release"
    assert actual["source"]["branchProvenance"] == "caller-asserted"
    assert actual["source"]["buildId"] == "16373615"
    assert actual["source"]["target"] == "aosp_cf_arm64_only_phone-userdebug"
    assert serialize_inventory(actual) == serialize_inventory(expected)
