#!/usr/bin/env bash
# Validates the coordinate mapping of input.md §3 on display 0, with ADB input (#25).
#
#   scripts/dev/validate-input-coordinates.sh [--serial SERIAL] [--display-size WxH] [--content x,y,w,h] [--taps N]
#   scripts/dev/validate-input-coordinates.sh --self-test
#
# This is the only place in the repository that runs `adb shell input` (input.md §1). It is a one-off check, not a
# product path: the production input path never runs a shell command per event (FR-IN-06).
#
# The mapping (input.md §3), with the content rectangle c in window points (AppKit, y up) and the display pixel size
# W x H:
#   x_px = (p.x - c.x) * W / c.w
#   y_px = (c.y + c.h - p.y) * H / c.h
# A value above the last pixel is replaced by it, so x_px is at most W - 1 and y_px at most H - 1. The guest rejects
# x >= W and y >= H (InputService.kt), and the far edges of the content map to the last pixel (CoordinateMapper.map).
# The script also uses the inverse, which gives the window point a click on a pixel comes from:
#   p.x = c.x + x_px * c.w / W
#   p.y = c.y + c.h - y_px * c.h / H
#
# Defaults, and the device steps:
#   --serial         the one device `adb devices` lists. If none is listed, `adb connect 127.0.0.1:6520` (the
#                    development endpoint of `apkrun dev boot`, DevAdb.swift) is tried once.
#   --display-size   `adb shell wm size -d 0`: the override size when one is set, else the physical size.
#   --content        0,0,W/2,H/2. DisplayWindow makes its content W/s x H/s points, with s the backing scale of
#                    NSScreen.main (DisplayPump.swift, DisplayGeometry.contentSize), and the content view starts at
#                    the origin. So the default assumes backing scale 2, which the reference Mac has. Pass --content
#                    for any other scale.
#   The button       the centre of io.apkrun.fixture.hellotext:id/increment_button in `uiautomator dump`, which is read
#                    with `adb exec-out cat` (no input command).
#   Each tap         the window point of the button centre is unmapped with the inverse above, mapped forward again,
#                    and must land within 1 px of the centre. The tap goes to the rounded pixel with
#                    `adb shell input -d 0 tap <x> <y>`. The script then waits up to 5 s for the HelloText log line
#                    `APKRUN-FIXTURE: click <n>` to rise in `logcat -d -s APKRUN-FIXTURE`.
#
# Output: one line per tap, then `hits: H of N taps`. Exit status 0 when every tap hits, 1 on a miss or a device
# failure, 64 on a usage error, 78 when adb is missing (environment-setup.md §2.5).
#
# Reference vectors for --self-test. The T0 test of #25 step 2 (CoordinateMapper) uses the same vectors, and the
# two must agree. Each row is: content (x, y, w, h), display (W, H), window point (p.x, p.y), expected pixel.
#   content (0, 0, 512, 384), display 1024 x 768:
#       (0, 384) -> (0, 0)         (512, 0) -> (1023, 767)      (256, 192) -> (512, 384)
#       (100, 300) -> (200, 168)   (100.5, 300.25) -> (201, 167.5)   (0, 0) -> (0, 767)
#   content (40, 30, 400, 300), display 1024 x 768:
#       (40, 330) -> (0, 0)        (440, 30) -> (1023, 767)     (240, 180) -> (512, 384)
#       (10, 180) -> (-76.8, 384), which is outside the content: the caller drops it. The clamp only lowers values above
#       the last pixel, so the formula is linear below it.
set -euo pipefail

print_usage() {
    printf 'usage: scripts/dev/validate-input-coordinates.sh [--serial SERIAL] [--display-size WxH] [--content x,y,w,h] [--taps N]\n'
    printf '       scripts/dev/validate-input-coordinates.sh --self-test\n'
}

usage() {
    print_usage >&2
    exit 64
}

