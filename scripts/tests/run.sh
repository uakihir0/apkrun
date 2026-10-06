#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fixture_root="$script_dir/fixtures/lock/base"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

checker="$repo_root/scripts/check-lock.sh"
module_checker="$repo_root/scripts/check-module-deps.sh"

python3 "$script_dir/test_test_linux_directory.py"
python3 "$script_dir/test_third_party_build.py"
python3 "$script_dir/test_third_party_notices.py"
python3 "$script_dir/test_embed_virgl_runtime.py"
"$script_dir/test_make_test_disks.sh"
"$script_dir/test_network_error_classification.sh"

expect_pass() {
    local name="$1"
    local root="$2"
    if ! "$checker" --root "$root"; then
        printf 'FAIL lock fixture %s: expected pass\n' "$name" >&2
        exit 1
    fi
    printf 'PASS lock fixture %s\n' "$name"
}

expect_fail() {
    local name="$1"
    local expected="$2"
    local root="$3"
    local output="$temporary_root/$name.log"
    if "$checker" --root "$root" >"$output" 2>&1; then
        printf 'FAIL lock fixture %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! rg -q -- "$expected" "$output"; then
        cat "$output" >&2
        printf 'FAIL lock fixture %s: expected diagnostic matching %s\n' "$name" "$expected" >&2
        exit 1
    fi
    printf 'PASS lock fixture %s\n' "$name"
}

expect_module_pass() {
    local name="$1"
    local root="$2"
    if ! "$module_checker" --root "$root"; then
        printf 'FAIL module dependency fixture %s: expected pass\n' "$name" >&2
        exit 1
    fi
    printf 'PASS module dependency fixture %s\n' "$name"
}

expect_module_fail() {
    local name="$1"
    local expected="$2"
    local root="$3"
    local output="$temporary_root/module-$name.log"
    if "$module_checker" --root "$root" >"$output" 2>&1; then
        printf 'FAIL module dependency fixture %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! rg -q -- "$expected" "$output"; then
        cat "$output" >&2
        printf 'FAIL module dependency fixture %s: expected diagnostic matching %s\n' "$name" "$expected" >&2
        exit 1
    fi
    printf 'PASS module dependency fixture %s\n' "$name"
}

new_fixture() {
    local name="$1"
    local destination="$temporary_root/$name"
    mkdir -p "$destination"
    cp -R "$fixture_root/." "$destination/"
    printf '%s\n' "$destination"
}

mutate_lock() {
    local root="$1"
    local mode="$2"
    python3 - "$root" "$mode" <<'PY'
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
lock_path = root / "ThirdParty/ThirdParty.lock.json"
lock = json.loads(lock_path.read_text())
component = lock["components"][0]
vendored_component = lock["components"][1]

def use_project_package(repository, version):
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let package = Package(name: "LockFixture", dependencies: [], targets: [])\n'
    )
    (root / "project-packages.json").write_text(
        json.dumps(
            {
                "packages": {
                    "fixture-package": {
                        "url": repository,
                        "exactVersion": version,
                    }
                }
            },
            indent=2,
        )
        + "\n"
    )
    (root / "project.yml").write_text(
        "name: LockFixture\n"
        "include:\n"
        "  - project-packages.json\n"
        "targets:\n"
        "  LockFixture:\n"
        "    type: framework\n"
        "    platform: macOS\n"
        "    sources: []\n"
    )

if mode == "branch":
    component["commit"] = "main"
elif mode == "short-commit":
    component["commit"] = "6a52f32"
elif mode == "reference-non-source":
    component["ships"] = "reference"
elif mode == "reference-build-flags":
    component["kind"] = "source"
    component["ships"] = "reference"
    component["buildFlags"] = ["-DREFERENCE_FIXTURE"]
elif mode == "reference-patch":
    component["kind"] = "source"
    component["ships"] = "reference"
    component["patches"] = ["swift-argument-parser/0001-reference.patch"]
    patch_path = root / "ThirdParty/patches/swift-argument-parser/0001-reference.patch"
    patch_path.parent.mkdir(parents=True, exist_ok=True)
    patch_path.write_text("reference fixture patch\n")
elif mode == "unsupported-ships":
    component["ships"] = "reference-only"
elif mode == "non-source-patch":
    component["patches"] = ["swift-argument-parser/0001-non-source.patch"]
    patch_path = root / "ThirdParty/patches/swift-argument-parser/0001-non-source.patch"
    patch_path.parent.mkdir(parents=True, exist_ok=True)
    patch_path.write_text("fixture patch on a non-source component\n")
elif mode == "missing-patch":
    component["kind"] = "source"
    component["patches"] = ["swift-argument-parser/0001-missing.patch"]
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let package = Package(name: "LockFixture", dependencies: [], targets: [])\n'
    )
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"] = []
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode == "pin-mismatch":
    component["commit"] = "0000000000000000000000000000000000000000"
elif mode == "repository-path-suffix":
    component["repository"] = "https://github.com/apple/swift.git-argument-parser.git"
elif mode == "repository-path-case":
    component["repository"] = "https://github.com/Apple/swift-argument-parser.git"
elif mode == "repository-default-port":
    default_port_url = "https://github.com:443/apple/swift-argument-parser.git"
    manifest_path = root / "Package.swift"
    manifest_path.write_text(
        manifest_path.read_text().replace(
            "https://github.com/apple/swift-argument-parser.git",
            default_port_url,
        )
    )
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"][0]["location"] = default_port_url
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode in (
    "malformed-repository-url",
    "malformed-repository-empty-host",
    "malformed-repository-invalid-port",
    "malformed-repository-empty-port",
    "malformed-repository-overflow-port",
):
    malformed_manifest_url = {
        "malformed-repository-url": "https://bad%/Foo.git",
        "malformed-repository-empty-host": "https:///Foo.git",
        "malformed-repository-invalid-port": "https://example.com:99999/Foo.git",
        "malformed-repository-empty-port": "https://example.com:/Foo.git",
        "malformed-repository-overflow-port": "https://example.com:999999999999999999999999/Foo.git",
    }[mode]
    manifest_path = root / "Package.swift"
    manifest_path.write_text(
        manifest_path.read_text().replace(
            "https://github.com/apple/swift-argument-parser.git",
            malformed_manifest_url,
        )
    )
    component["repository"] = malformed_manifest_url.lower()
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"][0]["location"] = malformed_manifest_url.upper().replace("HTTPS://", "https://")
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode == "unlisted-pin":
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"].append(
        {
            "identity": "unlisted-package",
            "kind": "remoteSourceControl",
            "location": "https://example.com/unlisted-package.git",
            "state": {
                "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "version": "1.0.0",
            },
        }
    )
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode == "non-exact-comment":
    manifest_path = root / "Package.swift"
    manifest = manifest_path.read_text()
    manifest_path.write_text(
        manifest.replace(
            'exact: "1.8.2"',
            'from: "1.8.2" // exact: "1.8.2"',
        )
    )
elif mode == "unlocked-manifest-package":
    manifest_path = root / "Package.swift"
    manifest = manifest_path.read_text()
    manifest_path.write_text(
        manifest.replace(
            "    ],\n    targets: []",
            '        .package(url: "https://example.com/unlisted.git", exact: "9.9.9"),\n'
            "    ],\n    targets: []",
        )
    )
elif mode == "variable-manifest-package":
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let repository = "https://example.com/unlisted.git"\n'
        "let package = Package(\n"
        '    name: "LockFixture",\n'
        "    dependencies: [.package(url: repository, exact: \"9.9.9\")],\n"
        "    targets: []\n"
        ")\n"
    )
elif mode == "raw-manifest-package":
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let package = Package(name: "LockFixture", dependencies: [\n'
        '    .package(url: #"https://example.com/unlisted.git"#, exact: "9.9.9"),\n'
        "], targets: [])\n"
    )
elif mode == "string-manifest-package":
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        "let example = #\"\"\"\n"
        '.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")\n'
        "\"\"\"#\n"
        'let package = Package(name: "LockFixture", targets: [])\n'
    )
elif mode == "project-yml-version":
    use_project_package("https://github.com/apple/swift-argument-parser.git", "1.8.2")
elif mode == "unlisted-project-package":
    use_project_package("https://example.com/unlisted.git", "9.9.9")
elif mode == "malformed-patches":
    component["patches"] = [123]
elif mode == "fifo-patch":
    component["kind"] = "source"
    component["patches"] = ["swift-argument-parser/0001-fifo.patch"]
    patch = root / "ThirdParty/patches/swift-argument-parser/0001-fifo.patch"
    patch.parent.mkdir(parents=True, exist_ok=True)
    os.mkfifo(patch)
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let package = Package(name: "LockFixture", dependencies: [], targets: [])\n'
    )
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"] = []
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode == "duplicate-pin":
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    duplicate = dict(resolved["pins"][0])
    duplicate["state"] = dict(duplicate["state"])
    duplicate["state"]["revision"] = "0" * 40
    resolved["pins"].append(duplicate)
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
elif mode == "boolean-schema":
    lock["schemaVersion"] = True
elif mode == "symlink-patch":
    component["patches"] = ["swift-argument-parser/0001-escape.patch"]
    patch = root / "ThirdParty/patches/swift-argument-parser/0001-escape.patch"
    patch.parent.mkdir(parents=True, exist_ok=True)
    patch.symlink_to(root / "Package.swift")
elif mode == "symlink-patch-directory":
    component["patches"] = ["swift-argument-parser/0001-escape.patch"]
    patches = root / "ThirdParty/patches/swift-argument-parser"
    patches.parent.mkdir(parents=True, exist_ok=True)
    license_dir = root / "ThirdParty/licenses/swift-argument-parser"
    (license_dir / "0001-escape.patch").write_text("patch fixture\n")
    patches.symlink_to(license_dir, target_is_directory=True)
