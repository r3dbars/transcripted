#!/bin/bash
# Transcripted Inference Server — first-time setup
# Run once: ./setup.sh
# Then the app will auto-launch the server on startup.

set -e

echo "🧠 Transcripted Local AI Setup"
echo "================================"

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "❌ Python 3 not found. Install via: brew install python"
    exit 1
fi

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "✅ Python $PYTHON_VERSION"

# Create venv
VENV_DIR="$(dirname "$0")/.venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "📦 Installing dependencies (this takes a few minutes first time)..."
pip install -q --upgrade pip
pip install -q -r "$(dirname "$0")/requirements.txt"

echo ""
echo "📥 Pre-downloading models (parakeet-tdt-1.1b + sortformer)..."
echo "   This downloads ~2.5GB and only happens once."
python3 -c "
import nemo.collections.asr as nemo_asr
print('Downloading Parakeet...')
nemo_asr.models.ASRModel.from_pretrained('nvidia/parakeet-tdt-1.1b')
print('Downloading Sortformer...')
from nemo.collections.asr.models import SortformerEncLabelModel
SortformerEncLabelModel.from_pretrained('nvidia/sortformer-diarizer-4spk-v1')
print('✅ Models cached')
"

echo ""
echo "✅ Setup complete!"
echo "   The Transcripted app will auto-start the server on launch."
echo "   To test manually: $VENV_DIR/bin/python server.py"