serial=""
display_size=""
content=""
taps=1
taps_given=false
self_test=false
while (($# > 0)); do
    case "$1" in
        --serial)
            (($# >= 2)) || usage
            serial="$2"
            shift 2
            ;;
        --display-size)
            (($# >= 2)) || usage
            display_size="$2"
            shift 2
            ;;
        --content)
            (($# >= 2)) || usage
            content="$2"
            shift 2
            ;;
        --taps)
            (($# >= 2)) || usage
            taps="$2"
            taps_given=true
            shift 2
            ;;
        --self-test)
            self_test=true
            shift
            ;;
        -h | --help)
            print_usage
            exit 0
            ;;
        *) usage ;;
    esac
done

if [[ "$self_test" == true ]]; then
    if [[ -n "$serial$display_size$content" || "$taps_given" == true ]]; then
        printf 'validate-input-coordinates: --self-test takes no device options\n' >&2
        exit 64
    fi
fi
if [[ -n "$display_size" && ! "$display_size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
    printf 'validate-input-coordinates: --display-size must be WxH in pixels, for example 1024x768\n' >&2
    exit 64
fi
content_pattern='^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?$'
if [[ -n "$content" ]]; then
    if [[ ! "$content" =~ $content_pattern ]]; then
        printf 'validate-input-coordinates: --content must be x,y,w,h in points, for example 0,0,512,384\n' >&2
        exit 64
    fi
    IFS=, read -r content_x content_y content_w content_h <<< "$content"
    if ! awk -v w="$content_w" -v h="$content_h" 'BEGIN { exit ((w > 0 && h > 0) ? 0 : 1) }'; then
        printf 'validate-input-coordinates: --content needs a positive width and height\n' >&2
        exit 64
    fi
fi
if [[ ! "$taps" =~ ^[1-9][0-9]*$ ]]; then
    printf 'validate-input-coordinates: --taps must be a positive whole number\n' >&2
    exit 64
fi

# The mapping of input.md §3 as awk functions. Every awk program in this script includes them, so the formula is
# written once. Keep it equal to CoordinateMapper (InputCore, #25 step 2), including the clamp to the last pixel.
mapping_awk='
function raw_x(px, cx, cw, pw) { return (px - cx) * pw / cw }
function raw_y(py, cy, ch, ph) { return (cy + ch - py) * ph / ch }
function last_pixel(v, n) { return v > n - 1 ? n - 1 : v }
function map_x(px, cx, cw, pw) { return last_pixel(raw_x(px, cx, cw, pw), pw) }
function map_y(py, cy, ch, ph) { return last_pixel(raw_y(py, cy, ch, ph), ph) }
function unmap_x(xp, cx, cw, pw) { return cx + xp * cw / pw }
function unmap_y(yp, cy, ch, ph) { return cy + ch - yp * ch / ph }
function nearest_pixel(v) { return v < 0 ? -int(0.5 - v) : int(v + 0.5) }
function absolute(v) { return v < 0 ? -v : v }
'

self_test_vectors() {
    cat <<'VECTORS'
# content x y w h | display W H | window px py | pixel x y
0 0 512 384 1024 768 0 384 0 0
0 0 512 384 1024 768 512 0 1023 767
0 0 512 384 1024 768 256 192 512 384
0 0 512 384 1024 768 100 300 200 168
0 0 512 384 1024 768 100.5 300.25 201 167.5
0 0 512 384 1024 768 0 0 0 767
40 30 400 300 1024 768 40 330 0 0
40 30 400 300 1024 768 440 30 1023 767
40 30 400 300 1024 768 240 180 512 384
40 30 400 300 1024 768 10 180 -76.8 384
VECTORS
}

run_self_test() {
    self_test_vectors | awk "$mapping_awk"'
        /^#/ || NF == 0 { next }
        NF != 10 { printf "self-test: malformed vector: %s\n", $0; malformed++; next }
        {
            count++
            # The forward mapping is clamped, so the inverse is checked on the unclamped pixel, which the inverse
            # returns to the window point exactly.
            mx = map_x($7, $1, $3, $5)
            my = map_y($8, $2, $4, $6)
            ux = unmap_x(raw_x($7, $1, $3, $5), $1, $3, $5)
            uy = unmap_y(raw_y($8, $2, $4, $6), $2, $4, $6)
            if (!near(mx, $9) || !near(my, $10) || !near(ux, $7) || !near(uy, $8)) {
                printf "self-test: FAIL content (%s, %s, %s, %s) display %sx%s window (%s, %s): pixel (%.6f, %.6f), window (%.6f, %.6f)\n", $1, $2, $3, $4, $5, $6, $7, $8, mx, my, ux, uy
                failures++
            }
        }
        END {
            printf "self-test: %d vectors, %d failures, %d malformed\n", count, failures + 0, malformed + 0
            exit ((failures + malformed) > 0 ? 1 : 0)
        }
        function near(a, b) { return absolute(a - b) < 1e-9 }
    '
}

if [[ "$self_test" == true ]]; then
    if run_self_test; then
        exit 0
    fi
    exit 1
fi

resolve_adb() {
    if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/platform-tools/adb" ]]; then
        printf '%s\n' "$ANDROID_HOME/platform-tools/adb"
    elif command -v adb > /dev/null 2>&1; then
        command -v adb
    else
        return 1
    fi
}

adb_bin="$(resolve_adb || true)"
if [[ -z "$adb_bin" ]]; then
    printf 'validate-input-coordinates: adb is missing; set ANDROID_HOME (environment-setup.md §2.5)\n' >&2
    exit 78
fi

list_devices() {
    "$adb_bin" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

if [[ -z "$serial" ]]; then
    found="$(list_devices)"
    if [[ -z "$found" ]]; then
        "$adb_bin" connect 127.0.0.1:6520 > /dev/null 2>&1 || true
        found="$(list_devices)"
    fi
    device_count="$(printf '%s\n' "$found" | awk 'NF { n++ } END { print n + 0 }')"
    if [[ "$device_count" -ne 1 ]]; then
        printf 'validate-input-coordinates: found %s devices; start apkrun dev boot or pass --serial\n' "$device_count" >&2
        exit 1
    fi
    serial="$found"
fi

adb_s() {
    "$adb_bin" -s "$serial" "$@"
}

if [[ -z "$display_size" ]]; then
    wm_output="$(adb_s shell wm size -d 0 | tr -d '\r')"
    display_size="$(printf '%s\n' "$wm_output" | awk -F': ' '
        /^Override size:/ { override = $2 }
        /^Physical size:/ { physical = $2 }
        END { print (override != "" ? override : physical) }')"
    if [[ ! "$display_size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
        printf 'validate-input-coordinates: cannot read the size of display 0 from wm size: %s\n' "$wm_output" >&2
        exit 1
    fi
fi
IFS=x read -r pixel_width pixel_height <<< "$display_size"

if [[ -z "$content" ]]; then
    content="$(awk -v w="$pixel_width" -v h="$pixel_height" 'BEGIN { printf "0,0,%g,%g", w / 2, h / 2 }')"
    IFS=, read -r content_x content_y content_w content_h <<< "$content"
fi

# The button's bounds come from the uiautomator dump. The dump is retried, because it fails while the screen is busy.
button_id="io.apkrun.fixture.hellotext:id/increment_button"
dump_path="/data/local/tmp/apkrun-024-validate-input.xml"
dump_xml=""
for _ in 1 2 3; do
    if adb_s shell uiautomator dump "$dump_path" > /dev/null 2>&1; then
        dump_xml="$(adb_s exec-out cat "$dump_path" 2> /dev/null | tr -d '\r' || true)"
        if [[ "$dump_xml" == *"$button_id"* ]]; then
            break
        fi
    fi
    sleep 1
done
adb_s shell rm -f "$dump_path" > /dev/null 2>&1 || true

nodes="$(printf '%s' "$dump_xml" | grep -o "<node [^>]*resource-id=\"$button_id\"[^>]*>" || true)"
node_count="$(printf '%s\n' "$nodes" | awk 'NF { n++ } END { print n + 0 }')"
if [[ "$node_count" -ne 1 ]]; then
    printf 'validate-input-coordinates: found %s nodes for %s in the dump; is HelloText on display 0?\n' "$node_count" "$button_id" >&2
    exit 1
fi
bounds="$(printf '%s' "$nodes" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -n 1 || true)"
bounds_numbers="$(printf '%s' "$bounds" | sed -E 's/^bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"$/\1 \2 \3 \4/')"
if [[ ! "$bounds_numbers" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    printf 'validate-input-coordinates: cannot read the bounds of the button: %s\n' "$bounds" >&2
    exit 1
fi
IFS=' ' read -r left top right bottom <<< "$bounds_numbers"
read -r centre_x centre_y <<< "$(awk -v l="$left" -v t="$top" -v r="$right" -v b="$bottom" 'BEGIN { printf "%.1f %.1f", (l + r) / 2, (t + b) / 2 }')"

# The window point of the centre, the forward mapping of that point, the check within 1 px, and the rounded tap.
plan="$(awk -v cx="$content_x" -v cy="$content_y" -v cw="$content_w" -v ch="$content_h" \
    -v W="$pixel_width" -v H="$pixel_height" -v bx="$centre_x" -v by="$centre_y" "$mapping_awk"'
BEGIN {
    wx = unmap_x(bx, cx, cw, W)
    wy = unmap_y(by, cy, ch, H)
    mx = map_x(wx, cx, cw, W)
    my = map_y(wy, cy, ch, H)
    tx = nearest_pixel(mx)
    ty = nearest_pixel(my)
    near_centre = absolute(mx - bx) <= 1 && absolute(my - by) <= 1
    inside = tx >= 0 && tx < W && ty >= 0 && ty < H
    printf "%.2f %.2f %.3f %.3f %d %d %s\n", wx, wy, mx, my, tx, ty, ((near_centre && inside) ? "yes" : "no")
}')"
IFS=' ' read -r window_x window_y mapped_x mapped_y tap_x tap_y within_one_pixel <<< "$plan"

printf 'serial: %s\n' "$serial"
printf 'display 0: %sx%s pixels\n' "$pixel_width" "$pixel_height"
printf 'content: %s,%s,%s,%s points (window content, y up)\n' "$content_x" "$content_y" "$content_w" "$content_h"
printf 'button: %s bounds [%s,%s][%s,%s], centre (%s, %s) pixels\n' "$button_id" "$left" "$top" "$right" "$bottom" "$centre_x" "$centre_y"
printf 'window click: (%s, %s) points -> mapped (%s, %s) pixels, within 1 px of the centre: %s\n' \
    "$window_x" "$window_y" "$mapped_x" "$mapped_y" "$within_one_pixel"
if [[ "$within_one_pixel" != yes ]]; then
    printf 'validate-input-coordinates: the mapping does not return the button centre; check the content rectangle\n' >&2
    exit 1
fi

# The number of click lines HelloText has logged, which is the last `APKRUN-FIXTURE: click <n>` line (0 before the first).
click_count() {
    adb_s logcat -d -s APKRUN-FIXTURE 2> /dev/null | awk '
        /APKRUN-FIXTURE: click [0-9]+/ {
            match($0, /click [0-9]+/)
            count = substr($0, RSTART + 6, RLENGTH - 6) + 0
        }
        END { print count + 0 }'
}

# Waits up to 5 s for the click count to rise above `before`. Prints the count and returns 1 when it does not.
wait_for_click_above() {
    local before="$1"
    local count=0
    for _ in $(seq 1 20); do
        count="$(click_count)"
        if ((count > before)); then
            printf '%s\n' "$count"
            return 0
        fi
        sleep 0.25
    done
    printf '%s\n' "$count"
    return 1
}

hits=0
for ((tap = 1; tap <= taps; tap++)); do
    before="$(click_count)"
    if ! adb_s shell input -d 0 tap "$tap_x" "$tap_y"; then
        printf 'tap %d/%d: adb shell input failed at pixel (%s, %s)\n' "$tap" "$taps" "$tap_x" "$tap_y" >&2
        exit 1
    fi
    if after="$(wait_for_click_above "$before")"; then
        hits=$((hits + 1))
        result="hit (click $after)"
    else
        result="miss (no click above $before within 5 s)"
    fi
    printf 'tap %d/%d: window (%s, %s) -> pixel (%s, %s): %s\n' \
        "$tap" "$taps" "$window_x" "$window_y" "$tap_x" "$tap_y" "$result"
done

printf 'hits: %d of %d taps\n' "$hits" "$taps"
if ((hits != taps)); then
    exit 1
fi
