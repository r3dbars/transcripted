# shellcheck shell=bash
# Shared dependency-staleness-check functions for the deps build pipeline.
# Sourced by build-deps.sh, build.sh, and run-integration-smoke.sh, which had
# each carried a byte-for-byte copy of these six functions (verified
# identical before this extraction — see the PR description for the diff
# proof). Every one of those scripts needs to answer the same question
# before doing expensive work: "is deps-libs/.build-deps-stamp still fresh
# for the current Sources/TranscriptedCore + Package.swift + build-deps.sh
# inputs?" A valid matching sha256 digest takes precedence over mtimes, so
# touched-but-unchanged inputs remain fresh. Callers retain conservative
# stale checks when the stamp is missing, invalid, or no longer matches.
#
# NOTE: scripts/entrypoints/build-beta.sh intentionally does NOT source this
# file. It carries its own narrower copy (dependency_input_listing,
# newest_dependency_input, deps_build_stamp_info only — inlined rather than
# split into a separate dependency_input_paths, and without a sort) and does
# only the mtime check, not the digest check the other three scripts also
# do. That is a genuine behavior divergence from the other three copies
# (confirmed during the 2026-08 build-infra refactor), not a copy/paste
# accident, so it was left alone rather than folded in here — folding it in
# would change beta-build staleness detection, which is out of scope for a
# behavior-preserving refactor.
#
# Inputs (must be set by the sourcing script before calling these):
#   DEPS_BUILD_STAMP — path to the deps-libs/.build-deps-stamp file
#
# Outputs: functions only (no arrays to export).
#   dependency_input_paths()    — sorted list of paths that feed the deps build
#   dependency_input_listing()  — "<mtime>\t<path>" rows for those inputs
#   dependency_input_digest()   — sha256 digest across those inputs' contents
#   newest_dependency_input()   — the single newest "<mtime>\t<path>" row
#   deps_build_stamp_info()     — "<mtime>\t<path>" row for the stamp file itself
#   deps_build_stamp_digest()   — the digest recorded inside the stamp file
#   dependency_inputs_match_stamp() — valid current content matches the stamp

dependency_input_paths() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md" ! -name "AGENTS.md"
    } | sort
}

dependency_input_listing() {
    dependency_input_paths | while IFS= read -r path; do
        [ -e "$path" ] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done
}

dependency_input_digest() {
    # Callers commonly use this inside a conditional, where errexit does not
    # stop a failed per-file hash. Preserve every pipeline/iteration failure.
    (
        set -o pipefail
        dependency_input_paths | while IFS= read -r path; do
            [ -f "$path" ] || continue
            shasum -a 256 "$path" || exit 1
        done | shasum -a 256 | awk '{print $1}'
    )
}

newest_dependency_input() {
    dependency_input_listing | awk 'NR == 1 || $1 > max { max = $1; line = $0 } END { if (line != "") print line }'
}

deps_build_stamp_info() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        printf '%s\t%s\n' "$(stat -f '%m' "$DEPS_BUILD_STAMP")" "$DEPS_BUILD_STAMP"
    fi
}

deps_build_stamp_digest() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        awk -F= '$1 == "dependency_inputs_sha256" {
            count++; value = substr($0, index($0, "=") + 1)
        } END { if (count == 1) print value; else exit 1 }' "$DEPS_BUILD_STAMP"
    fi
}

dependency_inputs_match_stamp() {
    local stamp_digest current_digest
    stamp_digest="$(deps_build_stamp_digest)" || return 1
    [[ "$stamp_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_digest="$(dependency_input_digest)" || return 1
    [[ "$current_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "$current_digest" = "$stamp_digest" ]
}
