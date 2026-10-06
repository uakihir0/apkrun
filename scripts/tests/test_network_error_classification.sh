#!/bin/sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
. "$repo_root/Tests/Fixtures/linux/network-errors.sh"

expect_socket_failure() {
    if ! apkrun_is_external_socket_connect_error "$1"; then
        printf 'FAIL expected an external socket-connect failure: %s\n' "$1" >&2
        exit 1
    fi
}

expect_download_timeout() {
    if ! apkrun_is_external_download_timeout "$1"; then
        printf 'FAIL expected an external download timeout: %s\n' "$1" >&2
        exit 1
    fi
}

expect_failure() {
    if apkrun_is_external_socket_connect_error "$1" \
        || apkrun_is_external_download_timeout "$1"; then
        printf 'FAIL unexpected external classification: %s\n' "$1" >&2
        exit 1
    fi
}

expect_socket_failure 'Connecting to example.test (192.0.2.1:443)
wget: can'\''t connect to remote host (192.0.2.1): Connection timed out'
expect_socket_failure 'wget: can'\''t connect to remote host (192.0.2.1): Network is unreachable'
expect_download_timeout 'wget: download timed out'
expect_failure 'ssl_client: TLS handshake failed: Connection reset by peer'
expect_failure 'wget: TLS request failed: Connection reset by peer'
expect_failure 'debug: wget: can'\''t connect to remote host (192.0.2.1): Connection timed out'
expect_failure 'debug: wget: download timed out'
expect_failure 'ssl_client: handshake stalled
wget: download timed out'
expect_failure 'wget: TLS handshake stalled
wget: download timed out'

oversized_output=$(
    printf 'wget: download timed out\n'
    head -c 4200 /dev/zero | tr '\000' 'x'
    printf '\nssl_client: TLS handshake failed\n'
)
captured_prefix="$(printf '%s' "$oversized_output" | head -c 4097)"
if ! apkrun_external_output_is_truncated "$captured_prefix"; then
    printf 'FAIL expected output over 4096 bytes to be marked truncated\n' >&2
    exit 1
fi
expect_failure "$captured_prefix"

newline_overflow_output=$(
    printf 'wget: download timed out\n'
    head -c 4071 /dev/zero | tr '\000' 'x'
    printf '\nssl_client: TLS handshake failed\n'
)
newline_capture=$(
    printf '%s' "$newline_overflow_output" | head -c 4097
    printf '.'
)
newline_capture="${newline_capture%.}"
if ! apkrun_external_output_is_truncated "$newline_capture"; then
    printf 'FAIL expected a newline sentinel at byte 4097 to remain detectable\n' >&2
    exit 1
fi
expect_failure "$newline_capture"

printf 'network error classification tests passed\n'
