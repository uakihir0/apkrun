#!/usr/bin/env python3
"""Check that every project in an APKRun AOSP manifest resolves to a full SHA."""

from __future__ import annotations

import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

COMMIT_SHA = re.compile(r"[0-9a-f]{40}\Z")


def validate(path: Path) -> str:
    try:
        payload = path.read_bytes()
        root = ET.fromstring(payload)
    except (OSError, ET.ParseError) as error:
        raise ValueError(f"cannot read a valid XML manifest: {error}") from error

    if root.tag != "manifest":
        raise ValueError("root element must be <manifest>")
    if next(root.iter("include"), None) is not None:
        raise ValueError("manifest must be self-contained; resolve <include> entries before pinning")

    default = root.find("default")
    default_revision = default.get("revision") if default is not None else None
    projects = list(root.iter("project"))
    if not projects:
        raise ValueError("manifest has no <project> entries")

    for project in projects:
        name = project.get("name", "<unnamed>")
        revision = project.get("revision", default_revision)
        if revision is None or COMMIT_SHA.fullmatch(revision) is None:
            raise ValueError(f"project {name!r} does not resolve to a full lowercase 40-character commit SHA")

    for element in root.iter("extend-project"):
        revision = element.get("revision")
        if revision is not None and COMMIT_SHA.fullmatch(revision) is None:
            name = element.get("name", "<unnamed>")
            raise ValueError(f"revision override for project {name!r} is not a full commit SHA")

    return hashlib.sha256(payload).hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <manifest.xml>", file=sys.stderr)
        return 64
    try:
        print(validate(Path(sys.argv[1])))
    except ValueError as error:
        print(f"validate-manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
