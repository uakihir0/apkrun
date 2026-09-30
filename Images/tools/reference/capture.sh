#!/bin/sh
# Capture a pinned Cuttlefish boot. Run this on the Linux reference host only.

set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../../.." && pwd)
profile=${1:-}

case "$profile" in
  default|target|swiftshader) ;;
  *)
    printf 'usage: %s {default|target|swiftshader}\n' "$0" >&2
    exit 2
    ;;
esac

if [ "$(uname -s)" != Linux ]; then
  printf 'capture.sh requires a Linux Cuttlefish reference host.\n' >&2
  exit 2
fi

if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ] && [ "$(uname -m)" != x86_64 ]; then
  printf 'unsupported reference-host architecture: %s\n' "$(uname -m)" >&2
  exit 2
fi

if [ -z "${CVD_HOST_DIR:-}" ] || [ ! -d "$CVD_HOST_DIR" ]; then
  printf 'set CVD_HOST_DIR to the extracted Cuttlefish host package directory.\n' >&2
  exit 2
fi
if [ ! -x "$CVD_HOST_DIR/bin/launch_cvd" ] \
  || [ ! -x "$CVD_HOST_DIR/bin/cvd" ] \
  || [ ! -x "$CVD_HOST_DIR/bin/adb" ]; then
  printf 'CVD_HOST_DIR must contain executable bin/launch_cvd, bin/cvd, and bin/adb.\n' >&2
  exit 2
fi
PATH="$CVD_HOST_DIR/bin:$PATH"
export PATH

for tool in adb chmod cp cvd launch_cvd timeout python3 gzip find ps grep awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'required host tool not found on PATH: %s\n' "$tool" >&2
    exit 2
  fi
done
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'; then
  printf 'capture.sh requires Python 3.12; activate Images/tools/.venv.\n' >&2
  exit 2
fi

if [ -z "${ANDROID_PRODUCT_OUT:-}" ] || [ ! -d "$ANDROID_PRODUCT_OUT" ]; then
  printf 'set ANDROID_PRODUCT_OUT to the extracted build 16373615 image directory.\n' >&2
  exit 2
fi
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  printf 'HOME must name the reference user home directory.\n' >&2
  exit 2
fi
cvd_instance_num=${APKRUN_CVD_INSTANCE_NUM:-1}
case "$cvd_instance_num" in
  ''|*[!0-9]*|0*)
    printf 'APKRUN_CVD_INSTANCE_NUM must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if [ "$cvd_instance_num" -gt 59016 ]; then
  printf 'APKRUN_CVD_INSTANCE_NUM must not exceed 59016 (ADB port limit).\n' >&2
  exit 2
fi
adb_port=$((6520 + cvd_instance_num - 1))

manifest_path="$repo_root/Images/manifests/16373615/android-image.json"
verify_product_images() {
python3 - "$manifest_path" "$1" <<'PY'
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath

manifest_path, product_out = Path(sys.argv[1]), Path(sys.argv[2])
try:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"cannot read pinned Android image manifest: {error}")
source = document.get("source", {})
if (
    source.get("buildId") != "16373615"
    or source.get("target") != "aosp_cf_arm64_only_phone-userdebug"
    or document.get("architecture") != "arm64"
):
    raise SystemExit("checked-in manifest does not identify the pinned ARM64 Cuttlefish build")
root = product_out.resolve()
artifacts = document.get("artifacts")
if not isinstance(artifacts, list) or not artifacts:
    raise SystemExit("pinned Android image manifest has no artifacts")
for artifact in artifacts:
    if not isinstance(artifact, dict):
        raise SystemExit("pinned Android image manifest contains an invalid artifact")
    filename = artifact.get("file")
    expected_size = artifact.get("size")
    expected_hash = artifact.get("sha256")
    relative = PurePosixPath(filename) if isinstance(filename, str) else None
    if (
        relative is None
        or relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
        or not isinstance(expected_size, int)
        or not isinstance(expected_hash, str)
        or len(expected_hash) != 64
    ):
        raise SystemExit("pinned Android image manifest contains invalid artifact metadata")
    path = root.joinpath(*relative.parts)
    try:
        resolved = path.resolve(strict=True)
        if root not in resolved.parents or not resolved.is_file():
            raise OSError("artifact resolves outside the product output directory")
        if resolved.stat().st_size != expected_size:
            raise OSError(f"size mismatch for {filename}")
        digest = hashlib.sha256()
        with resolved.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() != expected_hash:
            raise OSError(f"SHA-256 mismatch for {filename}")
    except OSError as error:
        raise SystemExit(f"product output does not match pinned artifact {filename}: {error}")
