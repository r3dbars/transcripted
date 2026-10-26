#!/bin/bash
# Guards scripts/release/sign-appcast.sh with a stub sign_update. No Sparkle
# tools, signing keys, or network are involved.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/release/sign-appcast.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-sparkle-signing.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Stand-in for sign_update: records stdin, then appends a signature block like
# the real tool does (STUB_MODE=nosig leaves the feed unsigned).
stub="$test_root/sign_update"
cat > "$stub" <<'STUB'
#!/bin/bash
feed="${@: -1}"
cat > "$(dirname "$feed")/stub-stdin.txt" || true
if [[ " $* " == *" --verify "* ]]; then
    [ "${STUB_MODE:-}" = "badverify" ] && exit 1
    exit 0
fi
[ "${STUB_MODE:-}" = "nosig" ] && exit 0
printf '<!-- sparkle-signatures:\nedSignature: stub\nlength: 1\n-->\n' >> "$feed"
STUB
chmod +x "$stub"

feed_dir="$test_root/feed"
mkdir -p "$feed_dir"
cat > "$feed_dir/appcast.xml" <<'XML'
<?xml version='1.0' encoding='utf-8'?>
<rss version="2.0"><channel><title>t</title></channel></rss>
XML

env SPARKLE_SIGN_TOOL="$stub" SPARKLE_PRIVATE_KEY=test-private-key \
    bash "$SCRIPT" "$feed_dir/appcast.xml" > "$test_root/out.txt" 2>&1 || { cat "$test_root/out.txt" >&2; fail "signing failed"; }
[ "$(grep -c 'sparkle-signatures' "$feed_dir/appcast.xml")" = "1" ] || fail "feed should carry exactly one signature block"
[ "$(cat "$feed_dir/stub-stdin.txt")" = "test-private-key" ] || fail "private key was not sent on stdin"
if grep -q "test-private-key" "$test_root/out.txt"; then
    fail "private key leaked into output"
fi

# Signing twice replaces the block instead of stacking a second one.
env SPARKLE_SIGN_TOOL="$stub" SPARKLE_PRIVATE_KEY=test-private-key \
    bash "$SCRIPT" "$feed_dir/appcast.xml" > /dev/null 2>&1 || fail "re-signing failed"
[ "$(grep -c 'sparkle-signatures' "$feed_dir/appcast.xml")" = "1" ] || fail "re-signing stacked signature blocks"

# A tool that silently leaves the feed unsigned must fail the step.
if env SPARKLE_SIGN_TOOL="$stub" SPARKLE_PRIVATE_KEY=k STUB_MODE=nosig \
    bash "$SCRIPT" "$feed_dir/appcast.xml" > "$test_root/nosig.txt" 2>&1; then
    fail "an unsigned result was accepted"
fi
grep -q "did not embed" "$test_root/nosig.txt" || fail "missing the unsigned-feed message"

# A signature that does not read back with the key must fail the step.
if env SPARKLE_SIGN_TOOL="$stub" SPARKLE_PRIVATE_KEY=k STUB_MODE=badverify \
    bash "$SCRIPT" "$feed_dir/appcast.xml" > "$test_root/badverify.txt" 2>&1; then
    fail "a feed whose signature does not verify was accepted"
fi
grep -q "does not verify" "$test_root/badverify.txt" || fail "missing the verify-failure message"

# Only the release asset name is accepted.
cp "$feed_dir/appcast.xml" "$feed_dir/other.xml"
if env SPARKLE_SIGN_TOOL="$stub" SPARKLE_PRIVATE_KEY=k bash "$SCRIPT" "$feed_dir/other.xml" > /dev/null 2>&1; then
    fail "a file not named appcast.xml was accepted"
fi

echo "Sparkle appcast signing tests passed"
