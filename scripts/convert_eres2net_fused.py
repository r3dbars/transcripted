#!/usr/bin/env python3
"""
Convert the PRETRAINED Alibaba 3D-Speaker ERes2Net speaker-embedding model
(modelscope iic/speech_eres2net_sv_en_voxceleb_16k) to a SINGLE fused CoreML
model that maps RAW 16kHz mono audio -> 192-dim L2-normalizable embedding.

Why fused (raw-audio-in, not fbank-in):
  The Transcripted app has NO Swift FFT/mel code. Rather than reimplement kaldi
  fbank in Swift (fiddly, parity-risky), we bake the ENTIRE kaldi-fbank frontend
  into the CoreML graph as a single Conv1d (windowed + preemphasis + DC-removal +
  DFT folded into one linear op) followed by power, a mel matmul (1x1 conv), and
  log. All ops are conv/elementwise/matmul -> converts cleanly + ANE-friendly.
  The Swift side then just feeds Float samples and gets an embedding. Zero DSP.

Pipeline reproduced EXACTLY (validated numerically vs torchaudio kaldi.fbank):
  raw float wav [-1,1] (1,N)
    -> kaldi fbank(80): frame(25ms/10ms, snip_edges) -> remove_dc -> preemph(0.97)
       -> povey window -> |rfft(512)|^2 (power) -> mel(80) -> log
    -> per-utterance mean-subtract over time
    -> ERes2Net nn.Module -> (1,192) embedding

The fbank frontend is built as fixed linear operators (numpy), folded into a
Conv1d kernel, so the CoreML graph is exact to kaldi yet has no FFT op.

ReLU patch: ERes2Net uses nn.Hardtanh(0,20) as its activation; coremltools has a
hardtanh lowering bug. We swap those for nn.ReLU before tracing (cap@20 ~never
fires; the official 3D-Speaker ONNX export does the same). Output-neutral.

Outputs under scripts/out/:
  - eres2net_fused.mlpackage         (raw-audio-in, flexible length)
  - eres2net_fused.mlmodelc          (compiled, ready to bundle)
  - golden_parity.json               (golden wav->embedding vectors for Swift test)
  - prints PASS/FAIL parity vs the modelscope PyTorch reference
"""
import os
import sys
import json
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
MLPACKAGE = os.path.join(OUT_DIR, "eres2net_fused.mlpackage")
GOLDEN = os.path.join(OUT_DIR, "golden_parity.json")

FEAT_DIM = 80
EMB_DIM = 192
CHANNELS = 32
SR = 16000

# kaldi fbank defaults for Kaldi.fbank(wav, num_mel_bins=80) (everything else default)
FRAME_LENGTH = 400        # 25ms @ 16k
FRAME_SHIFT = 160         # 10ms @ 16k
NFFT = 512                # round_to_power_of_two(400)
NFREQ = NFFT // 2 + 1     # 257
PREEMPH = 0.97
LOW_FREQ = 20.0
HIGH_FREQ = 0.0           # -> Nyquist
EPS = 1.1920929e-07       # kaldi log floor approx (torch float32 eps); validated below


# ----------------------------------------------------------------------------
# ERes2Net torch model (mirrors scripts/convert_eres2net_coreml.py)
# ----------------------------------------------------------------------------
def _patch_hardtanh(module):
    n = 0
    for name, child in module.named_children():
        if isinstance(child, nn.Hardtanh):
            setattr(module, name, nn.ReLU())
            n += 1
        else:
            n += _patch_hardtanh(child)
    return n


def build_eres2net(apply_relu_patch=True):
    from modelscope.models.audio.sv.ERes2Net import ERes2Net
    m = ERes2Net(feat_dim=FEAT_DIM, embed_dim=EMB_DIM, m_channels=CHANNELS)
    sd = torch.load(CKPT, map_location="cpu")
    m.load_state_dict(sd, strict=True)
    m.eval()
    if apply_relu_patch:
        n = _patch_hardtanh(m)
        print(f"[info] patched {n} Hardtanh->ReLU modules")
    m.eval()
    return m


