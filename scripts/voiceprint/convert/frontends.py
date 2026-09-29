"""Fbank front ends as plain conv / matmul graphs, for fused Core ML voiceprint models.

Swift feeds raw 16 kHz float samples to the fused model; there is no FFT or mel
code on the Swift side. So each model's feature pipeline is rebuilt here from ops
Core ML handles well: one strided Conv1d holds framing + DC removal +
pre-emphasis + window + DFT (all linear per frame, folded into one kernel), then
power, a 1x1 conv for the mel matrix, log, and the model's normalization.

`FbankFrontend` reproduces, by configuration:
  * torchaudio.compliance.kaldi.fbank (WeSpeaker, 3D-Speaker ModelScope recipes)
  * kaldi-native-fbank as sherpa-onnx configures it, including its librosa mel
    variant (sherpa's NeMo path) and snip_edges=false edge reflection.
Normalization: "cmn" (subtract the mean over time) or "per_feature" (NeMo /
sherpa: (x - mean) / (population std + 1e-5) per mel bin over time).

Every choice here is checked numerically against the reference implementation
(`reference_fbank`) by convert_coreml.py before conversion.
"""
from __future__ import annotations

import math

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

FLOAT_EPS = float(np.finfo(np.float32).eps)  # 1.1920929e-07, kaldi / knf log floor


def make_window(kind: str, length: int) -> np.ndarray:
    i = np.arange(length, dtype=np.float64)
    if kind == "povey":
        return np.power(0.5 - 0.5 * np.cos(2 * np.pi * i / (length - 1)), 0.85)
    if kind == "hamming":  # kaldi / knf / torchaudio kaldi: symmetric
        return 0.54 - 0.46 * np.cos(2 * np.pi * i / (length - 1))
    if kind == "hanning":  # kaldi symmetric hann
        return 0.5 - 0.5 * np.cos(2 * np.pi * i / (length - 1))
    if kind == "hann":  # knf "hann": periodic, like torch.hann_window
        return 0.5 - 0.5 * np.cos(2 * np.pi * i / length)
    if kind == "rectangular":
        return np.ones(length)
    raise ValueError(f"unknown window {kind}")


def kaldi_mel_banks(n_mels: int, nfft: int, sr: int, low: float, high: float) -> np.ndarray:
    """Kaldi mel matrix [n_mels, nfft//2 + 1] (Nyquist column zero, as kaldi and knf)."""
    import torchaudio.compliance.kaldi as K

    banks, _ = K.get_mel_banks(n_mels, nfft, float(sr), float(low), float(high), 100.0, -500.0, 1.0)
    banks = banks.numpy().astype(np.float64)
    return np.concatenate([banks, np.zeros((n_mels, 1))], axis=1)


def knf_librosa_mel_banks(n_mels: int, nfft: int, sr: int, low: float, high: float,
                          slaney_scale: bool = True, slaney_norm: bool = True) -> np.ndarray:
    """kaldi-native-fbank `InitLibrosaMelBanks` (is_librosa=true), in float32 like the C++."""
    f32 = np.float32
    num_fft_bins = nfft // 2
    nyquist = f32(0.5 * sr)
    low = f32(low)
    high = f32(high) if high > 0 else f32(nyquist + f32(high))
    fft_bin_width = f32(sr) / f32(nfft)

    def mel(fq):
        fq = f32(fq)
        if not slaney_scale:
            return f32(1127.0) * f32(np.log1p(fq / f32(700.0)))
        if fq <= 1000:
            return f32(fq * f32(3) / f32(200.0))
        return f32(f32(15) + f32(14.545078505785561) * f32(np.log(f32(fq / f32(1000)))))

    def inv(m):
        m = f32(m)
        if not slaney_scale:
            return f32(700.0) * f32(np.expm1(m / f32(1127.0)))
        if m <= 15:
            return f32(f32(200.0) / f32(3) * m)
        return f32(f32(1000) * f32(np.exp(f32((m - f32(15)) * f32(0.06875177742094911)))))

    mlo, mhi = mel(low), mel(high)
    delta = f32((mhi - mlo) / f32(n_mels + 1))
    out = np.zeros((n_mels, num_fft_bins + 1), dtype=np.float64)
    for b in range(n_mels):
        l_hz = inv(f32(mlo + f32(b) * delta))
        c_hz = inv(f32(mlo + f32(b + 1) * delta))
        r_hz = inv(f32(mlo + f32(b + 2) * delta))
        for i in range(num_fft_bins + 1):
            hz = f32(fft_bin_width * f32(i))
            if l_hz < hz < r_hz:
                if hz <= c_hz:
                    w = f32((hz - l_hz) / (c_hz - l_hz))
                else:
                    w = f32((r_hz - hz) / (r_hz - c_hz))
                if slaney_norm:
                    w = f32(w * f32(f32(2) / (r_hz - l_hz)))
                out[b, i] = w
    return out


