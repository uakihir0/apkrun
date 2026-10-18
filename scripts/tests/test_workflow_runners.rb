# Checks every GitHub workflow and composite action in the repository.
#
# - A workflow that a pull_request or pull_request_target event can start runs
#   every job on a GitHub-hosted label. A persistent self-hosted runner never
#   receives pull request code.
# - Every `uses:` reference names a full 40-character commit SHA, except local
#   actions under ./.
# - Every checkout disables persisted credentials.
#
# Negative fixtures mutate in-memory copies of real workflows and require each
# rule to reject the mutation, so a rule cannot pass by never running.
require "yaml"
require "json"
require "fileutils"
require "tmpdir"

HOSTED_LABELS = %w[xcode-27 ubuntu-latest].freeze
PULL_REQUEST_EVENTS = %w[pull_request pull_request_target].freeze
PINNED_USE = /@[0-9a-f]{40}\z/

def load_yaml(path)
  YAML.load_file(path)
end

def triggers_of(document)
  document.key?("on") ? document["on"] : document[true]
end

def pull_request_triggered?(document)
  triggers = triggers_of(document)
  names = triggers.is_a?(Hash) ? triggers.keys : Array(triggers)
  names.any? { |name| PULL_REQUEST_EVENTS.include?(name.to_s) }
end

def each_uses(document)
  if document.key?("runs")
    Array(document.dig("runs", "steps")).each do |step|
      yield step["uses"] if step["uses"]
    end
    return
  end
  document.fetch("jobs", {}).each_value do |job|
    yield job["uses"] if job["uses"]
    Array(job["steps"]).each do |step|
      yield step["uses"] if step["uses"]
    end
  end
end

def workflow_errors(name, document)
  errors = []
  if pull_request_triggered?(document)
    document.fetch("jobs", {}).each do |job_name, job|
      runs_on = job["runs-on"]
      labels = runs_on.is_a?(Array) ? runs_on : [runs_on]
      unless labels.all? { |label| HOSTED_LABELS.include?(label.to_s) }
        errors << "#{name}: job #{job_name} runs on #{runs_on.inspect}; " \
          "pull request workflows must use only #{HOSTED_LABELS.join(" or ")}"
      end
    end
  end
  each_uses(document) do |uses|
    next if uses.start_with?("./")
    next if uses.match?(PINNED_USE)
    errors << "#{name}: #{uses} is not pinned to a full commit SHA"
  end
  document.fetch("jobs", {}).each do |job_name, job|
    Array(job["steps"]).each do |step|
      next unless step["uses"].to_s.start_with?("actions/checkout@")
      next if step.dig("with", "persist-credentials") == false
      errors << "#{name}: job #{job_name} checkout must set persist-credentials: false"
    end
  end
  errors
end

def enables_lab_gui_input_test?(workflow)
  values = []
  collect_yaml_values(workflow, values)
  values.any? do |value|
    value = value.to_s
    value.include?("APKRUN_INPUT_INTERACTIVE_T2") ||
      value.include?("AndroidInputInteractive") ||
      value.include?("APKRUN_INPUT_CADENCE_T2") ||
      value.include?("AndroidInputCadence") ||
      value.include?("APKRUN_INPUT_EDGE_T2") ||
      value.include?("AndroidInputEdges")
  end
end

def collect_yaml_values(value, values)
  case value
  when Hash
    value.each do |key, child|
      values << key
      collect_yaml_values(child, values)
    end
  when Array
    value.each { |child| collect_yaml_values(child, values) }
  else
    values << value
  end
end

def workflow_paths(root)
  Dir.glob(File.join(root, ".github/workflows/*.{yml,yaml}")).sort
end

def action_paths(root)
  Dir.glob(File.join(root, ".github/actions/**/action.{yml,yaml}")).sort
end

def collect_local_action_references(value, references)
  case value
  when Hash
    value.each do |key, child|
      references << child if key == "uses" && child.is_a?(String) && child.start_with?("./")
      collect_local_action_references(child, references)
    end
  when Array
    value.each { |child| collect_local_action_references(child, references) }
  end
end

