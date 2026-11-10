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

# Both release entry points must recognize the owning repo's frozen feed even
# from another cwd or through a path alias. Only this copied fixture is writable.
fixture_repo="$test_root/repo"
caller="$test_root/caller"
mkdir -p "$fixture_repo/scripts/release" "$fixture_repo/config/release" \
    "$fixture_repo/docs" "$fixture_repo/updates" "$caller" "$test_root/file-alias" "$test_root/hard-alias"
cp "$ROOT_DIR/scripts/release/sign-appcast.sh" "$ROOT_DIR/scripts/release/generate-sparkle-appcast.sh" "$fixture_repo/scripts/release/"
cp "$ROOT_DIR/Info.plist" "$fixture_repo/Info.plist"
cp "$feed_dir/appcast.xml" "$fixture_repo/docs/appcast.xml"
cp "$fixture_repo/docs/appcast.xml" "$test_root/frozen-before.xml"
printf '{}\n' > "$fixture_repo/config/release/legacy-appcast-freeze.json"
ln -s "$fixture_repo/docs" "$test_root/directory-alias"
ln -s "$fixture_repo/docs/appcast.xml" "$test_root/file-alias/appcast.xml"
ln "$fixture_repo/docs/appcast.xml" "$test_root/hard-alias/appcast.xml"
frozen_tool="$test_root/frozen-tool"
cat > "$frozen_tool" <<'STUB'
#!/bin/bash
printf 'called\n' > "$FROZEN_TOOL_MARKER"
exit 42
STUB
chmod +x "$frozen_tool"

for entrypoint in sign-appcast.sh generate-sparkle-appcast.sh; do
    for alias in root absolute relative directory file hard; do
        case "$alias" in
            root) run_cwd="$fixture_repo"; target="docs/appcast.xml" ;;
            absolute) run_cwd="$caller"; target="$fixture_repo/docs/appcast.xml" ;;
            relative) run_cwd="$caller"; target="../repo/docs/appcast.xml" ;;
            directory) run_cwd="$caller"; target="$test_root/directory-alias/appcast.xml" ;;
            file) run_cwd="$caller"; target="$test_root/file-alias/appcast.xml" ;;
            hard) run_cwd="$caller"; target="$test_root/hard-alias/appcast.xml" ;;
        esac
        if [ "$entrypoint" = "sign-appcast.sh" ]; then
            argument="$target"
        else
            argument="$fixture_repo/updates"
        fi
        if (cd "$run_cwd" && env SPARKLE_SIGN_TOOL="$frozen_tool" SPARKLE_APPCAST_TOOL="$frozen_tool" \
            SPARKLE_PRIVATE_KEY=fixture-key REPO_APPCAST_PATH="$target" \
            INFO_PLIST_PATH="$fixture_repo/Info.plist" FROZEN_TOOL_MARKER="$test_root/tool-called" \
            bash "$fixture_repo/scripts/release/$entrypoint" "$argument") > "$test_root/frozen-out.txt" 2>&1; then
            fail "$entrypoint/$alias accepted the frozen feed"
        fi
        [ ! -e "$test_root/tool-called" ] || fail "$entrypoint/$alias invoked a release tool"
        grep -q 'frozen legacy feed' "$test_root/frozen-out.txt" || fail "$entrypoint/$alias missed the frozen-feed refusal"
        cmp -s "$test_root/frozen-before.xml" "$fixture_repo/docs/appcast.xml" || fail "$entrypoint/$alias changed the frozen feed"
    done
done

echo "Sparkle appcast signing tests passed"
