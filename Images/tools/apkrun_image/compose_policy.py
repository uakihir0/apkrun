"""Android 17 split SELinux policy composition helpers for #36."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

POLICY_VERSION = 30
_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)?$")
_GENFS_VERSION = re.compile(r"^[0-9]{6}$")
_CACHE_KEY = re.compile(r"^[0-9a-f]{64}-[0-9a-f]{64}$")
_SEAPP_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
_SEAPP_OUTPUT_KEYS = frozenset({"domain", "type", "levelFrom", "level"})
_SEAPP_MATCH_KEYS = frozenset(
    {
        "fromRunAs",
        "isEphemeralApp",
        "isOwner",
        "isPrivApp",
        "isSdkSandboxNext",
        "isSystemServer",
        "minTargetSdkVersion",
        "name",
        "seinfo",
        "user",
    }
)
_HASH_CIL_NAMES = {
    "plat": "plat_sepolicy.cil",
    "system_ext": "system_ext_sepolicy.cil",
    "product": "product_sepolicy.cil",
}
_HASH_SIDECAR_NAMES = {
    "plat": "precompiled_sepolicy.plat_sepolicy_and_mapping.sha256",
    "system_ext": "precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256",
    "product": "precompiled_sepolicy.product_sepolicy_and_mapping.sha256",
}
_LOCKED_COMPONENT = "selinux-cil"
_BUILD_COMPONENTS = ("flex", "m4")


class PolicyComposeError(ValueError):
    """A missing, unsafe, or inconsistent SELinux policy composition input."""


@dataclass(frozen=True)
class PolicyInputs:
    """The exact init-ordered CIL files and AOSP hash input pairs."""

    cil_paths: tuple[Path, ...]
    hash_inputs: tuple[tuple[str, tuple[Path, Path]], ...]
    mapping_version: str
    genfs_version: str | None

    def hashes_as_mapping(self) -> dict[str, tuple[Path, Path]]:
        """Return hash input pairs keyed by AOSP's plat/system_ext/product names."""
        return dict(self.hash_inputs)


def _checked_root(path: Path, name: str, *, required: bool) -> Path | None:
    _reject_symlink_components(path, f"{name} partition root")
    if not path.exists():
        if required:
            raise PolicyComposeError(f"{path}: required {name} partition root is missing.")
        return None
    if not path.is_dir():
        raise PolicyComposeError(f"{path}: {name} partition root must be a directory.")
    return path.resolve(strict=True)


def _regular_file(root: Path, relative: str, description: str) -> Path:
    candidate = root.joinpath(*Path(relative).parts)
    current = root
    for component in Path(relative).parts:
        current = current / component
        if current.is_symlink():
            raise PolicyComposeError(f"{current}: {description} must not be a symlink.")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise PolicyComposeError(f"{candidate}: missing {description}: {error}") from None
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise PolicyComposeError(
            f"{candidate}: {description} must be a regular file in its partition."
        )
    return resolved


def _optional_file(root: Path | None, relative: str, description: str) -> Path | None:
    if root is None:
        return None
    candidate = root.joinpath(*Path(relative).parts)
    if not candidate.exists() and not candidate.is_symlink():
        return None
    return _regular_file(root, relative, description)


def _read_selector(path: Path, pattern: re.Pattern[str], description: str) -> str:
    try:
        content = path.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise PolicyComposeError(f"{path}: cannot read {description}: {error}") from None
    value = content.removesuffix("\n")
    if not value or value.endswith("\n") or "\r" in value or not pattern.fullmatch(value):
        raise PolicyComposeError(f"{path}: invalid {description}.")
    return value


