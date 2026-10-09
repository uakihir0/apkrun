"""Tests for layout validation (android-image.md §4.2; reference §8)."""

from __future__ import annotations

import copy
import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from apkrun_image.layout import LayoutError, check_sources, load_layout, parse_layout

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PINNED_LAYOUT = REPOSITORY_ROOT / "Images/tools/layouts/cuttlefish-phone-arm64.json"
PINNED_MANIFEST = REPOSITORY_ROOT / "Images/manifests/16373615/android-image.json"
LAUNCHER_CAPTURE = (
    REPOSITORY_ROOT
    / "Images/reference/16373615/incomplete/default-20261001T120904-49816/internal-bootconfig.txt"
)
ANDROID_IMAGE_DOCUMENT = REPOSITORY_ROOT / "docs/02-design/android-image.md"
FAMILY = "cuttlefish-phone-arm64"

# The graphics keys of the launcher capture (guest_swiftshader). The guestSwiftshader and
# headless GPU profiles carry exactly these keys (android-image.md §6.2, graphics.md §9).
CAPTURE_GRAPHICS_KEYS = frozenset(
    {
        "androidboot.cpuvulkan.version",
        "androidboot.hardware.angle_feature_overrides_disabled",
        "androidboot.hardware.angle_feature_overrides_enabled",
        "androidboot.hardware.egl",
        "androidboot.hardware.gralloc",
        "androidboot.hardware.hwcomposer",
        "androidboot.hardware.hwcomposer.display_finder_mode",
        "androidboot.hardware.hwcomposer.display_framebuffer_format",
        "androidboot.hardware.vulkan",
        "androidboot.opengles.version",
        "androidboot.vendor.apex.com.android.hardware.graphics.composer",
    }
)

# Launcher-capture keys that APKRun leaves out of the image layer: host services, automotive
# keys, and the platform and instance layers (android-image.md §6.2, §7.3). Pinned here, so a
# key moved between the image layer and the omitted list fails this test.
OMITTED_CAPTURE_KEYS = frozenset(
    {
        "androidboot.auto_eth_guest_addr",
        "androidboot.boot_devices",
        "androidboot.ddr_size",
        "androidboot.lcd_density",
        "androidboot.serialconsole",
        "androidboot.serialno",
        "androidboot.vhal_proxy_server_port",
        "androidboot.vsock_tombstone_port",
    }
)

# Image-layer values that the launcher capture does not give the same way. Six keys are
# absent from the capture and set by APKRun, and wifi_impl replaces the capture's
# mac80211_hwsim_virtio. Each value is decided or verified on VZ (android-image.md §6.2).
DECIDED_IMAGE_VALUES = {
    "androidboot.cuttlefish_service_bluetooth_checker": "false",
    "androidboot.force_normal_boot": "1",
    "androidboot.hypervisor.vm.supported": "0",
    "androidboot.slot_suffix": "_a",
    "androidboot.vbmeta.device_state": "unlocked",
    "androidboot.verifiedbootstate": "orange",
    "androidboot.wifi_impl": "virt_wifi",
}


def _document() -> dict[str, Any]:
    return json.loads(PINNED_LAYOUT.read_text(encoding="utf-8"))


def _launcher_capture() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in LAUNCHER_CAPTURE.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        key, separator, value = line.partition("=")
        assert separator == "=", line
        assert key not in values, key
        values[key] = value
    return values


def test_pinned_layout_has_the_two_disks_of_the_plan() -> None:
    layout = load_layout(PINNED_LAYOUT, FAMILY)

    assert [disk.role for disk in layout.disks] == ["os", "userdata"]
    assert [disk.read_only for disk in layout.disks] == [True, False]
    assert len(layout.disks[0].partitions) == 9
    assert [partition.label for partition in layout.disks[1].partitions] == [
        "misc",
        "metadata",
        "frp",
        "userdata",
    ]
    assert layout.disks[1].userdata_strategy == "blankFormattable"


def test_pinned_layout_names_only_manifest_partitions() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    check_sources(
        load_layout(PINNED_LAYOUT, FAMILY), manifest["artifacts"], manifest["blankPartitions"]
    )


def test_pinned_layout_bootconfig_has_no_platform_instance_or_graphics_keys() -> None:
    image = _document()["bootconfig"]["image"]

    for key in (
        "androidboot.boot_devices",
        "androidboot.serialno",
        "androidboot.ddr_size",
        "androidboot.lcd_density",
        "androidboot.hardware.egl",
    ):
        assert key not in image


