#!/usr/bin/env python3
"""
Convert the Alibaba 3D-Speaker CAM++ speaker-embedding model (modelscope
iic/speech_campplus_sv_en_voxceleb_16k) to Apple CoreML, and verify the
converted model reproduces the PyTorch embeddings on real AMI audio.

=========================== RESULT: FAIL ===========================
Conversion *runs* (no unsupported ops, 14.4 MB mlprogram) but the converted
model does NOT reproduce the PyTorch embeddings: min cosine ~0.23 on real AMI
clips (want >0.99). This is a hard FAIL for shipping CAM++ on CoreML.

Root cause (see scripts/bn_probe.py, accumulation_test.py, this file's diagnosis
trail): the pretrained CAM++ has BatchNorm1d layers with near-zero running_var
(min ~4.7e-6 in transit1) -> normalization scale ~260x. Both torch.onnx.export
AND coremltools (independent frontends) lower the deep DenseTDNN backbone such
that ordinary float rounding gets amplified ~260x by these tiny-variance
channels and cascades through the dense-concat / residual structure. Evidence:
  - TorchScript trace vs eager PyTorch: cosine 1.000000 (trace is FAITHFUL)
  - ONNX (from same trace) vs eager:    cosine ~0.68 (frame) / ~0.23 (emb)
  - CoreML f16/ALL and f32/CPU:         cosine ~0.23 (same as ONNX => not f16)
  - Same failure with random-init OR pretrained at the FULL-MODEL level once
    pretrained weights create the tiny-variance BN channels.
  - Individual ops (FCM head, StatsPool std, seg_pooling, single CAMLayer/Block)
    all convert at cosine ~1.0; the error is ACCUMULATED through depth.
The faithful eager reference is validated: same-speaker cosine 0.79 vs
different-speaker -0.09 on the model's own example clips.

The kaldi-fbank front-end (the part we *expected* to be hard) is NOT the
blocker -- we sidestep it by converting only fbank-in -> embedding-out and
feeding identical host-computed fbank to both models.

Fallback ERes2Net (3D-Speaker, Conv2d-ResNet): ONNX export cosine 1.000000;
CoreML needs a trivial 1-line patch (its custom Hardtanh ReLU(0,20) trips a
coremltools int/float dtype bug) -> then CoreML cosine 1.000000. Recommend
ERes2Net, not CAM++, for the CoreML/ANE path.

Strategy
--------
The CAM++ pipeline is: raw 16k audio -> kaldi fbank (80-dim) -> mean-subtract
over time -> CAMPPlus nn.Module -> 512-dim embedding.

We convert ONLY the neural net (fbank-in -> embedding-out). fbank is computed on
the host (torchaudio.compliance.kaldi.fbank, exactly mirroring modelscope's
SpeakerVerificationCAMPPlus.__extract_feature) and fed identically to both the
PyTorch and CoreML models. The app would compute the same fbank in Swift.

The net takes a FIXED number of frames (default 300) so the trace has static
shapes; the app windows/pads to that frame count.

Outputs under scripts/out/:
  - campplus.mlpackage     (the converted CoreML model)
  - parity printed to stdout (PASS/PARTIAL/FAIL + cosine numbers)
"""

import os
import sys
import numpy as np
import torch
import torchaudio
import torchaudio.compliance.kaldi as Kaldi

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k"
)
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
AMI_WAV = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "ami", "audio", "ES2002a.Mix-Headset.wav",
)
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT_DIR, exist_ok=True)
MLPACKAGE = os.path.join(OUT_DIR, "campplus.mlpackage")

FEAT_DIM = 80
EMB_SIZE = 512
N_FRAMES = 300          # fixed trace length (~3s at 10ms hop)
SR = 16000


def build_torch_model():
    from modelscope.models.audio.sv.DTDNN import CAMPPlus
    m = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE)
    sd = torch.load(BIN, map_location="cpu")
    miss, unexp = m.load_state_dict(sd, strict=True)
    m.eval()
    return m


