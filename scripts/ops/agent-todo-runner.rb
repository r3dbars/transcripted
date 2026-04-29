#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "cgi"
require "json"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "tempfile"
require "time"
require "timeout"
require "yaml"

class AgentTodoRunner
  LABELS = {
    "agent todo" => ["5319e7", "Ready for the local Codex issue runner"],
    "agent in progress" => ["f9d0c4", "Claimed by the local Codex issue runner"],
    "human review" => ["0e8a16", "Codex opened a PR for human review"],
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
      "--json", "number,title,body,labels,url,assignees,author,createdAt,updatedAt"
    )

    issues.select { |issue| active_issue?(issue) || unauthorized_active_issue?(issue) }
  end

  def fetch_issue(number)
    capture_json(
      "gh", "issue", "view", number.to_s,
      "--repo", repo,
      "--json", "number,title,body,labels,url,assignees,author,createdAt,updatedAt"
    )
  end

  def active_issue?(issue)
    labels = label_names(issue)
    (labels & active_labels).any? && (labels & terminal_labels).empty? && allowed_author?(issue)
  end

  def unauthorized_active_issue?(issue)
    labels = label_names(issue)
    (labels & active_labels).any? && (labels & terminal_labels).empty? && !allowed_author?(issue)
  end

  def handle_issue(issue)
    number = issue.fetch("number")
    workspace = workspace_path(number)

    unless allowed_author?(issue)
      skip_unauthorized_issue(issue)
      return
    end

    puts "Claiming #{repo}##{number}: #{issue.fetch("title")}"
    claim_issue(issue)
    prepare_workspace(number, workspace)
    ensure_workpad(issue, workspace)
    run_codex(issue, workspace)
    begin
      post_review_packet(issue, workspace)
    rescue StandardError => error
      warn "Review packet failed for ##{number}: #{error.message}"
      comment_review_packet_failure(number, error.message)
    end
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

  def post_review_packet(issue, workspace)
    return if @dry_run

    number = issue.fetch("number")
    branch = run_command("git", "branch", "--show-current", chdir: workspace).strip
    raise "Codex completed but no branch was active in #{workspace}" if branch.empty?

    pr = find_pull_request(branch)
    raise "Codex completed but no PR was found for branch #{branch}" if pr.nil?

    puts "Creating review packet for PR ##{pr.fetch("number")}"
    changed_files = changed_files_for(workspace)
    classification = classify_change(changed_files)
    visual_files = visual_artifacts_for(workspace)
    visual_links = publish_visual_artifacts(number, pr, visual_files, workspace)
    qa_results = run_qa_packet(workspace, changed_files)
    automated_review = run_automated_pr_review(issue, workspace, pr, changed_files, qa_results)
    comment = review_packet_comment(
      issue: issue,
      pr: pr,
      branch: branch,
      changed_files: changed_files,
      classification: classification,
      visual_files: visual_files,
      visual_links: visual_links,
      qa_results: qa_results,
      automated_review: automated_review
    )

    write_review_packet_comment(pr.fetch("number"), comment)
  end

  def find_pull_request(branch)
    prs = capture_json(
      "gh", "pr", "list",
      "--repo", repo,
      "--head", branch,
      "--state", "all",
      "--limit", "1",
      "--json", "number,url,title,isDraft,state,headRefName,baseRefName"
    )
    prs.first
  end

  def changed_files_for(workspace)
    run_command("git", "fetch", "origin", "main", chdir: workspace)
    output = run_command("git", "diff", "--name-only", "origin/main...HEAD", chdir: workspace)
    output.lines.map(&:strip).reject(&:empty?)
  end

  def classify_change(files)
    flags = []
    flags << "ui change" if ui_change?(files)
    flags << "new feature/change" if feature_change?(files)
    flags << "tests/docs only" if flags.empty? && files.any? { |path| path.start_with?("Tests/", "docs/") || path.end_with?(".md") }
    flags << "unknown" if flags.empty?
    flags
  end

  def ui_change?(files)
    files.any? do |path|
      path.start_with?("Sources/UI/", "Resources/", "docs/assets/", "docs/screenshots/") ||
        path.match?(/\.(astro|css|html|js|jsx|ts|tsx|swiftui)$/)
    end
  end

  def feature_change?(files)
    files.any? do |path|
      path.start_with?("Sources/", "Tools/", "scripts/") &&
        !path.start_with?("Tests/")
    end
  end

  def visual_artifacts_for(workspace)
    root = File.join(workspace, ".agent-review", "visuals")
    return [] unless File.directory?(root)

    Dir.glob(File.join(root, "**", "*.{png,jpg,jpeg,gif}"), File::FNM_CASEFOLD).sort
  end

  def publish_visual_artifacts(_issue_number, pr, files, workspace)
    return [] if files.empty?

    files.map do |file|
      name = File.basename(file)
      raw_url = raw_visual_url(pr, file, workspace)
      raw_url ? "![#{name}](#{raw_url})" : local_visual_link(file)
    end
  rescue StandardError => error
    files.map { |file| "#{local_visual_link(file)} _(embed failed: #{error.message.lines.first&.strip})_" }
  end

  def raw_visual_url(pr, file, workspace)
    relative_path = Pathname.new(file).relative_path_from(Pathname.new(workspace)).to_s
    return nil if relative_path.start_with?("..")

    encoded_path = relative_path.split("/").map { |part| CGI.escape(part).gsub("+", "%20") }.join("/")
    "https://raw.githubusercontent.com/#{repo}/#{pr.fetch("headRefName")}/#{encoded_path}"
  end

  def local_visual_link(file)
    "`#{file}`"
  end

  def run_qa_packet(workspace, changed_files)
    results = []
    if File.directory?(File.join(workspace, "Tools", "TranscriptedQA"))
      results << run_packet_command(
        "Transcripted QA health",
        ["swift", "run", "transcripted-qa", "check-health"],
        chdir: File.join(workspace, "Tools", "TranscriptedQA"),
        timeout_seconds: 240
      )

      if deep_transcripted_qa?(changed_files)
        results << run_packet_command(
          "Transcripted QA validate-all",
          ["swift", "run", "transcripted-qa", "validate-all"],
          chdir: File.join(workspace, "Tools", "TranscriptedQA"),
          timeout_seconds: 900
        )
      end
    else
      results << {
        "name" => "Transcripted QA",
        "command" => "swift run transcripted-qa check-health",
        "status" => "skipped",
        "output" => "Tools/TranscriptedQA was not present."
      }
    end
    results
  end

  def deep_transcripted_qa?(files)
    files.any? do |path|
      path.start_with?(
        "Sources/Meeting/",
        "Sources/TranscriptedCore/",
        "Sources/Dictation/",
        "Sources/Support/TranscriptedStoragePaths",
        "Tools/TranscriptedQA/"
      )
    end
  end

  def run_packet_command(name, command, chdir:, timeout_seconds:)
    attempts = 0
    loop do
      attempts += 1
      output = +""
      status = nil

      begin
        Timeout.timeout(timeout_seconds) do
          stdout, stderr, process_status = Open3.capture3(*command, chdir: chdir)
          output = [stdout, stderr].reject(&:empty?).join("\n")
          status = process_status.success? ? "passed" : "failed"
        end
      rescue Timeout::Error
        return {
          "name" => name,
          "command" => command.shelljoin,
          "status" => "timed out",
          "output" => "Timed out after #{timeout_seconds}s.",
          "attempts" => attempts
        }
      rescue StandardError => error
        return {
          "name" => name,
          "command" => command.shelljoin,
          "status" => "failed",
          "output" => error.message,
          "attempts" => attempts
        } if attempts >= 2

        sleep 2
        next
      end

      return {
        "name" => name,
        "command" => command.shelljoin,
        "status" => status,
        "output" => truncate_packet_output(output),
        "attempts" => attempts
      } unless status == "failed" && attempts < 2

      sleep 2
    end
  end

  def run_automated_pr_review(issue, workspace, pr, changed_files, qa_results)
    review_dir = File.join(workspace, ".agent-review")
    FileUtils.mkdir_p(review_dir)
    review_path = File.join(review_dir, "automated-review.md")
    diff_path = File.join(review_dir, "pr.diff")
    File.write(diff_path, run_command("git", "diff", "--stat", "origin/main...HEAD", chdir: workspace) + "\n\n" + run_command("git", "diff", "origin/main...HEAD", chdir: workspace))

    prompt = <<~PROMPT
      You are doing an automated code review for Transcripted PR ##{pr.fetch("number")}.

      Issue: #{issue.fetch("url")}
      PR: #{pr.fetch("url")}
      Title: #{pr.fetch("title")}

      Changed files:
      #{changed_files.map { |path| "- #{path}" }.join("\n")}

      QA results:
      #{qa_results.map { |result| "- #{result.fetch("name")}: #{result.fetch("status")} (`#{result.fetch("command")}`)" }.join("\n")}

      Review the diff in .agent-review/pr.diff.
      The final Agent Review Packet comment is posted after this review finishes, so do not flag that comment as missing.

      Output concise Markdown only:
      - Findings first, ordered by severity, with file/line references when possible.
      - If you find no issues, say "No blocking issues found."
      - Then list residual risks/manual checks.
      - Do not modify files.
    PROMPT

    command = Shellwords.split(review_command(review_path))
    Open3.popen2e(*command, chdir: workspace) do |stdin, output, wait_thread|
      stdin.write(prompt)
      stdin.close
      output.each { |line| print line }
      status = wait_thread.value
      unless status.success?
        return {
          "status" => "failed",
          "body" => "Automated review command failed with status #{status.exitstatus}."
        }
      end
    end

    {
      "status" => "completed",
      "body" => File.exist?(review_path) ? File.read(review_path).strip : "Automated review completed but did not write output."
    }
  rescue StandardError => error
    {
      "status" => "failed",
      "body" => error.message
    }
  end

  def review_command(output_path)
    "codex exec -m gpt-5.5 -c model_reasoning_effort=medium --dangerously-bypass-approvals-and-sandbox --output-last-message #{Shellwords.escape(output_path)} -"
  end

  def review_packet_comment(issue:, pr:, branch:, changed_files:, classification:, visual_files:, visual_links:, qa_results:, automated_review:)
    visual_section = if visual_files.empty?
                       if classification.include?("ui change")
                         "UI change detected, but no visual artifact was found at `.agent-review/visuals/`.\n\nAgent follow-up: add a sanitized screenshot or GIF for this PR before merge."
                       else
                         "No UI visual required for this change."
                       end
                     else
                       visual_links.join("\n\n")
                     end

    qa_section = qa_results.map do |result|
      output = result.fetch("output", "").to_s
      output_block = if output.empty?
                       ""
                     else
                       escaped = output.gsub("```", "` ` `")
                       <<~MD

                         <details>
                         <summary>Output</summary>

                         ```text
                         #{escaped}
                         ```

                         </details>
                       MD
                     end
      <<~MD
        - **#{result.fetch("name")}**: #{result.fetch("status")}
          - Command: `#{result.fetch("command")}`
          - Attempts: #{result.fetch("attempts", 1)}
          #{output_block}
      MD
    end.join

    <<~MD
      ## Agent Review Packet

      Issue: #{issue.fetch("url")}
      Branch: `#{branch}`
      Change type: #{classification.join(", ")}

      ### What Changed
      #{changed_files.empty? ? "- No changed files detected." : changed_files.map { |path| "- `#{path}`" }.join("\n")}

      ### Visual Review
      #{visual_section}

      ### QA
      #{qa_section}

      ### Automated PR Review
      Status: #{automated_review.fetch("status")}

      #{automated_review.fetch("body")}
    MD
  end

  def write_review_packet_comment(pr_number, body)
    Tempfile.create(["agent-review-packet", ".md"]) do |file|
      file.write(body)
      file.flush
      run_command("gh", "pr", "comment", pr_number.to_s, "--repo", repo, "--body-file", file.path)
    end
  end

  def truncate_packet_output(output)
    text = output.to_s.strip
    return "" if text.empty?
    return text if text.length <= 4_000

    "[truncated]\n#{text[-4_000..]}"
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
        "author" => issue_author(issue),
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

  def comment_review_packet_failure(number, message)
    return if @dry_run

    body = <<~MD
      Codex opened or attempted the implementation PR, but the automated review packet failed.

      ```text
      #{message}
      ```
    MD
    run_command("gh", "issue", "comment", number.to_s, "--repo", repo, "--body", body)
  end

  def skip_unauthorized_issue(issue)
    number = issue.fetch("number")
    author = issue_author(issue)
    puts "Skipping ##{number}: author #{author} is not in allowed_authors"
    return if @dry_run

    edit_labels(number, [], [todo_label, in_progress_label])
    body = <<~MD
      Agent handoff skipped.

      `agent todo` is restricted to repository operators. This issue was opened by `#{author}`, which is not in the runner allowlist.
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
    @codex_command ||= @codex_config.fetch("command", "codex exec -m gpt-5.5 -c model_reasoning_effort=medium --dangerously-bypass-approvals-and-sandbox -").to_s
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
    @review_label ||= @tracker.fetch("review_label", "human review")
  end

  def blocked_label
    @blocked_label ||= @tracker.fetch("blocked_label", "agent blocked")
  end

  def done_label
    @done_label ||= @tracker.fetch("done_label", "agent done")
  end

  def allowed_author?(issue)
    authors = allowed_authors
    return true if authors.empty?

    authors.include?(issue_author(issue))
  end

  def allowed_authors
    @allowed_authors ||= Array(@tracker.fetch("allowed_authors", [])).map(&:to_s)
  end

  def issue_author(issue)
    author = issue.fetch("author", nil)
    return author.fetch("login", "unknown").to_s if author.is_a?(Hash)

    "unknown"
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