def derive_ordered_cil_paths(partition_roots: Mapping[str, Path]) -> PolicyInputs:
    """Resolve Android 17's init fallback-loader CIL order from extracted roots.

    Required partitions are system, system_ext, and vendor. Product and ODM CIL
    are included only when their partition and policy file are present. AOSP's
    optional mapping compatibility CIL is included immediately after its mapping.
    """
    for name in partition_roots:
        if name not in {"system", "system_ext", "vendor", "product", "odm"}:
            raise PolicyComposeError(f"unsupported policy partition {name!r}.")
    roots = {
        name: _checked_root(
            partition_roots[name], name, required=name in {"system", "system_ext", "vendor"}
        )
        for name in ("system", "system_ext", "vendor", "product", "odm")
        if name in partition_roots or name in {"system", "system_ext", "vendor"}
    }
    system = roots["system"]
    system_ext = roots["system_ext"]
    vendor = roots["vendor"]
    assert system is not None and system_ext is not None and vendor is not None

    vendor_selinux = "etc/selinux"
    version_path = _regular_file(
        vendor, f"{vendor_selinux}/plat_sepolicy_vers.txt", "platform policy version selector"
    )
    mapping_version = _read_selector(version_path, _VERSION, "platform policy version")
    genfs_path = _regular_file(
        vendor, f"{vendor_selinux}/genfs_labels_version.txt", "genfs labels version selector"
    )
    try:
        genfs_text = genfs_path.read_text(encoding="ascii").removesuffix("\n")
    except (OSError, UnicodeDecodeError) as error:
        raise PolicyComposeError(
            f"{genfs_path}: cannot read genfs labels version: {error}"
        ) from None
    if (
        genfs_text.endswith("\n")
        or "\r" in genfs_text
        or (genfs_text and not _GENFS_VERSION.fullmatch(genfs_text))
    ):
        raise PolicyComposeError(f"{genfs_path}: invalid genfs labels version.")

    system_selinux = "etc/selinux"
    system_ext_selinux = "etc/selinux"
    platform_cil = _regular_file(
        system, f"{system_selinux}/plat_sepolicy.cil", "platform policy CIL"
    )
    platform_mapping = _regular_file(
        system,
        f"{system_selinux}/mapping/{mapping_version}.cil",
        "platform policy mapping CIL",
    )
    platform_compat = _optional_file(
        system,
        f"{system_selinux}/mapping/{mapping_version}.compat.cil",
        "platform policy compatibility CIL",
    )

    system_ext_cil = _regular_file(
        system_ext,
        f"{system_ext_selinux}/system_ext_sepolicy.cil",
        "system_ext policy CIL",
    )
    system_ext_mapping = _regular_file(
        system_ext,
        f"{system_ext_selinux}/mapping/{mapping_version}.cil",
        "system_ext policy mapping CIL",
    )
    system_ext_compat = _optional_file(
        system_ext,
        f"{system_ext_selinux}/mapping/{mapping_version}.compat.cil",
        "system_ext policy compatibility CIL",
    )

    cil_paths: list[Path] = [platform_cil, platform_mapping]
    if platform_compat is not None:
        cil_paths.append(platform_compat)
    cil_paths.append(system_ext_cil)
    cil_paths.append(system_ext_mapping)
    if system_ext_compat is not None:
        cil_paths.append(system_ext_compat)

    hash_inputs: list[tuple[str, tuple[Path, Path]]] = [
        ("plat", (platform_cil, platform_mapping)),
        ("system_ext", (system_ext_cil, system_ext_mapping)),
    ]

    product_root = roots.get("product")
    product_cil = _optional_file(
        product_root, "etc/selinux/product_sepolicy.cil", "product policy CIL"
    )
    if product_cil is not None:
        product_mapping = _regular_file(
            product_root,  # type: ignore[arg-type]
            f"etc/selinux/mapping/{mapping_version}.cil",
            "product policy mapping CIL",
        )
        cil_paths.extend((product_cil, product_mapping))
        hash_inputs.append(("product", (product_cil, product_mapping)))
    elif product_root is not None:
        mapping_without_policy = _optional_file(
            product_root,  # type: ignore[arg-type]
            f"etc/selinux/mapping/{mapping_version}.cil",
            "product policy mapping CIL",
        )
        if mapping_without_policy is not None:
            raise PolicyComposeError(
                f"{mapping_without_policy}: mapping exists without product_sepolicy.cil."
            )

    vendor_public = _regular_file(
        vendor, f"{vendor_selinux}/plat_pub_versioned.cil", "versioned platform public CIL"
    )
    vendor_cil = _regular_file(vendor, f"{vendor_selinux}/vendor_sepolicy.cil", "vendor policy CIL")
    cil_paths.extend((vendor_public, vendor_cil))

    odm_root = roots.get("odm")
    odm_cil = _optional_file(odm_root, "etc/selinux/odm_sepolicy.cil", "ODM policy CIL")
    if odm_cil is not None:
        cil_paths.append(odm_cil)

    genfs_cil = None
    if genfs_text:
        genfs_cil = _regular_file(
            system,
            f"{system_selinux}/plat_sepolicy_genfs_{genfs_text}.cil",
            "selected platform genfs CIL",
        )
        cil_paths.append(genfs_cil)

    return PolicyInputs(
        cil_paths=tuple(cil_paths),
        hash_inputs=tuple(hash_inputs),
        mapping_version=mapping_version,
        genfs_version=genfs_text or None,
    )


