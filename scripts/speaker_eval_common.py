#!/usr/bin/env python3
"""Shared, dependency-free speaker-eval scoring helpers.

Used by scripts/score_speaker_eval.py (threshold sweeps) and
scripts/score_speaker_lab.py (the diarizer / fingerprint bake-off). Pure Python on
purpose: the lab's scorer and its unit tests run anywhere, including Linux CI boxes
without pyannote.metrics.

What lives here:

  * RTTM parsing and time-overlap helpers
  * `diarization_error` — DER + miss / false alarm / confusion, plus JER, with the
    same conventions as pyannote.metrics' DiarizationErrorRate(collar=c,
    skip_overlap=False): the collar is the TOTAL width centered on every reference
    boundary (c/2 each side), the evaluated region defaults to the union of the
    reference and hypothesis extents, overlapped speech is scored, and hypothesis
    labels are mapped to reference labels by an optimal one-to-one (Hungarian)
    assignment. scripts/test_score_speaker_lab.py cross-checks it against
    pyannote.metrics when that package is installed.
  * `identity_metrics` — fragmentation, false-merge, and the cross-meeting re-ID
    curve (moved verbatim from score_speaker_eval.py).
  * `recognition_metrics` — the returning-speaker scoreboard: for each reference
    speaker's appearance in a later meeting, was their voice RECOGNIZED (landed on a
    profile that already held their speech), given to the WRONG PERSON, or did the
    app ASK AGAIN (a brand-new profile the user must name again)?
"""
from collections import Counter, defaultdict


# ---------------------------------------------------------------------------
# RTTM / overlap
# ---------------------------------------------------------------------------

def parse_rttm(path):
    """Return list of (start, end, speaker_global_id)."""
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "SPEAKER":
                continue
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            out.append((start, start + dur, spk))
    return out


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def build_overlap_matrix(ref, hyp):
    """seconds of ref/hyp co-occurrence, keyed [true_id][hyp_label]."""
    m = defaultdict(lambda: defaultdict(float))
    hyp = sorted(hyp, key=lambda x: x[0])
    for (rs, re, tid) in ref:
        for (hs, he, pid) in hyp:
            if hs >= re:
                break
            ov = overlap(rs, re, hs, he)
            if ov > 0:
                m[tid][pid] += ov
    return m


def seconds_overlapping(ref_intervals, hyp_intervals):
    """Seconds of `ref_intervals` covered by `hyp_intervals` (pairwise sum, like the
    original score_speaker_eval.sec_assigned)."""
    hyp = sorted(hyp_intervals)
    total = 0.0
    for (rs, re) in ref_intervals:
        for (hs, he) in hyp:
            if hs >= re:
                break
            total += overlap(rs, re, hs, he)
    return total


def union_seconds(intervals):
    """Length of the union of (start, end) intervals."""
    total, cur_s, cur_e = 0.0, None, None
    for s, e in sorted((s, e) for s, e in intervals if e > s):
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    if cur_e is not None:
        total += cur_e - cur_s
    return total


# ---------------------------------------------------------------------------
# Optimal assignment (Hungarian, maximize)
# ---------------------------------------------------------------------------

