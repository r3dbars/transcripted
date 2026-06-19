#!/usr/bin/env python3
"""
Convert the PRETRAINED Alibaba 3D-Speaker ERes2Net speaker-embedding model
(modelscope iic/speech_eres2net_sv_en_voxceleb_16k) to Apple CoreML, and verify
the converted model reproduces the PyTorch embeddings on real AMI audio.

This is the decisive follow-up to scripts/convert_campplus_coreml.py: CAM++
FAILED CoreML parity (cosine ~0.23) due to PRETRAINED-weight-specific tiny-
variance BatchNorm (running_var min ~4.7e-6 -> ~260x amplification of converter
rounding through its deep DenseTDNN stack). ERes2Net converted at cosine 1.0 on
RANDOM weights, but that does NOT rule out the same pretrained-weight failure.
So here we test the ACTUAL pretrained ERes2Net.

Pipeline (mirrors modelscope SpeakerVerificationERes2Net.__extract_feature):
  raw 16k audio -> kaldi fbank(80) -> per-utterance mean-subtract over time
  -> ERes2Net nn.Module -> 192-dim embedding.
We convert ONLY fbank-in -> embedding-out (host computes fbank, same as CAM++).

ReLU patch: ERes2Net uses a custom ReLU = nn.Hardtanh(0, 20). coremltools has an
int/float dtype bug lowering hardtanh's clip bounds -> conversion errors. We swap
those for standard nn.ReLU before tracing (the cap at 20 effectively never fires;
the official 3D-Speaker ONNX export does the same). This does NOT change outputs.

Outputs under scripts/out/:
  - eres2net_pretrained.mlpackage
  - parity printed to stdout (PASS/FAIL + min/mean cosine)
"""
import os
import sys
import numpy as np
import torch
import torch.nn as nn
import torchaudio
import torchaudio.compliance.kaldi as Kaldi

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_eres2net_sv_en_voxceleb_16k")
CKPT = os.path.join(MODEL_DIR, "pretrained_eres2net.ckpt")
AMI_WAV = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "ami", "audio", "ES2002a.Mix-Headset.wav")
EXAMPLES = os.path.join(MODEL_DIR, "examples")
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT_DIR, exist_ok=True)
MLPACKAGE = os.path.join(OUT_DIR, "eres2net_pretrained.mlpackage")

FEAT_DIM = 80
EMB_DIM = 192
CHANNELS = 32
N_FRAMES = 300          # fixed trace length (~3s at 10ms hop)
SR = 16000


def build_torch_model(apply_relu_patch=True):
    from modelscope.models.audio.sv.ERes2Net import ERes2Net
    m = ERes2Net(feat_dim=FEAT_DIM, embed_dim=EMB_DIM, m_channels=CHANNELS)
    sd = torch.load(CKPT, map_location="cpu")
    miss, unexp = m.load_state_dict(sd, strict=True)
    print(f"[info] load_state_dict strict=True: missing={len(miss)} unexpected={len(unexp)}")
    m.eval()
    if apply_relu_patch:
        n = _patch_hardtanh(m)
        print(f"[info] patched {n} Hardtanh->ReLU modules for CoreML export")
    m.eval()
    return m


def _patch_hardtanh(module):
    n = 0
    for name, child in module.named_children():
        if isinstance(child, nn.Hardtanh):
            setattr(module, name, nn.ReLU())
            n += 1
        else:
            n += _patch_hardtanh(child)
    return n


def fbank_from_audio(wav_1d):
    """Mirror modelscope ERes2Net feature extraction exactly."""
    feat = Kaldi.fbank(wav_1d.unsqueeze(0), num_mel_bins=FEAT_DIM)
    feat = feat - feat.mean(dim=0, keepdim=True)
    return feat  # (T, 80)


def load_segment(path, start_s, dur_s):
    wav, sr = torchaudio.load(path)
    if sr != SR:
        wav = torchaudio.functional.resample(wav, sr, SR)
    wav = wav[0]
    a = int(start_s * SR)
    b = int((start_s + dur_s) * SR)
    return wav[a:b].contiguous()


def load_full(path):
    wav, sr = torchaudio.load(path)
    if sr != SR:
        wav = torchaudio.functional.resample(wav, sr, SR)
    return wav[0].contiguous()


def fixed_frames(feat, n):
    T = feat.shape[0]
    if T >= n:
        return feat[:n]
    return torch.cat([feat, torch.zeros(n - T, feat.shape[1])], dim=0)


