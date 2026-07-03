#!/usr/bin/env ruby
# frozen_string_literal: true

require "find"
require "json"
require "open3"
require "optparse"
require "pathname"
require "time"

REPO_ROOT = Pathname.new(__dir__).join("../..").expand_path
EXPECTED_PARAKEET_MODEL_DIR = "parakeet-tdt-0.6b-v3-coreml"
EXPECTED_RESOURCE_ICONS = ["Transcripted.icns"].freeze
MAX_APP_BYTES = 650 * 1024 * 1024
MAX_RESOURCES_BYTES = 520 * 1024 * 1024
MAX_TRANSCRIPTION_P95_SECONDS = 0.5
MAX_TRANSCRIPTION_P95_RTF = 0.05
MAX_MODEL_READY_P90_SECONDS = 30.0
MAX_DICTATION_FAST_START_P95_MS = 250.0
MAX_DICTATION_REQUEST_TO_RECORDING_P95_MS = 250.0
MAX_DICTATION_START_TO_FIRST_SAMPLE_P95_MS = 350.0
MAX_DICTATION_STOP_TO_PASTE_P95_MS = 750.0
MAX_DICTATION_STOP_TO_DONE_P95_MS = 1_000.0
MAX_MEETING_P95_RTF = 0.05
MAX_HOME_RECENT_CAPTURE_AVERAGE_LOAD_MS = 500.0
MAX_HOME_RECENT_CAPTURE_CANCEL_MS = 100.0
MIN_MEETING_DURATION_SECONDS = 30.0
MIN_TRANSCRIPTION_SAMPLES = 10
MIN_STARTUP_SAMPLES = 3
MIN_MEETING_SAMPLES = 10
STOP_LATENCY_STAGE_KEYS = [
  "stop_to_mic_stop_ms",
  "mic_stop_to_decode_start_ms",
  "model_wait_ms",
  "decode_ms",
  "cleanup_ms",
  "paste_ms",
  "auto_enter_ms",
  "save_ms"
].freeze

