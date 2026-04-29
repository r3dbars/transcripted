#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "time"
require "yaml"

class AgentTodoRunner
  LABELS = {
    "agent todo" => ["5319e7", "Ready for the local Codex issue runner"],
    "agent in progress" => ["f9d0c4", "Claimed by the local Codex issue runner"],
    "agent review" => ["0e8a16", "Codex opened a PR for human review"],
    "agent blocked" => ["d93f0b", "Codex needs human input before continuing"],
    "agent done" => ["cfd3d7", "Agent task is complete"]
  }.freeze

  def initialize(options)
    @repo_root = File.expand_path("../..", __dir__)
    @workflow_path = File.expand_path(options[:workflow] || File.join(@repo_root, "WORKFLOW.md"))
    @dry_run = options[:dry_run]
    @watch = options[:watch]
    @issue_number = options[:issue]
    @ensure_labels_requested = options[:ensure_labels]
    @labels_only = options[:labels_only]

    @config, @template = load_workflow(@workflow_path)
    @tracker = @config.fetch("tracker", {})
    @workspace_config = @config.fetch("workspace", {})
    @agent_config = @config.fetch("agent", {})
    @codex_config = @config.fetch("codex", {})
    @polling_config = @config.fetch("polling", {})
  end

  def run
    validate!
    ensure_labels if @ensure_labels_requested
    return if @labels_only

    loop do
      count = run_once
      break unless @watch

      puts "No matching issues." if count.zero?
      puts "Sleeping #{poll_interval_seconds}s..."
      sleep poll_interval_seconds
    end
  end

  private

  def load_workflow(path)
    body = File.read(path)
    unless body.start_with?("---\n")
      return [{}, body.strip]
    end

    _, yaml, prompt = body.split(/^---\s*$/, 3)
    raise "Could not parse YAML front matter in #{path}" if yaml.nil? || prompt.nil?

    [YAML.safe_load(yaml) || {}, prompt.strip]
  end

  def validate!
    raise "WORKFLOW.md must set tracker.kind: github" unless @tracker["kind"] == "github"
    raise "WORKFLOW.md must set tracker.repo" if repo.empty?
    raise "WORKFLOW.md must set workspace.root" if workspace_root.empty?
    raise "WORKFLOW.md has an empty Codex prompt body" if @template.empty?

    assert_command!("gh")
    assert_command!("git")
    assert_command!("codex")
  end

  def assert_command!(command)
    _, _, status = Open3.capture3("which", command)
    raise "Missing required command: #{command}" unless status.success?
  end

  def run_once
    issues = @issue_number ? [fetch_issue(@issue_number)] : fetch_candidates
    issues = issues.first(max_concurrent_agents)

    issues.each do |issue|
      with_issue_lock(issue) do
        handle_issue(issue)
      end
    end

    issues.length
  end

  def fetch_candidates
    issues = capture_json(
      "gh", "issue", "list",
      "--repo", repo,
      "--state", "open",
      "--limit", "100",
      "--json", "number,title,body,labels,url,assignees,createdAt,updatedAt"
    )

    issues.select { |issue| active_issue?(issue) }
  end

  def fetch_issue(number)
    capture_json(
      "gh", "issue", "view", number.to_s,
      "--repo", repo,
      "--json", "number,title,body,labels,url,assignees,createdAt,updatedAt"
    )
  end

  def active_issue?(issue)
    labels = label_names(issue)
    (labels & active_labels).any? && (labels & terminal_labels).empty?
  end

  def handle_issue(issue)
    number = issue.fetch("number")
    workspace = workspace_path(number)

    puts "Claiming #{repo}##{number}: #{issue.fetch("title")}"
    claim_issue(issue)
    prepare_workspace(number, workspace)
    ensure_workpad(issue, workspace)
    run_codex(issue, workspace)
  rescue StandardError => error
    warn "Issue ##{number || "?"} failed: #{error.message}"
    mark_blocked(number, error.message) if number
  end

  def claim_issue(issue)
    labels = label_names(issue)
    additions = []
    removals = []
    additions << in_progress_label unless labels.include?(in_progress_label)
    removals << todo_label if labels.include?(todo_label)
    edit_labels(issue.fetch("number"), additions, removals)
  end

  def prepare_workspace(number, path)
    if File.directory?(File.join(path, ".git"))
      puts "Reusing #{path}"
      return
    end

    if File.exist?(path) && !Dir.empty?(path)
      raise "Workspace exists but is not a git checkout: #{path}"
    end

    puts "Creating #{path}"
    return if @dry_run

    FileUtils.mkdir_p(path)
    run_command("git", "clone", clone_url, ".", chdir: path)
  end

  def ensure_workpad(issue, workspace)
    comments = capture_json(
      "gh", "issue", "view", issue.fetch("number").to_s,
      "--repo", repo,
      "--json", "comments"
    ).fetch("comments")

    return if comments.any? { |comment| comment.fetch("body", "").include?("## Codex Workpad") }

    body = <<~MD
      ## Codex Workpad

      State: In Progress
      Workspace: `#{workspace}`
      Branch: Pending
      PR: Pending

      ### Plan
      - [ ] Read the issue and required repo docs.
      - [ ] Sync with `origin/main`.
      - [ ] Implement the smallest safe change.
      - [ ] Run required verification.
      - [ ] Open a draft PR.

      ### Acceptance
      - Follow the issue body.

      ### Validation
      - Pending.

      ### Notes
      - Runner claimed this issue at #{Time.now.iso8601}.

      ### Blockers
      - None.
    MD

    puts "Creating workpad comment"
    return if @dry_run

    run_command("gh", "issue", "comment", issue.fetch("number").to_s, "--repo", repo, "--body", body)
  end

  def run_codex(issue, workspace)
    prompt = render_prompt(issue, workspace)
    log_path = log_path_for(issue.fetch("number"))
    FileUtils.mkdir_p(File.dirname(log_path)) unless @dry_run

    puts "Starting Codex in #{workspace}"
    puts "Log: #{log_path}"
    if @dry_run
      puts "--- prompt preview ---"
      puts prompt.lines.first(40).join
      puts "--- end preview ---"
      return
    end

    command = Shellwords.split(codex_command)
    env = {
      "AGENT_ISSUE_NUMBER" => issue.fetch("number").to_s,
      "AGENT_ISSUE_URL" => issue.fetch("url").to_s,
      "AGENT_WORKSPACE" => workspace,
      "AGENT_REPO" => repo
    }

    File.open(log_path, "w") do |log|
      Open3.popen2e(env, *command, chdir: workspace) do |stdin, output, wait_thread|
        stdin.write(prompt)
        stdin.close

        output.each do |line|
          print line
          log.write(line)
        end

        status = wait_thread.value
        raise "Codex exited with status #{status.exitstatus}. See #{log_path}" unless status.success?
      end
    end
  end

  def render_prompt(issue, workspace)
    context = {
      "repo" => repo,
      "issue" => {
        "number" => issue.fetch("number").to_s,
        "identifier" => "GH-#{issue.fetch("number")}",
        "title" => issue.fetch("title", ""),
        "body" => issue.fetch("body", "") || "",
        "url" => issue.fetch("url", ""),
        "labels" => label_names(issue).join(", ")
      },
      "workspace" => {
        "path" => workspace
      }
    }

    @template.gsub(/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/) do
      lookup(context, Regexp.last_match(1))
    end
  end

  def lookup(context, key)
    value = key.split(".").reduce(context) do |current, part|
      raise "Unknown template variable: #{key}" unless current.is_a?(Hash) && current.key?(part)

      current.fetch(part)
    end
    value.to_s
  end

  def with_issue_lock(issue)
    FileUtils.mkdir_p(lock_root) unless @dry_run
    lock_path = File.join(lock_root, "GH-#{issue.fetch("number")}.lock")

    if @dry_run
      yield
      return
    end

    begin
      Dir.mkdir(lock_path)
    rescue Errno::EEXIST
      puts "Skipping ##{issue.fetch("number")} because #{lock_path} exists"
      return
    end

    begin
      yield
    ensure
      FileUtils.rm_rf(lock_path)
    end
  end

  def mark_blocked(number, message)
    edit_labels(number, [blocked_label], [todo_label, in_progress_label])
    return if @dry_run

    body = <<~MD
      Codex runner stopped on a blocker.

      ```text
      #{message}
      ```
    MD
    run_command("gh", "issue", "comment", number.to_s, "--repo", repo, "--body", body)
  end

  def edit_labels(number, additions, removals)
    return if additions.empty? && removals.empty?

    args = ["gh", "issue", "edit", number.to_s, "--repo", repo]
    args += ["--add-label", additions.join(",")] unless additions.empty?
    args += ["--remove-label", removals.join(",")] unless removals.empty?
    puts args.shelljoin
    run_command(*args) unless @dry_run
  end

  def ensure_labels
    label_names = capture_json("gh", "label", "list", "--repo", repo, "--limit", "200", "--json", "name").map { |label| label["name"] }

    LABELS.each do |name, (color, description)|
      next if label_names.include?(name)

      puts "Creating label #{name}"
      run_command("gh", "label", "create", name, "--repo", repo, "--color", color, "--description", description) unless @dry_run
    end
  end

  def capture_json(*command)
    stdout, stderr, status = Open3.capture3(*command)
    raise "Command failed: #{command.shelljoin}\n#{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def run_command(*command, chdir: nil)
    options = {}
    options[:chdir] = chdir if chdir
    stdout, stderr, status = Open3.capture3(*command, **options)
    raise "Command failed: #{command.shelljoin}\n#{stdout}\n#{stderr}" unless status.success?

    stdout
  end

  def repo
    @repo ||= @tracker.fetch("repo", "").to_s
  end

  def clone_url
    @clone_url ||= @workspace_config.fetch("clone_url", "git@github.com:#{repo}.git").to_s
  end

  def workspace_root
    @workspace_root ||= File.expand_path(@workspace_config.fetch("root", "").to_s)
  end

  def workspace_path(number)
    File.join(workspace_root, "GH-#{number}")
  end

  def lock_root
    File.join(workspace_root, "_locks")
  end

  def log_path_for(number)
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    File.join(workspace_root, "_logs", "GH-#{number}-#{timestamp}.log")
  end

  def codex_command
    @codex_command ||= @codex_config.fetch("command", "codex exec --dangerously-bypass-approvals-and-sandbox --search -").to_s
  end

  def max_concurrent_agents
    value = @agent_config.fetch("max_concurrent_agents", 1).to_i
    value.positive? ? value : 1
  end

  def poll_interval_seconds
    value = @polling_config.fetch("interval_ms", 30_000).to_i / 1000.0
    value.positive? ? value : 30
  end

  def active_labels
    configured = @tracker["active_labels"]
    @active_labels ||= Array(configured.nil? ? [todo_label, in_progress_label] : configured)
  end

  def terminal_labels
    @terminal_labels ||= [review_label, blocked_label, done_label]
  end

  def todo_label
    @todo_label ||= @tracker.fetch("todo_label", "agent todo")
  end

  def in_progress_label
    @in_progress_label ||= @tracker.fetch("in_progress_label", "agent in progress")
  end

  def review_label
    @review_label ||= @tracker.fetch("review_label", "agent review")
  end

  def blocked_label
    @blocked_label ||= @tracker.fetch("blocked_label", "agent blocked")
  end

  def done_label
    @done_label ||= @tracker.fetch("done_label", "agent done")
  end

  def label_names(issue)
    issue.fetch("labels", []).map { |label| label.fetch("name") }
  end
end

options = {
  dry_run: ENV["DRY_RUN"] == "1",
  watch: false,
  ensure_labels: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/ops/agent-todo-runner.rb [options]"

  opts.on("--workflow PATH", "Workflow file path. Defaults to WORKFLOW.md.") { |value| options[:workflow] = value }
  opts.on("--issue NUMBER", Integer, "Run a specific GitHub issue.") { |value| options[:issue] = value }
  opts.on("--once", "Run one polling pass. This is the default.") { options[:watch] = false }
  opts.on("--watch", "Poll forever.") { options[:watch] = true }
  opts.on("--ensure-labels", "Create missing agent labels.") { options[:ensure_labels] = true }
  opts.on("--labels-only", "Create missing agent labels and exit.") do
    options[:ensure_labels] = true
    options[:labels_only] = true
  end
  opts.on("--dry-run", "Print actions without changing GitHub or launching Codex.") { options[:dry_run] = true }
end

parser.parse!

AgentTodoRunner.new(options).run