def _decode_policy_text(value: str | bytes, description: str) -> str:
    if isinstance(value, bytes):
        try:
            text = value.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise PolicyComposeError(f"{description} is not UTF-8: {error}") from None
    elif isinstance(value, str):
        text = value
    else:
        raise PolicyComposeError(f"{description} must be text or UTF-8 bytes.")
    if "\0" in text or "\r" in text:
        raise PolicyComposeError(f"{description} contains a NUL or non-canonical CR character.")
    return text


def _validate_cil(text: str, description: str) -> None:
    depth = 0
    quoted = False
    escaped = False
    comment = False
    for character in text:
        if comment:
            if character == "\n":
                comment = False
            continue
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            continue
        if character == ";":
            comment = True
        elif character == '"':
            quoted = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth < 0:
                raise PolicyComposeError(f"{description} has an unmatched closing parenthesis.")
    if quoted or depth:
        raise PolicyComposeError(f"{description} has an unterminated string or unbalanced CIL.")


def _context_identity(
    line: str, kind: Literal["file_contexts", "seapp_contexts"]
) -> tuple[str, ...]:
    fields = line.split()
    if kind == "file_contexts":
        if len(fields) < 2:
            raise PolicyComposeError(f"invalid file_contexts entry: {line!r}.")
        selector = [fields[0]]
        if fields[1].startswith("-"):
            if len(fields) < 3:
                raise PolicyComposeError(f"invalid file_contexts entry: {line!r}.")
            selector.append(fields[1])
        return tuple(selector)

    properties: dict[str, str] = {}
    for field in fields:
        key, separator, value = field.partition("=")
        if not separator or not _SEAPP_KEY.fullmatch(key) or not value or key in properties:
            raise PolicyComposeError(f"invalid seapp_contexts entry: {line!r}.")
        properties[key] = value
    match = tuple(
        sorted((key, value) for key, value in properties.items() if key in _SEAPP_MATCH_KEYS)
    )
    unknown = properties.keys() - _SEAPP_MATCH_KEYS - _SEAPP_OUTPUT_KEYS
    if not match or unknown:
        raise PolicyComposeError(f"invalid seapp_contexts selector: {line!r}.")
    return match


def merge_policy_text(
    existing: str | bytes,
    appended: str | bytes,
    *,
    kind: Literal["cil", "file_contexts", "seapp_contexts"],
) -> bytes:
    """Validate and append a policy fragment without ambiguous duplicate entries."""
    if kind not in {"cil", "file_contexts", "seapp_contexts"}:
        raise PolicyComposeError(f"unsupported policy text kind {kind!r}.")
    base = _decode_policy_text(existing, "existing policy")
    addition = _decode_policy_text(appended, "appended policy")
    if kind == "cil":
        _validate_cil(base, "existing policy")
        _validate_cil(addition, "appended policy")
    elif kind == "file_contexts":
        _validate_contexts(base, kind)
        addition = _dedupe_contexts(base, addition, kind)
    else:
        _validate_contexts(base, kind)
        addition = _dedupe_contexts(base, addition, kind)
    if not addition:
        return base.encode("utf-8")
    separator = "" if not base or base.endswith("\n") else "\n"
    result = f"{base}{separator}{addition}"
    if not result.endswith("\n"):
        result += "\n"
    return result.encode("utf-8")


def _context_entries(
    text: str,
    kind: Literal["file_contexts", "seapp_contexts"],
) -> list[tuple[str, tuple[str, ...]]]:
    entries = []
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        entries.append((stripped, _context_identity(stripped, kind)))
    return entries


def _validate_contexts(text: str, kind: Literal["file_contexts", "seapp_contexts"]) -> None:
    seen: dict[tuple[str, ...], str] = {}
    for line, identity in _context_entries(text, kind):
        previous = seen.get(identity)
        if previous is not None and previous != line:
            raise PolicyComposeError(f"conflicting {kind} entries share selector {identity!r}.")
        seen[identity] = line


