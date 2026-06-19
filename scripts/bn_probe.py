#!/usr/bin/env python3
"""Divergence appears at the first BatchNorm1d (tdnn). Probe the pretrained BN
running stats and isolate Conv1d+BN1d+ReLU through ONNX with REAL weights.
Check whether BN eval-mode fold differs (eps placement / momentum / var<0).
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
m = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE); m.eval()
sd = torch.load(BIN, map_location="cpu")
m.load_state_dict(sd, strict=True)

# Inspect ALL BatchNorm running_var ranges
bn_stats = []
for name, mod in m.named_modules():
    if isinstance(mod, (nn.BatchNorm1d, nn.BatchNorm2d)):
        rv = mod.running_var.detach().numpy()
        rm = mod.running_mean.detach().numpy()
        bn_stats.append((name, rv.min(), rv.max(), mod.eps, mod.affine,
                         (mod.weight is not None)))
print("BatchNorm running_var ranges (name, var_min, var_max, eps, affine):")
neg = 0
for name, vmn, vmx, eps, aff, hasw in bn_stats[:8]:
    print(f"  {name:30s} var[{vmn:.3e},{vmx:.3e}] eps={eps} affine={aff}")
print(f"  ... total BN layers: {len(bn_stats)}")
allmin = min(s[1] for s in bn_stats)
print(f"  global min running_var across all BNs: {allmin:.3e}  (any negative: {allmin<0})")

# Count affine vs non-affine (batchnorm_ => affine=False on the final dense)
naff = sum(1 for s in bn_stats if not s[4])
print(f"  non-affine BN layers: {naff}")

# Isolate the tdnn module (Conv1d stride2 + BN1d + ReLU) with REAL weights
print("\n== isolate xvector.tdnn (Conv1d+BN1d+ReLU, real weights) ==")
tdnn = m.xvector.tdnn  # TDNNLayer
# tdnn input channels = head.out_channels = 32*(80//8)=320
in_ch = m.head.out_channels
x = torch.randn(1, in_ch, 150)
with torch.no_grad():
    pt = tdnn(x).numpy()
p = os.path.join(OUT, "tdnn.onnx")
torch.onnx.export(tdnn, x, p, input_names=["i"], output_names=["o"], opset_version=14)
s = ort.InferenceSession(p, providers=["CPUExecutionProvider"])
o = s.run(["o"], {"i": x.numpy().astype(np.float32)})[0]
print(f"  tdnn ONNX vs eager: cosine={cosine(pt,o):.6f} maxabsdiff={float(np.max(np.abs(pt-o))):.4f}")

# Now isolate just the BatchNorm1d inside tdnn
bn = tdnn.nonlinear.batchnorm
xb = torch.randn(1, 128, 150)  # tdnn out_channels=128
with torch.no_grad():
    ptb = bn(xb).numpy()
pb = os.path.join(OUT, "bn.onnx")
torch.onnx.export(bn, xb, pb, input_names=["i"], output_names=["o"], opset_version=14)
sb = ort.InferenceSession(pb, providers=["CPUExecutionProvider"])
ob = sb.run(["o"], {"i": xb.numpy().astype(np.float32)})[0]
print(f"  BN1d-only ONNX vs eager: cosine={cosine(ptb,ob):.6f} maxabsdiff={float(np.max(np.abs(ptb-ob))):.4f}")

# Isolate just the Conv1d inside tdnn
conv = tdnn.linear
with torch.no_grad():
    ptc = conv(x).numpy()
pc = os.path.join(OUT, "conv.onnx")
torch.onnx.export(conv, x, pc, input_names=["i"], output_names=["o"], opset_version=14)
sc = ort.InferenceSession(pc, providers=["CPUExecutionProvider"])
oc = sc.run(["o"], {"i": x.numpy().astype(np.float32)})[0]
print(f"  Conv1d-only ONNX vs eager: cosine={cosine(ptc,oc):.6f} maxabsdiff={float(np.max(np.abs(ptc-oc))):.4f}")
print(f"    conv: in={conv.in_channels} out={conv.out_channels} k={conv.kernel_size} "
      f"stride={conv.stride} pad={conv.padding} dil={conv.dilation}")
