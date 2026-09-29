"""Landmark audio fingerprints (Shazam-style peak pairs) for duplicate / shared-audio detection.

Robust to re-encoding and small level changes: two recordings that hold the same audio share many
(f1, f2, dt) peak-pair hashes at one consistent time offset; two different utterances by the same
voice do not. Used by the voiceprint answer-key audit (scripts/voiceprint/audit/).
"""
from __future__ import annotations

import numpy as np
from scipy.ndimage import maximum_filter

SR = 16000
N_FFT = 1024
HOP = 160                      # 10 ms frames
F_LO, F_HI = 20, 256           # bins: ~310 Hz .. 4000 Hz (survives phone band and Opus)
PEAKS_PER_S = 30
FANOUT = 5
DT_MAX = 63                    # frames
DF_MAX = 63                    # bins


def spectrogram(x: np.ndarray, block_frames: int = 6000) -> np.ndarray:
    """Log-magnitude STFT [frames, bins], computed in blocks so hour-long audio stays small."""
    x = np.asarray(x, dtype=np.float32)
    if len(x) < N_FFT:
        x = np.pad(x, (0, N_FFT - len(x)))
    n = 1 + (len(x) - N_FFT) // HOP
    win = np.hanning(N_FFT).astype(np.float32)
    out = np.empty((n, F_HI - F_LO), dtype=np.float32)
    base = np.arange(N_FFT)[None, :]
    for s0 in range(0, n, block_frames):
        s1 = min(n, s0 + block_frames)
        idx = base + HOP * np.arange(s0, s1)[:, None]
        out[s0:s1] = np.log(np.abs(np.fft.rfft(x[idx] * win, axis=1))[:, F_LO:F_HI] + 1e-6)
    return out


def peaks(logs: np.ndarray, peaks_per_s: int = PEAKS_PER_S) -> tuple[np.ndarray, np.ndarray]:
    """Local maxima in a (11 frame x 15 bin) neighbourhood, strongest PEAKS_PER_S per second."""
    mx = maximum_filter(logs, size=(11, 15), mode="constant", cval=-np.inf)
    floor = np.median(logs) + 1.0
    t, f = np.nonzero((logs == mx) & (logs > floor))
    if len(t) == 0:
        return t, f
    keep = int(peaks_per_s * logs.shape[0] * HOP / SR) + 1
    if len(t) > keep:
        order = np.argsort(-logs[t, f])[:keep]
        t, f = t[order], f[order]
    o = np.lexsort((f, t))
    return t[o], f[o]


def hashes(x: np.ndarray, peaks_per_s: int = PEAKS_PER_S, fanout: int = FANOUT) -> tuple[np.ndarray, np.ndarray]:
    """Returns (hash int64 [K], anchor frame int32 [K])."""
    t, f = peaks(spectrogram(x), peaks_per_s)
    n = len(t)
    if n < 2:
        return np.zeros(0, np.int64), np.zeros(0, np.int32)
    K = 48
    i = np.arange(n)[:, None]
    j = i + np.arange(1, K + 1)[None, :]
    inb = j < n
    jj = np.minimum(j, n - 1)
    dt = t[jj] - t[i]
    df = f[jj] - f[i]
    ok = inb & (dt >= 1) & (dt <= DT_MAX) & (np.abs(df) <= DF_MAX)
    rank = np.cumsum(ok, axis=1)
    ok &= rank <= fanout
    ii, kk = np.nonzero(ok)
    a_f = f[ii].astype(np.int64)
    d_f = df[ii, kk].astype(np.int64)
    d_t = dt[ii, kk].astype(np.int64)
    h = (a_f << 14) | ((d_f + DF_MAX) << 7) | d_t
    return h, t[ii].astype(np.int32)


