#!/usr/bin/env python3
"""Rebuild Moondream's Parakeet Ultra as a NeMo checkpoint.

Parakeet Ultra (https://huggingface.co/moondream/parakeet-ultra, CC-BY-4.0) is
a post-trained nvidia/parakeet-tdt-0.6b-v3 with the same architecture and
tokenizer, published in Hugging Face Transformers format. FluidAudio's Core ML
converter (FluidInference/mobius) reads NeMo checkpoints, so this script:

1. loads the stock nvidia/parakeet-tdt-0.6b-v3 NeMo model at a pinned commit,
2. renames Ultra's Transformers weight names back to NeMo's (the inverse of
   transformers' models/parakeet/convert_nemo_to_hf.py),
3. refuses to continue unless every NeMo weight is covered with a matching
   shape and the architecture numbers in Ultra's config match,
4. transcribes one clip with both models as a sanity check, and
5. saves parakeet-ultra.nemo plus build-info.json for the packaging step.

Both upstream models are fetched at an exact Hugging Face commit. Unset
revisions resolve to the current commit, and build-info.json records the
commits and the sha256 of the downloaded weights, so a build can be repeated
(pass them back via --revision/--base-revision/--expect-*-sha256; install.sh
does this from pins.env).

Run it inside mobius's parakeet-tdt-v3-0.6b/coreml uv environment (install.sh
does this); it needs nemo_toolkit, torch, safetensors and huggingface_hub.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

BASE_MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
ULTRA_MODEL_ID = "moondream/parakeet-ultra"

# Inverse of transformers' NEMO_TO_HF_WEIGHT_MAPPING + NEMO_TDT_WEIGHT_MAPPING.
# Applied in order; every pattern is anchored so none can rewrite another's output.
HF_TO_NEMO = [
    (r"^encoder\.subsampling\.layers\.", "encoder.pre_encode.conv."),
    (r"^encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"^encoder\.encode_positions\.", "encoder.pos_enc."),
    (r"^(encoder\.layers\.\d+)\.conv\.norm\.", r"\1.conv.batch_norm."),
    (r"\.relative_k_proj\.", ".linear_pos."),
    (r"\.q_proj\.", ".linear_q."),
    (r"\.k_proj\.", ".linear_k."),
    (r"\.v_proj\.", ".linear_v."),
    (r"\.o_proj\.", ".linear_out."),
    (r"\.bias_([uv])$", r".pos_bias_\1"),
    (r"^decoder\.embedding\.", "decoder.prediction.embed."),
    (r"^decoder\.lstm\.", "decoder.prediction.dec_rnn.lstm."),
    (r"^encoder_projector\.", "joint.enc."),
    (r"^decoder\.decoder_projector\.", "joint.pred."),
    (r"^joint\.head\.", "joint.joint_net.2."),
]

# NeMo state entries Ultra does not (and need not) carry: the mel filterbank
# and window are fixed buffers shared with v3, and BatchNorm step counters are
# training bookkeeping.
NOT_REQUIRED_FROM_ULTRA = (
    re.compile(r"(^|\.)featurizer\.(fb|window)$"),
    re.compile(r"\.num_batches_tracked$"),
)


def hf_key_to_nemo(key: str) -> str:
    for pattern, replacement in HF_TO_NEMO:
        key = re.sub(pattern, replacement, key)
    return key


def is_required(nemo_key: str) -> bool:
    return not any(p.search(nemo_key) for p in NOT_REQUIRED_FROM_ULTRA)


def normalize_words(text: str) -> list[str]:
    return re.sub(r"[^\w\s']", " ", text.lower()).split()


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    prev = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, start=1):
        cur = [i]
        for j, hyp_word in enumerate(hypothesis, start=1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref_word != hyp_word)))
        prev = cur
    return prev[-1] / len(reference)


def check_config(ultra_config: dict, asr_model) -> None:
    cfg = asr_model.cfg
    encoder = ultra_config.get("encoder_config", {})
    expected = {
        "encoder hidden size": (encoder.get("hidden_size"), int(cfg.encoder.d_model)),
        "encoder layers": (encoder.get("num_hidden_layers"), int(cfg.encoder.n_layers)),
        "attention heads": (encoder.get("num_attention_heads"), int(cfg.encoder.n_heads)),
        "mel bins": (encoder.get("num_mel_bins"), int(cfg.encoder.feat_in)),
        "decoder hidden size": (ultra_config.get("decoder_hidden_size"), int(asr_model.decoder.pred_hidden)),
        "decoder layers": (ultra_config.get("num_decoder_layers"), int(asr_model.decoder.pred_rnn_layers)),
        "vocabulary incl. blank": (ultra_config.get("vocab_size"), int(asr_model.tokenizer.vocab_size) + 1),
        "TDT durations": (ultra_config.get("durations"), list(cfg.decoding.durations)),
    }
    mismatches = [f"{name}: Ultra {ultra} vs v3 {v3}" for name, (ultra, v3) in expected.items() if ultra != v3]
    if mismatches:
        sys.exit("Ultra's config does not match parakeet-tdt-0.6b-v3:\n  " + "\n  ".join(mismatches))
    print("Config matches parakeet-tdt-0.6b-v3.")


def check_tokenizer(tokenizer_path: Path, asr_model) -> None:
    """Ultra claims v3's tokenizer; token ids must line up exactly."""
    data = json.loads(tokenizer_path.read_text())
    vocab = data.get("model", {}).get("vocab")
    if isinstance(vocab, list):
        ultra_pieces = [entry[0] if isinstance(entry, list) else entry for entry in vocab]
    elif isinstance(vocab, dict):
        by_id = sorted(vocab.items(), key=lambda item: item[1])
        ultra_pieces = [piece for piece, _ in by_id]
    else:
        sys.exit("Could not read Ultra's tokenizer.json vocabulary; refusing to guess the token mapping.")

    sp = asr_model.tokenizer.tokenizer
    v3_pieces = [sp.id_to_piece(i) for i in range(int(asr_model.tokenizer.vocab_size))]
    if ultra_pieces[: len(v3_pieces)] != v3_pieces:
        first = next(
            (i for i, (a, b) in enumerate(zip(ultra_pieces, v3_pieces)) if a != b),
            min(len(ultra_pieces), len(v3_pieces)),
        )
        sys.exit(f"Ultra's tokenizer differs from v3's at token {first}; the v3 vocabulary files would mislabel words.")
    print(f"Tokenizer matches v3 ({len(v3_pieces)} tokens).")


