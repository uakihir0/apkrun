#!/usr/bin/env bash
# Regenerates the checked-in Swift sources of the guest protocol from
# Packages/GuestProtocol/proto (guest-protocol.md §2). The tools come only from
# build/tools, which scripts/bootstrap fills with the versions pinned in
# scripts/tool-versions.env and Package.resolved. Nothing on PATH is used.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tool-versions.env"

protoc="$repo_root/build/tools/protoc-$PROTOC_VERSION/bin/protoc"
protoc_gen_swift="$repo_root/build/tools/protoc-gen-swift/bin/protoc-gen-swift"
package_dir="$repo_root/Packages/GuestProtocol"
swift_out="$package_dir/Sources/GuestProtocol/Generated"

for tool in "$protoc" "$protoc_gen_swift"; do
    if [[ ! -x "$tool" ]]; then
        printf 'generate-protos: missing %s; run scripts/bootstrap\n' "$tool" >&2
        exit 1
    fi
done

# Remove stale output, so that a deleted .proto file also removes its Swift file.
rm -rf "$swift_out"
mkdir -p "$swift_out"

(
    cd "$package_dir/proto"
    "$protoc" \
        --plugin="protoc-gen-swift=$protoc_gen_swift" \
        --swift_out="$swift_out" \
        --swift_opt=Visibility=Public,FileNaming=DropPath \
        apkrun/guest/v1/*.proto
)

printf 'generate-protos: wrote %s Swift files to Packages/GuestProtocol/Sources/GuestProtocol/Generated\n' \
    "$(find "$swift_out" -name '*.pb.swift' | wc -l | tr -d ' ')"

# Golden frames (guest-protocol.md §16), shared by the Swift and Kotlin tests. Each
# valid-*.txtpb is a text-format Envelope. protoc encodes it, and the length prefix is
# added here. The invalid-*.bin frames are fixed byte sequences.
frames_dir="$package_dir/testdata/frames"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
rm -f "$frames_dir"/*.bin

# write_frame <body file> <frame file>: 4-byte big-endian length, then the body.
write_frame() {
    local length
    length="$(wc -c < "$1" | tr -d ' ')"
    printf '%08x' "$length" | xxd -r -p > "$2"
    cat "$1" >> "$2"
}

for source in "$frames_dir"/valid-*.txtpb; do
    name="$(basename "$source" .txtpb)"
    (
        cd "$package_dir/proto"
        "$protoc" -I . --encode=apkrun.guest.v1.Envelope apkrun/guest/v1/*.proto
    ) < "$source" > "$body"
    write_frame "$body" "$frames_dir/$name.bin"
done

# A length of 0 is invalid.
printf '\000\000\000\000' > "$frames_dir/invalid-zero-length.bin"
# 0x00400001 is one byte over the 4 MiB limit. The body is never read.
printf '00400001' | xxd -r -p > "$frames_dir/invalid-oversize.bin"
printf '\010\001' >> "$frames_dir/invalid-oversize.bin"
# The prefix promises 32 bytes, and only 6 follow.
printf '00000020' | xxd -r -p > "$frames_dir/invalid-truncated.bin"
printf '\010\001\022\002\012\000' >> "$frames_dir/invalid-truncated.bin"
# A 3-byte body that does not decode as an Envelope: a varint that never ends.
printf '00000003' | xxd -r -p > "$frames_dir/invalid-malformed.bin"
printf '\377\377\377' >> "$frames_dir/invalid-malformed.bin"

printf 'generate-protos: wrote %s golden frames to Packages/GuestProtocol/testdata/frames\n' \
    "$(find "$frames_dir" -name '*.bin' | wc -l | tr -d ' ')"
