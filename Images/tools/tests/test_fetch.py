"""Tests for Build API acquisition and manual artifact verification."""

from __future__ import annotations

import hashlib
import http.client
import json
import threading
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, cast
from urllib.parse import parse_qs, urlparse
from urllib.request import Request

import pytest

import apkrun_image.fetch as fetch_module
from apkrun_image.fetch import Artifact, FetchError, fetch_artifacts

ARTIFACT_NAME = "aosp_cf_arm64_only_phone-img-16373615.zip"
ARTIFACT_BYTES = b"pinned-build-fixture"


class FakeBuildAPI:
    """A loopback Build API and signed artifact endpoint."""

    def __init__(self) -> None:
        self.download_requests: list[str | None] = []
        self.interrupt_once = False
        self.interrupted = False
        self.include_digest = True
        self.download_bytes = ARTIFACT_BYTES
        self.redirect_download = False
        self.redirect_download_same_origin = False
        self.redirect_api = False

        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                if parsed.path.endswith("/attempts/latest/artifacts"):
                    assert parse_qs(parsed.query)["key"] == ["test-secret"]
                    if owner.redirect_api:
                        self.send_response(302)
                        self.send_header("Location", "http://example.invalid/metadata")
                        self.end_headers()
                        return
                    metadata = {
                        "name": ARTIFACT_NAME,
                        "size": len(ARTIFACT_BYTES),
                    }
                    if owner.include_digest:
                        metadata["sha256"] = hashlib.sha256(ARTIFACT_BYTES).hexdigest()
                    payload = {
                        "artifacts": [
                            {"name": "subdir/debug-symbols.zip", "size": 42},
                            metadata,
                        ]
                    }
                    self.send_json(payload)
                    return
                if parsed.path.endswith(f"/artifacts/{ARTIFACT_NAME}/url"):
                    assert parse_qs(parsed.query)["key"] == ["test-secret"]
                    endpoint = "/redirect" if owner.redirect_download else "/download"
                    self.send_json(
                        {"signedUrl": (f"http://127.0.0.1:{self.server.server_port}{endpoint}")}
                    )
                    return
                if parsed.path == "/redirect":
                    self.send_response(302)
                    if owner.redirect_download_same_origin:
                        target = f"http://127.0.0.1:{self.server.server_port}/download"
                    else:
                        target = "http://example.invalid/artifact"
                    self.send_header("Location", target)
                    self.end_headers()
                    return
                if parsed.path == "/download":
                    range_header = self.headers.get("Range")
                    owner.download_requests.append(range_header)
                    start = 0
                    if range_header is not None:
                        start = int(range_header.removeprefix("bytes=").removesuffix("-"))
                    if owner.interrupt_once and not owner.interrupted:
                        owner.interrupted = True
                        part = owner.download_bytes[:7]
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(owner.download_bytes)))
                        self.end_headers()
                        self.wfile.write(part)
                        self.wfile.flush()
                        self.close_connection = True
                        return
                    body = owner.download_bytes[start:]
                    self.send_response(206 if range_header is not None else 200)
                    if range_header is not None:
                        self.send_header(
                            "Content-Range",
                            f"bytes {start}-{len(owner.download_bytes) - 1}/"
                            f"{len(owner.download_bytes)}",
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
        "allow_loopback_http_for_testing": True,
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
    assert manifest["branchProvenance"] == "caller-asserted"
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


def test_concurrent_fetches_for_one_directory_are_serialized(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """Concurrent callers share one verified download and its manifest record."""
    output_directory = tmp_path / "download"
    arguments = fetch_arguments(output_directory, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(fetch_artifacts, **arguments) for _ in range(2)]
        results = [future.result() for future in futures]

    assert results[0] == results[1]
    assert fake_api.download_requests == [None]
    assert (output_directory / ARTIFACT_NAME).read_bytes() == ARTIFACT_BYTES
    assert not (output_directory / f"{ARTIFACT_NAME}.partial").exists()
    assert not (tmp_path / ".download.apkrun-fetch.lock").exists()


def test_fetch_lock_stays_stable_if_the_output_directory_is_replaced(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Renaming the output directory cannot bypass its parent-directory lock."""
    first_entered = threading.Event()
    second_entered = threading.Event()
    release_first = threading.Event()
    call_count = 0

    def blocked_fetch(**_arguments: object) -> list[object]:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            first_entered.set()
            assert release_first.wait(timeout=5)
        else:
            second_entered.set()
        return []

    monkeypatch.setattr(fetch_module, "_fetch_artifacts_locked", blocked_fetch)
    output_directory = tmp_path / "download"
    arguments = fetch_arguments(output_directory, "test-secret")
    output_directory = arguments["output_directory"]

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(fetch_artifacts, **arguments)
        assert first_entered.wait(timeout=5)
        output_directory.rename(tmp_path / "moved-output")
        output_directory.mkdir()
        second = executor.submit(fetch_artifacts, **arguments)

        assert not second_entered.wait(timeout=0.1)
        release_first.set()
        first.result(timeout=5)
        second.result(timeout=5)

    assert second_entered.is_set()


def test_partial_cleanup_preserves_a_path_replacement(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Cleanup restores a replacement when the partial path changes before rename."""
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    partial.write_bytes(b"owned partial")
    expected_identity = fetch_module._file_identity(partial.stat())
    replacement = tmp_path / "replacement"
    replacement.write_bytes(b"other process")
    real_rename = fetch_module.os.rename
    swapped = False

    def swap_then_rename(
        source: str,
        destination: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
    ) -> None:
        nonlocal swapped
        if source == partial.name and ".cleanup-" in destination and not swapped:
            swapped = True
            replacement.replace(partial)
        real_rename(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
        )

    monkeypatch.setattr(fetch_module.os, "rename", swap_then_rename)
    directory_descriptor = fetch_module.os.open(tmp_path, fetch_module.os.O_RDONLY)
    try:
        fetch_module._cleanup_owned_partial(
            directory_descriptor,
            partial.name,
            expected_identity,
        )
    finally:
        fetch_module.os.close(directory_descriptor)

    assert swapped
    assert partial.read_bytes() == b"other process"
    assert not list(tmp_path.glob("*.cleanup-*"))
    assert not list(tmp_path.glob(".*.cleanup-*"))


def test_api_artifact_sizes_reject_fractional_numbers() -> None:
    """A fractional JSON number cannot be truncated into a different size."""
    with pytest.raises(FetchError, match="invalid size"):
        fetch_module._positive_size(1.9, ARTIFACT_NAME)

    assert fetch_module._positive_size("19", ARTIFACT_NAME) == 19
    assert fetch_module._positive_size(fetch_module.MAX_ARTIFACT_SIZE, ARTIFACT_NAME) == (
        fetch_module.MAX_ARTIFACT_SIZE
    )
    with pytest.raises(FetchError, match="download limit"):
        fetch_module._positive_size(fetch_module.MAX_ARTIFACT_SIZE + 1, ARTIFACT_NAME)
    with pytest.raises(FetchError, match="invalid size"):
        fetch_module._positive_size("9" * 4301, ARTIFACT_NAME)


def test_existing_file_verification_stops_if_the_open_file_grows(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The hash reader is bounded even when a file grows after it is opened."""
    path = tmp_path / ARTIFACT_NAME
    path.write_bytes(b"four")
    real_hash_descriptor = fetch_module._sha256_descriptor

    def grow_then_hash(descriptor: int, *, maximum_size: int) -> str:
        with path.open("ab") as stream:
            stream.write(b"!")
        return real_hash_descriptor(descriptor, maximum_size=maximum_size)

    monkeypatch.setattr(fetch_module, "_sha256_descriptor", grow_then_hash)

    with pytest.raises(FetchError, match="grew beyond its expected size"):
        fetch_module._verify_file(
            path,
            Artifact(name=ARTIFACT_NAME, size=4),
            record=None,
        )


def test_partial_finalization_stops_if_the_open_file_grows(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Publishing reads at most one excess byte from a concurrently grown partial."""
    path = tmp_path / f"{ARTIFACT_NAME}.partial"
    path.write_bytes(b"four")
    expected_identity = fetch_module._file_identity(path.stat())
    real_read = fetch_module.os.read
    real_write = fetch_module.os.write
    requested_read_sizes: list[int] = []
    staged_writes: list[bytes] = []
    grew = False

    def grow_then_read(descriptor: int, size: int) -> bytes:
        nonlocal grew
        identity = fetch_module._file_identity(fetch_module.os.fstat(descriptor))
        if identity == expected_identity:
            requested_read_sizes.append(size)
        if identity == expected_identity and not grew:
            grew = True
            append_descriptor = fetch_module.os.open(
                path,
                fetch_module.os.O_WRONLY | fetch_module.os.O_APPEND,
            )
            try:
                real_write(append_descriptor, b"!")
            finally:
                fetch_module.os.close(append_descriptor)
        return real_read(descriptor, size)

    def capture_stage_write(descriptor: int, data: bytes | memoryview) -> int:
        if fetch_module._file_identity(fetch_module.os.fstat(descriptor)) != expected_identity:
            staged_writes.append(bytes(data))
        return real_write(descriptor, data)

    monkeypatch.setattr(fetch_module.os, "read", grow_then_read)
    monkeypatch.setattr(fetch_module.os, "write", capture_stage_write)

    with pytest.raises(FetchError, match="grew beyond its expected size"):
        fetch_module._publish_partial(
            path,
            Artifact(name=ARTIFACT_NAME, size=4),
            expected_sha256=None,
            expected_identity=expected_identity,
        )

    assert grew
    assert requested_read_sizes == [5]
    assert staged_writes == []
    assert path.read_bytes() == b"four!"
    assert not (tmp_path / ARTIFACT_NAME).exists()


def test_download_rejects_oversized_artifact_before_creating_partial(tmp_path: Path) -> None:
    """Direct callers cannot bypass the API size ceiling."""
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"

    with pytest.raises(FetchError, match="download limit"):
        fetch_module._download(
            url="https://artifact.example/download",
            partial_path=partial,
            artifact=Artifact(name=ARTIFACT_NAME, size=fetch_module.MAX_ARTIFACT_SIZE + 1),
        )

    assert not partial.exists()


def test_download_redirect_rejects_non_loopback_http_destination(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """A loopback test endpoint cannot redirect the client to an external HTTP host."""
    fake_api.redirect_download = True
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="redirected to an unsafe URL"):
        fetch_artifacts(**arguments)

    assert not (tmp_path / ARTIFACT_NAME).exists()
    assert not (tmp_path / f"{ARTIFACT_NAME}.partial").exists()


def test_download_redirect_allows_same_loopback_origin(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """A local Build API test endpoint can redirect within its own origin."""
    fake_api.redirect_download = True
    fake_api.redirect_download_same_origin = True
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    records = fetch_artifacts(**arguments)

    assert (tmp_path / ARTIFACT_NAME).read_bytes() == ARTIFACT_BYTES
    assert records[0].size == len(ARTIFACT_BYTES)


def test_download_redirect_rejects_https_to_loopback_http() -> None:
    """An HTTPS artifact host cannot downgrade even to a local HTTP endpoint."""
    handler = fetch_module._SafeRedirectHandler(allow_loopback_http_for_testing=True)

    with pytest.raises(FetchError, match="redirected to an unsafe URL"):
        handler.redirect_request(
            Request("https://artifacts.example/download"),
            None,
            302,
            "Found",
            {},
            "http://127.0.0.1/private",
        )


def test_loopback_redirect_cannot_change_ports() -> None:
    """Local test endpoints cannot use a redirect to reach another local service."""
    handler = fetch_module._SafeRedirectHandler(allow_loopback_http_for_testing=True)

    with pytest.raises(FetchError, match="redirected to an unsafe URL"):
        handler.redirect_request(
            Request("http://127.0.0.1:8000/metadata"),
            None,
            302,
            "Found",
            {},
            "http://127.0.0.1:8001/private",
        )


def test_api_request_rejects_unsafe_redirect(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """Build API JSON redirects are checked before a second request is opened."""
    fake_api.redirect_api = True
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="redirected to an unsafe URL"):
        fetch_artifacts(**arguments)

    assert not fake_api.download_requests


def test_api_request_rejects_loopback_http_without_test_override(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """Production callers cannot direct the Build API client to local HTTP."""
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url
    del arguments["allow_loopback_http_for_testing"]

    with pytest.raises(FetchError, match="request URL is unsafe"):
        fetch_artifacts(**arguments)


def test_signed_url_rejects_loopback_http_without_test_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An API response cannot make production downloads target loopback HTTP."""
    request_options: list[dict[str, object]] = []

    def return_loopback_signed_url(
        _url: str,
        **options: object,
    ) -> dict[str, str]:
        request_options.append(options)
        return {"signedUrl": "http://127.0.0.1:8080/artifact"}

    monkeypatch.setattr(fetch_module, "_request_json", return_loopback_signed_url)

    with pytest.raises(FetchError, match="unsafe download URL"):
        fetch_module._signed_url(
            base_url="https://build-api.example/v4",
            api_key="test-secret",
            build_id="16373615",
            target="aosp_cf_arm64_only_phone-userdebug",
            artifact_name=ARTIFACT_NAME,
        )

    assert request_options == [{"allow_loopback_http_for_testing": False}]


def test_api_json_response_is_bounded(monkeypatch: pytest.MonkeyPatch) -> None:
    """API metadata is read with a hard byte limit."""
    requested_sizes: list[int] = []

    class OversizedResponse:
        def __enter__(self) -> OversizedResponse:
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def read(self, size: int) -> bytes:
            requested_sizes.append(size)
            return b"x" * size

    monkeypatch.setattr(
        fetch_module,
        "_open_validated_url",
        lambda *_args, **_kwargs: OversizedResponse(),
    )

    with pytest.raises(FetchError, match="response exceeds"):
        fetch_module._request_json(
            "http://127.0.0.1/metadata",
            allow_loopback_http_for_testing=True,
        )

    assert requested_sizes == [fetch_module.MAX_API_RESPONSE_SIZE + 1]


def test_api_json_translates_extreme_integer_parse_errors_to_fetch_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A huge JSON integer cannot escape the fetch CLI as a raw ValueError."""

    class NumericResponse:
        def __enter__(self) -> NumericResponse:
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def read(self, _size: int = -1) -> bytes:
            return b'{"size":' + b"9" * 4301 + b"}"

    monkeypatch.setattr(
        fetch_module,
        "_open_validated_url",
        lambda *_args, **_kwargs: NumericResponse(),
    )

    with pytest.raises(FetchError, match="invalid JSON"):
        fetch_module._request_json(
            "http://127.0.0.1/metadata",
            allow_loopback_http_for_testing=True,
        )


def test_api_pagination_has_a_page_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    """Unique continuation tokens cannot make metadata listing run indefinitely."""
    page_count = 0

    def next_page(*_arguments: object, **_keywords: object) -> dict[str, object]:
        nonlocal page_count
        page_count += 1
        return {"artifacts": [], "nextPageToken": f"page-{page_count}"}

    monkeypatch.setattr(fetch_module, "_request_json", next_page)

    with pytest.raises(FetchError, match="more than 100 artifact pages"):
        fetch_module._list_artifacts(
            base_url="http://127.0.0.1",
            api_key="test",
            build_id="1",
            target="target-userdebug",
            pattern="*.zip",
        )

    assert page_count == fetch_module.MAX_API_PAGES


def test_api_pagination_rejects_oversized_tokens(monkeypatch: pytest.MonkeyPatch) -> None:
    """Continuation tokens cannot grow retained state without a bound."""
    monkeypatch.setattr(
        fetch_module,
        "_request_json",
        lambda *_arguments, **_keywords: {
            "artifacts": [],
            "nextPageToken": "x" * (fetch_module.MAX_PAGE_TOKEN_SIZE + 1),
        },
    )

    with pytest.raises(FetchError, match="pagination token exceeds"):
        fetch_module._list_artifacts(
            base_url="http://127.0.0.1",
            api_key="test",
            build_id="1",
            target="target-userdebug",
            pattern="*.zip",
        )


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


def test_api_fetch_preserves_unrecorded_file_without_upstream_digest(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """An unverified destination is preserved until the user moves it aside."""
    fake_api.include_digest = False
    artifact = tmp_path / ARTIFACT_NAME
    artifact.write_bytes(b"x" * len(ARTIFACT_BYTES))
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="move it aside"):
        fetch_artifacts(**arguments)

    assert artifact.read_bytes() == b"x" * len(ARTIFACT_BYTES)
    assert fake_api.download_requests == []


def test_api_fetch_rejects_symlinked_partial_without_touching_target(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """A planted partial symlink is rejected and its target stays untouched."""
    victim = tmp_path / "outside"
    victim.write_bytes(b"keep me")
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    partial.symlink_to(victim)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="regular file"):
        fetch_artifacts(**arguments)

    assert victim.read_bytes() == b"keep me"


def test_interrupted_download_keeps_writing_to_the_open_partial_file(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A path swap during a short read cannot redirect partial bytes through a symlink."""
    victim = tmp_path / "outside"
    victim.write_bytes(b"keep me")
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    real_open_validated_url = fetch_module._open_validated_url

    class SwappingResponse:
        def __init__(self, response: object) -> None:
            self.response = response
            self.swapped = False

        def __enter__(self) -> SwappingResponse:
            return self

        def __exit__(self, *_args: object) -> None:
            getattr(self.response, "close")()

        def __getattr__(self, name: str) -> object:
            return getattr(self.response, name)

        def read(self, _size: int = -1) -> bytes:
            if not self.swapped:
                self.swapped = True
                partial.unlink()
                partial.symlink_to(victim)
                raise http.client.IncompleteRead(ARTIFACT_BYTES[:7], len(ARTIFACT_BYTES) - 7)
            return cast(bytes, getattr(self.response, "read")(_size))

    def open_with_swap(
        request: Request,
        *,
        timeout: float,
        allow_loopback_http_for_testing: bool = False,
    ) -> object:
        response = real_open_validated_url(
            request,
            timeout=timeout,
            allow_loopback_http_for_testing=allow_loopback_http_for_testing,
        )
        if urlparse(request.full_url).path == "/download":
            return SwappingResponse(response)
        return response

    monkeypatch.setattr(fetch_module, "_open_validated_url", open_with_swap)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="was interrupted"):
        fetch_artifacts(**arguments)

    assert victim.read_bytes() == b"keep me"
    assert partial.is_symlink()


def test_finalization_rejects_a_partial_path_swapped_to_a_symlink(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A same-size symlink replacement at EOF is not published as an artifact."""
    fake_api.include_digest = False
    victim = tmp_path / "outside"
    victim.write_bytes(b"x" * len(ARTIFACT_BYTES))
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    real_open_validated_url = fetch_module._open_validated_url

    class SwappingResponse:
        def __init__(self, response: object) -> None:
            self.response = response
            self.swapped = False

        def __enter__(self) -> SwappingResponse:
            return self

        def __exit__(self, *_args: object) -> None:
            getattr(self.response, "close")()

        def __getattr__(self, name: str) -> object:
            return getattr(self.response, name)

        def read(self, size: int = -1) -> bytes:
            chunk = cast(bytes, getattr(self.response, "read")(size))
            if not chunk and not self.swapped:
                self.swapped = True
                partial.unlink()
                partial.symlink_to(victim)
            return chunk

    def open_with_swap(
        request: Request,
        *,
        timeout: float,
        allow_loopback_http_for_testing: bool = False,
    ) -> object:
        response = real_open_validated_url(
            request,
            timeout=timeout,
            allow_loopback_http_for_testing=allow_loopback_http_for_testing,
        )
        if urlparse(request.full_url).path == "/download":
            return SwappingResponse(response)
        return response

    monkeypatch.setattr(fetch_module, "_open_validated_url", open_with_swap)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="changed during finalization"):
        fetch_artifacts(**arguments)

    assert victim.read_bytes() == b"x" * len(ARTIFACT_BYTES)
    assert not (tmp_path / ARTIFACT_NAME).exists()
    assert partial.is_symlink()


def test_finalization_does_not_publish_a_staging_symlink(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A private read-only staging directory blocks path replacement."""
    victim = tmp_path / "outside"
    victim.write_bytes(b"keep the victim intact")
    final = tmp_path / ARTIFACT_NAME
    real_link = fetch_module.os.link
    replacement_was_blocked = False

    def link_after_swap_attempt(
        source: str,
        destination: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
        follow_symlinks: bool = True,
    ) -> None:
        nonlocal replacement_was_blocked
        staging_path = next(tmp_path.glob(".*.finalizing")) / source
        try:
            staging_path.unlink()
            staging_path.symlink_to(victim)
        except PermissionError:
            replacement_was_blocked = True
        real_link(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
            follow_symlinks=follow_symlinks,
        )

    monkeypatch.setattr(fetch_module.os, "link", link_after_swap_attempt)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    fetch_artifacts(**arguments)

    assert replacement_was_blocked
    assert victim.read_bytes() == b"keep the victim intact"
    assert final.read_bytes() == ARTIFACT_BYTES
    assert not list(tmp_path.glob(".*.finalizing"))


def test_finalization_rejects_staged_inode_writes(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The private staged inode is read-only before its final link is published."""
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    final = tmp_path / ARTIFACT_NAME
    real_link = fetch_module.os.link
    write_was_blocked = False

    def link_after_write_attempt(
        source: str,
        destination: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
        follow_symlinks: bool = True,
    ) -> None:
        nonlocal write_was_blocked
        staging_path = next(tmp_path.glob(".*.finalizing")) / source
        try:
            with staging_path.open("r+b") as staged:
                staged.write(b"x" * len(ARTIFACT_BYTES))
        except PermissionError:
            write_was_blocked = True
        real_link(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
            follow_symlinks=follow_symlinks,
        )

    monkeypatch.setattr(fetch_module.os, "link", link_after_write_attempt)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    fetch_artifacts(**arguments)

    assert write_was_blocked
    assert final.read_bytes() == ARTIFACT_BYTES
    assert not partial.exists()


def test_finalization_preserves_a_competing_final_path(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A competing final path is preserved when it replaces our atomic link."""
    final = tmp_path / ARTIFACT_NAME
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    replacement = b"replacement at the final path"
    real_link = fetch_module.os.link

    def link_then_replace_path(
        source: str,
        destination: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
        follow_symlinks: bool = True,
    ) -> None:
        real_link(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
            follow_symlinks=follow_symlinks,
        )
        final.unlink()
        final.write_bytes(replacement)

    monkeypatch.setattr(fetch_module.os, "link", link_then_replace_path)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="changed during finalization"):
        fetch_artifacts(**arguments)

    assert final.read_bytes() == replacement
    assert partial.read_bytes() == ARTIFACT_BYTES


def test_interruption_after_atomic_publication_leaves_a_complete_artifact(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An interruption after link publication cannot expose truncated bytes."""
    final = tmp_path / ARTIFACT_NAME
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    real_link = fetch_module.os.link

    def link_then_interrupt(
        source: str,
        destination: str,
        *,
        src_dir_fd: int | None = None,
        dst_dir_fd: int | None = None,
        follow_symlinks: bool = True,
    ) -> None:
        real_link(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
            follow_symlinks=follow_symlinks,
        )
        raise KeyboardInterrupt

    monkeypatch.setattr(fetch_module.os, "link", link_then_interrupt)
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(KeyboardInterrupt):
        fetch_artifacts(**arguments)

    assert final.read_bytes() == ARTIFACT_BYTES
    assert partial.read_bytes() == ARTIFACT_BYTES
    assert not list(tmp_path.glob(".*.finalizing"))


def test_finalization_never_overwrites_an_existing_artifact(tmp_path: Path) -> None:
    """Exclusive publication preserves an existing destination."""
    partial = tmp_path / f"{ARTIFACT_NAME}.partial"
    final = tmp_path / ARTIFACT_NAME
    partial.write_bytes(ARTIFACT_BYTES)
    final.write_bytes(b"preserve existing artifact")
    partial_stat = partial.stat()

    with pytest.raises(FetchError, match="already exists"):
        fetch_module._publish_partial(
            partial,
            Artifact(name=ARTIFACT_NAME, size=len(ARTIFACT_BYTES)),
            None,
            (partial_stat.st_dev, partial_stat.st_ino),
        )

    assert final.read_bytes() == b"preserve existing artifact"
    assert partial.read_bytes() == ARTIFACT_BYTES


def test_api_fetch_restarts_partial_when_upstream_has_no_digest(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """A local partial prefix is not trusted for resumption without an API digest."""
    fake_api.include_digest = False
    fake_api.interrupt_once = True
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url

    with pytest.raises(FetchError, match="run fetch again to resume"):
        fetch_artifacts(**arguments)
    fetch_artifacts(**arguments)

    assert fake_api.download_requests == [None, None]
    assert (tmp_path / ARTIFACT_NAME).read_bytes() == ARTIFACT_BYTES


def test_redownload_without_api_digest_retains_manifest_digest(
    tmp_path: Path,
    fake_api: FakeBuildAPI,
) -> None:
    """A prior fetch.json SHA-256 still authenticates a replacement download."""
    arguments = fetch_arguments(tmp_path, "test-secret")
    arguments["api_base_url"] = fake_api.base_url
    original = fetch_artifacts(**arguments)[0]
    (tmp_path / ARTIFACT_NAME).unlink()
    fake_api.include_digest = False
    fake_api.download_bytes = b"x" * len(ARTIFACT_BYTES)

    with pytest.raises(FetchError, match="SHA-256 mismatch"):
        fetch_artifacts(**arguments)

    manifest = json.loads((tmp_path / "fetch.json").read_text())
    assert manifest["artifacts"][0]["sha256"] == original.sha256
    assert not (tmp_path / ARTIFACT_NAME).exists()