elif mode == "symlink-license":
    component["licenseFiles"] = ["escape.txt"]
    license_dir = root / "ThirdParty/licenses/swift-argument-parser"
    (license_dir / "escape.txt").symlink_to(root / "Package.swift")
elif mode == "commit-trailing-newline":
    component["commit"] += "\n"
elif mode == "hash-trailing-newline":
    component["sha256"] = "a" * 64 + "\n"
elif mode == "malformed-resolved-json":
    (root / "Package.resolved").write_text("{\n")
elif mode == "vendored-file-hash":
    vendored_component["files"][0]["sha256"] = "0" * 64
elif mode == "vendored-file-path":
    vendored_component["files"][0]["path"] = "../Package.swift"
elif mode == "vendored-file-symlink":
    file_path = root / "Images/tools/vendor/escape.py"
    file_path.symlink_to(root / "Package.swift")
    vendored_component["files"] = [
        {
            "path": "Images/tools/vendor/escape.py",
            "sha256": "0" * 64,
        }
    ]
else:
    raise SystemExit(f"unknown mutation: {mode}")

lock_path.write_text(json.dumps(lock, indent=2) + "\n")
PY
}

expect_pass "valid lock" "$fixture_root"
expect_pass "repository lock" "$repo_root"

expect_cli_fail() {
    local name="$1"
    local expected="$2"
    shift 2
    local output="$temporary_root/cli-$name.log"
    if "$checker" "$@" >"$output" 2>&1; then
        printf 'FAIL check-lock arguments %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! rg -q -- "$expected" "$output"; then
        cat "$output" >&2
        printf 'FAIL check-lock arguments %s: expected diagnostic matching %s\n' "$name" "$expected" >&2
        exit 1
    fi
    printf 'PASS check-lock arguments %s\n' "$name"
}

expect_cli_fail "unknown option" "usage: check-lock.swift" --unknown
expect_cli_fail "missing root value" "usage: check-lock.swift" --root
expect_cli_fail "root value cannot be another option" "usage: check-lock.swift" --root --apply
expect_cli_fail "duplicate apply option" "--apply may be specified once" --apply --apply

python3 - "$checker" "$fixture_root" "$temporary_root" <<'PY'
import pathlib
import os
import shutil
import subprocess
import sys

