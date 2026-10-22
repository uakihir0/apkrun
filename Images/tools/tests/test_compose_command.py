"""T0 orchestration tests for complete Android image composition (#36)."""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest

from apkrun_image import compose_command as command

SYSTEM_EXT_SIZE = 8192
ODM_SIZE = 8192
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


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _install_composer_fakes(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    *,
    fail_on_top_level_vbmeta: bool = False,
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
            }
        ],
    }
    (product_root / "compose.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    for relative in command.PRODUCT_POLICY_INPUTS:
        path = product_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"fixture: {relative}\n", encoding="utf-8")

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
    monkeypatch.setattr(command, "load_component", lambda _component: Path("/fixture/avbtool.py"))
    monkeypatch.setattr(command, "verify_avbtool", lambda *_args: Path("/fixture/avbtool.py"))

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
            SimpleNamespace(name="vendor_a", size=8192, group=ODM_GROUP),
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
    monkeypatch.setattr(command, "export_tree", lambda _tools, _image, tree: tree.mkdir())
    monkeypatch.setattr(
        command,
        "_verify_product_labels",
        lambda *_args: {"rules": 2, "placements": 1},
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
    monkeypatch.setattr(
        command,
        "_partition_tree",
        lambda _info, _partition, _description: dict(ODM_DESCRIPTOR),
    )

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
    monkeypatch.setattr(
        command,
        "minimum_partition_size_for_descriptor",
        lambda _avbtool, _filesystem, **kwargs: kwargs["current_size"] + 4096,
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
        return dict(stock_descriptor)

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
        assert partition_name == "odm"
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
        destination.write_bytes(source.read_bytes() + f":{name}:".encode() + image.read_bytes())

    monkeypatch.setattr(command, "replace_partition", replace_partition)

    def refresh_system_ext(
        _avbtool: Path, _stock: Path, _image: Path, _key: Path, output: Path
    ) -> dict[str, object]:
        output.write_bytes(b"refreshed system_ext vbmeta")
        return {"updatedDescriptor": "system_ext"}

    monkeypatch.setattr(command, "refresh_system_ext_vbmeta", refresh_system_ext)

    def refresh_top_level(
        _avbtool: Path,
        _stock: Path,
        _image: Path,
        partition_name: str,
        _key: Path,
        output: Path,
        _work: Path,
    ) -> dict[str, object]:
        assert partition_name == "odm"
        if fail_on_top_level_vbmeta:
            raise command.ImageCompositionError("injected final vbmeta failure")
        output.write_bytes(b"refreshed top level vbmeta")
        return {"updatedDescriptor": "odm"}

    monkeypatch.setattr(command, "refresh_vbmeta_partition", refresh_top_level)

    def fake_git(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        output = "a" * 40 + "\n" if args[-2:] == ["rev-parse", "HEAD:Guest"] else ""
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    monkeypatch.setattr(command, "subprocess", SimpleNamespace(run=fake_git))
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
        *(product / relative for relative in command.PRODUCT_POLICY_INPUTS),
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
    assert record["apkrunRevision"] == "a" * 40
    assert record["policy"] == {"cilInputs": 7, "fixture": True}
    assert record["vbmeta"] == {
        "systemExt": {"updatedDescriptor": "system_ext"},
        "topLevel": {"updatedPartition": "odm", "updatedDescriptor": "odm"},
    }
    assert record["growth"]["grownBytes"] == SYSTEM_EXT_SIZE + 4096
    assert record["odmGrowth"]["grownBytes"] == ODM_SIZE + 4096
    assert record["outputHashes"] == {
        filename: _sha256(output / filename)
        for filename in ("super.img", "vbmeta_system_a.img", "vbmeta_a.img")
    }
    persisted = json.loads((output / "composition.json").read_text(encoding="utf-8"))
    assert persisted == record


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
