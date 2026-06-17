#!/usr/bin/env python3
"""Independent diarizer floor: with a PERFECT matcher (zero cross-meeting fusion),
how many speakers are STILL trapped purely because the diarizer mixed them inside a
single meeting's cluster?

Method (matcher-free, dumps+RTTM only):
  - For each diarizer cluster (meeting,speakerId), compute true-id mass via RTTM overlap.
  - 'Mixed' cluster: >=2 true ids each hold >= MIX_FRAC of the cluster's matched mass.
  - A perfect matcher assigns each cluster to its dominant true id, but a MIXED cluster
    physically contains >=2 speakers' audio, so every true id holding >=10% of that
    cluster is trapped together regardless of matcher quality.
  - Floor people-trapped = distinct true ids that appear (>=10% of some cluster's mass)
    in any mixed cluster alongside another such true id.
Reports per arm; identical for baseline/global since clusters are byte-identical.
"""
import json, glob, os, sys
from collections import defaultdict

ROOT = '/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2'
RTTM_DIR = os.path.join(ROOT, 'data/ami/rttm')
MIX_FRAC = 0.10   # match the people-trapped >=10% mass threshold

def load_rttm():
    rttm = defaultdict(list)
    for f in glob.glob(os.path.join(RTTM_DIR, '*.rttm')):
        m = os.path.basename(f)[:-5]
        for line in open(f):
            p = line.split()
            if p and p[0] == 'SPEAKER':
                st = float(p[3]); dur = float(p[4]); rttm[m].append((st, st+dur, p[7]))
    return rttm
RTTM = load_rttm()

def ov(a0,a1,b0,b1): return max(0.0, min(a1,b1)-max(a0,b0))

def floor(arm):
    dumpdir = os.path.join(ROOT,'data/eval',arm,'dumps')
    clusters = defaultdict(list)
    for f in glob.glob(os.path.join(dumpdir,'*.json')):
        d=json.load(open(f)); m=d['meeting']
        for s in d['segments']:
            clusters[(m,s['speakerId'])].append((s['start'],s['end']))
    trapped=set(); mixed_clusters=0
    for (m,sid),segs in clusters.items():
        mass=defaultdict(float)
        for s0,s1 in segs:
            for r0,r1,t in RTTM[m]:
                o=ov(s0,s1,r0,r1)
                if o>0: mass[t]+=o
        tot=sum(mass.values())
        if tot<=0: continue
        inside={t for t,v in mass.items() if v/tot>=MIX_FRAC}
        if len(inside)>=2:
            mixed_clusters+=1
            trapped|=inside
    return dict(arm=arm, mixed_clusters=mixed_clusters,
                floor_people_trapped=len(trapped),
                floor_ids=sorted(trapped))

if __name__=='__main__':
    arms=sys.argv[1].split(',')
    print(json.dumps([floor(a) for a in arms], indent=1))
