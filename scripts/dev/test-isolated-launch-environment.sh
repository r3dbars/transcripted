#!/bin/bash
# Compile the real automation gate and QA environment adapter. No app launch,
# preferences access, native permissions or capture-library access.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

environment_fixture_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
environment_fixture_uuid="$(/usr/bin/uuidgen)"
if [[ ! "$environment_fixture_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "Automation environment fixture could not create an owned run identity." >&2
    exit 1
fi
environment_fixture_leaf="transcripted-environment-contract-$environment_fixture_uuid"
environment_fixture_root="$environment_fixture_parent/$environment_fixture_leaf"
mkdir -m 700 "$environment_fixture_root"

cleanup_environment_fixture() {
    local result=$?
    trap - EXIT
    local canonical_root
    if [ -L "$environment_fixture_root" ] || [ ! -d "$environment_fixture_root" ]; then
        echo "Automation environment fixture refused cleanup of an unowned run root." >&2
        exit 1
    fi
    if ! canonical_root="$(cd "$environment_fixture_root" && pwd -P)"; then
        echo "Automation environment fixture could not validate its cleanup root." >&2
        exit 1
    fi
    if [ "$canonical_root" != "$environment_fixture_parent/$environment_fixture_leaf" ] || \
       [ "$(basename "$canonical_root")" != "$environment_fixture_leaf" ] || \
       [ "$(dirname "$canonical_root")" != "$environment_fixture_parent" ]; then
        echo "Automation environment fixture refused cleanup outside its owned parent." >&2
        exit 1
    fi
    if ! rm -rf -- "$environment_fixture_root"; then
        echo "Automation environment fixture cleanup failed." >&2
        exit 1
    fi
    exit "$result"
}
trap cleanup_environment_fixture EXIT


mkdir "$environment_fixture_root/tmp" "$environment_fixture_root/module-cache"
export TMPDIR="$environment_fixture_root/tmp/"
cat > "$environment_fixture_root/Contract.swift" <<'SWIFT'
import Foundation
@main enum Contract {
    static func main() {
        var environment = ["TRANSCRIPTED_AUTOMATED_HARNESS": "0", "__CFBundleIdentifier": "parent.fixture"]
        applyIsolatedLaunchEnvironment(&environment, isolatedHome: URL(fileURLWithPath: "/owned/fixture-home"))
        let active = AutomatedLaunchEnvironment.isActive(environment: environment)
        print(active ? "automated" : "interactive")
        exit(active ? 0 : 1)
    }
}
SWIFT
xcrun swiftc -parse-as-library -module-cache-path "$environment_fixture_root/module-cache" \
    Sources/Support/AutomatedLaunchEnvironment.swift \
    Tools/TranscriptedQA/Sources/TranscriptedQA/Utilities/IsolatedLaunchEnvironment.swift \
    "$environment_fixture_root/Contract.swift" -o "$environment_fixture_root/contract"
"$environment_fixture_root/contract"