def cosine(a, b):
    a = a.flatten().astype(np.float64)
    b = b.flatten().astype(np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def dirsize(p):
    if os.path.isfile(p):
        return os.path.getsize(p) / (1024 * 1024)
    return sum(os.path.getsize(os.path.join(d, f))
               for d, _, fs in os.walk(p) for f in fs) / (1024 * 1024)


def emb_full_eager(model, path):
    """Full-length embedding (no fixed crop) for speaker sanity check."""
    feat = fbank_from_audio(load_full(path)).unsqueeze(0)
    with torch.no_grad():
        return model(feat).numpy()[0]


def main():
    import coremltools as ct
    print(f"[info] torch {torch.__version__}, coremltools {ct.__version__}")

    # Reference model: NO relu patch (pristine), for parity reference + BN probe.
    print("[step] loading PRETRAINED ERes2Net (pristine) ...")
    ref_model = build_torch_model(apply_relu_patch=False)

    # ---- BN running_var probe (the CAM++ failure signature) ----
    bn_mins = []
    for name, mod in ref_model.named_modules():
        if isinstance(mod, (nn.BatchNorm1d, nn.BatchNorm2d)):
            rv = mod.running_var.detach().numpy()
            bn_mins.append((name, float(rv.min()), float(rv.max()), mod.eps))
    global_min = min(b[1] for b in bn_mins)
    worst = min(bn_mins, key=lambda b: b[1])
    print(f"[bn] {len(bn_mins)} BatchNorm layers")
    print(f"[bn] global min running_var = {global_min:.3e}  "
          f"(worst layer: {worst[0]}, 1/sqrt(var+eps) = "
          f"{1.0/np.sqrt(worst[1]+worst[3]):.1f}x)")
    print(f"[bn] CAM++ comparison: CAM++ min was 4.7e-6 (~260x) -> caused FAIL")

    # ---- PyTorch speaker sanity ----
    print("[step] PyTorch speaker sanity (example clips + AMI) ...")
    w1 = os.path.join(EXAMPLES, "speaker1_a_en_16k.wav")
    w2 = os.path.join(EXAMPLES, "speaker1_b_en_16k.wav")
    w3 = os.path.join(EXAMPLES, "speaker2_a_en_16k.wav")
    have_examples = all(os.path.exists(w) for w in (w1, w2, w3))
    if have_examples:
        e1 = emb_full_eager(ref_model, w1)
        e2 = emb_full_eager(ref_model, w2)
        e3 = emb_full_eager(ref_model, w3)
        print(f"[sanity] example spk1_a vs spk1_b (SAME): {cosine(e1,e2):.4f}")
        print(f"[sanity] example spk1_a vs spk2_a (DIFF): {cosine(e1,e3):.4f}")
    # AMI same-vs-diff: two clips from the same recording's early region tend to
    # share dominant speaker; just report a couple cross-segment cosines.
    a = emb_full_eager(ref_model, AMI_WAV)
    seg_a = fbank_from_audio(load_segment(AMI_WAV, 60.0, 4.0)).unsqueeze(0)
    with torch.no_grad():
        ea = ref_model(seg_a).numpy()[0]
    print(f"[sanity] AMI full vs AMI 60s+4s segment: {cosine(a,ea):.4f}")

    # ---- Build patched model for CoreML, verify patch is output-neutral ----
    print("[step] applying ReLU patch + verifying output-neutral ...")
    patched = build_torch_model(apply_relu_patch=True)
    example = torch.randn(1, N_FRAMES, FEAT_DIM)
    with torch.no_grad():
        ref_out = ref_model(example).numpy()
        patched_out = patched(example).numpy()
    patch_cos = cosine(ref_out, patched_out)
    print(f"[info] patched vs pristine PyTorch cosine: {patch_cos:.6f} "
          f"(should be ~1.0; cap@20 rarely fires)")

    # ---- Trace + convert ----
    print("[step] torch.jit.trace + coremltools.convert (mlprogram) ...")
    traced = torch.jit.trace(patched, example)
    traced.eval()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="fbank", shape=(1, N_FRAMES, FEAT_DIM),
                              dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.save(MLPACKAGE)
    sz = dirsize(MLPACKAGE)
    print(f"[ok] saved {MLPACKAGE}  ({sz:.2f} MB)")

    # ---- Parity on real AMI clips ----
    print("[step] parity on real AMI clips (PyTorch vs CoreML, identical fbank) ...")
    segments = [(60.0, 4.0), (120.0, 3.5), (200.0, 5.0), (300.0, 4.0),
                (450.0, 3.0), (600.0, 4.5)]
    cosines = []
    for i, (st, du) in enumerate(segments):
        feat = fixed_frames(fbank_from_audio(load_segment(AMI_WAV, st, du)),
                            N_FRAMES).unsqueeze(0)
        # PyTorch reference uses the PRISTINE model (patch is output-neutral, but
        # be strict and compare CoreML against the unmodified model).
        with torch.no_grad():
            pt = ref_model(feat).numpy()
        out = mlmodel.predict({"fbank": feat.numpy().astype(np.float32)})
        k = "embedding" if "embedding" in out else list(out.keys())[0]
        cm = np.asarray(out[k])
        c = cosine(pt, cm)
        maxabs = float(np.max(np.abs(pt.flatten() - cm.flatten())))
        cosines.append(c)
        print(f"  seg{i} [{st:.0f}s+{du:.1f}s]: cosine={c:.6f} maxabsdiff={maxabs:.5f}")

    mn, mean = min(cosines), float(np.mean(cosines))
    print(f"\n[summary] cosine over {len(cosines)} segs: min={mn:.6f} mean={mean:.6f}")
    verdict = "PASS" if mn > 0.99 else ("PARTIAL" if mn > 0.90 else "FAIL")
    print(f"[verdict] {verdict} | min cosine {mn:.6f} | mean {mean:.6f} | "
          f"size {sz:.2f} MB | BN min running_var {global_min:.3e} | "
          f"compute_units=ALL")
    return verdict, mn, mean, sz, global_min


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\n[verdict] FAIL — conversion/parity blocked: {type(e).__name__}: {e}")
        sys.exit(1)
