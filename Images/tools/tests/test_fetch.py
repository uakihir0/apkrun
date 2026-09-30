"""Tests for Build API acquisition and manual artifact verification."""

from __future__ import annotations

import hashlib
import json
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

import pytest

from apkrun_image.fetch import FetchError, fetch_artifacts

ARTIFACT_NAME = "aosp_cf_arm64_only_phone-img-16373615.zip"
ARTIFACT_BYTES = b"pinned-build-fixture"


class FakeBuildAPI:
    """A loopback Build API and signed artifact endpoint."""

    def __init__(self) -> None:
        self.download_requests: list[str | None] = []
        self.interrupt_once = False
        self.interrupted = False

        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                if parsed.path.endswith("/attempts/latest/artifacts"):
                    assert parse_qs(parsed.query)["key"] == ["test-secret"]
                    payload = {
                        "artifacts": [
                            {
                                "name": ARTIFACT_NAME,
                                "size": len(ARTIFACT_BYTES),
                                "sha256": hashlib.sha256(ARTIFACT_BYTES).hexdigest(),
                            }
                        ]
                    }
                    self.send_json(payload)
                    return
                if parsed.path.endswith(f"/artifacts/{ARTIFACT_NAME}/url"):
                    assert parse_qs(parsed.query)["key"] == ["test-secret"]
                    self.send_json({"signedUrl": f"http://127.0.0.1:{self.server.server_port}/download"})
                    return
                if parsed.path == "/download":
                    range_header = self.headers.get("Range")
                    owner.download_requests.append(range_header)
                    start = 0
                    if range_header is not None:
                        start = int(range_header.removeprefix("bytes=").removesuffix("-"))
                    if owner.interrupt_once and not owner.interrupted:
                        owner.interrupted = True
                        part = ARTIFACT_BYTES[:7]
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(ARTIFACT_BYTES)))
                        self.end_headers()
                        self.wfile.write(part)
                        self.wfile.flush()
                        self.close_connection = True
                        return
                    body = ARTIFACT_BYTES[start:]
                    self.send_response(206 if range_header is not None else 200)
                    if range_header is not None:
                        self.send_header(
                            "Content-Range",
                            f"bytes {start}-{len(ARTIFACT_BYTES) - 1}/{len(ARTIFACT_BYTES)}",
                        )
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_error(404)

            def send_json(self, value: dict[str, Any]) -> None:
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self) -> str:
        """Return the fake API origin."""
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self) -> None:
        """Stop the loopback server."""
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


@pytest.fixture
def fake_api() -> Iterator[FakeBuildAPI]:
    """Start and stop one local fake Build API."""
    server = FakeBuildAPI()
    try:
        yield server
    finally:
        server.close()


def fetch_arguments(directory: Path, api_key: str | None) -> dict[str, Any]:
    """Create common pinned-build test arguments."""
    return {
        "branch": "aosp-android-latest-release",
        "target": "aosp_cf_arm64_only_phone-userdebug",
        "build_id": "16373615",
        "pattern": "aosp_cf_arm64_only_phone-img-*.zip",
        "output_directory": directory,
        "api_key": api_key,
    }


def test_manual_download_is_hashed_and_verified_again(tmp_path: Path) -> None:
    """The keyless path accepts a manual file and verifies it on each run."""
    artifact = tmp_path / ARTIFACT_NAME
    artifact.write_bytes(ARTIFACT_BYTES)

    records = fetch_artifacts(**fetch_arguments(tmp_path, None))
    manifest = json.loads((tmp_path / "fetch.json").read_text())
    second_records = fetch_artifacts(**fetch_arguments(tmp_path, None))

    expected_digest = hashlib.sha256(ARTIFACT_BYTES).hexdigest()
    assert records[0].sha256 == expected_digest
    assert manifest["artifacts"] == [
        {"name": ARTIFACT_NAME, "sha256": expected_digest, "size": len(ARTIFACT_BYTES)}
    ]
    assert second_records == records


def test_manual_download_reports_next_step_when_missing(tmp_path: Path) -> None:
    """Missing manual input has an actionable API-key or download instruction."""
    with pytest.raises(FetchError, match="APKRUN_ANDROID_BUILD_API_KEY"):
        fetch_artifacts(**fetch_arguments(tmp_path, None))


def test_build_api_downloads_signed_artifact_and_writes_hash(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """The API listing, signed URL, bytes, and manifest form one verified flow."""
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    records = fetch_artifacts(**arguments)

    expected_digest = hashlib.sha256(ARTIFACT_BYTES).hexdigest()
    assert (tmp_path / ARTIFACT_NAME).read_bytes() == ARTIFACT_BYTES
    assert records[0].sha256 == expected_digest
    assert fake_api.download_requests == [None]
    assert not (tmp_path / f"{ARTIFACT_NAME}.partial").exists()


def test_interrupted_download_resumes_with_http_range(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """An interrupted transfer leaves a partial file and resumes from its size."""
    fake_api.interrupt_once = True
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="run fetch again to resume"):
        fetch_artifacts(**arguments)

    assert (tmp_path / f"{ARTIFACT_NAME}.partial").read_bytes() == ARTIFACT_BYTES[:7]
    records = fetch_artifacts(**arguments)

    assert (tmp_path / ARTIFACT_NAME).read_bytes() == ARTIFACT_BYTES
    assert records[0].sha256 == hashlib.sha256(ARTIFACT_BYTES).hexdigest()
    assert fake_api.download_requests == [None, "bytes=7-"]


def test_changed_local_artifact_fails_verification(tmp_path: Path) -> None:
    """A previously recorded artifact cannot be silently reused after mutation."""
    artifact = tmp_path / ARTIFACT_NAME
    artifact.write_bytes(ARTIFACT_BYTES)
    fetch_artifacts(**fetch_arguments(tmp_path, None))
    artifact.write_bytes(b"tampered")

    with pytest.raises(FetchError, match="size"):
        fetch_artifacts(**fetch_arguments(tmp_path, None))
