#!/bin/bash
# Exercise the real metallib packaging function with an inert metallib file.
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$TEST_ROOT/scripts/entrypoints/lib/bundle-metallib.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-metallib-packaging.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir -p "$fixture/deps-libs" "$fixture/Empty.app/Contents/Resources"
printf 'not really metal\n' > "$fixture/deps-libs/mlx.metallib"
app="$fixture/App.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

bundle_mlx_metallib "$fixture/deps-libs" "$app"

bundled="$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[ -f "$bundled" ] || fail "metallib not at the MLX SwiftPM-bundle path"
cmp -s "$fixture/deps-libs/mlx.metallib" "$bundled" || fail "bundled metallib differs from the deps build"
plutil -lint -s "$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Info.plist" || fail "resource bundle Info.plist is invalid"
[ -z "$(find "$app/Contents/MacOS" -name '*.metallib')" ] || fail "metallib left in Contents/MacOS"

# No deps metallib (a build without Cmlx) is a no-op, not an error.
bundle_mlx_metallib "$fixture/missing" "$fixture/Empty.app"
[ ! -e "$fixture/Empty.app/Contents/Resources/mlx-swift_Cmlx.bundle" ] || fail "created a resource bundle without a metallib"

# A metallib in Contents/MacOS gets signature xattrs, which blocks Sparkle deltas.
for script in scripts/entrypoints/build.sh scripts/entrypoints/build-beta.sh; do
    grep -q 'bundle_mlx_metallib deps-libs "$APP_BUNDLE"' "$TEST_ROOT/$script" || fail "$script doesn't bundle the metallib as a resource"
    if grep -q 'Contents/MacOS/\*\.metallib\|metallib" "$APP_BUNDLE/Contents/MacOS' "$TEST_ROOT/$script"; then
        fail "$script still puts or signs a metallib in Contents/MacOS"
    fi
done

echo "Metallib packaging tests passed."