checker = pathlib.Path(sys.argv[1])
fixture_root = pathlib.Path(sys.argv[2])
temporary_root = pathlib.Path(sys.argv[3])
for name, relative_path, expected in (
    ("lock", "ThirdParty/ThirdParty.lock.json", "lock file is not a regular file"),
    ("resolved", "Package.resolved", "Swift package lock file is not a regular file"),
):
    root = temporary_root / f"{name}-fifo"
    shutil.copytree(fixture_root, root)
    special_file = root / relative_path
    special_file.unlink()
    os.mkfifo(special_file)
    try:
        result = subprocess.run(
            [str(checker), "--root", str(root)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(f"FAIL check-lock {name} FIFO: reading the file blocked")
    output = result.stdout + result.stderr
    if result.returncode == 0 or expected not in output:
        raise SystemExit(f"FAIL check-lock {name} FIFO: unexpected result\n{output}")
    print(f"PASS check-lock {name} FIFO is rejected without blocking")
PY

python3 - "$checker" "$fixture_root" "$temporary_root/apply-lock" "$repo_root" <<'PY'
import json
import os
import fcntl
import pathlib
import shutil
import stat
import subprocess
import sys
import time

checker = pathlib.Path(sys.argv[1])
fixture_root = pathlib.Path(sys.argv[2])
temporary_root = pathlib.Path(sys.argv[3])
repo_root = pathlib.Path(sys.argv[4])


def run_git(directory, *arguments, capture=False):
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        check=True,
        capture_output=capture,
        text=True,
    )


def prepare_fixture(name, mode):
    root = temporary_root / name
    shutil.copytree(fixture_root, root)
    lock_path = root / "ThirdParty/ThirdParty.lock.json"
    lock = json.loads(lock_path.read_text())
    component = lock["components"][0]
    component["kind"] = "source"
    component["buildFlags"] = []
    component["patches"] = []
    component["ships"] = ["reference"] if mode == "reference" else "app"

    package_manifest = root / "Package.swift"
    package_manifest.write_text(
        "// swift-tools-version: 6.2\n"
        "import PackageDescription\n"
        'let package = Package(name: "LockFixture", dependencies: [], targets: [])\n'
    )
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"] = []
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")

    if mode == "reference":
        lock_path.write_text(json.dumps(lock, indent=2) + "\n")
        return root, None, None

    component["patches"] = ["swift-argument-parser/0001-fixture.patch"]
    patch_path = root / "ThirdParty/patches/swift-argument-parser/0001-fixture.patch"
    patch_path.parent.mkdir(parents=True, exist_ok=True)
    if mode == "missing":
        patch_path.write_text("fixture patch; source is intentionally absent\n")
        lock_path.write_text(json.dumps(lock, indent=2) + "\n")
        return root, None, None

    worktree = root / "source-worktree"
    worktree.mkdir()
    run_git(worktree, "init", "--quiet")
    run_git(worktree, "config", "user.name", "APKRun Fixture")
    run_git(worktree, "config", "user.email", "fixture@example.invalid")
    if mode == "ignored-collision":
        (worktree / ".gitignore").write_text("ignored-patch-output.txt\n")
        run_git(worktree, "add", ".gitignore")
    if mode in ("configured-filter", "configured-merge-driver"):
        attribute = "filter=fixture" if mode == "configured-filter" else "merge=fixture"
        (worktree / ".gitattributes").write_text(f"payload.txt {attribute}\n")
        run_git(worktree, "add", ".gitattributes")
    (worktree / "payload.txt").write_text("before\n")
    run_git(worktree, "add", "payload.txt")
    run_git(worktree, "commit", "--quiet", "-m", "fixture baseline")
    baseline = run_git(worktree, "rev-parse", "HEAD", capture=True).stdout.strip()

    (worktree / "payload.txt").write_text("after\n")
    if mode == "ignored-collision":
        (worktree / "ignored-patch-output.txt").write_text("patch contents\n")
        run_git(worktree, "add", "payload.txt")
        run_git(worktree, "add", "-f", "ignored-patch-output.txt")
    else:
        run_git(worktree, "add", "payload.txt")
    run_git(worktree, "commit", "--quiet", "-m", "fixture patch")
    patch = run_git(worktree, "format-patch", "--stdout", "-1", capture=True).stdout
    patch_path.write_text(patch)
    if mode == "patch-parent-symlink":
        external_patches = temporary_root / f"{name}-external-patches"
        patch_path.parent.rename(external_patches)
        patch_path.parent.symlink_to(external_patches, target_is_directory=True)
    if mode == "failing-series":
        component["patches"].append("swift-argument-parser/0002-invalid.patch")
        (patch_path.parent / "0002-invalid.patch").write_text("not a git patch\n")
    run_git(worktree, "reset", "--quiet", "--hard", baseline)
    run_git(worktree, "checkout", "--quiet", "--detach", baseline)

    lock_commit = "1" * 40 if mode == "mismatched" else baseline
    component["commit"] = lock_commit
    source_root = root / "ThirdParty/out/src/swift-argument-parser" / lock_commit
    source_root.parent.mkdir(parents=True, exist_ok=True)
    if mode == "symlink":
        external_root = temporary_root / f"{name}-external"
        external_root.parent.mkdir(parents=True, exist_ok=True)
        worktree.rename(external_root)
        source_root.symlink_to(external_root, target_is_directory=True)
    elif mode == "external-common-dir":
        run_git(
            worktree,
            "worktree",
            "add",
            "--quiet",
            "--detach",
            str(source_root),
            baseline,
        )
        pointer = (source_root / ".git").read_text().strip()
        metadata_path = pathlib.Path(pointer.removeprefix("gitdir: ")).resolve()
        local_metadata = source_root / ".git-metadata"
        shutil.move(metadata_path, local_metadata)
        (source_root / ".git").write_text(f"gitdir: {local_metadata}\n")
        common_directory = run_git(
            worktree, "rev-parse", "--absolute-git-dir", capture=True
        ).stdout.strip()
        (local_metadata / "commondir").write_text(f"{common_directory}\n")
        (local_metadata / "gitdir").write_text(f"{source_root / '.git'}\n")
    else:
        worktree.rename(source_root)
    if mode == "index-fifo":
        index_path = pathlib.Path(
            run_git(source_root, "rev-parse", "--git-path", "index", capture=True).stdout.strip()
        )
        if not index_path.is_absolute():
            index_path = source_root / index_path
        index_path.unlink()
        os.mkfifo(index_path)
    if mode == "head-fifo":
        head_path = source_root / ".git/HEAD"
        head_path.unlink()
        os.mkfifo(head_path)
    if mode == "active-operation":
        state_path = run_git(
            source_root, "rev-parse", "--git-path", "rebase-apply", capture=True
        ).stdout.strip()
        state_dir = pathlib.Path(state_path)
        if not state_dir.is_absolute():
            state_dir = source_root / state_dir
        state_dir.mkdir(parents=True)
    if mode == "ignored-collision":
        (source_root / "ignored-patch-output.txt").write_text("user data\n")
    if mode == "dirty":
        (source_root / "payload.txt").write_text("local change\n")
    if mode == "valid":
        payload = source_root / "payload.txt"
        payload_metadata = payload.stat()
        os.utime(
            payload,
            ns=(payload_metadata.st_atime_ns, payload_metadata.st_mtime_ns + 5_000_000_000),
        )
    if mode == "assume-unchanged":
        (source_root / "payload.txt").write_text("hidden local change\n")
        run_git(source_root, "update-index", "--assume-unchanged", "payload.txt")
    if mode == "fsmonitor":
        marker = root / "fsmonitor-helper-invoked"
        helper = root / "fsmonitor-helper.sh"
        helper.write_text(
            "#!/bin/sh\n"
            f"printf x >> '{marker}'\n"
            "printf 'token\\000'\n"
        )
        helper.chmod(0o700)
        run_git(source_root, "config", "core.fsmonitor", str(helper))
    if mode == "configured-filter":
        marker = root / "filter-helper-invoked"
        helper = root / "filter-helper.sh"
        helper.write_text(
            "#!/bin/sh\n"
            f"printf x >> '{marker}'\n"
            "cat\n"
        )
        helper.chmod(0o700)
        run_git(source_root, "config", "filter.fixture.clean", str(helper))
    if mode == "configured-merge-driver":
        marker = root / "merge-driver-invoked"
        helper = root / "merge-driver.sh"
        helper.write_text(
            "#!/bin/sh\n"
            f"printf x >> '{marker}'\n"
            "cat \"$1\"\n"
        )
        helper.chmod(0o700)
        run_git(source_root, "config", "merge.fixture.driver", str(helper))
    if mode == "config-include-fifo":
        include_path = root / "blocked-config-include"
        os.mkfifo(include_path)
        (source_root / ".git/config").write_text(
            f'[include]\n path = "{include_path}"\n'
        )
    if mode == "config-fifo":
        config_path = source_root / ".git/config"
        config_path.unlink()
        os.mkfifo(config_path)
    if mode == "output-parent-symlink":
        external_output = temporary_root / f"{name}-external-output"
        external_output.mkdir()
        (root / "ThirdParty/out/patched-src").symlink_to(
            external_output,
            target_is_directory=True,
        )
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    return root, source_root, baseline


def check(name, mode, expected, diagnostic=None):
    root, source_root, baseline = prepare_fixture(name, mode)
    source_index = (
        (source_root / ".git/index").read_bytes()
        if mode == "valid"
        else None
    )
    environment = os.environ.copy()
    if mode in ("valid", "fsmonitor"):
        environment["GIT_DIR"] = run_git(
            repo_root, "rev-parse", "--absolute-git-dir", capture=True
        ).stdout.strip()
    if mode == "lock-held":
        lock_path = root / "ThirdParty/out/.check-lock-apply.lock"
        lock_path.touch()
        lock_handle = lock_path.open("r+")
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = subprocess.run(
                [str(checker), "--root", str(root), "--apply"],
                capture_output=True,
                text=True,
                env=environment,
                timeout=5
                if mode in (
                    "config-include-fifo",
                    "config-fifo",
                    "index-fifo",
                    "head-fifo",
                )
                else 30,
                check=False,
            )
        finally:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            lock_handle.close()
    elif mode == "output-parent-move":
        output_parent = (
            root / "ThirdParty/out/patched-src/swift-argument-parser" / baseline
        )
        moved_parent = temporary_root / f"{name}-moved-parent"
        symlink_target = temporary_root / f"{name}-symlink-target"
        symlink_target.mkdir()
        process = subprocess.Popen(
            [str(checker), "--root", str(root), "--apply"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        moved = False
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            staging = list(root.glob(".apkrun-patch-staging-*"))
            if (
                staging
                and output_parent.is_dir()
                and not output_parent.is_symlink()
            ):
                output_parent.rename(moved_parent)
                output_parent.symlink_to(symlink_target, target_is_directory=True)
                moved = True
                break
            time.sleep(0.001)
        if not moved:
            process.kill()
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"FAIL lock patch fixture {name}: couldn't move the opened output parent\n"
                f"{stdout}{stderr}"
            )
        try:
            stdout, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"FAIL lock patch fixture {name}: checker hung after output-parent move\n"
                f"{stdout}{stderr}"
            )
        result = subprocess.CompletedProcess(
            process.args,
            process.returncode,
            stdout,
            stderr,
        )
    else:
        result = subprocess.run(
            [str(checker), "--root", str(root), "--apply"],
            capture_output=True,
            text=True,
            env=environment,
            timeout=5
            if mode in (
                "config-include-fifo",
                "config-fifo",
                "index-fifo",
                "head-fifo",
            )
            else 30,
            check=False,
        )
    helper_marker = {
        "fsmonitor": root / "fsmonitor-helper-invoked",
        "configured-filter": root / "filter-helper-invoked",
        "configured-merge-driver": root / "merge-driver-invoked",
    }.get(mode)
    if helper_marker is not None and helper_marker.exists():
        raise SystemExit(f"FAIL lock patch fixture {name}: configured helper was executed")
    if (result.returncode == 0) != expected:
        raise SystemExit(
            f"FAIL lock patch fixture {name}: unexpected exit {result.returncode}\n"
            f"{result.stdout}{result.stderr}"
        )
    output = result.stdout + result.stderr
    if diagnostic and diagnostic not in output:
        raise SystemExit(
            f"FAIL lock patch fixture {name}: missing {diagnostic!r}\n{output}"
        )
    if mode == "valid":
        if (source_root / ".git/index").read_bytes() != source_index:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: check-lock changed the pinned source index"
            )
        source_head = run_git(
            source_root, "rev-parse", "HEAD", capture=True
        ).stdout.strip()
        source_status = run_git(
            source_root, "status", "--porcelain=v1", capture=True
        ).stdout
        if source_head != baseline or source_status:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: pinned source checkout changed"
            )
        patched_parent = (
            root / "ThirdParty/out/patched-src/swift-argument-parser" / baseline
        )
        patched_checkouts = list(patched_parent.iterdir())
        if len(patched_checkouts) != 1:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: expected one patch-set checkout, "
                f"found {len(patched_checkouts)}"
            )
        patched_root = patched_checkouts[0]
        actual = run_git(patched_root, "show", "HEAD:payload.txt", capture=True).stdout
        if actual != "after\n":
            raise SystemExit(f"FAIL lock patch fixture {name}: patch contents were not applied")
        head = run_git(patched_root, "rev-parse", "HEAD", capture=True).stdout.strip()
        if head == baseline:
            raise SystemExit(f"FAIL lock patch fixture {name}: git am did not create a commit")
        parent = run_git(patched_root, "rev-parse", "HEAD^", capture=True).stdout.strip()
        if parent != baseline:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: applied commit has unexpected parent {parent}"
            )
        repeated = subprocess.run(
            [str(checker), "--root", str(root), "--apply"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if repeated.returncode != 0 or "patches applied" not in repeated.stdout:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: existing patched output was not reusable\n"
                f"{repeated.stdout}{repeated.stderr}"
            )
    if mode == "failing-series":
        head = run_git(source_root, "rev-parse", "HEAD", capture=True).stdout.strip()
        status = run_git(source_root, "status", "--porcelain=v1", capture=True).stdout
        output_path = root / "ThirdParty/out/patched-src/swift-argument-parser" / baseline
        if head != baseline or status or output_path.exists():
            raise SystemExit(
                f"FAIL lock patch fixture {name}: failed preflight changed the pinned checkout"
            )
    if mode == "symlink":
        actual = run_git(source_root, "show", "HEAD:payload.txt", capture=True).stdout
        if actual != "before\n":
            raise SystemExit(
                f"FAIL lock patch fixture {name}: linked checkout was unexpectedly modified"
            )
    if mode == "active-operation":
        state_path = run_git(
            source_root, "rev-parse", "--git-path", "rebase-apply", capture=True
        ).stdout.strip()
        state_dir = pathlib.Path(state_path)
        if not state_dir.is_absolute():
            state_dir = source_root / state_dir
        if not state_dir.is_dir():
            raise SystemExit(
                f"FAIL lock patch fixture {name}: existing Git operation state was removed"
            )
    if mode == "ignored-collision":
        if (source_root / "ignored-patch-output.txt").read_text() != "user data\n":
            raise SystemExit(
                f"FAIL lock patch fixture {name}: ignored user data was overwritten"
            )
        head = run_git(source_root, "rev-parse", "HEAD", capture=True).stdout.strip()
        if head != baseline:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: ignored collision changed the pinned commit"
            )
    if mode == "assume-unchanged":
        if (source_root / "payload.txt").read_text() != "hidden local change\n":
            raise SystemExit(f"FAIL lock patch fixture {name}: hidden tracked edit was overwritten")
        head = run_git(source_root, "rev-parse", "HEAD", capture=True).stdout.strip()
        if head != baseline:
            raise SystemExit(f"FAIL lock patch fixture {name}: hidden edit advanced HEAD")
    if mode == "external-common-dir":
        if (source_root / "payload.txt").read_text() != "before\n":
            raise SystemExit(f"FAIL lock patch fixture {name}: shared repository checkout changed")
    if mode == "lock-held":
        head = run_git(source_root, "rev-parse", "HEAD", capture=True).stdout.strip()
        if head != baseline:
            raise SystemExit(f"FAIL lock patch fixture {name}: competing apply changed HEAD")
    if mode == "config-include-fifo":
        if not stat.S_ISFIFO((root / "blocked-config-include").lstat().st_mode):
            raise SystemExit(f"FAIL lock patch fixture {name}: include FIFO was unexpectedly changed")
    if mode == "config-fifo":
        if not stat.S_ISFIFO((source_root / ".git/config").lstat().st_mode):
            raise SystemExit(f"FAIL lock patch fixture {name}: config FIFO was unexpectedly changed")
    if mode == "index-fifo":
        if not stat.S_ISFIFO((source_root / ".git/index").lstat().st_mode):
            raise SystemExit(f"FAIL lock patch fixture {name}: index FIFO was unexpectedly changed")
    if mode == "head-fifo":
        if not stat.S_ISFIFO((source_root / ".git/HEAD").lstat().st_mode):
            raise SystemExit(f"FAIL lock patch fixture {name}: HEAD FIFO was unexpectedly changed")
    if mode == "output-parent-symlink":
        external_output = temporary_root / f"{name}-external-output"
        if list(external_output.iterdir()):
            raise SystemExit(
                f"FAIL lock patch fixture {name}: symlink target received output"
            )
    if mode == "output-parent-move":
        symlink_target = temporary_root / f"{name}-symlink-target"
        staging = list(root.glob(".apkrun-patch-staging-*"))
        if list(symlink_target.iterdir()):
            raise SystemExit(
                f"FAIL lock patch fixture {name}: clone or publication followed the replacement symlink"
            )
        if len(staging) != 1:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: expected one preserved root staging checkout"
            )
        if (source_root / ".git/HEAD").read_text().strip() != baseline:
            raise SystemExit(
                f"FAIL lock patch fixture {name}: moving the output parent changed the pinned source"
            )
    print(f"PASS lock patch fixture {name}")


