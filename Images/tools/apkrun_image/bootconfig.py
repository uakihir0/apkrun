"""Merge Android bootconfig layers and build the Linux bootconfig trailer."""

from __future__ import annotations

import logging
import re
import struct
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field

BOOTCONFIG_MAGIC = b"#BOOTCONFIG\n"
MAX_BUILD_BOOTCONFIG_SIZE = 16 * 1024
MAX_KERNEL_BOOTCONFIG_SIZE = 32 * 1024
MAX_KERNEL_BOOTCONFIG_NODES = 1024
_KEY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+\Z")
_LOGGER = logging.getLogger("apkrun_image.bootconfig")


class BootconfigError(ValueError):
    """Bootconfig source text, layers, or serialized output is invalid."""


class BootconfigConflict(BootconfigError):
    """A later bootconfig layer changes a key without a documented override."""

    def __init__(self, key: str, layer_a: str, layer_b: str) -> None:
        self.key = key
        self.layer_a = layer_a
        self.layer_b = layer_b
        super().__init__(key, layer_a, layer_b)

    def __str__(self) -> str:
        return f"bootconfigConflict({self.key}, {self.layer_a}, {self.layer_b})"


class BootconfigTooLarge(BootconfigError):
    """Serialized bootconfig exceeds its configured size limit."""

    def __init__(self, size: int) -> None:
        self.size = size
        super().__init__(size)

    def __str__(self) -> str:
        return f"bootconfigTooLarge({self.size})"


class BootconfigTooManyNodes(BootconfigError):
    """Bootconfig exceeds the kernel parser's key/value node limit."""

    def __init__(self, count: int) -> None:
        self.count = count
        super().__init__(count)

    def __str__(self) -> str:
        return f"bootconfigTooManyNodes({self.count})"


@dataclass(frozen=True)
class BootconfigLayer:
    """One ordered source of key/value pairs and explicit override comments."""

    name: str
    values: Mapping[str, str]
    overrides: Mapping[str, str] = field(default_factory=dict)


def _validate_key_value(key: object, value: object) -> tuple[str, str]:
    """Require the deliberately small bootconfig key and value subset."""
    if not isinstance(key, str) or _KEY_PATTERN.fullmatch(key) is None:
        raise BootconfigError(f"invalid bootconfig key: {key!r}")
    if any(not component for component in key.split(".")):
        raise BootconfigError(f"invalid bootconfig key: {key!r}")
    if not isinstance(value, str):
        raise BootconfigError(f"bootconfig value for {key} must be a string.")
    if any(not (" " <= character <= "~") or character in {'"', "\\"} for character in value):
        raise BootconfigError(
            f"bootconfig value for {key} must be printable ASCII without quotes or backslashes."
        )
    return key, value


def _bootconfig_node_count(keys: Sequence[str]) -> int:
    """Count unique dotted key nodes plus one value node for each key."""
    key_nodes: set[tuple[str, ...]] = set()
    for key in keys:
        components = key.split(".")
        for length in range(1, len(components) + 1):
            key_nodes.add(tuple(components[:length]))
    return len(key_nodes) + len(keys)


def _check_node_limit(keys: Sequence[str]) -> int:
    """Reject configurations that the Linux bootconfig parser cannot represent."""
    count = _bootconfig_node_count(keys)
    if count > MAX_KERNEL_BOOTCONFIG_NODES:
        raise BootconfigTooManyNodes(count)
    return count


def parse_bootconfig_text(text: str, *, layer_name: str = "input") -> dict[str, str]:
    """Parse key=value bootconfig text, including comments and quoted values."""
    if not isinstance(text, str):
        raise BootconfigError("bootconfig input must be text.")
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        raise BootconfigError("bootconfig input must contain ASCII characters only.") from None

    normalized_text = text.replace("\r\n", "\n")
    if "\r" in normalized_text:
        raise BootconfigError("bootconfig input contains an invalid line ending.")
    values: dict[str, str] = {}
    for line_number, source_line in enumerate(normalized_text.split("\n"), start=1):
        line = source_line.strip(" ")
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise BootconfigError(f"bootconfig line {line_number} in {layer_name} is missing '='.")
        key_text, value_text = line.split("=", 1)
        key = key_text.strip(" ")
        raw_value = value_text.strip(" ")
        if raw_value.startswith(('"', "'")):
            quote = raw_value[0]
            closing_quote = raw_value.find(quote, 1)
            if closing_quote < 0:
                raise BootconfigError(
                    f"bootconfig line {line_number} in {layer_name} has unmatched quotes."
                )
            value = raw_value[1:closing_quote]
            remainder = raw_value[closing_quote + 1 :].strip(" ")
            if remainder and not remainder.startswith("#"):
                raise BootconfigError(
                    f"bootconfig line {line_number} in {layer_name} has unsupported "
                    "text after a quoted value."
                )
        else:
            value = raw_value.partition("#")[0].rstrip(" ")
            if "," in value or ";" in value:
                raise BootconfigError(
                    f"bootconfig line {line_number} in {layer_name} uses unsupported "
                    "array or statement syntax."
                )
        _validate_key_value(key, value)

        if key in values:
            if values[key] != value:
                raise BootconfigConflict(key, layer_name, layer_name)
            _LOGGER.debug(
                "dropping identical duplicate bootconfig key",
                extra={"key": key, "layer": layer_name},
            )
            continue
        values[key] = value
        _check_node_limit(tuple(values))
    return values


