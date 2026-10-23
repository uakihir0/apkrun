#!/usr/bin/env python3
"""Validate the Android image bundle selected by a G2/G3 acceptance run."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    arguments = sys.argv[1:]
    allow_stock = bool(arguments and arguments[0] == "--allow-stock")
    if allow_stock:
        arguments = arguments[1:]
    if len(arguments) != 1:
        print(
            "usage: verify-composed-image-bundle.py [--allow-stock] <bundle-directory>",
            file=sys.stderr,
        )
        return 2
    bundle = Path(arguments[0])
    manifest_path = bundle / "manifest.json"
    if bundle.is_symlink() or manifest_path.is_symlink() or not manifest_path.is_file():
        print(f"{bundle}: composed image bundle manifest is missing or unsafe.", file=sys.stderr)
        return 1
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"{manifest_path}: cannot read bundle manifest: {error}", file=sys.stderr)
        return 1
    provenance = manifest.get("provenance") if isinstance(manifest, dict) else None
    composition = provenance.get("composition") if isinstance(provenance, dict) else None
    valid_composed = (
        isinstance(manifest, dict)
        and manifest.get("kind") == "apkrun"
        and isinstance(composition, dict)
        and composition.get("schemaVersion") == 1
        and isinstance(composition.get("sourceManifest"), dict)
        and isinstance(composition.get("productInputs"), list)
        and composition.get("productInputs")
        and isinstance(composition.get("apkrunRevision"), str)
    )
    valid_stock = allow_stock and isinstance(manifest, dict) and manifest.get("kind") == "stock"
    if not valid_composed and not valid_stock:
        print(
            f"{manifest_path}: expected kind=apkrun with composition provenance"
            + (" or kind=stock." if allow_stock else "."),
            file=sys.stderr,
        )
        return 1
    print("verified stock or composed APKRun image bundle" if valid_stock else "verified composed APKRun image bundle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
