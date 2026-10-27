#!/usr/bin/env python3
"""Generate the launcher's bundled strings from its string catalog."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG_PATH = REPOSITORY_ROOT / "Apps/APKRunLauncher/Localizable.xcstrings"
OUTPUT_PATH = REPOSITORY_ROOT / "Apps/APKRunLauncher/LauncherStrings.generated.swift"


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def render(catalog: dict[str, object]) -> str:
    source_language = catalog.get("sourceLanguage")
    strings = catalog.get("strings")
    if not isinstance(source_language, str) or not isinstance(strings, dict) or not strings:
        raise ValueError("catalog must define a source language and at least one string")

    translations: dict[str, dict[str, str]] = {}
    supported_languages = {source_language}
    for key, entry in sorted(strings.items()):
        if not isinstance(key, str) or not isinstance(entry, dict):
            raise ValueError("every catalog entry must be a string key and object")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            raise ValueError(f"{key}: missing localizations")
        values: dict[str, str] = {}
        for language, localization in sorted(localizations.items()):
            if not isinstance(language, str) or not isinstance(localization, dict):
                raise ValueError(f"{key}: invalid localization")
            unit = localization.get("stringUnit")
            value = unit.get("value") if isinstance(unit, dict) else None
            if not isinstance(value, str):
                raise ValueError(f"{key}/{language}: missing string value")
            values[language] = value
        if source_language not in values:
            raise ValueError(f"{key}: source language {source_language} is missing")
        translations[key] = values
        supported_languages.update(values)

    lines = [
        "import Foundation",
        "",
        "enum LauncherStrings {",
        "    static let supportedLanguages = ["
        + ", ".join(swift_string(value) for value in sorted(supported_languages))
        + "]",
        "",
        "    private static let translations: [String: [String: String]] = [",
    ]
    for key, values in translations.items():
        lines.append(f"        {swift_string(key)}: [")
        for language, value in values.items():
            lines.append(f"            {swift_string(language)}: {swift_string(value)},")
        lines.append("        ],")
    lines.extend(
        [
            "    ]",
            "",
            "    static func text(",
            "        _ key: String,",
            "        locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? \"en\"),",
            "        arguments: [CVarArg] = []",
            "    ) -> String {",
            "        let language = locale.language.languageCode?.identifier ?? \"en\"",
            "        let template = translations[key]?[language] ?? translations[key]?[\"en\"] ?? key",
            "        guard !arguments.isEmpty else { return template }",
            "        return String(format: template, locale: locale, arguments: arguments)",
            "    }",
            "",
            "    static func title(for action: LauncherAction) -> String {",
            "        let key: String",
            "        switch action {",
            "        case .getAPKRun:",
            "            key = \"launcher.action.getAPKRun\"",
            "        case .openAPKRun:",
            "            key = \"launcher.action.openAPKRun\"",
            "        case .checkForUpdates:",
            "            key = \"launcher.action.checkForUpdates\"",
            "        case .updateMacApp:",
            "            key = \"launcher.action.updateMacApp\"",
            "        case .tryAgain:",
            "            key = \"launcher.action.tryAgain\"",
            "        }",
            "        return text(key)",
            "    }",
            "",
            "    static var quit: String { text(\"launcher.action.quit\") }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if the checked-in Swift is stale")
    parser.add_argument("--catalog", type=pathlib.Path, default=CATALOG_PATH)
    parser.add_argument("--output", type=pathlib.Path, default=OUTPUT_PATH)
    arguments = parser.parse_args()

    try:
        catalog = json.loads(arguments.catalog.read_text(encoding="utf-8"))
        generated = render(catalog)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"generate-launcher-strings: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        try:
            current = arguments.output.read_text(encoding="utf-8")
        except OSError as error:
            print(f"generate-launcher-strings: {error}", file=sys.stderr)
            return 1
        if current != generated:
            print(
                f"generate-launcher-strings: {arguments.output} is stale; regenerate it",
                file=sys.stderr,
            )
            return 1
        return 0

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