check("apply-valid", "valid", True, "patches applied")
check("apply-missing-source", "missing", False, "pinned source checkout is missing")
check("apply-wrong-pin", "mismatched", False, "expected pinned commit")
check("apply-dirty-source", "dirty", False, "source checkout is not clean")
check("apply-symlink-source", "symlink", False, "source checkout path contains a symlink")
check("apply-reference-without-checkout", "reference", True, "no patches to apply")
check("apply-preflights-failed-series", "failing-series", False, "source checkouts were not changed")
check("apply-preserves-active-git-operation", "active-operation", False, "Git operation is already in progress")
check("apply-preserves-ignored-user-data", "ignored-collision", False, "including ignored files")
check("apply-detects-assume-unchanged", "assume-unchanged", False, "non-normal flags")
check("apply-rejects-external-git-common-dir", "external-common-dir", False, "shared Git metadata must be inside")
check("apply-disables-configured-fsmonitor", "fsmonitor", True, "patches applied")
check(
    "apply-rejects-configured-filter",
    "configured-filter",
    False,
    "custom Git filters or merge drivers are configured",
)
check(
    "apply-rejects-configured-merge-driver",
    "configured-merge-driver",
    False,
    "custom Git filters or merge drivers are configured",
)
check(
    "apply-rejects-included-config-fifo",
    "config-include-fifo",
    False,
    "Git config includes are not allowed",
)
check("apply-rejects-config-fifo-without-blocking", "config-fifo", False, "Git config is not a regular file")
check("apply-rejects-index-fifo-without-blocking", "index-fifo", False, "Git index is not a regular file")
check("apply-rejects-head-fifo-without-blocking", "head-fifo", False, "Git HEAD is not a regular file")
check(
    "apply-rejects-output-parent-symlink",
    "output-parent-symlink",
    False,
    "couldn't safely open patched-source output directory",
)
check(
    "apply-detects-output-parent-move",
    "output-parent-move",
    False,
    "couldn't safely open patched-source output directory",
)
check(
    "apply-rejects-patch-parent-symlink",
    "patch-parent-symlink",
    False,
    "patch is not a regular file within its allowed directory",
)
check("apply-serializes-concurrent-runs", "lock-held", False, "another check-lock --apply operation")
PY

reference_non_source_root="$(new_fixture reference-non-source)"
mutate_lock "$reference_non_source_root" reference-non-source
expect_fail "reference classification requires a source" "reference to be the sole ships value for a source component" "$reference_non_source_root"

reference_build_flags_root="$(new_fixture reference-build-flags)"
mutate_lock "$reference_build_flags_root" reference-build-flags
expect_fail "reference entries reject build flags" "reference entries must not declare build flags or patches" "$reference_build_flags_root"

reference_patch_root="$(new_fixture reference-patch)"
mutate_lock "$reference_patch_root" reference-patch
expect_fail "reference entries reject patches" "reference entries must not declare build flags or patches" "$reference_patch_root"

unsupported_ships_root="$(new_fixture unsupported-ships)"
mutate_lock "$unsupported_ships_root" unsupported-ships
expect_fail "unsupported ships classification" "unsupported 'ships' value" "$unsupported_ships_root"

non_source_patch_root="$(new_fixture non-source-patch)"
mutate_lock "$non_source_patch_root" non-source-patch
expect_fail "patches require a source component" "may declare patches only for source components" "$non_source_patch_root"

branch_root="$(new_fixture branch-name)"
mutate_lock "$branch_root" branch
expect_fail "branch commit" "commit must be 40 lowercase hexadecimal" "$branch_root"

short_root="$(new_fixture short-commit)"
mutate_lock "$short_root" short-commit
expect_fail "short commit" "commit must be 40 lowercase hexadecimal" "$short_root"

patch_root="$(new_fixture missing-patch)"
mutate_lock "$patch_root" missing-patch
expect_fail "missing patch" "patch is missing" "$patch_root"

mismatch_root="$(new_fixture pin-mismatch)"
mutate_lock "$mismatch_root" pin-mismatch
expect_fail "pin mismatch" "revision .* does not match lock commit" "$mismatch_root"

repository_suffix_root="$(new_fixture repository-path-suffix)"
mutate_lock "$repository_suffix_root" repository-path-suffix
expect_fail "repository path suffix is preserved" "does not match lock repository" "$repository_suffix_root"

repository_case_root="$(new_fixture repository-path-case)"
mutate_lock "$repository_case_root" repository-path-case
expect_fail "repository path case is preserved" "does not match lock repository" "$repository_case_root"

default_port_root="$(new_fixture repository-default-port)"
mutate_lock "$default_port_root" repository-default-port
expect_pass "HTTPS default repository port is normalized" "$default_port_root"

malformed_repository_root="$(new_fixture malformed-repository-url)"
mutate_lock "$malformed_repository_root" malformed-repository-url
expect_fail "malformed repository URL is rejected" "valid HTTPS repository URL|command failed" "$malformed_repository_root"

empty_host_root="$(new_fixture malformed-repository-empty-host)"
mutate_lock "$empty_host_root" malformed-repository-empty-host
expect_fail "empty repository URL host is rejected" "valid HTTPS repository URL|command failed" "$empty_host_root"

invalid_port_root="$(new_fixture malformed-repository-invalid-port)"
mutate_lock "$invalid_port_root" malformed-repository-invalid-port
expect_fail "invalid repository URL port is rejected" "valid HTTPS repository URL|command failed" "$invalid_port_root"

empty_port_root="$(new_fixture malformed-repository-empty-port)"
mutate_lock "$empty_port_root" malformed-repository-empty-port
expect_fail "empty repository URL port is rejected" "valid HTTPS repository URL|command failed" "$empty_port_root"

overflow_port_root="$(new_fixture malformed-repository-overflow-port)"
mutate_lock "$overflow_port_root" malformed-repository-overflow-port
expect_fail "overflowing repository URL port is rejected" "valid HTTPS repository URL|command failed" "$overflow_port_root"

unlisted_root="$(new_fixture unlisted-pin)"
mutate_lock "$unlisted_root" unlisted-pin
expect_fail "unlisted Swift package pin" "has no ThirdParty lock entry" "$unlisted_root"

comment_root="$(new_fixture non-exact-comment)"
mutate_lock "$comment_root" non-exact-comment
expect_fail "comment cannot satisfy exact pin" "must use an exact version requirement" "$comment_root"

unlocked_manifest_root="$(new_fixture unlocked-manifest-package)"
mutate_lock "$unlocked_manifest_root" unlocked-manifest-package
expect_fail "unlocked manifest package" "has no ThirdParty lock entry" "$unlocked_manifest_root"

variable_manifest_root="$(new_fixture variable-manifest-package)"
mutate_lock "$variable_manifest_root" variable-manifest-package
expect_fail "variable manifest package" "has no ThirdParty lock entry" "$variable_manifest_root"

raw_manifest_root="$(new_fixture raw-manifest-package)"
mutate_lock "$raw_manifest_root" raw-manifest-package
expect_fail "raw string manifest package" "has no ThirdParty lock entry" "$raw_manifest_root"

string_manifest_root="$(new_fixture string-manifest-package)"
mutate_lock "$string_manifest_root" string-manifest-package
expect_fail "string literal cannot declare package" "must be declared in Package.swift or project.yml" "$string_manifest_root"

project_version_root="$(new_fixture project-yml-version)"
mutate_lock "$project_version_root" project-yml-version
expect_pass "exact included project package version" "$project_version_root"

unlisted_project_root="$(new_fixture unlisted-project-package)"
mutate_lock "$unlisted_project_root" unlisted-project-package
expect_fail "unlisted included project package" "has no ThirdParty lock entry" "$unlisted_project_root"

malformed_patches_root="$(new_fixture malformed-patches)"
mutate_lock "$malformed_patches_root" malformed-patches
expect_fail "malformed patch list" "requires a 'patches' string array" "$malformed_patches_root"

fifo_patch_root="$(new_fixture fifo-patch)"
mutate_lock "$fifo_patch_root" fifo-patch
expect_fail "FIFO patch rejected" "patch is not a regular file within its allowed directory" "$fifo_patch_root"

duplicate_pin_root="$(new_fixture duplicate-pin)"
mutate_lock "$duplicate_pin_root" duplicate-pin
expect_fail "duplicate Swift package pin" "duplicate Swift package pin" "$duplicate_pin_root"

boolean_schema_root="$(new_fixture boolean-schema)"
mutate_lock "$boolean_schema_root" boolean-schema
expect_fail "boolean schema version" "expected schemaVersion 1 and components" "$boolean_schema_root"

symlink_patch_root="$(new_fixture symlink-patch)"
mutate_lock "$symlink_patch_root" symlink-patch
expect_fail "patch symlink escape" "patch is not a regular file within its allowed directory" "$symlink_patch_root"

symlink_patch_directory_root="$(new_fixture symlink-patch-directory)"
mutate_lock "$symlink_patch_directory_root" symlink-patch-directory
expect_fail "patch directory symlink escape" "patch is not a regular file within its allowed directory" "$symlink_patch_directory_root"

