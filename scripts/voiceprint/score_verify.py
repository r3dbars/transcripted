#!/usr/bin/env python3
"""Verification scorer for the voiceprint bake-off.

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. VP = data/eval/voiceprint (or $VP_ROOT).

Runs on whatever exists and skips what is missing: sets without READY, models or conditions
without embeddings, cohorts that are not there yet. Results are cached per (model, set) and
recomputed only when an input changes, so running it again is cheap.

Trials, per (set, bucket). One list per (set, bucket), shared by every model and condition,
cached in VP/results/trials/<set>__b<bucket>.npz with a fingerprint of segments.jsonl:
  target      same speaker, different session (never the same session); never a stranger_only speaker
  non-target  different speakers, stranger_only speakers included (same-session pairs allowed)
  at most --max-trials of each, sampled uniformly without replacement, seeded by (set, bucket).
Trial conditions:
  clean, opus12, phone, noisy         both sides in that condition
  clean>opus12, clean>phone, clean>noisy   enroll side clean, test side degraded ("cross")

Scores, three variants, each reported for every model:
  cos       raw cosine
  centered  subtract one fixed mean vector (the mean raw embedding of the clean cohort set, as the
            app could ship it), L2-normalize, cosine. Fixes models whose raw cosines are squashed
            near 1 (x-vector heads).
  asnorm    adaptive S-norm on the raw cosine, top-300 cohort, cohort clips in the same condition
            as the side being normalized (falling back to clean).
The cohort is a disjoint set: yodas for every set except yodas itself, which uses libri. Cohort
clips whose audio hash matches a clip of the scored set are dropped. The headline uses each
model's best variant (highest pooled human cross TAR@1e-3; --rank-mode fixes one instead), and
the output says which variant won.

Metrics per cell: EER; minDCF (P_target 0.01, C_miss = C_fa = 1, normalized); TAR at FAR 1e-3 and
1e-4 (threshold allows at most floor(FAR * n_nontarget) false accepts, so report n: 30k
non-targets leave 3 false accepts at 1e-4); AUC. Bootstrap 95% CIs resample speakers with
replacement (a target trial of speaker s counts m_s times, a non-target of a, b counts m_a * m_b
times); replicate seeds depend only on the set, so replicates are paired across models and the
Delta-vs-baseline CI is a paired bootstrap.

Pooled summaries: mean over sets of (mean over that set's cells). "human" = vox1o, libri, ami,
icsi. yodas is reported on its own (its labels came from TitaNet/CAM++). "one threshold" rows pool
all trials of a scope and group under a single threshold, which gives enough non-targets for
FAR 1e-4 to mean something.

Leakage checks (the set is excluded and the run exits 2 when any fail):
  - a target trial with both sides from the same session, or the same source file
  - two different seg_ids whose clean clips hold identical audio (sha1 of the PCM data)
  - duplicate seg_id rows, a trial that pairs a clip with itself, label/speaker mismatches

Drop lists: seg_ids in VP/results/audit/drop_<set>.txt (the answer-key audit: duplicate videos,
label errors, second talkers) are removed before trials are built, and the trial cache is keyed
on the drop-list content. --no-drops scores the sets as built and writes every output with a
"_nodrops" suffix (results/verify_nodrops/, verify_summary_nodrops.*, trials/*__nodrops.npz), so
it never overwrites the default results.

Outputs:
  VP/results/verify/<model_id>.json        full detail for one model
  VP/results/verify_summary.csv            long format: model x scope x group x mode x metric
  VP/results/verify_summary.md             one row per model, ranked
  VP/results/verify/_cells/<model>/<set>.* per-(model, set) cache

Usage:
  score_verify.py [--models a,b] [--sets vox1o,libri] [--no-asnorm] [--boot 500] [--force]
--models / --sets only limit what is recomputed; the summary always covers every model with
valid cached results.
"""
from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, "3")

import argparse  # noqa: E402
import csv  # noqa: E402
import hashlib  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
import wave  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from scipy import sparse  # noqa: E402

SCORER_VERSION = "1.4"
TRIALS_VERSION = "2"  # trial file format
SEED_VERSION = "1"  # sampling seeds; changing it reshuffles every trial list
REPO = Path(__file__).resolve().parents[2]
DEFAULT_VP = Path(os.environ.get("VP_ROOT", str(REPO / "data" / "eval" / "voiceprint")))

HUMAN_SETS = ("vox1o", "libri", "ami", "icsi")
BIASED_SETS = ("yodas",)
CONDS = ("clean", "opus12", "phone", "noisy")
DEGRADED = ("opus12", "phone", "noisy")
CROSS = tuple(f"clean>{c}" for c in DEGRADED)
TRIAL_CONDS = CONDS + CROSS
GROUPS: dict[str, tuple[str, ...]] = {c: (c,) for c in TRIAL_CONDS}
GROUPS.update({"cross": CROSS, "degraded": DEGRADED, "overall": TRIAL_CONDS})
MODES = ("cos", "centered", "asnorm")
MODE_LABEL = {"cos": "raw cosine", "centered": "centered cosine", "asnorm": "AS-norm"}
FARS = {"tar@1e-3": 1e-3, "tar@1e-4": 1e-4}
METRICS = ("eer", "mindcf", "tar@1e-3", "tar@1e-4", "auc")
P_TARGET = 0.01
MAX_PER_CLASS = 30000
TOPK = 300
N_BOOT = 500
MIN_COHORT = 50
MAX_DROP_FRAC = 0.01  # a cell may lose at most 1% of its trials to clips a model failed to embed
TOP_NONTARGET_KEEP = 3000  # per cell, for the one-threshold pooled TAR
DUP_COS = 0.99  # clean target pairs at or above this cosine are flagged as suspected duplicate audio
BOOT_CHUNK = 100
BOOT_GRID = 1500  # rank-spaced ROC points per bootstrap replicate (plus exact points at low FAR)
BOOT_EXACT_FAR = 0.02  # below this FAR every operating point is kept, so TAR@FAR and minDCF stay exact
ENUMERATE_PAIRS_MAX = 4_000_000
AUDIT_DIR = Path("results") / "audit"


class DataError(Exception):
    """A set cannot be scored (malformed or incomplete data)."""


class LeakageError(DataError):
    """A trial list would leak: same session, same audio, or mislabeled pairs."""


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def stable_seed(*parts) -> int:
    return int.from_bytes(hashlib.sha256("|".join(map(str, parts)).encode()).digest()[:8], "little")


def ckey(cond: str) -> str:
    return cond.replace(">", "-to-")


def split_cond(cond: str) -> tuple[str, str]:
    if ">" in cond:
        a, b = cond.split(">", 1)
        return a, b
    return cond, cond


def save_npz(path: Path, **arrays) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    with open(tmp, "wb") as fh:
        np.savez(fh, **arrays)
    os.replace(tmp, path)


def save_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def file_sig(path: Path) -> list[int] | None:
    try:
        s = path.stat()
    except FileNotFoundError:
        return None
    return [int(s.st_size), int(s.st_mtime_ns)]


# ----------------------------------------------------------------------------------------------
# Metrics


def curve_metrics(tp: np.ndarray, fp: np.ndarray, p_target: float = P_TARGET) -> dict[str, np.ndarray]:
    """Metrics from cumulative accept counts.

    tp, fp: (B, G) weighted counts of targets / non-targets accepted at each threshold, one column
    per distinct score, thresholds descending (the last column accepts everything).
    Returns metric -> (B,) float array (NaN where a replicate has no targets or no non-targets).
    """
    tp = np.asarray(tp, dtype=np.float64)
    fp = np.asarray(fp, dtype=np.float64)
    nb = tp.shape[0]
    tot_t = tp[:, -1:]
    tot_n = fp[:, -1:]
    zero = np.zeros((nb, 1))
    with np.errstate(invalid="ignore", divide="ignore"):
        tpr = np.hstack([zero, tp / tot_t])
        fpr = np.hstack([zero, fp / tot_n])
    frr = 1.0 - tpr
    rows = np.arange(nb)
    # EER: fpr - frr rises from -1 to +1; interpolate on the first segment where it crosses 0.
    k = np.clip(np.argmax(fpr >= frr, axis=1), 1, None)
    a0, a1 = fpr[rows, k - 1], fpr[rows, k]
    b0, b1 = frr[rows, k - 1], frr[rows, k]
    den = (a1 - a0) - (b1 - b0)
    with np.errstate(invalid="ignore", divide="ignore"):
        t = np.where(den > 0, (b0 - a0) / np.where(den > 0, den, 1.0), 0.0)
    out = {"eer": a0 + t * (a1 - a0)}
    dcf = (p_target * frr + (1.0 - p_target) * fpr).min(axis=1) / min(p_target, 1.0 - p_target)
    out["mindcf"] = np.minimum(dcf, 1.0)
    for name, far in FARS.items():
        # accept the longest prefix of thresholds whose false accepts stay within floor(far * n).
        cnt = (fp <= far * tot_n + 1e-6).sum(axis=1)
        out[name] = tpr[rows, cnt]
    out["auc"] = 0.5 * np.sum(np.diff(fpr, axis=1) * (tpr[:, 1:] + tpr[:, :-1]), axis=1)
    bad = (tot_t[:, 0] <= 0) | (tot_n[:, 0] <= 0)
    if bad.any():
        for v in out.values():
            v[bad] = np.nan
    return out


