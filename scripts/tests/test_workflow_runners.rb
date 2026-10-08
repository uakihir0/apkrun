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

def expect_rejected(name, pattern, document)
  errors = workflow_errors("fixture.yml", document)
  return if errors.any? { |error| error.match?(pattern) }

  abort("FAIL workflow runner fixture #{name}: expected a rejection matching #{pattern}, got #{errors.inspect}")
end

mutated = copy(ci)
mutated["jobs"]["lint"]["runs-on"] = ["self-hosted", "apkrun-ci"]
expect_rejected("self-hosted lint job", /lint.*self-hosted/, mutated)
puts("PASS workflow runner fixture rejects a persistent self-hosted runner in ci.yml")

mutated = copy(policy)
mutated["jobs"]["workflow-policy"]["runs-on"] = "self-hosted"
expect_rejected("self-hosted policy job", /workflow-policy.*self-hosted/, mutated)
puts("PASS workflow runner fixture rejects a self-hosted policy job")

# integration.yml runs only on push and manual dispatch today. If a later task
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
