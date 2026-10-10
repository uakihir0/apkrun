#!/usr/bin/env python3
"""T0 tests for the virgl inputs and the manifest of the Linux test initramfs (#022)."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY_ROOT / "scripts" / "tools" / "initramfs-manifest.py"
LOCK = REPOSITORY_ROOT / "ThirdParty" / "ThirdParty.lock.json"
LICENSES = REPOSITORY_ROOT / "ThirdParty" / "licenses"
PACKAGES_LIST = REPOSITORY_ROOT / "Tests" / "Fixtures" / "linux" / "virgl-packages.list"
PATHS_LIST = REPOSITORY_ROOT / "Tests" / "Fixtures" / "linux" / "virgl-paths.list"
FETCH = REPOSITORY_ROOT / "scripts" / "fetch-test-linux.sh"
BUILD = REPOSITORY_ROOT / "scripts" / "build-test-initramfs.sh"

PT_LOAD = 1
PT_DYNAMIC = 2
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10


def load_tool() -> ModuleType:
    spec = importlib.util.spec_from_file_location("initramfs_manifest", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MANIFEST = load_tool()


def make_elf(needed: list[str]) -> bytes:
    """A minimal little-endian ELF64 shared object whose DT_NEEDED entries are `needed`."""
    strtab = b"\0"
    offsets = []
    for name in needed:
        offsets.append(len(strtab))
        strtab += name.encode("ascii") + b"\0"
    entry_count = len(needed) + 3  # DT_NEEDED..., DT_STRTAB, DT_STRSZ, DT_NULL
    dynamic_offset = 64 + 2 * 56
    dynamic_size = 16 * entry_count
    strtab_offset = dynamic_offset + dynamic_size
    total = strtab_offset + len(strtab)
    entries = [(DT_NEEDED, value) for value in offsets]
    entries += [(DT_STRTAB, strtab_offset), (DT_STRSZ, len(strtab)), (DT_NULL, 0)]
    header = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    header += struct.pack(
        "<HHIQQQIHHHHHH", 3, 183, 1, 0, 64, 0, 0, 64, 56, 2, 64, 0, 0
    )
    program_headers = struct.pack("<IIQQQQQQ", PT_LOAD, 6, 0, 0, 0, total, total, 0x1000)
    program_headers += struct.pack(
        "<IIQQQQQQ", PT_DYNAMIC, 6, dynamic_offset, dynamic_offset, dynamic_offset,
        dynamic_size, dynamic_size, 8,
    )
    dynamic = b"".join(struct.pack("<qQ", tag, value) for tag, value in entries)
    return header + program_headers + dynamic + strtab


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class InitramfsFixture(unittest.TestCase):
    """A synthetic package set, lock, and initramfs root in a temporary directory."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "root"
        self.downloads = self.base / "downloads"
        self.root.mkdir()
        self.downloads.mkdir()
        self.components: list[dict] = []
        self.cpio = self.base / "initramfs.cpio.gz"
        self.cpio.write_bytes(b"synthetic archive")
        self.packages_list = self.base / "packages.list"
        self.paths_list = self.base / "paths.list"
        self.lock = self.base / "lock.json"
        self.output = self.base / "manifest.json"

    def add_package(self, name: str, members: dict[str, bytes], links: dict[str, str] | None = None) -> None:
        version = "1.0-r0"
        file_name = f"{name}-{version}.apk"
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            info = tarfile.TarInfo(".PKGINFO")
            info.size = 0
            archive.addfile(info, io.BytesIO(b""))
            for path, data in members.items():
                info = tarfile.TarInfo(path)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                target = self.root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            for path, target_name in (links or {}).items():
                info = tarfile.TarInfo(path)
                info.type = tarfile.SYMTYPE
                info.linkname = target_name
                archive.addfile(info)
                link = self.root / path
                link.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(target_name, link)
        apk_bytes = buffer.getvalue()
        (self.downloads / file_name).write_bytes(apk_bytes)
        self.components.append(
            {
                "name": f"alpine-{name}",
                "group": "test-linux",
                "kind": "prebuilt",
                "url": f"https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/{file_name}",
                "version": version,
                "sha256": sha256(apk_bytes),
                "license": "MIT",
                "licenseFiles": ["COPYING"],
                "buildFlags": [],
                "patches": [],
                "ships": "tooling",
            }
        )

    def write_inputs(self, package_names: list[str], path_list: list[str]) -> None:
        self.lock.write_text(json.dumps({"schemaVersion": 1, "components": self.components}), encoding="utf-8")
        self.packages_list.write_text("\n".join(package_names) + "\n", encoding="utf-8")
        self.paths_list.write_text("\n".join(path_list) + "\n", encoding="utf-8")

    def run_tool(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(TOOL),
                "--root", str(self.root),
                "--lock", str(self.lock),
                "--packages", str(self.packages_list),
                "--paths", str(self.paths_list),
                "--downloads", str(self.downloads),
                "--cpio", str(self.cpio),
                "--output", str(self.output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )


class TestVirglInputs(unittest.TestCase):
    """The committed inputs: the lock, the package list, and the path list."""

    def setUp(self) -> None:
        self.lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.components = {component["name"]: component for component in self.lock["components"]}
        self.packages = [
            line.strip()
            for line in PACKAGES_LIST.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")
        ]

    def test_every_virgl_package_is_a_pinned_alpine_component(self) -> None:
        self.assertGreater(len(self.packages), 0)
        self.assertEqual(len(set(self.packages)), len(self.packages))
        for name in self.packages:
            with self.subTest(package=name):
                component = self.components.get(name)
                self.assertIsNotNone(component, "missing from the lock")
                self.assertEqual(component["group"], "test-linux")
                self.assertEqual(component["kind"], "prebuilt")
                self.assertEqual(component["ships"], "tooling")
                url = component["url"]
                self.assertTrue(
                    url.startswith("https://dl-cdn.alpinelinux.org/alpine/v3.23/"),
                    url,
                )
                self.assertTrue(url.endswith(f"-{component['version']}.apk"), url)
                self.assertRegex(component["sha256"], r"^[0-9a-f]{64}$")
                for license_file in component["licenseFiles"]:
                    self.assertTrue(
                        (LICENSES / name / license_file).is_file(),
                        f"license text is missing: {name}/{license_file}",
                    )

    def test_the_closure_names_the_packages_that_the_virgl_check_uses(self) -> None:
        for name in (
            "alpine-kmscube",
            "alpine-mesa-egl",
            "alpine-mesa-gbm",
            "alpine-mesa-gles",
            "alpine-mesa-dri-gallium",
            "alpine-mesa",
            "alpine-libdrm",
            "alpine-llvm21-libs",
        ):
            with self.subTest(package=name):
                self.assertIn(name, self.packages)

    def test_required_paths_are_relative_and_inside_the_root(self) -> None:
        paths = [
            line.strip()
            for line in PATHS_LIST.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")
        ]
        self.assertIn("usr/bin/kmscube", paths)
        self.assertIn("usr/lib/dri/virtio_gpu_dri.so", paths)
        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(path.startswith("/"))
                self.assertNotIn("..", path.split("/"))
                self.assertTrue(path.startswith("usr/"))

    def test_fetch_and_build_read_the_same_package_list(self) -> None:
        for script in (FETCH, BUILD):
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8")
                self.assertIn("Tests/Fixtures/linux/virgl-packages.list", text)
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn("tools/initramfs-manifest.py", build)
        self.assertIn("Tests/Fixtures/linux/virgl-paths.list", build)


class TestManifestTool(InitramfsFixture):
    def test_writes_a_manifest_for_a_complete_root(self) -> None:
        self.add_package(
            "fake-one",
            {
                "usr/bin/fake": make_elf(["libfake.so.1"]),
                "usr/lib/libfake.so.1": make_elf([]),
            },
            links={"usr/lib/dri/fake_dri.so": "../libfake.so.1"},
        )
        self.write_inputs(["alpine-fake-one"], ["usr/bin/fake", "usr/lib/dri/fake_dri.so"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["initramfs"]["sha256"], sha256(b"synthetic archive"))
        self.assertEqual(manifest["packages"][0]["name"], "alpine-fake-one")
        self.assertEqual(manifest["neededLibraries"], ["libfake.so.1"])
        link = manifest["requiredPaths"][1]
        self.assertEqual(link["path"], "usr/lib/dri/fake_dri.so")
        self.assertEqual(link["resolvedPath"], "usr/lib/libfake.so.1")
        self.assertEqual(link["sha256"], sha256(make_elf([])))

    def test_rejects_a_required_path_that_is_missing(self) -> None:
        self.add_package("fake-one", {"usr/bin/fake": make_elf([])})
        self.write_inputs(["alpine-fake-one"], ["usr/bin/fake", "usr/lib/missing.so"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("usr/lib/missing.so", result.stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_a_needed_soname_that_the_root_does_not_provide(self) -> None:
        self.add_package("fake-one", {"usr/bin/fake": make_elf(["libabsent.so.9"])})
        self.write_inputs(["alpine-fake-one"], ["usr/bin/fake"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("libabsent.so.9", result.stderr)
        self.assertIn("usr/bin/fake", result.stderr)

    def test_rejects_a_symlink_with_an_absolute_target(self) -> None:
        self.add_package("fake-one", {"usr/bin/fake": make_elf([])}, links={"usr/lib/escape.so": "/etc/passwd"})
        self.write_inputs(["alpine-fake-one"], ["usr/lib/escape.so"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("absolute symlink", result.stderr)

    def test_rejects_a_relative_symlink_that_leaves_the_root(self) -> None:
        self.add_package(
            "fake-one",
            {"usr/bin/fake": make_elf([])},
            links={"usr/lib/escape.so": "../../../../../etc/passwd"},
        )
        self.write_inputs(["alpine-fake-one"], ["usr/lib/escape.so"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("leaves the root", result.stderr)

    def test_rejects_a_package_whose_apk_differs_from_the_lock(self) -> None:
        self.add_package("fake-one", {"usr/bin/fake": make_elf([])})
        self.components[0]["sha256"] = "0" * 64
        self.write_inputs(["alpine-fake-one"], ["usr/bin/fake"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("SHA-256 mismatch for alpine-fake-one", result.stderr)

    def test_rejects_a_package_that_is_not_in_the_lock(self) -> None:
        self.add_package("fake-one", {"usr/bin/fake": make_elf([])})
        self.write_inputs(["alpine-absent"], ["usr/bin/fake"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("not in the lock: alpine-absent", result.stderr)

    def test_a_dangling_symlink_does_not_provide_a_needed_soname(self) -> None:
        self.add_package(
            "fake-one",
            {"usr/bin/fake": make_elf(["libghost.so.1"])},
            links={"usr/lib/libghost.so.1": "libmissing.so.1"},
        )
        self.write_inputs(["alpine-fake-one"], ["usr/bin/fake"])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("libghost.so.1", result.stderr)

    def test_checks_a_member_whose_name_starts_with_dot_slash(self) -> None:
        self.add_package("fake-one", {"./usr/bin/fake": make_elf(["libmissing.so.9"])})
        self.write_inputs(["alpine-fake-one"], [])

        result = self.run_tool()

        self.assertEqual(result.returncode, 1)
        self.assertIn("libmissing.so.9", result.stderr)

    def test_reads_every_needed_name_of_an_elf_file(self) -> None:
        path = self.base / "lib.so"
        path.write_bytes(make_elf(["liba.so.1", "libb.so.2"]))
        self.assertEqual(MANIFEST.read_needed(path), ["liba.so.1", "libb.so.2"])
        text = self.base / "text.txt"
        text.write_text("not an ELF file\n", encoding="utf-8")
        self.assertEqual(MANIFEST.read_needed(text), [])


if __name__ == "__main__":
    unittest.main()