def test_a_layout_for_another_device_family_is_rejected() -> None:
    document = _document()
    document["deviceFamily"] = "cuttlefish-tablet-arm64"
    with pytest.raises(
        LayoutError,
        match="layout cuttlefish-tablet-arm64 does not match deviceFamily cuttlefish-phone-arm64.",
    ):
        parse_layout(document, FAMILY)


def test_a_partition_without_a_source_is_named() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    artifacts = [
        artifact for artifact in manifest["artifacts"] if artifact["partition"] != "custom"
    ]
    with pytest.raises(LayoutError, match='layout partition "custom" has no artifact or blank'):
        check_sources(load_layout(PINNED_LAYOUT, FAMILY), artifacts, manifest["blankPartitions"])


def test_a_blank_partition_entry_must_be_marked_blank() -> None:
    manifest = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
    document = _document()
    del document["disks"][1]["partitions"][0]["blank"]
    with pytest.raises(LayoutError, match='names blank partition "misc" and must be blank'):
        check_sources(
            parse_layout(document, FAMILY), manifest["artifacts"], manifest["blankPartitions"]
        )


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda d: d["disks"][0].update(readOnly=False), "disks\\[0\\] must be the read-only"),
        (lambda d: d["disks"][1].update(role="os"), "roles must be unique"),
        (lambda d: d["disks"][1].update(file="os.img"), "files must be unique"),
        (lambda d: d["disks"][1].update(identifier="Bad_ID"), "identifier must match"),
        (lambda d: d["disks"][1]["partitions"][0].update(label="frp"), "used twice: frp"),
        (lambda d: d["disks"][1]["partitions"][3].pop("size"), "last partition must be blank"),
        (lambda d: d["disks"][1].update(userdataStrategy="grow"), "userdataStrategy must be"),
        (lambda d: d["disks"][1]["partitions"][0].update(size=100), "multiple of 512"),
        (lambda d: d["disks"][0]["partitions"][0].update(size=512), "only allowed for a blank"),
        (lambda d: d["disks"][0].update(extra=1), "unknown fields: extra"),
        (lambda d: d.update(disks=[]), "non-empty array"),
    ],
)
def test_broken_layouts_name_the_problem(
    mutate: Callable[[dict[str, Any]], object], message: str
) -> None:
    document = copy.deepcopy(_document())
    mutate(document)
    with pytest.raises(LayoutError, match=message):
        parse_layout(document, FAMILY)


def test_layer_two_image_values_are_the_launcher_capture_values() -> None:
    """The image layer is the capture without graphics and omitted keys, plus the decided values."""
    layout = _document()
    capture = _launcher_capture()
    sources = layout["bootconfig"]["sources"]
    omitted = {key for key in sources["omitted"] if key.startswith("androidboot.")}

    assert CAPTURE_GRAPHICS_KEYS | OMITTED_CAPTURE_KEYS <= set(capture)
    assert omitted == OMITTED_CAPTURE_KEYS
    assert set(sources["decided"]) == set(DECIDED_IMAGE_VALUES)
    expected = {
        key: value
        for key, value in capture.items()
        if key not in CAPTURE_GRAPHICS_KEYS and key not in omitted
    }
    expected.update(DECIDED_IMAGE_VALUES)
    assert layout["bootconfig"]["image"] == expected


def test_guest_swiftshader_and_headless_profiles_carry_the_capture_graphics_keys() -> None:
    capture = _launcher_capture()
    profiles = _document()["gpuProfiles"]
    expected = {key: capture[key] for key in CAPTURE_GRAPHICS_KEYS}

    assert profiles["guestSwiftshader"]["bootconfig"] == expected
    assert profiles["headless"]["bootconfig"] == expected


def test_layout_cites_the_capture_and_existing_design_sections() -> None:
    document = _document()

    assert LAUNCHER_CAPTURE.is_file()
    assert (
        str(LAUNCHER_CAPTURE.relative_to(REPOSITORY_ROOT))
        in document["bootconfig"]["sources"]["launcherCapture"]
    )
    headings = set(
        re.findall(
            r"^#{2,3} (\d+(?:\.\d+)?)[. ]",
            ANDROID_IMAGE_DOCUMENT.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
    )
    cited_text = json.dumps([document["bootconfig"], document["cmdline"]], ensure_ascii=False)
    cited = set(re.findall(r"§(\d+(?:\.\d+)?)", cited_text))

    assert cited
    assert cited <= headings, sorted(cited - headings)


def test_pinned_command_line_additions_are_the_verified_ones() -> None:
    additions = _document()["cmdline"]["additions"]

    assert [addition["value"] for addition in additions] == ["console=hvc0", "log_buf_len=2M"]
    assert all(addition["comment"] for addition in additions)