def boot_columns(ct: np.ndarray, cn: np.ndarray, grid_max: int = BOOT_GRID) -> np.ndarray:
    """ROC columns kept for bootstrap replicates.

    All columns when there are at most `grid_max`. Otherwise: every column that sits just before a
    non-target enters, up to FAR BOOT_EXACT_FAR (that is where the TAR@FAR optimum and, in
    practice, the minDCF optimum live, so both stay exact), plus `grid_max` rank-spaced columns
    for EER and AUC (error well under 0.1 point).
    """
    g = len(ct)
    if g <= grid_max:
        return np.arange(g)
    nxt = np.r_[cn[1:], cn[-1] + 1]
    exact = np.flatnonzero((nxt > cn) & (cn <= BOOT_EXACT_FAR * cn[-1]))
    spaced = np.linspace(0, g - 1, grid_max).round().astype(np.int64)
    return np.unique(np.r_[exact, spaced, g - 1])


def cell_metrics(scores: np.ndarray, labels: np.ndarray, spk_a: np.ndarray | None = None,
                 spk_b: np.ndarray | None = None, mult: np.ndarray | None = None,
                 chunk: int = BOOT_CHUNK, grid_max: int = BOOT_GRID) -> tuple[dict[str, float], np.ndarray | None]:
    """Point metrics (exact, full ROC), plus bootstrap replicates when `mult` (B, n_speakers) is given.

    Replicate weights: a target trial of speaker s counts mult[s]; a non-target trial between a
    and b counts mult[a] * mult[b]. Weighted counts per ROC column come from sparse products
    (speaker x column for targets, speaker-pair x column for non-targets), so a replicate costs
    O(trials) in C instead of a pass over the full ROC. Returns (point, reps (len(METRICS), B)).
    """
    scores = np.asarray(scores, dtype=np.float64)
    labels = np.asarray(labels, dtype=bool)
    order = np.argsort(-scores, kind="mergesort")
    s = scores[order]
    y = labels[order]
    ends = np.flatnonzero(np.r_[s[1:] != s[:-1], True])
    ct = np.cumsum(y)[ends]
    cn = (ends + 1) - ct
    pt = curve_metrics(ct[None, :], cn[None, :])
    point = {m: float(pt[m][0]) for m in METRICS}
    if mult is None:
        return point, None
    n_spk = mult.shape[1]
    cols = boot_columns(ct, cn, grid_max)
    nbins = len(cols)
    bins = np.searchsorted(ends[cols], np.arange(len(s)), side="left")  # sorted position -> ROC column
    a = np.asarray(spk_a, dtype=np.int64)[order]
    b = np.asarray(spk_b, dtype=np.int64)[order]
    q_t = sparse.csr_matrix((np.ones(int(y.sum())), (bins[y], a[y])), shape=(nbins, n_spk))
    lo, hi = np.minimum(a[~y], b[~y]), np.maximum(a[~y], b[~y])
    pairs, pidx = np.unique(lo * n_spk + hi, return_inverse=True)
    pa, pb = pairs // n_spk, pairs % n_spk
    q_n = sparse.csr_matrix((np.ones(len(pidx)), (bins[~y], pidx.reshape(-1))), shape=(nbins, len(pairs)))
    nb = mult.shape[0]
    reps = np.empty((len(METRICS), nb), dtype=np.float32)
    for lo_r in range(0, nb, chunk):
        m = mult[lo_r:lo_r + chunk].astype(np.float64)
        tp = np.cumsum(np.asarray(q_t @ m.T).T, axis=1)
        fp = np.cumsum(np.asarray(q_n @ (m[:, pa] * m[:, pb]).T).T, axis=1)
        res = curve_metrics(tp, fp)
        for i, name in enumerate(METRICS):
            reps[i, lo_r:lo_r + chunk] = res[name]
    return point, reps


