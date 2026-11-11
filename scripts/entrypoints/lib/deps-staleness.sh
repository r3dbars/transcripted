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
#   dependency_toolchain_digest() — effective package/app compiler identities
#   deps_toolchain_matches_stamp() — both current compiler identities match
#   write_deps_build_stamp(digest, cwd) — stamp a completed, unchanged build

dependency_input_paths() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md" ! -name "AGENTS.md"
    # The digest includes path order; login shells may change the locale.
    } | LC_ALL=C sort
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
    deps_build_stamp_value dependency_inputs_sha256
}

deps_build_stamp_value() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        awk -F= -v field="$1" '$1 == field {
            count++; value = substr($0, index($0, "=") + 1)
        } END { if (count == 1) print value; else exit 1 }' "$DEPS_BUILD_STAMP"
    else
        return 1
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

dependency_package_compiler() {
    # SwiftPM resolves SWIFT_EXEC cwd-first, then PATH for a bare name. A reuse
    # probe models the next fresh generated package, not this repository's cwd.
    # The generated package has no compiler executables of its own. Compilation
    # passes its real package cwd; reuse uses an absent sibling under mktemp's
    # same canonical parent. No previous temporary paths go into the stamp.
    python3 - "${1:-}" "${SWIFT_EXEC:-}" <<'PY'
import os, sys, uuid
try:
    cwd, override = sys.argv[1:]
    if cwd:
        cwd = os.path.realpath(cwd)
    else:
        parent = os.environ.get("TMPDIR", "").removesuffix("/") or "/tmp"
        cwd = os.path.join(os.path.realpath(parent), "transcripted-deps-probe-" + uuid.uuid4().hex)
        if os.path.lexists(cwd):
            raise SystemExit(1)
    def absolute(value):
        return os.path.normpath(value if os.path.isabs(value) else os.path.join(cwd, value))
    def executable(value):
        return os.path.isfile(value) and os.access(value, os.X_OK)
    paths = [absolute(value or ".") for value in os.environ.get("PATH", "").split(os.pathsep)]
    if override:
        candidates = [absolute(override)]
        if "/" not in override:
            candidates += [os.path.join(path, override) for path in paths]
        for candidate in candidates:
            if executable(candidate):
                print(candidate)
                raise SystemExit(0)
    # An unresolved/nonexecutable override is ignored by SwiftPM. Its normal
    # compiler belongs to the PATH-selected Swift driver, not arbitrary swiftc.
    for path in paths:
        candidate = os.path.join(path, "swift")
        if executable(candidate):
            print(candidate)
            raise SystemExit(0)
    raise SystemExit(1)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

dependency_toolchain_digest() {
    (
        set -o pipefail
        local app_version package_version package_compiler digest
        app_version="$(swiftc --version 2>/dev/null)" || return 1
        package_compiler="$(dependency_package_compiler "${1:-}")" || return 1
        package_version="$("$package_compiler" --version 2>/dev/null)" || return 1
        [[ "$app_version" =~ [^[:space:]] ]] && [[ "$package_version" =~ [^[:space:]] ]] || return 1
        if [ "$app_version" = "$package_version" ]; then
            # Same banner as CI's swiftc cache key on the usual shared toolchain.
            digest="$(printf '%s\n' "$app_version" | shasum -a 256 | awk '{print $1}')" || return 1
        else
            # PATH swiftc and SwiftPM's compiler may differ legitimately. Track
            # both without overriding selectors or deciding their compatibility.
            digest="$(printf 'app\0%s\0package\0%s\n' "$app_version" "$package_version" | shasum -a 256 | awk '{print $1}')" || return 1
        fi
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s\n' "$digest"
    )
}

deps_toolchain_matches_stamp() {
    local stamp_digest current_digest
    stamp_digest="$(deps_build_stamp_value swift_toolchain_sha256)" || return 1
    [[ "$stamp_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_digest="$(dependency_toolchain_digest)" || return 1
    [ "$current_digest" = "$stamp_digest" ]
}

write_deps_build_stamp() {
    local expected_toolchain="$1" current_toolchain input_digest
    [[ "$expected_toolchain" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_toolchain="$(dependency_toolchain_digest "${2:-}")" || return 1
    [ "$current_toolchain" = "$expected_toolchain" ] || return 1
    input_digest="$(dependency_input_digest)" || return 1
    [[ "$input_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    {
        printf 'dependency_inputs_sha256=%s\n' "$input_digest"
        printf 'swift_toolchain_sha256=%s\n' "$current_toolchain"
        printf 'built_at_unix=%s\n' "$(date +%s)"
    } > "$DEPS_BUILD_STAMP"
}
