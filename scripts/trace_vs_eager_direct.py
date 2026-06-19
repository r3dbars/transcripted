#!/usr/bin/env python3
"""Direct test: does torch.jit.trace(m) match eager m on the SAME real-fbank
input? Earlier we only compared trace-vs-eager on a random tensor (got 1.0).
Now test on the EXPORT random tensor AND real fbank. If trace != eager, the
TorchScript tracer itself is the culprit (in-place op / checkpoint), independent
of ONNX/CoreML.

Also try torch.jit.script (not trace) and torch.export as alternatives.
"""
import os, numpy as np, torch, warnings
warnings.filterwarnings("ignore")
import torchaudio, torchaudio.compliance.kaldi as Kaldi

MODEL_DIR = os.path.expanduser(
    "~/.cache/modelscope/hub/models/iic/speech_campplus_sv_en_voxceleb_16k")
BIN = os.path.join(MODEL_DIR, "campplus_voxceleb.bin")
AMI_WAV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "data","ami","audio","ES2002a.Mix-Headset.wav")
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

rnd = torch.randn(1, N_FRAMES, FEAT_DIM)
real = fixed(fbank(seg(AMI_WAV,60,4)), N_FRAMES).unsqueeze(0)

with torch.no_grad():
    e_rnd  = m(rnd).numpy()
    e_real = m(real).numpy()

# Trace on RANDOM, eval on both
tr_rnd = torch.jit.trace(m, rnd); tr_rnd.eval()
with torch.no_grad():
    t_rnd_on_rnd  = tr_rnd(rnd).numpy()
    t_rnd_on_real = tr_rnd(real).numpy()
print("trace(on rnd) vs eager  @rnd :", f"{cosine(e_rnd,  t_rnd_on_rnd):.6f}")
print("trace(on rnd) vs eager  @real:", f"{cosine(e_real, t_rnd_on_real):.6f}")

# Trace on REAL, eval on real
tr_real = torch.jit.trace(m, real); tr_real.eval()
with torch.no_grad():
    t_real_on_real = tr_real(real).numpy()
print("trace(on real) vs eager @real:", f"{cosine(e_real, t_real_on_real):.6f}")

# Does re-running eager AFTER trace change BN running stats? (trace may update them)
with torch.no_grad():
    e_real_after = m(real).numpy()
print("eager @real BEFORE vs AFTER tracing:", f"{cosine(e_real, e_real_after):.6f}")
