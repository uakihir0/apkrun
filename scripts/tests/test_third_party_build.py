#!/usr/bin/env python3
"""T0 coverage for graphics dependency inputs, fetching, and cache validation."""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts/tools/build_third_party.py"
SPEC = importlib.util.spec_from_file_location("build_third_party", MODULE_PATH)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


def command(*arguments, cwd=None):
    return subprocess.run(
        list(arguments),
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    ).stdout.strip()


def macho_tool_output(arguments, responses):
    tool = pathlib.Path(arguments[0]).name
    target = arguments[-1]
    if tool == "lipo":
        return responses.get("architectures", "arm64")
    if tool == "vtool":
        minimum = responses.get("minimum", "27.0")
        return "Load command 1\n      minos {}\n".format(minimum)
    if tool == "otool" and arguments[1] == "-D":
        install_name = responses.get(
            "install_name", "@rpath/" + pathlib.Path(target).name
        )
        return "{}:\n{}\n".format(target, install_name)
    if tool == "otool" and arguments[1] == "-L":
        dependency = responses.get("dependency", "@rpath/libEGL.dylib")
        return "{}:\n\t{} (compatibility version 1.0.0)\n".format(
            target, dependency
        )
    if tool == "otool" and arguments[1] == "-l":
        rpaths = responses.get("rpaths", [responses.get("rpath", "@loader_path")])
        return "".join(
            "Load command {}\n"
            "          cmd LC_RPATH\n"
            "      cmdsize 48\n"
            "         path {} (offset 12)\n".format(index, path)
            for index, path in enumerate(rpaths, start=12)
        )
    raise AssertionError("unexpected tool invocation: {}".format(arguments))


class BuildInputHashTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "ThirdParty/patches/angle").mkdir(parents=True)
        (self.root / "ThirdParty/patches/libepoxy").mkdir(parents=True)
        (self.root / "ThirdParty/patches/virglrenderer").mkdir(parents=True)
        (self.root / "ThirdParty/build").mkdir(parents=True)
        (self.root / "scripts/tools").mkdir(parents=True)
        for relative in builder.BUILD_SCRIPTS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("build input: {}\n".format(relative), encoding="utf-8")
        self.lock = {
            "schemaVersion": 1,
            "components": [
                {
                    "name": "angle",
                    "group": "virgl-runtime",
                    "kind": "source",
                    "commit": "a" * 40,
                    "version": "7151+apkrun.1",
                    "buildFlags": ['angle_enable_metal=true'],
                    "patches": ["angle/0001-angle.patch"],
                    "ships": "app",
                },
                {
                    "name": "libepoxy",
                    "group": "virgl-runtime",
                    "kind": "source",
                    "commit": "b" * 40,
                    "version": "1.5.11+apkrun.1",
                    "buildFlags": ["-Degl=yes"],
                    "patches": ["libepoxy/0001-epoxy.patch"],
                    "ships": "app",
                },
                {
                    "name": "virglrenderer",
                    "group": "virgl-runtime",
                    "kind": "source",
                    "commit": "c" * 40,
                    "version": "1.2.0+apkrun.1",
                    "buildFlags": ["-Dvenus=false"],
                    "patches": ["virglrenderer/0001-virgl.patch"],
                    "ships": "app",
                },
                {
                    "name": "analysis-only",
                    "group": "virgl-runtime",
                    "kind": "source",
                    "commit": "d" * 40,
                    "version": "0.1",
                    "buildFlags": [],
                    "patches": [],
                    "ships": "reference",
                },
            ],
        }
        self.write_lock()
        for item in self.lock["components"][:3]:
            (self.root / "ThirdParty/patches" / item["patches"][0]).write_bytes(
                b"patch contents for " + item["name"].encode("ascii")
            )

    def tearDown(self):
        self.temporary.cleanup()

    def write_lock(self):
        (self.root / "ThirdParty/ThirdParty.lock.json").write_text(
            json.dumps(self.lock, indent=2), encoding="utf-8"
        )

    def test_lock_order_and_json_key_order_do_not_change_hash(self):
        original = builder.input_hash(self.root, "virgl-runtime")
        self.lock["components"].reverse()
        self.lock["components"][0] = dict(reversed(list(self.lock["components"][0].items())))
        self.write_lock()
        self.assertEqual(original, builder.input_hash(self.root, "virgl-runtime"))

    def test_reference_entry_is_excluded_from_build_hash(self):
        original = builder.input_hash(self.root, "virgl-runtime")
        reference = self.lock["components"][-1]
        reference["commit"] = "e" * 40
        reference["version"] = "changed"
        self.write_lock()
        self.assertEqual(original, builder.input_hash(self.root, "virgl-runtime"))

    def test_mixed_reference_classification_is_rejected(self):
        self.lock["components"][-1]["ships"] = ["reference", "app"]
        self.write_lock()
        with self.assertRaisesRegex(builder.BuildFailure, "mixed reference classification"):
            builder.input_hash(self.root, "virgl-runtime")

    def test_patch_paths_cannot_escape_or_follow_symlinks(self):
        component = self.lock["components"][0]
        component["patches"] = ["../outside.patch"]
        (self.root / "ThirdParty/patches/outside.patch").write_bytes(b"outside")
        self.write_lock()
        with self.assertRaisesRegex(builder.BuildFailure, "unsafe patch path"):
            builder.input_hash(self.root, "virgl-runtime")

        component["patches"] = ["angle/0001-angle.patch"]
        self.write_lock()
        outside = self.root / "external-patches"
        outside.mkdir()
        (outside / "0001-angle.patch").write_bytes(b"redirected")
        angle_patches = self.root / "ThirdParty/patches/angle"
        angle_patches.rename(self.root / "ThirdParty/patches/angle-original")
        angle_patches.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(builder.BuildFailure, "unsafe patch path"):
            builder.input_hash(self.root, "virgl-runtime")

    def test_build_flags_patch_bytes_and_script_bytes_invalidate_hash(self):
        original = builder.input_hash(self.root, "virgl-runtime")
        self.lock["components"][0]["buildFlags"].append("angle_enable_vulkan=false")
        self.write_lock()
        self.assertNotEqual(original, builder.input_hash(self.root, "virgl-runtime"))

        changed_flags = builder.input_hash(self.root, "virgl-runtime")
        self.lock["components"][0]["buildFlags"].pop()
        self.write_lock()
        patch = self.root / "ThirdParty/patches/angle/0001-angle.patch"
        patch.write_bytes(b"changed patch bytes")
        self.assertNotEqual(original, builder.input_hash(self.root, "virgl-runtime"))

        patch.write_bytes(b"patch contents for angle")
        script = self.root / "ThirdParty/build/build-angle.sh"
        script.write_text("changed command\n", encoding="utf-8")
        self.assertNotEqual(original, builder.input_hash(self.root, "virgl-runtime"))
        self.assertNotEqual(changed_flags, original)

    def test_environment_fingerprint_changes_cache_identity(self):
        first = {"sdkVersion": "27.0", "clangVersion": "clang A"}
        second = {"sdkVersion": "27.0", "clangVersion": "clang B"}
        self.assertNotEqual(
            builder.environment_hash(first), builder.environment_hash(second)
        )

    def test_build_script_mode_is_part_of_the_hash(self):
        original = builder.input_hash(self.root, "virgl-runtime")
        script = self.root / "ThirdParty/build/build-angle.sh"
        script.chmod(0o755)
        self.assertNotEqual(original, builder.input_hash(self.root, "virgl-runtime"))


class MesonPythonEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.yaml_lib = pathlib.Path(self.temporary.name) / "pinned-python/lib"
        package = self.yaml_lib / "yaml"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(
            '__version__ = "6.0.3"\n', encoding="utf-8"
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_uses_only_locked_yaml_source(self):
        environment = {
            "APKRUN_THIRDPARTY_PYTHON": sys.executable,
            "APKRUN_THIRDPARTY_PYYAML_LIB": str(self.yaml_lib),
            "PYTHONPATH": "/unlocked/user/python",
        }
        meson_environment = builder.meson_environment_with_pinned_yaml(
            environment, "6.0.3"
        )
        self.assertEqual(str(self.yaml_lib), meson_environment["PYTHONPATH"])
        self.assertEqual("1", meson_environment["PYTHONDONTWRITEBYTECODE"])
        self.assertFalse((self.yaml_lib / "yaml/__pycache__").exists())
        self.assertEqual("/unlocked/user/python", environment["PYTHONPATH"])

    def test_rejects_yaml_source_with_unexpected_version(self):
        environment = {
            "APKRUN_THIRDPARTY_PYTHON": sys.executable,
            "APKRUN_THIRDPARTY_PYYAML_LIB": str(self.yaml_lib),
        }
        with self.assertRaisesRegex(builder.BuildFailure, "expected 6.0.2, found 6.0.3"):
            builder.meson_environment_with_pinned_yaml(environment, "6.0.2")


class SourcePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        command("git", "init", "--quiet", str(self.remote))
        command("git", "-C", str(self.remote), "config", "user.name", "Build Fixture")
        command(
            "git",
            "-C",
            str(self.remote),
            "config",
            "user.email",
            "build-fixture@example.invalid",
        )
        (self.remote / "pinned.txt").write_text("locked source\n", encoding="utf-8")
        command("git", "-C", str(self.remote), "add", "pinned.txt")
        command("git", "-C", str(self.remote), "commit", "--quiet", "-m", "fixture")
        self.commit = command("git", "-C", str(self.remote), "rev-parse", "HEAD")
        self.component = {
            "name": "fixture",
            "repository": str(self.remote),
            "commit": self.commit,
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_fetches_exact_commit_and_reuses_clean_checkout(self):
        with mock.patch.object(builder, "validate_source_reference"):
            path = builder.fetch_source(self.root, self.component)
        self.assertEqual(self.commit, command("git", "-C", str(path), "rev-parse", "HEAD"))
        with mock.patch.object(builder, "validate_source_reference"):
            self.assertEqual(path, builder.fetch_source(self.root, self.component))

    def test_dirty_cached_source_is_rejected_without_overwriting_it(self):
        with mock.patch.object(builder, "validate_source_reference"):
            path = builder.fetch_source(self.root, self.component)
        (path / "local-change.txt").write_text("do not discard\n", encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildFailure, "not clean"):
            with mock.patch.object(builder, "validate_source_reference"):
                builder.fetch_source(self.root, self.component)
        self.assertTrue((path / "local-change.txt").exists())

    def test_wrong_commit_is_rejected(self):
        with mock.patch.object(builder, "validate_source_reference"):
            path = builder.fetch_source(self.root, self.component)
        with self.assertRaisesRegex(builder.BuildFailure, "expected pinned commit"):
            builder.validate_source_checkout(path, "f" * 40)

    def test_invalid_repository_references_are_rejected_before_fetch(self):
        for repository in (
            "http://example.invalid/source.git",
            "https://user:password@example.invalid/source.git",
            "https://example.invalid/source.git?token=secret",
        ):
            with self.subTest(repository=repository):
                with self.assertRaises(builder.BuildFailure):
                    builder.validate_source_reference("fixture", repository, "a" * 40)


class MachOArtifactValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.artifact = self.root / "libepoxy.0.dylib"
        self.artifact.write_bytes(b"Mach-O fixture bytes")
        for name in builder.ARTIFACTS:
            artifact = self.root / name
            if not artifact.exists():
                artifact.write_bytes(b"Mach-O fixture bytes")
        self.responses = {}
        self.run_patch = mock.patch.object(
            builder, "run", side_effect=self.tool_output
        )
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def tool_output(self, arguments, **_kwargs):
        return macho_tool_output(arguments, self.responses)

    def test_valid_arm64_library_with_rpath_passes(self):
        builder.validate_runtime_artifact(
            self.artifact, self.artifact.name, self.root / "work"
        )

    def test_tool_output_filename_is_not_mistaken_for_a_build_reference(self):
        builder.validate_runtime_artifact(
            self.artifact, self.artifact.name, self.root, bundle_root=self.root
        )

    def test_wrong_architecture_version_install_name_and_dependency_fail(self):
        cases = (
            ("architectures", "arm64 x86_64", "exactly arm64"),
            ("minimum", "26.0", "older than 27.0"),
            ("install_name", "/tmp/libepoxy.0.dylib", "expected install name"),
            ("dependency", "/tmp/work/libEGL.dylib", "non-system absolute"),
            ("rpath", "@executable_path/../Frameworks", "must include @loader_path"),
            ("dependency", "@rpath/libmissing.dylib", "bundled dependency is missing"),
            (
                "rpaths",
                ["@loader_path", "/tmp/build/lib"],
                "unsupported or build-specific LC_RPATH",
            ),
        )
        for field, value, diagnostic in cases:
            with self.subTest(field=field):
                self.responses = {field: value}
                with self.assertRaisesRegex(builder.BuildFailure, diagnostic):
                    builder.validate_runtime_artifact(
                        self.artifact, self.artifact.name, self.root / "work"
                    )


class LibepoxyBuildTests(unittest.TestCase):
    def test_install_id_is_rewritten_before_virgl_links_against_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            stage = root / "stage"
            work = root / "work"
            source = root / "source"
            events = []

            def record_install_name(path, name):
                events.append(("install-name", path, name))

            def record_copy(path, destination, name):
                events.append(("copy", path, destination, name))

            with mock.patch.object(
                builder,
                "run_meson_component",
                side_effect=lambda *args, **kwargs: events.append(("build",)),
            ), mock.patch.object(
                builder, "add_install_name", side_effect=record_install_name
            ), mock.patch.object(
                builder, "copy_artifact", side_effect=record_copy
            ), mock.patch.object(
                builder,
                "normalize_runtime_rpaths",
                side_effect=lambda path: events.append(("rpaths", path)),
            ), mock.patch.object(
                builder,
                "copy_public_headers",
                side_effect=lambda source, stage, name: events.append(
                    ("headers", source, stage, name)
                ),
            ):
                builder.build_libepoxy(
                    {"buildFlags": []},
                    {"libepoxy": source},
                    stage,
                    work,
                    {},
                )

            self.assertEqual(
                events,
                [
                    ("build",),
                    (
                        "install-name",
                        work / "libepoxy/lib/libepoxy.0.dylib",
                        "libepoxy.0.dylib",
                    ),
                    (
                        "copy",
                        work / "libepoxy/lib/libepoxy.0.dylib",
                        stage,
                        "libepoxy.0.dylib",
                    ),
                    (
                        "install-name",
                        stage / "libepoxy.0.dylib",
                        "libepoxy.0.dylib",
                    ),
                    ("rpaths", stage / "libepoxy.0.dylib"),
                    (
                        "headers",
                        work / "libepoxy/include/epoxy",
                        stage,
                        "epoxy",
                    ),
                ],
            )


class AngleDependencyInventoryTests(unittest.TestCase):
    def setUp(self):
        self.components = [
            {
                "name": "angle-astc-encoder",
                "group": "virgl-runtime",
                "kind": "source",
                "ships": "app",
                "gnTargetPrefixes": ["//third_party/astc-encoder"],
            },
            {
                "name": "angle-vulkan-headers",
                "group": "virgl-runtime",
                "kind": "source",
                "ships": "app",
                "gnTargetPrefixes": ["//third_party/vulkan-headers"],
            },
            {
                "name": "angle-zlib",
                "group": "virgl-runtime",
                "kind": "source",
                "ships": "app",
                "gnTargetPrefixes": ["//third_party/zlib"],
            },
        ]
        self.dependencies = {
            "//:libEGL": (
                "//third_party/astc-encoder:astcenc\n"
                "//third_party/vulkan-headers/src:vulkan_headers\n"
                "//third_party/zlib:zlib\n"
            ),
            "//:libGLESv2": "//third_party/zlib/google:compression_utils_portable\n",
        }

    def test_exact_metal_target_dependencies_pass(self):
        builder.validate_angle_dependency_inventory(
            self.components, self.dependencies
        )

    def test_unlicensed_target_dependency_fails(self):
        dependencies = dict(self.dependencies)
        dependencies["//:libGLESv2"] += "//third_party/unknown:library\n"
        with self.assertRaisesRegex(
            builder.BuildFailure, "unlicensed third_party dependencies"
        ):
            builder.validate_angle_dependency_inventory(
                self.components, dependencies
            )

    def test_unused_license_inventory_entry_fails(self):
        components = self.components + [
            {
                "name": "angle-unused",
                "group": "virgl-runtime",
                "kind": "source",
                "ships": "app",
                "gnTargetPrefixes": ["//third_party/unused"],
            }
        ]
        with self.assertRaisesRegex(
            builder.BuildFailure, "outside the Metal target graph"
        ):
            builder.validate_angle_dependency_inventory(
                components, self.dependencies
            )


class CacheManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.lock_hash = "1" * 64
        self.env_hash = "2" * 64
        self.directory = self.root / "cache"
        self.directory.mkdir()
        artifacts = {}
        for index, name in enumerate(builder.ARTIFACTS):
            contents = ("fixture artifact {}\n".format(index)).encode("ascii")
            path = self.directory / name
            path.write_bytes(contents)
            artifacts[name] = builder.sha256_file(path)
        header = self.directory / "include/EGL/egl.h"
        header.parent.mkdir(parents=True)
        header.write_text("/* fixture header */\n", encoding="utf-8")
        (self.directory / "build-manifest.json").write_text(
            json.dumps(
                {
                    "schemaVersion": builder.SCHEMA_VERSION,
                    "group": "virgl-runtime",
                    "lockHash": self.lock_hash,
                    "environmentHash": self.env_hash,
                    "artifacts": artifacts,
                    "headers": builder.public_header_manifest(
                        self.directory / "include"
                    ),
                }
            ),
            encoding="utf-8",
        )
        self.run_patch = mock.patch.object(
            builder, "run", side_effect=lambda arguments, **kwargs: macho_tool_output(arguments, {})
        )
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def test_complete_hash_matched_cache_is_reused(self):
        self.assertTrue(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )

    def test_partial_or_corrupt_cache_is_rejected(self):
        artifact = self.directory / builder.ARTIFACTS[0]
        artifact.write_bytes(b"corrupt")
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )
        artifact.unlink()
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )

    def test_modified_or_symlinked_header_cache_is_rejected(self):
        header = self.directory / "include/EGL/egl.h"
        header.write_text("changed\n", encoding="utf-8")
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )
        header.unlink()
        header.symlink_to(self.root / "external.h")
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )

    def test_environment_mismatch_and_unexpected_file_are_rejected(self):
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, "3" * 64
            )
        )
        (self.directory / "extra.txt").write_text("unexpected", encoding="utf-8")
        self.assertFalse(
            builder.verify_manifest(
                self.directory, "virgl-runtime", self.lock_hash, self.env_hash
            )
        )

    def test_malformed_manifest_shapes_are_treated_as_cache_misses(self):
        manifest_path = self.directory / "build-manifest.json"
        for contents in ("[]", '{"artifacts":[]}', '{"artifacts":null}'):
            with self.subTest(contents=contents):
                manifest_path.write_text(contents, encoding="utf-8")
                self.assertFalse(
                    builder.verify_manifest(
                        self.directory, "virgl-runtime", self.lock_hash, self.env_hash
                    )
                )


class CurrentRuntimePointerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.cache_root = self.root / "ThirdParty/out/virgl-runtime"
        self.cache_root.mkdir(parents=True)

    def tearDown(self):
        self.temporary.cleanup()

    def test_current_pointer_atomically_tracks_verified_cache_name(self):
        first = self.cache_root / "first-key"
        first.mkdir()
        builder.publish_current_cache(self.root, first)
        current = self.cache_root / "current"
        self.assertTrue(current.is_symlink())
        self.assertEqual(current.readlink(), pathlib.Path("first-key"))

        second = self.cache_root / "second-key"
        second.mkdir()
        builder.publish_current_cache(self.root, second)
        self.assertEqual(current.readlink(), pathlib.Path("second-key"))

    def test_current_pointer_refuses_a_directory_at_its_path(self):
        (self.cache_root / "verified-key").mkdir()
        (self.cache_root / "current").mkdir()
        with self.assertRaisesRegex(builder.BuildFailure, "non-symlink runtime pointer"):
            builder.publish_current_cache(
                self.root, self.cache_root / "verified-key"
            )


class BuildLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_same_cache_key_builds_are_serialized_across_processes(self):
        ready = self.root / "ready"
        entered = self.root / "entered"
        worker = """
import pathlib, sys
sys.path.insert(0, sys.argv[3])
import build_third_party as b
pathlib.Path(sys.argv[2]).write_text("ready")
with b.exclusive_build_lock(pathlib.Path(sys.argv[1]), "same-key"):
    pathlib.Path(sys.argv[4]).write_text("entered")
"""
        with builder.exclusive_build_lock(self.root, "same-key"):
            process = subprocess.Popen(
                [
                    "python3",
                    "-c",
                    worker,
                    str(self.root),
                    str(ready),
                    str(MODULE_PATH.parent),
                    str(entered),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "worker did not reach the lock")
            self.assertFalse(entered.exists(), "worker entered while the lock was held")
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr or stdout)
        self.assertTrue(entered.exists())

    def test_repository_lock_is_validated_before_cache_lookup(self):
        checker = self.root / "scripts/check-lock.sh"
        checker.parent.mkdir(parents=True)
        checker.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        checker.chmod(0o755)
        with mock.patch.object(
            builder, "run", side_effect=builder.BuildFailure("invalid lock")
        ) as run_mock, mock.patch.object(builder, "verify_manifest") as cache_mock:
            with self.assertRaisesRegex(builder.BuildFailure, "invalid lock"):
                builder.run_build(self.root, "virgl-runtime", force=False)
        run_mock.assert_called_once_with([str(checker)], cwd=self.root)
        cache_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
