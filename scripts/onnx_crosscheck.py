#!/usr/bin/env python3
"""Cross-check: export the SAME bare CAMPPlus to ONNX and run via onnxruntime.
If ONNX matches PyTorch (cosine ~1.0) but CoreML does not, the divergence is a
coremltools graph-conversion problem (not model fragility). This tells us whether
a different export path (ONNX -> CoreML, or staying on ONNX) would work.
"""
import os, numpy as np, torch, warnings
warnings.filterwarnings("ignore")
import torchaudio, torchaudio.compliance.kaldi as Kaldi

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k")
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
AMI_WAV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "data","ami","audio","ES2002a.Mix-Headset.wav")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)
ONNX = os.path.join(OUT, "campplus.onnx")
FEAT_DIM, EMB_SIZE, N_FRAMES, SR = 80, 512, 300, 16000

def cosine(a,b):
    a=a.flatten().astype(np.float64); b=b.flatten().astype(np.float64)
    return float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))

from modelscope.models.audio.sv.DTDNN import CAMPPlus
m = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE)
m.load_state_dict(torch.load(BIN, map_location="cpu"), strict=True); m.eval()

def fbank(wav):
    f = Kaldi.fbank(wav.unsqueeze(0), num_mel_bins=FEAT_DIM)
    return f - f.mean(dim=0, keepdim=True)
def seg(p, st, du):
    w,sr = torchaudio.load(p)
    if sr!=SR: w = torchaudio.functional.resample(w, sr, SR)
    w=w[0]; return w[int(st*SR):int((st+du)*SR)].contiguous()
def fixed(f,n):
    if f.shape[0]>=n: return f[:n]
    return torch.cat([f, torch.zeros(n-f.shape[0], f.shape[1])],0)

# Export ONNX (dynamic-shape friendly so the host can vary frame count)
dummy = torch.randn(1, N_FRAMES, FEAT_DIM)
torch.onnx.export(
    m, dummy, ONNX,
    input_names=["fbank"], output_names=["embedding"],
    dynamic_axes={"fbank": {1: "T"}},
    opset_version=14)
sz = os.path.getsize(ONNX)/(1024*1024)
print(f"[ok] ONNX exported: {ONNX} ({sz:.2f} MB)")

import onnxruntime as ort
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])

segs = [(60.0,4.0),(120.0,3.5),(200.0,5.0),(300.0,4.0)]
print("\nseg : pytorch-vs-onnx cosine (want ~1.0)")
for i,(st,du) in enumerate(segs):
    feat = fixed(fbank(seg(AMI_WAV, st, du)), N_FRAMES).unsqueeze(0)
    with torch.no_grad():
        pt = m(feat).numpy()
    onx = sess.run(["embedding"], {"fbank": feat.numpy().astype(np.float32)})[0]
    print(f"  seg{i}: {cosine(pt, onx):.6f}")
