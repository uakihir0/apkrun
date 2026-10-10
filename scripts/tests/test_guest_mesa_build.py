#!/usr/bin/env python3
"""Checks for the guest Mesa build (ADR-0018, #099).

Without arguments, these are T0 checks that need no NDK and no VM: the lock pins, the parsers of the
llvm-readelf and llvm-nm output, and the verifier, which runs against fake ELF tools. With
`--out DIR`, they also check a built output (manifest, file hashes, ELF properties, exports) with the
NDK's llvm-readelf and llvm-nm. Nothing here boots a guest.

  python3 scripts/tests/test_guest_mesa_build.py
  python3 scripts/tests/test_guest_mesa_build.py --out ThirdParty/out/mesa-android [--ndk DIR]
"""

import json
import os
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "guest"))

import mesa_android as mesa  # noqa: E402

LOCK = REPO_ROOT / "ThirdParty" / "ThirdParty.lock.json"
LICENSES = REPO_ROOT / "ThirdParty" / "licenses"
GUEST_MESA_NAMES = {"mesa", "libdrm", "ninja", "bison", "meson", "mako", "markupsafe", "packaging", "ndk"}

# Output of llvm-readelf for a real shipped library (abridged), in the form the parsers read.
READELF_HEADER = """ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Type:                              DYN (Shared object file)
  Machine:                           AArch64
"""
READELF_DYNAMIC = """Dynamic section at offset 0x3f0a0 contains 30 entries:
  Tag        Type                     Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libgallium_dri.so]
 0x0000000000000001 (NEEDED)             Shared library: [libdrm.so]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so]
 0x000000000000000e (SONAME)             Library soname: [libEGL_mesa.so]
"""
READELF_LOAD = """Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x0a1b0 0x0a1b0 R   0x4000
  LOAD           0x00b000 0x000000000000b000 0x000000000000b000 0x15000 0x15000 R E 0x4000
"""
NM_DEFINED = """000000000002e260 T eglCreateContext
000000000002cb30 T eglInitialize
0000000000001000 W weak_symbol
000000000002c9b8 t local_text
"""


def lock_document():
    with open(LOCK, encoding="utf-8") as handle:
        return json.load(handle)


