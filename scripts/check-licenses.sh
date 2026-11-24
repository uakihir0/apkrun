#!/usr/bin/env bash
# License inventory check (legal-and-licensing.md §4–§6, #94):
#   - every lock entry has an identified license and committed license files
#   - distributed (`app`, `derived`) and tooling entries use allowed licenses
#     from the lists of legal-and-licensing.md §4.2 and §4.4
#   - every resolved Swift package is a lock entry
#   - RiftVM-derived markers name the pinned commit
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${1:-$script_dir/..}" && pwd)"

python3 - "$repo_root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
failures = []


def fail(msg):
    failures.append(msg)


def read_lists():
    """Parse the `app:` and `tooling:` code blocks of legal-and-licensing.md §4."""
    doc = (root / "docs/05-development/legal-and-licensing.md").read_text(
        encoding="utf-8"
    )
    lists = {}
    for name in ("app", "tooling"):
        match = re.search(r"```text\n" + name + r":\n(.*?)```", doc, re.S)
        if not match:
            fail("legal-and-licensing.md: no `%s:` license list block" % name)
            continue
        entries = [
            line.strip()
            for line in match.group(1).splitlines()
            if line.strip() and not line.strip().startswith("(")
        ]
        lists[name] = set(entries)
    lists["tooling"] |= lists.get("app", set())
    return lists


_lists = read_lists()
APP, TOOLING = _lists.get("app", set()), _lists.get("tooling", set())


def allowed(expr, licenses):
    """Evaluate an SPDX expression per legal-and-licensing.md §4.5."""
    expr = expr.strip()
    # "Public Domain" is written as two words upstream; make it one token.
    expr = re.sub(r"Public[ -]Domain", "Public-Domain", expr)
    # Normalise parentheses.
    tokens = re.findall(r"\(|\)|[^\s()]+", expr)

    # SPDX precedence: WITH binds to its atom, AND binds tighter than OR.
    def parse_or(index):
        value, index = parse_and(index)
        while index < len(tokens) and tokens[index] == "OR":
            rhs, index = parse_and(index + 1)
            value = value or rhs
        return value, index

    def parse_and(index):
        value, index = parse_factor(index)
        while index < len(tokens) and tokens[index] == "AND":
            rhs, index = parse_factor(index + 1)
            value = value and rhs
        return value, index

    def parse_factor(index):
        if index < len(tokens) and tokens[index] == "(":
            value, index = parse_or(index + 1)
            if index < len(tokens) and tokens[index] == ")":
                index += 1
            return value, index
        atom = tokens[index]
        if index + 2 < len(tokens) and tokens[index + 1] == "WITH":
            atom = atom + " WITH " + tokens[index + 2]
            index += 2
        return atom in licenses, index + 1

    value, _ = parse_or(0)
    return value


def ships_list(component):
    ships = component.get("ships")
    values = set(ships) if isinstance(ships, list) else {ships}
    if values & {"app", "derived"}:
        return "app"
    if values == {"tooling"}:
        kind = component.get("kind")
        return "app" if kind in ("vendored", "gradle", "cargo") else "tooling"
    return None  # image, reference: no redistribution list (§4.1)


def bad_license(expr):
    if not expr or not isinstance(expr, str):
        return "missing"
    if "NOASSERTION" in expr:
        return "unresolved (%s)" % expr
    return None


lock_path = root / "ThirdParty/ThirdParty.lock.json"
lock = json.loads(lock_path.read_text(encoding="utf-8"))
components = lock.get("components", [])

for component in components:
    name = component.get("name") or "<unnamed>"
    license_expr = component.get("license")
    problem = bad_license(license_expr)
    if problem:
        fail("%s: license %s" % (name, problem))
        continue

    license_files = component.get("licenseFiles")
    if not license_files:
        fail("%s: no licenseFiles" % name)
    else:
        for entry in license_files:
            copy = root / "ThirdParty/licenses" / name / entry
            if not copy.is_file():
                fail("%s: missing committed license copy %s" % (name, copy.relative_to(root)))

    which = ships_list(component)
    if which:
        allowed_set = APP if which == "app" else TOOLING
        if not allowed(license_expr, allowed_set):
            fail(
                "%s: license `%s` is not on the %s list (legal-and-licensing.md §4)"
                % (name, license_expr, which)
            )

# Every resolved Swift package is a lock entry.
resolved = root / "Package.resolved"
lock_names = {c.get("name") for c in components if c.get("kind") == "swiftpm"}
if resolved.is_file():
    pins = json.loads(resolved.read_text(encoding="utf-8")).get("pins", [])
    for pin in pins:
        identity = pin.get("identity")
        if identity not in lock_names:
            fail("Package.resolved pin `%s` has no swiftpm lock entry" % identity)

# RiftVM-derived markers name the pinned commit (§3.1).
rift = next((c for c in components if c.get("name") == "riftvm"), None)
if rift is not None:
    pin = rift.get("commit") or (rift.get("revision") or {}).get("commit")
    marker = re.compile(r"Derived from RiftVM ([0-9a-f]{40}) \(MIT\)")
    for source in root.rglob("*"):
        if source.suffix not in {".swift", ".cpp", ".hpp", ".mm", ".h", ".c", ".cc"}:
            continue
        if "ThirdParty" in source.parts or "Derived" not in source.read_text(
            encoding="utf-8", errors="ignore"
        ):
            continue
        for match in marker.finditer(source.read_text(encoding="utf-8")):
            if pin and match.group(1) != pin:
                fail("%s: RiftVM marker names %s, not the pin %s"
                     % (source.relative_to(root), match.group(1), pin))

if failures:
    print("check-licenses: %d failure(s)" % len(failures), file=sys.stderr)
    for item in failures:
        print("  " + item, file=sys.stderr)
    sys.exit(1)
print("check-licenses: %d components OK" % len(components))
PY