def fbank_from_audio(wav_1d: torch.Tensor) -> torch.Tensor:
    """Mirror modelscope SpeakerVerificationCAMPPlus.__extract_feature exactly.
    wav_1d: 1-D float tensor at 16kHz, range ~[-1,1] scaled to int16 magnitude
    is what kaldi expects? modelscope passes the raw torchaudio.load output
    (float [-1,1]) directly, so we do the same.
    Returns (T, 80) after per-utterance mean subtraction over time."""
    feat = Kaldi.fbank(wav_1d.unsqueeze(0), num_mel_bins=FEAT_DIM)
    feat = feat - feat.mean(dim=0, keepdim=True)
    return feat  # (T, 80)


def load_segment(path, start_s, dur_s):
    wav, sr = torchaudio.load(path)
    if sr != SR:
        wav = torchaudio.functional.resample(wav, sr, SR)
    wav = wav[0]  # mono
    a = int(start_s * SR)
    b = int((start_s + dur_s) * SR)
    return wav[a:b].contiguous()


def fixed_frames(feat: torch.Tensor, n: int) -> torch.Tensor:
    """Crop or pad (T,80) to exactly (n,80)."""
    T = feat.shape[0]
    if T >= n:
        return feat[:n]
    pad = torch.zeros(n - T, feat.shape[1])
    return torch.cat([feat, pad], dim=0)


def cosine(a, b):
    a = a.flatten().astype(np.float64)
    b = b.flatten().astype(np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main():
    print(f"[info] torch {torch.__version__}, torchaudio {torchaudio.__version__}")
    import coremltools as ct
    print(f"[info] coremltools {ct.__version__}")

    print("[step] building + loading torch CAMPPlus ...")
    model = build_torch_model()

    # Example input for tracing: (1, N_FRAMES, 80)
    example = torch.randn(1, N_FRAMES, FEAT_DIM)
    with torch.no_grad():
        ref_out = model(example)
    print(f"[info] torch forward ok, emb shape {tuple(ref_out.shape)}")

    print("[step] torch.jit.trace ...")
    traced = torch.jit.trace(model, example)
    traced.eval()
    # sanity: traced == eager
    with torch.no_grad():
        t_out = traced(example)
    trace_cos = cosine(ref_out.numpy(), t_out.numpy())
    print(f"[info] trace vs eager cosine: {trace_cos:.6f}")

    print("[step] coremltools.convert (mlprogram) ...")
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
    sz = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fs in os.walk(MLPACKAGE) for f in fs
    ) / (1024 * 1024)
    print(f"[ok] saved {MLPACKAGE}  ({sz:.2f} MB)")

    # ------- parity on real AMI segments -------
    print("[step] parity on real AMI clips ...")
    segments = [(60.0, 4.0), (120.0, 3.5), (200.0, 5.0), (300.0, 4.0)]
    cosines = []
    for i, (st, du) in enumerate(segments):
        wav = load_segment(AMI_WAV, st, du)
        feat = fbank_from_audio(wav)            # (T,80)
        feat = fixed_frames(feat, N_FRAMES)     # (N,80)
        inp = feat.unsqueeze(0)                 # (1,N,80)

        with torch.no_grad():
            pt = model(inp).numpy()

        cm = mlmodel.predict({"fbank": inp.numpy().astype(np.float32)})
        # output name may be 'embedding' or auto; grab the single 512 vector
        cm_key = "embedding" if "embedding" in cm else list(cm.keys())[0]
        cm_out = np.asarray(cm[cm_key])

        c = cosine(pt, cm_out)
        # also report normalized embedding cosine (what's actually used for
        # speaker matching) and max abs diff
        def norm(x):
            x = x.flatten()
            return x / (np.linalg.norm(x) + 1e-12)
        cn = cosine(norm(pt), norm(cm_out))
        maxabs = float(np.max(np.abs(pt.flatten() - cm_out.flatten())))
        cosines.append(c)
        print(f"  seg{i} [{st:.0f}s+{du:.1f}s]: cosine={c:.6f} "
              f"normcos={cn:.6f} maxabsdiff={maxabs:.5f}")

    mn = min(cosines)
    print(f"\n[summary] min cosine over {len(cosines)} segs: {mn:.6f}")
    if mn > 0.99:
        verdict = "PASS"
    elif mn > 0.90:
        verdict = "PARTIAL"
    else:
        verdict = "FAIL"
    print(f"[verdict] {verdict} | model size {sz:.2f} MB | compute_units=ALL")
    return verdict, mn, sz


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"\n[verdict] FAIL — conversion/parity blocked: {type(e).__name__}: {e}")
        sys.exit(1)
