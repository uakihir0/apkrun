"""Command dispatcher for the APKRun image tooling."""

from __future__ import annotations

import argparse
import importlib
import sys
from collections.abc import Sequence

COMMANDS = {
    "fetch": "Fetch and verify Android build artifacts.",
    "inventory": "Classify every file in an Android build by content.",
    "inspect": "Inspect an Android image file.",
}


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
    if not arguments:
        parser.print_help()
        return 0

    namespace, command_arguments = parser.parse_known_args(arguments)
    if namespace.command is None:
        return 0

    module = importlib.import_module(f".{namespace.command}", package=__package__)
    command_main = getattr(module, "main")
    return int(command_main(command_arguments))


if __name__ == "__main__":
    sys.exit(main())
