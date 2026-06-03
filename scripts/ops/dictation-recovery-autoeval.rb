#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic policy lab for the dictation start wait loop.
#
# This does not pretend to replace live CoreAudio testing. It gives us a stable
# way to score recovery knobs against the scenarios that are hard to reproduce
# on demand: wake, Bluetooth route churn, stale input flags, failed starts, and
# unrecoverable routes.

require "optparse"

Config = Struct.new(
  :name,
  :poll_ms,
  :refresh_interval_ms,
  :refresh_timeout_ms,
  :budget_ms,
  :refreshes_before_recovery_start,
  :forced_recovery_refreshes,
  :max_forced_recoveries,
  :max_recovery_start_attempts,
  :max_recording_start_attempts,
  keyword_init: true
)

Scenario = Struct.new(
  :name,
  :description,
  :recovering_until_ms,
  :flag_ready_at_ms,
  :actual_ready_at_ms,
  :passive_flag_updates,
  :refresh_updates_flag,
  :refresh_duration_ms,
  :refresh_never_finishes,
  :normal_start_ms,
  :recovery_start_ms,
  :force_recovery_ms,
  :force_makes_flag_ready,
  :force_makes_actual_ready,
  :normal_start_outcomes,
  :recovery_start_outcomes,
  :expect_success,
  keyword_init: true
)

Result = Struct.new(
  :config,
  :scenario,
  :success,
  :time_ms,
  :normal_starts,
  :recovery_starts,
  :refreshes,
  :forced_recoveries,
  :refresh_timeouts,
  :reason,
  keyword_init: true
) do
  def start_attempts
    normal_starts + recovery_starts
  end
end

BASELINE = Config.new(
  name: "baseline",
  poll_ms: 150,
  refresh_interval_ms: 300,
  refresh_timeout_ms: 900,
  budget_ms: 6000,
  refreshes_before_recovery_start: 4,
  forced_recovery_refreshes: 6,
  max_forced_recoveries: 2,
  max_recovery_start_attempts: 2,
  max_recording_start_attempts: 3
)

KEPT_POLICY = Config.new(
  name: "kept_current_policy",
  poll_ms: 100,
  refresh_interval_ms: 300,
  refresh_timeout_ms: 900,
  budget_ms: 6000,
  refreshes_before_recovery_start: 4,
  forced_recovery_refreshes: 5,
  max_forced_recoveries: 2,
  max_recovery_start_attempts: 2,
  max_recording_start_attempts: 2
)

