#!/usr/bin/env python3
"""Recompute people-trapped per the stated definition and decompose by cause.

people-trapped := number of distinct true ids that have >=10% of THEIR appearances'
mass inside a profile that is shared by >=2 such true ids (a >=2-person profile).

We approximate "appearance mass in a profile" via reid_detail: each (meeting,true)
appearance has a 'dominant' profile = where most of its mass landed, and a
reid_accuracy. We count a true id t as trapped if t is one of the >=2 true ids that
the false_merge.profiles map lists for some profile pid (these ARE the >=2-person
profiles by construction), i.e. t participates in a multi-true-id profile.

Then we split trapped speakers into:
  - reachable-by-within (diarizer): t shares at least one WITHIN-MEETING diarizer pair
    with another speaker in its profile -> would be trapped even with a perfect matcher.
  - matcher-only: t is in a multi-id profile but ALL its fused pairs are cross-meeting.
"""
import json, os, sys
from collections import defaultdict

ROOT = '/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2'
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
from q3_attribution import attribute_arm

def trapped_decomp(arm, match):
    att = attribute_arm(arm, match)
    diar_within = set()
    for p in att['diar_within_pairs']:
        a, b = p.split('|'); diar_within.add(frozenset((a, b)))

    trapped = set()                  # all true ids in any multi-id profile
    trapped_within = set()           # those sharing a within-meeting pair inside their profile
    for prof in att['per_profile']:
        tids = prof['tids']
        if len(tids) < 2:
            continue
        for t in tids:
            trapped.add(t)
        # for each speaker, does it share a within-meeting pair with a co-member?
        for t in tids:
            for u in tids:
                if t == u:
                    continue
                if frozenset((t, u)) in diar_within:
                    trapped_within.add(t)
                    break
    trapped_matcher_only = trapped - trapped_within
    return dict(arm=arm, match=match,
                profiles_end=att['profiles_end'],
                fm_count=att['fm_count'],
                trapped_total=len(trapped),
                trapped_within_diarizer=len(trapped_within),
                trapped_matcher_only=len(trapped_matcher_only),
                trapped_matcher_only_ids=sorted(trapped_matcher_only))

if __name__ == '__main__':
    arms = sys.argv[1].split(',')
    match = float(sys.argv[2]) if len(sys.argv) > 2 else 0.60
    res = [trapped_decomp(a, match) for a in arms]
    print(json.dumps(res, indent=1))
