#!/usr/bin/env python3
"""Checks scripts/tools/check_doc_refs.py on small fixture repositories."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/tools/check_doc_refs.py"

DESIGN = "# Graphics\n\nIntro.\n\n## 1. Scope\n\n### 1.1 Frame path\n\n## 3. Device\n"
INDEX = "# Tasks\n\n## 3. Task index\n\n| Task | Title | Milestone | Depends on | Gate |\n|---|---|---|---|---|\n| #7 | A task | M1 | None | |\n"


def run(files: dict[str, str], *arguments: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        return subprocess.run(
            [sys.executable, "-I", str(CHECKER), "--root", str(root), *arguments],
            capture_output=True,
            text=True,
        )


def repository(**extra: str) -> dict[str, str]:
    files = {"docs/02-design/graphics.md": DESIGN, "docs/04-plan/issues/README.md": INDEX}
    files.update(extra)
    return files


class CheckDocRefsTests(unittest.TestCase):
    def test_references_that_resolve_pass(self) -> None:
        text = "See [graphics.md](graphics.md) §1.1 and §3, and test-strategy §2.\n"
        result = run(repository(**{
            "docs/02-design/vm.md": "# VM\n\n## 1. A\n\nSee [graphics.md](graphics.md) §1.1–§3 and §1.\n",
            "docs/04-plan/test-strategy.md": "# Tests\n\n## 2. Tiers\n",
            "docs/02-design/input.md": "# Input\n\n## 1. A\n\n## 2. B\n\n" + text.replace("§3, and", "§3 and"),
            "Packages/A/Sources/A/A.swift": "/// The frame path (graphics.md §1.1, #7).\n",
        }), "--tasks")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_missing_section_fails(self) -> None:
        # Built from parts, so that the repository check does not read this file as a broken reference.
        result = run(repository(**{"Packages/A/A.swift": "// graphics.md " + "§12 step 3\n"}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("graphics.md has no section §12", result.stdout)

    def test_a_document_name_without_suffix_is_checked(self) -> None:
        result = run(repository(**{
            "docs/04-plan/test-strategy.md": "# Tests\n\n## 2. Tiers\n",
            "Tests/A.swift": "// T2, test-strategy " + "§6.4\n",
        }))
        self.assertIn("test-strategy has no section §6.4", result.stdout)

    def test_a_bare_section_in_a_task_entry_fails(self) -> None:
        entry = "# M1 Name\n\n## #7 A task\n\nRead §1.\n"
        result = run(repository(**{"docs/04-plan/issues/M01-name.md": entry}))
        self.assertIn("bare §1 in a task entry", result.stdout)

    def test_a_broken_link_and_anchor_fail(self) -> None:
        text = "[gone](gone.md) and [task](../04-plan/issues/M01-name.md#8-other)\n"
        result = run(repository(**{
            "docs/02-design/vm.md": "# VM\n\n" + text,
            "docs/04-plan/issues/M01-name.md": "# M1 Name\n\n## #7 A task\n",
        }))
        self.assertIn("link target does not exist: gone.md", result.stdout)
        self.assertIn("no heading for anchor #8-other", result.stdout)

    def test_an_unknown_task_fails_with_tasks(self) -> None:
        result = run(repository(**{"docs/02-design/vm.md": "# VM\n\nDone by #9.\n"}), "--tasks")
        self.assertIn("#9 is not in the task index", result.stdout)

    def test_generated_error_tables_may_cite_bare_sections(self) -> None:
        catalog = "# Errors\n\n<!-- errorgen:begin vm -->\n| a | §9.2 |\n<!-- errorgen:end vm -->\n"
        result = run(repository(**{"docs/03-reference/error-catalog.md": catalog}))
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
