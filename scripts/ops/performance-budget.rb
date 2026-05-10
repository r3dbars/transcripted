#!/usr/bin/env ruby
# frozen_string_literal: true

require "find"
require "json"
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
MIN_TRANSCRIPTION_SAMPLES = 10
MIN_STARTUP_SAMPLES = 3

options = {
  app_path: REPO_ROOT.join("build/Transcripted.app").to_s,
  events_path: nil,
  max_app_bytes: MAX_APP_BYTES,
  max_resources_bytes: MAX_RESOURCES_BYTES,
  max_transcription_p95_seconds: MAX_TRANSCRIPTION_P95_SECONDS,
  max_transcription_p95_rtf: MAX_TRANSCRIPTION_P95_RTF,
  max_model_ready_p90_seconds: MAX_MODEL_READY_P90_SECONDS,
  max_dictation_fast_start_p95_ms: MAX_DICTATION_FAST_START_P95_MS,
  require_dictation_fast_start_samples: 0
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/ops/performance-budget.rb [options]"
  parser.on("--app PATH", "Path to Transcripted.app") { |path| options[:app_path] = path }
  parser.on("--events PATH", "Optional events.jsonl path for runtime latency budgets") { |path| options[:events_path] = path }
  parser.on("--max-app-mb MB", Integer, "Expanded app size budget") { |mb| options[:max_app_bytes] = mb * 1024 * 1024 }
  parser.on("--max-resources-mb MB", Integer, "Resources directory size budget") { |mb| options[:max_resources_bytes] = mb * 1024 * 1024 }
  parser.on("--max-transcription-p95-s SECONDS", Float, "Dictation transcription p95 budget") { |seconds| options[:max_transcription_p95_seconds] = seconds }
  parser.on("--max-transcription-p95-rtf VALUE", Float, "Dictation transcription p95 RTF budget") { |rtf| options[:max_transcription_p95_rtf] = rtf }
  parser.on("--max-model-ready-p90-s SECONDS", Float, "Launch to model-ready p90 budget") { |seconds| options[:max_model_ready_p90_seconds] = seconds }
  parser.on("--max-dictation-fast-start-p95-ms MS", Float, "Ready-engine dictation fast-start p95 budget") { |ms| options[:max_dictation_fast_start_p95_ms] = ms }
  parser.on("--require-dictation-fast-start-samples N", Integer, "Require at least N fast-start samples in --events logs") { |count| options[:require_dictation_fast_start_samples] = count }
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

def fail_budget!(errors)
  return if errors.empty?

  warn "Performance budget failed:"
  errors.each { |error| warn "- #{error}" }
  exit 1
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

unless model_dirs == [EXPECTED_PARAKEET_MODEL_DIR]
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

    if transcription_elapsed.length < MIN_TRANSCRIPTION_SAMPLES
      errors << "Only #{transcription_elapsed.length} transcription samples, need at least #{MIN_TRANSCRIPTION_SAMPLES}"
    elsif percentile(transcription_elapsed, 0.95) > options[:max_transcription_p95_seconds]
      errors << "Dictation transcription p95 is #{format("%.3fs", percentile(transcription_elapsed, 0.95))}, above #{format("%.3fs", options[:max_transcription_p95_seconds])}"
    end

    if transcription_rtf.length < MIN_TRANSCRIPTION_SAMPLES
      errors << "Only #{transcription_rtf.length} transcription RTF samples, need at least #{MIN_TRANSCRIPTION_SAMPLES}"
    elsif percentile(transcription_rtf, 0.95) > options[:max_transcription_p95_rtf]
      errors << "Dictation transcription p95 RTF is #{format("%.3f", percentile(transcription_rtf, 0.95))}, above #{format("%.3f", options[:max_transcription_p95_rtf])}"
    end

    if startup_durations.length < MIN_STARTUP_SAMPLES
      errors << "Only #{startup_durations.length} launch to model-ready samples, need at least #{MIN_STARTUP_SAMPLES}"
    elsif percentile(startup_durations, 0.90) > options[:max_model_ready_p90_seconds]
      errors << "Launch to model-ready p90 is #{format("%.3fs", percentile(startup_durations, 0.90))}, above #{format("%.3fs", options[:max_model_ready_p90_seconds])}"
    end

    if options[:require_dictation_fast_start_samples].positive?
      if dictation_fast_start_ms.length < options[:require_dictation_fast_start_samples]
        errors << "Only #{dictation_fast_start_ms.length} dictation fast-start samples, need at least #{options[:require_dictation_fast_start_samples]}"
      elsif percentile(dictation_fast_start_ms, 0.95) > options[:max_dictation_fast_start_p95_ms]
        errors << "Dictation fast-start p95 is #{format("%.1fms", percentile(dictation_fast_start_ms, 0.95))}, above #{format("%.1fms", options[:max_dictation_fast_start_p95_ms])}"
      end

      unless fast_start_fallback_events.empty?
        errors << "Found #{fast_start_fallback_events.length} dictation fallback/retry events after the first fast-start sample"
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
      dictation_fast_start_fallback_events: fast_start_fallback_events.length
    }
  end
end

fail_budget!(errors)

puts "Performance budget OK"
puts "Expanded app: #{mib(app_size)}"
puts "Resources: #{mib(resources_size)}"
puts "Parakeet model: #{model_dirs.first}"
puts "Resource icons: #{resource_icons.join(", ")}"
if runtime_summary
  puts "Dictation transcription samples: #{runtime_summary[:transcription_samples]}"
  puts "Dictation transcription p95: #{format("%.3fs", runtime_summary[:transcription_p95])}"
  puts "Dictation transcription p95 RTF: #{format("%.3f", runtime_summary[:transcription_rtf_p95])}"
  puts "Launch model-ready samples: #{runtime_summary[:startup_samples]}"
  puts "Launch to model-ready p90: #{format("%.3fs", runtime_summary[:startup_p90])}"
  puts "Dictation fast-start samples: #{runtime_summary[:dictation_fast_start_samples]}"
  if runtime_summary[:dictation_fast_start_p95]
    puts "Dictation fast-start p95: #{format("%.1fms", runtime_summary[:dictation_fast_start_p95])}"
  end
  puts "Dictation fast-start fallback/retry events: #{runtime_summary[:dictation_fast_start_fallback_events]}"
end