def merge_bootconfig_layers(layers: Sequence[BootconfigLayer]) -> dict[str, str]:
    """Merge layers in order and enforce explicit, commented later-layer overrides."""
    values: dict[str, str] = {}
    key_layers: dict[str, str] = {}
    layer_names: set[str] = set()

    for layer in layers:
        if not isinstance(layer, BootconfigLayer):
            raise BootconfigError("bootconfig layers must be BootconfigLayer values.")
        if not isinstance(layer.name, str) or not layer.name.strip():
            raise BootconfigError("bootconfig layer needs a non-empty name.")
        if layer.name in layer_names:
            raise BootconfigError(f"duplicate bootconfig layer name: {layer.name}")
        if not isinstance(layer.values, Mapping) or not isinstance(layer.overrides, Mapping):
            raise BootconfigError(f"bootconfig layer {layer.name} has invalid values or overrides.")
        layer_names.add(layer.name)

        overrides: dict[str, str] = {}
        for key, comment in layer.overrides.items():
            _validate_key_value(key, "")
            if not isinstance(comment, str) or not comment.strip():
                raise BootconfigError(
                    f"override for {key} in layer {layer.name} needs a non-empty comment."
                )
            overrides[key] = comment
        for key in overrides:
            if key not in layer.values:
                raise BootconfigError(
                    f"override for {key} in layer {layer.name} has no corresponding value."
                )

        prior_keys = set(values)
        for key, value in layer.values.items():
            normalized_key, normalized_value = _validate_key_value(key, value)
            if normalized_key in values:
                if values[normalized_key] == normalized_value:
                    _LOGGER.debug(
                        "dropping identical duplicate bootconfig key",
                        extra={
                            "key": normalized_key,
                            "firstLayer": key_layers[normalized_key],
                            "duplicateLayer": layer.name,
                        },
                    )
                    continue
                if normalized_key not in overrides:
                    raise BootconfigConflict(
                        normalized_key,
                        key_layers[normalized_key],
                        layer.name,
                    )
            elif normalized_key in overrides:
                raise BootconfigError(
                    f"override for {normalized_key} in layer {layer.name} has no earlier value."
                )
            values[normalized_key] = normalized_value
            key_layers[normalized_key] = layer.name

        unused_overrides = set(overrides) - prior_keys
        if unused_overrides:
            key = sorted(unused_overrides)[0]
            raise BootconfigError(f"override for {key} in layer {layer.name} has no earlier value.")

    serialize_bootconfig(values)
    return values


def serialize_bootconfig(values: Mapping[str, str]) -> bytes:
    """Serialize sorted key/value pairs with canonical double-quoted values."""
    if not isinstance(values, Mapping):
        raise BootconfigError("bootconfig values must be a mapping.")
    normalized_values = [_validate_key_value(key, value) for key, value in values.items()]
    ordered_values = sorted(normalized_values)
    _check_node_limit([key for key, _value in ordered_values])
    serialized_size = sum(len(key) + len(value) + 6 for key, value in ordered_values)
    if serialized_size > MAX_BUILD_BOOTCONFIG_SIZE:
        raise BootconfigTooLarge(serialized_size)
    encoded = bytearray()
    for key, value in ordered_values:
        encoded.extend(f'{key} = "{value}"\n'.encode("ascii"))
    return bytes(encoded)


def make_bootconfig_trailer(
    bootconfig: bytes | str,
    *,
    command_line: str,
) -> bytes:
    """Create the padded bootconfig block, size, checksum, and Linux magic."""
    tokens = command_line.split() if isinstance(command_line, str) else []
    if "--" in tokens:
        tokens = tokens[: tokens.index("--")]
    if "bootconfig" not in tokens:
        raise BootconfigError("kernel command line must contain the bootconfig token.")
    if isinstance(bootconfig, str):
        try:
            block = bootconfig.encode("ascii")
        except UnicodeEncodeError:
            raise BootconfigError("bootconfig block must contain ASCII characters only.") from None
    elif isinstance(bootconfig, bytes):
        block = bootconfig
    else:
        raise BootconfigError("bootconfig block must be bytes or text.")
    if len(block) > MAX_KERNEL_BOOTCONFIG_SIZE:
        raise BootconfigTooLarge(len(block))
    try:
        parse_bootconfig_text(block.decode("ascii"), layer_name="serialized")
    except UnicodeDecodeError:
        raise BootconfigError("bootconfig block must contain ASCII characters only.") from None

    padding_size = (-len(block)) % 4
    padded_block = block + b"\x00" * padding_size
    if len(padded_block) > MAX_KERNEL_BOOTCONFIG_SIZE:
        raise BootconfigTooLarge(len(padded_block))
    size = len(padded_block)
    checksum = sum(padded_block) & 0xFFFFFFFF
    return padded_block + struct.pack("<II", size, checksum) + BOOTCONFIG_MAGIC
