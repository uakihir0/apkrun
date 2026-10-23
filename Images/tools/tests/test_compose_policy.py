"""Focused tests for Android 17 SELinux policy composition (#36)."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from apkrun_image.compose_policy import (
    PolicyComposeError,
    calculate_policy_hashes,
    compile_precompiled_policy,
    derive_ordered_cil_paths,
    install_precompiled_policy,
    merge_policy_text,
    verify_pinned_secilc,
)


def _put(root: Path, relative: str, content: str = "(allow a b (file (read)))\n") -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


@pytest.fixture
def partition_roots(tmp_path: Path) -> dict[str, Path]:
    system = tmp_path / "system"
    system_ext = tmp_path / "system_ext"
    vendor = tmp_path / "vendor"
    product = tmp_path / "product"
    odm = tmp_path / "odm"
    _put(system, "etc/selinux/plat_sepolicy.cil")
    _put(system, "etc/selinux/mapping/36.0.cil", "(type plat_map)\n")
    _put(system, "etc/selinux/mapping/36.0.compat.cil", "(type plat_compat)\n")
    _put(system, "etc/selinux/plat_sepolicy_genfs_202604.cil", "(type genfs_label)\n")
    _put(system_ext, "etc/selinux/system_ext_sepolicy.cil", "(type ext_policy)\n")
    _put(system_ext, "etc/selinux/mapping/36.0.cil", "(type ext_map)\n")
    _put(system_ext, "etc/selinux/mapping/36.0.compat.cil", "(type ext_compat)\n")
    _put(vendor, "etc/selinux/plat_sepolicy_vers.txt", "36.0\n")
    _put(vendor, "etc/selinux/genfs_labels_version.txt", "202604\n")
    _put(vendor, "etc/selinux/plat_pub_versioned.cil", "(type vendor_public)\n")
    _put(vendor, "etc/selinux/vendor_sepolicy.cil", "(type vendor_policy)\n")
    _put(product, "etc/selinux/product_sepolicy.cil", "(type product_policy)\n")
    _put(product, "etc/selinux/mapping/36.0.cil", "(type product_map)\n")
    _put(odm, "etc/selinux/odm_sepolicy.cil", "(type odm_policy)\n")
    return {
        "system": system,
        "system_ext": system_ext,
        "vendor": vendor,
        "product": product,
        "odm": odm,
    }


def test_android_17_loader_order_and_selected_optional_inputs(
    partition_roots: dict[str, Path],
) -> None:
    result = derive_ordered_cil_paths(partition_roots)
    names = [path.name for path in result.cil_paths]

    assert names == [
        "plat_sepolicy.cil",
        "36.0.cil",
        "36.0.compat.cil",
        "system_ext_sepolicy.cil",
        "36.0.cil",
        "36.0.compat.cil",
        "product_sepolicy.cil",
        "36.0.cil",
        "plat_pub_versioned.cil",
        "vendor_sepolicy.cil",
        "odm_sepolicy.cil",
        "plat_sepolicy_genfs_202604.cil",
    ]
    assert result.mapping_version == "36.0"
    assert result.genfs_version == "202604"
    assert tuple(result.hashes_as_mapping()) == ("plat", "system_ext", "product")


def test_android_17_loader_allows_absent_optional_inputs(
    partition_roots: dict[str, Path],
) -> None:
    partition_roots.pop("product")
    partition_roots.pop("odm")
    (partition_roots["system"] / "etc/selinux/mapping/36.0.compat.cil").unlink()
    (partition_roots["system_ext"] / "etc/selinux/mapping/36.0.compat.cil").unlink()

    result = derive_ordered_cil_paths(partition_roots)

    assert [path.name for path in result.cil_paths] == [
        "plat_sepolicy.cil",
        "36.0.cil",
        "system_ext_sepolicy.cil",
        "36.0.cil",
        "plat_pub_versioned.cil",
        "vendor_sepolicy.cil",
        "plat_sepolicy_genfs_202604.cil",
    ]
    assert tuple(result.hashes_as_mapping()) == ("plat", "system_ext")


def test_android_17_loader_requires_version_selected_inputs(
    partition_roots: dict[str, Path],
) -> None:
    (partition_roots["system"] / "etc/selinux/mapping/36.0.cil").unlink()
    with pytest.raises(PolicyComposeError, match="platform policy mapping"):
        derive_ordered_cil_paths(partition_roots)


@pytest.mark.parametrize(
    ("kind", "existing", "addition", "expected"),
    [
        ("cil", "(type before)\n", "(type after)", b"(type before)\n(type after)\n"),
        (
            "file_contexts",
            "/system_ext/bin/old u:object_r:system_file:s0\n",
            "/system_ext/bin/new u:object_r:system_file:s0",
            b"/system_ext/bin/old u:object_r:system_file:s0\n"
            b"/system_ext/bin/new u:object_r:system_file:s0\n",
        ),
        (
            "seapp_contexts",
            "user=_app seinfo=platform name=io.apkrun.old domain=system_app\n",
            "user=_app seinfo=platform name=io.apkrun.new domain=system_app",
            b"user=_app seinfo=platform name=io.apkrun.old domain=system_app\n"
            b"user=_app seinfo=platform name=io.apkrun.new domain=system_app\n",
        ),
    ],
)
def test_merge_policy_text_appends_a_valid_fragment(
    kind: str, existing: str, addition: str, expected: bytes
) -> None:
    assert merge_policy_text(existing, addition, kind=kind) == expected


def test_merge_policy_text_deduplicates_context_entries() -> None:
    line = "/system_ext/bin/apkrun_vsockd u:object_r:apkrun_vsockd_exec:s0\n"
    assert merge_policy_text(line, line, kind="file_contexts") == line.encode()


@pytest.mark.parametrize(
    ("kind", "existing", "addition"),
    [
        ("cil", "(type valid)\n", "(type broken"),
        (
            "file_contexts",
            "/system_ext/bin/apkrun u:object_r:system_file:s0\n",
            "/system_ext/bin/apkrun u:object_r:vendor_file:s0\n",
        ),
        (
            "seapp_contexts",
            "user=_app seinfo=platform name=io.apkrun.guest domain=system_app\n",
            "name=io.apkrun.guest seinfo=platform user=_app domain=platform_app\n",
        ),
    ],
)
def test_merge_policy_text_rejects_invalid_or_conflicting_input(
    kind: str, existing: str, addition: str
) -> None:
    with pytest.raises(PolicyComposeError):
        merge_policy_text(existing, addition, kind=kind)


def test_aosp_hashes_are_raw_concatenation_plus_newline(
    partition_roots: dict[str, Path],
) -> None:
    policy_inputs = derive_ordered_cil_paths(partition_roots)
    hashes = calculate_policy_hashes(policy_inputs.hashes_as_mapping())
    platform_pair = policy_inputs.hashes_as_mapping()["plat"]
    expected = hashlib.sha256(
        platform_pair[0].read_bytes() + platform_pair[1].read_bytes()
    ).hexdigest()

    assert hashes["plat"] == f"{expected}\n".encode("ascii")
    assert all(value.endswith(b"\n") for value in hashes.values())


def test_aosp_hashes_preserve_unchanged_stock_sidecars(
    partition_roots: dict[str, Path],
) -> None:
    policy_inputs = derive_ordered_cil_paths(partition_roots)
    original_hashes = calculate_policy_hashes(policy_inputs.hashes_as_mapping())
    odm_selinux = partition_roots["odm"] / "etc/selinux"
    for name in ("plat", "product"):
        (odm_selinux / f"precompiled_sepolicy.{name}_sepolicy_and_mapping.sha256").write_bytes(
            original_hashes[name]
        )
    ext_cil = partition_roots["system_ext"] / "etc/selinux/system_ext_sepolicy.cil"
    ext_cil.write_text("(type changed_ext_policy)\n", encoding="utf-8")

    preserved_hashes = calculate_policy_hashes(
        policy_inputs.hashes_as_mapping(),
        unchanged_odm_root=partition_roots["odm"],
    )

    assert preserved_hashes["plat"] == original_hashes["plat"]
    assert preserved_hashes["product"] == original_hashes["product"]
    assert preserved_hashes["system_ext"] != original_hashes["system_ext"]


def test_install_precompiled_policy_replaces_policy_and_sidecars_atomically(
    tmp_path: Path,
) -> None:
    compiled = tmp_path / "compiled"
    compiled.write_bytes(b"compiled Android policy")
    odm = tmp_path / "odm"
    destination = odm / "etc/selinux"
    destination.mkdir(parents=True)
    (destination / "precompiled_sepolicy").write_bytes(b"old policy")
    hashes = {
        "plat": b"a" * 64 + b"\n",
        "system_ext": b"b" * 64 + b"\n",
        "product": b"c" * 64 + b"\n",
    }

    outputs = install_precompiled_policy(compiled, odm, hashes)

    assert outputs["policy"].read_bytes() == b"compiled Android policy"
    for name, digest in hashes.items():
        assert outputs[name].read_bytes() == digest
        assert outputs[name].stat().st_mode & 0o777 == 0o644
    assert not list(destination.glob(".*"))


def test_install_precompiled_policy_rejects_bad_hash_before_mutating(
    tmp_path: Path,
) -> None:
    compiled = tmp_path / "compiled"
    compiled.write_bytes(b"compiled")
    odm = tmp_path / "odm"
    destination = odm / "etc/selinux"
    destination.mkdir(parents=True)
    policy = destination / "precompiled_sepolicy"
    policy.write_bytes(b"previous")

    with pytest.raises(PolicyComposeError, match="64 lowercase hex"):
        install_precompiled_policy(compiled, odm, {"plat": b"bad", "system_ext": b"c" * 65})

    assert policy.read_bytes() == b"previous"


def _fake_pinned_secilc(tool_directory: Path, lock_path: Path) -> Path:
    source_commit = "1" * 40
    component = {
        "name": "selinux-cil",
        "kind": "source",
        "repository": "https://example.invalid/selinux",
        "commit": source_commit,
        "version": "3.11",
        "buildFlags": ["secilc.target=secilc"],
    }
    lock = {
        "components": [
            component,
            {"name": "flex", "sha256": "2" * 64},
            {"name": "m4", "sha256": "3" * 64},
        ]
    }
    lock_path.write_text(json.dumps(lock), encoding="utf-8")
    binary = tool_directory / "bin/secilc"
    binary.parent.mkdir(parents=True)
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import json, pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "out = pathlib.Path(args[args.index('-o') + 1])\n"
        "out.write_bytes(b'compiled policy')\n"
        "(out.parent / 'compiler-argv.json').write_text(json.dumps(args))\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    (tool_directory / "build-manifest.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "component": "selinux-cil",
                "version": "3.11",
                "sourceCommit": source_commit,
                "sourceLock": component,
                "toolArchives": {"flex": "2" * 64, "m4": "3" * 64},
                "cacheKey": "4" * 64 + "-" + "5" * 64,
                "outputs": {"secilc": hashlib.sha256(binary.read_bytes()).hexdigest()},
            }
        ),
        encoding="utf-8",
    )
    return binary


def test_compile_uses_verified_secilc_and_keeps_neverallow_enabled(
    tmp_path: Path,
) -> None:
    tool_directory = tmp_path / "pinned-tools"
    lock_path = tmp_path / "ThirdParty.lock.json"
    _fake_pinned_secilc(tool_directory, lock_path)
    inputs = [tmp_path / "plat.cil", tmp_path / "mapping.cil"]
    for path in inputs:
        path.write_text("(type input)\n", encoding="utf-8")
    output = tmp_path / "odm/precompiled_sepolicy"

    assert verify_pinned_secilc(tool_directory, lock_path).name == "secilc"
    compile_precompiled_policy(tool_directory, lock_path, inputs, output)
    arguments = json.loads((output.parent / "compiler-argv.json").read_text(encoding="utf-8"))

    assert arguments[:7] == ["-m", "-M", "true", "-G", "-c", "30", str(inputs[0])]
    assert arguments[7] == str(inputs[1])
    assert arguments[-4:] == ["-o", arguments[-3], "-f", "/dev/null"]
    assert "-N" not in arguments
    assert output.read_bytes() == b"compiled policy"


def test_compile_rejects_a_modified_pinned_compiler(
    tmp_path: Path,
) -> None:
    tool_directory = tmp_path / "pinned-tools"
    lock_path = tmp_path / "ThirdParty.lock.json"
    binary = _fake_pinned_secilc(tool_directory, lock_path)
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o755)
    source = tmp_path / "policy.cil"
    source.write_text("(type input)\n", encoding="utf-8")

    with pytest.raises(PolicyComposeError, match="pinned build manifest"):
        compile_precompiled_policy(
            tool_directory, lock_path, [source], tmp_path / "out/precompiled_sepolicy"
        )
