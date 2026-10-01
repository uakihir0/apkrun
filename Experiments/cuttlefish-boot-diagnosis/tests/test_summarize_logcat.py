from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import summarize_logcat


def test_summary_keeps_counts_without_copying_log_messages(tmp_path: Path) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.txt").write_text(
        "06-01 12:00:00.000 I SystemServer: private-token=must-not-be-retained\n"
        "06-01 12:00:01.000 E ServiceManager: Could not find 'aidl/activity'\n"
        "06-01 12:00:02.000 I ActivityManager: BOOT_COMPLETED\n",
        encoding="utf-8",
    )

    summary = summarize_logcat.summarize(snapshots)
    encoded = json.dumps(summary)

    assert summary["snapshotCount"] == 1
    assert summary["systemServerLines"] == 1
    assert summary["activityServiceLookupFailures"] == 1
    assert summary["activityManagerLines"] == 1
    assert summary["bootCompletedLines"] == 1
    assert "private-token" not in encoded
    assert "must-not-be-retained" not in encoded


def test_summary_reads_capture_gzip_and_counts_only_selected_signals(
    tmp_path: Path,
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    capture_logcat = tmp_path / "logcat.txt.gz"
    capture_logcat.write_bytes(
        gzip.compress(
            b"06-01 12:00:00.000 E AndroidRuntime: FATAL EXCEPTION IN SYSTEM PROCESS\n"
            b"06-01 12:00:01.000 I SurfaceFlinger: ready\n"
            b"06-01 12:00:02.000 E EGL: failed to initialize\n"
        )
    )

    summary = summarize_logcat.summarize(snapshots, capture_logcat)

    assert summary["snapshotCount"] == 0
    assert summary["captureLogcatPresent"] is True
    assert summary["systemServerFatalLines"] == 1
    assert summary["surfaceFlingerLines"] == 1
    assert summary["graphicsFailureLines"] == 1


def test_summary_records_live_logcat_truncation_without_retaining_messages(
    tmp_path: Path,
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.txt").write_text(
        "private-token=must-not-be-retained\n", encoding="utf-8"
    )
    (snapshots / "logcat-001.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 128,
                "truncated": True,
                "timedOut": False,
                "cleanupComplete": True,
                "childExitCode": -9,
                "signal": None,
            }
        ),
        encoding="utf-8",
    )

    summary = summarize_logcat.summarize(snapshots)
    encoded = json.dumps(summary)

    assert summary["liveLogcatSampleCount"] == 1
    assert summary["liveLogcatBytes"] == 128
    assert summary["liveLogcatTruncatedSampleCount"] == 1
    assert summary["liveLogcatTimedOutSampleCount"] == 0
    assert summary["liveLogcatCleanupIncompleteSampleCount"] == 0
    assert summary["liveLogcatFailedSampleCount"] == 0
    assert "private-token" not in encoded


def test_summary_counts_live_logcat_failures_without_a_snapshot(tmp_path: Path) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 0,
                "truncated": False,
                "timedOut": True,
                "cleanupComplete": True,
                "childExitCode": -9,
                "signal": None,
            }
        ),
        encoding="utf-8",
    )

    summary = summarize_logcat.summarize(snapshots)

    assert summary["snapshotCount"] == 0
    assert summary["liveLogcatSampleCount"] == 1
    assert summary["liveLogcatTimedOutSampleCount"] == 1
    assert summary["liveLogcatFailedSampleCount"] == 1


def test_summary_marks_incomplete_live_logcat_cleanup_as_failure(
    tmp_path: Path,
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 0,
                "truncated": False,
                "timedOut": False,
                "cleanupComplete": False,
                "childExitCode": 0,
                "signal": None,
            }
        ),
        encoding="utf-8",
    )

    summary = summarize_logcat.summarize(snapshots)

    assert summary["liveLogcatCleanupIncompleteSampleCount"] == 1
    assert summary["liveLogcatFailedSampleCount"] == 1


def test_summary_rejects_live_logcat_status_without_cleanup_result(
    tmp_path: Path,
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bytesWritten": 0,
                "truncated": False,
                "timedOut": False,
                "childExitCode": 0,
                "signal": None,
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="invalid fields"):
        summarize_logcat.summarize(snapshots)


def test_summary_rejects_oversized_decompressed_logs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    (snapshots / "logcat-001.txt").write_bytes(b"x" * 33)
    monkeypatch.setattr(summarize_logcat, "MAX_UNCOMPRESSED_BYTES", 32)

    with pytest.raises(ValueError, match="aggregate size limit"):
        summarize_logcat.summarize(snapshots)


def test_summary_rejects_a_large_compressed_single_line_before_buffering_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    compressed = tmp_path / "logcat.txt.gz"
    compressed.write_bytes(gzip.compress(b"x" * (2 * 1024 * 1024)))
    monkeypatch.setattr(summarize_logcat, "MAX_LINE_BYTES", 1024)

    with pytest.raises(ValueError, match="per-line size limit"):
        summarize_logcat.summarize(snapshots, compressed)


def test_summary_rejects_symlink_inputs(tmp_path: Path) -> None:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    source = tmp_path / "outside.txt"
    source.write_text("not part of this experiment\n", encoding="utf-8")
    (snapshots / "logcat-001.txt").symlink_to(source)

    with pytest.raises(ValueError, match="must not be a symlink"):
        summarize_logcat.summarize(snapshots)
