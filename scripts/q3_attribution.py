#!/usr/bin/env python3
"""Q3 attribution: within-meeting (diarizer) vs cross-meeting (matcher) false merges.

For each arm we use:
  - dumps/*.json   : raw diarizer clusters (meeting, speakerId) + segment time spans
  - data/ami/rttm/ : ground-truth global recurring speaker ids + time spans
  - reports/cons_none_match_M.json : false_merge.profiles {pid:[trueids]} + reid_detail

A diarizer cluster = (meeting, speakerId). We overlap each cluster's segment spans
against the RTTM to compute, per cluster, the duration mass landing on each true id.
A cluster is 'mixed' if >=2 true ids each hold >= MIX_FRAC of the cluster's matched mass.

Attribution of a false-merge profile P (fuses trueids T = {t1..tk}, k>=2):
  - Look at every diarizer cluster assigned (dominant) to P.
  - WITHIN-MEETING pair (ti,tj): there exists a single cluster (one meeting) whose
    mixed-true-id set contains both ti and tj  -> diarizer fused them upstream.
  - CROSS-MEETING pair (ti,tj): ti and tj each reach P only via clusters that are
    each (near-)pure for one of them, in different meetings -> matcher fused them.
We classify each unordered fused pair, and also classify each profile.
"""
import json, glob, os, sys
from collections import defaultdict

ROOT = '/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2'
RTTM_DIR = os.path.join(ROOT, 'data/ami/rttm')
MIX_FRAC = 0.20   # a true id must hold >=20% of a cluster's matched mass to count as "in" it

# ---- load RTTM: meeting -> list of (start,end,trueid) ----
def load_rttm():
    rttm = defaultdict(list)
    for f in glob.glob(os.path.join(RTTM_DIR, '*.rttm')):
        m = os.path.basename(f)[:-5]
        for line in open(f):
            p = line.split()
            if p and p[0] == 'SPEAKER':
                st = float(p[3]); dur = float(p[4]); tid = p[7]
                rttm[m].append((st, st + dur, tid))
    return rttm

RTTM = load_rttm()

def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))

def cluster_true_mass(meeting, segs):
    """For one diarizer cluster's segments, return {trueid: overlapped_seconds}."""
    ref = RTTM[meeting]
    mass = defaultdict(float)
    for s0, s1 in segs:
        for r0, r1, tid in ref:
            ov = overlap(s0, s1, r0, r1)
            if ov > 0:
                mass[tid] += ov
    return mass

def analyze_arm(arm):
    dumpdir = os.path.join(ROOT, 'data/eval', arm, 'dumps')
    # cluster -> list of (start,end); cluster key = (meeting, speakerId)
    clusters = defaultdict(list)
    for f in glob.glob(os.path.join(dumpdir, '*.json')):
        d = json.load(open(f))
        meeting = d['meeting']
        for seg in d['segments']:
            clusters[(meeting, seg['speakerId'])].append((seg['start'], seg['end']))
    # per cluster: matched mass per true id, dominant true id, mixed-true-id set
    cl_info = {}
    for (meeting, sid), segs in clusters.items():
        mass = cluster_true_mass(meeting, segs)
        tot = sum(mass.values())
        if tot <= 0:
            cl_info[(meeting, sid)] = dict(dominant=None, mixed=set(), mass=mass, tot=0.0)
            continue
        dominant = max(mass, key=mass.get)
        mixed = {t for t, v in mass.items() if v / tot >= MIX_FRAC}
        cl_info[(meeting, sid)] = dict(dominant=dominant, mixed=mixed, mass=mass, tot=tot)
    return clusters, cl_info

