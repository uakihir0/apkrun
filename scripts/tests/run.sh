#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fixture_root="$script_dir/fixtures/lock/base"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

checker="$repo_root/scripts/check-lock.sh"
module_checker="$repo_root/scripts/check-module-deps.sh"

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
    if ! rg -q "$expected" "$output"; then
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
    if ! rg -q "$expected" "$output"; then
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
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
lock_path = root / "ThirdParty/ThirdParty.lock.json"
lock = json.loads(lock_path.read_text())
component = lock["components"][0]

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
elif mode == "missing-patch":
    component["patches"] = ["swift-argument-parser/0001-missing.patch"]
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
else:
    raise SystemExit(f"unknown mutation: {mode}")

lock_path.write_text(json.dumps(lock, indent=2) + "\n")
PY
}

expect_pass "valid lock" "$fixture_root"
expect_pass "repository lock" "$repo_root"

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
key_id = hashlib.sha256(bytes.fromhex(public_key)).hexdigest()[:16]
cases = (
    ("clean", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", None, True, None),
    ("test-hook", "APKRUN_STORE_FAULT", "release", None, False, "APKRUN_STORE_FAULT"),
    ("test-key", public_key, "release", None, False, "test signing material"),
    ("test-key-id", key_id, "release", None, False, "test signing material"),
    ("test-key-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".pub", False, "test signing material"),
    ("test-key-der-resource", "APKRUN_RELEASE_FIXTURE_CLEAN", "release", ".der", False, "test signing material"),
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
        resource_bytes = (
            public_key.encode("ascii")
            if resource_suffix == ".pub"
            else bytes.fromhex(public_key)
        )
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

unsupported_repo = pathlib.Path(sys.argv[2]).parent / "unsupported-signing-fixture-repo"
unsupported_checker = unsupported_repo / "scripts/release/check-release-build.sh"
unsupported_fixture = unsupported_repo / "Tests/Fixtures/signing/test-unsupported.jks"
unsupported_checker.parent.mkdir(parents=True)
unsupported_fixture.parent.mkdir(parents=True)
shutil.copy2(checker, unsupported_checker)
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
