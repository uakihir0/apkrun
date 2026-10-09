#!/usr/bin/env python3
"""Tests the release check's rule for keystores in Tests/Fixtures/signing (IR-338).

The checker finds its signing folder from its own location, so each case copies the checker into a
temporary repository layout with its own signing folder. A test keystore (`test-*.jks`, JKS or PKCS#12)
is accepted. Any other keystore is still rejected as an unsupported format, so a real release key that
is not named as a test fixture still fails the check.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

UNSUPPORTED = "unsupported binary or certificate signing fixture format"

repository = pathlib.Path(sys.argv[1]).resolve()
checker = repository / "scripts/release/check-release-build.sh"
test_keystore = (repository / "Tests/Fixtures/signing/test-fixture-a.jks").read_bytes()


def check(signing_files):
    """Runs the checker on a temporary repository whose signing folder holds `signing_files`."""
    with tempfile.TemporaryDirectory(prefix="apkrun-release-keystores-") as directory:
        root = pathlib.Path(directory)
        release = root / "scripts/release"
        release.mkdir(parents=True)
        shutil.copy2(checker, release / "check-release-build.sh")
        shutil.copy2(repository / "scripts/release/generate-notices.py", release / "generate-notices.py")
        (root / "ThirdParty").mkdir()
        shutil.copy2(repository / "ThirdParty/ThirdParty.lock.json", root / "ThirdParty/ThirdParty.lock.json")
        signing = root / "Tests/Fixtures/signing"
        signing.mkdir(parents=True)
        for name, data in signing_files.items():
            (signing / name).write_bytes(data)
        app = root / "APKRun.app"
        (app / "Contents").mkdir(parents=True)
        result = subprocess.run(
            [str(release / "check-release-build.sh"), str(app)],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout + result.stderr


def expect(name, output, *, mentioning):
    """The keystore must be rejected as unsupported, and the message must name the file."""
    if UNSUPPORTED not in output or mentioning not in output:
        raise SystemExit(f"FAIL keystore {name}: expected the unsupported-format rejection of {mentioning}\n{output}")
    print(f"PASS keystore {name}")


# A test keystore is accepted: the checker reports nothing about it.
output = check({"test-fixture-a.jks": test_keystore})
if UNSUPPORTED in output or "could not read" in output:
    raise SystemExit(f"FAIL keystore test-keystore-accepted: the test keystore was rejected\n{output}")
print("PASS keystore test-keystore-accepted")

# A keystore without the test- prefix stays unsupported, whatever its bytes are.
expect(
    "keystore-without-test-prefix",
    check({"release-signing.jks": test_keystore}),
    mentioning="release-signing.jks",
)

# A test- keystore whose bytes are neither JKS nor PKCS#12 stays unsupported.
expect(
    "test-keystore-with-unknown-bytes",
    check({"test-unknown.jks": b"not a keystore at all"}),
    mentioning="test-unknown.jks",
)

# A test- keystore that starts like PKCS#12 but is cut short is not one DER structure: unsupported.
expect(
    "test-keystore-truncated",
    check({"test-fixture-a.jks": test_keystore[:-100]}),
    mentioning="test-fixture-a.jks",
)

# Only the .jks suffix gets the test-keystore rule: the same bytes under .p12 stay unsupported.
expect(
    "test-keystore-with-other-suffix",
    check({"test-fixture-a.p12": test_keystore}),
    mentioning="test-fixture-a.p12",
)
