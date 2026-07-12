#!/bin/bash
# check-name-variants-parity.sh — drift guard for the byte-for-byte-mirrored
# nickname table.
#
# `Tools/TranscriptedMCP/Sources/TranscriptedMCP/NameVariants.swift` and
# `Sources/TranscriptedCore/Speaker/SpeakerProfileMerger.swift` each keep an
# independent copy of the same ~70-entry `[String: Set<String>]` nickname table
# (Core must not depend on the Tools packages, and the standalone MCP server has
# no compile-time dependency on Core, so the two cannot share a module). Both
# files say "any edit here MUST be mirrored there" in a comment, but nothing
# enforced it before this check. This extracts both dictionary literals,
# normalizes whitespace, and diffs them — a future edit to one table without the
# other fails CI instead of silently drifting (codebase audit 2026-07-08).
#
# Wired into .github/workflows/repo-hygiene.yml alongside
# scripts/dev/check-duplicate-declarations.py.
#
# Usage:
#   scripts/dev/check-name-variants-parity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

MCP_FILE="Tools/TranscriptedMCP/Sources/TranscriptedMCP/NameVariants.swift"
CORE_FILE="Sources/TranscriptedCore/Speaker/SpeakerProfileMerger.swift"

for f in "$MCP_FILE" "$CORE_FILE"; do
    if [ ! -f "$f" ]; then
        echo "check-name-variants-parity: expected file not found: $f" >&2
        echo "(the mirrored nickname table may have moved — update this script's paths)" >&2
        exit 1
    fi
done

# Extract the entries of the `[String: Set<String>]` dictionary literal: every
# line strictly between the `... : [String: Set<String>] = [` opener and the
# `]` that closes it (matched by itself, once leading/trailing whitespace is
# stripped, so indentation differences between the two files don't matter here).
extract_table() {
    local file="$1"
    awk '
        /: \[String: Set<String>\] = \[/ { capture=1; next }
        capture {
            trimmed = $0
            gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
            if (trimmed == "]") { capture = 0; next }
            print trimmed
        }
    ' "$file"
}

mcp_table="$(extract_table "$MCP_FILE")"
core_table="$(extract_table "$CORE_FILE")"

if [ -z "$mcp_table" ]; then
    echo "check-name-variants-parity: could not find the nickname table in $MCP_FILE" >&2
    echo "(expected a line matching ': [String: Set<String>] = [' — did the declaration change shape?)" >&2
    exit 1
fi

if [ -z "$core_table" ]; then
    echo "check-name-variants-parity: could not find the nickname table in $CORE_FILE" >&2
    echo "(expected a line matching ': [String: Set<String>] = [' — did the declaration change shape?)" >&2
    exit 1
fi

if [ "$mcp_table" != "$core_table" ]; then
    echo "check-name-variants-parity: FAILED" >&2
    echo "" >&2
    echo "$MCP_FILE and $CORE_FILE keep byte-for-byte-mirrored nickname tables," >&2
    echo "but they no longer match. Edit both together (each file says so in a" >&2
    echo "comment above the table) or this check will keep failing." >&2
    echo "" >&2
    echo "Diff (MCP < / Core >):" >&2
    diff <(echo "$mcp_table") <(echo "$core_table") >&2 || true
    exit 1
fi

echo "check-name-variants-parity: OK ($(echo "$mcp_table" | wc -l | tr -d ' ') entries match between $MCP_FILE and $CORE_FILE)"
