"""T0 orchestration tests for complete Android image composition (#36)."""

from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest

from apkrun_image import compose_command as command
from apkrun_image.erofs import REGULAR_FILE, Entry, TarMember
from apkrun_image.vendor_inject import MESA_LIBRARIES

SYSTEM_EXT_SIZE = 8192
ODM_SIZE = 8192
VENDOR_SIZE = 8192
SYSTEM_EXT_GROUP = "google_system_dynamic_partitions_a"
ODM_GROUP = "google_vendor_dynamic_partitions_a"
SYSTEM_EXT_DESCRIPTOR = {
    "partition": "system_ext",
    "dataBlockSize": 4096,
    "hashBlockSize": 4096,
    "fecRoots": 2,
    "hashAlgorithm": "blake2b-256",
    "salt": "system-ext-salt",
    "imageSize": 4096,
}
ODM_DESCRIPTOR = {
    "partition": "odm",
    "dataBlockSize": 4096,
    "hashBlockSize": 4096,
    "fecRoots": 2,
    "hashAlgorithm": "sha256",
    "salt": "odm-salt",
    "imageSize": 4096,
}
VENDOR_DESCRIPTOR = {
    "partition": "vendor",
    "dataBlockSize": 4096,
    "hashBlockSize": 4096,
    "fecRoots": 2,
    "hashAlgorithm": "sha256",
    "salt": "vendor-salt",
    "imageSize": 4096,
}
SEALED_ODM_DESCRIPTOR = {**ODM_DESCRIPTOR, "rootDigest": "rebuilt-odm"}
SEALED_VENDOR_DESCRIPTOR = {**VENDOR_DESCRIPTOR, "rootDigest": "rebuilt-vendor"}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_test_overlay(
    repository: Path,
    *,
    destination: str = "/system_ext/etc/init/apkrun_test.rc",
    source: str = "init/apkrun_test.rc",
) -> tuple[Path, Path]:
    fixture_root = repository / command.TEST_OVERLAY_RELATIVE_ROOT
    source_path = fixture_root / source
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_text("on boot\n    setprop apkrun.test_overlay 1\n", encoding="utf-8")
    plan_path = fixture_root / "compose.json"
    plan_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "entries": [
                    {
                        "source": source,
                        "destination": destination,
                        "kind": "regular file",
                        "mode": "0644",
                        "owner": {"uid": 0, "gid": 0},
                        "label": "u:object_r:system_file:s0",
                    }
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return fixture_root, plan_path


def _install_composer_fakes(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    *,
    fail_on_top_level_vbmeta: bool = False,
    mismatch_stock_system_ext_descriptor: bool = False,
    mismatch_stock_vendor_descriptor: bool = False,
) -> tuple[Path, Path, Path, dict[str, object]]:
    repository = tmp_path / "repository"
    product_root = repository / "Guest/product"
    manifest_path = repository / "Images/manifests/16373615/android-image.json"
    source_root = tmp_path / "source"
    inventory_path = repository / "Images/manifests/16373615/inventory.json"
    output_parent = tmp_path / "outputs"
    output_directory = output_parent / "composed"
    source_root.mkdir(parents=True)
    output_parent.mkdir()
    product_root.mkdir(parents=True)
    manifest_path.parent.mkdir(parents=True)
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    inventory_path.write_text("{}\n", encoding="utf-8")

    (product_root / "payload").mkdir()
    (product_root / "payload/apkrun.bin").write_bytes(b"apkrun fixture\n")
    (product_root / "prebuilt").mkdir()
    (product_root / command.GUEST_AGENT_APK).write_bytes(b"fixture APK")
    mesa_directory = product_root / command.MESA_PRODUCT_RELATIVE_PATH
    mesa_records: list[dict[str, object]] = []
    for name in MESA_LIBRARIES:
        header = bytearray(64)
        header[0:4] = b"\x7fELF"
        header[4] = 2
        header[5] = 1
        header[6] = 1
        header[16:18] = (3).to_bytes(2, "little")
        header[18:20] = (183).to_bytes(2, "little")
        content = bytes(header) + b"\0" + name.encode("ascii") + b"\0"
        library = mesa_directory / "vendor/lib64" / name
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_bytes(content)
        mesa_records.append(
            {
                "path": f"vendor/lib64/{name}",
                "sha256": hashlib.sha256(content).hexdigest(),
                "size": len(content),
                "class": "ELF64",
                "machine": "AArch64",
                "soname": name,
            }
        )
    real_load_component = command.load_component
    pinned_mesa = real_load_component(command.MESA_COMPONENT)
    pinned_ndk = real_load_component("ndk")
    third_party_lock = command._repository_root() / "ThirdParty/ThirdParty.lock.json"
    mesa_manifest = {
        "schemaVersion": 1,
        "component": "mesa-android",
        "mesa": {"commit": pinned_mesa["commit"], "version": pinned_mesa["version"]},
        "tools": {"ndk": pinned_ndk["version"]},
        "buildFlags": pinned_mesa["buildFlags"],
        "lock": {
            "path": "ThirdParty/ThirdParty.lock.json",
            "sha256": _sha256(third_party_lock),
            "group": "guest-mesa",
        },
        "files": mesa_records,
    }
    (mesa_directory / "manifest.json").write_text(
        json.dumps(mesa_manifest, indent=2) + "\n", encoding="utf-8"
    )
    plan = {
        "schemaVersion": 1,
        "entries": [
            {
                "source": "payload/apkrun.bin",
                "destination": "/system_ext/bin/apkrun",
                "kind": "regular file",
                "mode": "0755",
                "owner": {"uid": 0, "gid": 0},
                "label": "u:object_r:system_file:s0",
            },
            {
                "source": command.GUEST_AGENT_APK,
                "destination": command.GUEST_AGENT_IMAGE_PATH,
                "kind": "regular file",
                "mode": "0644",
                "owner": {"uid": 0, "gid": 0},
                "label": "u:object_r:system_file:s0",
            },
        ],
    }
    (product_root / "compose.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    for relative in command.PRODUCT_POLICY_INPUTS:
        path = product_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"fixture: {relative}\n", encoding="utf-8")
    for relative in command.PRODUCT_BUNDLE_INPUTS:
        path = product_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '{"packageName":"io.apkrun.guest","versionCode":1,"versionName":"test"}\n',
            encoding="utf-8",
        )
    certificate = command._repository_root() / "Tests/Fixtures/signing/aosp-test-platform.x509.pem"
    certificate_target = repository / "Tests/Fixtures/signing/aosp-test-platform.x509.pem"
    certificate_target.parent.mkdir(parents=True, exist_ok=True)
    certificate_target.write_bytes(certificate.read_bytes())
    android_home = repository / "android-sdk"
    build_tools = android_home / "build-tools" / command.ANDROID_BUILD_TOOLS_VERSION
    build_tools.mkdir(parents=True)
    (build_tools / "aapt2").write_text(
        "#!/usr/bin/env python3\n"
        "print(\"package: name='io.apkrun.guest' versionCode='1' versionName='test'\")\n",
        encoding="utf-8",
    )
    (build_tools / "apksigner").write_text(
        "#!/usr/bin/env python3\n"
        "print('V3.0 Signer: certificate SHA-256 digest: "
        "c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8')\n",
        encoding="utf-8",
    )
    for tool in (build_tools / "aapt2", build_tools / "apksigner"):
        tool.chmod(0o755)
    monkeypatch.setenv("ANDROID_HOME", str(android_home))

    document: dict[str, object] = {
        "source": {
            "origin": "ci.android.com",
            "buildId": "16373615",
            "target": "aosp_cf_arm64_only_phone-userdebug",
            "archives": [],
        },
        "roles": {"super": "stock-super"},
        "artifacts": [
            {"id": "stock-super", "partition": "super", "file": "super.img"},
            {
                "id": "stock-vbmeta-system",
                "partition": "vbmeta_system",
                "file": "vbmeta_system.img",
            },
            {"id": "stock-vbmeta", "partition": "vbmeta", "file": "vbmeta.img"},
        ],
        "logicalPartitions": [
            {"name": "system_ext_a", "size": SYSTEM_EXT_SIZE},
            {"name": "odm_a", "size": ODM_SIZE},
            {"name": "vendor_a", "size": VENDOR_SIZE},
        ],
    }
    manifest_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    @contextmanager
    def open_artifact(
        _document: object, _root: Path, _archives: list[Path], artifact: object
    ) -> Iterator[io.BytesIO]:
        name = artifact["file"]  # type: ignore[index]
        yield io.BytesIO(f"stock artifact: {name}\n".encode())

    monkeypatch.setattr(command, "_repository_root", lambda: repository)
    monkeypatch.setattr(
        command,
        "_validate_inputs",
        lambda *_args: (document, source_root, [], inventory_path),
    )
    monkeypatch.setattr(command, "_open_artifact", open_artifact)
    monkeypatch.setattr(command, "verify_tools", lambda _root: SimpleNamespace(version="fixture-1"))
    monkeypatch.setattr(
        command,
        "load_component",
        lambda component: (
            real_load_component(component)
            if component == command.MESA_COMPONENT
            else Path("/fixture/avbtool.py")
        ),
    )
    monkeypatch.setattr(command, "verify_avbtool", lambda *_args: Path("/fixture/avbtool.py"))
    monkeypatch.setattr(command, "_verify_pinned_fec_tool", lambda _repository, tool: tool)

    def partitions_for(stream: object, *, sparse: bool) -> SimpleNamespace:
        assert sparse is True
        name = Path(stream.name).name  # type: ignore[attr-defined]
        system_ext_size = SYSTEM_EXT_SIZE
        odm_size = ODM_SIZE
        if name in {"super-grown.img", "super-system-ext-composed.img", "super-grown-odm.img"}:
            system_ext_size += 4096
        if name == "super-grown-odm.img":
            odm_size += 4096
        entries = (
            SimpleNamespace(name="system_ext_a", size=system_ext_size, group=SYSTEM_EXT_GROUP),
            SimpleNamespace(name="odm_a", size=odm_size, group=ODM_GROUP),
            SimpleNamespace(name="system_a", size=16384, group=SYSTEM_EXT_GROUP),
            SimpleNamespace(name="product_a", size=8192, group=SYSTEM_EXT_GROUP),
            SimpleNamespace(name="vendor_a", size=VENDOR_SIZE, group=ODM_GROUP),
        )
        return SimpleNamespace(logical_partitions=entries)

    monkeypatch.setattr(command.lp, "read_dynamic_partitions", partitions_for)

    def copy_logical_partition(_super: Path, name: str, destination: Path) -> int:
        data = f"partition:{name}:".encode() + bytes(4096)
        destination.write_bytes(data)
        return len(data)

    monkeypatch.setattr(command, "_copy_logical_partition", copy_logical_partition)
    monkeypatch.setattr(
        command,
        "_copy_prefix",
        lambda _source, destination, _size: destination.write_bytes(b"E" * 4096),
    )

    def filesystem_prefix(
        _avbtool: Path, _partition_image: Path, name: str, destination: Path
    ) -> int:
        destination.write_bytes((name.encode("ascii") + b"\0") * 512)
        return destination.stat().st_size

    monkeypatch.setattr(command, "_filesystem_prefix", filesystem_prefix)

    def export_tree(_tools: object, image: Path, tree: Path) -> None:
        tree.mkdir()
        if image.name == "system-stock.erofs":
            contexts = tree / "system/etc/selinux/plat_file_contexts"
            contexts.parent.mkdir(parents=True)
            contexts.write_text(
                "/vendor/lib64/egl/libEGL_mesa\\.so u:object_r:vendor_file:s0\n",
                encoding="utf-8",
            )

    monkeypatch.setattr(command, "export_tree", export_tree)
    monkeypatch.setattr(
        command,
        "_verify_product_labels",
        lambda *_args: {"rules": 2, "placements": 2},
    )

    def policy_replacements(
        _tools: object,
        _product: Path,
        _trees: object,
        work: Path,
        _repository: Path,
        _secilc_root: Path,
        odm_output_tree: Path,
    ) -> tuple[dict[str, Path], Path, dict[str, object]]:
        replacements: dict[str, Path] = {}
        for index, image_path in enumerate(
            (
                "/system_ext/etc/selinux/system_ext_sepolicy.cil",
                "/system_ext/etc/selinux/system_ext_file_contexts",
                "/system_ext/etc/selinux/system_ext_seapp_contexts",
            )
        ):
            source = work / f"replacement-{index}"
            source.write_text(f"replacement {index}\n", encoding="utf-8")
            replacements[image_path] = source
        return replacements, work / "odm-stock-tree", {"cilInputs": 7, "fixture": True}

    monkeypatch.setattr(command, "_policy_replacements", policy_replacements)
    monkeypatch.setattr(
        command,
        "stock_system_ext_descriptor",
        lambda *_args: dict(SYSTEM_EXT_DESCRIPTOR),
    )
    monkeypatch.setattr(command, "_info", lambda _avbtool, image: {"image": image.name})
    monkeypatch.setattr(command, "_original_size", lambda _info, _partition: 4096)

    def partition_tree(info: object, partition: str, _description: str) -> dict[str, object]:
        image_name = info["image"]  # type: ignore[index]
        if image_name == "vbmeta-stock.img":
            if partition == "vendor" and mismatch_stock_vendor_descriptor:
                return {**VENDOR_DESCRIPTOR, "rootDigest": "different"}
            return dict(ODM_DESCRIPTOR if partition == "odm" else VENDOR_DESCRIPTOR)
        if image_name in {"vbmeta-after-odm.img", "vbmeta_a.img"}:
            descriptors = (
                {
                    "odm": SEALED_ODM_DESCRIPTOR,
                    "vendor": VENDOR_DESCRIPTOR,
                }
                if image_name == "vbmeta-after-odm.img"
                else {
                    "odm": SEALED_ODM_DESCRIPTOR,
                    "vendor": SEALED_VENDOR_DESCRIPTOR,
                }
            )
            return dict(descriptors[partition])
        return dict(ODM_DESCRIPTOR if partition == "odm" else VENDOR_DESCRIPTOR)

    monkeypatch.setattr(command, "_partition_tree", partition_tree)

    def rebuild_vendor(
        _tools: object,
        _stock: Path,
        scratch: Path,
        libraries: object,
        *,
        plat_name: str,
        plat_text: str,
        image_uuid: str,
    ) -> SimpleNamespace:
        assert plat_name == "system_a:/system/etc/selinux/plat_file_contexts"
        assert "plat_file_contexts" in plat_text or "vendor_file" in plat_text
        assert len(libraries) == len(MESA_LIBRARIES)  # type: ignore[arg-type]
        image = scratch / "vendor-mesa.erofs"
        image.write_bytes(b"V" * 8192)
        mesa_entries = {
            library.target: SimpleNamespace(label="u:object_r:vendor_file:s0")
            for library in libraries  # type: ignore[union-attr]
        }
        return SimpleNamespace(
            image=image,
            image_uuid=image_uuid,
            reproduced=21,
            stock_blocks=8,
            fs_blocks=9,
            mesa_entries=mesa_entries,
        )

    monkeypatch.setattr(command, "rebuild_vendor", rebuild_vendor)

    def rebuild_system_ext(
        _tools: object,
        _stock: Path,
        _product: Path,
        work: Path,
        *,
        image_uuid: str,
        replacements: dict[str, Path],
    ) -> SimpleNamespace:
        assert len(replacements) == 3
        image = work / "system-ext-rebuilt.erofs"
        image.write_bytes(b"S" * 8192)
        return SimpleNamespace(
            image=image,
            image_uuid=image_uuid,
            stock_entries_reproduced=12,
            added_entries={"new": object()},
        )

    monkeypatch.setattr(command, "rebuild_system_ext", rebuild_system_ext)

    def rebuild_odm(
        _tools: object,
        _stock: Path,
        _stock_tree: Path,
        _modified_tree: Path,
        work: Path,
        *,
        image_uuid: str,
    ) -> tuple[Path, dict[str, object]]:
        image = work / "odm-rebuilt.erofs"
        image.write_bytes(b"O" * 8192)
        return image, {"imageUUID": image_uuid, "filesystemBytes": image.stat().st_size}

    monkeypatch.setattr(command, "_rebuild_odm_policy", rebuild_odm)
    monkeypatch.setattr(
        command, "partition_growth_limit", lambda _super, _name: SYSTEM_EXT_SIZE + 16384
    )
    monkeypatch.setattr(
        command,
        "minimum_partition_size",
        lambda _avbtool, _filesystem, **kwargs: kwargs["current_size"] + 4096,
    )

    def minimum_partition_size_for_descriptor(
        _avbtool: object, _filesystem: Path, **kwargs: object
    ) -> int:
        if kwargs["partition_name"] == "vendor":
            assert kwargs["current_size"] == VENDOR_SIZE
            assert kwargs["maximum_size"] == VENDOR_SIZE
            return VENDOR_SIZE
        return int(kwargs["current_size"]) + 4096

    monkeypatch.setattr(
        command,
        "minimum_partition_size_for_descriptor",
        minimum_partition_size_for_descriptor,
    )

    def grow_partition(
        source: Path, _name: str, partition_size: int, destination: Path
    ) -> SimpleNamespace:
        destination.write_bytes(source.read_bytes() + f":grown:{partition_size}".encode())
        return SimpleNamespace(partition_size=partition_size, allocated_extents=(object(),))

    monkeypatch.setattr(command, "grow_partition", grow_partition)

    def seal(
        _avbtool: Path,
        filesystem: Path,
        output: Path,
        *,
        partition_size: int,
        stock_descriptor: dict[str, object],
        fec: Path,
    ) -> dict[str, object]:
        del filesystem, fec
        output.write_bytes(b"A" * partition_size)
        descriptor = dict(stock_descriptor)
        output_partition = output.stem.removesuffix("-sealed")
        if output_partition == "odm":
            descriptor = dict(SEALED_ODM_DESCRIPTOR)
        elif output_partition == "vendor":
            descriptor = dict(SEALED_VENDOR_DESCRIPTOR)
        return descriptor

    monkeypatch.setattr(command, "seal_system_ext", seal)

    def seal_odm(
        _avbtool: Path,
        filesystem: Path,
        output: Path,
        *,
        partition_name: str,
        partition_size: int,
        stock_descriptor: dict[str, object],
        fec: Path,
    ) -> dict[str, object]:
        assert partition_name in {"odm", "vendor"}
        assert stock_descriptor["fecRoots"] == 2
        assert fec.name == "fec"
        return seal(
            Path("/fixture/avbtool.py"),
            filesystem,
            output,
            partition_size=partition_size,
            stock_descriptor=stock_descriptor,
            fec=fec,
        )

    monkeypatch.setattr(command, "seal_partition", seal_odm)

    def replace_partition(source: Path, name: str, image: Path, destination: Path) -> None:
        if name == "vendor_a":
            assert image.stat().st_size == VENDOR_SIZE
        destination.write_bytes(source.read_bytes() + f":{name}:".encode() + image.read_bytes())

    monkeypatch.setattr(command, "replace_partition", replace_partition)

    def refresh_system_ext(
        _avbtool: Path, _stock: Path, _image: Path, _key: Path, output: Path
    ) -> dict[str, object]:
        output.write_bytes(b"refreshed system_ext vbmeta")
        previous_descriptor = dict(SYSTEM_EXT_DESCRIPTOR)
        if mismatch_stock_system_ext_descriptor:
            previous_descriptor["rootDigest"] = "different"
        return {
            "updatedDescriptor": "system_ext",
            "previousDescriptor": previous_descriptor,
        }

    monkeypatch.setattr(command, "refresh_system_ext_vbmeta", refresh_system_ext)

    def refresh_top_level(
        _avbtool: Path,
        stock: Path,
        image: Path,
        partition_name: str,
        _key: Path,
        output: Path,
        _work: Path,
    ) -> dict[str, object]:
        if partition_name == "odm":
            assert stock.name == "vbmeta-stock.img"
            assert image.name == "odm-sealed.img"
            previous = ODM_DESCRIPTOR
            descriptor = SEALED_ODM_DESCRIPTOR
        else:
            assert partition_name == "vendor"
            assert stock.name == "vbmeta-after-odm.img"
            assert image.name == "vendor-sealed.img"
            previous = VENDOR_DESCRIPTOR
            descriptor = SEALED_VENDOR_DESCRIPTOR
        if fail_on_top_level_vbmeta and partition_name == "vendor":
            raise command.ImageCompositionError("injected final vbmeta failure")
        output.write_bytes(f"refreshed top level vbmeta: {partition_name}".encode())
        return {"previousDescriptor": previous, "descriptor": descriptor}

    monkeypatch.setattr(command, "refresh_vbmeta_partition", refresh_top_level)

    real_subprocess_run = subprocess.run

    def fake_git(args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if args[0] != "git":
            return real_subprocess_run(args, **kwargs)  # type: ignore[arg-type]
        output = "a" * 40 + "\n" if args[-2:] == ["rev-parse", "HEAD:Guest"] else ""
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    monkeypatch.setattr(command.subprocess, "run", fake_git)
    return manifest_path, product_root, output_directory, document


def test_compose_image_records_hashed_outputs_and_source_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, document = _install_composer_fakes(monkeypatch, tmp_path)

    record = command.compose_image(manifest, output_directory=output, product_root=product)

    assert sorted(path.name for path in output.iterdir()) == sorted(command.OUTPUT_FILES)
    assert record["source"] == document["source"]
    assert record["sourceManifest"] == {
        "path": "Images/manifests/16373615/android-image.json",
        "sha256": _sha256(manifest),
    }
    product_files = [
        product / "compose.json",
        product / "payload/apkrun.bin",
        product / command.GUEST_AGENT_APK,
        *(product / relative for relative in command.PRODUCT_POLICY_INPUTS),
        *(product / relative for relative in command.PRODUCT_BUNDLE_INPUTS),
        product / command.MESA_PRODUCT_RELATIVE_PATH / "manifest.json",
        *(
            product / command.MESA_PRODUCT_RELATIVE_PATH / "vendor/lib64" / name
            for name in MESA_LIBRARIES
        ),
    ]
    assert record["productInputs"] == [
        {
            "path": f"Guest/product/{path.relative_to(product).as_posix()}",
            "sha256": _sha256(path),
        }
        for path in sorted(
            product_files, key=lambda item: item.relative_to(product).as_posix().encode()
        )
    ]
    assert "testOverlayInputs" not in record
    assert record["apkrunRevision"] == "a" * 40
    assert record["policy"] == {"cilInputs": 7, "fixture": True}
    assert record["vendor"]["stockEntriesReproduced"] == 21
    assert (
        record["vendor"]["mesa"]["commit"]
        == command.load_component(command.MESA_COMPONENT)["commit"]
    )
    assert len(record["vendor"]["injectedLibraries"]) == len(MESA_LIBRARIES)
    assert record["vendor"]["descriptor"] == SEALED_VENDOR_DESCRIPTOR
    assert record["vbmeta"] == {
        "systemExt": {
            "updatedDescriptor": "system_ext",
            "previousDescriptor": SYSTEM_EXT_DESCRIPTOR,
        },
        "topLevel": {
            "updates": [
                {
                    "updatedPartition": "odm",
                    "previousDescriptor": ODM_DESCRIPTOR,
                    "descriptor": SEALED_ODM_DESCRIPTOR,
                },
                {
                    "updatedPartition": "vendor",
                    "previousDescriptor": VENDOR_DESCRIPTOR,
                    "descriptor": SEALED_VENDOR_DESCRIPTOR,
                },
            ]
        },
    }
    assert record["growth"]["grownBytes"] == SYSTEM_EXT_SIZE + 4096
    assert record["odmGrowth"]["grownBytes"] == ODM_SIZE + 4096
    assert record["outputHashes"] == {
        filename: _sha256(output / filename)
        for filename in ("super.img", "vbmeta_system_a.img", "vbmeta_a.img")
    }
    persisted = json.loads((output / "composition.json").read_text(encoding="utf-8"))
    assert persisted == record


def test_repeated_compose_command_outputs_are_byte_identical(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, first_output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    _write_test_overlay(product.parents[1])
    second_output = first_output.with_name("composed-repeat")

    # The composer requires a case-sensitive output filesystem. This test exercises its command
    # path with synthetic filesystem outputs, so keep the host filesystem check out of scope.
    monkeypatch.setattr(command, "_filesystem_is_case_sensitive", lambda _directory: True)
    arguments = [
        "--manifest",
        str(manifest),
        "--product",
        str(product),
        "--test-overlay",
    ]
    assert command.main([*arguments, "--out", str(first_output)]) == 0
    assert command.main([*arguments, "--out", str(second_output)]) == 0

    def output_bytes(directory: Path) -> dict[str, bytes]:
        return {
            path.relative_to(directory).as_posix(): path.read_bytes()
            for path in directory.rglob("*")
            if path.is_file()
        }

    first = output_bytes(first_output)
    second = output_bytes(second_output)
    assert set(first) == set(second) == set(command.OUTPUT_FILES)
    assert first == second
    composition = json.loads(first["composition.json"])
    assert composition["testOverlayInputs"]
    assert set(composition["outputHashes"]) == {
        "super.img",
        "vbmeta_system_a.img",
        "vbmeta_a.img",
    }


def test_test_overlay_is_opt_in_and_hashes_only_fixed_fixture_inputs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    repository = product.parents[1]
    fixture_root, plan_path = _write_test_overlay(repository)
    source_path = fixture_root / "init/apkrun_test.rc"
    unreferenced_path = fixture_root / "unreferenced.txt"
    unreferenced_path.write_text("not a compose input\n", encoding="utf-8")
    observed: dict[str, object] = {}
    rebuild = command.rebuild_system_ext

    def capture_rebuild(
        tools: object,
        stock: Path,
        snapshot_product: Path,
        scratch: Path,
        *,
        image_uuid: str,
        replacements: dict[str, Path],
    ) -> object:
        placements = command.load_placements(snapshot_product / "compose.json", snapshot_product)
        observed["destinations"] = {placement.image_path for placement in placements}
        snapshotted_source = (
            snapshot_product / command.TEST_OVERLAY_RELATIVE_ROOT / "init/apkrun_test.rc"
        )
        observed["overlay_snapshot"] = snapshotted_source.read_bytes()
        observed["unreferenced_snapshot"] = (
            snapshot_product / command.TEST_OVERLAY_RELATIVE_ROOT / "unreferenced.txt"
        ).exists()
        return rebuild(
            tools,
            stock,
            snapshot_product,
            scratch,
            image_uuid=image_uuid,
            replacements=replacements,
        )

    monkeypatch.setattr(command, "rebuild_system_ext", capture_rebuild)

    record = command.compose_image(
        manifest,
        output_directory=output,
        product_root=product,
        test_overlay=True,
    )

    assert observed["destinations"] == {
        "/system_ext/bin/apkrun",
        command.GUEST_AGENT_IMAGE_PATH,
        "/system_ext/etc/init/apkrun_test.rc",
    }
    assert observed["overlay_snapshot"] == source_path.read_bytes()
    assert observed["unreferenced_snapshot"] is False
    assert record["testOverlayInputs"] == [
        {
            "path": f"{command.TEST_OVERLAY_RELATIVE_ROOT}/compose.json",
            "sha256": _sha256(plan_path),
        },
        {
            "path": f"{command.TEST_OVERLAY_RELATIVE_ROOT}/init/apkrun_test.rc",
            "sha256": _sha256(source_path),
        },
    ]
    assert all(item["path"].startswith("Guest/product/") for item in record["productInputs"])
    assert list(product.rglob("apkrun_test.rc")) == []
    persisted = json.loads((output / "composition.json").read_text(encoding="utf-8"))
    assert persisted["testOverlayInputs"] == record["testOverlayInputs"]


def test_test_overlay_rejects_duplicate_product_destination(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    repository = product.parents[1]
    _write_test_overlay(repository, destination="/system_ext/bin/apkrun")

    with pytest.raises(
        command.ImageCompositionError,
        match="test overlay cannot replace a product placement",
    ):
        command.compose_image(
            manifest,
            output_directory=output,
            product_root=product,
            test_overlay=True,
        )

    assert not output.exists()
    assert list(output.parent.iterdir()) == []


def test_test_overlay_cli_flag_has_no_user_supplied_path() -> None:
    arguments = command.build_parser().parse_args(
        ["--manifest", "manifest.json", "--out", "output", "--test-overlay"]
    )

    assert arguments.test_overlay is True
    with pytest.raises(SystemExit):
        command.build_parser().parse_args(
            [
                "--manifest",
                "manifest.json",
                "--out",
                "output",
                "--test-overlay",
                "/tmp/arbitrary-overlay",
            ]
        )


def test_compose_cli_rejects_case_insensitive_output_filesystem(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    output = tmp_path / "composed-image"
    monkeypatch.setattr(command, "_filesystem_is_case_sensitive", lambda _directory: False)

    result = command.main(["--manifest", "manifest.json", "--out", str(output)])

    assert result == 2
    assert "case-sensitive filesystem" in capsys.readouterr().err
    assert not output.exists()


def test_test_overlay_rejects_a_symlinked_fixture_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repository = tmp_path / "repository"
    outside = tmp_path / "outside"
    outside.mkdir()
    repository.mkdir()
    fixture_root = repository / command.TEST_OVERLAY_RELATIVE_ROOT
    fixture_root.parent.mkdir(parents=True)
    fixture_root.symlink_to(outside, target_is_directory=True)
    monkeypatch.setattr(command, "_repository_root", lambda: repository)

    with pytest.raises(command.ImageCompositionError, match="fixed test overlay root"):
        command._test_overlay_inputs(repository)


def test_test_overlay_rejects_a_symlinked_compose_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repository = tmp_path / "repository"
    fixture_root = repository / command.TEST_OVERLAY_RELATIVE_ROOT
    fixture_root.mkdir(parents=True)
    outside_plan = tmp_path / "compose.json"
    outside_plan.write_text('{"schemaVersion":1,"entries":[]}\n', encoding="utf-8")
    (fixture_root / "compose.json").symlink_to(outside_plan)
    monkeypatch.setattr(command, "_repository_root", lambda: repository)

    with pytest.raises(command.ImageCompositionError, match="must be a real file"):
        command._test_overlay_inputs(repository)


def test_test_overlay_rejects_symlinked_or_escaping_sources(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repository = tmp_path / "repository"
    fixture_root = repository / command.TEST_OVERLAY_RELATIVE_ROOT
    fixture_root.mkdir(parents=True)
    monkeypatch.setattr(command, "_repository_root", lambda: repository)
    source = fixture_root / "init/apkrun_test.rc"
    source.parent.mkdir()
    source.write_text("test\n", encoding="utf-8")
    (fixture_root / "init/symlink.rc").symlink_to(source)
    plan_path = fixture_root / "compose.json"

    def write_plan(source_name: str) -> None:
        plan_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "entries": [
                        {
                            "source": source_name,
                            "destination": "/system_ext/etc/init/apkrun_test.rc",
                            "kind": "regular file",
                            "mode": "0644",
                            "owner": {"uid": 0, "gid": 0},
                            "label": "u:object_r:system_file:s0",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    write_plan("init/symlink.rc")
    with pytest.raises(command.ImageCompositionError, match="must not be symlinks"):
        command._test_overlay_inputs(repository)

    write_plan("../outside.rc")
    with pytest.raises(command.ImageCompositionError, match="normalized relative path"):
        command._test_overlay_inputs(repository)


def test_compose_rejects_guest_agent_with_an_unpinned_signer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    android_home = Path(os.environ["ANDROID_HOME"])
    apksigner = android_home / "build-tools" / command.ANDROID_BUILD_TOOLS_VERSION / "apksigner"
    apksigner.write_text(
        "#!/usr/bin/env python3\nprint('Signer: certificate SHA-256 digest: " + "0" * 64 + "')\n",
        encoding="utf-8",
    )
    apksigner.chmod(0o755)

    with pytest.raises(
        command.ImageCompositionError, match="pinned AOSP test platform certificate"
    ):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()


def test_compose_rejects_agent_metadata_that_disagrees_with_the_apk(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    android_home = Path(os.environ["ANDROID_HOME"])
    aapt2 = android_home / "build-tools" / command.ANDROID_BUILD_TOOLS_VERSION / "aapt2"
    aapt2.write_text(
        "#!/usr/bin/env python3\n"
        "print(\"package: name='io.apkrun.guest' versionCode='2' versionName='test'\")\n",
        encoding="utf-8",
    )
    aapt2.chmod(0o755)

    with pytest.raises(command.ImageCompositionError, match="package/version"):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()


def test_compose_image_removes_staged_outputs_after_late_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(
        monkeypatch, tmp_path, fail_on_top_level_vbmeta=True
    )

    with pytest.raises(command.ImageCompositionError, match="injected final vbmeta failure"):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()
    assert list(output.parent.iterdir()) == []


def test_compose_image_removes_staging_after_keyboard_interrupt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)

    def interrupt_before_final_vbmeta(*_args: object, **_kwargs: object) -> dict[str, object]:
        raise KeyboardInterrupt

    monkeypatch.setattr(command, "refresh_vbmeta_partition", interrupt_before_final_vbmeta)

    with pytest.raises(KeyboardInterrupt):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()
    assert list(output.parent.iterdir()) == []


@pytest.mark.parametrize("existing_destination", ["directory", "symlink"])
def test_compose_does_not_replace_destination_created_during_composition(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    existing_destination: str,
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    publish = command._rename_directory_without_replacement
    preserved = tmp_path / "preserved"
    preserved.mkdir()
    marker = preserved / "created-during-composition"
    marker.write_text("preserve this output", encoding="utf-8")

    def publish_after_destination_is_created(source: Path, destination: Path) -> None:
        if existing_destination == "directory":
            destination.mkdir()
            destination_marker = destination / marker.name
            destination_marker.write_text(
                marker.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
        else:
            destination.symlink_to(preserved, target_is_directory=True)
        publish(source, destination)

    monkeypatch.setattr(
        command,
        "_rename_directory_without_replacement",
        publish_after_destination_is_created,
    )

    with pytest.raises(command.ImageCompositionError, match="output was created"):
        command.compose_image(manifest, output_directory=output, product_root=product)

    if existing_destination == "directory":
        assert output.is_dir()
        assert (output / marker.name).read_text(encoding="utf-8") == "preserve this output"
    else:
        assert output.is_symlink()
        assert output.resolve() == preserved
    assert marker.read_text(encoding="utf-8") == "preserve this output"
    assert not list(output.parent.glob(".apkrun-compose-*"))


def test_compose_rejects_mismatched_stock_system_ext_descriptors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(
        monkeypatch,
        tmp_path,
        mismatch_stock_system_ext_descriptor=True,
    )

    with pytest.raises(
        command.ImageCompositionError,
        match="stock system_ext_a footer and vbmeta_system_a descriptor disagree",
    ):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()


def test_compose_rejects_mismatched_stock_vendor_descriptors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(
        monkeypatch,
        tmp_path,
        mismatch_stock_vendor_descriptor=True,
    )

    with pytest.raises(
        command.ImageCompositionError,
        match="stock vendor_a footer and vbmeta_a descriptor disagree",
    ):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()


def test_compose_rejects_missing_staged_mesa_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, product, output, _document = _install_composer_fakes(monkeypatch, tmp_path)
    (product / command.MESA_PRODUCT_RELATIVE_PATH / "manifest.json").unlink()

    with pytest.raises(command.ImageCompositionError, match="invalid staged Mesa product"):
        command.compose_image(manifest, output_directory=output, product_root=product)

    assert not output.exists()


def test_snapshot_product_inputs_rejects_content_changed_after_hashing(tmp_path: Path) -> None:
    product = tmp_path / "Guest/product"
    (product / "payload").mkdir(parents=True)
    source = product / "payload/apkrun.bin"
    source.write_bytes(b"verified before snapshot")
    inputs = [{"path": "Guest/product/payload/apkrun.bin", "sha256": _sha256(source)}]
    source.write_bytes(b"changed after verification")

    with pytest.raises(
        command.ImageCompositionError,
        match="changed while composition inputs were being snapshotted",
    ):
        command._snapshot_product_inputs(product, inputs, tmp_path / "snapshot")


def test_composer_requires_the_checked_in_manifest_and_inventory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repository = tmp_path / "repository"
    manifest = repository / "Images/manifests/16373615/android-image.json"
    inventory = repository / "Images/manifests/16373615/inventory.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text("{}\n", encoding="utf-8")
    inventory.write_text("{}\n", encoding="utf-8")
    monkeypatch.setattr(command, "_repository_root", lambda: repository)

    alternate_manifest = tmp_path / "alternate-manifest.json"
    alternate_manifest.write_text("{}\n", encoding="utf-8")
    with pytest.raises(
        command.ImageCompositionError,
        match="checked-in build 16373615 Android image manifest",
    ):
        command._validate_inputs(alternate_manifest, None, None)

    alternate_inventory = tmp_path / "alternate-inventory.json"
    alternate_inventory.write_text("{}\n", encoding="utf-8")
    monkeypatch.setattr(command, "_load_json", lambda *_args, **_kwargs: {})
    monkeypatch.setattr(command, "_resolve_archive_root", lambda *_args, **_kwargs: tmp_path)
    with pytest.raises(
        command.ImageCompositionError,
        match="checked-in build 16373615 image inventory",
    ):
        command._validate_inputs(manifest, None, alternate_inventory)


def test_odm_policy_rebuild_uses_partition_root_paths(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    stock_tree = tmp_path / "odm-stock-tree"
    modified_tree = tmp_path / "odm-policy-tree"
    stock_tree.mkdir()
    (modified_tree / "etc/selinux").mkdir(parents=True)
    paths = (
        "/etc/selinux/precompiled_sepolicy",
        "/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256",
        "/etc/selinux/precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256",
    )
    entries: dict[str, Entry] = {}
    members: list[TarMember] = []
    for index, path in enumerate(paths):
        stock_file = stock_tree / path.lstrip("/")
        stock_file.parent.mkdir(parents=True, exist_ok=True)
        stock_file.write_text(f"stock {index}\n", encoding="utf-8")
        (modified_tree / path.lstrip("/")).write_text(f"generated {index}\n", encoding="utf-8")
        entries[path] = Entry(
            path=path,
            kind=REGULAR_FILE,
            mode=0o644,
            uid=0,
            gid=0,
            size=stock_file.stat().st_size,
            mtime="2026-01-01 00:00:00",
            sha256=command.sha256_file(stock_file),
        )
        members.append(
            TarMember(
                path=path,
                kind=REGULAR_FILE,
                mode=0o644,
                uid=0,
                gid=0,
                mtime=0,
                source=stock_file,
            )
        )

    monkeypatch.setattr(command, "read_tree", lambda *_args: entries)
    monkeypatch.setattr(command, "tree_members", lambda *_args: members)
    monkeypatch.setattr(command, "export_tree", lambda _tools, _image, tree: tree.mkdir())
    monkeypatch.setattr(command, "_entry_differences", lambda *_args, **_kwargs: [])
    rebuilt_members: list[TarMember] = []

    def build_ero(
        _tools: object, image_members: list[TarMember], scratch: Path, name: str, _uuid: str
    ) -> Path:
        if name == "odm-composed":
            rebuilt_members.extend(image_members)
        image = scratch / f"{name}.erofs"
        image.write_bytes(b"fixture")
        return image

    monkeypatch.setattr(command, "_build_ero", build_ero)

    image, record = command._rebuild_odm_policy(
        SimpleNamespace(),
        tmp_path / "odm-stock.erofs",
        stock_tree,
        modified_tree,
        tmp_path,
        image_uuid="d77cf8a1-8bdb-49d9-98ab-c9b719b4ab6b",
    )

    assert image.is_file()
    assert record["replacedEntries"] == len(paths)
    assert {member.path: member.source for member in rebuilt_members} == {
        path: modified_tree / path.lstrip("/") for path in paths
    }
