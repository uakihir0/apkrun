#!/usr/bin/env python3
"""Merge user-facing literals into String Catalogs and write generated tables.

Reads extracted literals from the app targets, the launcher, and the CLI,
adds missing keys to each target's Localizable.xcstrings, applies the
Japanese translations in scripts/l10n/ja.json, injects `ja` into every
errors.json message/remediation, and emits the generated Swift lookup
tables (LauncherStrings.generated.swift, CLIStrings.generated.swift) for
the targets that ship no resource bundle.

Usage: scripts/l10n/gen-strings.py [--check]
  --check only reports drift; used by scripts/check-strings.sh.
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JA = json.load(open(os.path.join(ROOT, "scripts/l10n/ja.json"), encoding="utf-8"))

# Literals handed to a user-facing text API. Extraction is intentionally
# conservative: keys are the English text itself (the xcstrings convention),
# so a literal in one of these callsites is always a catalog key.
UI_PATTERN = re.compile(
    r'(?:Text|Label|Button|Toggle|Section|Menu|Picker|NavigationLink|'
    r'\.alert|TextField|SecureField|\.help|\.navigationTitle|'
    r'\.accessibilityLabel|\.accessibilityHint|\.accessibilityValue|'
    r'String\(localized:)\s*\(\s*(?:verbatim:\s*)?"((?:[^"\\]|\\.){3,})"'
)
LAUNCHER_PATTERN = re.compile(
    r'(?:messageText|title|stringValue)\s*=\s*"((?:[^"\\]|\\.)+)"'
    r'|addButton\(withTitle:\s*"((?:[^"\\]|\\.)+)"'
    r'|alert\.informativeText\s*=\s*"((?:[^"\\]|\\.)+)"'
    r'|LauncherStrings\.text\("((?:[^"\\]|\\.)+)"'
)
CLI_PATTERNS = [
    re.compile(r'(?:Output\.write(?:LogLine)?|print|FileHandle\.standardError\.write)\s*\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'lines\.append\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'return\s+\(?\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\+=\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'return\s*\(\["((?:[^"\\]|\\.)+)"'),
    re.compile(r'^\s*"((?:[^"\\]|\\.)+)",?\s*$', re.M),
    re.compile(r'=\s*\["((?:[^"\\]|\\.)+)"'),
]


def cli_literal_ok(group):
    """Keep only literals a person reads in `apkrun` human output."""
    if group.lstrip().startswith("{") and '\\"' in group:
        return False
    if not re.search(r"[A-Za-z]{3,}", group):
        return False
    # bare identifiers, enum raw values, keys, codes
    if re.match(r"^[a-z][a-zA-Z0-9._~{}-]*$", group):
        return False
    # paths, dates, regexes, format fragments
    if re.match(r"^[a-zA-Z0-9./:_~{}\\\-]+$", group):
        return False
    if "\\u{" in group or re.match(r"^[yYmMdDhHsS\-:./\\]+$", group):
        return False
    if group.startswith(("apkrun://", "~/", "./", "/")):
        return False
    return True


def literals(pattern, files, min_alpha=4, keep=None):
    found = set()
    patterns = pattern if isinstance(pattern, list) else [pattern]
    for path in files:
        if "/Tests/" in path or ".generated." in path:
            continue
        source = open(path, encoding="utf-8").read()
        for pat in patterns:
            for match in pat.finditer(source):
                for group in match.groups():
                    if not group or not re.search(r"[A-Za-z]{%d,}" % min_alpha, group):
                        continue
                    # --json output is never localized (cli.md §6.3)
                    if group.lstrip().startswith("{") and '\\"' in group:
                        continue
                    if keep and not keep(group):
                        continue
                    found.add(group)
    return found


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def merge_catalog(path, keys, keys_files, check, format_keys=False):
    if os.path.exists(path):
        catalog = json.load(open(path, encoding="utf-8"))
    else:
        catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    strings = catalog.setdefault("strings", {})
    raw_by_fmt = {}
    if format_keys:
        # SwiftUI keys interpolated literals as `Ready: %@`, not `Ready: \(v)`.
        strings.update(
            {to_format_key(k): v for k, v in list(strings.items())}
        )
        for old in [k for k in list(strings) if "\\(" in k]:
            del strings[old]
        raw_by_fmt = {to_format_key(k): k for k in keys if "\\(" in k}
        keys = {to_format_key(k) if "\\(" in k else k for k in keys}
    corpus = "".join(
        open(p, encoding="utf-8").read()
        for p in keys_files
        if "/Tests/" not in p and ".generated." not in p
    )
    missing, untranslated = [], []
    for key in sorted(keys | set(strings)):
        raw = raw_by_fmt.get(key, key)
        entry = strings.setdefault(key, {"localizations": {}})
        locs = entry.setdefault("localizations", {})
        locs.setdefault("en", unit(key))
        ja_value = JA["strings"].get(raw)
        if ja_value and format_keys:
            ja_value = apply_specs(ja_value, specifiers(raw))
        if ja_value:
            current = locs.get("ja", {}).get("stringUnit", {})
            if current.get("value") != ja_value or current.get("state") != "translated":
                locs["ja"] = unit(ja_value)
        elif locs.get("ja", {}).get("stringUnit", {}).get("state") == "translated":
            pass  # a ja translation exists that is not in ja.json — keep it
        else:
            untranslated.append(key)
        if raw not in corpus:
            missing.append(key)  # catalog key no longer referenced in the tree
    if check:
        return missing, untranslated
    with open(path, "w", encoding="utf-8") as out:
        json.dump(catalog, out, ensure_ascii=False, indent=2, sort_keys=True)
        out.write("\n")
    return missing, untranslated


def inject_errors(path, check):
    catalog = json.load(open(path, encoding="utf-8"))
    missing = []
    for entry in catalog["errors"]:
        ja_entry = JA["errors"].get(entry["code"])
        if not ja_entry:
            if "message" in entry:
                missing.append(entry["code"])
            continue
        if "message" in entry:
            entry["message"]["ja"] = ja_entry["message"]
        if "remediation" in entry and ja_entry.get("remediation"):
            entry["remediation"]["ja"] = ja_entry["remediation"]
        for name, variant in (entry.get("variants") or {}).items():
            vja = JA.get("variants", {}).get("%s.%s" % (entry["code"], name))
            if not vja:
                if variant.get("message"):
                    missing.append("%s.%s" % (entry["code"], name))
                continue
            if variant.get("message"):
                variant["message"]["ja"] = vja["message"]
            if variant.get("remediation") and vja.get("remediation"):
                variant["remediation"]["ja"] = vja["remediation"]
    if check:
        return missing
    with open(path, "w", encoding="utf-8") as out:
        json.dump(catalog, out, ensure_ascii=False, indent=2, sort_keys=False)
        out.write("\n")
    return missing


def swift_literal(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"')\
        .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'


def split_interpolated(key):
    """Split a source literal into literal parts around \\( expr ) groups."""
    parts, i = [], 0
    while i < len(key):
        start = key.find("\\(", i)
        if start < 0:
            break
        parts.append(key[i:start])
        depth, j = 1, start + 2
        while j < len(key) and depth:
            if key[j] == "(":
                depth += 1
            elif key[j] == ")":
                depth -= 1
            j += 1
        i = j
    parts.append(key[i:])
    return parts


def interpolated_exprs(key):
    """Return the \\( expr ) fragments of a source literal, in order."""
    exprs, i = [], 0
    while True:
        start = key.find("\\(", i)
        if start < 0:
            break
        depth, j = 1, start + 2
        while j < len(key) and depth:
            if key[j] == "(":
                depth += 1
            elif key[j] == ")":
                depth -= 1
            j += 1
        exprs.append(key[start + 2:j - 1])
        i = j
    return exprs


NUMERIC_HINT = re.compile(
    r"Int\(|\.count|bytes|Bytes|framesPerSecond|droppedFrames|\.rounded|"
    r"percent|versionCode"
)


def specifiers(key):
    """SwiftUI format specifiers for a literal's interpolations (%lld/%@)."""
    return [
        "%lld" if NUMERIC_HINT.search(e) else "%@"
        for e in interpolated_exprs(key)
    ]


