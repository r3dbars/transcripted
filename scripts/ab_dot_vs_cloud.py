#!/usr/bin/env python3
"""Controlled dot-vs-cloud speaker-matcher A/B on cached VoxCeleb embeddings.

Replays the SAME single-speaker meetings (sorted order = round-robin across speakers)
through two matchers, everything else identical:
  DOT   - one EMA-averaged 256-d vector/profile; match cosine>=thr (today's design).
  CLOUD - keep each profile's sample vectors; match a new clip to its NEAREST stored sample.

Metrics per matcher:
  reid_to_anchor[k] = % of meeting-k clips assigned to the profile created at the person's
                      FIRST meeting (continuity with original identity).
  recognized[k]     = % of meeting-k clips matched to ANY existing profile (not a brand-new
                      badge) -> "did we treat them as a returning person at all".
  profiles_end      = badges created for n_true real people (ideal = n_true).
  false_merge       = profiles whose mass spans >=2 distinct true speakers (>=10% each).

Modes:
  (no --matcher) -> human-readable sweep table for both matchers.
  --matcher dot|cloud --thr T [--ema E|--cap C] --json -> one JSON result (for agents).
"""
import argparse, glob, json, math, os, sys
from collections import defaultdict

def cluster_mean(segs):
    def mean(embs):
        if not embs: return None
        dim=len(embs[0]); s=[0.0]*dim
        for e in embs:
            if len(e)==dim:
                for i in range(dim): s[i]+=e[i]
        n=len(embs); s=[x/n for x in s]
        nrm=math.sqrt(sum(x*x for x in s)) or 1.0
        return [x/nrm for x in s]
    good=[sg["embedding"] for sg in segs if sg.get("embedding") and sg["quality"]>=0.3 and (sg["end"]-sg["start"])>=1.0]
    if good: return mean(good)
    allv=[sg["embedding"] for sg in segs if sg.get("embedding")]
    return mean(allv)

def load_meetings(dumps_dir):
    out=[]
    for f in sorted(glob.glob(os.path.join(dumps_dir,"*.json"))):
        d=json.load(open(f)); m=d["meeting"]; spk=m.split("_",1)[1]
        emb=cluster_mean(d["segments"])
        if emb is not None: out.append((m,spk,emb))
    return out

def cos(a,b): return sum(x*y for x,y in zip(a,b))
def l2norm(v):
    n=math.sqrt(sum(x*x for x in v)) or 1.0
    return [x/n for x in v]

class DotDB:
    def __init__(self,thr,ema): self.thr=thr; self.ema=ema; self.P=[]
    def assign(self,emb,true):
        best,bi=-2,-1
        for i,p in enumerate(self.P):
            c=cos(emb,p["vec"])
            if c>best: best,bi=c,i
        new = not (bi>=0 and best>=self.thr)
        if not new:
            p=self.P[bi]; p["vec"]=l2norm([(1-self.ema)*o+self.ema*e for o,e in zip(p["vec"],emb)]); p["counts"][true]+=1
            return bi,False
        self.P.append({"vec":emb[:],"counts":defaultdict(int)}); self.P[-1]["counts"][true]+=1
        return len(self.P)-1,True

class CloudDB:
    def __init__(self,thr,cap): self.thr=thr; self.cap=cap; self.P=[]
    def assign(self,emb,true):
        best,bi=-2,-1
        for i,p in enumerate(self.P):
            c=max(cos(emb,s) for s in p["samples"])
            if c>best: best,bi=c,i
        new = not (bi>=0 and best>=self.thr)
        if not new:
            p=self.P[bi]; p["samples"].append(emb)
            if len(p["samples"])>self.cap: p["samples"].pop(0)
            p["counts"][true]+=1
            return bi,False
        self.P.append({"samples":[emb[:]],"counts":defaultdict(int)}); self.P[-1]["counts"][true]+=1
        return len(self.P)-1,True

def evaluate(meetings, db, max_app):
    anchor={}; appear=defaultdict(int)
    to_anchor=defaultdict(list); recog=defaultdict(list)
    for (m,spk,emb) in meetings:
        pid,is_new=db.assign(emb,spk)
        appear[spk]+=1; k=appear[spk]
        if k==1: anchor[spk]=pid
        else:
            to_anchor[k].append(1 if pid==anchor[spk] else 0)
            recog[k].append(0 if is_new else 1)
    cur=lambda d:{k:round(100*sum(v)/len(v)) for k,v in sorted(d.items()) if k<=max_app}
    fm=0
    for p in db.P:
        tot=sum(p["counts"].values()) or 1
        if sum(1 for t,c in p["counts"].items() if c/tot>=0.10)>=2: fm+=1
    return cur(to_anchor), cur(recog), len(db.P), fm

def run(meetings, matcher, thr, ema, cap, max_app):
    db = DotDB(thr,ema) if matcher=="dot" else CloudDB(thr,cap)
    a,r,pe,fm = evaluate(meetings, db, max_app)
    return {"matcher":matcher,"thr":thr,"ema":ema if matcher=="dot" else None,
            "cap":cap if matcher=="cloud" else None,
            "reid_to_anchor":a,"recognized":r,"profiles_end":pe,"false_merge":fm}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--dumps-dir",default="data/eval/voxceleb/dumps")
    ap.add_argument("--matcher",choices=["dot","cloud"])
    ap.add_argument("--thr",type=float); ap.add_argument("--ema",type=float,default=0.5)
    ap.add_argument("--cap",type=int,default=10); ap.add_argument("--max-app",type=int,default=8)
    ap.add_argument("--json",action="store_true")
    args=ap.parse_args()
    M=load_meetings(args.dumps_dir)
    n_true=len(set(s for _,s,_ in M))
    if args.matcher and args.thr is not None:
        res=run(M,args.matcher,args.thr,args.ema,args.cap,args.max_app); res["n_true"]=n_true; res["n_meetings"]=len(M)
        print(json.dumps(res)); return
    print(f"loaded {len(M)} meetings, {n_true} true speakers (ideal profiles={n_true})\n")
    print("DOT (one EMA vector):  reid-to-anchor by meeting #")
    for thr in (0.45,0.50,0.55,0.60):
        r=run(M,"dot",thr,args.ema,args.cap,args.max_app)
        cells=" ".join(f"m{k}:{r['reid_to_anchor'].get(k,'-'):>3}" for k in range(2,args.max_app+1))
        print(f"  thr={thr:.2f} | {cells} | profiles={r['profiles_end']:>3} fm={r['false_merge']}")
    print("\nCLOUD (nearest stored sample):  reid-to-anchor by meeting #")
    for thr in (0.55,0.60,0.65,0.70,0.75):
        r=run(M,"cloud",thr,args.ema,args.cap,args.max_app)
        cells=" ".join(f"m{k}:{r['reid_to_anchor'].get(k,'-'):>3}" for k in range(2,args.max_app+1))
        print(f"  thr={thr:.2f} | {cells} | profiles={r['profiles_end']:>3} fm={r['false_merge']}")

if __name__=="__main__": main()
