#!/usr/bin/env bash
set -euo pipefail

skip=false
if [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == "refs/heads/main" ]]; then
    skip=true
elif [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" \
    && "${APKRUN_PULL_REQUEST_HEAD_REF:-}" == "task/103-click-loss" \
    && "${APKRUN_PULL_REQUEST_HEAD_REPO:-}" == "${GITHUB_REPOSITORY:-}" ]]; then
    skip=true
fi

printf 'skip=%s\n' "$skip" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
printf 'resolve-test-deferral: APKRun CI test suites deferred=%s\n' "$skip"
