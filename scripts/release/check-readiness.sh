#!/usr/bin/env bash
# check-readiness.sh — evaluates the ten v1.0 release criteria of
# docs/04-plan/roadmap.md §3.6 (#95). Prints one line per criterion as
# `PASS|FAIL|MANUAL <n>. <name> — <evidence>` and exits non-zero when any
# criterion fails. MANUAL marks a criterion that only a person on the
# reference Mac can settle; it does not fail the run.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

python3 - "$repo_root" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
results = []  # (status, number, name, evidence)


def report(status, number, name, evidence):
    results.append((status, number, name, evidence))


def gh(*args):
    """Run gh; return parsed JSON or None when gh is unavailable."""
    try:
        proc = subprocess.run(
            ["gh", *args], capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def open_issues_with_labels(*labels):
    """Issue numbers open under any of the labels; None when gh fails."""
    numbers = set()
    for label in labels:
        issues = gh("issue", "list", "--label", label, "--state", "open",
                    "--json", "number", "--limit", "100")
        if issues is None:
            return None
        numbers.update(issue["number"] for issue in issues)
    return numbers


def all_issue_states():
    issues = gh("issue", "list", "--state", "all", "--json",
                "number,state", "--limit", "500")
    if issues is None:
        return None
    return {issue["number"]: issue["state"].upper() for issue in issues}


# --- 1. Requirements ---------------------------------------------------
must_tasks = {}
version_re = re.compile(r"^\d+(?:\.\d+)+$")
range_re = re.compile(r"#(\d+)\s*[–-]\s*#?(\d+)")
requirements = (root / "docs/00-product/requirements.md").read_text(encoding="utf-8")
columns = {}
for line in requirements.splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if "ID" in cells and "Pri" in cells:
        # Each requirements table places Pri/Ver/Tasks at its own offsets.
        columns = {name: cells.index(name) for name in ("Pri", "Ver", "Tasks") if name in cells}
        continue
    if len(cells) < 5 or not cells[0].startswith(("FR-", "NFR-")) or len(columns) < 3:
        continue
    pri, ver, tasks = cells[columns["Pri"]], cells[columns["Ver"]], cells[columns["Tasks"]]
    if pri != "Must" or not version_re.match(ver) or float(ver) > 1.0:
        continue
    for lo, hi in range_re.findall(tasks):
        for number in range(int(lo), int(hi) + 1):
            must_tasks[number] = cells[0]
    for number in re.findall(r"#(\d+)", range_re.sub("", tasks)):
        must_tasks[int(number)] = cells[0]

states = all_issue_states()
if states is None:
    report("MANUAL", 1, "Requirements",
           "gh unavailable; verify every Must task (version <= 1.0) is closed")
else:
    open_must = sorted(
        f"#{n} ({req})" for n, req in must_tasks.items()
        if states.get(n) == "OPEN"
    )
    if open_must:
        report("FAIL", 1, "Requirements",
               "Must tasks still open: " + ", ".join(open_must))
    else:
        report("PASS", 1, "Requirements",
               f"{len(must_tasks)} Must tasks closed; list unfinished Should items in the release notes")

# --- 2. Performance ----------------------------------------------------
report("MANUAL", 2, "Performance",
       "attach an apkrun-perf run on the reference Mac against requirements.md §2 (or a revising ADR)")

# --- 3. Reliability ----------------------------------------------------
nightlies = gh("run", "list", "--workflow", "nightly.yml", "--limit", "1",
               "--json", "conclusion,headSha")
nightly_failures = open_issues_with_labels("nightly-failure")
if nightlies is None or nightly_failures is None:
    report("MANUAL", 3, "Reliability",
           "gh unavailable; attach the release smoke matrix (test-strategy.md §9.2) results")
elif nightly_failures:
    report("FAIL", 3, "Reliability",
           "open nightly-failure issues: " + ", ".join(f"#{n}" for n in sorted(nightly_failures)))
elif nightlies and nightlies[0].get("conclusion") not in ("success", None):
    report("FAIL", 3, "Reliability",
           f"latest nightly on {nightlies[0].get('headSha', '?')[:8]} concluded {nightlies[0].get('conclusion')}")
else:
    report("MANUAL", 3, "Reliability",
           "latest nightly green and no nightly-failure issues; attach the T3 smoke matrix results")

# --- 4. Compatibility --------------------------------------------------
db_path = root / "Tests/Compatibility/database/compatibility.json"
try:
    db = json.loads(db_path.read_text(encoding="utf-8"))
    entries = {entry["packageID"]: entry for entry in db.get("entries", [])}
except (OSError, json.JSONDecodeError, KeyError):
    entries = {}

application_re = re.compile(r'applicationId\s*=\s*"([^"]+)"')
fixtures = []
for path in sorted((root / "Tests/Fixtures/AndroidApps").iterdir()):
    gradle = path / "build.gradle.kts"
    if not (path.is_dir() and gradle.exists()):
        continue
    match = application_re.search(gradle.read_text(encoding="utf-8"))
    if match:
        fixtures.append((path.name, match.group(1)))
missing = []
not_native = []
for fixture, package_id in fixtures:
    entry = entries.get(package_id)
    if entry is None:
        missing.append(fixture)
    elif entry.get("level") != "works":
        not_native.append(f"{fixture}={entry.get('level')}")
if missing:
    report("FAIL", 4, "Compatibility",
           "fixtures missing from the database: " + ", ".join(missing))
elif not_native:
    report("FAIL", 4, "Compatibility",
           "fixtures not at nativeLike/works: " + ", ".join(not_native))
else:
    report("PASS", 4, "Compatibility",
           f"all {len(fixtures)} fixtures are `works` in Tests/Compatibility/database/compatibility.json")

# --- 5. Security -------------------------------------------------------
security_issues = open_issues_with_labels("fuzz-crash", "security")
sr_open = []
security_model = (root / "docs/01-architecture/security-model.md").read_text(encoding="utf-8")
for line in security_model.splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) >= 4 and cells[0].startswith("SR-"):
        status = cells[3].lower()
        # A follow-up must name its tracking task; a bare follow-up is open.
        if status.startswith("follow-up") and not re.search(r"#\d+", cells[3]):
            sr_open.append(f"{cells[0]} (follow-up has no task)")
        elif not (status.startswith("closed") or status.startswith("follow-up")):
            sr_open.append(cells[0])
