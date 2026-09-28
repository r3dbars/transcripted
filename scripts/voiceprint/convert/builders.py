"""Build a fused torch module (raw 16 kHz audio [1, N] -> embedding [1, D]) per bake-off model.

Each builder mirrors that model's Python runtime (scripts/voiceprint/runtimes/<runtime>.py
plus VP/models/<id>/model.json) exactly, front end included:

  redimnet        ReDimNet / ReDimNet2 wrapper as-is: its front end is already conv
                  based (signal mean/std norm, pre-emphasis, conv DFT, mel conv, log,
                  mean norm). Optional level_norm_dbfs gain is rebuilt in-graph.
  wespeaker_onnx  torchaudio kaldi fbank (x 2^15, hamming, snip_edges, CMN) + the ONNX net.
  sherpa          kaldi-native-fbank as sherpa-onnx sets it up from the ONNX metadata:
                    nemo        hann (periodic), no DC removal, librosa/slaney mel 0-7600 Hz,
                                snip_edges, per-feature mean/std norm, [1, 80, T] + length
                    3d-speaker  povey, DC removal, kaldi mel 20-7600 Hz, snip_edges=false,
                                global-mean (CMN), samples scaled by 2^15 unless
                                normalize_samples=1

`fp32_scopes` names the submodules that stay fp32 in an fp16 model: the front end.
Its power spectrum spans far more range than fp16 has (and wespeaker scales by 2^15).
"""
from __future__ import annotations

import importlib.util
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

from .frontends import FbankFrontend
from .onnx_torch import OnnxModule

RUNTIMES = Path(__file__).resolve().parents[1] / "runtimes"


def load_runtime(name: str):
    path = RUNTIMES / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"vp_runtime_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    if str(RUNTIMES) not in sys.path:
        sys.path.insert(0, str(RUNTIMES))
    spec.loader.exec_module(mod)
    return mod


@dataclass
class Built:
    module: nn.Module
    dim: int
    fp32_scopes: list = field(default_factory=list)
    frontend: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)
    # called with the chosen input lengths (samples) before tracing; may make the
    # graph static-shape friendly for exactly those lengths, or raise if it cannot
    prepare: object = None
    default_enum: str | None = None
    default_shapes: str | None = None


