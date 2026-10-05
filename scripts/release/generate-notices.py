#!/usr/bin/env python3
"""Generate the offline third-party notices page for APKRun.app."""

from __future__ import annotations

import argparse
import html
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple


class NoticeFailure(RuntimeError):
    pass


def read_lock(root: pathlib.Path) -> Dict[str, Any]:
    path = root / "ThirdParty/ThirdParty.lock.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise NoticeFailure("{}: {}".format(path, error))
    if not isinstance(value, dict) or not isinstance(value.get("components"), list):
        raise NoticeFailure("{}: expected a components array".format(path))
    return value


def ships_with_app(component: Mapping[str, Any]) -> bool:
    ships = component.get("ships")
    if isinstance(ships, str):
        return ships in {"app", "derived"}
    return isinstance(ships, list) and any(
        value in {"app", "derived"} for value in ships if isinstance(value, str)
    )


def safe_file(root: pathlib.Path, relative: Any, role: str) -> pathlib.Path:
    if not isinstance(relative, str) or not relative or "\\" in relative or "\0" in relative:
        raise NoticeFailure("invalid {} path: {!r}".format(role, relative))
    path = pathlib.PurePosixPath(relative)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise NoticeFailure("unsafe {} path: {}".format(role, relative))
    if root.is_symlink() or not root.is_dir():
        raise NoticeFailure("unsafe {} directory: {}".format(role, root))

    candidate = root
    for part in path.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise NoticeFailure("symlink is not allowed in {} path: {}".format(role, candidate))
    try:
        resolved = candidate.resolve(strict=True)
        resolved_root = root.resolve(strict=True)
    except OSError as error:
        raise NoticeFailure("missing {} file {}: {}".format(role, candidate, error))
    if not resolved.is_relative_to(resolved_root) or not candidate.is_file():
        raise NoticeFailure("expected a regular {} file: {}".format(role, candidate))
    return candidate


def license_paths(
    root: pathlib.Path, component: Mapping[str, Any]
) -> List[Tuple[str, pathlib.Path]]:
    name = component.get("name")
    files = component.get("licenseFiles")
    if not isinstance(name, str) or not name:
        raise NoticeFailure("shipped lock entry has no name")
    if not isinstance(files, list) or not files:
        raise NoticeFailure("{}: shipped component has no licenseFiles".format(name))

    licenses_root = root / "ThirdParty/licenses"
    component_root = licenses_root / name
    result = []
    for relative in files:
        candidate = safe_file(component_root, relative, "license")
        result.append((relative, candidate))
    return result


def component_records(
    root: pathlib.Path, lock: Mapping[str, Any]
) -> List[Tuple[Mapping[str, Any], List[Tuple[str, pathlib.Path]]]]:
    components = [
        item for item in lock["components"] if isinstance(item, dict) and ships_with_app(item)
    ]
    components.sort(key=lambda item: str(item.get("name", "")).casefold())
    return [(item, license_paths(root, item)) for item in components]


def copyright_lines(license_texts: Iterable[str]) -> List[str]:
    result: List[str] = []
    seen = set()
    for text in license_texts:
        for line in text.splitlines():
            stripped = line.strip()
            if (
                stripped
                and re.search(r"(?i)\bcopyright\b|©|\(c\)", stripped)
                and stripped not in seen
            ):
                seen.add(stripped)
                result.append(stripped)
    return result


def generate_html(
    root: pathlib.Path, lock: Mapping[str, Any]
) -> str:
    sections = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>APKRun Third-Party Notices</title>",
        "<style>",
        "body{font:16px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;"
        "max-width:72rem;margin:2rem auto;padding:0 1.25rem;color:#202124}",
        "h1,h2,h3{line-height:1.2}section{border-top:1px solid #bbb;padding:1rem 0}",
        "dt{font-weight:600}dd{margin:0 0 .65rem 0;overflow-wrap:anywhere}",
        "pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f5f5;"
        "padding:1rem;border-radius:.35rem}",
        "</style></head><body>",
        "<h1>APKRun Third-Party Notices</h1>",
        "<section><h2>APKRun</h2>",
        "<p>The APKRun project license has not been selected. See open question OQ-40.</p>",
        "</section>",
    ]

    for component, files in component_records(root, lock):
        name = html.escape(str(component["name"]))
        version = html.escape(str(component.get("version", "Not specified")))
        repository = html.escape(str(component.get("repository", "Not specified")))
        license_id = html.escape(str(component.get("license", "Not specified")))
        texts = [
            (relative, path.read_text(encoding="utf-8"))
            for relative, path in files
        ]
        sections.extend(
            [
                "<section>",
                "<h2>{} <small>{}</small></h2>".format(name, version),
                "<dl><dt>Repository</dt><dd>{}</dd>".format(repository),
                "<dt>SPDX license expression</dt><dd>{}</dd></dl>".format(license_id),
            ]
        )
        copyrights = copyright_lines(text for _, text in texts)
        if copyrights:
            sections.append("<h3>Copyright</h3><ul>")
            sections.extend("<li>{}</li>".format(html.escape(line)) for line in copyrights)
            sections.append("</ul>")
        if component.get("ships") == "derived" or (
            isinstance(component.get("ships"), list)
            and "derived" in component["ships"]
        ):
            derived_files = component.get("derivedFiles", [])
            if not isinstance(derived_files, list):
                raise NoticeFailure(
                    "{}: derivedFiles must be an array".format(component["name"])
                )
            sections.append("<h3>Derived files</h3><ul>")
            sections.extend(
                "<li>{}</li>".format(html.escape(str(path)))
                for path in sorted(derived_files, key=str)
            )
            sections.append("</ul>")
        for relative, text in texts:
            sections.append("<h3>{}</h3>".format(html.escape(relative)))
            sections.append("<pre>{}</pre>".format(html.escape(text)))
        sections.append("</section>")
    sections.extend(["</body></html>", ""])
    return "\n".join(sections)