symlink_license_root="$(new_fixture symlink-license)"
mutate_lock "$symlink_license_root" symlink-license
expect_fail "license symlink escape" "license path is not a regular file within its allowed directory" "$symlink_license_root"

commit_newline_root="$(new_fixture commit-trailing-newline)"
mutate_lock "$commit_newline_root" commit-trailing-newline
expect_fail "commit trailing newline" "commit must be 40 lowercase hexadecimal" "$commit_newline_root"

hash_newline_root="$(new_fixture hash-trailing-newline)"
mutate_lock "$hash_newline_root" hash-trailing-newline
expect_fail "hash trailing newline" "sha256 must be 64 hexadecimal" "$hash_newline_root"

malformed_resolved_root="$(new_fixture malformed-resolved-json)"
mutate_lock "$malformed_resolved_root" malformed-resolved-json
expect_fail "malformed resolved JSON diagnostic" "Package.resolved: invalid JSON" "$malformed_resolved_root"

vendored_hash_root="$(new_fixture vendored-file-hash)"
mutate_lock "$vendored_hash_root" vendored-file-hash
expect_fail "vendored file hash mismatch" "vendored file SHA-256 mismatch" "$vendored_hash_root"

vendored_path_root="$(new_fixture vendored-file-path)"
mutate_lock "$vendored_path_root" vendored-file-path
expect_fail "vendored unsafe file path" "has unsafe vendored file path" "$vendored_path_root"

vendored_symlink_root="$(new_fixture vendored-file-symlink)"
mutate_lock "$vendored_symlink_root" vendored-file-symlink
expect_fail "vendored file symlink escape" "vendored path is not a regular file" "$vendored_symlink_root"

module_fixture_root="$script_dir/fixtures/module-deps"
new_module_fixture() {
    local name="$1"
    local destination="$temporary_root/module-$name"
    python3 "$module_fixture_root/prepare.py" "$repo_root" "$destination" "$name"
    printf '%s\n' "$destination"
}

valid_module_root="$(new_module_fixture valid)"
expect_module_pass "valid graph" "$valid_module_root"

forbidden_edge_root="$(new_module_fixture forbidden-edge)"
expect_module_fail "forbidden target edge" "DiagnosticsCore -> RuntimeAPI" "$forbidden_edge_root"

forbidden_import_root="$(new_module_fixture forbidden-import)"
expect_module_fail "forbidden implementation-only import" "forbidden import edge 'DiagnosticsCore -> RuntimeCore'" "$forbidden_import_root"

wrong_trait_root="$(new_module_fixture wrong-trait)"
expect_module_fail "unexpected trait condition" "must use only EmbeddedRuntime" "$wrong_trait_root"

third_party_library_root="$(new_module_fixture third-party-library)"
expect_module_fail "third-party product in library" "ArgumentParser.*not allowed for 'DiagnosticsCore'" "$third_party_library_root"

xcode_framework_root="$(new_module_fixture xcode-forbidden-framework)"
expect_module_fail "XcodeGen SDK dependency" "undeclared sdk dependency.*modules.md" "$xcode_framework_root"

xcode_missing_product_root="$(new_module_fixture xcode-missing-product)"
expect_module_fail "missing XcodeGen third-party product" "missing third-party product edge 'APKRun -> Sparkle'" "$xcode_missing_product_root"

helpers_directory_root="$(new_module_fixture helpers-directory)"
expect_module_fail "forbidden Helpers directory" "forbidden dumping-ground directory 'Helpers'" "$helpers_directory_root"

experiments_import_root="$(new_module_fixture experiments-import)"
expect_module_fail "Experiments module import" "imports Experiments module 'SpikeKit'" "$experiments_import_root"

unclassified_target_root="$(new_module_fixture unclassified-target)"
expect_module_fail "unclassified target dependency and import" "HiddenFixture.*RuntimeCore.*modules.md" "$unclassified_target_root"

experiment_target_root="$(new_module_fixture experiment-target-name-mismatch)"
expect_module_fail "Experiments import uses declared target name" "imports Experiments module 'HiddenExperiment'" "$experiment_target_root"

nested_experiment_root="$(new_module_fixture experiments-nested-package)"
expect_module_fail "nested Experiments product hides its target module" "imports Experiments module 'HiddenExperiment'" "$nested_experiment_root"

backtick_import_root="$(new_module_fixture backtick-import)"
expect_module_fail "backtick-escaped forbidden import" "forbidden import edge 'DiagnosticsCore -> RuntimeCore'" "$backtick_import_root"

nested_tests_import_root="$(new_module_fixture production-nested-tests-import)"
expect_module_fail "production import under nested Tests directory" "forbidden import edge 'RuntimeHost -> GraphicsCore'" "$nested_tests_import_root"

target_owner_root="$(new_module_fixture target-owner-path-mismatch)"
expect_module_fail "module target cannot inherit another owner path" "module target 'GraphicsCore' must be under.*Packages/GraphicsCore" "$target_owner_root"

ruby - "$repo_root/.github/workflows/ci.yml" "$repo_root/.github/workflows/ci-policy.yml" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
jobs = workflow.fetch("jobs")
trigger_key = workflow.key?("on") ? "on" : true
triggers = workflow.fetch(trigger_key)

def workflow_errors(workflow, trigger_key)
  errors = []
  triggers = workflow.fetch(trigger_key)
  unless triggers.key?("pull_request") && !triggers.key?("pull_request_target")
    errors << "pull requests must use the unprivileged pull_request event"
  end
  unless triggers.dig("push", "branches") == ["main"]
    errors << "push checks must run only for main"
  end
  workflow.fetch("jobs").each do |job_name, job|
    unless job["runs-on"] == "xcode-27"
      errors << "#{job_name} must use a fresh GitHub-hosted macOS 27 runner"
    end
    checkout = job.fetch("steps").find do |step|
      step["uses"]&.start_with?("actions/checkout@")
    end
    inputs = checkout&.fetch("with", {})
    unless inputs && inputs["persist-credentials"] == false
      errors << "#{job_name} checkout must not persist credentials"
    end
    unless inputs && inputs["ref"].include?("pull_request.head.sha")
      errors << "#{job_name} checkout must pin the pull request head SHA"
    end
    if inputs && inputs.key?("allow-unsafe-pr-checkout")
      errors << "#{job_name} must not enable unsafe pull request checkout"
    end
  end
  {
    "lint" => "scripts/ci/run-checks.sh",
    "codegen" => "scripts/ci/codegen.sh",
    "build" => "scripts/generate-project.sh",
  }.each do |job_name, check_command|
    steps = workflow.fetch("jobs").fetch(job_name).fetch("steps")
    bootstrap_index = steps.index { |step| step["run"] == "scripts/bootstrap" }
    check_index = steps.index { |step| step["run"] == check_command }
    unless bootstrap_index && check_index && bootstrap_index < check_index
      errors << "#{job_name} must install pinned tools before #{check_command}"
    end
  end
  build_commands = workflow.fetch("jobs").fetch("build").fetch("steps").map { |step| step["run"] }.compact
  build_job = workflow.fetch("jobs").fetch("build")
  unless build_job["needs"] == "third-party"
    errors << "build must wait for the verified third-party runtime"
  end
  build_steps = build_job.fetch("steps")
  build_key = build_steps.index { |step| step["id"] == "third-party-key" }
  build_cache = build_steps.index do |step|
    step["uses"]&.match?(/\Aactions\/cache@[0-9a-f]{40}/)
  end
  build_runtime_check = build_steps.index do |step|
    step["run"] == "scripts/build-third-party.sh virgl-runtime"
  end
  project_generation = build_steps.index { |step| step["run"] == "scripts/generate-project.sh" }
  unless build_key && build_cache && build_runtime_check && project_generation &&
      build_key < build_cache && build_cache < build_runtime_check &&
      build_runtime_check < project_generation
    errors << "build must restore and verify the third-party cache before Xcode project generation"
  end
  build_cache_step = build_steps[build_cache] if build_cache
  unless build_cache_step &&
      build_cache_step.dig("with", "path").to_s.include?("ThirdParty/out/virgl-runtime") &&
      build_cache_step.dig("with", "key").to_s.include?("steps.third-party-key.outputs.key")
    errors << "build cache must use the verified renderer cache key and output path"
  end
  build_parallelism_valid = build_commands.include?("swift build -j 2") &&
    build_commands.include?("swift build -j 2 --traits EmbeddedRuntime") &&
    build_commands.count { |command| command.include?("-jobs 2") } == 2
  unless build_parallelism_valid
    errors << "build parallelism must stay within the hosted runner memory budget"
  end
  test_commands = workflow.fetch("jobs").fetch("test-swift").fetch("steps").map { |step| step["run"] }.compact
  unless test_commands.any? { |command| command.include?("--skip 'SystemTests' -j 2") }
    errors << "test-swift must run T0 only and cap build parallelism"
  end
  image_commands = workflow.fetch("jobs").fetch("test-images").fetch("steps")
    .map { |step| step["run"] }.compact
  unless image_commands.any? { |command| command.include?("python3.12 -m venv Images/tools/.venv") } &&
      image_commands.any? { |command| command.include?("pip install -e 'Images/tools[test]'") } &&
      image_commands.any? { |command| command.include?("pytest Images/tools/tests") } &&
      image_commands.any? { |command| command.include?("ruff check Images/tools") }
    errors << "test-images must install Python tooling and run pytest and Ruff"
  end
  unless workflow.fetch("permissions") == { "contents" => "read" }
    errors << "workflow permissions must remain contents: read"
  end
  expected_jobs = %w[lint codegen third-party build test-swift test-graphics test-images]
  unless workflow.fetch("jobs").keys.sort == expected_jobs.sort
    errors << "CI jobs must match the required job set"
  end
  third_party_steps = workflow.fetch("jobs").fetch("third-party").fetch("steps")
  third_party_bootstrap = third_party_steps.index { |step| step["run"] == "scripts/bootstrap" }
  third_party_key = third_party_steps.index { |step| step["id"] == "third-party-key" }
  third_party_cache = third_party_steps.index do |step|
    step["uses"]&.match?(/\Aactions\/cache@[0-9a-f]{40}/)
  end
  third_party_build = third_party_steps.index do |step|
    step["run"] == "scripts/build-third-party.sh virgl-runtime"
  end
  unless third_party_bootstrap && third_party_key && third_party_cache && third_party_build &&
      third_party_bootstrap < third_party_key &&
      third_party_key < third_party_cache &&
      third_party_cache < third_party_build
    errors << "third-party must bootstrap, compute its pinned cache key, restore cache, then build"
  end
  cache_step = third_party_steps[third_party_cache] if third_party_cache
  unless cache_step &&
      cache_step.dig("with", "path").to_s.include?("ThirdParty/out/virgl-runtime") &&
      cache_step.dig("with", "key").to_s.include?("steps.third-party-key.outputs.key")
    errors << "third-party cache must use the detected renderer cache key and output path"
  end
  unless test_commands.none? { |command| command.include?("check-compile-fail.sh") }
    errors << "T1 compiler-fail checks must not run in the hosted T0 job"
  end
  errors << "workflow must not reference repository secrets" if workflow.to_s.include?("secrets.")
  errors