class GuestMesaLockTests(unittest.TestCase):
    def test_mesa_is_pinned_by_commit_and_version(self):
        mesa_entry = mesa.lock_component(lock_document(), "mesa")
        self.assertRegex(mesa_entry["commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(mesa_entry["commit"], "0fadfea4f394211946f308458f614839ef253ee8")
        self.assertEqual(mesa_entry["version"], "26.1.8")
        self.assertTrue(mesa_entry["repository"].startswith("https://"))
        self.assertEqual(mesa_entry["ships"], "image")

    def test_mesa_flags_follow_adr_0018(self):
        flags = set(mesa.lock_component(lock_document(), "mesa")["buildFlags"])
        for required in ("-Dplatforms=android", "-Dandroid-stub=true", "-Degl=enabled", "-Dgallium-drivers=virgl",
                         "-Dgles1=enabled", "-Dgles2=enabled", "-Dplatform-sdk-version=37",
                         "-Dzstd=disabled", "-Dxmlconfig=disabled", "--prefix=/vendor", "--libdir=lib64",
                         "--wrap-mode=nodownload"):
            self.assertIn(required, flags)
        self.assertNotIn("-Dvulkan-drivers=freedreno", flags)
        self.assertFalse(any(f.startswith("-Dvulkan-drivers=") and f != "-Dvulkan-drivers=" for f in flags))

    def test_guest_mesa_group_is_complete(self):
        self.assertEqual(set(mesa.lock_group_names(lock_document())), GUEST_MESA_NAMES)

    def test_guest_mesa_entries_are_pinned_and_licensed(self):
        for entry in lock_document()["components"]:
            if entry.get("group") != mesa.LOCK_GROUP:
                continue
            with self.subTest(component=entry["name"]):
                if entry["kind"] == "prebuilt":
                    self.assertTrue(entry["url"].startswith("https://"))
                    self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
                else:
                    self.assertRegex(entry["commit"], r"^[0-9a-f]{40}$")
                for license_file in entry["licenseFiles"]:
                    self.assertTrue((LICENSES / entry["name"] / license_file).is_file(), license_file)

    def test_python_tools_are_hash_pinned(self):
        lines = mesa.pip_requirements(lock_document()).splitlines()
        self.assertEqual(len(lines), len(mesa.PYTHON_TOOLS))
        for line in lines:
            self.assertRegex(line, r"^https://files\.pythonhosted\.org/\S+ --hash=sha256:[0-9a-f]{64}$")

    def test_mesa_licence_expression_names_the_terms_found(self):
        license_text = mesa.lock_component(lock_document(), "mesa")["license"]
        for term in ("MIT", "BSD-2-Clause", "BSD-3-Clause", "BSL-1.0", "HPND",
                     "GPL-3.0-or-later WITH Bison-exception-2.2"):
            self.assertIn(term, license_text)


class GuestMesaParserTests(unittest.TestCase):
    def test_header(self):
        self.assertEqual(mesa.parse_header(READELF_HEADER), {"class": "ELF64", "machine": "AArch64"})

    def test_dynamic_needed_soname_runpath(self):
        dynamic = mesa.parse_dynamic(READELF_DYNAMIC)
        self.assertEqual(dynamic["needed"], ["libgallium_dri.so", "libdrm.so", "libc.so"])
        self.assertEqual(dynamic["soname"], "libEGL_mesa.so")
        self.assertEqual(dynamic["runpath"], [])
        runpath = mesa.parse_dynamic(" 0x000000000000001d (RUNPATH)  Library runpath: [$ORIGIN/../x:/y]\n")
        self.assertEqual(runpath["runpath"], ["$ORIGIN/../x:/y"])

    def test_load_alignments(self):
        self.assertEqual(mesa.parse_load_alignments(READELF_LOAD), [0x4000, 0x4000])

    def test_defined_functions_skip_weak_and_local(self):
        self.assertEqual(mesa.parse_defined_functions(NM_DEFINED), {"eglCreateContext", "eglInitialize"})


class FakeToolchain:
    """Stand-ins for llvm-readelf and llvm-nm. Each reads canned text for the library's basename."""

    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.specs = self.root / "specs"
        self.specs.mkdir()
        self.readelf = self.root / "fake-readelf"
        self.nm = self.root / "fake-nm"
        self.readelf.write_text(
            '#!/bin/sh\nmode="${1#-}"\nfile="$2"\nexec cat "$FAKE_SPECS/$(basename "$file").$mode"\n')
        self.nm.write_text(
            '#!/bin/sh\ncase "$2" in --defined-only) kind=defined;; *) kind=undefined;; esac\n'
            'file="$3"\nexec cat "$FAKE_SPECS/$(basename "$file").nm.$kind"\n')
        for path in (self.readelf, self.nm):
            path.chmod(0o755)
        os.environ["FAKE_SPECS"] = str(self.specs)

    def set_spec(self, library, mode, text):
        (self.specs / f"{library}.{mode}").write_text(text)

    def set_default(self, library, needed, soname, runpath=(), align=0x4000, machine="AArch64",
                    defined=(), undefined=()):
        header = READELF_HEADER.replace("AArch64", machine)
        dynamic = "".join(f" 0x1 (NEEDED) Shared library: [{n}]\n" for n in needed)
        if soname:
            dynamic += f" 0xe (SONAME) Library soname: [{soname}]\n"
        for path in runpath:
            dynamic += f" 0x1d (RUNPATH) Library runpath: [{path}]\n"
        load = f"  LOAD 0x0 0x0 0x0 0x1 0x1 R {hex(align)}\n"
        self.set_spec(library, "h", header)
        self.set_spec(library, "d", dynamic)
        self.set_spec(library, "l", load)
        self.set_spec(library, "nm.defined", "".join(f"0000000000001000 T {s}\n" for s in defined))
        self.set_spec(library, "nm.undefined", "".join(f"                 U {s}\n" for s in undefined))


def write_output(root, toolchain, lock_path):
    """Create a fake output with the four shipped libraries and a manifest for it."""
    out = pathlib.Path(root) / "out"
    lib = out / mesa.LIB_DIR
    lib.mkdir(parents=True)
    contract = list(mesa.GUEST_SYMBOL_CONTRACT)
    for name, spec in mesa.SHIPPED.items():
        (lib / name).write_bytes(("fake " + name).encode())
        toolchain.set_default(name, sorted(spec["needed"]), name, defined=sorted(spec["exports"]),
                              undefined=contract)
    tools = {"ndk": "28.2.13676358 (r28c)"}
    mesa.write_manifest(out, lock_path, str(toolchain.readelf), str(toolchain.nm), tools)
    return out


class GuestMesaVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.toolchain = FakeToolchain(self.temporary.name)
        self.out = write_output(self.temporary.name, self.toolchain, LOCK)

    def verify(self):
        return mesa.verify(self.out, LOCK, str(self.toolchain.readelf), str(self.toolchain.nm))

    def manifest_path(self):
        return self.out / "manifest.json"

    def test_clean_output_passes(self):
        self.assertEqual(self.verify(), [])

    def test_changed_bytes_fail_the_hash(self):
        (self.out / mesa.LIB_DIR / "libEGL_mesa.so").write_bytes(b"tampered")
        self.assertTrue(any("SHA-256" in f or "size" in f for f in self.verify()))

    def test_runpath_from_the_build_tree_fails(self):
        self.toolchain.set_default("libEGL_mesa.so", sorted(mesa.SHIPPED["libEGL_mesa.so"]["needed"]),
                                   "libEGL_mesa.so", runpath=["$ORIGIN/../android_stub"],
                                   defined=sorted(mesa.SHIPPED["libEGL_mesa.so"]["exports"]))
        self.assertTrue(any("RUNPATH" in f for f in self.verify()))

    def test_libcxx_shared_is_not_allowed(self):
        needed = sorted(mesa.SHIPPED["libgallium_dri.so"]["needed"]) + ["libc++_shared.so"]
        self.toolchain.set_default("libgallium_dri.so", needed, "libgallium_dri.so")
        self.assertTrue(any("libc++_shared.so" in f for f in self.verify()))

    def test_small_load_alignment_fails(self):
        self.toolchain.set_default("libGLESv2_mesa.so", ["libgallium_dri.so", "libc.so"], "libGLESv2_mesa.so",
                                   align=0x1000)
        self.assertTrue(any("alignment" in f for f in self.verify()))

    def test_x86_machine_fails(self):
        self.toolchain.set_default("libGLESv1_CM_mesa.so", ["libgallium_dri.so", "libc.so"],
                                   "libGLESv1_CM_mesa.so", machine="Advanced Micro Devices X86-64")
        self.assertTrue(any("machine" in f for f in self.verify()))

    def test_missing_egl_export_fails(self):
        exports = sorted(mesa.SHIPPED["libEGL_mesa.so"]["exports"] - {"eglInitialize"})
        self.toolchain.set_default("libEGL_mesa.so", sorted(mesa.SHIPPED["libEGL_mesa.so"]["needed"]),
                                   "libEGL_mesa.so", defined=exports)
        self.assertTrue(any("eglInitialize" in f for f in self.verify()))

    def test_missing_contract_symbol_fails(self):
        contract = [s for s in mesa.GUEST_SYMBOL_CONTRACT if s != "drmGetDevices2"]
        for name in mesa.SHIPPED:
            self.toolchain.set_spec(name, "nm.undefined", "".join(f"                 U {s}\n" for s in contract))
        self.assertTrue(any("drmGetDevices2" in f for f in self.verify()))

    def test_manifest_from_another_lock_fails(self):
        data = json.loads(self.manifest_path().read_text())
        data["lock"]["sha256"] = "0" * 64
        self.manifest_path().write_text(json.dumps(data))
        self.assertTrue(any("current lock" in f for f in self.verify()))

    def test_manifest_flags_must_match_the_lock(self):
        data = json.loads(self.manifest_path().read_text())
        data["buildFlags"] = data["buildFlags"][:-1]
        self.manifest_path().write_text(json.dumps(data))
        self.assertTrue(any("buildFlags" in f for f in self.verify()))

    def test_manifest_ndk_revision_must_be_r28c(self):
        data = json.loads(self.manifest_path().read_text())
        data["tools"]["ndk"] = "27.0.12077973 (r27b)"
        self.manifest_path().write_text(json.dumps(data))
        self.assertTrue(any("NDK revision" in f for f in self.verify()))

    def test_missing_manifest_fails(self):
        self.manifest_path().unlink()
        self.assertEqual(len(self.verify()), 1)


class GuestMesaOutputTests(unittest.TestCase):
    """Checks on a built output. The class is run only with --out."""

    out = None
    readelf = None
    nm = None

    def test_output_holds_exactly_the_shipped_files(self):
        found = sorted(str(p.relative_to(self.out)) for p in self.out.rglob("*") if p.is_file())
        expected = sorted(["manifest.json"] + [f"{mesa.LIB_DIR}/{name}" for name in mesa.SHIPPED])
        self.assertEqual(found, expected)

    def test_verify_passes_on_the_output(self):
        self.assertEqual(mesa.verify(self.out, LOCK, self.readelf, self.nm), [])

    def test_each_library_is_aarch64_elf_with_16k_alignment(self):
        for name in mesa.SHIPPED:
            with self.subTest(library=name):
                record = mesa.elf_record(self.out / mesa.LIB_DIR / name, self.readelf, self.nm)
                self.assertEqual(record["class"], "ELF64")
                self.assertIn(record["machine"], ("AArch64", "EM_AARCH64"))
                self.assertEqual(record["loadAlign"], 0x4000)
                self.assertEqual(record["runpath"], [])

    def test_needed_entries_are_within_the_allowed_set(self):
        for name, spec in mesa.SHIPPED.items():
            with self.subTest(library=name):
                record = mesa.elf_record(self.out / mesa.LIB_DIR / name, self.readelf, self.nm)
                self.assertLessEqual(set(record["needed"]), spec["needed"])

    def test_egl_and_gles_exports_are_present(self):
        for name, spec in mesa.SHIPPED.items():
            if not spec["exports"]:
                continue
            with self.subTest(library=name):
                defined = mesa.parse_defined_functions(mesa.run_tool(self.nm, ["-D", "--defined-only",
                                                                              str(self.out / mesa.LIB_DIR / name)]))
                self.assertLessEqual(spec["exports"], defined)

    def test_manifest_records_the_ndk_and_the_tools(self):
        data = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(data["schemaVersion"], mesa.SCHEMA_VERSION)
        self.assertEqual(data["component"], mesa.COMPONENT)
        self.assertTrue(data["tools"]["ndk"].startswith("28.2.13676358"))
        for key in ("meson", "ninja", "bison", "flex", "m4", "python", "pyyaml", "libdrm"):
            self.assertIn(key, data["tools"])


def find_ndk_tools(ndk_arg):
    candidates = [ndk_arg] if ndk_arg else [
        str(REPO_ROOT / "build" / "android-sdk" / "ndk" / "28.2.13676358"),
        os.environ.get("ANDROID_NDK_HOME", ""),
        str(pathlib.Path.home() / "Library" / "Android" / "sdk" / "ndk" / "28.2.13676358"),
    ]
    for candidate in candidates:
        if candidate and (pathlib.Path(candidate) / "source.properties").is_file():
            bin_dir = pathlib.Path(candidate) / "toolchains" / "llvm" / "prebuilt" / "darwin-x86_64" / "bin"
            return str(bin_dir / "llvm-readelf"), str(bin_dir / "llvm-nm")
    raise SystemExit("no NDK 28.2.13676358 found; pass --ndk DIR")


def main(argv):
    output = None
    ndk = None
    index = 0
    while index < len(argv):
        if argv[index] in ("--out", "--ndk") and index + 1 < len(argv):
            if argv[index] == "--out":
                output = argv[index + 1]
            else:
                ndk = argv[index + 1]
            index += 2
        else:
            raise SystemExit(f"unknown argument {argv[index]!r}; "
                             "usage: test_guest_mesa_build.py [--out DIR] [--ndk DIR]")
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    for case in (GuestMesaLockTests, GuestMesaParserTests, GuestMesaVerifierTests):
        suite.addTests(loader.loadTestsFromTestCase(case))
    if output is not None:
        readelf, nm = find_ndk_tools(ndk)
        GuestMesaOutputTests.out = pathlib.Path(output).resolve()
        GuestMesaOutputTests.readelf = readelf
        GuestMesaOutputTests.nm = nm
        suite.addTests(loader.loadTestsFromTestCase(GuestMesaOutputTests))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