def boot_multiplicities(n_speakers: int, n_boot: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return rng.multinomial(n_speakers, np.full(n_speakers, 1.0 / n_speakers), size=n_boot).astype(np.int32)


def one_threshold_tar(tgts: list[np.ndarray], tops: list[np.ndarray], n_nontarget: list[int]) -> dict:
    """TAR at each FAR under one threshold across all given cells (pooled trials)."""
    n_t = int(sum(len(t) for t in tgts))
    n_n = int(sum(n_nontarget))
    out = {"n_target": n_t, "n_nontarget": n_n}
    if n_t == 0 or n_n == 0:
        return out
    merged = np.sort(np.concatenate(tops))[::-1] if tops else np.zeros(0)
    truncated = any(len(tp) < n for tp, n in zip(tops, n_nontarget))
    allt = np.concatenate(tgts)
    for name, far in FARS.items():
        allowed = int(np.floor(far * n_n + 1e-9))
        if allowed < len(merged):
            thr = merged[allowed]
            out[name] = float(np.mean(allt > thr))
        elif not truncated:
            out[name] = 1.0
        else:
            out[name] = None
        out[f"fa_allowed@{name[4:]}"] = allowed
    return out


# ----------------------------------------------------------------------------------------------
# Sets, audit, trials


@dataclass
class Trials:
    bucket: int
    e: np.ndarray  # row index of the enroll side
    t: np.ndarray  # row index of the test side
    y: np.ndarray  # True = target
    meta: dict


@dataclass
class SetState:
    name: str
    seg_ids: np.ndarray
    index: dict
    spk: np.ndarray
    spk_names: list
    spk_stranger: np.ndarray
    sess: np.ndarray
    src: np.ndarray
    bucket: np.ndarray
    clip: list
    fp: str  # kept rows + drop-list content: keys the trial cache
    fp_full: str = ""  # every row of segments.jsonl: keys the audio-hash cache
    all_ids: list = field(default_factory=list)  # every row, including dropped ones
    all_clips: list = field(default_factory=list)
    dropped: frozenset = frozenset()
    drop_info: dict = field(default_factory=dict)
    hash_hex: np.ndarray | None = None
    hash_id: np.ndarray | None = None
    trials: dict = field(default_factory=dict)
    error: str | None = None
    leak: bool = False
    warnings: list = field(default_factory=list)
    _mult: dict = field(default_factory=dict)

    @property
    def n(self) -> int:
        return len(self.seg_ids)

    def mult(self, n_boot: int) -> np.ndarray | None:
        if n_boot <= 0:
            return None
        if n_boot not in self._mult:
            self._mult[n_boot] = boot_multiplicities(len(self.spk_names), n_boot, stable_seed(self.name, "boot", SEED_VERSION))
        return self._mult[n_boot]


def load_drops(vp: Path, name: str) -> dict:
    """seg_ids listed in VP/results/audit/drop_<set>.txt (blank lines and # comments ignored)."""
    path = vp / AUDIT_DIR / f"drop_{name}.txt"
    if not path.exists():
        return {"file": None, "ids": frozenset(), "sha1": "none"}
    text = path.read_text()
    ids = frozenset(l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#"))
    return {"file": str(path.relative_to(vp)), "ids": ids, "sha1": hashlib.sha1(text.encode()).hexdigest()}


def canon_fp(rows: list, extra: str = "") -> str:
    canon = sorted(
        f"{r['seg_id']}\t{r['speaker']}\t{r['session']}\t{int(r['bucket'])}\t{int(bool(r.get('stranger_only')))}"
        f"\t{(r.get('src') or {}).get('file') or ''}\t{r['clip']}"
        for r in rows
    )
    return hashlib.sha1(("\n".join(canon) + extra).encode()).hexdigest()


def load_segments(vp: Path, name: str, drops: dict | None = None) -> SetState:
    """Load segments.jsonl; with `drops` (from load_drops), those seg_ids are removed first."""
    path = vp / "sets" / name / "segments.jsonl"
    rows = []
    for ln, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError as exc:
            raise DataError(f"{path}:{ln}: bad JSON ({exc})") from None
        for f in ("seg_id", "speaker", "session", "bucket", "clip"):
            if f not in r:
                raise DataError(f"{path}:{ln}: missing field {f!r}")
        rows.append(r)
    if not rows:
        raise DataError(f"{path}: no rows")
    seg_ids = [str(r["seg_id"]) for r in rows]
    if len(set(seg_ids)) != len(seg_ids):
        seen, dup = set(), None
        for s in seg_ids:
            if s in seen:
                dup = s
                break
            seen.add(s)
        raise LeakageError(f"{name}: duplicate seg_id rows in segments.jsonl (e.g. {dup})")
    fp_full = canon_fp(rows)
    all_ids, all_clips = seg_ids, [str(r["clip"]) for r in rows]
    drop_ids = frozenset(drops["ids"]) if drops else frozenset()
    drop_info = {"applied": drops is not None, "file": drops["file"] if drops else None,
                 "listed": len(drop_ids), "removed": 0, "not_found": 0}
    if drop_ids:
        present = set(seg_ids)
        rows = [r for r in rows if str(r["seg_id"]) not in drop_ids]
        seg_ids = [str(r["seg_id"]) for r in rows]
        drop_info["removed"] = len(all_ids) - len(rows)
        drop_info["not_found"] = len(drop_ids - present)
        if not rows:
            raise DataError(f"{name}: the drop list removes every clip")
    fp = canon_fp(rows, f"\n#drops {drops['sha1']}" if drops else "")
    spk_names, spk_inv = np.unique([str(r["speaker"]) for r in rows], return_inverse=True)
    _, sess_inv = np.unique([str(r["session"]) for r in rows], return_inverse=True)
    src_files = [str((r.get("src") or {}).get("file") or "") for r in rows]
    src_names, src_inv = np.unique(src_files, return_inverse=True)
    src_inv = src_inv.astype(np.int32)
    if "" in set(src_files):
        src_inv[np.array([f == "" for f in src_files])] = -1
    stranger = np.array([bool(r.get("stranger_only")) for r in rows])
    spk_stranger = np.zeros(len(spk_names), dtype=bool)
    np.logical_or.at(spk_stranger, spk_inv, stranger)
    try:
        bucket = np.array([int(r["bucket"]) for r in rows], dtype=np.int32)
    except (TypeError, ValueError):
        raise DataError(f"{name}: non-integer bucket") from None
    st = SetState(
        name=name, seg_ids=np.array(seg_ids), index={s: i for i, s in enumerate(seg_ids)},
        spk=spk_inv.astype(np.int32), spk_names=list(spk_names), spk_stranger=spk_stranger,
        sess=sess_inv.astype(np.int32), src=src_inv, bucket=bucket, clip=[str(r["clip"]) for r in rows], fp=fp,
        fp_full=fp_full, all_ids=all_ids, all_clips=all_clips,
        dropped=frozenset(set(all_ids) - set(seg_ids)), drop_info=drop_info,
    )
    if drop_info["not_found"]:
        st.warnings.append(f"{drop_info['not_found']} seg_ids in {drop_info['file']} are not in segments.jsonl")
    bad_set = sum(1 for r in rows if r.get("set") not in (None, name))
    if bad_set:
        st.warnings.append(f"{bad_set} rows have a 'set' field other than {name!r}")
    # sanity notes, not errors
    n_sess = np.zeros(len(spk_names), dtype=np.int64)
    pairs = np.unique(np.stack([st.spk, st.sess], axis=1), axis=0)
    np.add.at(n_sess, pairs[:, 0], 1)
    odd = int(np.sum(spk_stranger & (n_sess > 1)))
    if odd:
        st.warnings.append(f"{odd} stranger_only speakers have more than one session (kept out of targets)")
    return st


def hash_clip(path: Path) -> str:
    try:
        with wave.open(str(path), "rb") as w:
            data = w.readframes(w.getnframes())
        return hashlib.sha1(data).hexdigest()
    except (wave.Error, EOFError):
        return hashlib.sha1(path.read_bytes()).hexdigest()


def audit_audio(vp: Path, st: SetState, force: bool = False) -> None:
    """Hash every clean clip (cached, over every row, dropped or not); raise LeakageError if two
    kept seg_ids share identical audio."""
    cache = vp / "results" / "trials" / f"{st.name}__audit.npz"
    key = f"{st.fp_full}|{file_sig(vp / 'sets' / st.name / 'READY')}"
    idx = None
    if cache.exists() and not force:
        try:
            z = np.load(cache, allow_pickle=False)
            if str(z["key"]) == key:
                idx = {s: h for s, h in zip(z["seg_id"].astype(str), z["sha1"].astype(str))}
                if not all(s in idx for s in st.seg_ids):
                    idx = None
        except Exception:
            idx = None
    if idx is None:
        idx, missing = {}, []
        for sid, clip in zip(st.all_ids, st.all_clips):
            p = vp / clip
            if p.exists():
                idx[sid] = hash_clip(p)
            elif sid not in st.dropped:
                missing.append(clip)
        if missing:
            raise DataError(f"{st.name}: {len(missing)} clean clips missing (e.g. {missing[0]})")
        save_npz(cache, key=np.array(key), seg_id=np.array(list(idx)), sha1=np.array(list(idx.values())))
    hashes = np.array([idx[s] for s in st.seg_ids])
    st.hash_hex = hashes
    uniq, inv, counts = np.unique(hashes, return_inverse=True, return_counts=True)
    st.hash_id = inv.astype(np.int64)
    if (counts > 1).any():
        dup_groups = np.flatnonzero(counts > 1)
        examples = []
        for g in dup_groups[:3]:
            members = st.seg_ids[inv == g]
            examples.append(" == ".join(members[:3]))
        n_clips = int(counts[dup_groups].sum())
        raise LeakageError(f"{st.name}: {n_clips} clips in {len(dup_groups)} groups share identical audio "
                           f"under different seg_ids, e.g. {'; '.join(examples)}")


def build_trials(st: SetState, bucket: int, max_per_class: int) -> Trials:
    rows = np.flatnonzero(st.bucket == bucket)
    rng_t = np.random.default_rng(stable_seed(st.name, bucket, "target", SEED_VERSION))
    rng_n = np.random.default_rng(stable_seed(st.name, bucket, "nontarget", SEED_VERSION))
    rng_o = np.random.default_rng(stable_seed(st.name, bucket, "orient", SEED_VERSION))
    spk = st.spk[rows]

    # targets: every same-speaker, different-session pair, then a seeded uniform sample
    order = np.argsort(spk, kind="mergesort")
    rs, sp = rows[order], spk[order]
    bounds = np.flatnonzero(np.r_[True, sp[1:] != sp[:-1], True])
    ta, tb = [], []
    for g0, g1 in zip(bounds[:-1], bounds[1:]):
        if g1 - g0 < 2 or st.spk_stranger[sp[g0]]:
            continue
        i, j = np.triu_indices(g1 - g0, 1)
        a, b = rs[g0 + i], rs[g0 + j]
        keep = st.sess[a] != st.sess[b]
        ta.append(a[keep])
        tb.append(b[keep])
    ta = np.concatenate(ta) if ta else np.zeros(0, dtype=np.int64)
    tb = np.concatenate(tb) if tb else np.zeros(0, dtype=np.int64)
    n_t_possible = len(ta)
    if len(ta) > max_per_class:
        sel = np.sort(rng_t.choice(len(ta), max_per_class, replace=False))
        ta, tb = ta[sel], tb[sel]

    # non-targets: pairs of different speakers
    n = len(rows)
    _, spk_counts = np.unique(spk, return_counts=True)
    n_n_possible = n * (n - 1) // 2 - int(np.sum(spk_counts * (spk_counts - 1) // 2))
    if n * (n - 1) // 2 <= ENUMERATE_PAIRS_MAX:
        i, j = np.triu_indices(n, 1)
        keep = spk[i] != spk[j]
        i, j = i[keep], j[keep]
        if len(i) > max_per_class:
            sel = np.sort(rng_n.choice(len(i), max_per_class, replace=False))
            i, j = i[sel], j[sel]
    else:
        want = min(max_per_class, n_n_possible)
        codes = np.zeros(0, dtype=np.int64)
        while len(codes) < want:
            m = 2 * (want - len(codes)) + 1000
            x = rng_n.integers(0, n, m)
            z = rng_n.integers(0, n, m)
            lo, hi = np.minimum(x, z), np.maximum(x, z)
            ok = (lo != hi) & (spk[lo] != spk[hi])
            codes = np.concatenate([codes, lo[ok].astype(np.int64) * n + hi[ok]])
            _, first = np.unique(codes, return_index=True)
            codes = codes[np.sort(first)]  # dedupe, keep draw order (uniform sample)
        codes = np.sort(codes[:want])
        i, j = codes // n, codes % n
    na, nb = rows[i], rows[j]

    e = np.concatenate([ta, na]).astype(np.int64)
    t = np.concatenate([tb, nb]).astype(np.int64)
    y = np.concatenate([np.ones(len(ta), bool), np.zeros(len(na), bool)])
    flip = rng_o.random(len(e)) < 0.5  # random enroll/test orientation (matters for cross trials)
    e, t = np.where(flip, t, e), np.where(flip, e, t)
    meta = {
        "version": TRIALS_VERSION, "set": st.name, "bucket": int(bucket), "fingerprint": st.fp,
        "max_per_class": int(max_per_class), "n_clips": int(n), "n_speakers": int(len(spk_counts)),
        "n_target": int(y.sum()), "n_nontarget": int((~y).sum()),
        "n_target_possible": int(n_t_possible), "n_nontarget_possible": int(n_n_possible),
        "n_nontarget_same_session": int(np.sum(st.sess[na] == st.sess[nb])),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    return Trials(bucket=int(bucket), e=e, t=t, y=y, meta=meta)


def trials_path(vp: Path, set_name: str, bucket: int, ns: str = "") -> Path:
    return vp / "results" / "trials" / f"{set_name}__b{bucket}{'__' + ns if ns else ''}.npz"


def load_or_build_trials(vp: Path, st: SetState, bucket: int, max_per_class: int, force: bool = False,
                         ns: str = "") -> Trials:
    path = trials_path(vp, st.name, bucket, ns)
    if path.exists() and not force:
        try:
            z = np.load(path, allow_pickle=False)
            meta = json.loads(str(z["meta"]))
            if (meta.get("fingerprint") == st.fp and meta.get("version") == TRIALS_VERSION
                    and meta.get("max_per_class") == max_per_class):
                ids = np.array([st.index.get(s, -1) for s in z["seg_ids"].astype(str)], dtype=np.int64)
                e, t = ids[z["enroll"]], ids[z["test"]]
                if len(e) and (e >= 0).all() and (t >= 0).all():
                    return Trials(bucket=int(bucket), e=e, t=t, y=z["label"].astype(bool), meta=meta)
            log(f"  trials {st.name} b{bucket}: segments.jsonl changed, rebuilding")
        except Exception as exc:
            log(f"  trials {st.name} b{bucket}: unreadable cache ({exc}), rebuilding")
    tr = build_trials(st, bucket, max_per_class)
    used, inv = np.unique(np.r_[tr.e, tr.t], return_inverse=True)
    inv = inv.reshape(-1).astype(np.int32)
    save_npz(path, seg_ids=st.seg_ids[used], enroll=inv[:len(tr.e)], test=inv[len(tr.e):],
             label=tr.y.astype(np.int8), meta=np.array(json.dumps(tr.meta)))
    return tr


def verify_trials(st: SetState, tr: Trials) -> None:
    """Raise LeakageError when the trial list breaks a rule. Runs on every load."""
    problems = []
    e, t, y = tr.e, tr.t, tr.y

    def ex(mask):
        k = np.flatnonzero(mask)[:2]
        return ", ".join(f"{st.seg_ids[e[i]]} / {st.seg_ids[t[i]]}" for i in k)

    if len(e) != len(t) or len(e) != len(y):
        raise LeakageError(f"{st.name} b{tr.bucket}: trial arrays differ in length")
    if (e == t).any():
        problems.append(f"{int((e == t).sum())} trials pair a clip with itself")
    wrong_b = (st.bucket[e] != tr.bucket) | (st.bucket[t] != tr.bucket)
    if wrong_b.any():
        problems.append(f"{int(wrong_b.sum())} trials use a clip from another bucket")
    same_spk = st.spk[e] == st.spk[t]
    if (y & ~same_spk).any():
        problems.append(f"target trials with different speakers ({ex(y & ~same_spk)})")
    if (~y & same_spk).any():
        problems.append(f"non-target trials with the same speaker ({ex(~y & same_spk)})")
    same_sess = st.sess[e] == st.sess[t]
    if (y & same_sess).any():
        problems.append(f"{int((y & same_sess).sum())} target trials have both sides from the same session "
                        f"({ex(y & same_sess)})")
    same_src = (st.src[e] == st.src[t]) & (st.src[e] >= 0)
    if (y & same_src).any():
        problems.append(f"{int((y & same_src).sum())} target trials have both sides from the same source file "
                        f"({ex(y & same_src)})")
    if y.any() and st.spk_stranger[st.spk[e[y]]].any():
        problems.append("a stranger_only speaker appears in a target trial")
    if st.hash_id is not None:
        same_audio = st.hash_id[e] == st.hash_id[t]
        if same_audio.any():
            problems.append(f"{int(same_audio.sum())} trials compare identical audio ({ex(same_audio)})")
    codes = np.minimum(e, t) * st.n + np.maximum(e, t)
    if len(np.unique(codes)) != len(codes):
        problems.append(f"{len(codes) - len(np.unique(codes))} duplicate trials")
    if problems:
        raise LeakageError(f"{st.name} b{tr.bucket}: " + "; ".join(problems))


def list_sets(vp: Path) -> list[str]:
    d = vp / "sets"
    if not d.exists():
        return []
    return sorted(p.name for p in d.iterdir() if p.is_dir() and not p.name.startswith((".", "_")))


def prepare_sets(vp: Path, max_per_class: int, force: bool, notes: list, errors: list,
                 use_drops: bool = True, ns: str = "") -> dict[str, SetState]:
    """Load, drop, audit and build trials for every READY set. ns names the output namespace
    ("" by default, "nodrops" for --no-drops) so the two trial lists never overwrite each other."""
    states = {}
    for name in list_sets(vp):
        sd = vp / "sets" / name
        if not (sd / "READY").exists() or not (sd / "segments.jsonl").exists():
            notes.append(f"set {name}: not READY, skipped")
            continue
        try:
            st = load_segments(vp, name, load_drops(vp, name) if use_drops else None)
        except DataError as exc:
            errors.append(str(exc))
            continue
        states[name] = st
        try:
            audit_audio(vp, st, force=force)
            for b in sorted(np.unique(st.bucket).tolist()):
                tr = load_or_build_trials(vp, st, int(b), max_per_class, force=force, ns=ns)
                verify_trials(st, tr)
                st.trials[int(b)] = tr
        except LeakageError as exc:
            st.error, st.leak = str(exc), True
            st.trials = {}
            errors.append(f"LEAKAGE: {exc}")
        except DataError as exc:
            st.error = str(exc)
            st.trials = {}
            errors.append(str(exc))
        for w in st.warnings:
            notes.append(f"set {name}: {w}")
    return states


def cohort_set_for(name: str) -> str:
    return "libri" if name in BIASED_SETS else "yodas"


# ----------------------------------------------------------------------------------------------
# Embeddings and scoring


@dataclass
class Emb:
    E: np.ndarray  # (N, D) float32, L2-normalized, zeros where missing
    raw: np.ndarray  # (N, D) float32 as the model produced it, zeros where missing
    present: np.ndarray  # (N,) bool
    dim: int
    n_dup_rows: int


def emb_path(vp: Path, model: str, set_name: str, cond: str) -> Path:
    return vp / "emb" / model / f"{set_name}__{cond}.npz"


def ready_path(vp: Path, set_name: str, cond: str) -> Path:
    return vp / "sets" / set_name / "READY" if cond == "clean" else vp / "clips" / set_name / cond / "READY"


def load_emb(vp: Path, model: str, st: SetState, cond: str) -> tuple[Emb | None, str | None]:
    path = emb_path(vp, model, st.name, cond)
    if not path.exists():
        return None, "missing"
    ready = ready_path(vp, st.name, cond)
    if ready.exists() and path.stat().st_mtime < ready.stat().st_mtime:
        return None, f"stale: {path.name} is older than {ready.relative_to(vp)}; delete it so the daemon re-embeds"
    try:
        with np.load(path, allow_pickle=False) as z:
            ids = z["seg_id"].astype(str)
            X = np.asarray(z["emb"], dtype=np.float64)
    except Exception as exc:
        return None, f"unreadable ({type(exc).__name__}: {exc})"
    if X.ndim != 2 or len(ids) != len(X) or len(X) == 0:
        return None, f"bad shape {X.shape} for {len(ids)} ids"
    rows = np.array([st.index.get(s, -1) for s in ids], dtype=np.int64)
    if (rows < 0).any():
        unknown = [s for s, r in zip(ids, rows) if r < 0 and s not in st.dropped]
        if unknown:
            return None, f"stale: {len(unknown)} seg_ids are not in segments.jsonl"
        keep_rows = rows >= 0  # the rest are on the set's drop list
        ids, X, rows = ids[keep_rows], X[keep_rows], rows[keep_rows]
    if len(np.unique(rows)) != len(rows):
        return None, "duplicate seg_ids in npz"
    norms = np.linalg.norm(X, axis=1)
    ok = np.isfinite(norms) & (norms > 0)
    E = np.zeros((st.n, X.shape[1]), dtype=np.float32)
    E[rows[ok]] = (X[ok] / norms[ok, None]).astype(np.float32)
    raw = np.zeros((st.n, X.shape[1]), dtype=np.float32)
    raw[rows[ok]] = X[ok].astype(np.float32)
    present = np.zeros(st.n, dtype=bool)
    present[rows[ok]] = True
    n_dup = int(ok.sum() - len(np.unique(X[ok], axis=0))) if ok.any() else 0
    return Emb(E=E, raw=raw, present=present, dim=int(X.shape[1]), n_dup_rows=n_dup), None


def center(e: Emb, mean: np.ndarray) -> np.ndarray:
    """L2-normalized (raw - mean); zeros where missing."""
    X = e.raw.astype(np.float64) - mean[None, :]
    n = np.linalg.norm(X, axis=1)
    out = np.zeros_like(e.E)
    ok = e.present & (n > 0)
    out[ok] = (X[ok] / n[ok, None]).astype(np.float32)
    return out


def asnorm_stats(E: np.ndarray, present: np.ndarray, C: np.ndarray, k: int, chunk: int = 1024):
    """Mean and std of each clip's top-k cosine scores against the cohort C (rows L2-normalized)."""
    n = len(E)
    mu = np.zeros(n, dtype=np.float64)
    sd = np.ones(n, dtype=np.float64)
    idx = np.flatnonzero(present)
    nc = len(C)
    for lo in range(0, len(idx), chunk):
        ii = idx[lo:lo + chunk]
        S = E[ii] @ C.T
        top = np.partition(S, nc - k, axis=1)[:, nc - k:] if k < nc else S
        mu[ii] = top.mean(axis=1)
        sd[ii] = np.maximum(top.std(axis=1), 1e-6)
    return mu, sd


@dataclass
class Config:
    max_per_class: int = MAX_PER_CLASS
    topk: int = TOPK
    n_boot: int = N_BOOT
    asnorm: bool = True
    force: bool = False
    ns: str = ""  # output namespace: "" (drop lists applied) or "nodrops"

    def verify_dir(self, vp: Path) -> Path:
        return vp / "results" / ("verify" + (f"_{self.ns}" if self.ns else ""))

    def summary_path(self, vp: Path, ext: str) -> Path:
        return vp / "results" / (f"verify_summary{'_' + self.ns if self.ns else ''}.{ext}")


def cache_key(vp: Path, model: str, st: SetState, cfg: Config) -> dict:
    inputs = {}
    for set_name in (st.name, cohort_set_for(st.name)):
        for c in CONDS:
            for p in (emb_path(vp, model, set_name, c), ready_path(vp, set_name, c)):
                sig = file_sig(p)
                if sig is not None:
                    inputs[str(p.relative_to(vp))] = sig
    return {
        "scorer": SCORER_VERSION, "max_per_class": cfg.max_per_class, "topk": cfg.topk, "n_boot": cfg.n_boot,
        "p_target": P_TARGET, "set_fp": st.fp,
        "trials": {str(b): tr.meta["fingerprint"] + f"|{tr.meta['n_target']}|{tr.meta['n_nontarget']}"
                   for b, tr in sorted(st.trials.items())},
        "inputs": inputs,
    }


def find_stale(vp: Path, states: dict) -> list[str]:
    """Embedding files older than their set's or condition's READY. The daemon only embeds missing
    files, so these stay stale until someone deletes them."""
    out = []
    d = vp / "emb"
    if not d.exists():
        return out
    for mdir in sorted(p for p in d.iterdir() if p.is_dir() and not p.name.startswith((".", "_"))):
        for name in sorted(states):
            for c in CONDS:
                f = emb_path(vp, mdir.name, name, c)
                r = ready_path(vp, name, c)
                if f.exists() and r.exists() and f.stat().st_mtime < r.stat().st_mtime:
                    out.append(str(f.relative_to(vp)))
    return out


def cells_dir(vp: Path, model: str, cfg: Config) -> Path:
    return cfg.verify_dir(vp) / "_cells" / model


def score_model_set(vp: Path, model: str, st: SetState, states: dict, cfg: Config, emb_cache: dict):
    """Score every cell of one (model, set). Returns (record, arrays)."""
    notes: list[str] = []

    def get(set_state: SetState, cond: str):
        k = (set_state.name, cond)
        if k not in emb_cache:
            emb_cache[k] = load_emb(vp, model, set_state, cond)
        return emb_cache[k]

    embs = {}
    for c in CONDS:
        e, why = get(st, c)
        if e is not None:
            embs[c] = e
            if e.n_dup_rows:
                notes.append(f"{st.name}__{c}: {e.n_dup_rows} clips have a bit-identical embedding to another clip")
        elif why != "missing":
            notes.append(f"{st.name}__{c}: {why}")
    if not embs:
        if not notes:
            return None, None  # nothing embedded for this set yet
        return {"set": st.name, "cells": [], "notes": notes, "near_dup_clean": {}, "asnorm": bool(cfg.asnorm),
                "conds": [], "dim": None}, {}
    base_dim = embs.get("clean", next(iter(embs.values()))).dim
    for c in list(embs):
        if embs[c].dim != base_dim:
            notes.append(f"{st.name}__{c}: dim {embs[c].dim} != {base_dim}, skipped")
            del embs[c]

    stats: dict[str, tuple] = {}
    centered: dict[str, np.ndarray] = {}
    centered_info = None
    cname = cohort_set_for(st.name)
    cst = states.get(cname)
    def why_not(e, why):
        if e is None:
            return "not embedded yet" if why == "missing" else ("stale" if why.startswith("stale") else why)
        if e.dim != base_dim:
            return f"dim {e.dim} != {base_dim}"
        return None

    if cst is None or cst.hash_hex is None:
        notes.append(f"centering and AS-norm off for {st.name}: cohort set {cname} not ready")
    else:
        shared = np.isin(cst.hash_hex, st.hash_hex)
        # centered: one fixed mean vector per model (the clean cohort mean), as the app would ship it
        ce, why = get(cst, "clean")
        bad = why_not(ce, why) or (None if int((ce.present & ~shared).sum()) >= MIN_COHORT else "too few clips")
        if bad:
            notes.append(f"centering off for {st.name}: {cname} clean cohort {bad}")
        else:
            keep = ce.present & ~shared
            mean = ce.raw[keep].astype(np.float64).mean(axis=0)
            centered = {c: center(e, mean) for c, e in embs.items()}
            centered_info = {"set": cname, "cond": "clean", "size": int(keep.sum()),
                             "mean_norm": float(np.linalg.norm(mean)),
                             "mean_norm_over_avg_norm": float(np.linalg.norm(mean) / np.linalg.norm(ce.raw[keep], axis=1).mean())}
        if cfg.asnorm:
            off: dict[str, list] = {}
            for c in embs:
                cc = c
                ce, why = get(cst, c)
                if ce is None and c != "clean":
                    ce, why = get(cst, "clean")
                    cc = "clean"
                bad = why_not(ce, why)
                keep = ce.present & ~shared if not bad else None
                if not bad and int(keep.sum()) < MIN_COHORT:
                    bad = "too few clips"
                if bad:
                    off.setdefault(bad, []).append(c)
                    continue
                C = ce.E[keep]
                k = min(cfg.topk, len(C))
                mu, sd = asnorm_stats(embs[c].E, embs[c].present, C, k)
                stats[c] = (mu, sd, {"set": cname, "cond": cc, "size": int(len(C)), "topk": int(k),
                                     "dropped_shared_audio": int((ce.present & shared).sum())})
            for bad, conds in off.items():
                notes.append(f"AS-norm off for {st.name} ({', '.join(conds)}): {cname} cohort {bad}")

    mult = st.mult(cfg.n_boot)
    cells, arrays = [], {}
    near_dup = {}
    for b, tr in sorted(st.trials.items()):
        rows_b = np.flatnonzero(st.bucket == b)
        loc = np.full(st.n, -1, dtype=np.int64)
        loc[rows_b] = np.arange(len(rows_b))
        le, lt = loc[tr.e], loc[tr.t]
        sims: dict[tuple[str, str], np.ndarray] = {}
        for tc in TRIAL_CONDS:
            ec, xc = split_cond(tc)
            if ec not in embs or xc not in embs:
                continue
            Ee, Et = embs[ec], embs[xc]
            valid = Ee.present[tr.e] & Et.present[tr.t]
            n_drop = int((~valid).sum())
            if n_drop > MAX_DROP_FRAC * len(valid):
                notes.append(f"{st.name} b{b} {tc}: {n_drop}/{len(valid)} trials lack an embedding, cell skipped")
                continue
            if (ec, xc) not in sims:
                sims[(ec, xc)] = Ee.E[rows_b] @ Et.E[rows_b].T
            s = sims[(ec, xc)][le[valid], lt[valid]].astype(np.float64)
            s_cen = None
            if ec in centered and xc in centered:
                if ("c", ec, xc) not in sims:
                    sims[("c", ec, xc)] = centered[ec][rows_b] @ centered[xc][rows_b].T
                s_cen = sims[("c", ec, xc)][le[valid], lt[valid]].astype(np.float64)
            y = tr.y[valid]
            if not y.any() or y.all():
                continue
            ie, it = tr.e[valid], tr.t[valid]
            a_spk, b_spk = st.spk[ie], st.spk[it]
            modes = {"cos": s}
            if s_cen is not None:
                modes["centered"] = s_cen
            if ec in stats and xc in stats:
                mu_e, sd_e, info_e = stats[ec]
                mu_t, sd_t, info_t = stats[xc]
                modes["asnorm"] = 0.5 * ((s - mu_e[ie]) / sd_e[ie] + (s - mu_t[it]) / sd_t[it])
            if tc == "clean":
                hi_t = np.flatnonzero(y & (s >= DUP_COS))
                near_dup[b] = {"target": int(len(hi_t)), "nontarget": int((s[~y] >= DUP_COS).sum()),
                               "examples": [[str(st.seg_ids[ie[k]]), str(st.seg_ids[it[k]]), round(float(s[k]), 4)]
                                            for k in hi_t[np.argsort(-s[hi_t])][:5]]}
            n_t, n_n = int(y.sum()), int((~y).sum())
            for mode, sc in modes.items():
                point, reps = cell_metrics(sc, y, a_spk, b_spk, mult)
                cell = {
                    "set": st.name, "bucket": int(b), "cond": tc, "enroll_cond": ec, "test_cond": xc, "mode": mode,
                    "n_target": n_t, "n_nontarget": n_n, "n_dropped": n_drop,
                    "n_speakers": int(len(np.unique(np.concatenate([a_spk, b_spk])))),
                    "fa_allowed": {k: int(np.floor(v * n_n + 1e-9)) for k, v in FARS.items()},
                    "metrics": point,
                }
                if mode == "asnorm":
                    cell["cohort"] = {"enroll": info_e, "test": info_t}
                elif mode == "centered":
                    cell["cohort"] = centered_info
                cells.append(cell)
                tag = f"{b}__{ckey(tc)}__{mode}"
                if reps is not None:
                    arrays[f"rep__{tag}"] = reps
                arrays[f"tgt__{tag}"] = np.sort(sc[y]).astype(np.float32)[::-1]
                nt = sc[~y]
                keep = min(TOP_NONTARGET_KEEP, len(nt))
                arrays[f"top__{tag}"] = np.sort(np.partition(nt, len(nt) - keep)[len(nt) - keep:]).astype(np.float32)[::-1]
    record = {"set": st.name, "cells": cells, "notes": notes, "near_dup_clean": near_dup,
              "asnorm": bool(cfg.asnorm), "conds": sorted(embs), "dim": base_dim}
    return record, arrays


# ----------------------------------------------------------------------------------------------
# Per-model collection, pooling, outputs


@dataclass
class ModelResult:
    model_id: str
    meta: dict
    cells: list = field(default_factory=list)
    reps: dict = field(default_factory=dict)  # cell id -> (len(METRICS), B)
    one_thr: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)
    sets: dict = field(default_factory=dict)
    recomputed: list = field(default_factory=list)


def cell_id(c: dict) -> tuple:
    return (c["set"], c["bucket"], c["cond"], c["mode"])


def list_models(vp: Path) -> list[str]:
    d = vp / "emb"
    if not d.exists():
        return []
    out = []
    for p in sorted(d.iterdir()):
        if p.is_dir() and not p.name.startswith((".", "_")) and any(
                f.suffix == ".npz" and not f.name.startswith(".") for f in p.iterdir()):
            out.append(p.name)
    return out


def model_meta(vp: Path, model: str) -> dict:
    p = vp / "models" / model / "model.json"
    try:
        return json.loads(p.read_text())
    except Exception:
        return {}


def scope_defs(set_names: list[str]) -> dict[str, tuple[tuple[str, ...], tuple[int, ...] | None]]:
    scopes = {"human": (HUMAN_SETS, None)}
    for b in (2, 4, 8):
        scopes[f"human@b{b}"] = (HUMAN_SETS, (b,))
    for s in BIASED_SETS:
        scopes[s] = ((s,), None)
    for s in set_names:
        scopes[f"set:{s}"] = ((s,), None)
    return scopes


def pooled_value(points: dict, reps: dict, ids: list[tuple]):
    """Mean over sets of the mean over that set's cells. Returns (point (M,), reps (M, B) or None)."""
    by_set: dict[str, list[tuple]] = {}
    for cid in ids:
        by_set.setdefault(cid[0], []).append(cid)
    if not by_set:
        return None, None
    pt = np.mean([np.mean([[points[c][m] for m in METRICS] for c in cs], axis=0) for cs in by_set.values()], axis=0)
    rp = None
    if all(c in reps for c in ids):
        with np.errstate(invalid="ignore"):
            rp = np.mean([np.mean([reps[c] for c in cs], axis=0) for cs in by_set.values()], axis=0)
    return pt, rp


def ci(rp: np.ndarray | None) -> list | None:
    if rp is None or np.all(np.isnan(rp)):
        return None
    lo, hi = np.nanpercentile(rp, [2.5, 97.5])
    return [float(lo), float(hi)]


def collect_model(vp: Path, model: str, states: dict, cfg: Config, recompute_sets: set | None,
                  may_recompute: bool) -> ModelResult:
    res = ModelResult(model_id=model, meta=model_meta(vp, model))
    emb_cache: dict = {}
    cdir = cells_dir(vp, model, cfg)
    for name, st in sorted(states.items()):
        if st.error or not st.trials:
            continue
        if not any(emb_path(vp, model, name, c).exists() for c in CONDS):
            continue
        key = cache_key(vp, model, st, cfg)
        jpath, npath = cdir / f"{name}.json", cdir / f"{name}.npz"
        record, arrays = None, None
        allowed = may_recompute and (recompute_sets is None or name in recompute_sets)
        if jpath.exists() and npath.exists() and not (cfg.force and allowed):
            try:
                cached = json.loads(jpath.read_text())
                if cached.get("key") == key and (cached.get("asnorm") or not cfg.asnorm):
                    record = cached
            except Exception:
                record = None
        if record is None:
            if not allowed:
                if jpath.exists():
                    res.notes.append(f"{name}: cached result is stale and was not recomputed (filtered out)")
                continue
            t0 = time.time()
            record, arrays = score_model_set(vp, model, st, states, cfg, emb_cache)
            if record is None:
                continue
            record["key"] = key
            record["computed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            save_npz(npath, **arrays)
            save_text(jpath, json.dumps(record, indent=1))
            res.recomputed.append(name)
            log(f"  {model} / {name}: {len(record['cells'])} cells in {time.time() - t0:.1f}s")
        with np.load(npath, allow_pickle=False) as z:
            arrays = {k: z[k] for k in z.files}
        res.sets[name] = {k: record[k] for k in ("conds", "dim", "asnorm", "near_dup_clean", "notes") if k in record}
        res.sets[name]["computed_at"] = record.get("computed_at")
        for n in record.get("notes", []):
            res.notes.append(n)
        for c in record["cells"]:
            res.cells.append(c)
            tag = f"{c['bucket']}__{ckey(c['cond'])}__{c['mode']}"
            if f"rep__{tag}" in arrays:
                res.reps[cell_id(c)] = arrays[f"rep__{tag}"]
            res.one_thr[cell_id(c)] = (arrays[f"tgt__{tag}"], arrays[f"top__{tag}"], c["n_nontarget"])
    return res


def pooled_table(res: ModelResult, scopes: dict, base: ModelResult | None) -> tuple[dict, dict]:
    points = {cell_id(c): c["metrics"] for c in res.cells}
    by_key = {cell_id(c): c for c in res.cells}
    pooled: dict = {}
    one: dict = {}
    base_points = {cell_id(c): c["metrics"] for c in base.cells} if base else {}
    for sname, (sets, buckets) in scopes.items():
        for g, conds in GROUPS.items():
            for mode in MODES:
                ids = sorted(cid for cid in points if cid[0] in sets and cid[2] in conds and cid[3] == mode
                             and (buckets is None or cid[1] in buckets))
                if not ids:
                    continue
                pt, rp = pooled_value(points, res.reps, ids)
                entry = {"n_cells": len(ids),
                         "n_target": int(sum(by_key[c]["n_target"] for c in ids)),
                         "n_nontarget": int(sum(by_key[c]["n_nontarget"] for c in ids)),
                         "sets": sorted({c[0] for c in ids}), "metrics": {}}
                for i, m in enumerate(METRICS):
                    entry["metrics"][m] = {"value": float(pt[i]), "ci": ci(rp[i] if rp is not None else None)}
                if base is not None and base.model_id != res.model_id:
                    common = [c for c in ids if c in base_points]
                    if common:
                        mp, mr = pooled_value(points, res.reps, common)
                        bp, br = pooled_value(base_points, base.reps, common)
                        entry["delta_n_cells"] = len(common)
                        for i, m in enumerate(METRICS):
                            d_ci = ci(mr[i] - br[i]) if (mr is not None and br is not None) else None
                            entry["metrics"][m]["delta"] = {"value": float(mp[i] - bp[i]), "ci": d_ci}
                pooled.setdefault(sname, {}).setdefault(g, {})[mode] = entry
                if not sname.startswith("human@"):
                    parts = [res.one_thr[c] for c in ids if c in res.one_thr]
                    if parts:
                        one.setdefault(sname, {}).setdefault(g, {})[mode] = one_threshold_tar(
                            [p[0] for p in parts], [p[1] for p in parts], [p[2] for p in parts])
    return pooled, one


def pick_baseline(results: dict, explicit: str | None) -> str | None:
    if explicit:
        return explicit if explicit in results else None
    flagged = [m for m, r in results.items() if r.meta.get("baseline")]
    if not flagged:
        return None
    return sorted(flagged, key=lambda m: (-len(results[m].cells), m))[0]


def fmt_pct(v, digits=1):
    return "–" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.{digits}f}"


def fmt_num(entry, digits=3):
    return "–" if not entry or entry["value"] is None else f"{entry['value']:.{digits}f}"


def fmt_ci_pct(entry, digits=1):
    if entry is None:
        return "–"
    s = fmt_pct(entry["value"], digits)
    if entry.get("ci"):
        s += f" [{fmt_pct(entry['ci'][0], digits)}, {fmt_pct(entry['ci'][1], digits)}]"
    return s


def num(v) -> str:
    return "" if v is None else f"{v:.6f}"


def pair(v) -> list[str]:
    return [num(v[0]), num(v[1])] if v else ["", ""]


def get_metric(pooled: dict, scope: str, group: str, mode: str, metric: str):
    return pooled.get(scope, {}).get(group, {}).get(mode, {}).get("metrics", {}).get(metric)


def pick_headline_mode(res: ModelResult, pooled: dict, rank_mode: str) -> tuple[str | None, dict, str]:
    """The scoring variant used for a model's headline, the headline value of every variant, and
    the trial group it was picked on ("cross"; "clean" while no degraded embeddings exist yet).

    rank_mode "best": the variant with the highest pooled human TAR@1e-3, among variants that cover
    every human cell the raw cosine covers in that group (so they average the same mix of cells).
    Ties go to the simpler variant (cos, then centered, then asnorm).
    """
    for group in ("cross", "clean"):
        by_mode = {}
        for mode in MODES:
            e = get_metric(pooled, "human", group, mode, "tar@1e-3")
            if e is not None:
                by_mode[mode] = e["value"]
        if not by_mode:
            continue
        if rank_mode != "best":
            return (rank_mode if rank_mode in by_mode else None), by_mode, group
        conds = GROUPS[group]

        def cells(mode):
            return {cell_id(c)[:3] for c in res.cells if c["mode"] == mode and c["set"] in HUMAN_SETS and c["cond"] in conds}

        ref = cells("cos")
        best, best_v = None, -1.0
        for mode in MODES:
            if mode in by_mode and cells(mode) == ref and by_mode[mode] > best_v + 1e-12:
                best, best_v = mode, by_mode[mode]
        return best, by_mode, group
    return None, {}, "cross"


def paired_delta(res: ModelResult, mode: str, base: ModelResult, base_mode: str, sets: tuple, group: str) -> dict | None:
    """Pooled metric difference (model variant minus baseline variant) on the cells both have,
    with a paired bootstrap CI (replicates share speaker resamples across models)."""
    conds = GROUPS[group]
    pm = {cell_id(c)[:3]: c["metrics"] for c in res.cells if c["mode"] == mode and c["set"] in sets and c["cond"] in conds}
    pb = {cell_id(c)[:3]: c["metrics"] for c in base.cells if c["mode"] == base_mode and c["set"] in sets and c["cond"] in conds}
    common = sorted(set(pm) & set(pb))
    if not common:
        return None
    rm = {k: res.reps[k + (mode,)] for k in common if k + (mode,) in res.reps}
    rb = {k: base.reps[k + (base_mode,)] for k in common if k + (base_mode,) in base.reps}
    mp, mr = pooled_value(pm, rm, common)
    bp, br = pooled_value(pb, rb, common)
    out = {"n_cells": len(common), "model_mode": mode, "baseline_mode": base_mode, "metrics": {}}
    for i, m in enumerate(METRICS):
        out["metrics"][m] = {"value": float(mp[i] - bp[i]),
                             "ci": ci(mr[i] - br[i]) if (mr is not None and br is not None) else None}
    return out


def write_outputs(vp: Path, results: dict, states: dict, baseline: str | None, rank_mode: str,
                  errors: list, notes: list, cfg: Config) -> None:
    out_dir = cfg.verify_dir(vp)
    out_dir.mkdir(parents=True, exist_ok=True)
    scopes = scope_defs(sorted(states))
    base = results.get(baseline) if baseline else None
    tables = {m: pooled_table(r, scopes, base) for m, r in results.items()}
    heads = {m: pick_headline_mode(results[m], tables[m][0], rank_mode) for m in results}
    base_mode = heads[baseline][0] if baseline else None
    base_group = heads[baseline][2] if baseline else None
    deltas = {}
    for m, r in results.items():
        mode = heads[m][0]
        if base is not None and m != baseline and mode and base_mode and heads[m][2] == base_group:
            deltas[m] = {g: paired_delta(r, mode, base, base_mode, HUMAN_SETS, g) for g in ("cross", "clean", "overall")}

    # expected cells (union over models), for the coverage column
    expected: dict[tuple, set] = {}
    for r in results.values():
        for c in r.cells:
            for sname, (sets, buckets) in scopes.items():
                if c["set"] in sets and (buckets is None or c["bucket"] in buckets):
                    for g, conds in GROUPS.items():
                        if c["cond"] in conds:
                            expected.setdefault((sname, g, c["mode"]), set()).add(cell_id(c)[:3])

    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    for m, r in results.items():
        pooled, one = tables[m]
        mode, by_mode, hgroup = heads[m]
        head = get_metric(pooled, "human", hgroup, mode, "tar@1e-3") if mode else None
        doc = {
            "model_id": m, "baseline": bool(r.meta.get("baseline")), "is_reference_baseline": m == baseline,
            "meta": {k: r.meta.get(k) for k in ("family", "runtime", "dim", "params_m", "train_data", "status", "source_url")},
            "scorer_version": SCORER_VERSION, "generated_at": now,
            "config": {"max_per_class": cfg.max_per_class, "asnorm_topk": cfg.topk, "n_boot": cfg.n_boot,
                       "p_target": P_TARGET, "fars": FARS, "human_sets": HUMAN_SETS, "reported_separately": BIASED_SETS,
                       "rank_mode": rank_mode,
                       "drops": {n: st.drop_info for n, st in sorted(states.items())}},
            "headline": {"metric": f"human / {hgroup} / tar@1e-3", "group": hgroup, "mode": mode,
                         "value": head["value"] if head else None,
                         "ci": head["ci"] if head else None, "by_mode": by_mode,
                         "reference_baseline": baseline, "baseline_mode": base_mode,
                         "delta_vs_baseline": deltas.get(m)},
            "pooled": pooled, "one_threshold": one, "sets": r.sets,
            "cells": sorted(r.cells, key=lambda c: (c["set"], c["bucket"], TRIAL_CONDS.index(c["cond"]), MODES.index(c["mode"]))),
            "notes": r.notes,
        }
        save_text(out_dir / f"{m}.json", json.dumps(doc, indent=1))

    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["model_id", "baseline", "headline_mode", "scope", "group", "mode", "metric", "value", "ci_lo", "ci_hi",
                "delta_vs_baseline", "delta_lo", "delta_hi", "n_cells", "n_cells_expected", "n_target", "n_nontarget"])
    for m in sorted(results):
        pooled, one = tables[m]
        isb = int(bool(results[m].meta.get("baseline")))
        hm = heads[m][0] or ""
        for sname in pooled:
            for g in pooled[sname]:
                for mode, entry in pooled[sname][g].items():
                    for metric in METRICS:
                        e = entry["metrics"][metric]
                        d = e.get("delta") or {}
                        w.writerow([m, isb, hm, sname, g, mode, metric, num(e["value"]), *pair(e.get("ci")),
                                    num(d.get("value")), *pair(d.get("ci")),
                                    entry["n_cells"], len(expected.get((sname, g, mode), ())),
                                    entry["n_target"], entry["n_nontarget"]])
        for g, d in (deltas.get(m) or {}).items():
            if not d:
                continue
            for metric in METRICS:
                e = d["metrics"][metric]
                w.writerow([m, isb, hm, "human+headline_vs_baseline", g, f"{d['model_mode']}-vs-{d['baseline_mode']}",
                            metric, "", "", "", num(e["value"]), *pair(e.get("ci")), d["n_cells"], "", "", ""])
        for sname in one:
            for g in one[sname]:
                for mode, e in one[sname][g].items():
                    for metric in FARS:
                        if e.get(metric) is None:
                            continue
                        w.writerow([m, isb, hm, f"{sname}+one_threshold", g, mode, metric, num(e[metric]), "", "",
                                    "", "", "", "", "", e["n_target"], e["n_nontarget"]])
    save_text(cfg.summary_path(vp, "csv"), buf.getvalue())
    save_text(cfg.summary_path(vp, "md"),
              render_md(results, tables, heads, deltas, states, baseline, rank_mode, expected, errors, notes, cfg, now,
                        find_stale(vp, states)))


def render_md(results, tables, heads, deltas, states, baseline, rank_mode, expected, errors, notes, cfg, now,
              stale=()) -> str:
    L = []
    human_present = [s for s in HUMAN_SETS if s in states and states[s].trials]
    variant_txt = ("each model's best of raw cosine, centered cosine and AS-norm (column \"variant\")"
                   if rank_mode == "best" else MODE_LABEL[rank_mode])
    L.append("# Voiceprint verification summary\n")
    L.append(f"Generated {now} by `scripts/voiceprint/score_verify.py` v{SCORER_VERSION}.\n")
    L.append(
        f"Ranked by pooled TAR at FAR 1e-3 on cross-condition trials (enroll clean, test opus12 / phone / noisy), "
        f"using {variant_txt}, averaged over the human-labeled sets that are ready "
        f"({', '.join(human_present) or 'none yet'}). Brackets are 95% bootstrap CIs over speakers "
        f"({cfg.n_boot} replicates). Δ compares each model's headline variant with the baseline's headline variant, "
        f"paired, on the cells both have; `*` means its CI excludes 0. TAR, EER and AUC are in %.\n")
    applied = [(n, st.drop_info) for n, st in sorted(states.items()) if st.drop_info.get("applied")]
    if applied:
        parts = []
        for n, d in applied:
            txt = f"{n} {d['removed']}" if d["file"] else f"{n} 0 (no list)"
            if d.get("not_found"):
                txt += f" ({d['not_found']} listed ids not in the set)"
            parts.append(txt)
        L.append("Drop lists applied (`results/audit/drop_<set>.txt`, from the answer-key audit), clips removed before "
                 "trials were built: " + ", ".join(parts) + ".\n")
    elif states:
        L.append("Drop lists **not** applied (`--no-drops`): every clip of every set is scored.\n")
    if errors:
        L.append("## Errors\n")
        for e in errors:
            L.append(f"- **{e}**")
        L.append("")
    if not results:
        L.append("_No model has embeddings for a ready set yet._\n")

    n_exp = len(expected.get(("human", "overall", "cos"), ()))

    def n_have(m):
        return len({cell_id(c)[:3] for c in results[m].cells if c["mode"] == "cos" and c["set"] in HUMAN_SETS})

    def rank_key(m):
        mode, _, group = heads[m]
        e = get_metric(tables[m][0], "human", "cross", mode, "tar@1e-3") if mode else None
        c = get_metric(tables[m][0], "human", "clean", mode, "tar@1e-3") if mode else None
        # complete rows first; rows with cross trials before clean-only rows (ranked on clean)
        return (0 if n_have(m) >= n_exp else 1, 0 if e else 1, -(e or c or {"value": -1.0})["value"], m)

    ranked = sorted(results, key=rank_key)
    if results:
        L.append("| # | model | variant | TAR@1e-3 cross | Δ vs baseline | raw / centered / AS-norm | "
                 "TAR@1e-4 cross, one threshold | EER cross | EER clean | minDCF overall | AUC overall | "
                 "yodas TAR@1e-3 cross | cells |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for i, m in enumerate(ranked, 1):
            pooled, one = tables[m]
            r = results[m]
            mode, by_mode, hgroup = heads[m]
            name = f"`{m}`"
            if r.meta.get("baseline"):
                name += " **(baseline)**"
            if r.meta.get("status") not in (None, "ready"):
                name += f" _(status: {r.meta.get('status')})_"
            if mode is None:
                L.append(f"| {i} | {name} | – | – | – | – | – | – | – | – | – | – | {n_have(m)}/{n_exp} partial |")
                continue
            head = get_metric(pooled, "human", hgroup, mode, "tar@1e-3")
            d = ((deltas.get(m) or {}).get(hgroup) or {}).get("metrics", {}).get("tar@1e-3")
            if m == baseline:
                dtxt = "ref"
            elif d:
                sig = "*" if d.get("ci") and (d["ci"][0] > 0 or d["ci"][1] < 0) else ""
                dtxt = f"{100 * d['value']:+.1f}{sig}"
                if d.get("ci"):
                    dtxt += f" [{100 * d['ci'][0]:+.1f}, {100 * d['ci'][1]:+.1f}]"
            else:
                dtxt = "–"
            variants = " / ".join(
                ("**" + fmt_pct(by_mode[k]) + "**" if k == mode else fmt_pct(by_mode[k])) if k in by_mode else "–"
                for k in MODES)
            ot = one.get("human", {}).get("cross", {}).get(mode, {})
            ot_txt = "–"
            if ot.get("tar@1e-4") is not None:
                ot_txt = f"{fmt_pct(ot['tar@1e-4'])} ({ot.get('fa_allowed@1e-4')} FA of {ot['n_nontarget']})"
            eer_x = get_metric(pooled, "human", "cross", mode, "eer")
            eer_c = get_metric(pooled, "human", "clean", mode, "eer")
            dcf = get_metric(pooled, "human", "overall", mode, "mindcf")
            auc = get_metric(pooled, "human", "overall", mode, "auc")
            yo = get_metric(pooled, "yodas", "cross", mode, "tar@1e-3")
            have = n_have(m)
            vtxt = mode if hgroup == "cross" else f"{mode} (on clean: no cross yet)"
            htxt = fmt_ci_pct(head) + ("" if hgroup == "cross" else " (clean)")
            L.append(f"| {i} | {name} | {vtxt} | {htxt} | {dtxt} | {variants} | {ot_txt} "
                     f"| {fmt_ci_pct(eer_x, 2)} | {fmt_ci_pct(eer_c, 2)} | {fmt_num(dcf, 3)} "
                     f"| {fmt_pct(auc['value'], 2) if auc else '–'} | {fmt_pct(yo['value']) if yo else '–'} "
                     f"| {have}/{n_exp}{'' if have >= n_exp else ' partial'} |")
        L.append("")
        L.append("_variant: which scoring won for that model (cos = raw cosine; centered = subtract the model's "
                 "mean embedding from the cohort set, then cosine; asnorm = adaptive S-norm, top-"
                 f"{cfg.topk} cohort). The raw / centered / AS-norm column shows the headline for each, winner in "
                 "bold. Picking the best of three on the same trials flatters every model a little, and the Δ CI "
                 "does not include that selection. Rows marked partial miss some human-set cells another model has, "
                 "so their pooled numbers average a different mix; they sort after complete rows._\n")
        wins = {}
        for m in ranked:
            if heads[m][0] and heads[m][2] == "cross":
                wins[heads[m][0]] = wins.get(heads[m][0], 0) + 1
        if wins:
            L.append("Variant wins: " + ", ".join(f"{k} {v}" for k, v in sorted(wins.items(), key=lambda x: -x[1])) + ".\n")

        L.append("## By condition (human sets, headline variant): TAR@1e-3 / EER\n")
        L.append("| model | variant | " + " | ".join(TRIAL_CONDS) + " |")
        L.append("|---|---|" + "---|" * len(TRIAL_CONDS))
        for m in ranked:
            pooled, mode = tables[m][0], heads[m][0]
            cells = []
            for tc in TRIAL_CONDS:
                t = get_metric(pooled, "human", tc, mode, "tar@1e-3") if mode else None
                e = get_metric(pooled, "human", tc, mode, "eer") if mode else None
                cells.append(f"{fmt_pct(t['value'])} / {fmt_pct(e['value'], 2)}" if t else "–")
            L.append(f"| `{m}` | {mode or '–'} | " + " | ".join(cells) + " |")
        L.append("")

        L.append("## By clip length (human sets, cross, headline variant): TAR@1e-3 / EER\n")
        L.append("| model | variant | 2 s | 4 s | 8 s |")
        L.append("|---|---|---|---|---|")
        for m in ranked:
            pooled, mode = tables[m][0], heads[m][0]
            cells = []
            for b in (2, 4, 8):
                t = get_metric(pooled, f"human@b{b}", "cross", mode, "tar@1e-3") if mode else None
                e = get_metric(pooled, f"human@b{b}", "cross", mode, "eer") if mode else None
                cells.append(f"{fmt_pct(t['value'])} / {fmt_pct(e['value'], 2)}" if t else "–")
            L.append(f"| `{m}` | {mode or '–'} | " + " | ".join(cells) + " |")
        L.append("")

    L.append("## Trials\n")
    L.append("Same pairs for every model and condition. FA allowed = false accepts the FAR threshold may let "
             "through in one cell. With only a few at 1e-4, per-cell TAR@1e-4 is noisy, so the one-threshold "
             "column pools every human cross cell under a single threshold.\n")
    L.append("| set | bucket | speakers | clips | target | non-target (same session) | FA allowed @1e-3 / 1e-4 |")
    L.append("|---|---|---|---|---|---|---|")
    for name, st in sorted(states.items()):
        if st.error:
            L.append(f"| {name} | – | – | {st.n} | excluded: {'LEAKAGE' if st.leak else 'error'} | | |")
            continue
        for b, tr in sorted(st.trials.items()):
            mt = tr.meta
            L.append(f"| {name}{'' if name in HUMAN_SETS else ' (separate)'} | {b} | {mt['n_speakers']} | {mt['n_clips']} "
                     f"| {mt['n_target']} of {mt['n_target_possible']} | {mt['n_nontarget']} ({mt['n_nontarget_same_session']}) "
                     f"| {int(np.floor(1e-3 * mt['n_nontarget']))} / {int(np.floor(1e-4 * mt['n_nontarget']))} |")
    L.append("")

    extra = []
    for m in ranked:
        r = results[m]
        nd = sum(v.get("target", 0) for s in r.sets.values() for v in (s.get("near_dup_clean") or {}).values())
        if nd and m == baseline:
            ex = [e for s in r.sets.values() for v in (s.get("near_dup_clean") or {}).values() for e in v.get("examples", [])]
            ex_txt = "; ".join(f"{a} / {b} ({c})" for a, b, c in sorted(ex, key=lambda x: -x[2])[:3])
            extra.append(f"`{m}`: {nd} clean target trials (different sessions) score cosine ≥ {DUP_COS}; check them "
                         f"for the same audio under two sessions: {ex_txt}")
    by_note: dict[str, list] = {}
    for m in ranked:
        for n in results[m].notes:
            by_note.setdefault(n, []).append(m)
    for n, ms in by_note.items():
        who = ", ".join(f"`{m}`" for m in ms) if len(ms) <= 3 else f"{len(ms)} models"
        extra.append(f"{n} ({who})")
    if stale:
        sets_ = sorted({Path(f).name.split("__")[0] for f in stale})
        extra.insert(0, f"**{len(stale)} embedding files are stale** (older than their READY, so they are skipped, and the "
                        f"daemon will not redo them until they are deleted; sets: {', '.join(sets_)}): "
                        + ", ".join(f"`{f}`" for f in stale[:12]) + (" …" if len(stale) > 12 else ""))
    if notes or extra:
        L.append("## Notes\n")
        for n in notes + extra[:60]:
            L.append(f"- {n}")
        if len(extra) > 60:
            L.append(f"- … {len(extra) - 60} more in the per-model JSON files")
        L.append("")
    L.append("Metric definitions: EER interpolated on the ROC; minDCF normalized, P_target 0.01, C_miss = C_fa = 1; "
             "TAR@FAR uses the threshold that lets at most floor(FAR × non-targets) false accepts through; pooled "
             "numbers are the mean over sets of the mean over that set's buckets and conditions. yodas is reported "
             "on its own because its labels came from TitaNet / CAM++. Full detail: `results/verify/<model>.json`.\n")
    return "\n".join(L)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vp", default=str(DEFAULT_VP), help="VP root (default data/eval/voiceprint or $VP_ROOT)")
    ap.add_argument("--models", default="", help="comma list: recompute only these models")
    ap.add_argument("--sets", default="", help="comma list: recompute only these sets")
    ap.add_argument("--no-asnorm", action="store_true", help="skip AS-norm scoring")
    ap.add_argument("--boot", type=int, default=N_BOOT, help="bootstrap replicates (0 = no CIs)")
    ap.add_argument("--max-trials", type=int, default=MAX_PER_CLASS, help="max target and max non-target trials per (set, bucket)")
    ap.add_argument("--topk", type=int, default=TOPK, help="AS-norm cohort top-k")
    ap.add_argument("--rank-mode", choices=("best",) + MODES, default="best",
                    help="scoring variant for the headline: best (each model's best of the three, default), cos, centered, asnorm")
    ap.add_argument("--baseline", default=None, help="reference model for Δ (default: model.json baseline: true)")
    ap.add_argument("--force", action="store_true", help="ignore caches (audit, trials, per-model cells)")
    ap.add_argument("--no-drops", action="store_true",
                    help="ignore VP/results/audit/drop_<set>.txt; outputs get a _nodrops suffix")
    args = ap.parse_args(argv)

    vp = Path(args.vp).resolve()
    cfg = Config(max_per_class=args.max_trials, topk=args.topk, n_boot=args.boot, asnorm=not args.no_asnorm,
                 force=args.force, ns="nodrops" if args.no_drops else "")
    t0 = time.time()
    notes: list[str] = []
    errors: list[str] = []
    want_sets = {s for s in args.sets.split(",") if s} or None
    want_models = {m for m in args.models.split(",") if m} or None

    states = prepare_sets(vp, cfg.max_per_class, cfg.force, notes, errors, use_drops=not args.no_drops, ns=cfg.ns)
    if want_sets:
        for s in sorted(want_sets - set(states)):
            notes.append(f"set {s}: requested but not ready")
    log(f"sets ready: {', '.join(f'{n}' + (' (EXCLUDED)' if st.error else '') for n, st in states.items()) or 'none'} "
        f"({time.time() - t0:.1f}s)")

    models = list_models(vp)
    if want_models:
        for m in sorted(want_models - set(models)):
            notes.append(f"model {m}: requested but has no embeddings")
    results = {}
    for m in models:
        r = collect_model(vp, m, states, cfg, want_sets, may_recompute=want_models is None or m in want_models)
        if r.cells:
            results[m] = r
    baseline = pick_baseline(results, args.baseline)
    if args.baseline and baseline is None:
        notes.append(f"baseline {args.baseline}: no results")
    write_outputs(vp, results, states, baseline, args.rank_mode, errors, notes, cfg)
    log(f"scored {len(results)} models; recomputed "
        f"{sum(len(r.recomputed) for r in results.values())} (model, set) pairs in {time.time() - t0:.1f}s")
    log(f"wrote {cfg.summary_path(vp, 'md')}")
    if errors:
        bar = "!" * 78
        log(f"\n{bar}")
        for e in errors:
            log(f"ERROR: {e}")
        log(bar)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
