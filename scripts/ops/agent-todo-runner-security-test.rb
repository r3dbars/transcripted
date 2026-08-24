#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "agent-todo-runner"

class AgentTodoRunnerSecurityTest < Minitest::Test
  SAFE_COMMAND = AgentTodoRunner::SAFE_CODEX_COMMAND

  class FixtureRunner < AgentTodoRunner
    def initialize(workflow:, issue_comments:, pull_requests:, pull_request_payloads:, inline_comments: {}, closing_pull_requests: [])
      @fixture_issue_comments = issue_comments
      @fixture_pull_requests = pull_requests
      @fixture_closing_pull_requests = closing_pull_requests
      @fixture_pull_request_payloads = pull_request_payloads
      @fixture_inline_comments = inline_comments
      super(workflow: workflow, dry_run: true, watch: false, ensure_labels: false, labels_only: false)
    end

    private

    def issue_comments(_number)
      @fixture_issue_comments
    end

    def branch_linked_issue_pull_requests(_number)
      @fixture_pull_requests
    end

    def closing_issue_pull_requests(_number)
      @fixture_closing_pull_requests
    end

    def capture_json(*args)
      return @fixture_pull_request_payloads.fetch(args[3].to_i) if args[0, 3] == ["gh", "pr", "view"]

      raise "unexpected command: #{args.inspect}"
    end


    def inline_pull_request_comments(number)
      @fixture_inline_comments.fetch(number, [])
    end
  end

  def test_only_allowlisted_feedback_reaches_prompt
    with_workflow(SAFE_COMMAND) do |workflow|
      runner = FixtureRunner.new(
        workflow: workflow,
        issue_comments: [
          feedback("owner issue feedback", "r3dbars", "2026-08-24T10:00:00Z"),
          feedback("attacker issue prompt", "mallory", "2026-08-24T11:00:00Z")
        ],
        pull_requests: [{ "number" => 42 }],
        pull_request_payloads: {
          42 => {
            "comments" => [feedback("trusted PR comment", "justinbetker", "2026-08-24T12:00:00Z"), feedback("attacker PR comment", "mallory", "2026-08-24T13:00:00Z")],
            "reviews" => [feedback("trusted review", "r3dbars", "2026-08-24T14:00:00Z"), feedback("attacker review", "mallory", "2026-08-24T15:00:00Z")]
          }
        },
        inline_comments: {
          42 => [feedback("trusted inline review", "justinbetker", "2026-08-24T16:00:00Z"), feedback("attacker inline review", "mallory", "2026-08-24T17:00:00Z")]
        }
      )

      prompt = runner.send(:render_prompt, issue, "/tmp/workspace")
      assert_includes prompt, "owner issue feedback"
      assert_includes prompt, "trusted PR comment"
      assert_includes prompt, "trusted review"
      assert_includes prompt, "trusted inline review"
      refute_includes prompt, "attacker issue prompt"
      refute_includes prompt, "attacker PR comment"
      refute_includes prompt, "attacker review"
      refute_includes prompt, "attacker inline review"
      assert_operator prompt.index("owner issue feedback"), :<, prompt.index("trusted inline review")
    end
  end

  def test_closing_and_branch_linked_pull_requests_are_combined_without_duplicates
    with_workflow(SAFE_COMMAND) do |workflow|
      runner = FixtureRunner.new(
        workflow: workflow,
        issue_comments: [],
        pull_requests: [{ "number" => 42 }, { "number" => 43 }],
        closing_pull_requests: [{ "number" => 41 }, { "number" => 42 }],
        pull_request_payloads: {}
      )

      assert_equal [41, 42, 43], runner.send(:issue_pull_requests, 7).map { |pull_request| pull_request.fetch("number") }
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

  def test_feedback_truncation_preserves_valid_utf8
    with_workflow(SAFE_COMMAND) do |workflow|
      runner = FixtureRunner.new(workflow: workflow, issue_comments: [], pull_requests: [], pull_request_payloads: {})
      value = ("a" * 3_999) + "😀"
      truncated = runner.send(:truncate_utf8, value, 4_000)
      assert truncated.valid_encoding?
      assert_operator truncated.bytesize, :<=, 4_000
    end
  end

  private

  def feedback(body, login, created_at = "2026-08-24T10:00:00Z")
    { "body" => body, "url" => "https://example.test/comment", "createdAt" => created_at, "author" => { "login" => login } }
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
