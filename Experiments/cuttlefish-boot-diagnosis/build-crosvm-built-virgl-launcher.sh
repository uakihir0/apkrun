#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s /absolute/path/to/crosvm-built-virgl-launcher\n' "$0" >&2
  exit 2
fi

output=$1
case "$output" in
  /*) ;;
  *)
    printf '%s\n' 'The launcher output path must be absolute.' >&2
    exit 2
    ;;
esac

script_dir=${0%/*}
if [ "$script_dir" = "$0" ]; then
  script_dir=.
fi
script_dir=$(CDPATH= cd "$script_dir" && pwd -P)
source_file="$script_dir/crosvm-built-virgl-launcher.c"
compiler=${CC:-cc}
readelf=${READELF:-readelf}
sha256sum=${SHA256SUM:-sha256sum}
expected_crosvm_sha256=48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7
expected_gfxstream_sha256=c8e1f380e2ebfbe5814c57ba1f81d94659be0d6771edac421493cac02575f503

output_directory=${output%/*}
if [ -z "$output_directory" ]; then
  output_directory=/
fi
for input in "$output_directory/crosvm" \
  "$output_directory/libgfxstream_backend.so"; do
  if [ -L "$input" ] || [ ! -f "$input" ]; then
    printf 'Expected an adjacent regular diagnostic binary: %s\n' "$input" >&2
    exit 1
  fi
done
crosvm_sha256=$("$sha256sum" -- "$output_directory/crosvm")
crosvm_sha256=${crosvm_sha256%% *}
gfxstream_sha256=$("$sha256sum" -- "$output_directory/libgfxstream_backend.so")
gfxstream_sha256=${gfxstream_sha256%% *}
for digest in "$crosvm_sha256" "$gfxstream_sha256"; do
  if ! printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
    printf '%s\n' 'Could not calculate a valid SHA-256 digest for diagnostic binaries.' >&2
    exit 1
  fi
done
if [ "$crosvm_sha256" != "$expected_crosvm_sha256" ] ||
  [ "$gfxstream_sha256" != "$expected_gfxstream_sha256" ]; then
  printf '%s\n' 'Adjacent binaries do not match the pinned diagnostic build.' >&2
  exit 1
fi
if [ -e "$output" ] || [ -L "$output" ]; then
  printf '%s\n' 'The launcher output path must not already exist.' >&2
  exit 1
fi
mkdir -p "$output_directory"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -static \
  "-DAPKRUN_EXPECTED_CROSVM_SHA256=\"$crosvm_sha256\"" \
  "-DAPKRUN_EXPECTED_GFXSTREAM_SHA256=\"$gfxstream_sha256\"" \
  -o "$output" "$source_file"

program_headers=$("$readelf" --program-headers "$output")
if printf '%s\n' "$program_headers" | grep -q 'INTERP'; then
  printf '%s\n' 'The diagnostic launcher must be statically linked.' >&2
  exit 1
fi

machine=$("$readelf" --file-header "$output" |
  sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
if [ "$machine" != AArch64 ]; then
  printf 'The diagnostic launcher must target AArch64; got %s.\n' "$machine" >&2
  exit 1
fi

chmod 755 "$output"
printf '%s\n' 'Built and verified a static AArch64 diagnostic launcher.'