print("Verified all product image artifacts against build 16373615.")
PY
}
if ! verify_product_images "$ANDROID_PRODUCT_OUT"; then
  printf 'ANDROID_PRODUCT_OUT must contain the artifacts from the pinned build 16373615.\n' >&2
  exit 2
fi
if ! source_symlink=$(find "$ANDROID_PRODUCT_OUT" -type l -print -quit); then
  printf 'could not inspect ANDROID_PRODUCT_OUT for symbolic links.\n' >&2
  exit 2
fi
if [ -n "$source_symlink" ]; then
  printf 'ANDROID_PRODUCT_OUT contains symbolic links; re-extract the product files without links.\n' >&2
  exit 2
fi

target_gpu_mode=${APKRUN_TARGET_GPU_MODE:-drm_virgl}
virgl_source_revision=${APKRUN_DRM_VIRGL_SOURCE_REVISION:-}
virgl_properties_file=${APKRUN_DRM_VIRGL_PROPS_FILE:-}
if [ "$profile" = target ]; then
  case "$target_gpu_mode" in
    drm_virgl) ;;
    guest_swiftshader)
      if [ -z "$virgl_source_revision" ] || [ -z "$virgl_properties_file" ] \
        || [ ! -f "$virgl_properties_file" ]; then
        printf '%s\n' \
          'guest_swiftshader target fallback requires APKRUN_DRM_VIRGL_SOURCE_REVISION and APKRUN_DRM_VIRGL_PROPS_FILE.' \
          >&2
        exit 2
      fi
      ;;
    *)
      printf 'unsupported APKRUN_TARGET_GPU_MODE: %s\n' "$target_gpu_mode" >&2
      exit 2
      ;;
  esac
fi

timeout_seconds=${APKRUN_BOOT_TIMEOUT_SECONDS:-600}
case "$timeout_seconds" in
  ''|*[!0-9]*)
    printf 'APKRUN_BOOT_TIMEOUT_SECONDS must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if [ "$timeout_seconds" -lt 1 ]; then
  printf 'APKRUN_BOOT_TIMEOUT_SECONDS must be greater than zero.\n' >&2
  exit 2
fi
stop_timeout_seconds=${APKRUN_CVD_STOP_TIMEOUT_SECONDS:-120}
case "$stop_timeout_seconds" in
  ''|*[!0-9]*)
    printf 'APKRUN_CVD_STOP_TIMEOUT_SECONDS must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if [ "$stop_timeout_seconds" -lt 1 ]; then
  printf 'APKRUN_CVD_STOP_TIMEOUT_SECONDS must be greater than zero.\n' >&2
  exit 2
fi

reference_root="$repo_root/Images/reference/16373615"
destination="$reference_root/$profile"
if [ -e "$destination" ]; then
  printf 'capture destination already exists; refusing to overwrite: %s\n' "$destination" >&2
  exit 2
fi
mkdir -p "$reference_root"
adb_devices=$(adb devices | awk 'NR > 1 && NF >= 2 { print $1 "\t" $2 }')
if [ -n "$adb_devices" ]; then
  printf 'ADB already has attached devices; disconnect them before capturing:\n%s\n' \
    "$adb_devices" >&2
  exit 2
fi
existing_crosvm=$(ps -ww -eo pid,args | grep '[c]rosvm' || true)
if [ -n "$existing_crosvm" ]; then
  printf 'a crosvm process is already running; use a dedicated reference host:\n%s\n' \
    "$existing_crosvm" >&2
  exit 2
fi
capture_lock_root=/tmp
capture_lock="$capture_lock_root/apkrun-cvd-capture.lock"
stage=
stage_normalized=0
cvd_home=
preserve_cvd_home=0
started=0
cvd_group_name=
capture_failed=0
capture_lock_owned=0
lock_initializing=0
pending_signal_status=
adb_connect_attempted=0
adb_disconnect_attempted=0
capture_started_at=$(date +%s)
capture_script_pid=$$
exec 3>&2

remove_cvd_group_bounded() {
  HOME="$cvd_home" timeout --kill-after=10s "$stop_timeout_seconds" \
    cvd --group_name="$cvd_group_name" remove
}