SCENARIOS = [
  Scenario.new(
    name: "fast_ready_no_recovery",
    description: "Normal ready route should not get slower or trigger recovery work.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 0,
    actual_ready_at_ms: 0,
    passive_flag_updates: true,
    refresh_updates_flag: true,
    refresh_duration_ms: 70,
    refresh_never_finishes: false,
    normal_start_ms: 85,
    recovery_start_ms: 100,
    force_recovery_ms: 550,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:success],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "cold_launch_unready_then_ready",
    description: "App starts dictation before the route flag has caught up.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 520,
    actual_ready_at_ms: 520,
    passive_flag_updates: false,
    refresh_updates_flag: true,
    refresh_duration_ms: 80,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 550,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "wake_recovery_finishes",
    description: "Mac wakes and the audio device recovery flag clears later.",
    recovering_until_ms: 1200,
    flag_ready_at_ms: 1200,
    actual_ready_at_ms: 1200,
    passive_flag_updates: true,
    refresh_updates_flag: true,
    refresh_duration_ms: 80,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 650,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "bluetooth_reconnect_stale_flag",
    description: "Bluetooth route becomes recordable before the readiness flag updates.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 1300,
    actual_ready_at_ms: 760,
    passive_flag_updates: false,
    refresh_updates_flag: true,
    refresh_duration_ms: 100,
    refresh_never_finishes: false,
    normal_start_ms: 100,
    recovery_start_ms: 120,
    force_recovery_ms: 700,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "bluetooth_late_ready_stale_flag",
    description: "Bluetooth route settles later; early recovery starts can waste the one guarded attempt.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 1600,
    actual_ready_at_ms: 1050,
    passive_flag_updates: false,
    refresh_updates_flag: true,
    refresh_duration_ms: 100,
    refresh_never_finishes: false,
    normal_start_ms: 100,
    recovery_start_ms: 120,
    force_recovery_ms: 700,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "slow_refresh_would_recover",
    description: "A slow route would become ready via refresh without hard recovery.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 1260,
    actual_ready_at_ms: 1260,
    passive_flag_updates: false,
    refresh_updates_flag: true,
    refresh_duration_ms: 90,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 650,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "selected_input_stale_until_force",
    description: "Selected route is stale and refreshes cannot repair it.",
    recovering_until_ms: 0,
    flag_ready_at_ms: nil,
    actual_ready_at_ms: nil,
    passive_flag_updates: false,
    refresh_updates_flag: false,
    refresh_duration_ms: 90,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 650,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "first_start_fails_retry_succeeds",
    description: "Input says ready, the first CoreAudio start fails, retry succeeds.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 0,
    actual_ready_at_ms: 0,
    passive_flag_updates: true,
    refresh_updates_flag: true,
    refresh_duration_ms: 70,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 600,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:fail, :success],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "ready_flag_start_keeps_failing",
    description: "Input format says ready, but every normal start fails until rebuild.",
    recovering_until_ms: 0,
    flag_ready_at_ms: 0,
    actual_ready_at_ms: nil,
    passive_flag_updates: true,
    refresh_updates_flag: true,
    refresh_duration_ms: 80,
    refresh_never_finishes: false,
    normal_start_ms: 100,
    recovery_start_ms: 110,
    force_recovery_ms: 650,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:fail, :fail, :when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "refresh_times_out_then_recovery_start",
    description: "A readiness refresh wedges and the guarded recovery start must unblock it.",
    recovering_until_ms: 0,
    flag_ready_at_ms: nil,
    actual_ready_at_ms: 950,
    passive_flag_updates: false,
    refresh_updates_flag: false,
    refresh_duration_ms: 5000,
    refresh_never_finishes: true,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 650,
    force_makes_flag_ready: true,
    force_makes_actual_ready: true,
    normal_start_outcomes: [:when_actual_ready],
    recovery_start_outcomes: [:when_actual_ready],
    expect_success: true
  ),
  Scenario.new(
    name: "unrecoverable_route_times_out",
    description: "Mic route never becomes recordable; failure must stay clear and bounded.",
    recovering_until_ms: 0,
    flag_ready_at_ms: nil,
    actual_ready_at_ms: nil,
    passive_flag_updates: false,
    refresh_updates_flag: false,
    refresh_duration_ms: 100,
    refresh_never_finishes: false,
    normal_start_ms: 90,
    recovery_start_ms: 100,
    force_recovery_ms: 700,
    force_makes_flag_ready: false,
    force_makes_actual_ready: false,
    normal_start_outcomes: [:fail],
    recovery_start_outcomes: [:fail],
    expect_success: false
  )
].freeze

def config_variants
  [
    BASELINE,
    BASELINE.dup.tap { |config| config.name = "poll_100ms"; config.poll_ms = 100 },
    BASELINE.dup.tap { |config| config.name = "poll_75ms"; config.poll_ms = 75 },
    BASELINE.dup.tap { |config| config.name = "poll_50ms"; config.poll_ms = 50 },
    BASELINE.dup.tap { |config| config.name = "refresh_interval_200ms"; config.refresh_interval_ms = 200 },
    BASELINE.dup.tap { |config| config.name = "refresh_interval_150ms"; config.refresh_interval_ms = 150 },
    BASELINE.dup.tap { |config| config.name = "refresh_timeout_600ms"; config.refresh_timeout_ms = 600 },
    BASELINE.dup.tap { |config| config.name = "recovery_start_after_3_refreshes"; config.refreshes_before_recovery_start = 3 },
    BASELINE.dup.tap { |config| config.name = "recovery_start_after_2_refreshes"; config.refreshes_before_recovery_start = 2 },
    BASELINE.dup.tap { |config| config.name = "max_ready_start_attempts_2"; config.max_recording_start_attempts = 2 },
    BASELINE.dup.tap { |config| config.name = "max_ready_start_attempts_1"; config.max_recording_start_attempts = 1 },
    BASELINE.dup.tap { |config| config.name = "force_after_5_refreshes"; config.forced_recovery_refreshes = 5 },
    BASELINE.dup.tap { |config| config.name = "force_after_4_refreshes"; config.forced_recovery_refreshes = 4 },
    KEPT_POLICY,
    BASELINE.dup.tap do |config|
      config.name = "combo_poll100_refresh200_attempts2"
      config.poll_ms = 100
      config.refresh_interval_ms = 200
      config.max_recording_start_attempts = 2
    end
  ]
