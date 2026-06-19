#!/usr/bin/env python3
"""Trace is faithful (1.0) but ONNX & CoreML both diverge (0.40) -> a converter
op-lowering bug, NOT a tracer/model bug. Bisect through ONNX (fast) to find the
first module whose ONNX output diverges from eager. Then inspect that module's
ops.
"""
import os, numpy as np, torch, torch.nn as nn, warnings
warnings.filterwarnings("ignore")
import onnxruntime as ort

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k")
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
FEAT_DIM, EMB_SIZE, N_FRAMES = 80, 512, 300

def cosine(a,b):
    a=a.flatten().astype(np.float64); b=b.flatten().astype(np.float64)
    return float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))

from modelscope.models.audio.sv.DTDNN import CAMPPlus
full = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE, output_level='frame')
full.load_state_dict(torch.load(BIN, map_location="cpu"), strict=False); full.eval()

class Truncated(nn.Module):
    def __init__(self, base, k): super().__init__(); self.base=base; self.k=k
    def forward(self, x):
        x = x.permute(0,2,1)
        x = self.base.head(x)
        for i, mod in enumerate(self.base.xvector):
            if i >= self.k: break
            x = mod(x)
        return x

names = list(dict(full.xvector.named_children()).keys())
rnd = torch.randn(1, N_FRAMES, FEAT_DIM)

def onnx_cos(mod, x):
    with torch.no_grad(): pt = mod(x).numpy()
    p = os.path.join(OUT, "bisect.onnx")
    torch.onnx.export(mod, x, p, input_names=["i"], output_names=["o"], opset_version=14)
    s = ort.InferenceSession(p, providers=["CPUExecutionProvider"])
    o = s.run(["o"], {"i": x.numpy().astype(np.float32)})[0]
    return cosine(pt, o), float(np.max(np.abs(pt-o)))

# head only
class HeadOnly(nn.Module):
    def __init__(self, base): super().__init__(); self.base=base
    def forward(self, x):
        x = x.permute(0,2,1); return self.base.head(x)
c,d = onnx_cos(HeadOnly(full), rnd)
print(f"head only            : cosine={c:.6f} maxabsdiff={d:.4f}")

for k in range(1, len(names)+1):
    c,d = onnx_cos(Truncated(full,k), rnd)
    print(f"up to [{k-1}] {names[k-1]:13s}: cosine={c:.6f} maxabsdiff={d:.4f}")