def referenced_local_action_paths(root, workflow_documents)
  root_path = File.realpath(root)
  queue = []
  workflow_documents.each { |_name, document| collect_local_action_references(document, queue) }
  paths = []
  errors = []
  inspected = {}
  until queue.empty?
    reference = queue.shift
    action_directory = File.expand_path(reference, root_path)
    unless action_directory.start_with?("#{root_path}/")
      errors << "local action #{reference} resolves outside the repository"
      next
    end
    if reference.match?(%r{\A\./\.github/workflows/[^/]+\.ya?ml\z})
      unless File.file?(action_directory)
        errors << "local reusable workflow #{reference} does not exist"
      end
      next
    end
    manifest = %w[action.yml action.yaml].map { |name| File.join(action_directory, name) }.find do |path|
      File.file?(path)
    end
    if manifest
      manifest = File.realpath(manifest)
      unless manifest.start_with?("#{root_path}/")
        errors << "local action manifest #{reference} resolves outside the repository"
        next
      end
      next if inspected[manifest]

      inspected[manifest] = true
      paths << manifest
      collect_local_action_references(load_yaml(manifest), queue)
    else
      errors << "local action #{reference} has no action.yml or action.yaml"
    end
  end
  [paths.uniq.sort, errors]
end

def copy(document)
  Marshal.load(Marshal.dump(document))
end

root = ARGV.fetch(0)
workflow_files = workflow_paths(root)
action_files = action_paths(root)
abort("FAIL workflow pins: no workflows found under #{root}") if workflow_files.empty?