end

errors = workflow_errors(workflow, trigger_key)
unless errors.empty?
  abort("FAIL workflow security fixture:\n#{errors.map { |error| "  #{error}" }.join("\n")}")
end
puts("PASS workflow security fixture uses ephemeral GitHub-hosted pull request jobs")

unsafe_workflow = Marshal.load(Marshal.dump(workflow))
unsafe_workflow.fetch("jobs").fetch("lint")["runs-on"] = ["self-hosted", "apkrun-ci"]
unless workflow_errors(unsafe_workflow, trigger_key).any? { |error| error.include?("lint must use") }
  abort("FAIL workflow security fixture: accepted a persistent self-hosted runner")
end
puts("PASS workflow security fixture rejects a persistent self-hosted runner")

unsafe_workflow = Marshal.load(Marshal.dump(workflow))
unsafe_triggers = unsafe_workflow.fetch(trigger_key)
unsafe_triggers.delete("pull_request")
unsafe_triggers["pull_request_target"] = {}
unless workflow_errors(unsafe_workflow, trigger_key).any? { |error| error.include?("unprivileged pull_request") }
  abort("FAIL workflow security fixture: accepted pull_request_target")
end
puts("PASS workflow security fixture rejects pull_request_target")

unsafe_workflow = Marshal.load(Marshal.dump(workflow))
unsafe_workflow["env"] = { "LEAK" => "${{ secrets.TEST_SECRET }}" }
unless workflow_errors(unsafe_workflow, trigger_key).any? { |error| error.include?("repository secrets") }
  abort("FAIL workflow security fixture: accepted a repository secret reference")
end
puts("PASS workflow security fixture rejects repository secret references")

unsafe_workflow = Marshal.load(Marshal.dump(workflow))
unsafe_workflow.fetch("jobs").fetch("codegen").fetch("steps").reject! do |step|
  step["run"] == "scripts/bootstrap"
end
unless workflow_errors(unsafe_workflow, trigger_key).any? { |error| error.include?("install pinned tools") }
  abort("FAIL workflow bootstrap fixture: accepted a clean runner without pinned tool setup")
end
puts("PASS workflow bootstrap fixture requires clean runners to install pinned tools")

policy_workflow = YAML.load_file(ARGV.fetch(1))
policy_trigger_key = policy_workflow.key?("on") ? "on" : true
policy_trigger = policy_workflow.fetch(policy_trigger_key).fetch("pull_request_target")
required_policy_events = %w[opened reopened synchronize edited labeled unlabeled]
unless (required_policy_events - policy_trigger.fetch("types")).empty?
  abort("FAIL CI policy workflow fixture: missing revision or label revocation event")
end
policy_checkout = policy_workflow.fetch("jobs").fetch("workflow-policy").fetch("steps").find do |step|
  step["uses"]&.start_with?("actions/checkout@")
end
unless policy_checkout&.dig("with", "ref") == "refs/heads/main"
  abort("FAIL CI policy workflow fixture: policy job must use trusted main")
end
puts("PASS CI policy workflow reruns on edits and label revocation using trusted main")
RUBY

ruby - "$repo_root/.github/workflows/clean-third-party.yml" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
trigger_key = workflow.key?("on") ? "on" : true
triggers = workflow.fetch(trigger_key)
job = workflow.fetch("jobs").fetch("clean-third-party")
steps = job.fetch("steps")
commands = steps.map { |step| step["run"] }.compact
clean_index = commands.index("rm -rf ThirdParty/out")
build_index = commands.index("scripts/build-third-party.sh virgl-runtime")
unless triggers.key?("schedule") && triggers.key?("workflow_dispatch") &&
    job["if"] == "github.ref == 'refs/heads/main'" &&
    job["runs-on"] == "xcode-27" &&
    steps.none? { |step| step["uses"]&.start_with?("actions/cache@") } &&
    clean_index && build_index && clean_index < build_index
  abort("FAIL clean third-party workflow must rebuild main without restoring a cache")
end
puts("PASS weekly third-party workflow performs a clean, uncached build")
RUBY

python3 - "$repo_root/scripts/ci/check-pr-control-changes.py" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
from unittest import mock

script = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("check_pr_control_changes", script)
if spec is None or spec.loader is None:
    raise SystemExit("FAIL CI policy fixture: unable to load policy checker")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

repository = "owner/repository"
head_sha = "a" * 40
base = {"ref": "main", "sha": "b" * 40, "repo": {"full_name": repository}}

def pull_request(sha=head_sha, labels=None, base_info=base):
    return {
        "head": {"sha": sha},
        "base": base_info,
        "user": {"login": "contributor"},
        "labels": [{"name": name} for name in (labels or [])],
    }

def event(action, sha=head_sha, label=None, base_info=base, sender_login="maintainer"):
    result = {
        "action": action,
        "pull_request": {"head": {"sha": sha}, "base": base_info},
        "sender": {"login": sender_login, "type": "User"},
    }
    if label is not None:
        result["label"] = {"name": label}
    return result

def authorized(action, paths, *, event_sha=head_sha, current_sha=head_sha,
               labels=None, label=None, base_info=base, current_base=base,
               reviews=None, sender_login="maintainer"):
    current = pull_request(current_sha, labels, current_base)
    payload = event(action, event_sha, label, base_info, sender_login)
    return policy.is_authorized(
        "pull_request_target", payload, current, paths, reviews or [], repository
    )

assert authorized("opened", ["README.md"])
print("PASS CI policy fixture allows pull requests without control-file changes")

assert policy.is_control_path(".swift-format")
assert policy.is_control_path(".swift-format-tests")
assert policy.is_control_path(".xcode-version")
assert policy.is_control_path("scripts/tool-versions.env")
assert policy.is_control_path(".github/actions/ci/action.yml")
assert policy.is_control_path("scripts/check-new-rule.sh")
assert policy.is_control_path("scripts/build/embed-cli.sh")
assert policy.is_control_path("gradlew")
assert policy.is_control_path("gradle/wrapper/gradle-wrapper.jar")
assert policy.is_control_path("Guest/build.gradle.kts")
assert policy.is_control_path("Guest/settings.gradle.kts")
assert policy.is_control_path("Guest/gradle/libs.versions.toml")
assert policy.is_control_path("Guest/guestd/gradle.lockfile")
assert policy.is_control_path("Guest/buildSrc/src/main/kotlin/BuildConvention.kt")
assert policy.is_control_path("build-logic/src/main/kotlin/Rules.kt")
assert policy.is_control_path("Guest/vsockd/Cargo.toml")
assert policy.is_control_path("Guest/vsockd/Cargo.lock")
assert policy.is_control_path("Guest/vsockd/rust-toolchain.toml")
assert policy.is_control_path("Guest/vsockd/rustfmt.toml")
assert policy.is_control_path("Guest/vsockd/.rustfmt.toml")
assert policy.is_control_path("Guest/vsockd/clippy.toml")
assert policy.is_control_path("Guest/vsockd/.clippy.toml")
assert policy.is_control_path("Guest/vsockd/.cargo/config.toml")
assert policy.is_control_path("scripts/errorgen.swift")
assert policy.is_control_path("scripts/generate-protos.sh")
assert policy.is_control_path("Package.swift")
assert policy.is_control_path("Packages/RuntimeCore/Package.swift")
assert policy.is_control_path("Package.resolved")
assert policy.is_control_path("ThirdParty/ThirdParty.lock.json")
assert policy.is_control_path("Packages/RuntimeCore/Tests/RuntimeCoreTests/Test.swift")
assert policy.is_control_path("Apps/APKRun/UITests/SmokeTests.swift")
assert policy.is_control_path("project.yml")
assert policy.is_control_path("docs/01-architecture/modules.md")
print("PASS CI policy fixture protects generators, manifests, tests, and module policy")

assert not authorized(
    "opened",
    ["Package.resolved", "ThirdParty/ThirdParty.lock.json"],
)
print("PASS CI policy fixture gates paired Swift dependency pin changes")

assert not authorized("opened", ["scripts/build/embed-cli.sh"])
assert not authorized(
    "opened",
    ["gradlew", "Guest/build.gradle.kts", "Guest/gradle/libs.versions.toml"],
)
print("PASS CI policy fixture gates Xcode and Gradle build code")

assert not authorized("opened", [".github/workflows/ci.yml"])
print("PASS CI policy fixture blocks unreviewed CI control-file changes")

assert authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
print("PASS CI policy fixture accepts the current reviewer applying the label")

assert not authorized(
    "edited",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
print("PASS CI policy fixture requires label re-application after a pull request edit")

assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    sender_login="different-maintainer",
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    sender_login="contributor",
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer-bot", "type": "Bot"},
        }
    ],
)
assert not authorized(
    "unlabeled",
    [".github/workflows/ci.yml"],
    labels=[],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
print("PASS CI policy fixture binds label authority to its human approver and revokes on removal")

assert not authorized(
    "synchronize",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    event_sha="b" * 40,
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": "b" * 40,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "contributor", "type": "User"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "review-bot", "type": "Bot"},
        }
    ],
)
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        },
        {
            "state": "CHANGES_REQUESTED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        },
    ],
)
print("PASS CI policy fixture rejects missing, stale, self, and withdrawn approvals")

assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    base_info={"ref": "feature", "repo": {"full_name": repository}},
    current_base={"ref": "feature", "repo": {"full_name": repository}},
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
print("PASS CI policy fixture only trusts pull requests targeting main")

advanced_base = {"ref": "main", "sha": "c" * 40, "repo": {"full_name": repository}}
assert not authorized(
    "labeled",
    [".github/workflows/ci.yml"],
    labels=[policy.APPROVAL_LABEL],
    label=policy.APPROVAL_LABEL,
    base_info=base,
    current_base=advanced_base,
    reviews=[
        {
            "state": "APPROVED",
            "commit_id": head_sha,
            "user": {"login": "maintainer", "type": "User"},
        }
    ],
)
assert not policy.same_pull_request_revision(
    pull_request(),
    pull_request(base_info=advanced_base),
)
event_payload = {
    "number": 1,
    "pull_request": {
        "head": {"sha": head_sha},
        "base": base,
    },
}
final_pull_request = pull_request(
    labels=[policy.APPROVAL_LABEL],
    base_info=advanced_base,
)
with tempfile.TemporaryDirectory() as temporary_directory:
    event_path = pathlib.Path(temporary_directory) / "event.json"
    event_path.write_text(json.dumps(event_payload), encoding="utf-8")
    api_responses = [
        pull_request(labels=[policy.APPROVAL_LABEL]),
        {"files": [{"filename": ".github/workflows/ci.yml"}]},
        [
            {
                "state": "APPROVED",
                "commit_id": head_sha,
                "user": {"login": "maintainer", "type": "User"},
            }
        ],
        final_pull_request,
    ]
    with mock.patch.object(policy, "api_json", side_effect=api_responses):
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_TOKEN": "fixture-token",
                "GITHUB_REPOSITORY": repository,
                "GITHUB_EVENT_NAME": "pull_request_target",
            },
        ):
            assert policy.main() == 2
print("PASS CI policy fixture rejects base-ref changes and unstable API snapshots")

renamed = [
    {
        "filename": "docs/renamed-workflow.md",
        "previous_filename": ".github/workflows/ci.yml",
    }
]
with mock.patch.object(policy, "api_json", return_value={"files": renamed}):
    renamed_paths = policy.changed_files(repository, base["sha"], head_sha, "token")
assert ".github/workflows/ci.yml" in renamed_paths
assert policy.is_control_path(".github/workflows/ci.yml")
print("PASS CI policy fixture checks both sides of renamed files")

compare_limit = {
    "files": [{"filename": f"docs/file-{index}.md"} for index in range(300)]
}
with mock.patch.object(policy, "api_json", return_value=compare_limit):
    try:
        policy.changed_files(repository, base["sha"], head_sha, "token")
    except ValueError as error:
        assert "300" in str(error)
    else:
        raise SystemExit("FAIL CI policy fixture: accepted a capped compare response")
print("PASS CI policy fixture fails closed at the GitHub compare file limit")

compare_url = (
    f"https://api.github.com/repos/{repository}/compare/"
    f"{base['sha']}...{head_sha}?per_page=100&page=1"
)
assert policy.commit_compare_api_url(repository, base["sha"], head_sha) == compare_url
for invalid_sha in ("main", "a" * 39, "g" * 40):
    try:
        policy.commit_compare_api_url(repository, invalid_sha, head_sha)
    except ValueError:
        pass
    else:
        raise SystemExit("FAIL CI policy fixture: accepted a non-commit base SHA")

# Model a live PR moving A -> B -> A while the file list is requested. The
# compare URL must remain bound to A, so B's protected path cannot be mistaken
# for the files in the final A revision.
race_event = {
    "number": 1,
    "action": "opened",
    "pull_request": {"head": {"sha": head_sha}, "base": base},
    "sender": {"login": "contributor", "type": "User"},
}
transient_base = {
    "ref": "main",
    "sha": "d" * 40,
    "repo": {"full_name": repository},
}
race_pull_requests = iter(
    [
        pull_request(),
        pull_request(sha="c" * 40, base_info=transient_base),
        pull_request(),
    ]
)
race_urls = []

def race_api_json(url, token):
    race_urls.append(url)
    if url == compare_url:
        transient_revision = next(race_pull_requests)
        assert transient_revision["head"]["sha"] != head_sha
        assert transient_revision["base"]["sha"] != base["sha"]
        assert policy.is_control_path(".github/workflows/ci.yml")
        return {"files": [{"filename": "README.md"}]}
    return next(race_pull_requests)

with tempfile.TemporaryDirectory() as temporary_directory:
    event_path = pathlib.Path(temporary_directory) / "event.json"
    event_path.write_text(json.dumps(race_event), encoding="utf-8")
    with mock.patch.object(policy, "api_json", side_effect=race_api_json):
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_TOKEN": "fixture-token",
                "GITHUB_REPOSITORY": repository,
                "GITHUB_EVENT_NAME": "pull_request_target",
            },
        ):
            assert policy.main() == 0
assert race_urls == [
    f"https://api.github.com/repos/{repository}/pulls/1",
    compare_url,
    f"https://api.github.com/repos/{repository}/pulls/1",
]
assert all("/files?" not in url for url in race_urls)
print("PASS CI policy fixture pins changed paths to the captured commit pair")
PY

ruby - "$repo_root/.github/workflows/ci-policy.yml" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
trigger_key = workflow.key?("on") ? "on" : true
triggers = workflow.fetch(trigger_key)
target = triggers.fetch("pull_request_target")
job = workflow.fetch("jobs").fetch("workflow-policy")
steps = job.fetch("steps")
checkout = steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }

errors = []
errors << "policy must target pull requests to main only" unless target["branches"] == ["main"]
unless target["types"].sort == %w[opened reopened synchronize edited labeled unlabeled].sort
  errors << "policy must run on revision, label approval, and label revocation events"
end
errors << "policy token permissions must be read-only" unless
  workflow["permissions"] == { "contents" => "read", "pull-requests" => "read" }
errors << "policy job must run on GitHub-hosted Ubuntu" unless job["runs-on"] == "ubuntu-latest"
if job.key?("if") || job["continue-on-error"]
  errors << "policy job must not be conditional or ignore failures"
end
unless checkout && checkout["uses"].match?(/\Aactions\/checkout@[0-9a-f]{40}/)
  errors << "policy must pin checkout to an action commit"
end
inputs = checkout&.fetch("with", {})
unless inputs && inputs.keys.sort == %w[persist-credentials ref] &&
       inputs["ref"] == "refs/heads/main" && inputs["persist-credentials"] == false
  errors << "policy must check out trusted main code without persisted credentials"
end
unless steps.length == 2 &&
       steps[1]["run"] == "python3 scripts/ci/check-pr-control-changes.py" &&
       steps[1]["env"] == { "GITHUB_TOKEN" => "${{ github.token }}" }
  errors << "policy must run the base-branch control-file checker"
end
unless workflow.fetch("jobs").keys == ["workflow-policy"] && triggers.keys == ["pull_request_target"]
  errors << "policy must contain only the pull_request_target policy job"
end
unless workflow["concurrency"]&.fetch("cancel-in-progress") == true &&
       workflow["concurrency"]["group"].include?("pull_request.number")
  errors << "policy runs must serialize per pull request and cancel stale runs"
end
if workflow.to_s.include?("pull_request.head") || workflow.to_s.include?("self-hosted") ||
   workflow.to_s.include?("secrets.")
  errors << "policy must not check out PR code, use persistent runners, or reference secrets"
