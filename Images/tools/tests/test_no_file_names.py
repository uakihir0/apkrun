"""Prevent production Python code from assuming Android image filenames."""

from __future__ import annotations

import ast
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def test_apkrun_image_sources_do_not_embed_image_file_names() -> None:
    """Input image names come from the manifest; the fixed ramdisk output is allowed."""
    package_directory = REPOSITORY_ROOT / "Images/tools/apkrun_image"
    forbidden_extensions = (".img", ".zip")
    allowed_output_names = {
        "extract.py": {"ramdisk.img"},
        # The injected partition is written under this fixed name (#099, IR-633). No input name is
        # assumed; the output name is the tool's own.
        "vendor_inject.py": {"vendor_a.img"},
    }

    for path in sorted(package_directory.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                if node.value in allowed_output_names.get(path.name, set()):
                    continue
                assert not node.value.endswith(forbidden_extensions), (
                    path,
                    getattr(node, "lineno", None),
                    node.value,
                )
