#!/usr/bin/env python3
"""Checks that the workflow-policy checker fails closed without GitHub context.

The checker runs as a subprocess with every GITHUB_* variable removed (as on a
developer Mac) or with one of the required variables missing. Each case must
exit 2 before it makes any network request, so the job can never report a
pass for a pull request it could not verify.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

repository = pathlib.Path(sys.argv[1])
checker = repository / "scripts/ci/check-pr-control-changes.py"
base_environment = {
    key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")
}

with tempfile.TemporaryDirectory() as temporary_directory:
    empty_event = pathlib.Path(temporary_directory) / "empty-event.json"
    empty_event.write_text("{}\n", encoding="utf-8")
    incomplete_event = pathlib.Path(temporary_directory) / "incomplete-event.json"
    incomplete_event.write_text('{"number": 1}\n', encoding="utf-8")

    complete = {
        "GITHUB_EVENT_PATH": str(empty_event),
        "GITHUB_TOKEN": "fixture-token",
        "GITHUB_REPOSITORY": "owner/repository",
        "GITHUB_EVENT_NAME": "pull_request_target",
    }
    cases = (
        ("no GitHub context", "required GitHub environment is missing", {}),
        (
            "missing token",
            "required GitHub environment is missing",
            {key: value for key, value in complete.items() if key != "GITHUB_TOKEN"},
        ),
        (
            "missing repository",
            "required GitHub environment is missing",
            {key: value for key, value in complete.items() if key != "GITHUB_REPOSITORY"},
        ),
        (
            "missing event path",
            "required GitHub environment is missing",
            {key: value for key, value in complete.items() if key != "GITHUB_EVENT_PATH"},
        ),
        (
            "event without pull request",
            "unable to verify pull request",
            {**complete, "GITHUB_EVENT_PATH": str(incomplete_event)},
        ),
    )

    for name, expected, values in cases:
        environment = {**base_environment, **values}
        result = subprocess.run(
            [sys.executable, str(checker)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 2 or expected not in result.stderr:
            raise SystemExit(
                f"FAIL CI policy context {name}: expected exit 2 with {expected!r}, "
                f"got {result.returncode}\n{result.stdout}{result.stderr}"
            )
        print(f"PASS CI policy context fixture fails closed: {name}")