disconnect_adb_bounded() {
  [ -n "$cvd_home" ] || return 0
  [ "$adb_connect_attempted" -eq 1 ] || return 0
  [ "$adb_disconnect_attempted" -eq 0 ] || return 0
  adb_disconnect_attempted=1
  HOME="$cvd_home" timeout --kill-after=2s 10 \
    adb disconnect "127.0.0.1:$adb_port" >/dev/null 2>&1 || true
}

discard_staging_path() {
  discard_path=$1
  rm -rf "$discard_path" >/dev/null 2>&1 && [ ! -e "$discard_path" ]
}

discard_stage_with_raw_logcat() {
  raw_stage=$stage
  if discard_staging_path "$raw_stage"; then
    stage=
    printf 'raw logcat cleanup failed; the entire capture stage was discarded.\n' >&2
  else
    stage=
    printf 'raw logcat cleanup failed; unpublished staging data may remain at %s and must be removed manually.\n' \
      "$raw_stage" >&2
  fi
}

remove_raw_logcat() {
  [ -n "${stage:-}" ] || return 0
  raw_log="$stage/.logcat.raw"
  [ -e "$raw_log" ] || return 0
  if rm -f "$raw_log" >/dev/null 2>&1 && [ ! -e "$raw_log" ]; then
    return 0
  fi
  discard_stage_with_raw_logcat
  return 1
}