# ----------------------------------------------------------------------------
# Build the fbank linear operators (exact kaldi replication)
# ----------------------------------------------------------------------------
def povey_window(n=FRAME_LENGTH):
    # kaldi povey window = hann(N)^0.85 with hann = 0.5 - 0.5 cos(2*pi*i/(N-1))
    i = np.arange(n, dtype=np.float64)
    hann = 0.5 - 0.5 * np.cos(2.0 * np.pi * i / (n - 1))
    return np.power(hann, 0.85)


def build_frontend_weights():
    """Return (conv_weight [514,1,400], mel_weight [80,257,1]) as float32 numpy."""
    w = povey_window(FRAME_LENGTH)  # (400,)

    # DC removal: x' = x - mean(x)  -> D = I - (1/L) * ones
    L = FRAME_LENGTH
    D = np.eye(L) - np.ones((L, L)) / L

    # Preemphasis on the DC-removed signal:
    #   y[n] = x'[n] - 0.97 x'[n-1]   for n>=1
    #   y[0] = x'[0] - 0.97 x'[0] = 0.03 x'[0]   (kaldi replicates first sample)
    E = np.eye(L)
    for n in range(1, L):
        E[n, n - 1] = -PREEMPH
    E[0, 0] = 1.0 - PREEMPH
    ED = E @ D  # (L,L) linear op applied to the raw frame

    # DFT basis truncated to the first L samples (frame zero-padded 400->512):
    #   Re_k[n] = cos(2*pi*k*n/NFFT),  Im_k[n] = -sin(2*pi*k*n/NFFT)
    k = np.arange(NFREQ).reshape(-1, 1)          # (257,1)
    n = np.arange(L).reshape(1, -1)              # (1,400)
    ang = 2.0 * np.pi * k * n / NFFT             # (257,400)
    cos_b = np.cos(ang)
    sin_b = -np.sin(ang)

    # Fold window into the basis, then fold the (DC+preemph) linear op:
    #   M_real = (w ⊙ cos) @ ED ,  M_imag = (w ⊙ sin) @ ED   -> (257,400) each
    W = w.reshape(1, -1)
    M_real = (cos_b * W) @ ED
    M_imag = (sin_b * W) @ ED

    conv_w = np.concatenate([M_real, M_imag], axis=0)        # (514,400)
    conv_w = conv_w.reshape(2 * NFREQ, 1, L).astype(np.float32)

    # mel filterbank (80,256) from torchaudio kaldi, padded to (80,257)
    melbanks, _ = Kaldi.get_mel_banks(
        FEAT_DIM, NFFT, SR, LOW_FREQ, HIGH_FREQ, 100.0, -500.0, 1.0)
    melbanks = melbanks.numpy().astype(np.float64)           # (80, 256)
    if melbanks.shape[1] == NFREQ - 1:
        melbanks = np.concatenate(
            [melbanks, np.zeros((FEAT_DIM, 1))], axis=1)      # (80,257)
    mel_w = melbanks.reshape(FEAT_DIM, NFREQ, 1).astype(np.float32)
    return conv_w, mel_w


class FbankFrontend(nn.Module):
    """Raw float wav (1,N) -> log-mel fbank (1,T,80), exact kaldi, no FFT op."""
    def __init__(self):
        super().__init__()
        conv_w, mel_w = build_frontend_weights()
        self.register_buffer("dft", torch.from_numpy(conv_w))   # (514,1,400)
        self.register_buffer("mel", torch.from_numpy(mel_w))    # (80,257,1)

    def forward(self, wav):
        # wav: (1, N) float32 in [-1, 1]
        x = wav.unsqueeze(1)                                    # (1,1,N)
        lin = torch.nn.functional.conv1d(x, self.dft, stride=FRAME_SHIFT)  # (1,514,T)
        re = lin[:, :NFREQ, :]
        im = lin[:, NFREQ:, :]
        power = re * re + im * im                              # (1,257,T)
        mel = torch.nn.functional.conv1d(power, self.mel)       # (1,80,T)
        logmel = torch.log(torch.clamp(mel, min=EPS))           # (1,80,T)
        feat = logmel.transpose(1, 2)                          # (1,T,80)
        feat = feat - feat.mean(dim=1, keepdim=True)            # per-utt CMN over time
        return feat