def _dedupe_contexts(
    existing: str,
    appended: str,
    kind: Literal["file_contexts", "seapp_contexts"],
) -> str:
    identities = {identity: line for line, identity in _context_entries(existing, kind)}
    lines: list[str] = []
    for raw_line in appended.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            lines.append(raw_line)
            continue
        identity = _context_identity(stripped, kind)
        previous = identities.get(identity)
        if previous is not None:
            if previous != stripped:
                raise PolicyComposeError(
                    f"conflicting appended {kind} entry for selector {identity!r}."
                )
            continue
        identities[identity] = stripped
        lines.append(raw_line)
    return "\n".join(lines)


def merge_policy_file(
    existing_path: Path,
    appended_path: Path,
    output_path: Path,
    *,
    kind: Literal["cil", "file_contexts", "seapp_contexts"],
) -> Path:
    """Merge two real files and atomically write the validated UTF-8 result."""
    for path, description in (
        (existing_path, "existing policy"),
        (appended_path, "appended policy"),
    ):
        if path.is_symlink() or not path.is_file():
            raise PolicyComposeError(f"{path}: {description} must be a regular file.")
    try:
        result = merge_policy_text(
            existing_path.read_bytes(), appended_path.read_bytes(), kind=kind
        )
        mode = stat.S_IMODE(existing_path.stat().st_mode)
        _atomic_write(output_path, result, mode=mode)
    except OSError as error:
        raise PolicyComposeError(f"could not merge policy files: {error}") from None
    return output_path


def calculate_policy_hashes(
    hash_inputs: Mapping[str, Sequence[Path]],
    *,
    unchanged_odm_root: Path | None = None,
) -> dict[str, bytes]:
    """Compute AOSP hashes, retaining verified stock plat/product hash bytes.

    ``unchanged_odm_root`` lets composition preserve the source image's platform
    and product sidecars byte-for-byte while recalculating the changed system_ext
    pair. The preserved values must match the selected stock CIL inputs.
    """
    if not {"plat", "system_ext"}.issubset(hash_inputs):
        raise PolicyComposeError("platform and system_ext hash inputs are required.")
    unknown = set(hash_inputs) - set(_HASH_CIL_NAMES)
    if unknown:
        raise PolicyComposeError(f"unsupported policy hash group(s): {sorted(unknown)}.")
    hashes: dict[str, bytes] = {}
    for name in ("plat", "system_ext", "product"):
        paths = hash_inputs.get(name)
        if paths is None:
            continue
        if len(paths) != 2:
            raise PolicyComposeError(f"{name} hash inputs must contain CIL and mapping paths.")
        digest = hashlib.sha256()
        for path in paths:
            _reject_symlink_components(path, "policy hash input")
            if not path.is_file():
                raise PolicyComposeError(f"{path}: policy hash input must be a regular file.")
            try:
                with path.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
            except OSError as error:
                raise PolicyComposeError(f"cannot hash {path}: {error}") from None
        hashes[name] = f"{digest.hexdigest()}\n".encode("ascii")
    if unchanged_odm_root is not None:
        odm_selinux = _safe_directory(unchanged_odm_root / "etc" / "selinux", create=False)
        for name in ("plat", "product"):
            if name not in hashes:
                continue
            sidecar = odm_selinux / _HASH_SIDECAR_NAMES[name]
            if sidecar.is_symlink() or not sidecar.is_file():
                raise PolicyComposeError(f"{sidecar}: unchanged stock hash sidecar is missing.")
            try:
                original = sidecar.read_bytes()
            except OSError as error:
                raise PolicyComposeError(f"{sidecar}: cannot read stock hash: {error}") from None
            if not re.fullmatch(rb"[0-9a-f]{64}\n", original) or original != hashes[name]:
                raise PolicyComposeError(
                    f"{sidecar}: stock hash does not match the unchanged {name} policy inputs."
                )
            hashes[name] = original
    return hashes


def _safe_directory(path: Path, *, create: bool) -> Path:
    absolute = Path(os.path.abspath(path))
    _reject_symlink_components(absolute, "output directory")
    if create:
        absolute.mkdir(parents=True, exist_ok=True)
    if not absolute.is_dir():
        raise PolicyComposeError(f"{absolute}: output directory is missing or not a directory.")
    return absolute.resolve(strict=True)


def _reject_symlink_components(path: Path, description: str) -> None:
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current = current / component
        if current.is_symlink():
            raise PolicyComposeError(f"{current}: {description} contains a symlink.")