end
unless errors.empty?
  abort("FAIL CI policy workflow fixture:\n#{errors.map { |error| "  #{error}" }.join("\n")}")
end
puts("PASS CI policy workflow uses read-only metadata checks on trusted main code")
RUBY

python3 - "$repo_root/scripts/check-todos.sh" "$temporary_root/todos" <<'PY'
import pathlib
import subprocess
import sys

checker = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
root.mkdir()
subprocess.run(["git", "-C", str(root), "init", "--quiet"], check=True)

todo_marker = "TO" + "DO"
fixme_marker = "FIX" + "ME"
cases = (
    ("missing-number", f"// {todo_marker}: temporary\n", False),
    ("placeholder-number", f"// {todo_marker}(#NNN): temporary\n", False),
    ("malformed-fixme", f"// {fixme_marker}(x): temporary\n", False),
    ("numbered-marker", f"// {todo_marker}(#123): temporary\n", True),
)

for name, contents, should_pass in cases:
    source = root / "Sample.swift"
    source.write_text(contents)
    for relative in (
        "docs/example.py",
        "ThirdParty/patches/example/example.sh",
        "Images/tools/vendor/example.py",
    ):
        ignored = root / relative
        ignored.parent.mkdir(parents=True, exist_ok=True)
        ignored.write_text(f"# {todo_marker}: ignored\n")
    (root / "Untracked.swift").write_text(f"// {fixme_marker}(x)\n")
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run(["git", "-C", str(root), "reset", "--quiet", "Untracked.swift"], check=True)

    result = subprocess.run(
        [str(checker), "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    if (result.returncode == 0) != should_pass:
        raise SystemExit(
            f"FAIL marker fixture {name}: expected "
            f"{'pass' if should_pass else 'failure'}\n{result.stdout}{result.stderr}"
        )
    if not should_pass and "must be followed by an issue reference" not in result.stdout:
        raise SystemExit(f"FAIL marker fixture {name}: missing diagnostic\n{result.stdout}")
    print(f"PASS marker fixture {name}")
PY

python3 - "$repo_root" "$temporary_root/format" <<'PY'
import pathlib
import subprocess
import sys

repo_root = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
root.mkdir()
source = root / "FormattingFixture.swift"
command = [
    "xcrun",
    "swift-format",
    "lint",
    "--strict",
    "--configuration",
    str(repo_root / ".swift-format"),
    str(source),
]

source.write_text("let value=1\n")
bad = subprocess.run(command, capture_output=True, text=True, check=False)
if bad.returncode == 0:
    raise SystemExit("FAIL format fixture: badly formatted source passed")
print("PASS format fixture rejects bad source")

source.write_text("let value = 1\n")
good = subprocess.run(command, capture_output=True, text=True, check=False)
if good.returncode != 0:
    raise SystemExit(f"FAIL format fixture: valid source failed\n{good.stdout}{good.stderr}")
print("PASS format fixture accepts formatted source")
PY

python3 - "$repo_root" "$temporary_root/release" <<'PY'
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
fixture_root = repository / "scripts/tests/fixtures/release"
checker = repository / "scripts/release/check-release-build.sh"
source = fixture_root / "release-check.c"
public_key = (repository / "Tests/Fixtures/signing/test-release-check-ed25519.pub").read_text().strip()
avb_public_key = (repository / "Tests/Fixtures/signing/test-apkrun-image-fixture.avbpubkey").read_bytes()
avb_private_key = (repository / "Tests/Fixtures/signing/test-apkrun-image-fixture-rsa.pem").read_bytes()
key_id = hashlib.sha256(bytes.fromhex(public_key)).hexdigest()[:16]
runtime_libraries = (
    "libvirglrenderer.1.dylib",
    "libepoxy.0.dylib",
    "libEGL.dylib",
    "libGLESv2.dylib",
)
runtime_fixture = pathlib.Path(sys.argv[2]) / "virgl-runtime-fixture.dylib"
runtime_fixture.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(
    [
        "xcrun",
        "clang",
        "-dynamiclib",
        "-arch",
        "arm64",
        "-mmacosx-version-min=27.0",
        "-Wl,-install_name,@rpath/libvirglrenderer.1.dylib",
        str(source),
        "-o",
        str(runtime_fixture),
    ],
    check=True,
)

def populate_release_payload(app):
    contents = app / "Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(repository / "scripts/release/generate-notices.py"),
            "--output",
            str(resources / "ThirdPartyNotices.html"),
        ],
        check=True,
    )
    runtime_directory = contents / "Frameworks/VirGLRuntime"
    runtime_directory.mkdir(parents=True, exist_ok=True)
    for name in runtime_libraries:
        destination = runtime_directory / name
        shutil.copy2(runtime_fixture, destination)
        subprocess.run(
            ["install_name_tool", "-id", f"@rpath/{name}", str(destination)],
            check=True,
        )

cases = (
    ("clean", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", None, True, None),
    ("test-hook", "APKRUN_STORE_FAULT", "release", None, False, "APKRUN_STORE_FAULT"),
    ("test-key", public_key, "release", None, False, "test signing material"),
    ("test-key-id", key_id, "release", None, False, "test signing material"),
    ("test-key-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".pub", False, "test signing material"),
    ("test-key-der-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".der", False, "test signing material"),
    ("test-avb-public-key-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".avbpubkey", False, "test signing material"),
    ("test-avb-private-key-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".rsa.pem", False, "test signing material"),
    ("development-identity", "APKRUN_RELEASE_FIXTURE_CLEAN", "dev", None, False, "APKRunBuildIdentity"),
    ("release-update-identity", "APKRUN_RELEASE_FIXTURE_CLEAN", "updatetest", None, False, "updatetest"),
)

for name, marker, identity, resource_suffix, should_pass, expected in cases:
    app = pathlib.Path(sys.argv[2]) / f"{name}.app"
    contents = app / "Contents"
    binary = contents / "MacOS/release-check.o"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "io.apkrun.release-check-fixture",
                "APKRunBuildIdentity": identity,
            }
        )
    )
    if name == "clean":
        populate_release_payload(app)
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-arch",
            "arm64",
            "-c",
            str(source),
            f'-DRELEASE_CHECK_MARKER="{marker}"',
            "-o",
            str(binary),
        ],
        check=True,
    )
    if resource_suffix:
        resources = contents / "Resources"
        resources.mkdir()
        resource_bytes = {
            ".pub": public_key.encode("ascii"),
            ".der": bytes.fromhex(public_key),
            ".avbpubkey": avb_public_key,
            ".rsa.pem": avb_private_key,
        }[resource_suffix]
        (resources / f"test-key{resource_suffix}").write_bytes(resource_bytes)
    result = subprocess.run(
        [str(checker), str(app)],
        capture_output=True,
        text=True,
        check=False,
    )
    if should_pass:
        if result.returncode != 0:
            raise SystemExit(f"FAIL release fixture {name}: expected pass\n{result.stdout}{result.stderr}")
    else:
        if result.returncode == 0:
            raise SystemExit(f"FAIL release fixture {name}: expected failure")
        output = result.stdout + result.stderr
        if expected not in output:
            raise SystemExit(f"FAIL release fixture {name}: missing {expected!r}\n{output}")
    print(f"PASS release fixture {name}")

stale_runtime_app = pathlib.Path(sys.argv[2]) / "clean.app"
stale_runtime_directory = (
    stale_runtime_app / "Contents/Frameworks/VirGLRuntime"
)
(stale_runtime_directory / "stale.dylib").write_bytes(b"stale runtime")
stale_result = subprocess.run(
    [str(checker), str(stale_runtime_app)],
    capture_output=True,
    text=True,
    check=False,
)
stale_output = stale_result.stdout + stale_result.stderr
if stale_result.returncode == 0 or "unexpected VirGL runtime files" not in stale_output:
    raise SystemExit(
        "FAIL release fixture stale-runtime-file: expected rejection\n" + stale_output
    )
print("PASS release fixture stale-runtime-file")

for name, embedded_identity, should_pass in (
    ("embedded-release-identity", "release", True),
    ("embedded-missing-identity", None, False),
):
    app = pathlib.Path(sys.argv[2]) / f"{name}.app"
    contents = app / "Contents"
    binary = contents / "MacOS/apkrun"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "io.apkrun.release-check-fixture",
                "APKRunBuildIdentity": "release",
            }
        )
    )
    if should_pass:
        populate_release_payload(app)
    embedded_info = {}
    if embedded_identity is not None:
        embedded_info["APKRunBuildIdentity"] = embedded_identity
    embedded_plist = contents / "embedded-info.plist"
    embedded_plist.write_bytes(plistlib.dumps(embedded_info))
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-arch",
            "arm64",
            str(source),
            f"-Wl,-sectcreate,__TEXT,__info_plist,{embedded_plist}",
            "-o",
            str(binary),
        ],
        check=True,
    )
    section = subprocess.run(
        ["otool", "-s", "__TEXT", "__info_plist", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if section.returncode != 0 or "__info_plist" not in section.stdout:
        raise SystemExit(f"FAIL release fixture {name}: embedded plist section was not created")
    result = subprocess.run(
        [str(checker), str(app)],
        capture_output=True,
        text=True,
        check=False,
    )
    if should_pass:
        if result.returncode != 0:
            raise SystemExit(f"FAIL release fixture {name}: expected pass\n{result.stdout}{result.stderr}")
    else:
        output = result.stdout + result.stderr
        if result.returncode == 0 or "embedded Release APKRunBuildIdentity" not in output:
            raise SystemExit(f"FAIL release fixture {name}: expected missing embedded identity rejection\n{output}")
    print(f"PASS release fixture {name}")

unsupported_repo = pathlib.Path(sys.argv[2]).parent / "unsupported-signing-fixture-repo"
unsupported_checker = unsupported_repo / "scripts/release/check-release-build.sh"
unsupported_fixture = unsupported_repo / "Tests/Fixtures/signing/test-unsupported.jks"
unsupported_checker.parent.mkdir(parents=True)
unsupported_fixture.parent.mkdir(parents=True)
shutil.copy2(checker, unsupported_checker)
unsupported_notices = unsupported_repo / "scripts/release/generate-notices.py"
unsupported_notices.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(repository / "scripts/release/generate-notices.py", unsupported_notices)
unsupported_third_party = unsupported_repo / "ThirdParty"
unsupported_third_party.mkdir(parents=True)
shutil.copy2(
    repository / "ThirdParty/ThirdParty.lock.json",
    unsupported_third_party / "ThirdParty.lock.json",
)
shutil.copytree(
    repository / "ThirdParty/licenses",
    unsupported_third_party / "licenses",
)
unsupported_fixture.write_bytes(b"\xfe\xed\xfe\xedunsupported keystore fixture")
result = subprocess.run(
    [str(unsupported_checker), str(pathlib.Path(sys.argv[2]) / "clean.app")],
    capture_output=True,
    text=True,
    check=False,
)
output = result.stdout + result.stderr
if result.returncode == 0 or "unsupported binary or certificate signing fixture format" not in output:
    raise SystemExit(f"FAIL release fixture unsupported key store: expected fail-closed rejection\n{output}")
print("PASS release fixture unsupported key store fails closed")
PY

printf 'scripts/tests: passed\n'
