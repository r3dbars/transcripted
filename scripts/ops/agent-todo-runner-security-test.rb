#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "agent-todo-runner"

class AgentTodoRunnerSecurityTest < Minitest::Test
  SAFE_COMMAND = AgentTodoRunner::SAFE_CODEX_COMMAND

  class FixtureRunner < AgentTodoRunner
    def initialize(workflow:, issue_comments:, pull_requests:, pull_request_payloads:)
      @fixture_issue_comments = issue_comments
      @fixture_pull_requests = pull_requests
      @fixture_pull_request_payloads = pull_request_payloads
      super(workflow: workflow, dry_run: true, watch: false, ensure_labels: false, labels_only: false)
    end

    private

    def issue_comments(_number)
      @fixture_issue_comments
    end

    def issue_pull_requests(_number)
      @fixture_pull_requests
    end

    def capture_json(*args)
      return @fixture_pull_request_payloads.fetch(args[3].to_i) if args[0, 3] == ["gh", "pr", "view"]

      raise "unexpected command: #{args.inspect}"
    end
  end

  def test_only_allowlisted_feedback_reaches_prompt
    with_workflow(SAFE_COMMAND) do |workflow|
      runner = FixtureRunner.new(
        workflow: workflow,
        issue_comments: [
          feedback("owner issue feedback", "r3dbars"),
          feedback("attacker issue prompt", "mallory")
        ],
        pull_requests: [{ "number" => 42 }],
        pull_request_payloads: {
          42 => {
            "comments" => [feedback("trusted PR comment", "justinbetker"), feedback("attacker PR comment", "mallory")],
            "reviews" => [feedback("trusted review", "r3dbars"), feedback("attacker review", "mallory")]
          }
        }
      )

      prompt = runner.send(:render_prompt, issue, "/tmp/workspace")
      assert_includes prompt, "owner issue feedback"
      assert_includes prompt, "trusted PR comment"
      assert_includes prompt, "trusted review"
      refute_includes prompt, "attacker issue prompt"
      refute_includes prompt, "attacker PR comment"
      refute_includes prompt, "attacker review"
    end
  end

  def test_dangerous_command_is_rejected
    command = "codex exec --dangerously-bypass-approvals-and-sandbox -"
    with_workflow(command) do |workflow|
      runner = FixtureRunner.new(workflow: workflow, issue_comments: [], pull_requests: [], pull_request_payloads: {})
      error = assert_raises(RuntimeError) { runner.send(:validate_codex_command!) }
      assert_match(/must not bypass/, error.message)
    end
  end

  def test_safe_command_is_accepted
    with_workflow(SAFE_COMMAND) do |workflow|
      runner = FixtureRunner.new(workflow: workflow, issue_comments: [], pull_requests: [], pull_request_payloads: {})
      runner.send(:validate_codex_command!)
    end
  end

  def test_empty_author_allowlist_is_rejected
    with_workflow(SAFE_COMMAND, allowed_authors: "[]") do |workflow|
      runner = FixtureRunner.new(workflow: workflow, issue_comments: [], pull_requests: [], pull_request_payloads: {})
      error = assert_raises(RuntimeError) { runner.send(:validate!) }
      assert_match(/non-empty tracker.allowed_authors/, error.message)
    end
  end

  private

  def feedback(body, login)
    { "body" => body, "url" => "https://example.test/comment", "author" => { "login" => login } }
  end

  def issue
    {
      "number" => 7,
      "title" => "Trusted issue",
      "body" => "Trusted body",
      "url" => "https://example.test/issues/7",
      "author" => { "login" => "r3dbars" },
      "labels" => [{ "name" => "agent todo" }]
    }
  end

  def with_workflow(command, allowed_authors: "[r3dbars, justinbetker]")
    Tempfile.create(["workflow", ".md"]) do |file|
      file.write(<<~WORKFLOW)
        ---
        tracker:
          kind: github
          repo: r3dbars/transcripted
          allowed_authors: #{allowed_authors}
        workspace:
          root: /tmp/workspaces
        codex:
          command: #{command}
        ---
        Issue: {{ issue.title }}
        {{ trusted_feedback }}
      WORKFLOW
      file.flush
      yield file.path
    end
  end
end