def frame_operator(length: int, remove_dc: bool, preemph: float) -> np.ndarray:
    """Per-frame linear op (L x L): DC removal then kaldi pre-emphasis (d[0] -= c * d[0])."""
    op = np.eye(length)
    if remove_dc:
        op = (np.eye(length) - np.ones((length, length)) / length) @ op
    if preemph:
        e = np.eye(length)
        for n in range(1, length):
            e[n, n - 1] = -preemph
        e[0, 0] = 1.0 - preemph
        op = e @ op
    return op


class FbankFrontend(nn.Module):
    """Raw audio [1, N] (float, [-1, 1]) -> normalized log-mel.

    layout "tf" returns [1, T, n_mels]; "ft" returns [1, n_mels, T].
    """

    def __init__(self, *, n_mels=80, sample_rate=16000, frame_length=400, frame_shift=160,
                 nfft=512, window="povey", scale=1.0, remove_dc=True, preemph=0.97,
                 snip_edges=True, mel="kaldi", low_freq=20.0, high_freq=0.0,
                 log_floor=FLOAT_EPS, norm="cmn", norm_eps=1e-5, layout="tf"):
        super().__init__()
        self.cfg = dict(n_mels=n_mels, sample_rate=sample_rate, frame_length=frame_length,
                        frame_shift=frame_shift, nfft=nfft, window=window, scale=scale,
                        remove_dc=remove_dc, preemph=preemph, snip_edges=snip_edges, mel=mel,
                        low_freq=low_freq, high_freq=high_freq, log_floor=log_floor,
                        norm=norm, norm_eps=norm_eps, layout=layout)
        L = frame_length
        self.shift = frame_shift
        self.nfreq = nfft // 2 + 1
        self.snip_edges = snip_edges
        self.log_floor = float(log_floor)
        self.norm = norm
        self.norm_eps = float(norm_eps)
        self.layout = layout
        # snip_edges=false (kaldi): frame m starts at m*shift + shift//2 - L//2, edges
        # reflect symmetrically (-1 -> 0, N -> N-1); frames = (N + shift//2) // shift.
        self.pad_left = L // 2 - frame_shift // 2
        self.pad_right = L // 2

        w = make_window(window, L).reshape(1, L)
        k = np.arange(self.nfreq).reshape(-1, 1)
        n = np.arange(L).reshape(1, -1)
        ang = 2.0 * np.pi * k * n / nfft
        op = frame_operator(L, remove_dc, preemph)
        m_re = (np.cos(ang) * w) @ op * scale
        m_im = (-np.sin(ang) * w) @ op * scale
        dft = np.concatenate([m_re, m_im], axis=0).reshape(2 * self.nfreq, 1, L)
        self.register_buffer("dft", torch.from_numpy(dft.astype(np.float32)))

        if mel == "kaldi":
            banks = kaldi_mel_banks(n_mels, nfft, sample_rate, low_freq, high_freq)
        elif mel == "knf_librosa":
            banks = knf_librosa_mel_banks(n_mels, nfft, sample_rate, low_freq, high_freq)
        else:
            raise ValueError(mel)
        self.register_buffer("mel", torch.from_numpy(banks.astype(np.float32).reshape(n_mels, self.nfreq, 1)))

    def forward(self, wav: torch.Tensor) -> torch.Tensor:
        x = wav
        if not self.snip_edges:
            left = torch.flip(x[:, : self.pad_left], dims=[1])
            right = torch.flip(x[:, -self.pad_right:], dims=[1])
            x = torch.cat([left, x, right], dim=1)
        x = x.unsqueeze(1)  # [1, 1, N]
        lin = F.conv1d(x, self.dft, stride=self.shift)  # [1, 2F, T]
        re = lin[:, : self.nfreq, :]
        im = lin[:, self.nfreq:, :]
        power = re * re + im * im
        mel = F.conv1d(power, self.mel)  # [1, M, T]
        feat = torch.log(torch.clamp(mel, min=self.log_floor))
        mean = feat.mean(dim=2, keepdim=True)
        if self.norm == "cmn":
            feat = feat - mean
        elif self.norm == "per_feature":
            d = feat - mean
            std = torch.sqrt((d * d).mean(dim=2, keepdim=True))
            feat = d / (std + self.norm_eps)
        elif self.norm not in (None, "none"):
            raise ValueError(self.norm)
        if self.layout == "tf":
            feat = feat.transpose(1, 2)
        return feat


# --------------------------------------------------------------------------- references
def torchaudio_kaldi_fbank(wav: np.ndarray, *, scale=1.0, window="povey", n_mels=80,
                           low_freq=20.0, high_freq=0.0, snip_edges=True, norm="cmn") -> np.ndarray:
    """Reference: torchaudio kaldi fbank (+ CMN). Returns [T, n_mels]."""
    import torchaudio.compliance.kaldi as K

    w = torch.from_numpy(np.ascontiguousarray(wav, dtype=np.float32))[None] * scale
    fb = K.fbank(w, num_mel_bins=n_mels, frame_length=25, frame_shift=10, dither=0.0,
                 sample_frequency=16000, window_type=window, use_energy=False,
                 low_freq=low_freq, high_freq=high_freq, snip_edges=snip_edges).numpy()
    if norm == "cmn":
        fb = fb - fb.mean(axis=0, keepdims=True)
    return fb