workflow_documents = workflow_files.map { |path| [File.basename(path), load_yaml(path)] }
local_action_files, local_action_errors = referenced_local_action_paths(root, workflow_documents)
unless local_action_errors.empty?
  abort("FAIL local actions:\n#{local_action_errors.map { |error| "  #{error}" }.join("\n")}")
end
action_documents = (action_files + local_action_files).uniq.sort.map do |path|
  [path.delete_prefix("#{root}/"), load_yaml(path)]
end
documents = workflow_documents + action_documents
errors = documents.flat_map { |name, document| workflow_errors(name, document) }
unless errors.empty?
  abort("FAIL workflow runners and pins:\n#{errors.map { |error| "  #{error}" }.join("\n")}")
end
puts("PASS workflow runners and pins: #{documents.length} files use hosted runners for pull requests and pinned actions")

ci = documents.to_h.fetch("ci.yml")
policy = documents.to_h.fetch("ci-policy.yml")
integration = documents.to_h.fetch("integration.yml")

ci_steps = ci.fetch("jobs").flat_map do |job_name, job|
  Array(job["steps"]).map { |step| [job_name, step] }
end
test_steps = ci_steps.select do |_job_name, step|
  step.fetch("run", "").match?(/\b(?:swift\s+test|pytest|xcodebuild\s+test|gradle(?:w)?\s+.*\btest\w*)\b/)
end
expected_test_steps = [
  "test-swift/Run Swift T0 tests",
  "test-graphics/Run Metal and VirGL T1 tests",
  "test-graphics/Run Metal and VirGL T1 tests with Address Sanitizer",
  "test-graphics/Run Metal and VirGL T1 tests with Undefined Behavior Sanitizer",
  "test-images/Run image tooling tests"
]
actual_test_steps = test_steps.map { |job_name, step| "#{job_name}/#{step["name"]}" }
unless actual_test_steps.sort == expected_test_steps.sort
  abort("FAIL workflow tests: test command inventory changed: #{actual_test_steps.inspect}")
end
if test_steps.any? { |_job_name, step| step.key?("if") }
  abort("FAIL workflow tests: CI test commands must run for every required workflow event")
end

check_step = ci_steps.find { |job_name, step| job_name == "lint" && step["name"] == "Run repository checks" }&.last
unless check_step && !check_step.key?("if") && !check_step.key?("env")
  abort("FAIL workflow tests: repository checks must always run without test-suppression flags")
end
puts("PASS CI test commands and repository checks remain enabled")

manual_test_workflows = {
  "integration.yml" => { "linux-guest" => /\bxcodebuild\s+test\b/ },
  "nightly.yml" => {
    "gates" => %r{scripts/run-gate\.sh\s+G1},
    "network" => /\bxcodebuild\s+test\b/
  }
}
manual_test_workflows.each do |workflow_name, expected_jobs|
  workflow = documents.to_h.fetch(workflow_name)
  workflow_triggers = triggers_of(workflow)
  dispatch_inputs = workflow_triggers.fetch("workflow_dispatch", {}).to_h.fetch("inputs", {})
  unless workflow_triggers.keys == ["workflow_dispatch"] && !dispatch_inputs.key?("enable_test_runs")
    abort("FAIL workflow tests: #{workflow_name} must retain its existing manual-dispatch contract")
  end
  jobs = workflow.fetch("jobs")
  jobs.each do |job_name, job|
    if job.fetch("steps", []).any? { |step| step["id"] == "test-deferral" }
      abort("FAIL workflow tests: #{workflow_name}/#{job_name} must not suppress unrelated test suites")
    end
  end
  actual_test_jobs = jobs.filter_map do |job_name, job|
    commands = Array(job["steps"]).map { |step| step.fetch("run", "") }
    job_name if commands.any? { |command| command.match?(/\bxcodebuild\s+test\b|scripts\/run-gate\.sh\s+G1/) }
  end
  unless actual_test_jobs.sort == expected_jobs.keys.sort
    abort("FAIL workflow tests: #{workflow_name} test command inventory changed: #{actual_test_jobs.inspect}")
  end
  expected_jobs.each do |job_name, command_pattern|
    job = jobs.fetch(job_name)
    unless job["if"] == "github.ref == 'refs/heads/main'"
      abort("FAIL workflow tests: #{workflow_name}/#{job_name} must retain its main-only manual gate")
    end
    test_steps = Array(job["steps"]).select { |step| step.fetch("run", "").match?(command_pattern) }
    unless test_steps.any? && test_steps.all? { |step| !step.key?("if") }
      abort("FAIL workflow tests: #{workflow_name}/#{job_name} must run its expected test command unconditionally")
    end
  end
end
puts("PASS manual integration and nightly workflows retain their original test behavior")

test_plan = JSON.parse(File.read(File.join(root, "Tests/IntegrationTests/IntegrationTests.xctestplan")))
input_configs = {
  "AndroidInputCadence" => {
    "APKRUN_INPUT_CADENCE_T2" => "1",
    "ANDROID_ADB_SERVER_PORT" => "15044"
  },
  "AndroidInputEdges" => {
    "APKRUN_INPUT_EDGE_T2" => "1",
    "ANDROID_ADB_SERVER_PORT" => "15043"
  },
  "AndroidInputInteractive" => {
    "APKRUN_INPUT_INTERACTIVE_T2" => "1",
    "ANDROID_ADB_SERVER_PORT" => "15041"
  }
}
required_input_config_values = {
  "APKRUN_INTEGRATION_SUITE" => "android-input",
  "APKRUN_INPUT_T2" => "1",
  "APKRUN_VIRGL_RUNTIME_PATH" => "/tmp/apkrun-test-linux/virgl-runtime",
  "APKRUN_GUEST_DIR" => "/tmp/apkrun-test-guest",
  "APKRUN_FIXTURE_APK" => "/tmp/apkrun-test-fixtures/HelloText.apk"
}
configurations = test_plan.fetch("configurations").to_h do |configuration|
  entries = configuration.fetch("options", {}).fetch("environmentVariableEntries", [])
  [configuration.fetch("name"), entries]
end
android_input_ports = configurations.filter_map do |_name, entries|
  values = entries.select { |entry| entry["enabled"] == true }
    .to_h { |entry| [entry["key"], entry["value"]] }
  ["#{values["ANDROID_ADB_SERVER_PORT"]}"] if values["APKRUN_INTEGRATION_SUITE"] == "android-input"
end
if android_input_ports.empty? ||
    android_input_ports.any?(&:empty?) ||
    android_input_ports.uniq.length != android_input_ports.length
  abort("FAIL workflow input-test guard: Android input configurations must use unique ADB server ports")
end
opt_in_keys = input_configs.values.flat_map(&:keys).grep(/APKRUN_INPUT_/)
enabled_opt_ins = configurations.flat_map do |name, entries|
  entries.select { |entry| entry["enabled"] == true && opt_in_keys.include?(entry["key"]) }
    .map { |entry| [name, entry["key"], entry["value"]] }
end
expected_opt_ins = [
  ["AndroidInputCadence", "APKRUN_INPUT_CADENCE_T2", "1"],
  ["AndroidInputEdges", "APKRUN_INPUT_EDGE_T2", "1"],
  ["AndroidInputInteractive", "APKRUN_INPUT_INTERACTIVE_T2", "1"]
]
unless enabled_opt_ins.sort == expected_opt_ins.sort
  abort("FAIL workflow input-test guard: only the intended GUI configurations may enable exact opt-in values")
end

input_configs.each do |configuration_name, exact_values|
  entries = configurations.fetch(configuration_name, nil)
  abort("FAIL workflow input-test guard: missing #{configuration_name} configuration") unless entries

  enabled_values = entries.select { |entry| entry["enabled"] == true }
    .to_h { |entry| [entry["key"], entry["value"]] }
  expected_values = required_input_config_values.merge(exact_values)
  unless expected_values.all? { |key, value| enabled_values[key] == value }
    abort("FAIL workflow input-test guard: #{configuration_name} is missing required environment values")
  end
  if entries.map { |entry| entry["key"] }.uniq.length != entries.length
    abort("FAIL workflow input-test guard: #{configuration_name} has duplicate environment keys")
  end
end
android_input_test_source = File.read(File.join(root, "Tests/IntegrationTests/AndroidInputTests/AndroidInputTests.swift"))
unless android_input_test_source.include?('environment["APKRUN_INPUT_INTERACTIVE_T2"] == "1"') &&
    android_input_test_source.include?('environment["APKRUN_INPUT_CADENCE_T2"] == "1"') &&
    android_input_test_source.include?('environment["APKRUN_INPUT_EDGE_T2"] == "1"') &&
    android_input_test_source.include?("testThreeConsecutiveHundredClickBatchesThroughDirectView") &&
    android_input_test_source.include?("runThreeConsecutiveHundredClickBatches(pointerDelivery: .directView)") &&
    android_input_test_source.include?('throw XCTSkip("Run only on a dedicated lab GUI session')
  abort("FAIL workflow input-test guard: desktop input tests must remain opt-in")
end
if documents.any? { |_name, workflow| enables_lab_gui_input_test?(workflow) }
  abort("FAIL workflow input-test guard: a GitHub workflow enables a dedicated GUI test")
end
puts("PASS GitHub workflows do not enable opt-in AndroidInput GUI tests")
root_env_fixture = copy(ci)
root_env_fixture["env"] = root_env_fixture.fetch("env", {}).merge("APKRUN_INPUT_INTERACTIVE_T2" => "1")
unless enables_lab_gui_input_test?(root_env_fixture)
  abort("FAIL workflow input-test guard fixture: a workflow-level opt-in was not detected")
end
edge_env_fixture = {
  "jobs" => {
    "test" => {
      "steps" => [{ "env" => { "APKRUN_INPUT_EDGE_T2" => "1" } }]
    }
  }
}
unless enables_lab_gui_input_test?(edge_env_fixture)
  abort("FAIL workflow input-test guard fixture: an edge environment opt-in was not detected")
end
edge_yaml_fixture = {
  "runs" => {
    "steps" => [{ "run" => "xcodebuild test -only-test-configuration AndroidInputEdges" }]
  }
}
unless enables_lab_gui_input_test?(edge_yaml_fixture)
  abort("FAIL workflow input-test guard fixture: an edge action command was not detected")
end
cadence_env_fixture = {
  "jobs" => {
    "test" => {
      "steps" => [{ "env" => { "APKRUN_INPUT_CADENCE_T2" => "1" } }]
    }
  }
}
unless enables_lab_gui_input_test?(cadence_env_fixture)
  abort("FAIL workflow input-test guard fixture: a cadence environment opt-in was not detected")
end
cadence_yaml_fixture = {
  "runs" => {
    "steps" => [{ "run" => "xcodebuild test -only-test-configuration AndroidInputCadence" }]
  }
}
unless enables_lab_gui_input_test?(cadence_yaml_fixture)
  abort("FAIL workflow input-test guard fixture: a cadence action command was not detected")
end
puts("PASS workflow input-test guard rejects GUI configuration, environment, and local-action opt-in fixtures")

Dir.mktmpdir("apkrun-workflow-policy") do |fixture_root|
  workflow_directory = File.join(fixture_root, ".github/workflows")
  action_directory = File.join(fixture_root, ".github/actions/inside")
  external_action_directory = File.join(fixture_root, "tools/desktop-input")
  nested_action_directory = File.join(fixture_root, "tools/desktop-child")
  reusable_workflow_path = File.join(workflow_directory, "reuse.yaml")
  FileUtils.mkdir_p([workflow_directory, action_directory, external_action_directory, nested_action_directory])
  File.write(File.join(workflow_directory, "fixture.yaml"), YAML.dump({
    "jobs" => {
      "check" => { "steps" => [{ "uses" => "./tools/desktop-input" }] },
      "reuse" => { "uses" => "./.github/workflows/reuse.yaml" }
    }
  }))
  File.write(reusable_workflow_path, YAML.dump({ "jobs" => { "test" => { "runs-on" => "ubuntu-latest" } } }))
  File.write(File.join(action_directory, "action.yaml"), YAML.dump({ "runs" => { "using" => "composite", "steps" => [] } }))
  File.write(File.join(external_action_directory, "action.yaml"), YAML.dump({
    "runs" => {
      "using" => "composite",
      "steps" => [{ "uses" => "./tools/desktop-child" }]
    }
  }))
  File.write(File.join(nested_action_directory, "action.yml"), YAML.dump({
    "runs" => {
      "using" => "composite",
      "steps" => [{ "env" => { "APKRUN_INPUT_EDGE_T2" => "1" } }]
    }
  }))

  fixture_workflows = workflow_paths(fixture_root)
  fixture_workflow_documents = fixture_workflows.map { |path| [File.basename(path), load_yaml(path)] }
  fixture_actions, fixture_errors = referenced_local_action_paths(fixture_root, fixture_workflow_documents)
  fixture_documents = action_paths(fixture_root).map { |path| [path, load_yaml(path)] } +
    fixture_actions.map { |path| [path, load_yaml(path)] }
  unless fixture_workflows.length == 2 &&
      fixture_workflows.any? { |path| path.end_with?("fixture.yaml") } &&
      fixture_workflows.any? { |path| path.end_with?("reuse.yaml") } &&
      fixture_documents.length == 3 &&
      fixture_errors.empty? &&
      fixture_documents.any? { |_path, document| enables_lab_gui_input_test?(document) }
    abort("FAIL workflow input-test discovery fixture: .yaml workflow or action opt-in was not discovered")
  end
end
puts("PASS workflow input-test discovery fixture scans .yaml workflows and nested local actions")

def expect_rejected(name, pattern, document)
  errors = workflow_errors("fixture.yml", document)
  return if errors.any? { |error| error.match?(pattern) }

  abort("FAIL workflow runner fixture #{name}: expected a rejection matching #{pattern}, got #{errors.inspect}")
end

# Required jobs must run for every pull request and every push to main. A path
# filter or an if: condition would leave a required check pending or skipped.
def required_job_errors(document)
  errors = []
  triggers = triggers_of(document)
  unless triggers.key?("pull_request") && [nil, {}].include?(triggers["pull_request"])
    errors << "pull_request must not filter by branch or path"
  end
  unless triggers["push"] == { "branches" => ["main"] }
    errors << "push must run only for main without path filters"
  end
  %w[lint codegen build test-swift].each do |job_name|
    job = document.fetch("jobs").fetch(job_name)
    errors << "#{job_name} must run unconditionally" if job.key?("if") || job.key?("paths")
  end
  errors
end

required_errors = required_job_errors(ci)
unless required_errors.empty?
  abort("FAIL workflow required jobs:\n#{required_errors.map { |error| "  #{error}" }.join("\n")}")
end
puts("PASS workflow required jobs run for every pull request and push to main")

mutated = copy(ci)
mutated["jobs"]["build"]["if"] = "github.event_name == 'push'"
unless required_job_errors(mutated).any? { |error| error.include?("build must run unconditionally") }
  abort("FAIL workflow required jobs fixture: accepted a conditional required job")
end
puts("PASS workflow required jobs fixture rejects a conditional required job")

mutated = copy(ci)
mutated["on"] = mutated.fetch("on", {}).merge("pull_request" => { "branches" => ["release"] })
mutated.delete(true)
unless required_job_errors(mutated).any? { |error| error.include?("pull_request must not filter") }
  abort("FAIL workflow required jobs fixture: accepted a branch-filtered pull request trigger")
end
puts("PASS workflow required jobs fixture rejects a filtered pull request trigger")

mutated = copy(ci)
mutated["jobs"]["lint"]["runs-on"] = ["self-hosted", "apkrun-ci"]
expect_rejected("self-hosted lint job", /lint.*self-hosted/, mutated)
puts("PASS workflow runner fixture rejects a persistent self-hosted runner in ci.yml")

mutated = copy(policy)
mutated["jobs"]["workflow-policy"]["runs-on"] = "self-hosted"
expect_rejected("self-hosted policy job", /workflow-policy.*self-hosted/, mutated)
puts("PASS workflow runner fixture rejects a self-hosted policy job")

# integration.yml runs only on manual dispatch today. If a later task
# enables pull requests for it, the lab runner must be rejected.
mutated = copy(integration)
mutated["on"] = { "pull_request" => {} }
expect_rejected("lab runner on pull requests", /linux-guest.*self-hosted/, mutated)
puts("PASS workflow runner fixture rejects a lab runner once pull requests can start it")

mutated = copy(ci)
mutated["jobs"]["test-swift"]["steps"].each do |step|
  step["uses"] = "actions/cache@v4" if step["uses"].to_s.start_with?("actions/cache@")
end
expect_rejected("tag-pinned action", /actions\/cache@v4 is not pinned/, mutated)
puts("PASS workflow pin fixture rejects an action pinned by tag")

mutated = copy(ci)
mutated["jobs"]["codegen"]["steps"].each do |step|
  step["with"] = step["with"].merge("persist-credentials" => true) if step["with"]
end
expect_rejected("persisted checkout credentials", /codegen checkout must set persist-credentials/, mutated)
puts("PASS workflow checkout fixture rejects persisted credentials")
