#!/usr/bin/env python3
"""Check that references between documents, and from code to documents, resolve.

    python3 -I scripts/tools/check_doc_refs.py --root REPOSITORY [--tasks] [--list-sections]

Markdown files checked: docs/**/*.md, AGENTS.md, README.md, and .github/**/*.md.

- A relative link must point to a file that exists. A `#anchor` on a link to a Markdown file must
  match a heading of that file.
- A section reference `name.md §N` (or `[name.md](path) §N`, `§N.M`, `§N–§M`, `§N, §M`) must name a
  numbered heading of that document. A bare `§N` in a document refers to the document itself.
- With --tasks, a task reference `#N` in docs/ must be a task of the task index
  (docs/04-plan/issues/README.md §3).
- `ADR-NNNN`, `R-NN`, `OQ-NN`, `FR-…`, and `NFR-…` must be defined in their documents.

In tracked source files (outside docs/, ThirdParty/, and Images/reference/), only section
references that name a document (`name.md §N`) are checked.

--list-sections prints every resolved section reference as `document §N <- file:line` and exits 0.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

CODE_SUFFIXES = {
    ".swift", ".h", ".c", ".m", ".mm", ".cpp", ".cc", ".kt", ".kts", ".rs", ".py", ".sh",
    ".yml", ".yaml", ".json", ".proto", ".te", ".mk", ".bp", ".rc", ".txt", ".csv", ".list",
}
SKIPPED_PREFIXES = ("ThirdParty/", "Images/reference/", "Images/tools/vendor/", "docs/")
TASK_INDEX = "docs/04-plan/issues/README.md"
ID_SOURCES = {
    "ADR": "docs/01-architecture/decisions",
    "R": "docs/04-plan/risks.md",
    "OQ": "docs/04-plan/open-questions.md",
    "FR": "docs/00-product/requirements.md",
    "NFR": "docs/00-product/requirements.md",
}

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
SECTION_NUMBER = re.compile(r"^(\d+(?:\.\d+)*)\.?(?:\s|$)")
LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
DOC_MENTION = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.-]*\.md)(?:\]\(([^)\s]+)\))?\)?")
SECTION_ITEM = r"§?\s?(\d+(?:\.\d+)*)"
SECTION_LIST = re.compile(
    r"\s*§§?\s?(\d+(?:\.\d+)*)((?:(?:\s*,\s*(?:and\s+|or\s+)?|\s+and\s+|\s+or\s+|\s*[–-]\s*)"
    + r"§\s?\d+(?:\.\d+)*)*)"
)
SECTION_TAIL = re.compile(r"§\s?(\d+(?:\.\d+)*)")
BARE_SECTION = re.compile(r"(?<![\w§])§\s?(\d+(?:\.\d+)*)")
TASK_REF = re.compile(r"(?<![\w&/#`])#(\d{1,3})(?![\w-])")
ID_REF = re.compile(r"\b(ADR-\d{4}|R-\d{2}|OQ-\d{2}|N?FR-[A-Z]+-\d{2})\b")
CODE_SPAN = re.compile(r"`[^`\n]*`")
FENCE = re.compile(r"^\s*(```|~~~)")


@dataclass
class Document:
    path: PurePosixPath
    sections: set[str]
    anchors: set[str]
    tasks: set[str]


def slug(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "").strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def parse_document(root: Path, path: PurePosixPath) -> Document:
    sections: set[str] = set()
    anchors: set[str] = set()
    tasks: set[str] = set()
    seen: dict[str, int] = {}
    in_fence = False
    for line in (root / path).read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = HEADING.match(line)
        if not match:
            continue
        title = match.group(2)
        number = SECTION_NUMBER.match(title)
        if number:
            sections.add(number.group(1))
        task = re.match(r"#(\d{1,3}) ", title)
        if task:
            tasks.add(task.group(1))
        anchor = slug(title)
        count = seen.get(anchor, 0)
        seen[anchor] = count + 1
        anchors.add(anchor if count == 0 else f"{anchor}-{count}")
    return Document(path, sections, anchors, tasks)


def tracked(root: Path) -> list[PurePosixPath]:
    output = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
    ).stdout
    return [PurePosixPath(item.decode()) for item in output.split(b"\0") if item]


def markdown_files(files: list[PurePosixPath]) -> list[PurePosixPath]:
    result = []
    for path in files:
        value = path.as_posix()
        if path.suffix != ".md":
            continue
        if value.startswith("docs/") or value in {"AGENTS.md", "README.md"} or value.startswith(".github/"):
            result.append(path)
    return result


def resolve(base: PurePosixPath, target: str) -> PurePosixPath:
    parts: list[str] = []
    for part in (base.parent / target).parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part != ".":
            parts.append(part)
    return PurePosixPath(*parts)


def section_numbers(head: str, tail: str) -> list[str]:
    return [head] + SECTION_TAIL.findall(tail)


def section_exists(document: Document, number: str) -> bool:
    return number in document.sections


def strip_code(line: str) -> str:
    return CODE_SPAN.sub(lambda match: " " * len(match.group(0)), line)


def defined_ids(root: Path) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    adr_dir = root / ID_SOURCES["ADR"]
    result["ADR"] = {
        f"ADR-{path.name[:4]}" for path in adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md")
    }
    for prefix in ("R", "OQ", "FR", "NFR"):
        path = root / ID_SOURCES[prefix]
        values: set[str] = set()
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                row = re.match(r"^\|\s*\**(" + prefix + r"-[A-Z0-9-]+?)\**\s*\|", line)
                if row:
                    values.add(row.group(1))
                heading = re.match(r"^#{2,6}\s+(" + prefix + r"-[A-Z0-9-]+)\b", line)
                if heading:
                    values.add(heading.group(1))
        result[prefix] = values
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--tasks", action="store_true", help="check task references in docs/")
    parser.add_argument("--list-sections", action="store_true")
    arguments = parser.parse_args()
    root: Path = arguments.root.resolve()

    files = tracked(root)
    markdown = markdown_files(files)
    documents = {path: parse_document(root, path) for path in markdown}
    by_name: dict[str, list[PurePosixPath]] = {}
    for path in documents:
        by_name.setdefault(path.name, []).append(path)
    ids = defined_ids(root)
    # A hyphenated document name without `.md` (`test-strategy §5`) is a reference too.
    stems = sorted(
        {path.stem for path in documents if "-" in path.stem and path.as_posix().startswith("docs/")},
        key=len,
        reverse=True,
    )
    stem_mention = re.compile(r"(?<![\w/.-])(" + "|".join(map(re.escape, stems)) + r")(?![\w.-])")

    def stem_document(stem: str) -> Document | None:
        candidates = [c for c in by_name.get(f"{stem}.md", []) if c.as_posix().startswith("docs/")]
        return documents[candidates[0]] if len(candidates) == 1 else None

    index = documents.get(PurePosixPath(TASK_INDEX))
    tasks: set[str] = set()
    if index is not None:
        text = (root / TASK_INDEX).read_text(encoding="utf-8")
        tasks = set(re.findall(r"^\|\s*#(\d{1,3})\s*\|", text, re.MULTILINE))

    failures: list[str] = []
    listing: list[str] = []

    def check_sections(source: str, line_number: int, document: Document | None, numbers: list[str],
                       name: str) -> None:
        if document is None:
            return
        for number in numbers:
            listing.append(f"{document.path} §{number} <- {source}:{line_number}")
            if not section_exists(document, number):
                failures.append(f"{source}:{line_number}: {name} has no section §{number}")

    for path in markdown:
        source = path.as_posix()
        current = documents[path]
        in_fence = False
        generated = False
        for line_number, raw in enumerate((root / path).read_text(encoding="utf-8").splitlines(), 1):
            if FENCE.match(raw):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            if raw.startswith("<!-- errorgen:begin"):
                generated = True
            elif raw.startswith("<!-- errorgen:end"):
                generated = False
            line = strip_code(raw)
            consumed: list[tuple[int, int]] = []

            for match in LINK.finditer(line):
                target = match.group(2)
                if re.match(r"^[a-z]+:", target) or target.startswith("#") and not target[1:]:
                    continue
                file_part, _, anchor = target.partition("#")
                linked = current.path if not file_part else resolve(path, file_part)
                if file_part and not (root / linked).exists():
                    failures.append(f"{source}:{line_number}: link target does not exist: {target}")
                    continue
                if anchor and linked.suffix == ".md":
                    document = documents.get(linked)
                    if document is not None and anchor not in document.anchors:
                        failures.append(f"{source}:{line_number}: no heading for anchor #{anchor} in {linked}")

            for match in DOC_MENTION.finditer(line):
                after = SECTION_LIST.match(line, match.end())
                if not after:
                    continue
                consumed.append((match.start(), after.end()))
                name = match.group(1)
                link = match.group(2)
                document: Document | None = None
                if link and not re.match(r"^[a-z]+:", link):
                    document = documents.get(resolve(path, link.partition("#")[0]))
                elif name == path.name:
                    document = current
                else:
                    candidates = by_name.get(name, [])
                    document = documents[candidates[0]] if len(candidates) == 1 else None
                check_sections(source, line_number, document, section_numbers(after.group(1), after.group(2)), name)

            for match in stem_mention.finditer(line):
                after = SECTION_LIST.match(line, match.end())
                if not after or any(start <= match.start() < end for start, end in consumed):
                    continue
                consumed.append((match.start(), after.end()))
                check_sections(source, line_number, stem_document(match.group(1)),
                               section_numbers(after.group(1), after.group(2)), match.group(1))

            for match in BARE_SECTION.finditer(line):
                if any(start <= match.start() < end for start, end in consumed):
                    continue
                if generated:
                    # The generated catalog tables cite sections of each domain's design document.
                    continue
                if source.startswith("docs/04-plan/issues/M") or source.startswith("docs/04-plan/issues/post"):
                    failures.append(
                        f"{source}:{line_number}: bare §{match.group(1)} in a task entry; name the document"
                    )
                    continue
                check_sections(source, line_number, current, [match.group(1)], path.name)

            if arguments.tasks and source.startswith("docs/"):
                for match in TASK_REF.finditer(line):
                    if match.group(1) not in tasks:
                        failures.append(f"{source}:{line_number}: #{match.group(1)} is not in the task index")

            for match in ID_REF.finditer(line):
                value = match.group(1)
                prefix = value.split("-")[0]
                if value not in ids.get(prefix, set()):
                    failures.append(f"{source}:{line_number}: {value} is not defined in {ID_SOURCES[prefix]}")

    for path in files:
        value = path.as_posix()
        if path.suffix not in CODE_SUFFIXES or value.startswith(SKIPPED_PREFIXES):
            continue
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            if "§" not in line:
                continue
            for match in DOC_MENTION.finditer(line):
                after = SECTION_LIST.match(line, match.end())
                if not after:
                    continue
                name = match.group(1)
                link = match.group(2)
                document = None
                if link and not re.match(r"^[a-z]+:", link):
                    document = documents.get(resolve(path, link.partition("#")[0]))
                if document is None:
                    candidates = [c for c in by_name.get(name, []) if c.as_posix().startswith("docs/")]
                    if name in {"AGENTS.md"}:
                        candidates = [PurePosixPath("AGENTS.md")]
                    document = documents[candidates[0]] if len(candidates) == 1 else None
                check_sections(value, line_number, document, section_numbers(after.group(1), after.group(2)), name)
            for match in stem_mention.finditer(line):
                after = SECTION_LIST.match(line, match.end())
                if after:
                    check_sections(value, line_number, stem_document(match.group(1)),
                                   section_numbers(after.group(1), after.group(2)), match.group(1))

    if arguments.list_sections:
        print("\n".join(sorted(listing)))
        return 0
    for failure in failures:
        print(failure)
    if failures:
        print(f"check-doc-refs: {len(failures)} broken reference(s)", file=sys.stderr)
        return 1
    print("check-doc-refs: all references resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
