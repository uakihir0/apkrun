#!/usr/bin/env python3
"""Focused tests for the pinned AOSP fec host-tool build."""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILDER_PATH = ROOT / "scripts/tools/build_fec.py"
SPEC = importlib.util.spec_from_file_location("build_fec", BUILDER_PATH)
assert SPEC and SPEC.loader
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


def command(arguments: list[str]) -> str:
    result = subprocess.run(
        arguments,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(arguments)}\n{result.stdout}"
        )
    return result.stdout.strip()


def make_sparse_image(path: pathlib.Path) -> bytes:
    block_size = 4096
    raw_block = bytes((index * 3) & 0xFF for index in range(block_size))
    fill_word = b"\x12\x34\x56\x78"
    expected = raw_block + fill_word * (block_size // 4) + bytes(block_size)
    header = struct.pack(
        "<IHHHHIIII",
        0xED26FF3A,
        1,
        0,
        28,
        12,
        block_size,
        3,
        3,
        0,
    )
    chunks = b"".join(
        (
            struct.pack("<HHII", 0xCAC1, 0, 1, 12 + block_size) + raw_block,
            struct.pack("<HHII", 0xCAC2, 0, 1, 16) + fill_word,
            struct.pack("<HHII", 0xCAC3, 0, 1, 12),
        )
    )
    path.write_bytes(header + chunks)
    return expected


class FecBuildDefinitionTests(unittest.TestCase):
    def test_compiler_environment_removes_inherited_flags_and_paths(self) -> None:
        environment = {
            "PATH": "/usr/bin",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "CPATH": "/tmp/include",
            "CPLUS_INCLUDE_PATH": "/tmp/cxx",
            "LIBRARY_PATH": "/tmp/lib",
            "CFLAGS": "-march=native",
            "LDFLAGS": "-L/tmp/lib",
            "SDKROOT": "/tmp/sdk",
        }
        sanitized = builder.compiler_environment(environment)
        self.assertEqual(sanitized["PATH"], environment["PATH"])
        self.assertEqual(sanitized["DEVELOPER_DIR"], environment["DEVELOPER_DIR"])
        for name in builder.COMPILER_ENVIRONMENT_REMOVED:
            self.assertNotIn(name, sanitized)

    def test_sources_are_pinned_and_build_uses_narrow_host_shims(self) -> None:
        self.assertEqual(
            builder.SOURCE_COMPONENTS["aosp-verity"]["commit"],
            "1289e9b3f282909eec6e80414e14dcc207bda439",
        )
        self.assertEqual(
            builder.SOURCE_COMPONENTS["aosp-verity"]["tagObject"],
            "740be3463713251280b0471d3dfb3cdd321520dd",
        )
        self.assertEqual(
            builder.SOURCE_COMPONENTS["libfec-rs"]["commit"],
            "90857deb7973c0ca24c79b9c1809fc9667f32c4f",
        )
        self.assertIn("scripts/tools/fec_host/sparse_compat.cpp", builder.SHIM_FILES)
        self.assertIn(
            "encode_rs_char.c", builder.SOURCE_COMPONENTS["libfec-rs"]["files"]
        )
        self.assertEqual(
            builder.OUTPUT_RELATIVE.as_posix(), "ThirdParty/out/fec/bin/fec"
        )
        locked = builder.validate_lock(ROOT)
        for name, component in locked.items():
            for relative in component["licenseFiles"]:
                notice = ROOT / "ThirdParty/licenses" / name / relative
                self.assertTrue(notice.is_file(), str(notice))


class FecVerifyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="apkrun-fec-verify-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.prefix = self.root / builder.OUTPUT_RELATIVE.parent
        self.prefix.mkdir(parents=True)
        self.binary = self.root / builder.OUTPUT_RELATIVE
        self.binary.write_bytes(b"fixture fec executable")
        self.lock = self.prefix / ".build.lock"
        self.lock.touch()
        self.manifest = self.prefix / ".apkrun-fec-build.json"
        self.components = {
            name: {
                "repository": record["repository"],
                "commit": record["commit"],
                "version": record["version"],
            }
            for name, record in builder.SOURCE_COMPONENTS.items()
        }
        self.host = {"architecture": "arm64", "xcodeVersion": "fixture"}
        self.inputs_hash = "a" * 64
        self.sources = {
            name: self.root / "ThirdParty/out/src" / name / component["commit"]
            for name, component in self.components.items()
        }
        for source in self.sources.values():
            source.mkdir(parents=True)
        self.write_manifest()

    def write_manifest(self, **overrides: object) -> None:
        record: dict[str, object] = {
            "schemaVersion": builder.SCHEMA_VERSION,
            "sources": {
                name: {
                    "repository": component["repository"],
                    "pin": component["commit"],
                    "version": component["version"],
                    "commit": component["commit"],
                }
                for name, component in self.components.items()
            },
            "inputsSha256": self.inputs_hash,
            "host": self.host,
            "flags": list(builder.BUILD_FLAGS),
            "binarySha256": builder.sha256_file(self.binary),
            "architecture": "arm64",
        }
        record.update(overrides)
        self.manifest.write_bytes(builder.canonical_json(record) + b"\n")

    def verify_patches(self):
        return (
            mock.patch.object(builder, "validate_lock", return_value=self.components),
            mock.patch.object(
                builder,
                "host_environment",
                return_value=(self.host, "/fake/clang", "/fake/clang++", "/fake/sdk"),
            ),
            mock.patch.object(builder, "existing_sources", return_value=self.sources),
            mock.patch.object(builder, "hash_inputs", return_value=self.inputs_hash),
            mock.patch.object(
                builder, "git_output", side_effect=lambda path, *_: path.name
            ),
            mock.patch.object(
                builder, "executable_path", side_effect=lambda name: f"/fake/{name}"
            ),
            mock.patch.object(builder, "verify_binary"),
            mock.patch.object(builder, "smoke_test"),
            mock.patch.object(
                builder,
                "fetch_source",
                side_effect=AssertionError("verify must not fetch sources"),
            ),
            mock.patch.object(
                builder,
                "compile_binary",
                side_effect=AssertionError("verify must not build the binary"),
            ),
        )

    def test_verify_checks_the_existing_manifest_and_smoke_tests_without_building(
        self,
    ) -> None:
        before = {
            path: path.read_bytes() for path in (self.binary, self.lock, self.manifest)
        }
        patches = self.verify_patches()
        with (
            patches[0],
            patches[1],
            patches[2],
            patches[3],
            patches[4],
            patches[5],
            patches[6] as verify_binary,
            patches[7] as smoke_test,
            patches[8],
            patches[9],
        ):
            result = builder.verify(self.root)

        self.assertEqual(result, self.binary)
        verify_binary.assert_called_once_with(
            self.binary,
            lipo="/fake/lipo",
            otool="/fake/otool",
        )
        smoke_test.assert_called_once()
        self.assertTrue(self.binary.is_file())
        self.assertTrue(self.manifest.is_file())
        self.assertTrue(self.lock.is_file())
        self.assertEqual(
            {path: path.read_bytes() for path in before},
            before,
        )

    def test_verify_rejects_a_stale_build_manifest(self) -> None:
        self.write_manifest(flags=["-march=native"])
        patches = self.verify_patches()
        with (
            patches[0],
            patches[1],
            patches[2],
            patches[3],
            patches[4],
            patches[5],
            patches[6],
            patches[7],
            patches[8],
            patches[9],
            self.assertRaisesRegex(builder.BuildFailure, "manifest does not match"),
        ):
            builder.verify(self.root)

    def test_verify_rejects_binary_hash_mismatch(self) -> None:
        self.binary.write_bytes(b"tampered executable")
        patches = self.verify_patches()
        with (
            patches[0],
            patches[1],
            patches[2],
            patches[3],
            patches[4],
            patches[5],
            patches[6],
            patches[7],
            patches[8],
            patches[9],
            self.assertRaisesRegex(builder.BuildFailure, "manifest does not match"),
        ):
            builder.verify(self.root)

    def test_verify_requires_an_existing_lock_and_does_not_create_it(self) -> None:
        self.lock.unlink()
        with self.assertRaisesRegex(builder.BuildFailure, "build lock is missing"):
            builder.verify(self.root)
        self.assertFalse(self.lock.exists())

    def test_existing_sources_refuses_missing_checkout_without_fetching(self) -> None:
        source_root = self.root / "ThirdParty/out/src"
        source_root.mkdir(parents=True, exist_ok=True)
        components = {
            "aosp-verity": {"commit": "1" * 40},
            "libfec-rs": {"commit": "2" * 40},
        }
        with (
            mock.patch.object(
                builder,
                "validate_clean_checkout",
                side_effect=AssertionError("a missing checkout must be rejected first"),
            ),
            mock.patch.object(
                builder,
                "fetch_source",
                side_effect=AssertionError("verification must not fetch sources"),
            ),
            self.assertRaisesRegex(builder.BuildFailure, "checkout is missing"),
        ):
            builder.existing_sources(self.root, components)

    def test_verify_mode_cannot_be_combined_with_force(self) -> None:
        with self.assertRaises(SystemExit):
            builder.parse_args(["--verify", "--force"])

    def test_manifest_match_rejects_unexpected_fields(self) -> None:
        self.write_manifest(unreviewedSetting=True)
        with mock.patch.object(
            builder, "git_output", side_effect=lambda path, *_: path.name
        ):
            self.assertFalse(
                builder.manifest_matches(
                    self.root,
                    self.binary,
                    self.manifest,
                    inputs_hash=self.inputs_hash,
                    host=self.host,
                    components=self.components,
                )
            )


@unittest.skipUnless(
    (ROOT / "ThirdParty/out/fec/bin/fec").is_file(),
    "run scripts/build-fec-tool.sh to build the pinned FEC utility first",
)
class BuiltFecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = ROOT / "ThirdParty/out/fec/bin/fec"

    def test_size_calculation_boundary(self) -> None:
        self.assertEqual(
            command([str(self.binary), "--print-fec-size", "4096", "--roots", "2"]),
            "12288",
        )
        self.assertEqual(
            command(
                [
                    str(self.binary),
                    "--print-fec-size",
                    str(254 * 4096),
                    "--roots",
                    "2",
                ]
            ),
            "20480",
        )

    def test_encode_header_digest_and_decode_round_trip(self) -> None:
        original = bytes((index * 37 + 11) & 0xFF for index in range(4096))
        with tempfile.TemporaryDirectory(prefix="apkrun-fec-test-") as temp_name:
            directory = pathlib.Path(temp_name)
            source = directory / "input.img"
            fec_path = directory / "fec.bin"
            restored = directory / "restored.img"
            source.write_bytes(original)
            command(
                [
                    str(self.binary),
                    "--encode",
                    "--roots",
                    "2",
                    str(source),
                    str(fec_path),
                ]
            )
            fec_data = fec_path.read_bytes()
            self.assertEqual(builder.verify_fec_header(fec_data, len(original)), 8192)
            command(
                [
                    str(self.binary),
                    "--decode",
                    "--roots",
                    "2",
                    str(source),
                    str(fec_path),
                    str(restored),
                ]
            )
            self.assertEqual(restored.read_bytes(), original)

    def test_android_sparse_input_is_expanded_before_encoding(self) -> None:
        with tempfile.TemporaryDirectory(prefix="apkrun-fec-sparse-test-") as temp_name:
            directory = pathlib.Path(temp_name)
            sparse = directory / "sparse.img"
            expected = make_sparse_image(sparse)
            fec_path = directory / "fec.bin"
            restored = directory / "restored.img"
            command(
                [
                    str(self.binary),
                    "--encode",
                    "--roots",
                    "2",
                    str(sparse),
                    str(fec_path),
                ]
            )
            command(
                [
                    str(self.binary),
                    "--decode",
                    "--roots",
                    "2",
                    str(sparse),
                    str(fec_path),
                    str(restored),
                ]
            )
            self.assertEqual(restored.read_bytes(), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
