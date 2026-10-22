#!/usr/bin/env bash
# Run a committed APKRun AOSP build on the configured Linux builder (#36).
set -euo pipefail

usage() {
    cat <<'USAGE'
usage: scripts/aosp/remote-build.sh --revision <full-commit-sha> --variant userdebug|user

Set APKRUN_AOSP_BUILDER to user@host. The revision must be reachable from
origin; only that committed revision is sent to the builder.
USAGE
}

fail() {
    printf 'remote-build: %s\n' "$1" >&2
    exit "${2:-1}"
}

revision=""
variant=""
while (($# > 0)); do
    case "$1" in
        --revision)
            (($# >= 2)) || { usage >&2; exit 64; }
            revision="$2"
            shift 2
            ;;
        --variant)
            (($# >= 2)) || { usage >&2; exit 64; }
            variant="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a full lowercase 40-character Git commit SHA" 64
[[ "$variant" == "userdebug" || "$variant" == "user" ]] || fail "--variant must be userdebug or user" 64
[[ "$variant" != "user" ]] \
    || fail "user builds are disabled until OQ-36 defines the release signing flow; use --variant userdebug" 78

builder="${APKRUN_AOSP_BUILDER:-}"
[[ -n "$builder" ]] || fail "set APKRUN_AOSP_BUILDER to an SSH target such as user@aosp-builder" 78
[[ "$builder" =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || fail "APKRUN_AOSP_BUILDER contains unsupported characters" 78

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
origin_url="$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null)" \
    || fail "the current checkout has no origin remote"

python3 - "$origin_url" <<'PY' >/dev/null \
    || fail "origin must be a credential-free GitHub HTTPS or SSH URL"
import re
import sys

if not (
    re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?/?", sys.argv[1])
    or re.fullmatch(r"git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?/?", sys.argv[1])
):
    raise SystemExit(1)
PY

git -C "$repo_root" cat-file -e "${revision}^{commit}" 2>/dev/null \
    || fail "revision $revision is not present in this checkout" 64
git -C "$repo_root" fetch --quiet --no-tags origin '+refs/heads/*:refs/remotes/origin/*' \
    || fail "could not refresh origin branch references"
remote_branches="$(git -C "$repo_root" for-each-ref --contains "$revision" --format='%(refname)' refs/remotes/origin)"
[[ -n "$remote_branches" ]] \
    || fail "revision $revision is not reachable from an origin branch; push it before building" 64

command -v ssh >/dev/null 2>&1 || fail "ssh is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

printf -v remote_revision '%q' "$revision"
printf -v remote_variant '%q' "$variant"
printf -v remote_origin '%q' "$origin_url"
remote_command="bash -s -- $remote_revision $remote_variant $remote_origin"

remote_output="$(
    ssh -o BatchMode=yes -- "$builder" "$remote_command" <<'REMOTE_SCRIPT'
set -euo pipefail

revision="$1"
variant="$2"
origin_url="$3"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { printf 'remote-build: invalid revision\n' >&2; exit 64; }
[[ "$variant" == userdebug || "$variant" == user ]] || { printf 'remote-build: invalid variant\n' >&2; exit 64; }
[[ "$origin_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?/?$ \
    || "$origin_url" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?/?$ ]] \
    || { printf 'remote-build: rejected repository URL\n' >&2; exit 64; }
[[ "$(id -u)" -ne 0 ]] || { printf 'remote-build: SSH builder account must not be root\n' >&2; exit 78; }
command -v git >/dev/null 2>&1 || { printf 'remote-build: git is missing on the builder host\n' >&2; exit 78; }
command -v docker >/dev/null 2>&1 || { printf 'remote-build: Docker is missing on the builder host\n' >&2; exit 78; }

aosp_root="$HOME/aosp"
cache_root="$HOME/.cache/apkrun-aosp"
source_root="$cache_root/source"
container_home="$cache_root/container-home"
logs_dir="$aosp_root/logs"
[[ ! -L "$aosp_root" && ! -L "$cache_root" && ! -L "$source_root" && ! -L "$logs_dir" ]] \
    || { printf 'remote-build: AOSP paths must not be symlinks\n' >&2; exit 78; }
mkdir -p "$aosp_root" "$cache_root" "$container_home"
[[ ! -L "$aosp_root" && ! -L "$cache_root" && ! -L "$source_root" ]] \
    || { printf 'remote-build: AOSP paths must not be symlinks\n' >&2; exit 78; }
mkdir -p "$logs_dir"

if [[ ! -d "$source_root/.git" ]]; then
    git clone --filter=blob:limit=10M "$origin_url" "$source_root"
else
    configured_origin="$(git -C "$source_root" config --get remote.origin.url)"
    [[ "$configured_origin" == "$origin_url" ]] \
        || { printf 'remote-build: cached APKRun checkout uses a different origin\n' >&2; exit 78; }
fi
git -C "$source_root" fetch --quiet --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
git -C "$source_root" cat-file -e "${revision}^{commit}"
branches="$(git -C "$source_root" for-each-ref --contains "$revision" --format='%(refname)' refs/remotes/origin)"
[[ -n "$branches" ]] \
    || { printf 'remote-build: requested revision is not reachable from origin\n' >&2; exit 64; }
git -C "$source_root" checkout --quiet --detach "$revision"
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]] \
    || { printf 'remote-build: cached checkout has tracked changes or untracked files\n' >&2; exit 78; }

docker build --platform linux/amd64 \
    --tag apkrun-aosp-builder \
    --file "$source_root/scripts/aosp/builder.Dockerfile" \
    "$source_root/scripts/aosp"
image_digest="$(docker image inspect --format '{{.Id}}' apkrun-aosp-builder)"
[[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { printf 'remote-build: Docker returned an invalid image digest\n' >&2; exit 1; }

docker_args=(
    run --rm
    --user "$(id -u):$(id -g)"
    --workdir /work/aosp
    --mount "type=bind,source=$aosp_root,target=/work/aosp"
    --mount "type=bind,source=$source_root,target=/work/apkrun"
    --mount "type=bind,source=$container_home,target=/work/home"
    --env HOME=/work/home
    --env APKRUN_SOURCE_DIR=/work/apkrun
    --env APKRUN_AOSP_ROOT=/work/aosp
    --env "APKRUN_BUILDER_IMAGE_DIGEST=$image_digest"
    --env "APKRUN_CI=${APKRUN_CI:-0}"
)
build_log="$(mktemp "$logs_dir/.apkrun-build.XXXXXX")"
trap '[[ ! -e "$build_log" ]] || rm -f "$build_log"' EXIT
if ! docker "${docker_args[@]}" apkrun-aosp-builder \
    /work/apkrun/scripts/aosp/build-product.sh \
    --revision "$revision" --variant "$variant" >"$build_log" 2>&1; then
    failed_number="$(sed -n 's/^APKRUN_BUILD_NUMBER=//p' "$build_log" | tail -n 1)"
    if [[ "$failed_number" =~ ^ar[0-9]{6,}$ && ! -e "$logs_dir/$failed_number.log" ]]; then
        final_log="$logs_dir/$failed_number.log"
    else
        final_log="$logs_dir/failed-$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}.log"
    fi
    mv "$build_log" "$final_log"
    tail -n 80 "$final_log" >&2 || true
    printf 'remote-build: build failed; full log: %s\n' "$final_log" >&2
    exit 1
fi

build_number="$(sed -n 's/^APKRUN_BUILD_NUMBER=//p' "$build_log" | tail -n 1)"
[[ "$build_number" =~ ^ar[0-9]{6,}$ ]] \
    || { printf 'remote-build: build did not return a valid build number\n' >&2; exit 1; }
[[ ! -e "$logs_dir/$build_number.log" ]] \
    || { printf 'remote-build: log already exists for build number %s\n' "$build_number" >&2; exit 78; }
final_log="$logs_dir/$build_number.log"
mv "$build_log" "$final_log"
printf 'remote-build: full log: %s\n' "$final_log"
latest_info="$source_root/Images/work/$build_number/download/build-info.json"
[[ -s "$latest_info" && ! -L "$latest_info" ]] \
    || { printf 'remote-build: build-info.json was not produced for %s\n' "$build_number" >&2; exit 1; }
python3 - "$latest_info" "$revision" "$variant" <<'PY'
import json
import pathlib
import re
import sys

info_path = pathlib.Path(sys.argv[1])
info = json.loads(info_path.read_text(encoding="utf-8"))
build_number = info.get("buildNumber")
if not isinstance(build_number, str) or not re.fullmatch(r"ar[0-9]{6,}", build_number):
    raise SystemExit("remote-build: invalid build number in build-info.json")
if info.get("revision") != sys.argv[2]:
    raise SystemExit("remote-build: build-info.json revision does not match request")
if info.get("variant") != sys.argv[3]:
    raise SystemExit("remote-build: build-info.json variant does not match request")
archive = info_path.parent / f"apkrun_arm64-img-{build_number}.zip"
if not archive.is_file() or archive.is_symlink() or archive.stat().st_size == 0:
    raise SystemExit(f"remote-build: missing dist archive {archive}")
print(f"APKRUN_BUILD_NUMBER={build_number}")
print(f"APKRUN_BUILD_OUTPUT_DIR={info_path.parent}")
PY
REMOTE_SCRIPT
)"

printf '%s\n' "$remote_output"
build_number="$(printf '%s\n' "$remote_output" | awk -F= '/^APKRUN_BUILD_NUMBER=/ { value = $2 } END { print value }')"
build_output_dir="$(printf '%s\n' "$remote_output" | awk -F= '/^APKRUN_BUILD_OUTPUT_DIR=/ { value = $2 } END { print value }')"
[[ "$build_number" =~ ^ar[0-9]{6,}$ ]] || fail "builder did not return a valid build number"
[[ "$build_output_dir" == /* && "$build_output_dir" != *$'\n'* ]] \
    || fail "builder did not return a valid absolute artifact directory"

local_output_dir="$repo_root/Images/work/$build_number/download"
archive_name="apkrun_arm64-img-$build_number.zip"
mkdir -p "$local_output_dir"
[[ ! -e "$local_output_dir/$archive_name" && ! -e "$local_output_dir/build-info.json" ]] \
    || fail "local output already exists at $local_output_dir"
archive_temporary="$(mktemp "$local_output_dir/.apkrun-image.XXXXXX")"
info_temporary="$(mktemp "$local_output_dir/.build-info.XXXXXX")"
cleanup_transfer() {
    rm -f "$archive_temporary" "$info_temporary"
}
trap cleanup_transfer EXIT
printf -v remote_archive_path '%q' "$build_output_dir/$archive_name"
printf -v remote_info_path '%q' "$build_output_dir/build-info.json"
ssh -o BatchMode=yes -- "$builder" "cat -- $remote_archive_path" >"$archive_temporary"
ssh -o BatchMode=yes -- "$builder" "cat -- $remote_info_path" >"$info_temporary"
[[ -s "$archive_temporary" && -s "$info_temporary" ]] || fail "downloaded build artifacts are empty"
python3 - "$info_temporary" "$revision" "$variant" "$build_number" <<'PY'
import json
import pathlib
import sys

info = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if info.get("revision") != sys.argv[2]:
    raise SystemExit("remote-build: downloaded build-info.json revision mismatch")
if info.get("variant") != sys.argv[3]:
    raise SystemExit("remote-build: downloaded build-info.json variant mismatch")
if info.get("buildNumber") != sys.argv[4]:
    raise SystemExit("remote-build: downloaded build-info.json build number mismatch")
PY
unzip -Z1 "$archive_temporary" >/dev/null || fail "downloaded AOSP artifact is not a valid zip archive"
mv "$archive_temporary" "$local_output_dir/$archive_name"
mv "$info_temporary" "$local_output_dir/build-info.json"
trap - EXIT

printf 'remote-build: copied %s and build-info.json to %s\n' "$archive_name" "$local_output_dir"
printf 'Next: scripts/inventory-cuttlefish.py %s\n' "$local_output_dir"
printf 'Then: source Images/tools/.venv/bin/activate && python3 -m apkrun_image bundle --manifest Images/manifests/%s/android-image.json --layout Images/tools/layouts/cuttlefish-phone-arm64.json --input %s --out Images/work/%s/bundle/ --image-version <YYYY.MM.N>\n' \
    "$build_number" "$local_output_dir" "$build_number"
