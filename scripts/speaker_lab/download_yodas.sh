#!/usr/bin/env bash
# Download YODAS3 shards (audio tar + metadata parquet) for the speaker lab.
#
#   bash scripts/speaker_lab/download_yodas.sh en 0000 0001
#
# YODAS3 is CC BY 3.0 (espnet/yodas3 on Hugging Face). Everything lands under
# data/eval/yodas3/raw/, which is gitignored. Never commit the audio or anything
# derived from it. Each audio shard is about 8.5 GB. curl -C - resumes partial files.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <lang> <shard> [<shard> ...]   e.g. $0 en 0000 0001" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lang="$1"
shift
root="${YODAS_ROOT:-$repo_root/data/eval/yodas3}"
base="https://huggingface.co/datasets/espnet/yodas3/resolve/main/data/$lang"
mkdir -p "$root/raw/$lang/audio" "$root/raw/$lang/metadata"

for shard in "$@"; do
  if [[ ! "$shard" =~ ^[0-9]{4}$ ]]; then
    echo "shard must be 4 digits, got '$shard'" >&2
    exit 2
  fi
  echo "[yodas] $lang/$shard metadata"
  curl -sSfL -C - --retry 5 -o "$root/raw/$lang/metadata/$shard.parquet" "$base/metadata/$shard.parquet"
  echo "[yodas] $lang/$shard audio (~8.5 GB)"
  curl -sSfL -C - --retry 10 -o "$root/raw/$lang/audio/$shard.tar" "$base/audio/$shard.tar"
done
echo "[yodas] done: $root/raw/$lang"
