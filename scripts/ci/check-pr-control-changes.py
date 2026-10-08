#!/usr/bin/env python3
"""Require a current human reviewer to approve CI control-file changes."""

import json
import os
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


APPROVAL_LABEL = "ci-policy-approved"
API_VERSION = "2022-11-28"
CONTROL_DIRECTORIES = (
    ".github/workflows/",
    ".github/actions/",
    "gradle/",
    "Guest/gradle/",
    "scripts/build/",
    "scripts/ci/",
    "scripts/tests/",
    "scripts/tools/",
)
CONTROL_FILES = {
    ".swift-format",
    ".swift-format-tests",
    ".xcode-version",
    "docs/01-architecture/modules.md",
    "ThirdParty/ThirdParty.lock.json",
    "scripts/bootstrap",
    "scripts/errorgen.swift",
    "scripts/generate-project.sh",
    "scripts/generate-protos.sh",
    "scripts/smoke-products.sh",
    "scripts/release/check-release-build.sh",
    # Generates ThirdPartyNotices.html; CI and the release check both run it.
    "scripts/release/generate-notices.py",
    "scripts/tool-versions.env",
}
CONTROL_BASENAMES = {
    "Cargo.toml",
    "Cargo.lock",
    "clippy.toml",
    ".clippy.toml",
    "rustfmt.toml",
    ".rustfmt.toml",
    "rust-toolchain",
    "rust-toolchain.toml",
    "Package.swift",
    "Package.resolved",
    "project.yml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "gradlew",
    "gradlew.bat",
    "gradle.properties",
    "gradle.lockfile",
    "gradle-wrapper.jar",
    "gradle-wrapper.properties",
    "libs.versions.toml",
}
CONTROL_DIRECTORY_NAMES = {"buildSrc", "build-logic", ".cargo"}
# "tests" and "test" cover the test trees outside Swift targets, such as
# Images/tools/tests (pytest in CI) and Gradle src/test.
TEST_DIRECTORIES = {"Tests", "UITests", "tests", "test"}


def pull_request_revision(
    pull_request: dict[str, Any],
) -> Optional[tuple[str, str, str, str]]:
    head = pull_request.get("head")
    base = pull_request.get("base")
    base_repository = base.get("repo") if isinstance(base, dict) else None
    if not isinstance(head, dict) or not isinstance(base, dict):
        return None
    head_sha = head.get("sha")
    base_ref = base.get("ref")
    base_sha = base.get("sha")
    repository = (
        base_repository.get("full_name") if isinstance(base_repository, dict) else None
    )
    values = (head_sha, base_ref, base_sha, repository)
    if not all(isinstance(value, str) and value for value in values):
        return None
    return head_sha, base_ref, base_sha, repository.casefold()


def same_pull_request_revision(
    first: dict[str, Any], second: dict[str, Any]
) -> bool:
    first_revision = pull_request_revision(first)
    return (
        first_revision is not None
        and first_revision == pull_request_revision(second)
    )


def is_control_path(path: str) -> bool:
    normalized = PurePosixPath(path).as_posix()
    if normalized in CONTROL_FILES:
        return True
    if normalized.startswith(CONTROL_DIRECTORIES):
        return True
    parts = PurePosixPath(normalized).parts
    name = PurePosixPath(normalized).name
    return (
        name in CONTROL_BASENAMES
        or any(part in CONTROL_DIRECTORY_NAMES for part in parts)
        or any(part in TEST_DIRECTORIES for part in parts)
        or (normalized.startswith("scripts/") and name.startswith("check-"))
    )


def is_authorized(
    event_name: str,
    event: dict[str, Any],
    current_pull_request: dict[str, Any],
    changed_paths: list[str],
    reviews: list[dict[str, Any]],
    repository: str,
) -> bool:
    if event_name != "pull_request_target":
        return False
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        return False

    event_revision = pull_request_revision(pull_request)
    current_revision = pull_request_revision(current_pull_request)
    if event_revision is None or event_revision != current_revision:
        return False
    current_head_sha = current_revision[0]
    _, current_base_ref, _, current_base_repository = current_revision
    event_base = pull_request.get("base")
    if not isinstance(event_base, dict):
        return False
    event_base_repository = event_base.get("repo")
    if not isinstance(event_base_repository, dict):
        return False
    event_base_repository_name = event_base_repository.get("full_name")
    if (
        current_base_ref != "main"
        or not isinstance(event_base_repository_name, str)
        or event_base_repository_name.casefold() != repository.casefold()
        or current_base_repository != repository.casefold()
    ):
        return False

    changed_control_paths = [path for path in changed_paths if is_control_path(path)]
    if not changed_control_paths:
        return True

    author = current_pull_request.get("user")
    author_login = author.get("login") if isinstance(author, dict) else None
    if not isinstance(author_login, str) or not author_login:
        return False
    latest_review_by_user: dict[str, str] = {}
    for review in reviews:
        reviewer = review.get("user")
        reviewer_login = reviewer.get("login") if isinstance(reviewer, dict) else None
        if (
            isinstance(reviewer_login, str)
            and reviewer.get("type") == "User"
            and reviewer_login.casefold() != author_login.casefold()
            and review.get("commit_id") == current_head_sha
            and isinstance(review.get("state"), str)
        ):
            latest_review_by_user[reviewer_login.casefold()] = review["state"]
    action = event.get("action")
    added_label = event.get("label")
    labels = current_pull_request.get("labels")
    sender = event.get("sender")
    sender_login = sender.get("login") if isinstance(sender, dict) else None
    if (
        action != "labeled"
        or not isinstance(added_label, dict)
        or added_label.get("name") != APPROVAL_LABEL
        or not isinstance(labels, list)
        or not isinstance(sender_login, str)
        or not isinstance(sender, dict)
        or sender.get("type") != "User"
        or sender_login.casefold() == author_login.casefold()
        or latest_review_by_user.get(sender_login.casefold()) != "APPROVED"
    ):
        return False
    return any(
        isinstance(label, dict) and label.get("name") == APPROVAL_LABEL
        for label in labels
    )