on_exit() {
  exit_status=${1:-$?}
  exec 2>&3
  exec 3>&-
  trap '' HUP INT TERM
  disconnect_adb_bounded
  if [ "$started" -eq 1 ]; then
    if remove_cvd_group_bounded >/dev/null 2>&1; then
      started=0
      if rm -rf "$cvd_home"; then
        cvd_home=
        preserve_cvd_home=0
      else
        preserve_cvd_home=1
      fi
    else
      preserve_cvd_home=1
    fi
  fi
  if [ -n "$cvd_home" ] && [ -d "$cvd_home" ]; then
    if [ "$preserve_cvd_home" -eq 1 ]; then
      printf 'Cuttlefish HOME retained for inspection or cleanup: %s\n' "$cvd_home" >&2
    elif rm -rf "$cvd_home"; then
      cvd_home=
    else
      printf 'could not remove temporary Cuttlefish HOME: %s\n' "$cvd_home" >&2
    fi
  fi
  if [ -n "${stage:-}" ] && [ -d "$stage" ]; then
    if [ "$exit_status" -eq 0 ]; then
      exit_status=1
    fi
    remove_raw_logcat || true
    if [ -n "${stage:-}" ] && [ -d "$stage" ]; then
      missing_file="$stage/MISSING.txt"
      if [ ! -f "$missing_file" ]; then
        : > "$missing_file"
      fi
      if [ "$stage_normalized" -eq 0 ]; then
        printf 'capture\tprocess exited before normal capture completion\n' \
          >> "$missing_file" 2>/dev/null || true
        if python3 "$script_dir/compare_boot.py" normalize "$stage" >/dev/null 2>&1; then
          stage_normalized=1
        else
          failed_stage=$stage
          stage=
          if discard_staging_path "$failed_stage"; then
            printf 'staging data was discarded after interrupted normalization failed.\n' >&2
          else
            printf 'normalization failed; unpublished staging data remains at %s and must be removed manually.\n' \
              "$failed_stage" >&2
          fi
        fi
      else
        if [ ! -s "$missing_file" ]; then
          printf 'capture\tprocess exited before profile publication\n' \
            >> "$missing_file" 2>/dev/null || true
        fi
      fi
    fi
    if [ -n "${stage:-}" ] && [ "$stage_normalized" -eq 1 ]; then
      incomplete_root="$reference_root/incomplete"
      if mkdir -p "$incomplete_root" 2>/dev/null; then
        incomplete_destination="$incomplete_root/${profile}-interrupted-$(date +%Y%m%dT%H%M%S)-$$"
        if mv -T "$stage" "$incomplete_destination"; then
          stage=
          printf 'normalized incomplete capture retained at %s\n' \
            "$incomplete_destination" >&2
        else
          failed_stage=$stage
          stage=
          if discard_staging_path "$failed_stage"; then
            printf 'could not retain interrupted capture; staging data was discarded.\n' >&2
          else
            printf 'could not retain interrupted capture; normalized staging data remains at %s.\n' \
              "$failed_stage" >&2
          fi
        fi
      else
        failed_stage=$stage
        stage=
        if discard_staging_path "$failed_stage"; then
          printf 'could not create incomplete capture directory; staging data was discarded.\n' \
            >&2
        else
          printf 'could not create incomplete capture directory; normalized staging data remains at %s.\n' \
            "$failed_stage" >&2
        fi
      fi
    fi
  fi
  if [ "$capture_lock_owned" -eq 1 ]; then
    rmdir "$capture_lock" >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
handle_signal() {
  signal_status=$1
  if [ "$lock_initializing" -eq 1 ]; then
    pending_signal_status=$signal_status
    return 0
  fi
  trap - EXIT
  on_exit "$signal_status"
}
trap on_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

lock_initializing=1
if (
  umask 077
  APKRUN_CAPTURE_SCRIPT_PID="$capture_script_pid" mkdir "$capture_lock"
) 2>/dev/null; then
  capture_lock_owned=1
else
  lock_initializing=0
  if [ -n "$pending_signal_status" ]; then
    handle_signal "$pending_signal_status"
  fi
  printf 'another reference capture is active; lock exists: %s\n' \
    "$capture_lock" >&2
  exit 2
fi
lock_initializing=0
if [ -n "$pending_signal_status" ]; then
  handle_signal "$pending_signal_status"
fi

stage=$(mktemp -d "$reference_root/.${profile}.capture.XXXXXX")
cvd_home=$(mktemp -d "${TMPDIR:-/tmp}/apkrun-cvd-home.${profile}.XXXXXX")
cvd_group_suffix=$(printf '%s' "${cvd_home##*.}" | tr '[:upper:]' '[:lower:]')
cvd_group_name="apkrun_${profile}_${cvd_group_suffix}"
runtime_root="$cvd_home"
instance_runtime="$runtime_root/.missing-instance"
mkdir -p "$runtime_root"
capture_marker="$stage/capture-start-marker"
: > "$capture_marker"
missing_file="$stage/MISSING.txt"
: > "$missing_file"

record_missing() {
  printf '%s\t%s\n' "$1" "$2" >> "$missing_file"
  capture_failed=1
}

private_product_out="$cvd_home/product"
if ! mkdir -p "$private_product_out" \
  || ! cp -a "$ANDROID_PRODUCT_OUT/." "$private_product_out/" \
  || ! chmod -R u+rwX "$private_product_out"; then
  record_missing "product-images" \
    "could not create a writable private copy of ANDROID_PRODUCT_OUT"
  exit 1
fi
if ! copied_symlink=$(find "$private_product_out" -type l -print -quit); then
  record_missing "product-images" \
    "could not verify the private product copy for symbolic links"
  exit 1
fi
if [ -n "$copied_symlink" ]; then
  record_missing "product-images" \
    "private product copy contains a symbolic link; Cuttlefish was not started"
  exit 1
fi
if ! verify_product_images "$private_product_out" >/dev/null; then
  record_missing "product-images" \
    "private product copy does not match pinned build 16373615; Cuttlefish was not started"
  exit 1
fi

if [ "$profile" = target ] && [ "$target_gpu_mode" = guest_swiftshader ]; then
  if cp "$virgl_properties_file" "$stage/graphics-props-from-source.txt"; then
    printf '%s\n' "$virgl_source_revision" > "$stage/graphics-props-source-revision.txt"
  else
    record_missing "graphics-props-from-source.txt" "could not copy the drm_virgl source properties"
  fi
fi

create_cvd_group_with_common_options() {
  HOME="$cvd_home" cvd create \
    --host_path="$CVD_HOST_DIR" \
    --product_path="$private_product_out" \
    --base_directory="$runtime_root" \
    --group_name="$cvd_group_name" \
    --base_instance_num="$cvd_instance_num" \
    --num_instances=1 \
    --nostart \
    "$@" \
    && HOME="$cvd_home" cvd --group_name="$cvd_group_name" start
}

launch_profile() {
  case "$profile" in
    default)
      create_cvd_group_with_common_options --cpus 4 --memory_mb 4096
      ;;
    target)
      create_cvd_group_with_common_options \
        --gpu_mode="$target_gpu_mode" \
        --secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure \
        --cpus 4 \
        --memory_mb 4096
      ;;
    swiftshader)
      create_cvd_group_with_common_options \
        --gpu_mode=guest_swiftshader \
        --secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure \
        --cpus 4 \
        --memory_mb 4096
      ;;
  esac
}

