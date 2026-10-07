#!/usr/bin/env bash
# Measures Save my writing's secret scrubber (WritingSecretScrubber):
#   - recall on the labelled corpus (Tests/Fixtures/writing-secret-corpus.json),
#     known misses included, and changes to its ordinary texts;
#   - false positives on text that has no secrets: this repo's docs (as Notes),
#     Swift sources (as VS Code), shell scripts (as Terminal) and commit
#     messages (as Slack), cut into entry-sized chunks.
#
#   bash scripts/dev/measure-writing-scrubber.sh           # tables
#   bash scripts/dev/measure-writing-scrubber.sh --show    # plus every changed line (stderr)
#   bash scripts/dev/measure-writing-scrubber.sh --counts-only <writing folder>
#       numbers only for real day files; never prints their text.
#
# Local only. Builds a throwaway binary under a temp dir.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
work="$(mktemp -d "${TMPDIR:-/tmp}/writing-scrubber-measure.XXXXXX")"
trap 'rm -rf "$work"' EXIT

swiftc -O \
    Sources/TranscriptedWriting/Core/Text/SecretRules.swift \
    Sources/TranscriptedWriting/Core/Text/WritingSecretScrubber.swift \
    Sources/TranscriptedWriting/Core/Text/WritingSecretScrubber+Prompts.swift \
    scripts/dev/writing-scrubber-measure/main.swift \
    -o "$work/measure"

if [[ "${1:-}" == "--counts-only" ]]; then
    TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$work/measure" --counts-only "${2:?writing folder}"
    exit 0
fi

git ls-files 'docs/*.md' '*.md' | sort -u > "$work/docs.txt"
# The two rule files are catalogues of example secrets in their doc comments.
git ls-files 'Sources/*.swift' 'Tools/*.swift' \
    | grep -v -e 'Core/Text/WritingSecretScrubber.swift' -e 'Core/Text/WritingSecretScrubber+Prompts.swift' -e 'Core/Text/SecretRules.swift' > "$work/swift.txt"
git ls-files '*.sh' > "$work/scripts.txt"
mkdir -p "$work/log"
git log -n 3000 --format='%B%n' > "$work/log/commits.txt"
echo "$work/log/commits.txt" > "$work/commits.txt"

TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$work/measure" Tests/Fixtures/writing-secret-corpus.json "$@" \
    --sweep "Docs (Markdown) as Notes" com.apple.Notes "$work/docs.txt" \
    --sweep "Swift sources as VS Code" com.microsoft.VSCode "$work/swift.txt" \
    --sweep "Shell scripts as Terminal" com.apple.Terminal "$work/scripts.txt" \
    --sweep "Commit messages as Slack" com.tinyspeck.slackmacgap "$work/commits.txt"
