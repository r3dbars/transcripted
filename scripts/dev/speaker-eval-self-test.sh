#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
exec Tools/SpeakerEvalHarness/.build/debug/speaker-eval-harness autoeval-self-test
