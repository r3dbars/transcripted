#!/usr/bin/env python3
"""ROOT CAUSE confirmed: dynamic time-axis breaks strided Conv1d in export.
Verify the FIX end-to-end on real AMI audio for BOTH:
  (a) ONNX with fully static shape (no dynamic_axes)
  (b) CoreML with fully static shape
Both must hit cosine >0.99 vs eager PyTorch.
Report final model sizes.
"""
import os, numpy as np, torch, warnings
warnings.filterwarnings("ignore")
import torchaudio, torchaudio.compliance.kaldi as Kaldi
import onnxruntime as ort
import coremltools as ct

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k")
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
AMI_WAV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "data","ami","audio","ES2002a.Mix-Headset.wav")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
os.makedirs(OUT, exist_ok=True)
FEAT_DIM, EMB_SIZE, N_FRAMES, SR = 80, 512, 300, 16000

def cosine(a,b):
    a=a.flatten().astype(np.float64); b=b.flatten().astype(np.float64)
    return float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))
def dirsize(p):
    if os.path.isfile(p): return os.path.getsize(p)/(1024*1024)
    return sum(os.path.getsize(os.path.join(d,f)) for d,_,fs in os.walk(p) for f in fs)/(1024*1024)

from modelscope.models.audio.sv.DTDNN import CAMPPlus
m = CAMPPlus(feat_dim=FEAT_DIM, embedding_size=EMB_SIZE); m.eval()
m.load_state_dict(torch.load(BIN, map_location="cpu"), strict=True)

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

segs = [(60.0,4.0),(120.0,3.5),(200.0,5.0),(300.0,4.0),(450.0,3.0)]
feats = [fixed(fbank(seg(AMI_WAV,st,du)), N_FRAMES).unsqueeze(0) for st,du in segs]
ref = []
for f in feats:
    with torch.no_grad():
        ref.append(m(f).numpy())

dummy = torch.randn(1, N_FRAMES, FEAT_DIM)

# (a) ONNX static
onnx_static = os.path.join(OUT, "campplus_static.onnx")
torch.onnx.export(m, dummy, onnx_static, input_names=["fbank"],
                  output_names=["embedding"], opset_version=14)  # NO dynamic_axes
s = ort.InferenceSession(onnx_static, providers=["CPUExecutionProvider"])
print("== ONNX (static shape) vs eager ==")
onnx_cos = []
for i,f in enumerate(feats):
    o = s.run(["embedding"], {"fbank": f.numpy().astype(np.float32)})[0]
    c = cosine(ref[i], o); onnx_cos.append(c)
    print(f"  seg{i}: cosine={c:.6f}")
print(f"  min ONNX cosine: {min(onnx_cos):.6f}  size={dirsize(onnx_static):.2f} MB")

# (b) CoreML static
traced = torch.jit.trace(m, dummy); traced.eval()
mlpkg = os.path.join(OUT, "campplus_static.mlpackage")
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="fbank", shape=(1,N_FRAMES,FEAT_DIM), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram", compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS13)
ml.save(mlpkg)
print("\n== CoreML (static shape, FLOAT16/ALL) vs eager ==")
cm_cos = []
for i,f in enumerate(feats):
    o = ml.predict({"fbank": f.numpy().astype(np.float32)})
    k = "embedding" if "embedding" in o else list(o.keys())[0]
    c = cosine(ref[i], np.asarray(o[k])); cm_cos.append(c)
    print(f"  seg{i}: cosine={c:.6f}")
print(f"  min CoreML cosine: {min(cm_cos):.6f}  size={dirsize(mlpkg):.2f} MB")

# (c) CoreML static FLOAT32 CPU (precision ceiling)
ml32 = ct.convert(
    traced,
    inputs=[ct.TensorType(name="fbank", shape=(1,N_FRAMES,FEAT_DIM), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram", compute_units=ct.ComputeUnit.CPU_ONLY,
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS13)
print("\n== CoreML (static, FLOAT32/CPU) vs eager ==")
cm32 = []
for i,f in enumerate(feats):
    o = ml32.predict({"fbank": f.numpy().astype(np.float32)})
    k = "embedding" if "embedding" in o else list(o.keys())[0]
    c = cosine(ref[i], np.asarray(o[k])); cm32.append(c)
    print(f"  seg{i}: cosine={c:.6f}")
print(f"  min CoreML-f32 cosine: {min(cm32):.6f}")

print("\n========= VERDICT =========")
mn = min(min(cm_cos), min(onnx_cos))
v = "PASS" if min(cm_cos) > 0.99 else ("PARTIAL" if min(cm_cos) > 0.9 else "FAIL")
print(f"CoreML(f16/ALL) min cosine = {min(cm_cos):.6f} -> {v}")
print(f"ONNX(static)    min cosine = {min(onnx_cos):.6f}")
print(f"CoreML mlpackage size = {dirsize(mlpkg):.2f} MB")