def refresh_component(root: pathlib.Path, name: str) -> None:
    lock = read_lock(root)
    component = next(
        (
            item
            for item in lock["components"]
            if isinstance(item, dict) and item.get("name") == name
        ),
        None,
    )
    if component is None or component.get("kind") != "source":
        raise NoticeFailure("{} is not a pinned source component".format(name))

    checker = root / "scripts/check-lock.sh"
    if checker.is_symlink() or not checker.is_file():
        raise NoticeFailure("missing or unsafe lock validator: {}".format(checker))
    subprocess.run([str(checker), "--apply"], cwd=root, check=True)
    source_root = root / "ThirdParty/out/src"
    source = safe_directory(source_root, name, str(component.get("commit", "")))
    destination_root = root / "ThirdParty/licenses"
    license_files = component.get("licenseFiles")
    if not isinstance(license_files, list):
        raise NoticeFailure("{}: licenseFiles must be an array".format(name))
    for relative in license_files:
        source_file = safe_file(source, relative, "upstream license")
        destination = destination_root / name
        for part in pathlib.PurePosixPath(relative).parts:
            destination = destination / part
            if destination.is_symlink():
                raise NoticeFailure("refusing to replace license symlink: {}".format(destination))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, destination)


def safe_directory(root: pathlib.Path, *parts: str) -> pathlib.Path:
    if root.is_symlink() or not root.is_dir():
        raise NoticeFailure("unsafe source root: {}".format(root))
    candidate = root
    for part in parts:
        if not part or part in {".", ".."} or "/" in part or "\\" in part:
            raise NoticeFailure("unsafe source directory component: {!r}".format(part))
        candidate = candidate / part
        if candidate.is_symlink():
            raise NoticeFailure("source directory must not be a symlink: {}".format(candidate))
    if not candidate.is_dir():
        raise NoticeFailure("pinned source checkout is missing: {}".format(candidate))
    return candidate


def check_license_copies(root: pathlib.Path, lock: Mapping[str, Any]) -> None:
    component_records(root, lock)
    checker = root / "scripts/check-lock.sh"
    if checker.is_symlink() or not checker.is_file():
        raise NoticeFailure("missing or unsafe lock validator: {}".format(checker))
    subprocess.run([str(checker), "--apply"], cwd=root, check=True)
    for component in lock["components"]:
        if (
            not isinstance(component, dict)
            or component.get("kind") != "source"
            or not ships_with_app(component)
        ):
            continue
        name = component["name"]
        source = safe_directory(
            root / "ThirdParty/out/src",
            name,
            str(component.get("commit", "")),
        )
        for relative, committed in license_paths(root, component):
            upstream = safe_file(source, relative, "upstream license")
            if upstream.read_bytes() != committed.read_bytes():
                raise NoticeFailure(
                    "{}: committed license copy differs from pinned source {}".format(
                        name, relative
                    )
                )


def output_path(root: pathlib.Path, requested: str | None) -> pathlib.Path:
    if requested:
        return pathlib.Path(requested).expanduser().resolve()
    build_directory = pathlib.Path(os.environ.get("TARGET_BUILD_DIR", str(root / "build")))
    resources = os.environ.get("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    if resources:
        build_directory = build_directory / resources
    return build_directory / "ThirdPartyNotices.html"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--refresh", metavar="NAME")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    try:
        lock = read_lock(root)
        if args.refresh:
            refresh_component(root, args.refresh)
            return 0
        if args.check:
            check_license_copies(root, lock)
            print("generate-notices: pinned shipped-source license copies match")
            return 0

        destination = output_path(root, args.output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(generate_html(root, lock), encoding="utf-8")
    except (NoticeFailure, OSError, subprocess.CalledProcessError, UnicodeError) as error:
        print("generate-notices: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
