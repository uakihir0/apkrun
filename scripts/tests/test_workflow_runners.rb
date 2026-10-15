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
require "open3"
require "tempfile"

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

def copy(document)
  Marshal.load(Marshal.dump(document))
end

root = ARGV.fetch(0)
workflow_paths = Dir.glob(File.join(root, ".github/workflows/*.yml")).sort
action_paths = Dir.glob(File.join(root, ".github/actions/**/action.{yml,yaml}")).sort
abort("FAIL workflow pins: no workflows found under #{root}") if workflow_paths.empty?

documents = workflow_paths.map { |path| [File.basename(path), load_yaml(path)] }
documents += action_paths.map { |path| [path.delete_prefix("#{root}/"), load_yaml(path)] }
errors = documents.flat_map { |name, document| workflow_errors(name, document) }
unless errors.empty?
  abort("FAIL workflow runners and pins:\n#{errors.map { |error| "  #{error}" }.join("\n")}")
end
puts("PASS workflow runners and pins: #{documents.length} files use hosted runners for pull requests and pinned actions")

ci = documents.to_h.fetch("ci.yml")
policy = documents.to_h.fetch("ci-policy.yml")
integration = documents.to_h.fetch("integration.yml")

expected_deferral_context = {
  "APKRUN_PULL_REQUEST_HEAD_REF" => "${{ github.event.pull_request.head.ref }}",
  "APKRUN_PULL_REQUEST_HEAD_REPO" => "${{ github.event.pull_request.head.repo.full_name }}"
}
unless ci.fetch("env", {}).slice(*expected_deferral_context.keys) == expected_deferral_context
  abort("FAIL workflow test deferral: missing pull request ref/repository context")
end
if ci.fetch("env", {}).key?("APKRUN_SKIP_CI_TESTS")
  abort("FAIL workflow test deferral: do not evaluate the case-sensitive ref in a GitHub expression")
end

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
  abort("FAIL workflow test deferral: test command inventory changed: #{actual_test_steps.inspect}")
end
unless test_steps.all? { |_job_name, step| step["if"] == "steps.test-deferral.outputs.skip != 'true'" }
  abort("FAIL workflow test deferral: a CI test step is not guarded by the resolved scope")
end

%w[lint test-swift test-graphics test-images].each do |job_name|
  job_steps = Array(ci.fetch("jobs").fetch(job_name)["steps"])
  resolver = job_steps.index { |step| step["id"] == "test-deferral" && step["run"] == "scripts/ci/resolve-test-deferral.sh" }
  first_test = test_steps.select { |candidate_job, _step| candidate_job == job_name }.map { |_candidate_job, step| job_steps.index(step) }.min
  if resolver.nil? || (first_test && resolver >= first_test)
    abort("FAIL workflow test deferral: #{job_name} does not resolve scope before its tests")
  end
end

check_step = ci_steps.find { |job_name, step| job_name == "lint" && step["name"] == "Run repository checks" }&.last
unless check_step&.dig("env", "APKRUN_SKIP_CI_TESTS") == "${{ steps.test-deferral.outputs.skip }}"
  abort("FAIL workflow test deferral: repository checks do not receive the resolved scope")
end

def resolve_test_deferral(script, event_name:, head_ref:, head_repo:, repository:)
  Tempfile.create("apkrun-test-deferral") do |output|
    environment = {
      "GITHUB_OUTPUT" => output.path,
      "GITHUB_EVENT_NAME" => event_name,
      "GITHUB_REPOSITORY" => repository,
      "APKRUN_PULL_REQUEST_HEAD_REF" => head_ref,
      "APKRUN_PULL_REQUEST_HEAD_REPO" => head_repo
    }
    _stdout, status = Open3.capture2e(environment, script)
    abort("FAIL workflow test deferral: resolver exited with #{status.exitstatus}") unless status.success?

    File.read(output.path).strip
  end
end

resolver = File.join(root, "scripts/ci/resolve-test-deferral.sh")
unless File.executable?(resolver)
  abort("FAIL workflow test deferral: resolver is not executable")
end
scenarios = {
  "same-repository task PR" => ["pull_request", "task/103-click-loss", "uakihir0/apkrun", "uakihir0/apkrun", "skip=true"],
  "case-variant branch" => ["pull_request", "Task/103-click-loss", "uakihir0/apkrun", "uakihir0/apkrun", "skip=false"],
  "fork PR" => ["pull_request", "task/103-click-loss", "contributor/apkrun", "uakihir0/apkrun", "skip=false"],
  "main push" => ["push", "task/103-click-loss", "uakihir0/apkrun", "uakihir0/apkrun", "skip=false"]
}
scenarios.each do |name, (event_name, head_ref, head_repo, repository, expected)|
  actual = resolve_test_deferral(
    resolver,
    event_name: event_name,
    head_ref: head_ref,
    head_repo: head_repo,
    repository: repository
  )
  abort("FAIL workflow test deferral #{name}: expected #{expected}, got #{actual}") unless actual == expected
end
puts("PASS workflow test deferral is exact to the same-repository #103 pull request")

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