end

def percentile(values, ratio)
  return nil if values.empty?

  sorted = values.sort
  sorted[[((sorted.length - 1) * ratio).ceil, sorted.length - 1].min]
end

def recording_start_attempts_exhausted?(input_format_ready, attempts, config)
  input_format_ready && config.max_recording_start_attempts.positive? &&
    attempts >= config.max_recording_start_attempts
end

def wait_action(state, config)
  return :wait_for_recovery if state[:is_recovering]

  exhausted = recording_start_attempts_exhausted?(
    state[:input_format_ready],
    state[:recording_start_attempts_since_recovery],
    config
  )
  should_force = state[:readiness_refreshes] >= config.forced_recovery_refreshes || exhausted
  return :force_input_recovery if should_force && state[:forced_recoveries] < config.max_forced_recoveries

  if state[:input_format_ready]
    return :refresh_input_readiness if exhausted

    return :start_recording
  end

  should_try_recovery_start = state[:readiness_refresh_timed_out] ||
    state[:readiness_refreshes] >= config.refreshes_before_recovery_start
  return :start_recovery_recording if should_try_recovery_start && state[:recovery_starts].zero?

  if should_try_recovery_start &&
     state[:forced_recoveries].positive? &&
     state[:forced_recoveries] < config.max_forced_recoveries &&
     state[:recovery_starts] < config.max_recovery_start_attempts
    return :start_recovery_recording
  end

  :refresh_input_readiness
end

def ready_at_time?(time_ms, ready_at_ms)
  ready_at_ms && time_ms >= ready_at_ms
end

def outcome_success?(outcomes, attempt_index, actual_ready)
  outcome = outcomes[[attempt_index, outcomes.length - 1].min] || :fail
  case outcome
  when :success
    true
  when :fail
    false
  when :when_actual_ready
    actual_ready
  else
    raise "unknown start outcome: #{outcome.inspect}"
  end
end

def start_refresh!(state, now_ms, scenario, forced: false)
  return false if state[:active_refresh]

  finish_ms = scenario.refresh_never_finishes ? now_ms + 1_000_000 : now_ms + scenario.refresh_duration_ms
  if forced
    finish_ms = now_ms + scenario.force_recovery_ms
    state[:forced_recoveries] += 1
    state[:readiness_refreshes] = 0
    state[:recording_start_attempts_since_recovery] = 0
    state[:active_refresh] = {
      kind: :force,
      started_at_ms: now_ms,
      finish_at_ms: finish_ms
    }
  else
    state[:readiness_refreshes] += 1
    state[:active_refresh] = {
      kind: :refresh,
      started_at_ms: now_ms,
      finish_at_ms: finish_ms
    }
  end
  true
end

def complete_refresh_if_ready!(state, now_ms, scenario)
  active = state[:active_refresh]
  return unless active && active[:finish_at_ms] <= now_ms

  case active[:kind]
  when :refresh
    if scenario.refresh_updates_flag &&
       ready_at_time?(active[:finish_at_ms], scenario.flag_ready_at_ms)
      state[:input_format_ready] = true
    end
  when :force
    state[:actual_recording_ready] = true if scenario.force_makes_actual_ready
    state[:input_format_ready] = true if scenario.force_makes_flag_ready
  end

  state[:active_refresh] = nil
end

def cancel_refresh_if_timed_out!(state, now_ms, config)
  active = state[:active_refresh]
  return unless active
  return if now_ms - active[:started_at_ms] < config.refresh_timeout_ms

  state[:active_refresh] = nil
  state[:readiness_refresh_timed_out] = true
  state[:refresh_timeouts] += 1
end

def update_passive_state!(state, now_ms, scenario)
  if scenario.passive_flag_updates && ready_at_time?(now_ms, scenario.flag_ready_at_ms)
    state[:input_format_ready] = true
  end

  if ready_at_time?(now_ms, scenario.actual_ready_at_ms)
    state[:actual_recording_ready] = true
  end
end

