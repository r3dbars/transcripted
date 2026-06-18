#!/bin/bash
# Embedding bake-off: re-extract embeddings for the AMI dump segments with alternative
# models, all 6 codec arms (measurement only; venv .venv_emb). Idempotent (skips arms
# already at 32 dumps). Writes data/eval/ami_<arm>__<model>/dumps/.
set -uo pipefail
cd "$(dirname "$0")/.."
. .venv_emb/bin/activate
MODELS="${MODELS:-ecapa wavlm xvect}"
ARMS="${ARMS:-clean opus24k opus16k opus12k opus8k g711u}"
echo "### bakeoff start | models='$MODELS' arms='$ARMS'"
for model in $MODELS; do
  for arm in $ARMS; do
    out="data/eval/ami_${arm}__${model}/dumps"
    n=$(ls "$out"/*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -ge 32 ]; then echo "### skip $arm/$model (have $n)"; continue; fi
    echo "### extract $arm / $model"
    python scripts/extract_embeddings.py --arm "$arm" --model "$model" 2>&1 \
      | grep -vE "Warning|warn|deprecat|backend|NotOpenSSL|urllib3|Fetching|Downloading" | tail -1
  done
done
echo "### BAKEOFF DONE (models=$MODELS)"