capture_adb() {
  HOME="$cvd_home" APKRUN_CAPTURE_PID=$$ adb "$@"
}

preserve_cvd_home=1
started=1
if ! launch_profile > "$stage/cvd-create-console.log" 2>&1; then
  record_missing "guest" "Cuttlefish group create or start failed; see cvd-create-console.log"
else
  preserve_cvd_home=0
  discovered_instance_runtime=$(find "$runtime_root" -type d \
    -path "*/instances/cvd-$cvd_instance_num" -print -quit 2>/dev/null || true)
  if [ -n "$discovered_instance_runtime" ]; then
    instance_runtime=$discovered_instance_runtime
  else
    record_missing "instance-runtime" \
      "Cuttlefish did not create the selected instance directory under its private base directory"
  fi
  boot_timeout_deadline=$(($(date +%s) + timeout_seconds))
  booted=0
  device_invalid=0
  adb_serial=
  while [ "$(date +%s)" -lt "$boot_timeout_deadline" ]; do
    adb_connect_attempted=1
    capture_adb connect "127.0.0.1:$adb_port" >/dev/null 2>&1 || true
    adb_serial=$(capture_adb devices |
      awk -v port="$adb_port" \
        'NR > 1 && $2 == "device" && $1 ~ ("^(127[.]0[.]0[.]1|localhost):" port "$") { print $1 }')
    device_count=$(printf '%s\n' "$adb_serial" | awk 'NF { count++ } END { print count+0 }')
    if [ "$device_count" -gt 1 ]; then
      record_missing "guest" "multiple ADB devices matched Cuttlefish instance $cvd_instance_num"
      device_invalid=1
      break
    fi
    if [ "$device_count" -eq 1 ]; then
      boot_state=$(capture_adb -s "$adb_serial" shell getprop sys.boot_completed 2>/dev/null |
        tr -d '\r' || true)
      if [ "$boot_state" = 1 ]; then
        booted=1
        break
      fi
    fi
    sleep 2
  done
  if [ "$device_invalid" -eq 0 ] && [ "$booted" -ne 1 ]; then
    record_missing "guest" "sys.boot_completed did not become 1 within ${timeout_seconds}s"
  elif [ "$booted" -eq 1 ]; then
    capture_adb -s "$adb_serial" wait-for-device >/dev/null 2>&1 ||
      record_missing "guest" "adb wait-for-device failed"
    tab=$(printf '\t')
    while IFS="$tab" read -r output_file guest_command || [ -n "${output_file:-}" ]; do
      case "${output_file:-}" in
        ''|'#'*) continue ;;
      esac
      case "$output_file" in
        */*|*..*)
          record_missing "$output_file" "unsafe output filename in guest-capture.txt"
          continue
          ;;
      esac
      if [ -z "${guest_command:-}" ]; then
        record_missing "$output_file" "missing guest command in guest-capture.txt"
        continue
      fi
      if [ "$output_file" = logcat.txt.gz ]; then
        raw_log="$stage/.logcat.raw"
        if capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \
          > "$raw_log" 2>/dev/null; then
          if gzip -n -c "$raw_log" > "$stage/$output_file"; then
            if ! remove_raw_logcat; then
              exit 1
            fi
          else
            rm -f "$stage/$output_file" >/dev/null 2>&1 || true
            if ! remove_raw_logcat; then
              exit 1
            fi
            record_missing "$output_file" "could not gzip guest logcat output"
          fi
        else
          if ! remove_raw_logcat; then
            exit 1
          fi
          record_missing "$output_file" "guest logcat command failed"
        fi
      elif ! capture_adb -s "$adb_serial" exec-out sh -c "$guest_command" \
        > "$stage/$output_file" 2>/dev/null; then
        rm -f "$stage/$output_file"
        record_missing "$output_file" "guest command failed: $guest_command"
      fi
    done < "$script_dir/guest-capture.txt"
  fi
fi

copy_first_match() {
  destination_name=$1
  source_path=$(find "$instance_runtime" -newer "$capture_marker" -type f \
    -name "$destination_name" -print -quit 2>/dev/null || true)
  if [ -n "$source_path" ] && [ -f "$source_path" ]; then
    if ! cp "$source_path" "$stage/$destination_name"; then
      rm -f "$stage/$destination_name" >/dev/null 2>&1 || true
      record_missing "$destination_name" "could not copy this Cuttlefish artifact"
    fi
  else
    record_missing "$destination_name" "not found in the selected Cuttlefish instance runtime"
  fi
}

ps -ww -eo pid,args | awk \
  -v instance_path="$instance_runtime" '
  NR == 1 { header = $0; next }
  {
    path_offset = index($0, instance_path)
    path_match = 0
    if (path_offset > 0) {
      path_suffix = substr($0, path_offset + length(instance_path), 1)
      path_match = path_suffix == "" || path_suffix == "/" ||
        path_suffix ~ /[[:space:]":,]/
    }
  }
  index($0, "crosvm") && path_match {
      lines = lines $0 "\n"
      found = 1
    }
  END {
    if (!found) exit 1
    print header
    printf "%s", lines
  }
' > "$stage/crosvm-command-line.txt" || true
if [ ! -s "$stage/crosvm-command-line.txt" ]; then
  record_missing "crosvm-command-line.txt" \
    "no crosvm process matched the private Cuttlefish HOME in ps output"
fi

internal_bootconfig=$(find "$instance_runtime" -newer "$capture_marker" -type f \
  -path '*/internal/bootconfig' \
  -print -quit 2>/dev/null || true)
