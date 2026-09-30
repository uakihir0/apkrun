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
  expected_jobs = %w[lint codegen build test-swift test-images]
  unless workflow.fetch("jobs").keys.sort == expected_jobs.sort
    errors << "CI jobs must match the M0 and M1 required job set"
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
