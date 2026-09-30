"""Bootconfig layer, serialization, and Linux trailer golden tests."""

from __future__ import annotations

import struct
from pathlib import Path

import pytest

from apkrun_image.bootconfig import (
    BOOTCONFIG_MAGIC,
    MAX_BUILD_BOOTCONFIG_SIZE,
    MAX_KERNEL_BOOTCONFIG_NODES,
    MAX_KERNEL_BOOTCONFIG_SIZE,
    BootconfigConflict,
    BootconfigError,
    BootconfigLayer,
    BootconfigTooLarge,
    BootconfigTooManyNodes,
    make_bootconfig_trailer,
    merge_bootconfig_layers,
    parse_bootconfig_text,
    serialize_bootconfig,
)

FIXTURE_ROOT = Path(__file__).parent / "fixtures/bootconfig"
KERNEL_COMMAND_LINE = "console=hvc0 bootconfig"


def _golden_names() -> tuple[str, ...]:
    """List each checked-in source/expected binary pair deterministically."""
    return ("empty", "one-key", "many-keys", "values-with-spaces", "exactly-16k")


@pytest.mark.parametrize("name", _golden_names())
def test_bootconfig_text_and_trailer_match_golden_vectors(name: str) -> None:
    """Every shared text vector serializes to its checked-in binary trailer."""
    source = (FIXTURE_ROOT / f"{name}.txt").read_text(encoding="ascii")
    actual = make_bootconfig_trailer(
        serialize_bootconfig(parse_bootconfig_text(source, layer_name=name)),
        command_line=KERNEL_COMMAND_LINE,
    )

    assert actual == (FIXTURE_ROOT / f"{name}.bin").read_bytes()


def test_golden_vector_at_16_kib_is_accepted_exactly() -> None:
    """The largest build-time block is accepted when it is exactly 16 KiB."""
    source = (FIXTURE_ROOT / "exactly-16k.txt").read_text(encoding="ascii")
    encoded = serialize_bootconfig(parse_bootconfig_text(source))

    assert len(encoded) == MAX_BUILD_BOOTCONFIG_SIZE


def test_many_keys_are_sorted_and_values_are_always_double_quoted() -> None:
    """Canonical serialization is deterministic regardless of input order."""
    first = serialize_bootconfig({"z.last": "last", "a.first": "first value"})
    second = serialize_bootconfig({"a.first": "first value", "z.last": "last"})

    assert first == second
    assert first == b'a.first = "first value"\nz.last = "last"\n'


def test_merge_drops_identical_duplicates_and_logs_debug(caplog: pytest.LogCaptureFixture) -> None:
    """Identical values in later layers are kept once and are visible in debug logs."""
    caplog.set_level("DEBUG", logger="apkrun_image.bootconfig")

    result = merge_bootconfig_layers(
        (
            BootconfigLayer("vendor", {"androidboot.hardware": "cutf_cvm"}),
            BootconfigLayer("image", {"androidboot.hardware": "cutf_cvm"}),
        )
    )

    assert result == {"androidboot.hardware": "cutf_cvm"}
    assert "dropping identical duplicate bootconfig key" in caplog.text


def test_merge_conflict_has_the_required_message() -> None:
    """A changed value fails with both layer names in the stable error message."""
    with pytest.raises(BootconfigConflict) as failure:
        merge_bootconfig_layers(
            (
                BootconfigLayer("vendor", {"androidboot.slot_suffix": "_a"}),
                BootconfigLayer("image", {"androidboot.slot_suffix": "_b"}),
            )
        )

    assert str(failure.value) == ("bootconfigConflict(androidboot.slot_suffix, vendor, image)")
    assert failure.value.key == "androidboot.slot_suffix"
    assert failure.value.layer_a == "vendor"
    assert failure.value.layer_b == "image"


def test_merge_allows_a_later_override_with_a_comment() -> None:
    """An explicit override replaces the earlier value and changes its owner layer."""
    result = merge_bootconfig_layers(
        (
            BootconfigLayer("vendor", {"androidboot.slot_suffix": "_b"}),
            BootconfigLayer(
                "image",
                {"androidboot.slot_suffix": "_a"},
                {"androidboot.slot_suffix": "ADR-0015 selects slot A."},
            ),
        )
    )

    assert result == {"androidboot.slot_suffix": "_a"}


@pytest.mark.parametrize(
    ("overrides", "values", "message"),
    (
        ({"androidboot.key": ""}, {"androidboot.key": "value"}, "needs a non-empty comment"),
        ({"androidboot.key": "unused"}, {}, "has no corresponding value"),
        ({"androidboot.new": "comment"}, {"androidboot.new": "value"}, "no earlier value"),
    ),
)
def test_merge_rejects_invalid_overrides(
    overrides: dict[str, str],
    values: dict[str, str],
    message: str,
) -> None:
    """Override keys need a comment, a value, and an earlier value to replace."""
    layers = [BootconfigLayer("vendor", {"androidboot.key": "earlier"})]
    layers.append(BootconfigLayer("image", values, overrides))

    with pytest.raises(BootconfigError, match=message):
        merge_bootconfig_layers(layers)


def test_parse_bootconfig_drops_identical_duplicate_lines() -> None:
    """Repeated identical source lines do not create duplicate output keys."""
    parsed = parse_bootconfig_text(
        "androidboot.hardware=cutf_cvm\nandroidboot.hardware=cutf_cvm\n",
        layer_name="vendor",
    )

    assert parsed == {"androidboot.hardware": "cutf_cvm"}


def test_parse_bootconfig_rejects_conflicting_duplicate_lines() -> None:
    """One source layer cannot assign two values to the same key."""
    with pytest.raises(BootconfigConflict, match=r"bootconfigConflict\(key, vendor, vendor\)"):
        parse_bootconfig_text("key=one\nkey=two\n", layer_name="vendor")


