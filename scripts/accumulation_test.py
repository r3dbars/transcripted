#!/usr/bin/env python3
"""Confirm error accumulation through the dense CAM-TDNN stack, and find the
exact op whose float32 CoreML result diverges from PyTorch at >1e-3.

We test the real (pretrained) backbone truncated to N blocks, to see cosine
decay with depth. We also dump per-op: the CAMLayer maxabsdiff of 0.014 in f32
is too big for rounding -> probe which sub-tensor (linear_local 'y', the gating
'm', or y*m) diverges.
"""
import os, numpy as np, torch, torch.nn as nn, torch.nn.functional as F, warnings
warnings.filterwarnings("ignore")
import coremltools as ct

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k")
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
FEAT_DIM, EMB_SIZE, N_FRAMES = 80, 512, 300

def cosine(a, b):
    a=a.flatten().astype(np.float64); b=b.flatten().astype(np.float64)
    return float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))

def f32_cosine(mod, inp_shape):
    ex = torch.randn(*inp_shape); mod.eval()
    with torch.no_grad(): pt = mod(ex).numpy()
    tr = torch.jit.trace(mod, ex); tr.eval()
    ml = ct.convert(tr,
        inputs=[ct.TensorType(name="x", shape=inp_shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="y", dtype=np.float32)],
        convert_to="mlprogram", compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS13)
    o = ml.predict({"x": ex.numpy().astype(np.float32)})
    cm = np.asarray(o["y"] if "y" in o else list(o.values())[0])
    return cosine(pt, cm), float(np.max(np.abs(pt-cm)))

from modelscope.models.audio.sv.DTDNN import CAMPPlus
from modelscope.models.audio.sv.DTDNN_layers import CAMLayer

# --- Probe CAMLayer internal tensors ---
print("== CAMLayer internal probe ==")
class CAMProbe(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.l = c
    def forward(self, x):
        y = self.l.linear_local(x)
        context = x.mean(-1, keepdim=True) + self.l.seg_pooling(x)
        context = self.l.relu(self.l.linear1(context))
        m = self.l.sigmoid(self.l.linear2(context))
        return y * m
cam = CAMLayer(128, 32, 3, 1, 1, 1, False)
c, d = f32_cosine(CAMProbe(cam), (1,128,150))
print(f"  y*m cosine={c:.6f} maxabsdiff={d:.5f}")

# m-gate only
class GateOnly(nn.Module):
    def __init__(self, c): super().__init__(); self.l=c
    def forward(self, x):
        context = x.mean(-1, keepdim=True) + self.l.seg_pooling(x)
        context = self.l.relu(self.l.linear1(context))
        return self.l.sigmoid(self.l.linear2(context))
c, d = f32_cosine(GateOnly(cam), (1,128,150))
print(f"  gate m cosine={c:.6f} maxabsdiff={d:.5f}")

# --- Depth decay on the REAL pretrained backbone ---
print("\n== cosine vs backbone depth (real weights, frame output) ==")
sd = torch.load(BIN, map_location="cpu")
full = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE, output_level='frame')
full.load_state_dict(sd, strict=False); full.eval()

class Truncated(nn.Module):
    """Run head + first k modules of xvector."""
    def __init__(self, base, k):
        super().__init__(); self.base = base; self.k = k
    def forward(self, x):
        x = x.permute(0,2,1)
        x = self.base.head(x)
        for i, mod in enumerate(self.base.xvector):
            if i >= self.k: break
            x = mod(x)
        return x

# xvector modules: tdnn, block1, transit1, block2, transit2, block3, transit3, out_nonlinear
names = list(dict(full.xvector.named_children()).keys())
print("  xvector modules:", names)
for k in [1, 2, 3, 4, 5, 6]:
    t = Truncated(full, k)
    c, d = f32_cosine(t, (1, N_FRAMES, FEAT_DIM))
    upto = names[k-1] if k-1 < len(names) else "?"
    print(f"  up to module[{k-1}]={upto:14s}: cosine={c:.6f} maxabsdiff={d:.4f}")