def api_json(url: str, token: str) -> Any:
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
        },
    )
    with urlopen(request, timeout=20) as response:
        return json.loads(response.read())


def pull_request_api_url(repository: str, pull_number: int) -> str:
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repository):
        raise ValueError("GITHUB_REPOSITORY must be owner/repository")
    if pull_number < 1:
        raise ValueError("pull request number must be positive")
    return f"https://api.github.com/repos/{repository}/pulls/{pull_number}"


def commit_compare_api_url(repository: str, base_sha: str, head_sha: str) -> str:
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repository):
        raise ValueError("GITHUB_REPOSITORY must be owner/repository")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", base_sha):
        raise ValueError("pull request base SHA is malformed")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", head_sha):
        raise ValueError("pull request head SHA is malformed")
    return (
        f"https://api.github.com/repos/{repository}/compare/"
        f"{base_sha}...{head_sha}?{urlencode({'per_page': 100, 'page': 1})}"
    )


def changed_files(
    repository: str, base_sha: str, head_sha: str, token: str
) -> list[str]:
    url = commit_compare_api_url(repository, base_sha, head_sha)
    comparison = api_json(url, token)
    if not isinstance(comparison, dict) or not isinstance(
        comparison.get("files"), list
    ):
        raise ValueError("GitHub returned a malformed commit comparison")
    files = comparison["files"]
    if len(files) >= 300:
        raise ValueError(
            "pull request has at least 300 changed files or reached the compare "
            "API limit; split it so all paths can be checked"
        )

    paths: list[str] = []
    for file in files:
        if not isinstance(file, dict) or not isinstance(file.get("filename"), str):
            raise ValueError("GitHub returned a malformed commit comparison file")
        paths.append(file["filename"])
        previous_filename = file.get("previous_filename")
        if previous_filename is not None:
            if not isinstance(previous_filename, str):
                raise ValueError("GitHub returned a malformed previous file path")
            paths.append(previous_filename)
    return paths


def pull_request_reviews(base_url: str, token: str) -> list[dict[str, Any]]:
    reviews: list[dict[str, Any]] = []
    page = 1
    while True:
        url = f"{base_url}/reviews?{urlencode({'per_page': 100, 'page': page})}"
        page_reviews = api_json(url, token)
        if not isinstance(page_reviews, list) or not all(
            isinstance(review, dict) for review in page_reviews
        ):
            raise ValueError("GitHub returned a malformed pull request review list")
        reviews.extend(page_reviews)
        if len(page_reviews) < 100:
            return reviews
        if page >= 100:
            raise ValueError(
                "pull request has at least 10000 reviews; unable to verify approval"
            )
        page += 1


def main() -> int:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    token = os.environ.get("GITHUB_TOKEN")
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not event_path or not token or not repository:
        print(
            "check-pr-control-changes: required GitHub environment is missing",
            file=sys.stderr,
        )
        return 2

    try:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
        if not isinstance(event, dict):
            raise ValueError("event payload must be an object")
        pull_request = event.get("pull_request")
        if not isinstance(pull_request, dict):
            raise ValueError("pull request details are missing from the event")
        pull_number = event.get("number")
        if not isinstance(pull_number, int):
            raise ValueError("pull request number is missing from the event")

        base_url = pull_request_api_url(repository, pull_number)
        current_pull_request = api_json(base_url, token)
        if not isinstance(current_pull_request, dict):
            raise ValueError("GitHub returned malformed pull request metadata")
        current_revision = pull_request_revision(current_pull_request)
        if current_revision is None:
            raise ValueError("GitHub returned incomplete pull request revision data")
        current_head_sha, _, current_base_sha, _ = current_revision
        paths = changed_files(repository, current_base_sha, current_head_sha, token)
        reviews = (
            pull_request_reviews(base_url, token)
            if any(is_control_path(path) for path in paths)
            else []
        )
        verified_pull_request = api_json(base_url, token)
        if not isinstance(verified_pull_request, dict):
            raise ValueError("GitHub returned malformed pull request metadata")
        if not same_pull_request_revision(current_pull_request, verified_pull_request):
            raise ValueError(
                "pull request head or base changed during policy verification"
            )
        current_pull_request = verified_pull_request
    except (OSError, json.JSONDecodeError, ValueError, HTTPError, URLError) as error:
        print(
            f"check-pr-control-changes: unable to verify pull request: {error}",
            file=sys.stderr,
        )
        return 2

    if not is_authorized(
        os.environ.get("GITHUB_EVENT_NAME", ""),
        event,
        current_pull_request,
        paths,
        reviews,
        repository,
    ):
        print(
            "check-pr-control-changes: CI control files changed or the approval is "
            f"stale; a maintainer must review the current commit and add "
            f"'{APPROVAL_LABEL}'",
            file=sys.stderr,
        )
        return 1
    print("check-pr-control-changes: authorized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
