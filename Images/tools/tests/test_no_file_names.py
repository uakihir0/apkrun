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
        # The injected partition is written under this fixed name (#99, IR-633). No input name is
        # assumed; the output name is the tool's own.
        "vendor_inject.py": {"vendor_a.img"},
        # The refreshed top-level vbmeta is written under this fixed name (#99, IR-745). The
        # input names come from the stock bundle and the manifest, not from this name.
        "vendor_reseal.py": {"vbmeta_a.img"},
        # These are private staging/output names used while the compose transaction rewrites the
        # existing partitions. The source image names continue to come from its manifest.
        "compose_avb.py": {"system_ext.img", "vbmeta-a-composed.img", "vbmeta_system.img"},
        "compose_command.py": {
            "odm-sealed.img",
            "odm-stock.img",
            "product-stock.img",
            "super-grown-odm.img",
            "super-grown.img",
            "super-stock.img",
            "super-system-ext-composed.img",
            "super.img",
            "system-ext-sealed.img",
            "system-ext-stock.img",
            "system-stock.img",
            "vbmeta-stock.img",
            "vbmeta-system-stock.img",
            "vbmeta_a.img",
            "vbmeta_system_a.img",
            "vendor-stock.img",
        },
        "bundle_variant.py": {
            "stock-vbmeta_a.img",
            "refreshed-vbmeta_a.img",
            "resealed-vendor_a.img",
            "injected-vendor_a.img",
        },
        # The composer writes these fixed overlay names into its output bundle. Source names
        # still come from the Android image manifest.
        "bundle.py": {"super.img", "vbmeta_system_a.img", "vbmeta_a.img"},
    }

    for path in sorted(package_directory.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                if node.value in allowed_output_names.get(path.name, set()):
                    continue
                    assert not any(
                        node.value != extension and node.value.endswith(extension)
                        for extension in forbidden_extensions
                    ), (
                        path,
                        getattr(node, "lineno", None),
                        node.value,
                    )
