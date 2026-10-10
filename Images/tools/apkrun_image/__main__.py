"""Command dispatcher for the APKRun image tooling."""

from __future__ import annotations

import argparse
import importlib
import sys
from collections.abc import Sequence

COMMANDS = {
    "bundle": "Build and sign a runtime image bundle.",
    "disks": "Build the raw GPT disks of a device layout.",
    "erofs-tools": "Fetch and verify the pinned erofs-utils tools.",
    "extract": "Extract verified Android boot artifacts.",
    "fetch": "Fetch and verify Android build artifacts.",
    "inject-vendor": "Rebuild vendor_a with the verified guest Mesa libraries.",
    "inventory": "Classify every file in an Android build by content.",
    "inspect": "Inspect an Android image file.",
    "keygen": "Create the Ed25519 key pair that signs runtime image bundles.",
    "manifest": "Generate or validate an Android image manifest.",
}

# Command names that are not valid module names map to their module.
MODULES = {"erofs-tools": "erofs", "inject-vendor": "vendor_inject"}


def build_parser() -> argparse.ArgumentParser:
    """Build the top-level command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image",
        description="Acquire and inspect pinned Android image inputs.",
    )
    parser.add_argument(
        "command",
        nargs="?",
        choices=tuple(COMMANDS),
        help="command to run",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Dispatch to a command module."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser()
    if not arguments or arguments[0] in {"-h", "--help"}:
        parser.print_help()
        return 0
    command = arguments[0]
    if command not in COMMANDS:
        parser.error(f"invalid choice: {command!r} (choose from {', '.join(COMMANDS)})")
    module = importlib.import_module(f".{MODULES.get(command, command)}", package=__package__)
    command_main = getattr(module, "main")
    return int(command_main(arguments[1:]))


if __name__ == "__main__":
    sys.exit(main())
