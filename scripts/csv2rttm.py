#!/usr/bin/env python3
"""Turn a simple speaker-label CSV into the RTTM the eval expects.
CSV columns (header required): start,end,speaker   (seconds; speaker = any stable name/id)
  e.g.   0.0,4.2,alice
         4.2,9.8,bob
Usage: python3 scripts/csv2rttm.py labels.csv NAME > ground_truth.rttm
"""
import csv, sys

if len(sys.argv) < 3:
    sys.exit("usage: csv2rttm.py <labels.csv> <recording_name>")
name = sys.argv[2]
for r in csv.DictReader(open(sys.argv[1])):
    s, e, spk = float(r["start"]), float(r["end"]), r["speaker"].strip()
    print(f"SPEAKER {name} 1 {s:.3f} {e - s:.3f} <NA> <NA> {spk} <NA> <NA>")