def match_all(h: np.ndarray, t: np.ndarray, item: np.ndarray, group: np.ndarray | None = None,
              max_bucket: int = 400, min_count: int = 4, off_bin: int = 2):
    """All-vs-all matching over a flat hash table.

    h, t, item: per-hash arrays (hash, anchor frame, item index). group (optional, per item): only
    pairs of items in *different* groups are counted (e.g. different sessions).
    Returns dict {(a, b): (best_count, offset_frames)} with a < b, best_count = hashes agreeing on one
    offset bin plus its two neighbouring bins. Offset = t_a - t_b in frames (10 ms).
    """
    best: dict[tuple[int, int], tuple[int, int]] = {}
    if len(h) == 0:
        return best
    o = np.argsort(h, kind="stable")
    h, t, item = h[o], t[o], item[o]
    bounds = np.flatnonzero(np.diff(h)) + 1
    starts = np.concatenate([[0], bounds])
    ends = np.concatenate([bounds, [len(h)]])
    sizes = ends - starts
    ok = (sizes >= 2) & (sizes <= max_bucket)
    starts, sizes = starts[ok], sizes[ok]
    n_items = int(item.max()) + 1
    OFFR = 200001
    parts_k, parts_c = [], []
    chunk_pairs = 15_000_000
    npair = sizes * (sizes - 1) // 2
    cum = np.cumsum(npair)
    i = 0
    while i < len(starts):
        base = cum[i - 1] if i else 0
        j = int(np.searchsorted(cum, base + chunk_pairs, side="right"))
        j = max(j, i + 1)
        s, z = starts[i:j], sizes[i:j]
        elem = np.repeat(s, z) + (np.arange(z.sum()) - np.repeat(np.cumsum(z) - z, z))
        rank = elem - np.repeat(s, z)
        cnt = np.repeat(z, z) - rank - 1
        first = np.repeat(elem, cnt)
        step = np.arange(cnt.sum()) - np.repeat(np.cumsum(cnt) - cnt, cnt) + 1
        second = first + step
        a, b = item[first], item[second]
        keep = a != b
        if group is not None:
            keep &= group[a] != group[b]
        first, second = first[keep], second[keep]
        a, b = a[keep].astype(np.int64), b[keep].astype(np.int64)
        ta, tb = t[first].astype(np.int64), t[second].astype(np.int64)
        swap = a > b
        a2 = np.where(swap, b, a)
        b2 = np.where(swap, a, b)
        off = np.where(swap, tb - ta, ta - tb)
        key = (a2 * n_items + b2) * OFFR + (np.floor_divide(off, off_bin) + OFFR // 2)
        u, c = np.unique(key, return_counts=True)
        parts_k.append(u)
        parts_c.append(c)
        i = j
    if not parts_k:
        return best
    k = np.concatenate(parts_k)
    c = np.concatenate(parts_c)
    o = np.argsort(k, kind="stable")
    k, c = k[o], c[o]
    b_ = np.flatnonzero(np.diff(k)) + 1
    st = np.concatenate([[0], b_])
    k = k[st]
    c = np.add.reduceat(c, st)
    # neighbour bins
    idx_l = np.searchsorted(k, k - 1)
    idx_r = np.searchsorted(k, k + 1)
    left = np.where((idx_l < len(k)) & (k[np.minimum(idx_l, len(k) - 1)] == k - 1), c[np.minimum(idx_l, len(k) - 1)], 0)
    right = np.where((idx_r < len(k)) & (k[np.minimum(idx_r, len(k) - 1)] == k + 1), c[np.minimum(idx_r, len(k) - 1)], 0)
    tot = c + left + right
    m = tot >= min_count
    k, tot = k[m], tot[m]
    pair = k // OFFR
    offb = k % OFFR - OFFR // 2
    for p_, v_, ob in zip(pair.tolist(), tot.tolist(), offb.tolist()):
        a_, b2_ = divmod(p_, n_items)
        cur = best.get((a_, b2_))
        if cur is None or v_ > cur[0]:
            best[(a_, b2_)] = (int(v_), int(ob * off_bin))
    return best