def apply_specs(text, specs):
    """Replace each \\(...) placeholder of text with a format specifier."""
    parts = split_interpolated(text)
    return "".join(
        part + (specs[n] if n < len(specs) else "")
        for n, part in enumerate(parts)
    )


def to_format_key(key):
    """xcstrings lookup key for an interpolated literal (SwiftUI uses %@)."""
    return apply_specs(key, specifiers(key)) if "\\(" in key else key


def eval_literal(key):
    """Evaluate the escapes of a captured source literal to its runtime text."""
    out, i = [], 0
    while i < len(key):
        if key[i] == "\\" and i + 1 < len(key):
            c = key[i + 1]
            simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                      "\\": "\\", '"': '"', "'": "'"}
            if c in simple:
                out.append(simple[c]); i += 2; continue
            if c == "u" and key[i + 2] == "{":
                end = key.index("}", i)
                out.append(chr(int(key[i + 3:end], 16))); i = end + 1; continue
            out.append(key[i:i + 2]); i += 2
        else:
            out.append(key[i]); i += 1
    return "".join(out)


def emit_table(path, enum_name, keys):
    """Write the generated en/ja lookup table for bundle-less executables.

    Call sites pass the *interpolated* runtime string, so plain keys are an
    exact dictionary hit and interpolated literals are matched by a regex
    built from the literal segments; captured runs fill the ja template's
    \\(...) placeholders in order (ja.json must preserve placeholder order).
    """
    regexes = []
    for key in sorted(keys):
        ja_value = JA["strings"].get(key)
        if not ja_value or "\\(" not in key:
            continue
        parts = split_interpolated(key)
        # A pattern must have real literal evidence: a meaningful leading
        # literal (it pins the match to message starts) or enough literal
        # text overall. Thin keys like `\(key)=\(value)` would emit
        # `^(.*?)=(.*?)$` and rewrite any `x=y` or JSON line.
        leading = eval_literal(parts[0]).strip()
        if len(leading) < 4 and sum(len(p) for p in parts) < 12:
            continue
        pattern = "^" + "(.*?)".join(
            re.escape(eval_literal(p)) for p in parts
        ) + "$"
        regexes.append((pattern, ja_value, sum(len(p) for p in parts)))


    lines = [
        "// Generated by scripts/l10n/gen-strings.py. Do not edit.",
        "",
        "import Foundation",
        "",
        "/// Localized human strings for the %s target." % enum_name.removesuffix("Strings"),
        "/// Keyed by the English text; resolves the runtime language from",
        "/// Locale.preferredLanguages (ja first, then English fallback).",
        "enum %s {" % enum_name,
        "    /// Test hook: when set, overrides the process locale for `text(_:)` resolution.",
        "    nonisolated(unsafe) static var forcedLanguage: String?",
        "",
        "    static func text(_ key: String) -> String {",
        "        let ja = (forcedLanguage ?? Locale.preferredLanguages.first ?? \"en\")",
        "            .hasPrefix(\"ja\")",
        "        guard ja else { return enTable[key] ?? key }",
        "        // Localize line by line so composed output (tables, doctor rows) is",
        "        // covered even when the whole block is not a single catalog key.",
        "        return key.split(separator: \"\\n\", omittingEmptySubsequences: false)",
        "            .map { line in localizedLine(String(line)) }",
        "            .joined(separator: \"\\n\")",
        "    }",
        "",
        "    private static func localizedLine(_ key: String) -> String {",
        "        if let value = jaTable[key] { return value }",
        "        let range = NSRange(key.startIndex..., in: key)",
        "        for (pattern, template) in interpolatedJA {",
        "            guard let match = pattern.firstMatch(in: key, range: range) else { continue }",
        "            let captures = (1..<match.numberOfRanges).map {",
        "                match.range(at: $0).location != NSNotFound",
        "                    ? String(key[Range(match.range(at: $0), in: key)!]) : String()",
        "            }",
        "            return splice(template, captures)",
        "        }",
        "        return key",
        "    }",
        "",
        "    private static func splice(_ template: String, _ captures: [String]) -> String {",
        "        var result = template",
        "        for capture in captures {",
        "            guard let range = result.range(of: #\"\\\\([^)]*?\\)\"#, options: .regularExpression) else { break }",
        "            result.replaceSubrange(range, with: capture)",
        "        }",
        "        return result",
        "    }",
        "",
        "    private static let enTable: [String: String] = [",
    ]
    for key in sorted(keys):
        runtime = eval_literal(key)
        lines.append("        %s: %s," % (swift_literal(runtime), swift_literal(runtime)))
    lines += ["    ]", "", "    private static let jaTable: [String: String] = ["]
    for key in sorted(keys):
        ja_value = JA["strings"].get(key)
        if ja_value:
            lines.append("        %s: %s," % (swift_literal(eval_literal(key)),
                                              swift_literal(eval_literal(ja_value))))
    lines += ["    ]", "",
              "    private static let interpolatedJA: [(NSRegularExpression, String)] = ["]
    regexes.sort(key=lambda entry: -entry[2])
    for pattern, template, _ in regexes:
        lines.append("        (try! NSRegularExpression(pattern: %s), %s),"
                     % (swift_literal(pattern), swift_literal(template)))
    lines += ["    ]", "}", ""]
    with open(path, "w", encoding="utf-8") as out:
        out.write("\n".join(lines))