class FusedModel(nn.Module):
    def __init__(self, frontend, eres2net):
        super().__init__()
        self.frontend = frontend
        self.eres2net = eres2net

    def forward(self, wav):
        feat = self.frontend(wav)        # (1,T,80)
        return self.eres2net(feat)       # (1,192)


# ----------------------------------------------------------------------------
# Reference helpers (modelscope-exact)
# ----------------------------------------------------------------------------
def ref_fbank(wav_1d):
    feat = Kaldi.fbank(wav_1d.unsqueeze(0), num_mel_bins=FEAT_DIM)
    feat = feat - feat.mean(dim=0, keepdim=True)
    return feat  # (T,80)


def load_segment(path, start_s, dur_s):
    wav, sr = torchaudio.load(path)
    if sr != SR:
        wav = torchaudio.functional.resample(wav, sr, SR)
    wav = wav[0]
    a = int(start_s * SR)
    b = int((start_s + dur_s) * SR)
    return wav[a:b].contiguous()


def cosine(a, b):
    a = np.asarray(a).flatten().astype(np.float64)
    b = np.asarray(b).flatten().astype(np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def dirsize(p):
    if os.path.isfile(p):
        return os.path.getsize(p) / (1024 * 1024)
    return sum(os.path.getsize(os.path.join(d, f))
               for d, _, fs in os.walk(p) for f in fs) / (1024 * 1024)


def main():
    import coremltools as ct
    print(f"[info] torch {torch.__version__}, coremltools {ct.__version__}")

    ref_eres = build_eres2net(apply_relu_patch=False)
    frontend = FbankFrontend().eval()

    # ---- GATE 1: fbank frontend numerically == kaldi.fbank (pre-CMN) ----
    print("[gate1] fbank frontend vs torchaudio kaldi.fbank ...")
    seg = load_segment(AMI_WAV, 60.0, 4.0)
    my_pre = frontend.forward(seg.unsqueeze(0))  # includes CMN; compare post-CMN
    ref_pre = ref_fbank(seg).unsqueeze(0)
    # align time length (snip_edges should match exactly)
    T = min(my_pre.shape[1], ref_pre.shape[1])
    d = (my_pre[:, :T] - ref_pre[:, :T]).abs().max().item()
    c = cosine(my_pre[:, :T].detach().numpy(), ref_pre[:, :T].detach().numpy())
    print(f"[gate1] frames mine={my_pre.shape[1]} ref={ref_pre.shape[1]} | "
          f"maxabsdiff={d:.6e} cosine={c:.8f}")
    if d > 1e-2:
        print(f"[verdict] FAIL gate1 — fbank mismatch maxabs={d:.4e}")
        return "FAIL"

    # ---- GATE 2: fused torch == modelscope reference (fbank->eres2net) ----
    print("[gate2] fused torch model vs modelscope reference ...")
    fused = FusedModel(frontend, build_eres2net(apply_relu_patch=True)).eval()
    segments = [(60.0, 4.0), (120.0, 3.5), (200.0, 5.0), (300.0, 4.0),
                (450.0, 3.0), (600.0, 4.5)]
    g2 = []
    for st, du in segments:
        s = load_segment(AMI_WAV, st, du)
        with torch.no_grad():
            fe = fused(s.unsqueeze(0)).numpy()
            rf = ref_eres(ref_fbank(s).unsqueeze(0)).numpy()
        g2.append(cosine(fe, rf))
    print(f"[gate2] fused-torch vs ref cosine min={min(g2):.6f} mean={np.mean(g2):.6f}")
    if min(g2) < 0.999:
        print(f"[verdict] FAIL gate2 — fused torch diverges (min {min(g2):.4f})")
        return "FAIL"

    # ---- Convert to CoreML (flexible audio length) ----
    print("[step] tracing + converting fused model to CoreML ...")
    example = load_segment(AMI_WAV, 60.0, 4.0).unsqueeze(0).contiguous()
    traced = torch.jit.trace(fused, example)
    traced.eval()
    audio_len = ct.RangeDim(lower_bound=8000, upper_bound=480000, default=64000)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, audio_len), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.save(MLPACKAGE)
    sz = dirsize(MLPACKAGE)
    print(f"[ok] saved {MLPACKAGE} ({sz:.2f} MB)")

    # ---- GATE 3: CoreML == reference on real AMI segments ----
    print("[gate3] CoreML vs modelscope reference ...")
    g3 = []
    golden = []
    for st, du in segments:
        s = load_segment(AMI_WAV, st, du)
        with torch.no_grad():
            rf = ref_eres(ref_fbank(s).unsqueeze(0)).numpy()[0]
        out = mlmodel.predict({"audio": s.unsqueeze(0).numpy().astype(np.float32)})
        cm = np.asarray(out["embedding"]).flatten()
        c = cosine(rf, cm)
        g3.append(c)
        print(f"  [{st:.0f}s+{du:.1f}s] cosine={c:.6f} | T={s.shape[0]} samples")
        golden.append({"start": st, "dur": du, "coreml_embedding": cm.tolist()})

    # same/diff speaker sanity via CoreML
    if all(os.path.exists(os.path.join(EXAMPLES, w)) for w in
           ["speaker1_a_en_16k.wav", "speaker1_b_en_16k.wav", "speaker2_a_en_16k.wav"]):
        def cm_emb(path):
            wav, sr = torchaudio.load(path)
            if sr != SR:
                wav = torchaudio.functional.resample(wav, sr, SR)
            wav = wav[0].unsqueeze(0).numpy().astype(np.float32)
            return np.asarray(mlmodel.predict({"audio": wav})["embedding"]).flatten()
        e1 = cm_emb(os.path.join(EXAMPLES, "speaker1_a_en_16k.wav"))
        e2 = cm_emb(os.path.join(EXAMPLES, "speaker1_b_en_16k.wav"))
        e3 = cm_emb(os.path.join(EXAMPLES, "speaker2_a_en_16k.wav"))
        print(f"[sanity] CoreML same-spk cosine = {cosine(e1, e2):.4f} (want high)")
        print(f"[sanity] CoreML diff-spk cosine = {cosine(e1, e3):.4f} (want low)")

    mn, mean = min(g3), float(np.mean(g3))
    verdict = "PASS" if mn > 0.99 else ("PARTIAL" if mn > 0.95 else "FAIL")
    print(f"\n[summary] CoreML vs ref cosine min={mn:.6f} mean={mean:.6f} | size {sz:.2f} MB")
    print(f"[verdict] {verdict} | fused raw-audio->embedding | flexible length | compute=ALL")

    # ---- compile to .mlmodelc + write golden vectors for the Swift parity test ----
    if verdict != "FAIL":
        import subprocess
        mlmodelc = os.path.join(OUT_DIR, "eres2net_fused.mlmodelc")
        if os.path.isdir(mlmodelc):
            import shutil
            shutil.rmtree(mlmodelc)
        subprocess.run(["xcrun", "coremlcompiler", "compile", MLPACKAGE, OUT_DIR],
                       check=True)
        print(f"[ok] compiled -> {mlmodelc} ({dirsize(mlmodelc):.2f} MB)")
        with open(GOLDEN, "w") as f:
            json.dump({"model": "eres2net_fused", "dim": EMB_DIM,
                       "wav": "data/ami/audio/ES2002a.Mix-Headset.wav",
                       "samples": golden}, f)
        print(f"[ok] wrote golden parity vectors -> {GOLDEN}")
    return verdict


if __name__ == "__main__":
    try:
        v = main()
        sys.exit(0 if v in ("PASS", "PARTIAL") else 1)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\n[verdict] FAIL — {type(e).__name__}: {e}")
        sys.exit(1)
