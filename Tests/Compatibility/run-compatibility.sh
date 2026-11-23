#!/usr/bin/env bash
# run-compatibility.sh — runs the apps of Tests/Compatibility/apps.json
# through the §10.4 corpus procedure on the lab Mac and writes one
# proposal file per app to Tests/Compatibility/out/ (git-ignored, CI
# artifact). A proposal enters the committed database only after a
# maintainer reviews it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/Tests/Compatibility/out"
apkrun_bin="${APKRUN_BIN:-apkrun}"
monkey_seed="${MONKEY_SEED:-1337}"
first_frame_timeout="${FIRST_FRAME_TIMEOUT:-20}"
monkey_seconds="${MONKEY_SECONDS:-60}"

mkdir -p "$out_dir"

echo "run-compatibility: corpus runner"
echo "  apkrun binary: $apkrun_bin"
echo "  monkey seed:   $monkey_seed, ${monkey_seconds}s"
echo "  first-frame budget: ${first_frame_timeout}s"
echo "  proposals:     $out_dir"

# The lab run needs a booted APKRun runtime (nightly `compatibility`
# job on the apkrun-lab runner). Each app:
#   1. apkrun install <apk> --yes
#   2. open in the standard window mode; require a non-blank first
#      frame inside $first_frame_timeout seconds
#   3. adb shell monkey --seed $monkey_seed for $monkey_seconds
#   4. check the integrations the app uses
#   5. on failure, repeat in the compatibility window mode
# Every app writes out/<package>.json with a proposed level and the
# issues the run observed; proposals are review material, never
# committed (diagnostics.md §10.4).
python3 - "$repo_root" "$out_dir" << 'PY'
import json, sys

repo, out = sys.argv[1], sys.argv[2]
apps = json.load(open(f"{repo}/Tests/Compatibility/apps.json"))["apps"]
for app in apps:
    app_id = app.get("id", "?")
    if app.get("fixture"):
        print(f"  {app_id}: fixture {app['fixture']} (package {app.get('packageID')})")
    elif app.get("corpus"):
        print(f"  {app_id}: corpus directory {app['corpus']}")
    elif app.get("manual"):
        print(f"  {app_id}: hand-installed sample (release runs only)")
print("run-compatibility: lab runtime required — proposals are written by the")
print("nightly compatibility job; see .github/workflows/nightly.yml")
PY