def hungarian_max(weights):
    """Maximum-weight one-to-one assignment for a rectangular matrix (list of rows).
    Returns a list of (row, col) pairs. O(n^3); n is a handful of speakers."""
    n_rows = len(weights)
    n_cols = len(weights[0]) if n_rows else 0
    n = max(n_rows, n_cols)
    if n == 0:
        return []
    big = max((w for row in weights for w in row), default=0.0)
    # square cost matrix for minimization; padding cells cost `big` (weight 0)
    cost = [[big - (weights[i][j] if i < n_rows and j < n_cols else 0.0) for j in range(n)]
            for i in range(n)]
    INF = float("inf")
    u = [0.0] * (n + 1)
    v = [0.0] * (n + 1)
    p = [0] * (n + 1)
    way = [0] * (n + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (n + 1)
        used = [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], INF, 0
            for j in range(1, n + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j], way[j] = cur, j0
                    if minv[j] < delta:
                        delta, j1 = minv[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break
    pairs = []
    for j in range(1, n + 1):
        i = p[j]
        if i and i - 1 < n_rows and j - 1 < n_cols:
            pairs.append((i - 1, j - 1))
    return pairs


# ---------------------------------------------------------------------------
# DER / JER
# ---------------------------------------------------------------------------

def _collar_regions(ref, collar):
    if collar <= 0:
        return []
    half = collar / 2.0
    regions = []
    for s, e, _ in ref:
        regions.append((s - half, s + half))
        regions.append((e - half, e + half))
    return regions


def _merge(intervals):
    merged = []
    for s, e in sorted(intervals):
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return merged


def diarization_error(ref, hyp, collar=0.25, uem=None):
    """DER and friends for one recording.

    ref, hyp: lists of (start, end, label). Hypothesis labels may be any hashable
    values; they never collide with reference labels (namespaced internally).
    collar: total collar width in seconds centered on reference boundaries
    (pyannote convention; 0.25 => +/-0.125 s).
    uem: optional (start, end) evaluated region; default = union of the extents.

    Returns a dict of seconds (total, miss, false_alarm, confusion, correct) and
    rates (der, miss_rate, false_alarm_rate, confusion_rate, jer), plus the
    optimal hyp->ref mapping.
    """
    ref = [(float(s), float(e), ("R", l)) for s, e, l in ref if e > s]
    hyp = [(float(s), float(e), ("H", l)) for s, e, l in hyp if e > s]
    empty = {"total": 0.0, "miss": 0.0, "false_alarm": 0.0, "confusion": 0.0, "correct": 0.0,
             "der": 0.0, "miss_rate": 0.0, "false_alarm_rate": 0.0, "confusion_rate": 0.0,
             "jer": 0.0, "mapping": {}}
    if not ref and not hyp:
        return empty
    if uem is None:
        starts = [s for s, _, _ in ref + hyp]
        ends = [e for _, e, _ in ref + hyp]
        uem = (min(starts), max(ends))
    u0, u1 = uem
    excluded = _merge(_collar_regions(ref, collar))

    bounds = {u0, u1}
    for s, e, _ in ref + hyp:
        bounds.add(s)
        bounds.add(e)
    for s, e in excluded:
        bounds.add(s)
        bounds.add(e)
    points = sorted(bounds)

    # Sweep line: elementary intervals between consecutive boundaries, with the
    # multiset of active reference / hypothesis labels on each.
    starts_at = defaultdict(list)
    ends_at = defaultdict(list)
    for s, e, l in ref + hyp:
        starts_at[s].append(l)
        ends_at[e].append(l)
    active_r, active_h = Counter(), Counter()
    elems = []   # (duration, Counter(ref), Counter(hyp))
    ex_i = 0
    for idx, a in enumerate(points):
        for l in ends_at.get(a, ()):
            (active_r if l[0] == "R" else active_h)[l] -= 1
        for l in starts_at.get(a, ()):
            (active_r if l[0] == "R" else active_h)[l] += 1
        if idx + 1 >= len(points):
            break
        b = points[idx + 1]
        d = b - a
        if d <= 1e-12:
            continue
        m = (a + b) / 2.0
        if not (u0 <= m <= u1):
            continue
        while ex_i < len(excluded) and excluded[ex_i][1] <= m:
            ex_i += 1
        if ex_i < len(excluded) and excluded[ex_i][0] < m < excluded[ex_i][1]:
            continue
        R = Counter({k: c for k, c in active_r.items() if c > 0})
        H = Counter({k: c for k, c in active_h.items() if c > 0})
        if R or H:
            elems.append((d, R, H))

    ref_labels = sorted({l for _, R, _ in elems for l in R}, key=str)
    hyp_labels = sorted({l for _, _, H in elems for l in H}, key=str)
    ri = {l: i for i, l in enumerate(ref_labels)}
    hi = {l: i for i, l in enumerate(hyp_labels)}
    co = [[0.0] * len(hyp_labels) for _ in ref_labels]
    for d, R, H in elems:
        for r, rc in R.items():
            for h, hc in H.items():
                co[ri[r]][hi[h]] += d * rc * hc
    mapping = {}
    if ref_labels and hyp_labels:
        for i, j in hungarian_max(co):
            if co[i][j] > 0:
                mapping[hyp_labels[j]] = ref_labels[i]

    total = miss = fa = conf = correct = 0.0
    ref_time = defaultdict(float)
    hyp_time = defaultdict(float)
    inter = defaultdict(float)   # (ref_label) -> seconds where ref & its mapped hyp are both active
    inv = {r: h for h, r in mapping.items()}
    for d, R, H in elems:
        nr, nh = sum(R.values()), sum(H.values())
        mapped = Counter()
        for h, c in H.items():
            mapped[mapping.get(h, h)] += c
        corr = sum(min(c, mapped[r]) for r, c in R.items())
        total += d * nr
        miss += d * max(0, nr - nh)
        fa += d * max(0, nh - nr)
        conf += d * (min(nr, nh) - corr)
        correct += d * corr
        for r in R:
            ref_time[r] += d
            h = inv.get(r)
            if h is not None and h in H:
                inter[r] += d
        for h in H:
            hyp_time[h] += d

    # JER (dscore-style): mean over reference speakers of 1 - |r ∩ h| / |r ∪ h| for the
    # optimally mapped hypothesis speaker h; an unmapped reference speaker scores 1.
    jers = []
    for r in ref_labels:
        h = inv.get(r)
        if h is None:
            jers.append(1.0)
            continue
        union = ref_time[r] + hyp_time[h] - inter[r]
        jers.append(1.0 - (inter[r] / union if union > 0 else 0.0))
    jer = sum(jers) / len(jers) if jers else (1.0 if hyp_labels else 0.0)

    denom = total if total > 0 else 1.0
    return {
        "total": total, "miss": miss, "false_alarm": fa, "confusion": conf, "correct": correct,
        "der": (miss + fa + conf) / denom if total > 0 else (1.0 if fa > 0 else 0.0),
        "miss_rate": miss / denom, "false_alarm_rate": fa / denom, "confusion_rate": conf / denom,
        "jer": jer,
        "mapping": {str(h[1]): str(r[1]) for h, r in mapping.items()},
    }


# ---------------------------------------------------------------------------
# Identity metrics (fragmentation / false-merge / re-ID curve)
# ---------------------------------------------------------------------------

FRAG_MIN = 0.10
MERGE_MIN = 0.10


def identity_metrics(meetings):
    """meetings: ordered list of (meeting_id, ref, hyp) where hyp labels are the
    persistent DB-profile ids (consistent across the whole replay).

    Returns fragmentation, false-merge, and the cross-meeting re-ID curve exactly as
    score_speaker_eval.py has always computed them.
    """
    global_ref_time = defaultdict(float)
    global_overlap = defaultdict(lambda: defaultdict(float))
    meeting_dom = {}
    by_meeting = {}
    order = []
    for meeting, ref, hyp in meetings:
        order.append(meeting)
        by_meeting[meeting] = (ref, hyp)
        om = build_overlap_matrix(ref, hyp)
        for tid, secs in om.items():
            ref_sec = sum(e - s for s, e, t in ref if t == tid)
            global_ref_time[tid] += ref_sec
            dom_pid, dom_sec = (max(secs.items(), key=lambda kv: kv[1]) if secs else (None, 0.0))
            meeting_dom[(meeting, tid)] = (dom_pid, dom_sec, ref_sec)
            for pid, ov in secs.items():
                global_overlap[tid][pid] += ov

    fragmentation = {}
    for tid, profiles in global_overlap.items():
        tot = global_ref_time[tid] or 1.0
        frag = sum(1 for pid, ov in profiles.items() if ov / tot >= FRAG_MIN)
        fragmentation[tid] = max(1, frag)

    profile_to_true = defaultdict(lambda: defaultdict(float))
    for tid, profiles in global_overlap.items():
        for pid, ov in profiles.items():
            profile_to_true[pid][tid] += ov
    false_merge = {}
    for pid, trues in profile_to_true.items():
        tot = sum(trues.values()) or 1.0
        n = sum(1 for tid, ov in trues.items() if ov / tot >= MERGE_MIN)
        if n >= 2:
            false_merge[pid] = sorted([t for t, ov in trues.items() if ov / tot >= MERGE_MIN])

    first_anchor = {}
    reid_by_appearance = defaultdict(list)
    reid_detail = []
    appearance_counter = defaultdict(int)
    for meeting in order:
        ref, hyp = by_meeting[meeting]
        for tid in sorted(global_ref_time.keys()):
            key = (meeting, tid)
            if key not in meeting_dom:
                continue
            dom_pid, dom_sec, ref_sec = meeting_dom[key]
            if ref_sec <= 0:
                continue
            appearance_counter[tid] += 1
            k = appearance_counter[tid]
            if k == 1:
                first_anchor[tid] = dom_pid
            anchor = first_anchor.get(tid)
            covered = 0.0
            if anchor is not None:
                covered = seconds_overlapping(
                    [(s, e) for (s, e, t) in ref if t == tid],
                    [(s, e) for (s, e, p) in hyp if p == anchor])
            acc = covered / ref_sec if ref_sec else 0.0
            reid_by_appearance[k].append(acc)
            reid_detail.append({"meeting": meeting, "true": tid, "appearance": k,
                                "anchor": anchor, "dominant": dom_pid,
                                "reid_accuracy": round(acc, 4)})

    reid_curve = {str(k): round(sum(v) / len(v), 4) for k, v in sorted(reid_by_appearance.items())}
    return {
        "fragmentation": fragmentation,
        "false_merge": false_merge,
        "reid_curve": reid_curve,
        "reid_detail": reid_detail,
        "true_speakers": sorted(global_ref_time.keys()),
    }


# ---------------------------------------------------------------------------
# Returning-speaker recognition
# ---------------------------------------------------------------------------

RECOGNIZED = "recognized"
WRONG_PERSON = "wrong_person"
ASKED_AGAIN = "asked_again"
UNDETECTED = "undetected"
NEW_OK = "new_ok"
FALSE_MATCH = "false_match"


def recognition_metrics(meetings, min_appearance_sec=5.0):
    """Classify every reference speaker appearance in replay order.

    meetings: ordered list of (meeting_id, ref, hyp); hyp labels are persistent
    DB-profile ids. A speaker's "dominant profile" in a meeting is the profile that
    holds the most of their reference speech there.

    A profile's OWNER is the reference speaker who held the most speech on it across
    all EARLIER meetings (a profile unseen in earlier meetings has no owner yet —
    it was created in this meeting, so the user would be asked to name it).

    Returning appearance (the speaker already appeared in an earlier meeting):
      recognized   — dominant profile's owner is this same speaker
      wrong_person — dominant profile is owned by someone else
      asked_again  — dominant profile is brand new (the user names them again)
      undetected   — no hypothesis speech overlaps them at all
    First appearance:
      new_ok       — dominant profile is new (correct: a stranger is a stranger)
      false_match  — dominant profile already existed (a new person was matched to
                     someone the app already knows)
      undetected   — as above
    Appearances with less than `min_appearance_sec` of reference speech are skipped
    (too little voice to fingerprint; they neither help nor hurt).
    """
    owner_mass = defaultdict(lambda: defaultdict(float))   # profile -> tid -> seconds, EARLIER meetings
    seen_speakers = set()
    events = []
    for meeting, ref, hyp in meetings:
        om = build_overlap_matrix(ref, hyp)
        ref_time = defaultdict(float)
        for s, e, t in ref:
            ref_time[t] += e - s
        owners = {pid: max(m.items(), key=lambda kv: (kv[1], kv[0]))[0]
                  for pid, m in owner_mass.items() if m}
        for tid in sorted(ref_time):
            secs = ref_time[tid]
            if secs < min_appearance_sec:
                continue
            profiles = om.get(tid, {})
            returning = tid in seen_speakers
            dom, dom_sec = (max(profiles.items(), key=lambda kv: (kv[1], str(kv[0])))
                            if profiles else (None, 0.0))
            if dom is None:
                outcome = UNDETECTED
            elif returning:
                owner = owners.get(dom)
                if owner is None:
                    outcome = ASKED_AGAIN
                elif owner == tid:
                    outcome = RECOGNIZED
                else:
                    outcome = WRONG_PERSON
            else:
                outcome = FALSE_MATCH if dom in owners else NEW_OK
            events.append({
                "meeting": meeting, "speaker": tid, "returning": returning,
                "outcome": outcome, "profile": dom,
                "profileOwner": owners.get(dom) if dom is not None else None,
                "speechSeconds": round(secs, 2),
                "dominantShare": round(dom_sec / secs, 4) if secs > 0 else 0.0,
            })
            seen_speakers.add(tid)
        # this meeting's mass becomes history for the next meeting
        for tid, profiles in om.items():
            for pid, ov in profiles.items():
                owner_mass[pid][tid] += ov

    ret = [e for e in events if e["returning"]]
    first = [e for e in events if not e["returning"]]

    def rate(n, d):
        return round(n / d, 4) if d else None

    n_rec = sum(1 for e in ret if e["outcome"] == RECOGNIZED)
    n_wrong = sum(1 for e in ret if e["outcome"] == WRONG_PERSON)
    n_asked = sum(1 for e in ret if e["outcome"] == ASKED_AGAIN)
    n_undet = sum(1 for e in ret if e["outcome"] == UNDETECTED)
    n_fm = sum(1 for e in first if e["outcome"] == FALSE_MATCH)
    by_k = defaultdict(lambda: Counter())
    counts = Counter()
    for e in events:
        counts[e["speaker"]] += 1
        e["appearance"] = counts[e["speaker"]]
        by_k[e["appearance"]][e["outcome"]] += 1
    return {
        "returningAppearances": len(ret),
        "recognized": n_rec,
        "wrongPerson": n_wrong,
        "askedAgain": n_asked,
        "undetected": n_undet,
        "recognizedRate": rate(n_rec, len(ret)),
        "wrongPersonRate": rate(n_wrong, len(ret)),
        "askedAgainRate": rate(n_asked, len(ret)),
        "undetectedRate": rate(n_undet, len(ret)),
        "firstAppearances": len(first),
        "firstAppearanceFalseMatches": n_fm,
        "firstAppearanceFalseMatchRate": rate(n_fm, len(first)),
        "byAppearance": {str(k): dict(v) for k, v in sorted(by_k.items())},
        "minAppearanceSeconds": min_appearance_sec,
        "events": events,
    }