def test_parse_bootconfig_handles_inline_comments_without_changing_values() -> None:
    """Unquoted and quoted comment markers follow the kernel bootconfig grammar."""
    parsed = parse_bootconfig_text(
        'plain=one # trailing comment\nquoted="two # words" # trailing comment\n',
        layer_name="vendor",
    )

    assert parsed == {"plain": "one", "quoted": "two # words"}


def test_parse_bootconfig_rejects_array_syntax_not_supported_by_scalar_layers() -> None:
    """The scalar layer model does not silently turn arrays into one string."""
    with pytest.raises(BootconfigError, match="unsupported array or statement syntax"):
        parse_bootconfig_text("key=one,two\n", layer_name="vendor")


@pytest.mark.parametrize(
    ("values", "message"),
    (
        ({"bad key": "value"}, "invalid bootconfig key"),
        ({"bad/key": "value"}, "invalid bootconfig key"),
        ({"good.key": "non-ascii é"}, "printable ASCII"),
        ({"good.key": 'quote"value'}, "printable ASCII"),
        ({"good.key": "back\\slash"}, "printable ASCII"),
        ({"good.key": "line\nbreak"}, "printable ASCII"),
    ),
)
def test_serialize_rejects_invalid_keys_and_values(
    values: dict[str, str],
    message: str,
) -> None:
    """The serializer enforces the documented restricted key/value alphabet."""
    with pytest.raises(BootconfigError, match=message):
        serialize_bootconfig(values)


def test_serialize_rejects_non_string_mapping_keys_without_traceback() -> None:
    """Malformed API input yields a typed validation error."""
    with pytest.raises(BootconfigError, match="invalid bootconfig key"):
        serialize_bootconfig({1: "value"})  # type: ignore[dict-item]


def test_build_size_limit_reports_the_actual_serialized_size() -> None:
    """The build-time serializer rejects a block one byte beyond 16 KiB."""
    value = "x" * (MAX_BUILD_BOOTCONFIG_SIZE - 6)

    with pytest.raises(BootconfigTooLarge) as failure:
        serialize_bootconfig({"k": value})

    assert failure.value.size == MAX_BUILD_BOOTCONFIG_SIZE + 1
    assert str(failure.value) == f"bootconfigTooLarge({MAX_BUILD_BOOTCONFIG_SIZE + 1})"


def test_kernel_node_limit_accepts_exact_boundary() -> None:
    """512 flat scalar keys use exactly the 1024 documented kernel nodes."""
    values = {f"k{index:03d}": "v" for index in range(MAX_KERNEL_BOOTCONFIG_NODES // 2)}
    encoded = serialize_bootconfig(values)

    assert len(values) * 2 == MAX_KERNEL_BOOTCONFIG_NODES
    assert len(encoded) < MAX_BUILD_BOOTCONFIG_SIZE


def test_kernel_node_limit_rejects_one_entry_over_boundary() -> None:
    """A small serialized block still fails when its tree has too many nodes."""
    values = {f"k{index:03d}": "v" for index in range(MAX_KERNEL_BOOTCONFIG_NODES // 2 + 1)}

    with pytest.raises(BootconfigTooManyNodes) as failure:
        serialize_bootconfig(values)

    assert failure.value.count == MAX_KERNEL_BOOTCONFIG_NODES + 2
    assert len(values) < 600


def test_kernel_node_count_reuses_shared_dotted_prefixes() -> None:
    """Hierarchical keys count each shared key node once and one value node each."""
    encoded = serialize_bootconfig({"root.alpha": "a", "root.beta": "b"})

    assert encoded == b'root.alpha = "a"\nroot.beta = "b"\n'


def test_trailer_contains_padded_size_checksum_and_magic() -> None:
    """The trailer covers NUL padding in both the little-endian size and checksum."""
    block = b'key = "value"\n'
    trailer = make_bootconfig_trailer(block, command_line=KERNEL_COMMAND_LINE)
    padding_size = (-len(block)) % 4
    padded = block + b"\x00" * padding_size
    suffix = trailer[len(padded) :]
    size, checksum = struct.unpack_from("<II", suffix)

    assert trailer[: len(padded)] == padded
    assert size == len(padded)
    assert checksum == sum(padded)
    assert suffix[8:] == BOOTCONFIG_MAGIC


def test_empty_bootconfig_has_zero_size_and_checksum() -> None:
    """The empty golden vector still carries the size, checksum, and magic trailer."""
    trailer = make_bootconfig_trailer(b"", command_line=KERNEL_COMMAND_LINE)

    assert trailer == struct.pack("<II", 0, 0) + BOOTCONFIG_MAGIC


@pytest.mark.parametrize(
    "command_line",
    (
        "",
        "console=hvc0",
        "console=hvc0 notbootconfig",
        "bootconfig=1",
        "console=hvc0 -- bootconfig",
    ),
)
def test_trailer_requires_the_exact_bootconfig_command_line_token(command_line: str) -> None:
    """A substring or assignment cannot enable the kernel bootconfig parser."""
    with pytest.raises(BootconfigError, match="must contain the bootconfig token"):
        make_bootconfig_trailer(b"", command_line=command_line)


def test_trailer_enforces_the_kernel_limit() -> None:
    """The runtime trailer rejects blocks beyond the 32 KiB kernel ceiling."""
    oversized = b"x" * (MAX_KERNEL_BOOTCONFIG_SIZE + 1)

    with pytest.raises(BootconfigTooLarge) as failure:
        make_bootconfig_trailer(oversized, command_line=KERNEL_COMMAND_LINE)

    assert failure.value.size == MAX_KERNEL_BOOTCONFIG_SIZE + 1