if security_issues is None:
    report("MANUAL", 5, "Security",
           "gh unavailable; verify no open fuzz-crash/security issues and security-model.md §9 manually")
elif security_issues or sr_open:
    parts = []
    if security_issues:
        parts.append("open issues: " + ", ".join(f"#{n}" for n in sorted(security_issues)))
    if sr_open:
        parts.append("unsettled review items: " + ", ".join(sr_open))
    report("FAIL", 5, "Security", "; ".join(parts))
else:
    report("PASS", 5, "Security",
           "no open fuzz-crash/security issues; every §9 review item is closed or has a non-High follow-up")

# --- 6. Distribution ---------------------------------------------------
report("MANUAL", 6, "Distribution",
       "attach Developer ID signature, notarization + stapler output, the signed appcast and image feed on the production host (OQ-01), and a distribution wrapper check (#89)")

# --- 7. Legal ----------------------------------------------------------
licenses = subprocess.run(
    ["bash", str(root / "scripts/check-licenses.sh"), str(root)],
    capture_output=True, text=True,
)
if licenses.returncode == 0:
    report("PASS", 7, "Legal", "check-licenses.sh passes; confirm the §11 checklist and R-10 outcome (C10-8)")
else:
    report("FAIL", 7, "Legal", licenses.stderr.strip().splitlines()[-1] if licenses.stderr.strip() else "check-licenses.sh failed")

# --- 8. Localization and accessibility ---------------------------------
strings = subprocess.run(
    ["bash", str(root / "scripts/check-strings.sh")], cwd=root,
    capture_output=True, text=True,
)
if strings.returncode == 0:
    report("MANUAL", 8, "Localization and accessibility",
           "check-strings.sh passes; attach the VoiceOver checklist results (NFR-L10N-01/02, #93)")
else:
    report("FAIL", 8, "Localization and accessibility",
           strings.stderr.strip().splitlines()[-1] if strings.stderr.strip() else "check-strings.sh failed")

# --- 9. Diagnostics ----------------------------------------------------
report("MANUAL", 9, "Diagnostics",
       "attach `apkrun doctor` output showing every FR-OPS-01 failure class and a secret-free boot-failure bundle (FR-OPS-02)")

# --- 10. Risks and questions -------------------------------------------
risk_failures = []
risks = (root / "docs/04-plan/risks.md").read_text(encoding="utf-8")
for line in risks.splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) >= 5 and cells[0].startswith("R-"):
        impact, status = cells[2], cells[4].lower()
        if impact == "High" and status.startswith("open") and "fallback" not in status:
            risk_failures.append(f"{cells[0]} has no accepted fallback")

question_failures = []
questions = (root / "docs/04-plan/open-questions.md").read_text(encoding="utf-8")
for line in questions.splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) >= 6 and cells[0].startswith("OQ-"):
        kind, deadline, status = cells[2], cells[3].lower(), cells[5].lower()
        not_due = any(marker in deadline for marker in ("after v1.0", "post-v1", "feedback"))
        if kind == "Decision" and status == "open" and not not_due:
            question_failures.append(f"{cells[0]} (deadline: {cells[3]})")

if risk_failures or question_failures:
    report("FAIL", 10, "Risks and questions", "; ".join(risk_failures + question_failures))
else:
    report("PASS", 10, "Risks and questions",
           "no open High-impact risk without a fallback; no open Decision due at or before v1.0")

# --- report -------------------------------------------------------------
failed = 0
for status, number, name, evidence in results:
    print(f"{status:<6} {number}. {name} — {evidence}")
    if status == "FAIL":
        failed += 1
if failed:
    print(f"check-readiness: {failed} criterion(a) failing", file=sys.stderr)
    sys.exit(1)
PY