options = {
  app_path: REPO_ROOT.join("build/Transcripted.app").to_s,
  events_path: nil,
  stats_path: nil,
  max_app_bytes: MAX_APP_BYTES,
  max_resources_bytes: MAX_RESOURCES_BYTES,
  max_transcription_p95_seconds: MAX_TRANSCRIPTION_P95_SECONDS,
  max_transcription_p95_rtf: MAX_TRANSCRIPTION_P95_RTF,
  max_model_ready_p90_seconds: MAX_MODEL_READY_P90_SECONDS,
  max_dictation_fast_start_p95_ms: MAX_DICTATION_FAST_START_P95_MS,
  max_dictation_request_to_recording_p95_ms: MAX_DICTATION_REQUEST_TO_RECORDING_P95_MS,
  max_dictation_start_to_first_sample_p95_ms: MAX_DICTATION_START_TO_FIRST_SAMPLE_P95_MS,
  max_dictation_stop_to_paste_p95_ms: MAX_DICTATION_STOP_TO_PASTE_P95_MS,
  max_dictation_stop_to_done_p95_ms: MAX_DICTATION_STOP_TO_DONE_P95_MS,
  max_meeting_p95_rtf: MAX_MEETING_P95_RTF,
  min_meeting_duration_seconds: MIN_MEETING_DURATION_SECONDS,
  min_transcription_samples: MIN_TRANSCRIPTION_SAMPLES,
  min_meeting_samples: MIN_MEETING_SAMPLES,
  check_home_recent_captures: false,
  max_home_recent_capture_average_load_ms: MAX_HOME_RECENT_CAPTURE_AVERAGE_LOAD_MS,
  max_home_recent_capture_cancel_ms: MAX_HOME_RECENT_CAPTURE_CANCEL_MS,
  require_launch_model_ready_samples: 0,
  require_dictation_fast_start_samples: 0,
  require_dictation_stop_latency_samples: 0,
  events_since: nil,
  stats_since: nil,
  allow_missing_parakeet_model: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/ops/performance-budget.rb [options]"
  parser.on("--app PATH", "Path to Transcripted.app") { |path| options[:app_path] = path }
  parser.on("--events PATH", "Optional events.jsonl path for runtime latency budgets") { |path| options[:events_path] = path }
  parser.on("--stats PATH", "Optional stats.sqlite path for meeting throughput budgets") { |path| options[:stats_path] = path }
  parser.on("--max-app-mb MB", Integer, "Expanded app size budget") { |mb| options[:max_app_bytes] = mb * 1024 * 1024 }
  parser.on("--max-resources-mb MB", Integer, "Resources directory size budget") { |mb| options[:max_resources_bytes] = mb * 1024 * 1024 }
  parser.on("--max-transcription-p95-s SECONDS", Float, "Dictation transcription p95 budget") { |seconds| options[:max_transcription_p95_seconds] = seconds }
  parser.on("--max-transcription-p95-rtf VALUE", Float, "Dictation transcription p95 RTF budget") { |rtf| options[:max_transcription_p95_rtf] = rtf }
  parser.on("--max-model-ready-p90-s SECONDS", Float, "Launch to model-ready p90 budget") { |seconds| options[:max_model_ready_p90_seconds] = seconds }
  parser.on("--max-dictation-fast-start-p95-ms MS", Float, "Ready-engine dictation fast-start p95 budget") { |ms| options[:max_dictation_fast_start_p95_ms] = ms }
  parser.on("--max-dictation-request-to-recording-p95-ms MS", Float, "Dictation request-to-recording p95 budget for strict fresh start proof") { |ms| options[:max_dictation_request_to_recording_p95_ms] = ms }
  parser.on("--max-dictation-start-to-first-sample-p95-ms MS", Float, "Dictation start-to-first-audio-sample p95 budget for strict fresh start proof") { |ms| options[:max_dictation_start_to_first_sample_p95_ms] = ms }
  parser.on("--max-dictation-stop-to-paste-p95-ms MS", Float, "Dictation stop-to-paste p95 budget") { |ms| options[:max_dictation_stop_to_paste_p95_ms] = ms }
  parser.on("--max-dictation-stop-to-done-p95-ms MS", Float, "Dictation stop pipeline p95 budget") { |ms| options[:max_dictation_stop_to_done_p95_ms] = ms }
  parser.on("--max-meeting-p95-rtf VALUE", Float, "Meeting processing p95 real-time-factor budget") { |rtf| options[:max_meeting_p95_rtf] = rtf }
  parser.on("--min-meeting-duration-s SECONDS", Float, "Minimum recording duration for meeting throughput stats") { |seconds| options[:min_meeting_duration_seconds] = seconds }
  parser.on("--min-transcription-samples N", Integer, "Minimum dictation transcription samples to require when --events is provided") { |count| options[:min_transcription_samples] = count }
  parser.on("--min-meeting-samples N", Integer, "Minimum meeting throughput samples to require when --stats is provided") { |count| options[:min_meeting_samples] = count }
  parser.on("--check-home-recent-captures", "Run deterministic Home recent-captures loader budget") { options[:check_home_recent_captures] = true }
  parser.on("--max-home-recent-capture-average-load-ms MS", Float, "Home recent-captures average load budget") { |ms| options[:max_home_recent_capture_average_load_ms] = ms }
  parser.on("--max-home-recent-capture-cancel-ms MS", Float, "Home recent-captures cancellation acknowledgement budget") { |ms| options[:max_home_recent_capture_cancel_ms] = ms }
  parser.on("--require-launch-model-ready-samples N", Integer, "Require at least N launch-to-model-ready samples in --events logs") { |count| options[:require_launch_model_ready_samples] = count }
  parser.on("--require-dictation-fast-start-samples N", Integer, "Require at least N fast-start samples in --events logs") { |count| options[:require_dictation_fast_start_samples] = count }
  parser.on("--require-dictation-stop-latency-samples N", Integer, "Require at least N stop-latency samples in --events logs") { |count| options[:require_dictation_stop_latency_samples] = count }
  parser.on("--events-since ISO8601", "Only score runtime events at or after this timestamp") { |value| options[:events_since] = Time.parse(value) }
  parser.on("--stats-since ISO8601", "Only score meeting stats at or after this timestamp") { |value| options[:stats_since] = Time.parse(value) }
  parser.on("--allow-missing-parakeet-model", "Allow thin builds that download the Parakeet model on first use") { options[:allow_missing_parakeet_model] = true }
end.parse!

def directory_size(path)
  return File.size(path) if File.file?(path)
  return 0 unless File.exist?(path)

  total = 0
  Find.find(path) do |entry|
    next unless File.file?(entry)

    total += File.size(entry)
  end
  total
end

def mib(bytes)
  format("%.1f MiB", bytes.to_f / (1024 * 1024))
end

def percentile(values, quantile)
  sorted = values.sort
  return nil if sorted.empty?

  index = ((sorted.length - 1) * quantile).round
  sorted[index]
end

def latency_stage_summary(events, stage_keys)
  stage_keys.each_with_object({}) do |key, summary|
    values = events
      .map { |event| float_or_nil(event.fetch("context", {})[key]) }
      .compact
    next if values.empty?

    summary[key] = {
      count: values.length,
      p95: percentile(values, 0.95),
      max: values.max
    }
  end
end

def slowest_latency_stage(stage_summary)
  stage_summary.max_by { |_, values| values[:p95] || 0.0 }
end

def parse_events(path)
  events = []
  File.foreach(path) do |line|
    event = JSON.parse(line)
    event["_time"] = Time.parse(event.fetch("timestamp"))
    events << event
  rescue JSON::ParserError, KeyError, ArgumentError
    next
  end
  events
end

def float_or_nil(value)
  Float(value)
rescue TypeError, ArgumentError
  nil
end

def startup_model_ready_durations(events)
  durations = []

  events.each_with_index do |event, index|
    next unless event["event"] == "app_launched"

    launch_time = event["_time"]
    next unless launch_time

    events[(index + 1)..]&.each do |candidate|
      break if candidate["event"] == "app_launched"

      if candidate["event"] == "models_loaded" && candidate["_time"]
        durations << (candidate["_time"] - launch_time)
        break
      end
    end
  end

  durations
end

def meeting_rtf_samples(stats_path, minimum_duration_seconds:, since_time: nil)
  predicates = [
    "duration_seconds >= #{minimum_duration_seconds.to_f}",
    "processing_time_ms > 0"
  ]
  if since_time
    predicates << "created_at >= '#{since_time.utc.iso8601}'"
  end

  sql = <<~SQL
    SELECT duration_seconds, processing_time_ms
    FROM recordings
    WHERE #{predicates.join(" AND ")};
  SQL

  stdout, stderr, status = Open3.capture3("sqlite3", "-separator", "\t", stats_path.to_s, sql)
  unless status.success?
    raise "sqlite3 failed for #{stats_path}: #{stderr.strip}"
  end

  stdout.lines.each_with_object([]) do |line, samples|
    duration_seconds, processing_ms = line.strip.split("\t", 2).map { |value| Float(value) }
    next if duration_seconds <= 0

    samples << (processing_ms / 1000.0) / duration_seconds
  rescue ArgumentError, TypeError
    next
  end
rescue Errno::ENOENT
  raise "sqlite3 is required for --stats checks"
end

def fail_budget!(errors)
  return if errors.empty?

  warn "Performance budget failed:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end

def run_home_recent_capture_benchmark(max_average_load_ms:, max_cancel_ms:)
  command = [
    "scripts/dev/benchmark-home-recent-captures.sh",
    "--max-average-load-ms",
    max_average_load_ms.to_s,
    "--max-cancellation-ms",
    max_cancel_ms.to_s
  ]
  stdout, stderr, status = Open3.capture3(
    { "REPETITIONS" => "5" },
    *command,
    chdir: REPO_ROOT.to_s
  )
  {
    command: command.join(" "),
    stdout: stdout,
    stderr: stderr,
    status: status
  }
end

app_path = Pathname.new(options[:app_path]).expand_path
errors = []

unless app_path.directory?
  fail_budget!(["Missing app bundle: #{app_path}"])
end

resources_path = app_path.join("Contents/Resources")
parakeet_models_path = resources_path.join("parakeet-models")

app_size = directory_size(app_path.to_s)
resources_size = directory_size(resources_path.to_s)

if app_size > options[:max_app_bytes]
  errors << "Expanded app is #{mib(app_size)}, above #{mib(options[:max_app_bytes])}"
end

if resources_size > options[:max_resources_bytes]
  errors << "Resources are #{mib(resources_size)}, above #{mib(options[:max_resources_bytes])}"
end

model_dirs = if parakeet_models_path.directory?
  parakeet_models_path.children.select(&:directory?).map { |path| path.basename.to_s }.sort
else
  []
end

if options[:allow_missing_parakeet_model]
  unless model_dirs.empty? || model_dirs == [EXPECTED_PARAKEET_MODEL_DIR]
    errors << "Expected no Parakeet model directory or #{EXPECTED_PARAKEET_MODEL_DIR.inspect}, found #{model_dirs.inspect}"
  end
elsif model_dirs != [EXPECTED_PARAKEET_MODEL_DIR]
  errors << "Expected one Parakeet model directory #{EXPECTED_PARAKEET_MODEL_DIR.inspect}, found #{model_dirs.inspect}"
end

resource_icons = resources_path.children
  .select { |path| [".icns", ".png"].include?(path.extname.downcase) }
  .map { |path| path.basename.to_s }
  .sort

unless resource_icons == EXPECTED_RESOURCE_ICONS
  errors << "Expected release resource icons #{EXPECTED_RESOURCE_ICONS.inspect}, found #{resource_icons.inspect}"
end

runtime_summary = nil
if options[:events_path]
  events_path = Pathname.new(options[:events_path]).expand_path
  if !events_path.file?
    errors << "Missing events file: #{events_path}"
  else
    events = parse_events(events_path.to_s)
    if options[:events_since]
      events = events.select { |event| event["_time"] && event["_time"] >= options[:events_since] }
    end
    transcription_events = events.select { |event| event["event"] == "transcription_complete" }
    transcription_elapsed = transcription_events
      .map { |event| float_or_nil(event.fetch("context", {})["elapsed_s"]) }
      .compact
    transcription_rtf = transcription_events
      .map { |event| float_or_nil(event.fetch("context", {})["rtf"]) }
      .compact
    startup_durations = startup_model_ready_durations(events)
    dictation_fast_starts = events
      .select { |event| event["event"] == "dictation_recording_fast_start" }
      .map { |event| [event["_time"], float_or_nil(event.fetch("context", {})["start_ms"])] }
      .select { |time, value| time && value }
    dictation_fast_start_ms = dictation_fast_starts.map { |_, value| value }
    first_fast_start_time = dictation_fast_starts.map(&:first).min
    dictation_start_proof_events = if first_fast_start_time
      events.select { |event| event["_time"] && event["_time"] >= first_fast_start_time }
    else
      events
    end
    dictation_request_to_recording_ms = dictation_start_proof_events
      .select { |event| ["dictation_recording_fast_start", "dictation_started_after_wait"].include?(event["event"]) }
      .map { |event| float_or_nil(event.fetch("context", {})["request_to_recording_ms"]) }
      .compact
    dictation_start_to_first_sample_ms = dictation_start_proof_events
      .select { |event| event["event"] == "audio_samples_detected" }
      .map { |event| float_or_nil(event.fetch("context", {})["start_to_first_sample_ms"]) }
      .compact
    fast_start_fallback_events = if first_fast_start_time
      events.select do |event|
        [
          "dictation_fast_start_fell_back_to_wait",
          "dictation_recording_retry",
          "audio_start_deferred"
        ].include?(event["event"]) && event["_time"] && event["_time"] >= first_fast_start_time
      end
    else
      []
    end
    dictation_stop_latency_events = events.select { |event| event["event"] == "dictation_stop_latency_measured" }
    dictation_stop_to_paste_ms = dictation_stop_latency_events
      .map { |event| float_or_nil(event.fetch("context", {})["stop_to_paste_ms"]) }
      .compact
    dictation_stop_to_done_ms = dictation_stop_latency_events
      .map { |event| float_or_nil(event.fetch("context", {})["stop_to_done_ms"]) }
      .compact
    dictation_stop_stage_summary = latency_stage_summary(
      dictation_stop_latency_events,
      STOP_LATENCY_STAGE_KEYS
    )

    if transcription_elapsed.length < options[:min_transcription_samples]
      errors << "Only #{transcription_elapsed.length} transcription samples, need at least #{options[:min_transcription_samples]}"
    elsif !transcription_elapsed.empty? && percentile(transcription_elapsed, 0.95) > options[:max_transcription_p95_seconds]
      errors << "Dictation transcription p95 is #{format("%.3fs", percentile(transcription_elapsed, 0.95))}, above #{format("%.3fs", options[:max_transcription_p95_seconds])}"
    end

    if transcription_rtf.length < options[:min_transcription_samples]
      errors << "Only #{transcription_rtf.length} transcription RTF samples, need at least #{options[:min_transcription_samples]}"
    elsif !transcription_rtf.empty? && percentile(transcription_rtf, 0.95) > options[:max_transcription_p95_rtf]
      errors << "Dictation transcription p95 RTF is #{format("%.3f", percentile(transcription_rtf, 0.95))}, above #{format("%.3f", options[:max_transcription_p95_rtf])}"
    end

    if options[:require_launch_model_ready_samples].positive?
      if startup_durations.length < options[:require_launch_model_ready_samples]
        errors << "Only #{startup_durations.length} launch to model-ready samples, need at least #{options[:require_launch_model_ready_samples]}"
      elsif percentile(startup_durations, 0.90) > options[:max_model_ready_p90_seconds]
        errors << "Launch to model-ready p90 is #{format("%.3fs", percentile(startup_durations, 0.90))}, above #{format("%.3fs", options[:max_model_ready_p90_seconds])}"
      end
    end

    required_fast_start_samples = options[:require_dictation_fast_start_samples]
    if required_fast_start_samples.positive?
      if dictation_fast_start_ms.length < required_fast_start_samples
        errors << "Only #{dictation_fast_start_ms.length} dictation fast-start samples, need at least #{required_fast_start_samples}"
      elsif percentile(dictation_fast_start_ms, 0.95) > options[:max_dictation_fast_start_p95_ms]
        errors << "Dictation fast-start p95 is #{format("%.1fms", percentile(dictation_fast_start_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_fast_start_p95_ms])}"
      end

      if dictation_request_to_recording_ms.length < required_fast_start_samples
        errors << "Only #{dictation_request_to_recording_ms.length} dictation request-to-recording samples, need at least #{required_fast_start_samples}"
      elsif percentile(dictation_request_to_recording_ms, 0.95) > options[:max_dictation_request_to_recording_p95_ms]
        errors << "Dictation request-to-recording p95 is #{format("%.1fms", percentile(dictation_request_to_recording_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_request_to_recording_p95_ms])}"
      end

      if dictation_start_to_first_sample_ms.length < required_fast_start_samples
        errors << "Only #{dictation_start_to_first_sample_ms.length} dictation start-to-first-sample samples, need at least #{required_fast_start_samples}"
      elsif percentile(dictation_start_to_first_sample_ms, 0.95) > options[:max_dictation_start_to_first_sample_p95_ms]
        errors << "Dictation start-to-first-sample p95 is #{format("%.1fms", percentile(dictation_start_to_first_sample_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_start_to_first_sample_p95_ms])}"
      end

      unless fast_start_fallback_events.empty?
        errors << "Found #{fast_start_fallback_events.length} dictation fallback/retry events after the first fast-start sample"
      end
    end

    if options[:require_dictation_stop_latency_samples].positive?
      if dictation_stop_to_paste_ms.length < options[:require_dictation_stop_latency_samples]
        errors << "Only #{dictation_stop_to_paste_ms.length} dictation stop-to-paste samples, need at least #{options[:require_dictation_stop_latency_samples]}"
      elsif percentile(dictation_stop_to_paste_ms, 0.95) > options[:max_dictation_stop_to_paste_p95_ms]
        errors << "Dictation stop-to-paste p95 is #{format("%.1fms", percentile(dictation_stop_to_paste_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_stop_to_paste_p95_ms])}"
      end

      if dictation_stop_to_done_ms.length < options[:require_dictation_stop_latency_samples]
        errors << "Only #{dictation_stop_to_done_ms.length} dictation stop pipeline samples, need at least #{options[:require_dictation_stop_latency_samples]}"
      elsif percentile(dictation_stop_to_done_ms, 0.95) > options[:max_dictation_stop_to_done_p95_ms]
        errors << "Dictation stop pipeline p95 is #{format("%.1fms", percentile(dictation_stop_to_done_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_stop_to_done_p95_ms])}"
      end
    end

    runtime_summary = {
      transcription_samples: transcription_elapsed.length,
      transcription_p95: percentile(transcription_elapsed, 0.95),
      transcription_rtf_p95: percentile(transcription_rtf, 0.95),
      startup_samples: startup_durations.length,
      startup_p90: percentile(startup_durations, 0.90),
      dictation_fast_start_samples: dictation_fast_start_ms.length,
      dictation_fast_start_p95: percentile(dictation_fast_start_ms, 0.95),
      dictation_request_to_recording_samples: dictation_request_to_recording_ms.length,
      dictation_request_to_recording_p95: percentile(dictation_request_to_recording_ms, 0.95),
      dictation_start_to_first_sample_samples: dictation_start_to_first_sample_ms.length,
      dictation_start_to_first_sample_p95: percentile(dictation_start_to_first_sample_ms, 0.95),
      dictation_fast_start_fallback_events: fast_start_fallback_events.length,
      dictation_stop_latency_samples: dictation_stop_latency_events.length,
      dictation_stop_to_paste_p95: percentile(dictation_stop_to_paste_ms, 0.95),
      dictation_stop_to_done_p95: percentile(dictation_stop_to_done_ms, 0.95),
      dictation_stop_stage_summary: dictation_stop_stage_summary,
      dictation_stop_slowest_stage: slowest_latency_stage(dictation_stop_stage_summary),
      events_since: options[:events_since]
    }
  end
end

stats_summary = nil
if options[:stats_path]
  stats_path = Pathname.new(options[:stats_path]).expand_path
  if !stats_path.file?
    errors << "Missing stats database: #{stats_path}"
  else
    begin
      meeting_rtfs = meeting_rtf_samples(
        stats_path,
        minimum_duration_seconds: options[:min_meeting_duration_seconds],
        since_time: options[:stats_since]
      )
      meeting_p95 = percentile(meeting_rtfs, 0.95)

      if meeting_rtfs.length < options[:min_meeting_samples]
        errors << "Only #{meeting_rtfs.length} meeting throughput samples, need at least #{options[:min_meeting_samples]}"
      elsif !meeting_rtfs.empty? && meeting_p95 > options[:max_meeting_p95_rtf]
        errors << "Meeting processing p95 RTF is #{format("%.3f", meeting_p95)}, above #{format("%.3f", options[:max_meeting_p95_rtf])}"
      end

      stats_summary = {
        meeting_samples: meeting_rtfs.length,
        meeting_p95_rtf: meeting_p95,
        minimum_duration_seconds: options[:min_meeting_duration_seconds],
        stats_since: options[:stats_since]
      }
    rescue RuntimeError => error
      errors << error.message
    end
  end
end

home_recent_capture_summary = nil
if options[:check_home_recent_captures]
  result = run_home_recent_capture_benchmark(
    max_average_load_ms: options[:max_home_recent_capture_average_load_ms],
    max_cancel_ms: options[:max_home_recent_capture_cancel_ms]
  )
  home_recent_capture_summary = result
  unless result[:status].success?
    errors << [
      "Home recent-captures benchmark failed",
      result[:stderr].strip,
      result[:stdout].strip
    ].reject(&:empty?).join(": ")
  end
end

fail_budget!(errors)

puts "Performance budget OK"
puts "Expanded app: #{mib(app_size)}"
puts "Resources: #{mib(resources_size)}"
puts "Parakeet model: #{model_dirs.first || "not bundled (runtime download)"}"
puts "Resource icons: #{resource_icons.join(", ")}"
if runtime_summary
  if runtime_summary[:events_since]
    puts "Runtime events since: #{runtime_summary[:events_since].utc.iso8601}"
  end
  puts "Dictation transcription samples: #{runtime_summary[:transcription_samples]}"
  if runtime_summary[:transcription_p95]
    puts "Dictation transcription p95: #{format("%.3fs", runtime_summary[:transcription_p95])}"
  else
    puts "Dictation transcription p95: n/a"
  end
  if runtime_summary[:transcription_rtf_p95]
    puts "Dictation transcription p95 RTF: #{format("%.3f", runtime_summary[:transcription_rtf_p95])}"
  else
    puts "Dictation transcription p95 RTF: n/a"
  end
  puts "Launch model-ready samples: #{runtime_summary[:startup_samples]}"
  if runtime_summary[:startup_p90]
    puts "Launch to model-ready p90: #{format("%.3fs", runtime_summary[:startup_p90])}"
  else
    puts "Launch to model-ready p90: n/a"
  end
  puts "Dictation fast-start samples: #{runtime_summary[:dictation_fast_start_samples]}"
  if runtime_summary[:dictation_fast_start_p95]
    puts "Dictation fast-start p95: #{format("%.1fms", runtime_summary[:dictation_fast_start_p95])}"
  end
  puts "Dictation request-to-recording samples: #{runtime_summary[:dictation_request_to_recording_samples]}"
  if runtime_summary[:dictation_request_to_recording_p95]
    puts "Dictation request-to-recording p95: #{format("%.1fms", runtime_summary[:dictation_request_to_recording_p95])}"
  end
  puts "Dictation start-to-first-sample samples: #{runtime_summary[:dictation_start_to_first_sample_samples]}"
  if runtime_summary[:dictation_start_to_first_sample_p95]
    puts "Dictation start-to-first-sample p95: #{format("%.1fms", runtime_summary[:dictation_start_to_first_sample_p95])}"
  end
  puts "Dictation fast-start fallback/retry events: #{runtime_summary[:dictation_fast_start_fallback_events]}"
  puts "Dictation stop latency samples: #{runtime_summary[:dictation_stop_latency_samples]}"
  if runtime_summary[:dictation_stop_to_paste_p95]
    puts "Dictation stop-to-paste p95: #{format("%.1fms", runtime_summary[:dictation_stop_to_paste_p95])}"
  end
  if runtime_summary[:dictation_stop_to_done_p95]
    puts "Dictation stop pipeline p95: #{format("%.1fms", runtime_summary[:dictation_stop_to_done_p95])}"
  end
  unless runtime_summary[:dictation_stop_stage_summary].empty?
    puts "Dictation stop stage p95s:"
    STOP_LATENCY_STAGE_KEYS.each do |stage|
      summary = runtime_summary[:dictation_stop_stage_summary][stage]
      next unless summary

      puts "  #{stage}: p95=#{format("%.1fms", summary[:p95])} max=#{format("%.1fms", summary[:max])} n=#{summary[:count]}"
    end
  end
  if runtime_summary[:dictation_stop_slowest_stage]
    stage, summary = runtime_summary[:dictation_stop_slowest_stage]
    puts "Dictation stop slowest stage: #{stage} p95=#{format("%.1fms", summary[:p95])}"
  end
end
if stats_summary
  if stats_summary[:stats_since]
    puts "Meeting stats since: #{stats_summary[:stats_since].utc.iso8601}"
  end
  puts "Meeting throughput samples: #{stats_summary[:meeting_samples]}"
  puts "Meeting minimum duration: #{format("%.1fs", stats_summary[:minimum_duration_seconds])}"
  if stats_summary[:meeting_p95_rtf]
    puts "Meeting processing p95 RTF: #{format("%.3f", stats_summary[:meeting_p95_rtf])}"
  else
    puts "Meeting processing p95 RTF: n/a"
  end
end
if home_recent_capture_summary
  puts "Home recent-captures benchmark:"
  puts home_recent_capture_summary[:stdout].strip
end