if [ -n "$internal_bootconfig" ] && [ -f "$internal_bootconfig" ]; then
  if ! python3 - "$internal_bootconfig" "$stage/internal-bootconfig.txt" <<'PY'
import struct
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_bytes()
destination = Path(sys.argv[2])
if len(source) >= 64 and source[-64:-60] == b"AVBf":
    magic, major, minor, original_size, vbmeta_offset, vbmeta_size = struct.unpack_from(
        ">4sIIQQQ", source, len(source) - 64
    )
    footer_offset = len(source) - 64
    if (
        magic != b"AVBf"
        or original_size > vbmeta_offset
        or vbmeta_offset > footer_offset
        or vbmeta_size > footer_offset - vbmeta_offset
    ):
        raise SystemExit("invalid AVB footer in Cuttlefish internal bootconfig")
    source = source[:original_size]
destination.write_bytes(source)
PY
  then
    record_missing "internal-bootconfig.txt" "could not validate or strip its AVB footer"
  fi
else
  record_missing "internal-bootconfig.txt" \
    "not found in the selected Cuttlefish instance runtime"
fi

copy_first_match cuttlefish_config.json
copy_first_match kernel.log
copy_first_match launcher.log

if [ -s "$stage/cuttlefish_config.json" ]; then
  if ! python3 - "$stage/cuttlefish_config.json" "$stage/composite-disk-specs.json" <<'PY'
import json
import sys
from pathlib import Path
from typing import Any

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
matches: dict[str, Any] = {}

def visit(value: Any, prefix: str = "") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            name = f"{prefix}.{key}" if prefix else str(key)
            if "composite" in str(key).lower():
                matches[name] = child
            visit(child, name)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            visit(child, f"{prefix}[{index}]")

visit(source)
if not matches:
    raise SystemExit("no composite disk specifications found in Cuttlefish config")