def main():
    check = "--check" in sys.argv
    os.chdir(ROOT)
    problems = []

    app_keys = literals(UI_PATTERN, glob.glob("Apps/APKRun/**/*.swift", recursive=True))
    stale, untr = merge_catalog("Apps/APKRun/Localizable.xcstrings", app_keys, glob.glob("Apps/APKRun/**/*.swift", recursive=True), check, format_keys=True)
    problems += [("APKRun", "stale", k) for k in stale] + [("APKRun", "untranslated", k) for k in untr]

    bar_keys = literals(UI_PATTERN, glob.glob("Apps/APKRunMenuBar/**/*.swift", recursive=True))
    stale, untr = merge_catalog("Apps/APKRunMenuBar/Localizable.xcstrings", bar_keys, glob.glob("Apps/APKRunMenuBar/**/*.swift", recursive=True), check, format_keys=True)
    problems += [("MenuBar", "stale", k) for k in stale] + [("MenuBar", "untranslated", k) for k in untr]

    launcher_keys = literals(LAUNCHER_PATTERN, glob.glob("Apps/APKRunLauncher/*.swift"))
    stale, untr = merge_catalog("Apps/APKRunLauncher/Localizable.xcstrings", launcher_keys, glob.glob("Apps/APKRunLauncher/*.swift"), check)
    problems += [("Launcher", "stale", k) for k in stale] + [("Launcher", "untranslated", k) for k in untr]
    if not check:
        emit_table("Apps/APKRunLauncher/LauncherStrings.generated.swift", "LauncherStrings", launcher_keys)

    cli_keys = literals(CLI_PATTERNS, glob.glob("CLI/apkrun/**/*.swift", recursive=True), min_alpha=3, keep=cli_literal_ok)
    stale, untr = merge_catalog("CLI/apkrun/Localizable.xcstrings", cli_keys, glob.glob("CLI/apkrun/**/*.swift", recursive=True), check)
    problems += [("CLI", "stale", k) for k in stale] + [("CLI", "untranslated", k) for k in untr]
    if not check:
        emit_table("CLI/apkrun/CLIStrings.generated.swift", "CLIStrings", cli_keys)

    missing = inject_errors("Packages/DiagnosticsCore/ErrorCatalog/errors.json", check)
    problems += [("errors.json", "untranslated", k) for k in missing]

    if check:
        for scope, kind, key in sorted(problems):
            print("%s %s: %s" % (scope, kind, key))
    else:
        print("catalogs merged; %d lint items" % len(problems))
    return 0


if __name__ == "__main__":
    sys.exit(main())
