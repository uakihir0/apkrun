#!/usr/bin/env python3
"""T0 checks for clean and safe VirGL runtime embedding."""

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_SCRIPT = REPO_ROOT / "scripts/build/embed-virgl-runtime.sh"
LIBRARIES = (
    "libvirglrenderer.1.dylib",
    "libepoxy.0.dylib",
    "libEGL.dylib",
    "libGLESv2.dylib",
)


class EmbedVirglRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.script = self.repository / "scripts/build/embed-virgl-runtime.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy2(SOURCE_SCRIPT, self.script)
        self.script.chmod(0o755)

        build_script = self.repository / "scripts/build-third-party.sh"
        build_script.parent.mkdir(parents=True, exist_ok=True)
        build_script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "if [[ \"${1:-}\" == \"--print-cache-key\" ]]; then\n"
            "  printf 'fixture-key\\n'\n"
            "fi\n",
            encoding="utf-8",
        )
        build_script.chmod(0o755)

        self.runtime_source = (
            self.repository / "ThirdParty/out/virgl-runtime/fixture-key"
        )
        self.runtime_source.mkdir(parents=True)
        for name in LIBRARIES:
            (self.runtime_source / name).write_bytes(("new " + name).encode())

        self.target_build = self.root / "DerivedData"
        self.runtime_destination = (
            self.target_build
            / "APKRun.app/Contents/Frameworks/VirGLRuntime"
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_embed(self):
        environment = os.environ.copy()
        environment.update(
            {
                "SRCROOT": str(self.repository),
                "TARGET_BUILD_DIR": str(self.target_build),
                "WRAPPER_NAME": "APKRun.app",
                "EXPANDED_CODE_SIGN_IDENTITY": "",
                "CODE_SIGNING_ALLOWED": "NO",
            }
        )
        return subprocess.run(
            ["bash", str(self.script)],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_removes_stale_runtime_files_before_copying(self):
        self.runtime_destination.mkdir(parents=True)
        (self.runtime_destination / "stale.dylib").write_bytes(b"stale")
        (self.runtime_destination / LIBRARIES[0]).write_bytes(b"old")

        result = self.run_embed()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            {item.name for item in self.runtime_destination.iterdir()},
            set(LIBRARIES),
        )
        for name in LIBRARIES:
            self.assertEqual(
                (self.runtime_destination / name).read_bytes(),
                ("new " + name).encode(),
            )

    def test_refuses_symlinked_runtime_destination(self):
        external_directory = self.root / "external"
        external_directory.mkdir()
        marker = external_directory / "keep.txt"
        marker.write_text("preserve", encoding="utf-8")
        self.runtime_destination.parent.mkdir(parents=True)
        self.runtime_destination.symlink_to(external_directory)

        result = self.run_embed()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing symlinked VirGL runtime destination", result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")


if __name__ == "__main__":
    unittest.main()
