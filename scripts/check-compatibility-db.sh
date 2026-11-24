#!/usr/bin/env bash
# check-compatibility-db.sh — validates Tests/Compatibility/database/
# compatibility.json against the §10.2 format: required fields, the
# recommendedSettings key allowlist, integrations.* only to false, and
# en+ja strings on every issue. Runs in the lint job; needs only python3.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
db="$repo_root/Tests/Compatibility/database/compatibility.json"

python3 - "$db" << 'PY'
import json, re, sys

errors = []
path = sys.argv[1]
try:
    db = json.load(open(path))
except (OSError, json.JSONDecodeError) as error:
    print(f"check-compatibility-db: {path}: {error}", file=sys.stderr)
    sys.exit(1)

if db.get("schemaVersion") != 1:
    errors.append("schemaVersion must be 1")
if not isinstance(db.get("generatedAt"), str):
    errors.append("generatedAt must be a string")
entries = db.get("entries")
if not isinstance(entries, list):
    errors.append("entries must be an array")
    entries = []

ALLOWED_PREFIXES = ("window.", "input.", "integrations.")
ALLOWED_EXACT = {"update.healthCheckLaunch"}
LEVELS = {"works", "compatibilityMode", "unsupported"}
SOURCES = {"lab", "report"}
DIGEST = re.compile(r"^[0-9a-f]{64}$")

def localized(node, where):
    if not isinstance(node, dict) or "en" not in node or "ja" not in node:
        errors.append(f"{where}: needs en and ja")
    else:
        for locale in ("en", "ja"):
            if not isinstance(node[locale], str) or not node[locale]:
                errors.append(f"{where}.{locale}: empty or not a string")

for index, entry in enumerate(entries):
    where = f"entries[{index}]"
    if not isinstance(entry.get("packageID"), str) or not entry["packageID"]:
        errors.append(f"{where}.packageID: required")
    if entry.get("level") not in LEVELS:
        errors.append(f"{where}.level: must be one of {sorted(LEVELS)}")
    if entry.get("source") not in SOURCES:
        errors.append(f"{where}.source: must be one of {sorted(SOURCES)}")
    for digest in entry.get("signerDigests") or []:
        if not DIGEST.match(digest):
            errors.append(f"{where}.signerDigests: bad SHA-256 hex {digest!r}")
    codes = entry.get("versionCodes")
    if codes is not None:
        if not isinstance(codes, dict) or set(codes) != {"min", "max"}:
            errors.append(f"{where}.versionCodes: needs min and max")
        else:
            for side in ("min", "max"):
                value = codes[side]
                if value is not None and not isinstance(value, int):
                    errors.append(f"{where}.versionCodes.{side}: integer or null")
            if (isinstance(codes["min"], int) and isinstance(codes["max"], int)
                    and codes["min"] > codes["max"]):
                errors.append(f"{where}.versionCodes: min > max")
    settings = entry.get("recommendedSettings")
    if not isinstance(settings, dict):
        errors.append(f"{where}.recommendedSettings: required object")
    else:
        for key, value in settings.items():
            if key not in ALLOWED_EXACT and not key.startswith(ALLOWED_PREFIXES):
                errors.append(f"{where}.recommendedSettings: disallowed key {key!r}")
            if key.startswith("integrations.") and value is not False:
                errors.append(
                    f"{where}.recommendedSettings.{key}: integrations may only be turned off")
    for issue_index, issue in enumerate(entry.get("issues") or []):
        iw = f"{where}.issues[{issue_index}]"
        if not isinstance(issue.get("id"), str) or not issue["id"]:
            errors.append(f"{iw}.id: required")
        localized(issue.get("title"), f"{iw}.title")
        if "workaround" in issue:
            localized(issue["workaround"], f"{iw}.workaround")
    tested = entry.get("testedWith")
    if not isinstance(tested, dict) or not all(
        isinstance(tested.get(k), str) and tested[k] for k in ("apkrun", "image", "date")):
        errors.append(f"{where}.testedWith: needs apkrun, image, date")

if errors:
    for error in errors:
        print(f"check-compatibility-db: {error}", file=sys.stderr)
    sys.exit(1)
print(f"check-compatibility-db: {len(entries)} entries OK")
PY
