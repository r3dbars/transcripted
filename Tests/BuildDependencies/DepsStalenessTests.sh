#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/entrypoints/lib/deps-staleness.sh"
fixture_parent="${TMPDIR:-/tmp}"
fixture_root="$(mktemp -d "$fixture_parent/transcripted-deps-staleness.XXXXXX")"
cleanup() {
    local status=$?
    if ! python3 - "$fixture_root" "$fixture_parent" <<'PY'
import pathlib, re, shutil, sys
root, parent = map(pathlib.Path, sys.argv[1:])
if root.is_symlink() or root.resolve().parent != parent.resolve() or not re.fullmatch(r"transcripted-deps-staleness\.[A-Za-z0-9]{6}", root.name):
    raise SystemExit("Refusing cleanup outside the owned staleness fixture")
shutil.rmtree(root)
PY
    then status=1; fi
    exit "$status"
}
trap cleanup EXIT
cd "$fixture_root"
mkdir -p Sources/TranscriptedCore scripts/entrypoints deps-libs bin
printf 'synthetic package\n' > Package.swift
printf 'synthetic build script\n' > scripts/entrypoints/build-deps.sh
printf 'first input\n' > Sources/TranscriptedCore/Input.swift
DEPS_BUILD_STAMP="$fixture_root/deps-libs/.build-deps-stamp"
real_shasum="$(command -v shasum)"
export real_shasum
checks=0
expect_fresh() {
    if ! dependency_inputs_match_stamp; then echo "FAIL: $1" >&2; exit 1; fi
    checks=$((checks + 1))
}
expect_stale() {
    if dependency_inputs_match_stamp; then echo "FAIL: $1" >&2; exit 1; fi
    checks=$((checks + 1))
}
write_stamp() {
    printf 'dependency_inputs_sha256=%s\nbuilt_at_unix=100\n' "$(dependency_input_digest)" > "$DEPS_BUILD_STAMP"
}
set_times() {
    python3 - "$1" "$2" <<'PY'
import os, pathlib, sys
source_time, stamp_time = map(int, sys.argv[1:])
for p in [pathlib.Path("Package.swift"), pathlib.Path("scripts/entrypoints/build-deps.sh"), *pathlib.Path("Sources/TranscriptedCore").glob("*")]:
    os.utime(p, (source_time, source_time))
os.utime("deps-libs/.build-deps-stamp", (stamp_time, stamp_time))
PY
}

write_stamp
set_times 200 100
expect_fresh 'matching digest rescues newer input mtimes'
set_times 100 200
expect_fresh 'matching digest accepts older input mtimes'
printf 'changed bytes\n' > Sources/TranscriptedCore/Input.swift
set_times 100 200
expect_stale 'changed bytes stay stale despite older mtimes'
set_times 200 100
expect_stale 'changed bytes with newer mtimes stay stale'
write_stamp
mv Sources/TranscriptedCore/Input.swift Sources/TranscriptedCore/Renamed.swift
expect_stale 'renamed inputs change the digest'
write_stamp
rm Sources/TranscriptedCore/Renamed.swift
expect_stale 'deleted inputs change the digest'
rm "$DEPS_BUILD_STAMP"
expect_stale 'missing stamp is stale'
printf 'built_at_unix=100\n' > "$DEPS_BUILD_STAMP"
expect_stale 'legacy stamp without digest is stale'
digest="$(dependency_input_digest)"
for bad in '' not-a-digest "$digest=trailing" " $digest" "$digest "; do
    printf 'dependency_inputs_sha256=%s\n' "$bad" > "$DEPS_BUILD_STAMP"
    expect_stale 'malformed digest cannot authorize reuse'
done
printf 'dependency_inputs_sha256=%s\n%s\n' "${digest:0:32}" "${digest:32}" > "$DEPS_BUILD_STAMP"
expect_stale 'split-line digest is stale'
printf 'dependency_inputs_sha256=%s\ndependency_inputs_sha256=%s\n' "$digest" "$digest" > "$DEPS_BUILD_STAMP"
expect_stale 'duplicate digest fields are stale'

write_stamp
cat > bin/shasum <<'SH'
#!/usr/bin/env bash
# An early per-file failure must survive later successful hashes and awk.
if [[ "${3:-}" == Package.swift ]]; then "$real_shasum" "$@"; exit 9; fi
exec "$real_shasum" "$@"
SH
chmod +x bin/shasum
PATH="$fixture_root/bin:$PATH" expect_stale 'failed per-file hash cannot authorize reuse'
cat > bin/shasum <<'SH'
#!/usr/bin/env bash
if [[ "$#" == 3 ]]; then exec "$real_shasum" "$@"; fi
"$real_shasum" "$@"
exit 9
SH
PATH="$fixture_root/bin:$PATH" expect_stale 'failed aggregate hash cannot authorize reuse'
echo "PASS: $checks dependency freshness contracts"
