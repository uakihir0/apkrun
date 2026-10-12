#!/usr/bin/env python3
"""Checks scripts/tools/check-g3-evidence.py: the test's verdict, the xcresult test results, and the pinned text of
the fixed-size statement (roadmap.md §2, condition 6). The gate needs a VM and Xcode, so the checks use fixtures."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_g3_evidence", ROOT / "scripts/tools/check-g3-evidence.py")
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)


def case(identifier: str, result: str) -> dict:
    return {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result}


def tree(*cases: dict) -> dict:
    return {"testNodes": [{"nodeType": "Test Plan", "children": list(cases)}]}


G3 = "G3GraphicsTests/testHelloGLRendersThroughVirglInAWindowWithoutReadbacksTearingOrRendererCrash()"


class SummaryTests(unittest.TestCase):
    def test_a_passed_summary_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.txt"
            path.write_text("gate: G3\nresult: passed\n", encoding="utf-8")
            self.assertTrue(checker.summary_check(path)[0])

    def test_a_failed_summary_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.txt"
            path.write_text("gate: G3\nresult: failed\nfailed: 1 the window\n", encoding="utf-8")
            self.assertFalse(checker.summary_check(path)[0])

    def test_a_missing_summary_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(checker.summary_check(Path(directory) / "summary.txt")[0])


class XCResultTests(unittest.TestCase):
    def test_the_passed_g3_test_passes(self) -> None:
        self.assertTrue(checker.xcresult_check(tree(case(G3, "Passed")))[0])

    def test_a_skipped_g3_test_fails(self) -> None:
        self.assertFalse(checker.xcresult_check(tree(case(G3, "Skipped")))[0])

    def test_a_failed_g3_test_fails(self) -> None:
        self.assertFalse(checker.xcresult_check(tree(case(G3, "Failed")))[0])

    def test_a_run_without_the_g3_test_fails(self) -> None:
        self.assertFalse(checker.xcresult_check(tree())[0])
        self.assertFalse(checker.xcresult_check(tree(case("LinuxGuestTests/testBoot()", "Passed")))[0])

    def test_another_failed_test_in_the_run_fails(self) -> None:
        other = case("G3EvidenceTests/testA()", "Failed")
        self.assertFalse(checker.xcresult_check(tree(case(G3, "Passed"), other))[0])


class FixedSizeTests(unittest.TestCase):
    def repository(self, graphics: str, windowing: str) -> Path:
        directory = Path(tempfile.mkdtemp())
        (directory / "docs/02-design").mkdir(parents=True)
        (directory / "docs/02-design/graphics.md").write_text(graphics, encoding="utf-8")
        (directory / "docs/02-design/display-and-windowing.md").write_text(windowing, encoding="utf-8")
        return directory

    def test_the_pinned_statements_in_their_sections_pass(self) -> None:
        graphics, windowing = self.pinned_documents()
        self.assertTrue(checker.fixed_size_check(self.repository(graphics, windowing))[0])

    def test_a_changed_statement_fails(self) -> None:
        graphics, windowing = self.pinned_documents()
        graphics = graphics.replace("fixed-size", "resizable")
        self.assertFalse(checker.fixed_size_check(self.repository(graphics, windowing))[0])

    def test_the_statement_outside_its_section_fails(self) -> None:
        graphics, windowing = self.pinned_documents()
        windowing = windowing.replace("### 5.3 Wrapper presentation algorithm", "### 5.3 Renamed")
        windowing += "\n**Development window (#023), fixed-size:** display 0 keeps the image's default mode, and the window scales the layer with aspect fit when it is resized (graphics.md §12 #023, step 3).\n"
        self.assertFalse(checker.fixed_size_check(self.repository(graphics, windowing))[0])

    @staticmethod
    def pinned_documents() -> tuple[str, str]:
        graphics = (
            "# Graphics\n\n### #023 SurfaceFlinger to Metal (M2, gate G3)\n\n1. list\n"
            "3. The window is **fixed-size**: display 0 keeps the image's default mode, and the window scales the layer "
            "with aspect fit.\n\n### Later tasks\n"
        )
        windowing = (
            "# Display\n\n### 5.3 Wrapper presentation algorithm\n\n- **Development window (#023), fixed-size:** display 0 "
            "keeps the image's default mode, and the window scales the layer with aspect fit when it is resized "
            "(graphics.md §12 #023, step 3).\n\n### 5.4 Color and format\n"
        )
        return graphics, windowing


if __name__ == "__main__":
    unittest.main(verbosity=2)
