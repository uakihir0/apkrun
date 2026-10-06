#!/bin/sh

apkrun_has_wget_client_error() {
    printf '%s\n' "$1" | grep -Eiq '^(ssl_client:|wget: (TLS|SSL|error))'
}

apkrun_external_output_is_truncated() {
    [ "$(printf '%s' "$1" | wc -c | tr -d '[:space:]')" -gt 4096 ]
}

apkrun_is_external_socket_connect_error() {
    if apkrun_external_output_is_truncated "$1" \
        || apkrun_has_wget_client_error "$1"; then
        return 1
    fi
    printf '%s\n' "$1" | grep -Eiq \
        '^wget: can.t connect to remote host \([^)]*\): (Connection timed out|Operation timed out|Network is unreachable|No route to host|Connection refused|Connection reset by peer|Connection aborted|Host is down)$'
}

apkrun_is_external_download_timeout() {
    if apkrun_external_output_is_truncated "$1" \
        || apkrun_has_wget_client_error "$1"; then
        return 1
    fi
    printf '%s\n' "$1" | grep -Eiq '^wget: download timed out$'
}