def _atomic_write(path: Path, content: bytes, *, mode: int) -> None:
    if path.name in {"", ".", ".."}:
        raise PolicyComposeError(f"{path}: invalid output filename.")
    parent = _safe_directory(path.parent, create=True)
    if path.is_symlink():
        raise PolicyComposeError(f"{path}: refusing to replace a symlink.")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(mode)
        os.replace(temporary, parent / path.name)
        _fsync_directory(parent)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install_precompiled_policy(
    compiled_policy: Path,
    odm_root: Path,
    hashes: Mapping[str, bytes],
) -> dict[str, Path]:
    """Atomically replace precompiled policy and its AOSP-matching ODM sidecars."""
    _reject_symlink_components(compiled_policy, "compiled policy")
    if not compiled_policy.is_file():
        raise PolicyComposeError(f"{compiled_policy}: compiled policy must be a regular file.")
    if compiled_policy.stat().st_size == 0:
        raise PolicyComposeError(f"{compiled_policy}: compiled policy is empty.")
    if not {"plat", "system_ext"}.issubset(hashes):
        raise PolicyComposeError("platform and system_ext hash sidecars are required.")
    if set(hashes) - set(_HASH_SIDECAR_NAMES):
        raise PolicyComposeError("hash sidecars include an unsupported policy group.")
    for name, content in hashes.items():
        if not isinstance(content, bytes) or not re.fullmatch(rb"[0-9a-f]{64}\n", content):
            raise PolicyComposeError(
                f"{name} hash sidecar must be 64 lowercase hex digits plus LF."
            )

    root = _safe_directory(odm_root, create=False)
    selinux_directory = _safe_directory(root / "etc" / "selinux", create=True)
    outputs = {"policy": selinux_directory / "precompiled_sepolicy"}
    outputs.update({name: selinux_directory / _HASH_SIDECAR_NAMES[name] for name in hashes})
    for destination in outputs.values():
        if destination.is_symlink():
            raise PolicyComposeError(f"{destination}: refusing to replace a symlink.")

    staged: dict[Path, Path] = {}
    try:
        for name, destination in outputs.items():
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{destination.name}.", dir=selinux_directory
            )
            temporary = Path(temporary_name)
            staged[destination] = temporary
            if name == "policy":
                with compiled_policy.open("rb") as source, os.fdopen(descriptor, "wb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                    target.flush()
                    os.fsync(target.fileno())
            else:
                with os.fdopen(descriptor, "wb") as target:
                    target.write(hashes[name])
                    target.flush()
                    os.fsync(target.fileno())
            temporary.chmod(0o644)
        for destination, temporary in staged.items():
            os.replace(temporary, destination)
        _fsync_directory(selinux_directory)
    except (OSError, PolicyComposeError) as error:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)
        raise PolicyComposeError(
            f"could not install compiled policy and hash sidecars: {error}"
        ) from None
    return outputs


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_locked_component(lock_path: Path) -> dict[str, object]:
    _reject_symlink_components(lock_path, "third-party lock")
    if not lock_path.is_file():
        raise PolicyComposeError(f"{lock_path}: third-party lock must be a regular file.")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyComposeError(f"{lock_path}: cannot read third-party lock: {error}") from None
    components = lock.get("components") if isinstance(lock, dict) else None
    if not isinstance(components, list):
        raise PolicyComposeError(f"{lock_path}: expected a components array.")
    matches = [
        component
        for component in components
        if isinstance(component, dict) and component.get("name") == _LOCKED_COMPONENT
    ]
    if len(matches) != 1:
        raise PolicyComposeError(
            f"{lock_path}: expected exactly one {_LOCKED_COMPONENT} component."
        )
    component = matches[0]
    if (
        component.get("kind") != "source"
        or not isinstance(component.get("commit"), str)
        or not isinstance(component.get("version"), str)
        or not isinstance(component.get("buildFlags"), list)
    ):
        raise PolicyComposeError(f"{lock_path}: {_LOCKED_COMPONENT} component is incomplete.")
    return component


