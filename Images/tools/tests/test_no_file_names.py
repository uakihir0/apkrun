"""Prevent production Python code from assuming Android image filenames."""

from __future__ import annotations

import ast
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def test_apkrun_image_sources_do_not_embed_image_file_names() -> None:
    """Manifest and inventory code only obtains file paths from the input."""
    package_directory = REPOSITORY_ROOT / "Images/tools/apkrun_image"
    forbidden_extensions = (".img", ".zip")

    for path in sorted(package_directory.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                assert not node.value.endswith(forbidden_extensions), (
                    path,
                    getattr(node, "lineno", None),
                    node.value,
                )
