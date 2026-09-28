#!/usr/bin/env bash
# One command on an Apple Silicon Mac:
#
#   bash scripts/stt-shootout/run.sh              # full hour-long test, every model
#   bash scripts/stt-shootout/run.sh --minutes 3  # quick check that every model runs
#
# Installs uv (Python manager) into ~/.local/bin if it's missing, then runs
# shootout.py with Python 3.12. Everything lands in ~/stt-shootout; the
# report is ~/stt-shootout/runs/<run>/report.md. Extra flags pass through
# (see: bash scripts/stt-shootout/run.sh --help).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "The shootout measures Apple Silicon speed, so it only runs on an Apple Silicon Mac." >&2
  echo "(For a Linux dry run of the plumbing: python3 $here/shootout.py --self-test)" >&2
  exit 1
fi

export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "Installing uv (Python manager) into ~/.local/bin..." >&2
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >&2
fi

# Quiet the Hugging Face client; keep the shootout out of the real app log.
export HF_HUB_DISABLE_TELEMETRY=1
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
export PYTHONWARNINGS="ignore::SyntaxWarning"
# Python packages and uv's own Python live under ~/stt-shootout too, so
# deleting that folder removes everything the shootout downloaded.
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/stt-shootout/uv-cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$HOME/stt-shootout/uv-python}"

exec uv run --quiet --no-project --python 3.12 \
  --with "yt-dlp[default,deno]" --with "jiwer==4.0.0" --with "whisper-normalizer==0.1.12" \
  python "$here/shootout.py" "$@"