def simulate(scenario, config)
  now_ms = 0
  state = {
    active_refresh: nil,
    actual_recording_ready: ready_at_time?(0, scenario.actual_ready_at_ms),
    input_format_ready: ready_at_time?(0, scenario.flag_ready_at_ms),
    readiness_refreshes: 0,
    forced_recoveries: 0,
    recovery_starts: 0,
    normal_starts: 0,
    refresh_timeouts: 0,
    readiness_refresh_timed_out: false,
    recording_start_attempts_since_recovery: 0,
    is_recovering: scenario.recovering_until_ms.positive?
  }
  next_refresh_at_ms = 0

  unless state[:is_recovering] || state[:input_format_ready]
    start_refresh!(state, now_ms, scenario, forced: false)
    next_refresh_at_ms = now_ms + config.refresh_interval_ms
  end

  while now_ms < config.budget_ms
    complete_refresh_if_ready!(state, now_ms, scenario)
    cancel_refresh_if_timed_out!(state, now_ms, config)
    update_passive_state!(state, now_ms, scenario)

    state[:is_recovering] = now_ms < scenario.recovering_until_ms ||
      (state[:active_refresh]&.fetch(:kind) == :force)

    action = wait_action(state, config)
    case action
    when :wait_for_recovery
      # keep waiting
    when :refresh_input_readiness
      if now_ms >= next_refresh_at_ms &&
         start_refresh!(state, now_ms, scenario, forced: false)
        next_refresh_at_ms = now_ms + config.refresh_interval_ms
      end
    when :force_input_recovery
      if start_refresh!(state, now_ms, scenario, forced: true)
        next_refresh_at_ms = now_ms + config.refresh_interval_ms
      end
    when :start_recovery_recording
      state[:recovery_starts] += 1
      state[:readiness_refresh_timed_out] = false
      attempt_index = state[:recovery_starts] - 1
      now_ms += scenario.recovery_start_ms
      update_passive_state!(state, now_ms, scenario)
      if outcome_success?(scenario.recovery_start_outcomes, attempt_index, state[:actual_recording_ready])
        return Result.new(
          config: config.name,
          scenario: scenario.name,
          success: true,
          time_ms: now_ms,
          normal_starts: state[:normal_starts],
          recovery_starts: state[:recovery_starts],
          refreshes: state[:readiness_refreshes],
          forced_recoveries: state[:forced_recoveries],
          refresh_timeouts: state[:refresh_timeouts],
          reason: "recovery_start"
        )
      end
      if start_refresh!(state, now_ms, scenario, forced: false)
        next_refresh_at_ms = now_ms + config.refresh_interval_ms
      end
    when :start_recording
      state[:normal_starts] += 1
      state[:recording_start_attempts_since_recovery] += 1
      attempt_index = state[:normal_starts] - 1
      now_ms += scenario.normal_start_ms
      update_passive_state!(state, now_ms, scenario)
      if outcome_success?(scenario.normal_start_outcomes, attempt_index, state[:actual_recording_ready])
        return Result.new(
          config: config.name,
          scenario: scenario.name,
          success: true,
          time_ms: now_ms,
          normal_starts: state[:normal_starts],
          recovery_starts: state[:recovery_starts],
          refreshes: state[:readiness_refreshes],
          forced_recoveries: state[:forced_recoveries],
          refresh_timeouts: state[:refresh_timeouts],
          reason: "ready_start"
        )
      end
      if start_refresh!(state, now_ms, scenario, forced: false)
        next_refresh_at_ms = now_ms + config.refresh_interval_ms
      end
    else
      raise "unknown action: #{action.inspect}"
    end

    now_ms += config.poll_ms
  end

  Result.new(
    config: config.name,
    scenario: scenario.name,
    success: false,
    time_ms: config.budget_ms,
    normal_starts: state[:normal_starts],
    recovery_starts: state[:recovery_starts],
    refreshes: state[:readiness_refreshes],
    forced_recoveries: state[:forced_recoveries],
    refresh_timeouts: state[:refresh_timeouts],
    reason: "microphone_start_timeout"
  )
end

def summarize(results)
  successes = results.select(&:success)
  expected_successes = results.select { |result| scenario_by_name(result.scenario).expect_success }
  success_times = expected_successes.select(&:success).map(&:time_ms)
  {
    successes: successes.length,
    failures: results.length - successes.length,
    unexpected_failures: expected_successes.count { |result| !result.success },
    p50_ms: percentile(success_times, 0.50),
    p90_ms: percentile(success_times, 0.90),
    p95_ms: percentile(success_times, 0.95),
    max_ms: success_times.max,
    start_attempts: results.sum(&:start_attempts),
    recovery_starts: results.sum(&:recovery_starts),
    refreshes: results.sum(&:refreshes),
    forced_recoveries: results.sum(&:forced_recoveries),
    refresh_timeouts: results.sum(&:refresh_timeouts),
    microphone_start_timeouts: results.count { |result| !result.success }
  }