# --------------------------------------------------------------------------- ReDimNet static-shape patch
def _redimnet_static(wrap: nn.Module, lengths: list[int]) -> list[str]:
    """Rewrite ReDimNet2's shape arithmetic so the traced graph has no runtime-computed
    reshape targets (Core ML then keeps it off GPU / ANE, CPU only, ~10x slower).

    Same math: batch is 1, channel / freq sizes are constants, time is -1, and the
    backbone's crop of T to a multiple of the time stride becomes a constant slice.
    That crop is only constant when every enumerated length leaves the same remainder,
    so lengths are checked here (whole seconds all drop 3 frames)."""
    import types

    bb = wrap.backbone
    if type(bb).__name__ != "ReDimNet2" or bb.is_subnet or bb.return_all_outputs or \
            wrap.pad_right_samples is not None or getattr(bb, "dual_agg", False):
        raise NotImplementedError("static patch covers plain ReDimNet2 only")
    ts = int(bb.time_stride)
    crops = set()
    with torch.no_grad():
        for n in lengths:
            t = int(wrap.spec(torch.zeros(1, n)).shape[-1])
            crops.add(t - (t // ts) * ts)
    if len(crops) != 1:
        raise ValueError(f"input lengths give different time crops {sorted(crops)}; use lengths that are "
                         f"multiples of {160 * ts} samples (e.g. whole seconds)")
    crop = crops.pop()

    def to1d_fwd(self, x):
        return x.permute(0, 2, 1, 3).reshape(1, int(x.shape[1]) * int(x.shape[2]), -1)

    def to2d_fwd(self, x):
        return x.reshape(1, self.f, self.c, -1).permute(0, 2, 1, 3)

    def mha_fwd(self, h):
        if self.qk_rope:
            raise NotImplementedError("rope attention")
        H, D = self.num_heads, self.head_dim
        q = self.q_proj(h).reshape(1, -1, H, D).transpose(1, 2)
        k = self.k_proj(h).reshape(1, -1, H, D).transpose(1, 2)
        v = self.v_proj(h).reshape(1, -1, H, D).transpose(1, 2)
        if self.qk_norm:
            q = torch.nn.functional.normalize(q, dim=-1)
            k = torch.nn.functional.normalize(k, dim=-1)
        a = torch.softmax(torch.matmul(q, k.transpose(-1, -2)) * self.scaling, dim=-1)
        o = torch.matmul(a, v).transpose(1, 2).reshape(1, -1, self.embed_dim)
        return self.out_proj(o)

    def astp_fwd(self, x):
        if x.dim() == 4:
            x = x.reshape(1, int(x.shape[1]) * int(x.shape[2]), -1)
        if self.global_context_att:
            mean = torch.mean(x, dim=-1, keepdim=True)
            std = torch.sqrt(torch.var(x, dim=-1, keepdim=True) + 1e-7)
            zero = x * 0.0
            x_in = torch.cat((x, zero + mean, zero + std), dim=1)
        else:
            x_in = x
        alpha = torch.tanh(self.linear1(x_in))
        alpha = torch.softmax(self.linear2(alpha), dim=2)
        mean = torch.sum(alpha * x, dim=2)
        var = torch.sum(alpha * (x ** 2), dim=2) - mean ** 2
        std = torch.sqrt(var.clamp(min=1e-7))
        return torch.cat([mean, std], dim=1)

    def bb_fwd(self, inp):
        if crop:
            inp = inp[:, :, :, :-crop]
        x = self.stem(inp)
        if self.agg_gnorm:
            x = self.stem_gnorm(x)
        outs = [x]
        for i in range(self.num_stages):
            outs.extend(self.run_stage(outs, i))
        x = self.fin_wght1d(outs)
        x = self.fin_to2d(x)
        return self.head(x)

    def wrap_fwd(self, x):
        x = self.spec(x)
        if x.ndim == 3:
            x = x.unsqueeze(1)
        out = self.backbone(x)
        if out.ndim == 4:
            out = out.reshape(1, int(out.shape[1]) * int(out.shape[2]), -1)
        if self.before_pool_offset is not None:
            out = out[:, :, self.before_pool_offset:]
        out = self.bn(self.pool(out))
        out = self.linear(out)
        if self.bn2 is not None:
            out = self.bn2(out)
        return out

    patched = {}
    for m in wrap.modules():
        name = type(m).__name__
        fn = {"to1d": to1d_fwd, "to2d": to2d_fwd, "MultiHeadAttention": mha_fwd, "ASTP": astp_fwd}.get(name)
        if fn is not None:
            m.forward = types.MethodType(fn, m)
            patched[name] = patched.get(name, 0) + 1
    bb.forward = types.MethodType(bb_fwd, bb)
    wrap.forward = types.MethodType(wrap_fwd, wrap)
    return [f"static-shape patch: {patched}, constant time crop {crop} frames (stride {ts}); "
            f"valid for input lengths that are multiples of {160 * ts} samples"]


def _patch_hardtanh(module: nn.Module) -> int:
    n = 0
    for name, child in module.named_children():
        if isinstance(child, nn.Hardtanh) and child.min_val == 0.0:
            setattr(module, name, nn.ReLU())
            n += 1
        else:
            n += _patch_hardtanh(child)
    return n


class LevelNorm(nn.Module):
    """runtimes/redimnet.py level_norm_dbfs: gain = min(target / rms, 0.99 / peak)."""

    def __init__(self, dbfs: float):
        super().__init__()
        self.target = float(10 ** (dbfs / 20))

    def forward(self, x):
        rms = torch.sqrt((x * x).mean(dim=1, keepdim=True))
        peak = torch.amax(torch.abs(x), dim=1, keepdim=True)
        g = torch.minimum(self.target / torch.clamp(rms, min=1e-7), 0.99 / torch.clamp(peak, min=1e-7))
        return x * g


class ReDimNetFused(nn.Module):
    def __init__(self, wrap: nn.Module, level_norm_dbfs=None):
        super().__init__()
        self.level = LevelNorm(level_norm_dbfs) if level_norm_dbfs is not None else None
        self.net = wrap

    def forward(self, audio):
        if self.level is not None:
            audio = self.level(audio)
        return self.net(audio)


class FbankOnnxFused(nn.Module):
    def __init__(self, frontend: FbankFrontend, net: OnnxModule, with_length: bool, out_index: int | None):
        super().__init__()
        self.frontend = frontend
        self.net = net
        self.with_length = with_length
        self.out_index = out_index

    def forward(self, audio):
        feat = self.frontend(audio)
        if self.with_length:
            n = feat.shape[2]
            length = n.to(torch.int64).reshape(1) if isinstance(n, torch.Tensor) \
                else torch.tensor([n], dtype=torch.int64)
            out = self.net(feat, length)
        else:
            out = self.net(feat)
        if self.out_index is not None:
            out = out[self.out_index]
        return out.reshape(1, -1)


def _onnx_meta(path: Path) -> dict:
    import onnx

    m = onnx.load(str(path), load_external_data=False)
    return {p.key: p.value for p in m.metadata_props}


def build(model_id: str, meta: dict, model_dir: Path) -> Built:
    runtime = meta["runtime"]
    if runtime == "redimnet":
        rt = load_runtime("redimnet")
        import os

        saved = os.environ.pop("REDIMNET_DEVICE", None)
        try:
            emb = rt.Embedder(model_dir, dict(meta, device="cpu"), threads=3)
        finally:
            if saved is not None:
                os.environ["REDIMNET_DEVICE"] = saved
        wrap = emb.model.cpu().eval()
        n = _patch_hardtanh(wrap)
        fused = ReDimNetFused(wrap, meta.get("level_norm_dbfs")).eval()
        notes = [f"ReDimNet front end kept as the model's own conv graph (net.spec); hardtanh->relu patched: {n}"]
        if meta.get("level_norm_dbfs") is not None:
            notes.append(f"level_norm_dbfs={meta['level_norm_dbfs']} rebuilt in-graph (LevelNorm)")
        built = Built(fused, int(meta["dim"]), fp32_scopes=["spec", "level"],
                      frontend={"kind": "redimnet_own", "level_norm_dbfs": meta.get("level_norm_dbfs")},
                      notes=notes, default_enum="1:10:1")
        if type(wrap).__name__ == "ReDimNet2Wrap":
            built.prepare = lambda lengths: built.notes.extend(_redimnet_static(wrap, lengths))
        return built

    onnx_files = [f for f in meta.get("files", []) if str(f).endswith(".onnx")]
    if not onnx_files:
        raise ValueError(f"{model_id}: no .onnx in files")
    onnx_path = model_dir / onnx_files[0]
    om = _onnx_meta(onnx_path)

    if runtime == "wespeaker_onnx":
        fe = FbankFrontend(window="hamming", scale=32768.0, remove_dc=True, preemph=0.97,
                           snip_edges=True, mel="kaldi", low_freq=20.0, high_freq=0.0,
                           norm="cmn", layout="tf")
        net = OnnxModule(onnx_path)
        return Built(FbankOnnxFused(fe, net, False, None).eval(), int(meta["dim"]),
                     fp32_scopes=["frontend"], frontend={"kind": "torchaudio_kaldi", **fe.cfg},
                     notes=["front end = runtimes/wespeaker_onnx.py (torchaudio kaldi fbank x2^15, hamming, CMN)"])

    if runtime == "sherpa":
        fw = om.get("framework", "")
        if fw == "nemo":
            win = om.get("window_type", "hann")
            fe = FbankFrontend(n_mels=int(om.get("feat_dim", 80)), window=win, scale=1.0,
                               remove_dc=False, preemph=0.97, snip_edges=True, mel="knf_librosa",
                               low_freq=0.0, high_freq=-400.0,
                               norm="per_feature" if om.get("feature_normalize_type") == "per_feature" else None,
                               norm_eps=1e-5, layout="ft",
                               frame_length=int(float(om.get("window_size_ms", 25)) * 16),
                               frame_shift=int(float(om.get("window_stride_ms", 10)) * 16))
            net = OnnxModule(onnx_path, outputs=["embs"])
            return Built(FbankOnnxFused(fe, net, True, None).eval(), int(meta["dim"]),
                         fp32_scopes=["frontend"], frontend={"kind": "sherpa_knf_nemo", **fe.cfg},
                         notes=["front end = sherpa-onnx NeMo path (knf is_librosa, snip_edges, per_feature norm)"])
        if fw in ("3d-speaker", "3dspeaker"):
            norm_samples = om.get("normalize_samples", "1") in ("1", "true", "True")
            fnt = om.get("feature_normalize_type", "")
            fe = FbankFrontend(window="povey", scale=1.0 if norm_samples else 32768.0, remove_dc=True,
                               preemph=0.97, snip_edges=False, mel="kaldi", low_freq=20.0,
                               high_freq=-400.0, norm="cmn" if fnt == "global-mean" else None,
                               layout="tf")
            net = OnnxModule(onnx_path)
            return Built(FbankOnnxFused(fe, net, False, None).eval(), int(meta["dim"]),
                         fp32_scopes=["frontend"], frontend={"kind": "sherpa_knf_general", **fe.cfg},
                         notes=["front end = sherpa-onnx general path (knf povey, snip_edges=false, global-mean)"])
        raise NotImplementedError(f"sherpa framework {fw!r}")

    raise NotImplementedError(f"runtime {runtime!r}")