def transplant(asr_model, ultra_state: dict) -> dict:
    import torch

    nemo_state = asr_model.state_dict()
    mapped: dict[str, "torch.Tensor"] = {}
    unused: list[str] = []
    for hf_key, tensor in ultra_state.items():
        nemo_key = hf_key_to_nemo(hf_key)
        if nemo_key in nemo_state:
            mapped[nemo_key] = tensor
        else:
            unused.append(hf_key)

    missing = sorted(k for k in nemo_state if is_required(k) and k not in mapped)
    if missing:
        preview = "\n  ".join(missing[:25])
        sys.exit(
            f"{len(missing)} NeMo weights have no Ultra counterpart; the name mapping is out of date.\n  {preview}"
        )

    wrong_shape = [
        f"{k}: Ultra {tuple(mapped[k].shape)} vs v3 {tuple(nemo_state[k].shape)}"
        for k in mapped
        if tuple(mapped[k].shape) != tuple(nemo_state[k].shape)
    ]
    if wrong_shape:
        sys.exit("Shape mismatches between Ultra and v3:\n  " + "\n  ".join(wrong_shape[:25]))

    merged = dict(nemo_state)
    for key, tensor in mapped.items():
        merged[key] = tensor.to(dtype=nemo_state[key].dtype)
    # Count before loading: state_dict() tensors share storage with the live
    # parameters, so after load_state_dict they already hold Ultra's values.
    changed = sum(1 for k in mapped if not torch.equal(merged[k], nemo_state[k]))
    asr_model.load_state_dict(merged, strict=True)

    print(f"Loaded {len(mapped)} Ultra tensors into v3 ({changed} differ from stock v3).")
    if unused:
        # Moondream's checkpoint carries extras (e.g. a voice-activity head)
        # that the v3 graph FluidAudio runs has no place for.
        print(f"Dropped {len(unused)} Ultra-only tensors, e.g. {', '.join(sorted(unused)[:5])}")
    if changed == 0:
        sys.exit("Every Ultra tensor equals stock v3; this is not Parakeet Ultra.")
    return {"tensors_loaded": len(mapped), "tensors_changed": changed, "tensors_dropped": sorted(unused)}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_sha256(label: str, path: Path, expected: str | None) -> str:
    actual = sha256_of(path)
    if expected and actual != expected.strip().lower():
        sys.exit(
            f"{label} checksum mismatch, refusing to build.\n"
            f"  file:     {path}\n"
            f"  expected: {expected.strip().lower()}\n"
            f"  got:      {actual}\n"
            "The pinned commit's file changed or the download is corrupt. Delete it from the Hugging Face "
            "cache and retry, or update the pin in scripts/models/parakeet-ultra/pins.env if the change "
            "is intended."
        )
    print(f"{label} sha256 {actual}" + (" (matches pin)" if expected else ""))
    return actual


def resolve_revision(api, repo_id: str, revision: str | None) -> str:
    """The exact commit SHA to fetch; an unset revision means the repo's current commit."""
    if revision:
        return revision
    sha = api.model_info(repo_id).sha
    if not sha:
        sys.exit(f"Hugging Face did not report a commit for {repo_id}; pass the revision explicitly.")
    return sha


