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
