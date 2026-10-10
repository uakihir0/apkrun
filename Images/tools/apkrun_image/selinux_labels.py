"""SELinux labels for files that a rebuild adds, from the image's own file contexts (#099).

libselinux loads the platform file contexts of system_a, then the vendor's file contexts, as one
list. For one path, the matching rule with the longest literal stem wins, and a tie goes to the
later rule. This is the rule that IR-623 checked against the stock vendor partition of build
16373615, where it reproduces every label. A rebuild labels only the files it adds, and it refuses
to label a file when the contexts do not reproduce the stock labels, so an unlabelled library is
never written silently.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from apkrun_image.erofs import DIRECTORY, REGULAR_FILE, SYMLINK, Entry

VENDOR_MOUNT = "/vendor"
NO_LABEL = "<<none>>"
_FILE_TYPES = {"-d": DIRECTORY, "-l": SYMLINK, "-f": REGULAR_FILE, "--": REGULAR_FILE}
_OTHER_TYPES = ("-b", "-c", "-p", "-s")
_METACHARACTERS = re.compile(r"[^\\.^$|?*+()\[\]{}]*")


class ContextsError(ValueError):
    """The file contexts cannot be read, or they do not reproduce the stock labels."""


@dataclass(frozen=True)
class ContextRule:
    """One line of a file contexts file, in the order libselinux loads it."""

    pattern: str
    kind: str | None
    context: str | None
    stem: int
    order: int
    source: str


def literal_stem(pattern: str) -> int:
    """Return the length of the literal prefix of a regular expression (libselinux's stem)."""
    return len(_METACHARACTERS.match(pattern).group(0))  # type: ignore[union-attr]


def parse_contexts(source: str, text: str, *, first_order: int = 0) -> list[ContextRule]:
    """Parse one file contexts file. Lines are `regex [type] context`, and `#` starts a comment."""
    rules: list[ContextRule] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) == 2:
            pattern, context = fields
            kind: str | None = None
        elif len(fields) == 3:
            pattern, flag, context = fields
            if flag in _FILE_TYPES:
                kind = _FILE_TYPES[flag]
            elif flag in _OTHER_TYPES:
                kind = "other"
            else:
                raise ContextsError(f"{source}:{number}: unknown file type {flag!r}.")
        else:
            raise ContextsError(f"{source}:{number}: expected a pattern and a context.")
        try:
            re.compile(pattern)
        except re.error as error:
            raise ContextsError(f"{source}:{number}: invalid pattern: {error}.") from None
        rules.append(
            ContextRule(
                pattern=pattern,
                kind=kind,
                context=None if context == NO_LABEL else context,
                stem=literal_stem(pattern),
                order=first_order + len(rules),
                source=source,
            )
        )
    if not rules:
        raise ContextsError(f"{source}: no rules were found.")
    return rules


def load_contexts(parts: Sequence[tuple[str, str]]) -> list[ContextRule]:
    """Parse the contexts files in load order (name, text) into one list."""
    rules: list[ContextRule] = []
    for source, text in parts:
        rules.extend(parse_contexts(source, text, first_order=len(rules)))
    return rules


def _candidates(rules: Sequence[ContextRule], path: str, kind: str) -> list[ContextRule]:
    matches = []
    for rule in rules:
        if rule.kind is not None and rule.kind != kind:
            continue
        if re.fullmatch(rule.pattern, path):
            matches.append(rule)
    return matches


def vendor_path(erofs_path: str) -> str:
    """Return the path a file has on the device, for an EROFS path of the vendor partition."""
    return VENDOR_MOUNT if erofs_path == "/" else VENDOR_MOUNT + erofs_path


def label_for(rules: Sequence[ContextRule], erofs_path: str, kind: str) -> str | None:
    """Return the label that the contexts give a vendor file, or None when no rule matches."""
    matches = _candidates(rules, vendor_path(erofs_path), kind)
    if not matches:
        raise ContextsError(f"{vendor_path(erofs_path)}: no file context matches this file.")
    winner = max(matches, key=lambda rule: (rule.stem, rule.order))
    return winner.context


def last_rule_label(rules: Sequence[ContextRule], erofs_path: str, kind: str) -> str | None:
    """Return the label of the last matching rule, which must agree with `label_for`."""
    matches = _candidates(rules, vendor_path(erofs_path), kind)
    if not matches:
        raise ContextsError(f"{vendor_path(erofs_path)}: no file context matches this file.")
    return matches[-1].context


def check_reproduces(rules: Sequence[ContextRule], entries: Mapping[str, Entry]) -> int:
    """Check that the contexts give every stock entry its label; return how many were checked."""
    mismatches: list[str] = []
    checked = 0
    for path in sorted(entries):
        entry = entries[path]
        expected = entry.label
        actual = label_for(rules, path, entry.kind)
        checked += 1
        if actual != expected:
            mismatches.append(f"{vendor_path(path)}: stock {expected!r}, contexts {actual!r}")
    if mismatches:
        raise ContextsError(
            f"the file contexts give {len(mismatches)} stock labels a different value; "
            f"first: {mismatches[0]}"
        )
    return checked


def read_contexts_text(path: Path) -> str:
    """Read a file contexts file as UTF-8 text."""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ContextsError(f"{path}: cannot read the file contexts: {error}.") from None


def summarize(rules: Sequence[ContextRule]) -> dict[str, Any]:
    """Return counts for the provenance record."""
    sources: dict[str, int] = {}
    for rule in rules:
        sources[rule.source] = sources.get(rule.source, 0) + 1
    return {"rules": len(rules), "rulesPerSource": sources}
