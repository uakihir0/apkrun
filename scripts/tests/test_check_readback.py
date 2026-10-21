#!/usr/bin/env python3
"""Checks scripts/tools/check_readback.py: which calls count as host readbacks, and the per-file allowance."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_readback", ROOT / "scripts/tools/check_readback.py")
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["check_readback"] = checker
spec.loader.exec_module(checker)


class ReadbackCallTests(unittest.TestCase):
    def test_a_call_in_the_normal_path_counts(self) -> None:
        text = "func f() {\n    IOSurfaceLock(surface, .readOnly, nil)\n}\n"
        self.assertEqual(checker.readback_calls(text), [(2, "IOSurfaceLock")])

    def test_a_call_inside_the_test_flag_does_not_count(self) -> None:
        text = "#if APKRUN_EMBEDDED_RUNTIME && APKRUN_TEST_READBACK\n    gb_transfer_read(r, &a, p, n)\n#endif\n"
        self.assertEqual(checker.readback_calls(text), [])

    def test_the_else_branch_of_the_test_flag_counts(self) -> None:
        text = "#if APKRUN_TEST_READBACK\n    x()\n#else\n    texture.getBytes(p, bytesPerRow: 4)\n#endif\n"
        self.assertEqual(checker.readback_calls(text), [(4, "texture.getBytes")])

    def test_a_negated_flag_counts(self) -> None:
        text = "#if !APKRUN_TEST_READBACK\n    engine.transferRead(t, into: &d)\n#endif\n"
        self.assertEqual(checker.readback_calls(text), [(2, "engine.transferRead")])

    def test_comments_and_enum_cases_do_not_count(self) -> None:
        text = "// glReadPixels( is never called\n/* IOSurfaceLock( */\nrecorder.record(.transferRead(t, byteCount: 1))\n"
        self.assertEqual(checker.readback_calls(text), [])


class RepositoryTests(unittest.TestCase):
    def run_checker(self, files: dict[str, str]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            return subprocess.run(
                [sys.executable, "-I", str(ROOT / "scripts/tools/check_readback.py"), "--root", str(root)],
                capture_output=True,
                text=True,
            )

    def test_a_new_readback_in_a_product_module_fails(self) -> None:
        result = self.run_checker({"Packages/WindowingCore/Sources/WindowingCore/A.swift": "let _ = glReadPixels(0)\n"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("A.swift:1: host readback call `glReadPixels`", result.stdout)

    def test_tests_are_not_scanned(self) -> None:
        result = self.run_checker({"Packages/WindowingCore/Tests/WindowingCoreTests/A.swift": "IOSurfaceLock(s)\n"})
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