def verify_pinned_secilc(tool_directory: Path, third_party_lock: Path) -> Path:
    """Verify the secilc build manifest against ThirdParty.lock before use."""
    _reject_symlink_components(tool_directory, "pinned secilc tool")
    if not tool_directory.is_dir():
        raise PolicyComposeError(f"{tool_directory}: pinned secilc tool directory is invalid.")
    manifest_path = tool_directory / "build-manifest.json"
    binary_directory = tool_directory / "bin"
    binary = tool_directory / "bin" / "secilc"
    _reject_symlink_components(manifest_path, "secilc build manifest")
    _reject_symlink_components(binary_directory, "secilc binary directory")
    _reject_symlink_components(binary, "secilc binary")
    if not manifest_path.is_file() or not binary.is_file():
        raise PolicyComposeError(f"{tool_directory}: pinned secilc output is missing or unsafe.")
    if not os.access(binary, os.X_OK):
        raise PolicyComposeError(f"{binary}: pinned secilc binary is not executable.")
    component = _read_locked_component(third_party_lock)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyComposeError(f"{manifest_path}: cannot read build manifest: {error}") from None
    if not isinstance(manifest, dict):
        raise PolicyComposeError(f"{manifest_path}: expected a JSON object.")
    actual_sha256 = _sha256_file(binary)
    outputs = manifest.get("outputs")
    cache_key = manifest.get("cacheKey")
    expected_archives = {}
    try:
        lock = json.loads(third_party_lock.read_text(encoding="utf-8"))
        for dependency in _BUILD_COMPONENTS:
            matches = [
                item
                for item in lock["components"]
                if isinstance(item, dict) and item.get("name") == dependency
            ]
            if len(matches) != 1 or not isinstance(matches[0].get("sha256"), str):
                raise PolicyComposeError(
                    f"{third_party_lock}: missing pinned {dependency} archive."
                )
            expected_archives[dependency] = matches[0]["sha256"]
    except (KeyError, OSError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyComposeError(
            f"{third_party_lock}: cannot validate secilc dependencies: {error}"
        ) from None
    if (
        manifest.get("schemaVersion") != 1
        or manifest.get("component") != _LOCKED_COMPONENT
        or manifest.get("version") != component["version"]
        or manifest.get("sourceCommit") != component["commit"]
        or manifest.get("sourceLock") != component
        or manifest.get("toolArchives") != expected_archives
        or not isinstance(cache_key, str)
        or not _CACHE_KEY.fullmatch(cache_key)
        or not isinstance(outputs, dict)
        or outputs != {"secilc": actual_sha256}
    ):
        raise PolicyComposeError(
            f"{manifest_path}: secilc does not match its pinned build manifest."
        )
    return binary


def compile_precompiled_policy(
    tool_directory: Path,
    third_party_lock: Path,
    cil_paths: Sequence[Path],
    output_path: Path,
    *,
    timeout_seconds: int = 300,
) -> Path:
    """Run verified Android 17 secilc with neverallow checks enabled."""
    if not cil_paths:
        raise PolicyComposeError("at least one CIL input is required.")
    for path in cil_paths:
        _reject_symlink_components(path, "secilc input")
        if not path.is_file():
            raise PolicyComposeError(f"{path}: secilc input must be a regular file.")
    if (
        not isinstance(timeout_seconds, int)
        or isinstance(timeout_seconds, bool)
        or timeout_seconds <= 0
    ):
        raise PolicyComposeError("secilc timeout must be a positive integer.")
    compiler = verify_pinned_secilc(tool_directory, third_party_lock)
    parent = _safe_directory(output_path.parent, create=True)
    if output_path.is_symlink():
        raise PolicyComposeError(f"{output_path}: refusing to replace a symlink.")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=parent)
    temporary = Path(temporary_name)
    os.close(descriptor)
    arguments = [
        str(compiler),
        "-m",
        "-M",
        "true",
        "-G",
        "-c",
        str(POLICY_VERSION),
        *(str(path) for path in cil_paths),
        "-o",
        str(temporary),
        "-f",
        "/dev/null",
    ]
    try:
        result = subprocess.run(
            arguments,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
        )
        if result.returncode:
            raise PolicyComposeError(
                f"secilc failed with status {result.returncode}: {result.stdout[-4000:]}"
            )
        if temporary.is_symlink() or not temporary.is_file() or temporary.stat().st_size == 0:
            raise PolicyComposeError("secilc succeeded without producing a non-empty policy.")
        os.chmod(temporary, 0o644)
        os.replace(temporary, parent / output_path.name)
        _fsync_directory(parent)
    except subprocess.TimeoutExpired:
        raise PolicyComposeError(f"secilc exceeded {timeout_seconds} seconds.") from None
    except OSError as error:
        raise PolicyComposeError(f"could not run secilc: {error}") from None
    finally:
        temporary.unlink(missing_ok=True)
    return output_path
