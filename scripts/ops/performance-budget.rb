#!/usr/bin/env ruby
# frozen_string_literal: true

require "find"
require "optparse"
require "pathname"

REPO_ROOT = Pathname.new(__dir__).join("../..").expand_path
EXPECTED_PARAKEET_MODEL_DIR = "parakeet-tdt-0.6b-v3-coreml"
EXPECTED_RESOURCE_ICONS = ["Transcripted.icns"].freeze
MAX_APP_BYTES = 650 * 1024 * 1024
MAX_RESOURCES_BYTES = 520 * 1024 * 1024

options = {
  app_path: REPO_ROOT.join("build/Transcripted.app").to_s,
  max_app_bytes: MAX_APP_BYTES,
  max_resources_bytes: MAX_RESOURCES_BYTES
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/ops/performance-budget.rb [options]"
  parser.on("--app PATH", "Path to Transcripted.app") { |path| options[:app_path] = path }
  parser.on("--max-app-mb MB", Integer, "Expanded app size budget") { |mb| options[:max_app_bytes] = mb * 1024 * 1024 }
  parser.on("--max-resources-mb MB", Integer, "Resources directory size budget") { |mb| options[:max_resources_bytes] = mb * 1024 * 1024 }
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

fail_budget!(errors)

puts "Performance budget OK"
puts "Expanded app: #{mib(app_size)}"
puts "Resources: #{mib(resources_size)}"
puts "Parakeet model: #{model_dirs.first}"
puts "Resource icons: #{resource_icons.join(", ")}"