# ---- diarizer over/under segmentation (matcher-independent) ----
def diarizer_seg_stats(arm):
    clusters, cl_info = analyze_arm(arm)
    # group clusters by meeting
    by_meeting = defaultdict(list)
    for (meeting, sid) in clusters:
        by_meeting[meeting].append(sid)
    ref_speakers_per_meeting = {m: len(set(t for _,_,t in RTTM[m])) for m in RTTM}
    over = under = exact = 0
    n_clusters_total = 0
    n_mixed_clusters = 0          # clusters covering >=2 true ids (under-seg: merged speakers)
    # per true speaker per meeting: how many distinct clusters hold >=MIX_FRAC of THAT cluster
    # over-seg: one true speaker split across multiple clusters within a meeting
    split_count = 0   # (meeting,trueid) appearances split across >1 cluster
    appear_total = 0
    for m, sids in by_meeting.items():
        nhyp = len(sids); nref = ref_speakers_per_meeting[m]
        n_clusters_total += nhyp
        if nhyp > nref: over += 1
        elif nhyp < nref: under += 1
        else: exact += 1
        # mixed clusters
        for sid in sids:
            if len(cl_info[(m, sid)]['mixed']) >= 2:
                n_mixed_clusters += 1
        # over-seg per true id: count clusters whose dominant==tid
        dom_count = defaultdict(int)
        for sid in sids:
            dom = cl_info[(m, sid)]['dominant']
            if dom is not None:
                dom_count[dom] += 1
        for tid in set(t for _,_,t in RTTM[m]):
            appear_total += 1
            if dom_count.get(tid, 0) > 1:
                split_count += 1
    return dict(meetings=len(by_meeting), clusters=n_clusters_total,
                mean_clusters_per_meeting=round(n_clusters_total/len(by_meeting),2),
                over_seg_meetings=over, under_seg_meetings=under, exact_meetings=exact,
                mixed_clusters=n_mixed_clusters,
                appearances_split=split_count, appearances_total=appear_total)

# ---- false-merge attribution using reid_detail (appearance->profile) ----
def attribute_arm(arm, match):
    clusters, cl_info = analyze_arm(arm)
    rep = json.load(open(os.path.join(ROOT,'data/eval',arm,'reports',f'cons_none_match_{match:.2f}.json')))
    fm = rep['false_merge']['profiles']        # pid -> [trueids]
    reid = rep['reid_detail']                  # rows: meeting,true,appearance,anchor,dominant,reid_accuracy

    # map profile -> list of (meeting, true) appearances assigned to it (dominant)
    prof_appearances = defaultdict(list)
    for r in reid:
        prof_appearances[r['dominant']].append((r['meeting'], r['true']))

    # Build, per meeting, the within-meeting mixed-pairs the DIARIZER created
    # (independent of matcher): pairs (ti,tj) that share a single diarizer cluster.
    diar_within_pairs = set()   # frozenset({ti,tj}) globally (these CAN ONLY come from diarizer)
    diar_within_by_meeting = defaultdict(set)
    for (m, sid), info in cl_info.items():
        mx = sorted(info['mixed'])
        for i in range(len(mx)):
            for j in range(i+1, len(mx)):
                pr = frozenset((mx[i], mx[j]))
                diar_within_pairs.add(pr)
                diar_within_by_meeting[m].add(pr)

    per_profile = []
    pair_within = set()
    pair_cross = set()
    profiles_with_any_within = 0
    profiles_pure_cross = 0

    for pid, tids in fm.items():
        tids = sorted(set(tids))
        # all unordered pairs fused in this profile
        pairs = [(tids[i], tids[j]) for i in range(len(tids)) for j in range(i+1, len(tids))]
        within_pairs_here = []
        cross_pairs_here = []
        for (a, b) in pairs:
            pr = frozenset((a, b))
            if pr in diar_within_pairs:
                within_pairs_here.append((a, b)); pair_within.add(pr)
            else:
                cross_pairs_here.append((a, b)); pair_cross.add(pr)
        has_within = len(within_pairs_here) > 0
        if has_within: profiles_with_any_within += 1
        else: profiles_pure_cross += 1
        per_profile.append(dict(pid=pid, tids=tids,
                                within=within_pairs_here, cross=cross_pairs_here))

    return dict(arm=arm, match=match,
                profiles_end=rep['profiles_at_end'],
                fm_count=len(fm),
                fused_pairs_total=len(pair_within)+len(pair_cross),
                pairs_within_diarizer=len(pair_within),
                pairs_cross_matcher=len(pair_cross),
                profiles_with_within=profiles_with_any_within,
                profiles_pure_cross=profiles_pure_cross,
                per_profile=per_profile,
                diar_within_pairs=sorted(['|'.join(sorted(p)) for p in diar_within_pairs]))

if __name__ == '__main__':
    arms = sys.argv[1].split(',') if len(sys.argv) > 1 else ['ami_clean']
    match = float(sys.argv[2]) if len(sys.argv) > 2 else 0.60
    out = {}
    for arm in arms:
        out[arm] = dict(diarizer=diarizer_seg_stats(arm),
                        attribution=attribute_arm(arm, match))
    print(json.dumps(out, indent=1))