end

def scenario_by_name(name)
  SCENARIOS.find { |scenario| scenario.name == name } || raise("missing scenario #{name}")
end

def delta(current, baseline)
  return "" if current.nil? || baseline.nil?

  value = current - baseline
  value.zero? ? "0" : format("%+d", value)
end

def print_table(headers, rows)
  widths = headers.map(&:length)
  rows.each do |row|
    row.each_with_index do |cell, index|
      widths[index] = [widths[index], cell.to_s.length].max
    end
  end
  puts "| #{headers.each_with_index.map { |header, i| header.ljust(widths[i]) }.join(" | ")} |"
  puts "| #{widths.map { |width| "-" * width }.join(" | ")} |"
  rows.each do |row|
    puts "| #{row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join(" | ")} |"
  end
end

options = {
  details: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/ops/dictation-recovery-autoeval.rb [--details]"
  parser.on("--details", "Print per-scenario rows for every tested knob") do
    options[:details] = true
  end
end.parse!

variants = config_variants
all_results = variants.to_h do |config|
  [config.name, SCENARIOS.map { |scenario| simulate(scenario, config) }]
end
baseline_summary = summarize(all_results.fetch(BASELINE.name))

puts "# Dictation Recovery Autoeval"
puts
puts "Primary metric: request-to-listening time for slow dictation recovery scenarios."
puts "Guardrails: expected success cases must still succeed; unrecoverable route must time out clearly; attempts and hard recoveries stay bounded."
puts "Baseline: pre-keeper policy, 150ms poll, force after 6 stale refreshes, ready-start cap 3."
puts "Kept current policy: 100ms poll, force after 5 stale refreshes, ready-start cap 2."
puts

puts "## Scenarios"
print_table(
  ["scenario", "expect_success", "purpose"],
  SCENARIOS.map { |scenario| [scenario.name, scenario.expect_success ? "yes" : "no", scenario.description] }
)
puts

puts "## Knob Summary"
summary_rows = variants.map do |config|
  summary = summarize(all_results.fetch(config.name))
  [
    config.name,
    summary[:p95_ms],
    delta(summary[:p95_ms], baseline_summary[:p95_ms]),
    summary[:max_ms],
    delta(summary[:max_ms], baseline_summary[:max_ms]),
    summary[:unexpected_failures],
    summary[:start_attempts],
    delta(summary[:start_attempts], baseline_summary[:start_attempts]),
    summary[:refreshes],
    delta(summary[:refreshes], baseline_summary[:refreshes]),
    summary[:recovery_starts],
    summary[:forced_recoveries],
    summary[:refresh_timeouts],
    summary[:microphone_start_timeouts]
  ]
end
print_table(
  [
    "knob",
    "p95_ms",
    "p95_delta",
    "max_ms",
    "max_delta",
    "unexpected_failures",
    "starts",
    "start_delta",
    "refreshes",
    "refresh_delta",
    "recovery_starts",
    "forced",
    "refresh_timeouts",
    "mic_timeouts"
  ],
  summary_rows
)
puts

puts "## Baseline Raw Results"
baseline_rows = all_results.fetch(BASELINE.name).map do |result|
  [
    result.scenario,
    result.success ? "success" : "timeout",
    result.time_ms,
    result.normal_starts,
    result.recovery_starts,
    result.refreshes,
    result.forced_recoveries,
    result.refresh_timeouts,
    result.reason
  ]
end
print_table(
  ["scenario", "outcome", "time_ms", "normal", "recovery", "refreshes", "forced", "timeouts", "reason"],
  baseline_rows
)

if options[:details]
  puts
  puts "## Per-Knob Raw Results"
  variants.reject { |config| config.name == BASELINE.name }.each do |config|
    puts
    puts "### #{config.name}"
    rows = all_results.fetch(config.name).map do |result|
      baseline = all_results.fetch(BASELINE.name).find { |base| base.scenario == result.scenario }
      [
        result.scenario,
        result.success ? "success" : "timeout",
        result.time_ms,
        delta(result.time_ms, baseline.time_ms),
        result.normal_starts,
        result.recovery_starts,
        result.refreshes,
        result.forced_recoveries,
        result.refresh_timeouts,
        result.reason
      ]
    end
    print_table(
      ["scenario", "outcome", "time_ms", "delta", "normal", "recovery", "refreshes", "forced", "timeouts", "reason"],
      rows
    )
  end
end