Path(sys.argv[2]).write_text(
    json.dumps(matches, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY
  then
    record_missing "composite-disk-specs.json" "no composite disk specifications in cuttlefish_config.json"
  fi
else
  record_missing "composite-disk-specs.json" "cannot inspect missing cuttlefish_config.json"
fi

host_os=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -n 1)
host_os=${host_os:-Linux}
host_kernel=$(uname -srmo)
cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')
virtualization=$(systemd-detect-virt --vm 2>/dev/null || true)
if [ -z "$virtualization" ] || [ "$virtualization" = none ]; then
  host_kind=linux
  nested_virtualization=off
else
  host_kind="linux-$virtualization"
  if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    nested_virtualization=on
  else
    nested_virtualization=off
  fi
fi
cvd_package_version=${APKRUN_CVD_PACKAGE_VERSION:-}
if [ -z "$cvd_package_version" ] && command -v dpkg-query >/dev/null 2>&1; then
  cvd_package_version=$(dpkg-query -W -f='${Version}' cuttlefish-base 2>/dev/null || true)
fi
if [ -z "$cvd_package_version" ]; then
  cvd_package_version=unknown
  record_missing "host.json" \
    "set APKRUN_CVD_PACKAGE_VERSION or install dpkg-query to record the CVD package version"
fi
capture_finished_at=$(date +%s)
APKRUN_CAPTURE_PROFILE=$profile \
APKRUN_CAPTURE_HOST_KIND=$host_kind \
APKRUN_CAPTURE_HOST_OS=$host_os \
APKRUN_CAPTURE_HOST_KERNEL=$host_kernel \
APKRUN_CAPTURE_CPU_COUNT=$cpu_count \
APKRUN_CAPTURE_NESTED_VIRTUALIZATION=$nested_virtualization \
APKRUN_CAPTURE_CVD_VERSION=$cvd_package_version \
APKRUN_CAPTURE_CVD_INSTANCE_NUM=$cvd_instance_num \
APKRUN_CAPTURE_TARGET_GPU_MODE=$target_gpu_mode \
APKRUN_CAPTURE_VIRGL_SOURCE_REVISION=$virgl_source_revision \
APKRUN_CAPTURE_DURATION=$((capture_finished_at - capture_started_at)) \
python3 - "$stage/host.json" <<'PY'
import json
import os
import platform
import sys
from pathlib import Path

document = {
    "schemaVersion": 1,
    "buildId": "16373615",
    "profile": os.environ["APKRUN_CAPTURE_PROFILE"],
    "hostKind": os.environ["APKRUN_CAPTURE_HOST_KIND"],
    "os": os.environ["APKRUN_CAPTURE_HOST_OS"],
    "kernel": os.environ["APKRUN_CAPTURE_HOST_KERNEL"],
    "architecture": platform.machine(),
    "cvdPackageVersion": os.environ["APKRUN_CAPTURE_CVD_VERSION"],
    "cvdInstanceNumber": int(os.environ["APKRUN_CAPTURE_CVD_INSTANCE_NUM"]),
    "targetGpuMode": (
        os.environ["APKRUN_CAPTURE_TARGET_GPU_MODE"]
        if os.environ["APKRUN_CAPTURE_PROFILE"] == "target"
        else None
    ),
    "drmVirglSourceRevision": (
        os.environ["APKRUN_CAPTURE_VIRGL_SOURCE_REVISION"] or None
    ),
    "cpuCount": (
        int(os.environ["APKRUN_CAPTURE_CPU_COUNT"])
        if os.environ["APKRUN_CAPTURE_CPU_COUNT"].isdigit()
        else None
    ),
    "nestedVirtualization": os.environ["APKRUN_CAPTURE_NESTED_VIRTUALIZATION"],
    "captureDurationSeconds": int(os.environ["APKRUN_CAPTURE_DURATION"]),
}
Path(sys.argv[1]).write_text(
    json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY

disconnect_adb_bounded
if [ "$started" -eq 1 ]; then
  if remove_cvd_group_bounded >/dev/null 2>&1; then
    started=0
    preserve_cvd_home=0
  else
    started=0
    preserve_cvd_home=1
    record_missing "guest" "scoped cvd remove reported a shutdown failure"
    record_missing "cvd-runtime-home" "CVD group removal failed; retained HOME path is printed to stderr"
  fi
fi
rm -f "$capture_marker"

if ! remove_raw_logcat; then
  exit 1
fi
if ! python3 "$script_dir/compare_boot.py" normalize "$stage"; then
  failed_stage=$stage
  stage=
  if discard_staging_path "$failed_stage"; then
    printf 'normalization failed; raw capture data was discarded and not published.\n' >&2
  else
    printf 'normalization failed; unpublished staging data remains at %s and must be removed manually.\n' \
      "$failed_stage" >&2
  fi
  exit 1
fi
stage_normalized=1

if [ "$capture_failed" -ne 0 ]; then
  incomplete_root="$reference_root/incomplete"
  mkdir -p "$incomplete_root"
  incomplete_destination="$incomplete_root/${profile}-$(date +%Y%m%dT%H%M%S)-$$"
  if ! mv -T "$stage" "$incomplete_destination"; then
    printf 'could not preserve incomplete capture at %s\n' "$incomplete_destination" >&2
    exit 1
  fi
  stage=
  printf 'Incomplete capture retained at %s; see MISSING.txt. No profile was published.\n' \
    "$incomplete_destination" >&2
  exit 1
fi

if ! mv -T "$stage" "$destination"; then
  printf 'could not move capture into %s\n' "$destination" >&2
  exit 1
fi
stage=
printf 'Capture written to %s\n' "$destination"
