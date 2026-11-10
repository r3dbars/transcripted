#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/entrypoints/lib/deps-staleness.sh"
fixture_parent="${TMPDIR:-/tmp}"
fixture_root="$(mktemp -d "$fixture_parent/transcripted-deps-toolchain.XXXXXX")"
cleanup() {
    local status=$?
    if ! python3 - "$fixture_root" "$fixture_parent" <<'PY'
import pathlib, re, shutil, sys
root, parent = map(pathlib.Path, sys.argv[1:])
if root.is_symlink() or root.resolve().parent != parent.resolve() or not re.fullmatch(r"transcripted-deps-toolchain\.[A-Za-z0-9]{6}", root.name):
    raise SystemExit("Refusing cleanup outside the owned toolchain fixture")
shutil.rmtree(root)
PY
    then status=1; fi
    exit "$status"
}
trap cleanup EXIT
cd "$fixture_root"
mkdir -p bin deps-libs Sources/TranscriptedCore scripts/entrypoints
printf 'synthetic package\n' > Package.swift
printf 'synthetic input\n' > Sources/TranscriptedCore/Input.swift
printf 'synthetic builder\n' > scripts/entrypoints/build-deps.sh
DEPS_BUILD_STAMP="$fixture_root/deps-libs/.build-deps-stamp"
real_shasum="$(command -v shasum)"
export real_shasum
unset SWIFT_EXEC SWIFT_EXEC_MANIFEST DEVELOPER_DIR TOOLCHAINS SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
export APP_VERSION=compiler-A PACKAGE_VERSION=compiler-A OVERRIDE_VERSION=compiler-C
export APP_STATUS=0 PACKAGE_STATUS=0 OVERRIDE_STATUS=0 HASH_STATUS=0
cat > bin/swiftc <<'SH'
#!/bin/bash
[ "$#" = 1 ] && [ "$1" = --version ] || exit 91
printf '%s\n' "$APP_VERSION"
exit "$APP_STATUS"
SH
cat > bin/swift <<'SH'
#!/bin/bash
[ "$#" = 1 ] && [ "$1" = --version ] || exit 91
printf '%s\n' "$PACKAGE_VERSION"
exit "$PACKAGE_STATUS"
SH
cat > 'bin/override compiler' <<'SH'
#!/bin/bash
[ "$#" = 1 ] && [ "$1" = --version ] || exit 91
printf '%s\n' "$OVERRIDE_VERSION"
exit "$OVERRIDE_STATUS"
SH
cat > bin/shasum <<'SH'
#!/bin/bash
"$real_shasum" "$@" || exit $?
exit "$HASH_STATUS"
SH
chmod +x bin/*
export PATH="$fixture_root/bin:$PATH"
checks=0
pass() { checks=$((checks + 1)); }
expect_match() {
    if ! deps_toolchain_matches_stamp; then echo "FAIL: $1" >&2; exit 1; fi
    pass
}
expect_stale() {
    if deps_toolchain_matches_stamp; then echo "FAIL: $1" >&2; exit 1; fi
    pass
}
write_current() {
    local identity
    identity="$(dependency_toolchain_digest "${1:-}")"
    write_deps_build_stamp "$identity" "${1:-}"
}
expect_write_rejected() {
    cp "$DEPS_BUILD_STAMP" before-stamp
    if write_deps_build_stamp "$1"; then echo 'FAIL: invalid build completion stamped ready' >&2; exit 1; fi
    cmp before-stamp "$DEPS_BUILD_STAMP"
    pass
}

same_identity="$(dependency_toolchain_digest)"
ci_identity="$(printf '%s\n' "$APP_VERSION" | "$real_shasum" -a 256 | awk '{print $1}')"
[ "$same_identity" = "$ci_identity" ] || { echo 'FAIL: shared compiler identity differs from CI banner hash' >&2; exit 1; }
pass
write_current
expect_match 'unchanged package and app compilers match the written stamp'
dependency_inputs_match_stamp || { echo 'FAIL: toolchain writer lost the content digest' >&2; exit 1; }
pass
APP_VERSION=compiler-B
expect_stale 'changing only app compiler invalidates reuse'
write_current
expect_match 'different but stable package/app compilers can be stamped'
PACKAGE_VERSION=compiler-B
expect_stale 'changing only package compiler invalidates reuse'
APP_VERSION=compiler-A PACKAGE_VERSION=compiler-A
write_current
before_build="$(dependency_toolchain_digest)"
APP_VERSION=compiler-B
expect_write_rejected "$before_build"
APP_VERSION=compiler-A

export SWIFT_EXEC="$fixture_root/bin/override compiler"
write_current
expect_match 'quoted SWIFT_EXEC compiler is the package identity'
PACKAGE_STATUS=9
expect_match 'SWIFT_EXEC prevents querying the unrelated PATH package compiler'
PACKAGE_STATUS=0
OVERRIDE_VERSION=compiler-D
expect_stale 'changing SWIFT_EXEC compiler invalidates reuse'
OVERRIDE_VERSION=compiler-C APP_VERSION=compiler-B
expect_stale 'app compiler still participates when SWIFT_EXEC is set'
APP_VERSION=compiler-A OVERRIDE_STATUS=9
expect_stale 'failed override version query is not a fingerprint'
OVERRIDE_STATUS=0
unset SWIFT_EXEC
write_current
for side in APP PACKAGE; do
    if [ "$side" = APP ]; then APP_STATUS=9; else PACKAGE_STATUS=9; fi
    expect_stale 'failed compiler query cannot reuse a stamp despite valid output'
    expect_write_rejected "$same_identity"
    APP_STATUS=0 PACKAGE_STATUS=0
    if [ "$side" = APP ]; then APP_VERSION=''; else PACKAGE_VERSION=''; fi
    expect_stale 'empty successful compiler output is not an identity'
    if [ "$side" = APP ]; then APP_VERSION=$' \t\n'; else PACKAGE_VERSION=$' \t\n'; fi
    expect_stale 'whitespace-only compiler output is not an identity'
    APP_VERSION=compiler-A PACKAGE_VERSION=compiler-A
done
HASH_STATUS=9
expect_stale 'failed hash cannot reuse a stamp despite a correct digest on stdout'
expect_write_rejected "$same_identity"
HASH_STATUS=0
write_current
SWIFT_EXEC="$fixture_root/missing compiler" expect_match 'unresolved override falls back as SwiftPM does'
printf 'not executable\n' > 'nonexecutable compiler'
SWIFT_EXEC="$fixture_root/nonexecutable compiler" expect_match 'nonexecutable override falls back as SwiftPM does'

# A real generated package and a future absent sibling share the same parent.
# Only the fake selectors below can run; none points to an installed compiler.
package_parent="$fixture_root/package-parent"
actual_package="$package_parent/actual"
future_package="$package_parent/future"
mkdir -p "$actual_package"
cp 'bin/override compiler' "$package_parent/external compiler"
absolute_override="$(SWIFT_EXEC="$package_parent/external compiler" dependency_toolchain_digest)"
actual_relative="$(SWIFT_EXEC='../external compiler' dependency_toolchain_digest "$actual_package")"
future_relative="$(SWIFT_EXEC='../external compiler' dependency_toolchain_digest "$future_package")"
[ "$actual_relative" = "$absolute_override" ] || { echo 'FAIL: actual package relative override resolved incorrectly' >&2; exit 1; }
pass
[ "$future_relative" = "$absolute_override" ] || { echo 'FAIL: fresh sibling changed escaped compiler identity' >&2; exit 1; }
pass
SWIFT_EXEC='../external compiler' write_current "$actual_package"
TMPDIR="$package_parent" SWIFT_EXEC='../external compiler' expect_match 'reader fresh sibling matches actual package compiler'

cp 'bin/override compiler' "$actual_package/swiftc"
cwd_first="$(SWIFT_EXEC=swiftc dependency_toolchain_digest "$actual_package")"
future_bare="$(SWIFT_EXEC=swiftc dependency_toolchain_digest "$future_package")"
[ "$cwd_first" = "$absolute_override" ] || { echo 'FAIL: bare override did not prefer package cwd' >&2; exit 1; }
pass
[ "$future_bare" = "$same_identity" ] || { echo 'FAIL: absent fresh cwd did not fall back to PATH override' >&2; exit 1; }
pass

original_fixture_path="$PATH"
mkdir -p app-only default-driver "$actual_package/relative-driver"
cp bin/swiftc bin/shasum app-only/
cp bin/swift default-driver/
cp 'bin/override compiler' "$actual_package/relative-driver/swift"
export PATH="$fixture_root/app-only:relative-driver:$fixture_root/default-driver:/usr/bin:/bin:/usr/sbin:/sbin"
actual_driver="$(dependency_toolchain_digest "$actual_package")"
future_driver="$(dependency_toolchain_digest "$future_package")"
[ "$actual_driver" = "$absolute_override" ] || { echo 'FAIL: relative PATH driver did not resolve in package cwd' >&2; exit 1; }
pass
[ "$future_driver" = "$same_identity" ] || { echo 'FAIL: absent fresh relative PATH did not reach fake default driver' >&2; exit 1; }
pass
cp "$actual_package/relative-driver/swift" "$actual_package/swift"
export PATH="$fixture_root/app-only:.:$fixture_root/default-driver:/usr/bin:/bin:/usr/sbin:/sbin"
[ "$(dependency_toolchain_digest "$actual_package")" = "$absolute_override" ] || { echo 'FAIL: dot PATH driver lost package cwd' >&2; exit 1; }
pass
[ "$(dependency_toolchain_digest "$future_package")" = "$same_identity" ] || { echo 'FAIL: dot PATH selected repository cwd for a future package' >&2; exit 1; }
pass
export PATH="$original_fixture_path"
[ ! -e "$future_package" ] || { echo 'FAIL: resolver created its hypothetical package cwd' >&2; exit 1; }
pass

printf 'dependency_inputs_sha256=%s\n' "$(dependency_input_digest)" > "$DEPS_BUILD_STAMP"
expect_stale 'legacy stamp without toolchain identity requires rebuild'
for bad in '' invalid "$same_identity=trailing" " $same_identity" "$same_identity "; do
    printf 'swift_toolchain_sha256=%s\n' "$bad" > "$DEPS_BUILD_STAMP"
    expect_stale 'malformed toolchain field cannot authorize reuse'
done
printf 'swift_toolchain_sha256=%s\n%s\n' "${same_identity:0:32}" "${same_identity:32}" > "$DEPS_BUILD_STAMP"
expect_stale 'split-line toolchain identity is rejected'
printf 'swift_toolchain_sha256=%s\nswift_toolchain_sha256=%s\n' "$same_identity" "$same_identity" > "$DEPS_BUILD_STAMP"
expect_stale 'duplicate toolchain identity is rejected'
rm "$DEPS_BUILD_STAMP"
expect_stale 'missing stamp cannot authorize reuse'
echo "PASS: $checks dependency toolchain contracts"
