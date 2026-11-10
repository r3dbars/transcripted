#!/bin/bash
# Fetch the reviewed publisher bytes; never extract or install an unchecked archive.
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo 'Usage: install-mcp-publisher.sh <destination executable>' >&2
    exit 64
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
version=v1.8.8
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) architecture=arm64 ;;
    Darwin/x86_64) architecture=amd64 ;;
    *) echo 'Unsupported MCP publisher platform.' >&2; exit 1 ;;
esac
asset="mcp-publisher_darwin_$architecture.tar.gz"
checksums="$repo_root/.github/mcp-publish-tools/mcp-publisher-$version.sha256"
expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$checksums")"
if ! [[ "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    echo 'Missing or invalid pinned MCP publisher checksum.' >&2
    exit 1
fi
temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
work="$(mktemp -d "$temp_root/transcripted-mcp-publisher.XXXXXX")"
cleanup() {
    if [[ "$(dirname "$work")" != "$temp_root" || "$(basename "$work")" != transcripted-mcp-publisher.* || -L "$work" ]]; then
        echo 'Refusing cleanup outside the owned publisher temporary directory.' >&2
        return 1
    fi
    rm -rf "$work"
}
trap cleanup EXIT
curl -fsSL "https://github.com/modelcontextprotocol/registry/releases/download/$version/$asset" -o "$work/$asset"
(cd "$work" && printf '%s  %s\n' "$expected" "$asset" | shasum -a 256 -c -)
tar -xzf "$work/$asset" -C "$work" mcp-publisher
install -m 755 "$work/mcp-publisher" "$1"