def download_base_nemo(api, revision: str) -> Path:
    """The single .nemo file in nvidia/parakeet-tdt-0.6b-v3 at `revision`.

    NeMo's from_pretrained can't pin a commit, so fetch the file directly.
    """
    from huggingface_hub import hf_hub_download

    nemo_files = [f for f in api.list_repo_files(BASE_MODEL_ID, revision=revision) if f.endswith(".nemo")]
    if len(nemo_files) != 1:
        sys.exit(
            f"Expected exactly one .nemo file in {BASE_MODEL_ID} @ {revision}, found "
            f"{len(nemo_files)}: {', '.join(nemo_files) or 'none'}. Refusing to guess which one is v3."
        )
    return Path(hf_hub_download(BASE_MODEL_ID, nemo_files[0], revision=revision))


def transcribe_text(asr_model, audio: Path) -> str:
    result = asr_model.transcribe([str(audio)], batch_size=1, verbose=False)
    if isinstance(result, tuple):
        result = result[0]
    first = result[0]
    return getattr(first, "text", first)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sanity-audio", type=Path, required=True, help="A short 16 kHz English clip")
    parser.add_argument("--revision", default=None,
                        help=f"{ULTRA_MODEL_ID} commit to fetch (default: its current commit)")
    parser.add_argument("--base-revision", default=None,
                        help=f"{BASE_MODEL_ID} commit to fetch (default: its current commit)")
    parser.add_argument("--expect-ultra-sha256", default=None,
                        help="Stop unless Ultra's model.safetensors has this sha256")
    parser.add_argument("--expect-base-sha256", default=None,
                        help=f"Stop unless {BASE_MODEL_ID}'s .nemo file has this sha256")
    args = parser.parse_args()

    import nemo.collections.asr as nemo_asr
    import torch
    from huggingface_hub import HfApi, hf_hub_download
    from safetensors.torch import load_file

    args.output_dir.mkdir(parents=True, exist_ok=True)

    api = HfApi()
    revision = resolve_revision(api, ULTRA_MODEL_ID, args.revision)
    base_revision = resolve_revision(api, BASE_MODEL_ID, args.base_revision)

    print(f"Fetching {ULTRA_MODEL_ID} @ {revision}")
    files = {
        name: Path(hf_hub_download(ULTRA_MODEL_ID, name, revision=revision))
        for name in ("config.json", "tokenizer.json", "model.safetensors")
    }
    ultra_sha256 = verify_sha256("Ultra model.safetensors", files["model.safetensors"], args.expect_ultra_sha256)

    print(f"Fetching {BASE_MODEL_ID} @ {base_revision}")
    base_nemo = download_base_nemo(api, base_revision)
    base_sha256 = verify_sha256(f"{BASE_MODEL_ID} {base_nemo.name}", base_nemo, args.expect_base_sha256)

    print(f"Loading {BASE_MODEL_ID} (NeMo)")
    asr_model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(str(base_nemo), map_location="cpu")
    asr_model.eval()

    check_config(json.loads(files["config.json"].read_text()), asr_model)
    check_tokenizer(files["tokenizer.json"], asr_model)

    print("Transcribing the sanity clip with stock v3")
    v3_text = transcribe_text(asr_model, args.sanity_audio)

    stats = transplant(asr_model, load_file(str(files["model.safetensors"])))
    asr_model.eval()

    print("Transcribing the sanity clip with Ultra")
    with torch.inference_mode():
        ultra_text = transcribe_text(asr_model, args.sanity_audio)
    difference = word_error_rate(normalize_words(v3_text), normalize_words(ultra_text))
    print(f"  v3:    {v3_text}\n  Ultra: {ultra_text}\n  word difference: {difference:.1%}")
    # A retrained model disagrees on a few words. A broken weight mapping
    # produces gibberish, which differs on most of them.
    if not ultra_text.strip() or difference > 0.35:
        sys.exit("Ultra's transcript is far from v3's on a clean clip; the conversion is broken, not installing it.")

    nemo_path = args.output_dir / "parakeet-ultra.nemo"
    asr_model.save_to(str(nemo_path))
    build_info = {
        "model": ULTRA_MODEL_ID,
        "revision": revision,
        "safetensors_sha256": ultra_sha256,
        "base_model": BASE_MODEL_ID,
        "base_revision": base_revision,
        "base_nemo_file": base_nemo.name,
        "base_nemo_sha256": base_sha256,
        "license": "CC-BY-4.0",
        "sanity_clip_word_difference_vs_v3": round(difference, 4),
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **stats,
    }
    (args.output_dir / "build-info.json").write_text(json.dumps(build_info, indent=2) + "\n")
    print(f"Wrote {nemo_path}")


if __name__ == "__main__":
    main()
