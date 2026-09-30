"""Download and verify Android Build API artifacts."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import http.client
import json
import os
import re
import stat
import sys
import tempfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, urlopen

API_BASE_URL = "https://androidbuild-pa.googleapis.com/v4"
API_KEY_ENV = "APKRUN_ANDROID_BUILD_API_KEY"
CHUNK_SIZE = 1024 * 1024
USER_AGENT = "APKRun-Image-Tools/0.1.0"


class FetchError(Exception):
    """An actionable artifact acquisition failure."""


@dataclass(frozen=True)
class Artifact:
    """Artifact metadata returned by the Android Build API."""

    name: str
    size: int
    sha256: str | None = None


@dataclass(frozen=True)
class DownloadRecord:
    """Local artifact metadata written to fetch.json."""

    name: str
    size: int
    sha256: str


def build_parser() -> argparse.ArgumentParser:
    """Build the fetch command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image fetch",
        description="Fetch and verify pinned Android build artifacts.",
    )
    parser.add_argument("--branch", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--build", dest="build_id", required=True)
    parser.add_argument("--artifact", required=True, help="artifact name glob")
    parser.add_argument("--out", required=True, type=Path)
    return parser


def _artifact_name(value: object) -> str:
    """Validate an API-provided artifact name before using it as a path."""
    if not isinstance(value, str) or not value:
        raise FetchError("Android Build API returned an artifact without a name.")
    if value in {".", ".."} or Path(value).name != value or "/" in value or "\\" in value:
        raise FetchError("Android Build API returned an unsafe artifact name.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", value):
        raise FetchError(f"Android Build API returned an unsupported artifact name: {value!r}.")
    return value


def _positive_size(value: object, name: str) -> int:
    """Parse a positive byte count from the API response."""
    if isinstance(value, bool):
        raise FetchError(f"Android Build API returned an invalid size for {name}.")
    try:
        size = int(value)
    except (OverflowError, TypeError, ValueError) as error:
        raise FetchError(f"Android Build API returned an invalid size for {name}.") from error
    if size < 0:
        raise FetchError(f"Android Build API returned an invalid size for {name}.")
    return size


def _sha256_value(value: object, name: str) -> str | None:
    """Return an optional API SHA-256 in canonical lowercase form."""
    if value is None or value == "":
        return None
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{64}", value) is None:
        raise FetchError(f"Android Build API returned an invalid SHA-256 for {name}.")
    return value.lower()


def _request_json(
    url: str,
    *,
    timeout: float = 60.0,
) -> Mapping[str, Any]:
    """Read an API JSON response without exposing its query string on errors."""
    request = Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
        method="GET",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except HTTPError as error:
        raise FetchError(f"Android Build API request failed with HTTP {error.code}.") from None
    except (URLError, TimeoutError, OSError):
        raise FetchError("Could not reach the Android Build API.") from None
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise FetchError("Android Build API returned invalid JSON.") from None
    if not isinstance(value, dict):
        raise FetchError("Android Build API returned an unexpected response.")
    return value


def _api_url(base_url: str, path: str, api_key: str, parameters: Mapping[str, str]) -> str:
    """Build an API URL with a key that is never included in diagnostics."""
    query = dict(parameters)
    query["key"] = api_key
    return f"{base_url.rstrip('/')}{path}?{urlencode(query)}"


def _list_artifacts(
    *,
    base_url: str,
    api_key: str,
    build_id: str,
    target: str,
    pattern: str,
) -> list[Artifact]:
    """Resolve an artifact glob across all pages of the Build API response."""
    path = f"/builds/{quote(build_id, safe='')}/{quote(target, safe='')}/attempts/latest/artifacts"
    page_token = ""
    seen_page_tokens: set[str] = set()
    matches: dict[str, Artifact] = {}
    while True:
        if page_token in seen_page_tokens:
            raise FetchError("Android Build API returned a pagination cycle.")
        seen_page_tokens.add(page_token)
        parameters = {"pageToken": page_token} if page_token else {}
        response = _request_json(
            _api_url(base_url, path, api_key, parameters),
        )
        artifacts = response.get("artifacts")
        if not isinstance(artifacts, list):
            raise FetchError("Android Build API response has no artifact list.")
        for value in artifacts:
            if not isinstance(value, dict):
                raise FetchError("Android Build API returned malformed artifact metadata.")
            raw_name = value.get("name")
            if not isinstance(raw_name, str):
                raise FetchError("Android Build API returned an artifact without a name.")
            if not fnmatch.fnmatchcase(raw_name, pattern):
                continue
            name = _artifact_name(raw_name)
            size = _positive_size(value.get("size"), name)
            digest = _sha256_value(
                value.get("sha256", value.get("sha256Digest")),
                name,
            )
            candidate = Artifact(name=name, size=size, sha256=digest)
            if name in matches and matches[name] != candidate:
                raise FetchError(f"Android Build API returned conflicting metadata for {name}.")
            matches[name] = candidate
        next_page = response.get("nextPageToken")
        if not next_page:
            break
        if not isinstance(next_page, str) or next_page == page_token:
            raise FetchError("Android Build API returned an invalid pagination token.")
        page_token = next_page
    return [matches[name] for name in sorted(matches)]


def _signed_url(
    *,
    base_url: str,
    api_key: str,
    build_id: str,
    target: str,
    artifact_name: str,
) -> str:
    """Request a time-limited download URL for one artifact."""
    path = (
        f"/builds/{quote(build_id, safe='')}/{quote(target, safe='')}"
        f"/attempts/latest/artifacts/{quote(artifact_name, safe='')}/url"
    )
    response = _request_json(_api_url(base_url, path, api_key, {}))
    value = response.get("signedUrl", response.get("url"))
    if not isinstance(value, str):
        raise FetchError(f"Android Build API returned no download URL for {artifact_name}.")
    parsed = urlparse(value)
    loopback_http = parsed.scheme == "http" and parsed.hostname in {
        "127.0.0.1",
        "::1",
        "localhost",
    }
    if (parsed.scheme != "https" and not loopback_http) or not parsed.netloc:
        raise FetchError(f"Android Build API returned an unsafe download URL for {artifact_name}.")
    return value


def _sha256_file(path: Path) -> str:
    """Hash a file incrementally."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_descriptor(descriptor: int) -> str:
    """Hash an already-open file without resolving its path again."""
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while chunk := os.read(descriptor, CHUNK_SIZE):
        digest.update(chunk)
    return digest.hexdigest()


def _file_identity(file_stat: os.stat_result) -> tuple[int, int]:
    """Return the filesystem identity used to detect path replacement."""
    return file_stat.st_dev, file_stat.st_ino


def _file_version(file_stat: os.stat_result) -> tuple[int, int, int, int, int]:
    """Return identity and timestamps used to detect in-place mutation."""
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def _unlink_if_identity_matches(path: Path, expected_identity: tuple[int, int]) -> None:
    """Remove only the path entry created by this finalization attempt."""
    try:
        file_stat = path.lstat()
        if _file_identity(file_stat) == expected_identity:
            path.unlink()
    except OSError:
        return


def _publish_partial(
    partial_path: Path,
    artifact: Artifact,
    expected_sha256: str | None,
    expected_identity: tuple[int, int],
) -> DownloadRecord:
    """Copy, verify, then publish a partial without following a swapped path."""
    try:
        descriptor = os.open(partial_path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        raise FetchError(
            f"The partial download for {artifact.name} changed during finalization."
        ) from None

    final_path = partial_path.with_suffix("")
    staging_path: Path | None = None
    staging_descriptor = -1
    staging_identity: tuple[int, int] | None = None
    linked_identity: tuple[int, int] | None = None
    try:
        with os.fdopen(descriptor, "rb"):
            opened_stat = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened_stat.st_mode)
                or opened_stat.st_nlink != 1
                or _file_identity(opened_stat) != expected_identity
            ):
                raise FetchError(
                    f"The partial download for {artifact.name} changed during finalization."
                )
            if opened_stat.st_size != artifact.size:
                raise FetchError(
                    f"Download of {artifact.name} stopped at {opened_stat.st_size} "
                    f"of {artifact.size} bytes; run fetch again to resume."
                )
            try:
                path_stat = partial_path.lstat()
            except OSError:
                raise FetchError(
                    f"The partial download for {artifact.name} changed during finalization."
                ) from None
            if (
                stat.S_ISLNK(path_stat.st_mode)
                or path_stat.st_nlink != 1
                or _file_identity(path_stat) != expected_identity
            ):
                raise FetchError(
                    f"The partial download for {artifact.name} changed during finalization."
                )

            staging_descriptor, staging_name = tempfile.mkstemp(
                prefix=f".{artifact.name}.",
                suffix=".finalizing",
                dir=partial_path.parent,
            )
            staging_path = Path(staging_name)
            staging_initial_stat = os.fstat(staging_descriptor)
            staging_identity = _file_identity(staging_initial_stat)
            if (
                not stat.S_ISREG(staging_initial_stat.st_mode)
                or staging_initial_stat.st_nlink != 1
                or staging_initial_stat.st_size != 0
            ):
                raise FetchError(
                    f"The staged artifact {artifact.name} changed during finalization."
                )
            digest_builder = hashlib.sha256()
            copied_size = 0
            os.lseek(descriptor, 0, os.SEEK_SET)
            while chunk := os.read(descriptor, CHUNK_SIZE):
                digest_builder.update(chunk)
                copied_size += len(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(staging_descriptor, view)
                    view = view[written:]
            digest = digest_builder.hexdigest()
            if copied_size != artifact.size:
                raise FetchError(
                    f"Download of {artifact.name} changed during finalization; run fetch again."
                )
            if expected_sha256 is not None and digest != expected_sha256:
                raise FetchError(
                    f"{artifact.name} SHA-256 mismatch; remove its .partial file and "
                    "run fetch again."
                )
            os.fsync(staging_descriptor)
            staging_stat = os.fstat(staging_descriptor)
            if (
                not stat.S_ISREG(staging_stat.st_mode)
                or staging_stat.st_nlink != 1
                or _file_identity(staging_stat) != staging_identity
                or staging_stat.st_size != artifact.size
            ):
                raise FetchError(
                    f"The staged artifact {artifact.name} changed during finalization."
                )
            try:
                staging_path_stat = staging_path.lstat()
                partial_path_stat = partial_path.lstat()
            except OSError:
                raise FetchError(
                    f"The partial download for {artifact.name} changed during finalization."
                ) from None
            if (
                stat.S_ISLNK(staging_path_stat.st_mode)
                or _file_identity(staging_path_stat) != staging_identity
                or stat.S_ISLNK(partial_path_stat.st_mode)
                or _file_identity(partial_path_stat) != expected_identity
            ):
                raise FetchError(
                    f"The partial download for {artifact.name} changed during finalization."
                )

            try:
                os.link(staging_path, final_path, follow_symlinks=False)
            except FileExistsError:
                raise FetchError(
                    f"The destination for {artifact.name} already exists; "
                    "verify or remove it first."
                ) from None
            except OSError:
                raise FetchError(
                    f"Could not safely publish the downloaded artifact {artifact.name}."
                ) from None
            try:
                linked_stat = final_path.lstat()
                linked_identity = _file_identity(linked_stat)
                if (
                    stat.S_ISLNK(linked_stat.st_mode)
                    or not stat.S_ISREG(linked_stat.st_mode)
                    or linked_identity != staging_identity
                ):
                    raise FetchError(
                        f"The downloaded artifact {artifact.name} changed during finalization."
                    )
                published_descriptor = os.open(final_path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(published_descriptor, "rb"):
                    published_stat = os.fstat(published_descriptor)
                    if (
                        not stat.S_ISREG(published_stat.st_mode)
                        or published_stat.st_nlink < 2
                        or _file_identity(published_stat) != staging_identity
                        or published_stat.st_size != artifact.size
                    ):
                        raise FetchError(
                            f"The downloaded artifact {artifact.name} changed during finalization."
                        )
                    published_digest = _sha256_descriptor(published_descriptor)
                    if published_digest != digest or (
                        expected_sha256 is not None and published_digest != expected_sha256
                    ):
                        raise FetchError(
                            f"{artifact.name} changed while it was being finalized; "
                            "run fetch again."
                        )
                    hashed_stat = os.fstat(published_descriptor)
                    if _file_version(hashed_stat) != _file_version(published_stat):
                        raise FetchError(
                            f"{artifact.name} changed while it was being finalized; "
                            "run fetch again."
                        )
                    try:
                        final_path_stat = final_path.lstat()
                    except OSError:
                        raise FetchError(
                            f"The downloaded artifact {artifact.name} changed during finalization."
                        ) from None
                    if (
                        stat.S_ISLNK(final_path_stat.st_mode)
                        or not stat.S_ISREG(final_path_stat.st_mode)
                        or _file_version(final_path_stat) != _file_version(hashed_stat)
                    ):
                        raise FetchError(
                            f"The downloaded artifact {artifact.name} changed during finalization."
                        )
            except FetchError:
                if linked_identity is not None:
                    _unlink_if_identity_matches(final_path, linked_identity)
                    if staging_path is not None:
                        _unlink_if_identity_matches(staging_path, linked_identity)
                raise
            except OSError:
                if linked_identity is not None:
                    _unlink_if_identity_matches(final_path, linked_identity)
                    if staging_path is not None:
                        _unlink_if_identity_matches(staging_path, linked_identity)
                raise FetchError(
                    f"The downloaded artifact {artifact.name} changed during finalization."
                ) from None

            try:
                partial_path_stat = partial_path.lstat()
                if _file_identity(partial_path_stat) == expected_identity:
                    partial_path.unlink()
            except OSError:
                pass
            digest = published_digest
    finally:
        if staging_descriptor >= 0:
            os.close(staging_descriptor)
        if staging_path is not None and staging_identity is not None:
            _unlink_if_identity_matches(staging_path, staging_identity)

    return DownloadRecord(name=artifact.name, size=artifact.size, sha256=digest)


def _load_existing_records(
    path: Path,
    *,
    branch: str,
    target: str,
    build_id: str,
) -> dict[str, DownloadRecord]:
    """Load and validate the prior fetch manifest, if present."""
    if path.is_symlink():
        raise FetchError(f"{path} must not be a symbolic link.")
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise FetchError(f"{path} is unreadable; remove it and run fetch again.") from None
    if (
        not isinstance(value, dict)
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("schemaVersion") != 2
    ):
        raise FetchError(f"{path} has an unsupported format; remove it and run fetch again.")
    if any(
        value.get(field) != expected
        for field, expected in (
            ("branch", branch),
            ("target", target),
            ("buildId", build_id),
        )
    ):
        raise FetchError(
            f"{path} describes a different Android build; move it aside before fetching."
        )
    records = value.get("artifacts")
    if not isinstance(records, list):
        raise FetchError(f"{path} has no artifact records; remove it and run fetch again.")
    result: dict[str, DownloadRecord] = {}
    for item in records:
        if not isinstance(item, dict):
            raise FetchError(f"{path} contains a malformed artifact record.")
        name = _artifact_name(item.get("name"))
        size = _positive_size(item.get("size"), name)
        digest = _sha256_value(item.get("sha256"), name)
        if digest is None:
            raise FetchError(f"{path} has no SHA-256 for {name}.")
        if name in result:
            raise FetchError(f"{path} contains duplicate records for {name}.")
        result[name] = DownloadRecord(name=name, size=size, sha256=digest)
    return result


def _write_manifest(
    path: Path,
    *,
    branch: str,
    target: str,
    build_id: str,
    records: Sequence[DownloadRecord],
) -> None:
    """Write deterministic local provenance for the fetched artifacts."""
    value = {
        "artifacts": [
            {"name": item.name, "sha256": item.sha256, "size": item.size}
            for item in sorted(records, key=lambda record: record.name)
        ],
        "branch": branch,
        "branchProvenance": "caller-asserted",
        "buildId": build_id,
        "schemaVersion": 2,
        "target": target,
    }
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".partial",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    except OSError:
        raise FetchError(f"Could not safely write {path.name}.") from None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _verify_file(path: Path, artifact: Artifact, record: DownloadRecord | None) -> DownloadRecord:
    """Verify size and digest for an already downloaded artifact."""
    if not path.is_file() or path.is_symlink():
        raise FetchError(f"{path.name} is not a regular artifact file.")
    size = path.stat().st_size
    if size != artifact.size:
        raise FetchError(
            f"{path.name} has size {size}, expected {artifact.size}; "
            "remove the damaged file and run fetch again."
        )
    digest = _sha256_file(path)
    expected = artifact.sha256 or (record.sha256 if record is not None else None)
    if expected is not None and digest != expected:
        raise FetchError(
            f"{path.name} SHA-256 mismatch; remove the damaged file and run fetch again."
        )
    if record is not None and (record.size != size or record.sha256 != digest):
        raise FetchError(
            f"{path.name} no longer matches fetch.json; "
            "remove the damaged file and run fetch again."
        )
    return DownloadRecord(name=artifact.name, size=size, sha256=digest)


def _download(
    *,
    url: str,
    partial_path: Path,
    artifact: Artifact,
    expected_sha256: str | None = None,
    timeout: float = 120.0,
) -> DownloadRecord:
    """Resume a signed artifact download and atomically publish verified bytes."""
    digest_to_check = artifact.sha256 or expected_sha256
    try:
        partial_stat = partial_path.lstat()
    except FileNotFoundError:
        partial_stat = None
    except OSError:
        raise FetchError(f"Could not inspect the partial download for {artifact.name}.") from None
    if partial_stat is not None and (
        stat.S_ISLNK(partial_stat.st_mode)
        or not stat.S_ISREG(partial_stat.st_mode)
        or partial_stat.st_nlink != 1
    ):
        raise FetchError(f"The partial download path for {artifact.name} must be a regular file.")
    reset_partial = False
    if partial_stat is not None and digest_to_check is None:
        # Without a server or manifest digest, an existing prefix cannot be authenticated.
        reset_partial = True
    offset = partial_stat.st_size if partial_stat is not None else 0
    if offset > artifact.size:
        reset_partial = True
        offset = 0
    if reset_partial:
        offset = 0
    if offset == artifact.size:
        if partial_stat is None:
            raise FetchError(f"Could not inspect the partial download for {artifact.name}.")
        return _publish_partial(
            partial_path,
            artifact,
            digest_to_check,
            _file_identity(partial_stat),
        )

    headers = {"User-Agent": USER_AGENT}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = Request(url, headers=headers, method="GET")
    try:
        response = urlopen(request, timeout=timeout)
    except HTTPError as error:
        raise FetchError(
            f"Artifact download failed with HTTP {error.code}; run fetch again to resume."
        ) from None
    except (URLError, TimeoutError, OSError):
        raise FetchError("Artifact download failed; run fetch again to resume.") from None

    with response:
        status = getattr(response, "status", response.getcode())
        if offset and status == 206:
            content_range = response.headers.get("Content-Range", "")
            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+|\*)", content_range)
            if match is None or int(match.group(1)) != offset:
                raise FetchError(
                    f"Artifact server returned an invalid resume range for {artifact.name}."
                )
            if match.group(3) != "*" and int(match.group(3)) != artifact.size:
                raise FetchError(
                    f"Artifact server reported an unexpected size for {artifact.name}."
                )
            mode = "ab"
            expected_remaining = artifact.size - offset
        elif status == 200:
            mode = "wb"
            expected_remaining = artifact.size
        else:
            raise FetchError(f"Artifact server returned HTTP {status} for {artifact.name}.")

        received = 0
        descriptor = -1
        try:
            flags = os.O_RDWR | os.O_NOFOLLOW
            flags |= os.O_APPEND if mode == "ab" else 0
            flags |= os.O_CREAT | os.O_EXCL if partial_stat is None else 0
            descriptor = os.open(partial_path, flags, 0o600)
            opened_stat = os.fstat(descriptor)
            if not stat.S_ISREG(opened_stat.st_mode) or opened_stat.st_nlink != 1:
                raise FetchError(
                    f"The partial download path for {artifact.name} must be a regular file."
                )
            if partial_stat is not None and (
                _file_identity(opened_stat) != _file_identity(partial_stat)
            ):
                raise FetchError(
                    f"The partial download for {artifact.name} changed during transfer."
                )
            if mode == "wb":
                os.ftruncate(descriptor, 0)
            elif opened_stat.st_size != offset:
                raise FetchError(
                    f"The partial download for {artifact.name} changed during transfer."
                )
            writer_identity = _file_identity(os.fstat(descriptor))
            output_stream = os.fdopen(descriptor, mode)
            descriptor = -1
            with output_stream as output:
                try:
                    while chunk := response.read(CHUNK_SIZE):
                        received += len(chunk)
                        if received > expected_remaining:
                            raise FetchError(
                                f"Artifact server sent too many bytes for {artifact.name}."
                            )
                        output.write(chunk)
                except http.client.IncompleteRead as error:
                    if error.partial:
                        received += len(error.partial)
                        if received > expected_remaining:
                            raise FetchError(
                                f"Artifact server sent too many bytes for {artifact.name}."
                            ) from None
                        output.write(error.partial)
                    output.flush()
                    os.fsync(output.fileno())
                    raise FetchError(
                        f"Download of {artifact.name} was interrupted; run fetch again to resume."
                    ) from None
                output.flush()
                os.fsync(output.fileno())
        except FetchError:
            raise
        except OSError:
            raise FetchError("Could not write the artifact; run fetch again to resume.") from None
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    return _publish_partial(partial_path, artifact, digest_to_check, writer_identity)


def fetch_artifacts(
    *,
    branch: str,
    target: str,
    build_id: str,
    pattern: str,
    output_directory: Path,
    api_key: str | None,
    api_base_url: str = API_BASE_URL,
) -> list[DownloadRecord]:
    """Fetch all artifacts matching a pattern, or verify manual downloads."""
    if not branch or not target or not build_id or not pattern:
        raise FetchError("Branch, target, build ID, and artifact pattern must be non-empty.")
    output_directory.mkdir(parents=True, exist_ok=True)
    manifest_path = output_directory / "fetch.json"
    old_records = _load_existing_records(
        manifest_path,
        branch=branch,
        target=target,
        build_id=build_id,
    )
    if api_key is None:
        artifacts = [
            Artifact(
                name=path.name,
                size=old_records[path.name].size
                if path.name in old_records
                else path.stat().st_size,
            )
            for path in output_directory.iterdir()
            if path.is_file() and not path.is_symlink() and fnmatch.fnmatchcase(path.name, pattern)
        ]
        if not artifacts:
            raise FetchError(
                f"No artifact matching {pattern!r} was found in {output_directory}. "
                f"Set {API_KEY_ENV} to download automatically, or download the file from "
                "ci.android.com and run this command again."
            )
    else:
        artifacts = _list_artifacts(
            base_url=api_base_url,
            api_key=api_key,
            build_id=build_id,
            target=target,
            pattern=pattern,
        )
        if not artifacts:
            raise FetchError(
                f"No Android Build API artifact matched {pattern!r} "
                f"for build {build_id} and target {target}."
            )

    records: list[DownloadRecord] = []
    for artifact in artifacts:
        final_path = output_directory / artifact.name
        if final_path.is_symlink():
            raise FetchError(f"{artifact.name} must not be a symbolic link.")
        old_record = old_records.get(artifact.name)
        if final_path.exists():
            if api_key is None or artifact.sha256 is not None or old_record is not None:
                records.append(_verify_file(final_path, artifact, old_record))
                continue
            raise FetchError(
                f"{artifact.name} exists without a verifiable SHA-256; move it aside or "
                "run fetch without an API key to record a manual download."
            )
        if api_key is None:
            raise FetchError(
                f"{artifact.name} is recorded in fetch.json but is missing; "
                "download it again from ci.android.com."
            )
        signed_url = _signed_url(
            base_url=api_base_url,
            api_key=api_key,
            build_id=build_id,
            target=target,
            artifact_name=artifact.name,
        )
        records.append(
            _download(
                url=signed_url,
                partial_path=output_directory / f"{artifact.name}.partial",
                artifact=artifact,
                expected_sha256=old_record.sha256 if old_record is not None else None,
            )
        )

    _write_manifest(
        manifest_path,
        branch=branch,
        target=target,
        build_id=build_id,
        records=records,
    )
    return records


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point for artifact acquisition."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    api_key = os.environ.get(API_KEY_ENV)
    try:
        records = fetch_artifacts(
            branch=arguments.branch,
            target=arguments.target,
            build_id=arguments.build_id,
            pattern=arguments.artifact,
            output_directory=arguments.out.expanduser(),
            api_key=api_key or None,
        )
    except FetchError as error:
        print(f"apkrun_image fetch: {error}", file=sys.stderr)
        return 2
    for record in records:
        print(f"{record.name} verified ({record.size} bytes, sha256 {record.sha256})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
