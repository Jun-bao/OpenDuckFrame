"""Prespecified paired native cost screen; pure standard-library offline math."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import statistics


def percentile(values, q):
    values = sorted(values)
    index = (len(values)-1)*q
    lo, hi = math.floor(index), math.ceil(index)
    return values[lo] if lo == hi else values[lo]*(hi-index)+values[hi]*(index-lo)


def analyze(raw):
    if not raw["functionalComplete"] or len(raw["pairs"]) != 200:
        raise ValueError("cost run incomplete; no passing screen")
    original = [row["original_ns"]/1e6 for row in raw["pairs"]]
    student = [row["student_ns"]/1e6 for row in raw["pairs"]]
    differences = [a-b for a,b in zip(original,student)]
    rng = random.Random(20261108)
    means = [statistics.fmean(rng.choices(differences,k=200)) for _ in range(10000)]
    ci = [percentile(means,.025),percentile(means,.975)]
    d0 = dict(n=200,p50_ms=percentile(original,.5),p95_ms=percentile(original,.95))
    s = dict(n=200,p50_ms=percentile(student,.5),p95_ms=percentile(student,.95))
    saving = 1-s["p50_ms"]/d0["p50_ms"]
    gates = dict(p50_reduction_ge10pct=saving>=.1,paired_mean_ci95_strictly_positive=ci[0]>0,
                 p95_not_worse=s["p95_ms"]<=d0["p95_ms"])
    return dict(original=d0,student=s,p50_relative_reduction=saving,
                paired_mean_saved_ms=statistics.fmean(differences),paired_mean_saved_ci95_ms=ci,
                bootstrap=dict(seed=20261108,resamples=10000,unit="one temporally paired AB row"),
                gates=gates,cost_screen_passed=all(gates.values()),
                original_sha256=raw["original_sha256"],student_sha256=raw["student_sha256"],
                width=raw["width"],height=raw["height"],
                scope="Short conditional native stream wall-time screen; adjacent pairs are not independent sessions. Not App FPS or visual quality acceptance.")


if __name__ == "__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--raw",type=Path,required=True)
    ap.add_argument("--output",type=Path,required=True)
    args=ap.parse_args()
    if args.output.exists():raise FileExistsError(args.output)
    result=analyze(json.loads(args.raw.read_text()))
    result["raw_sha256"]=hashlib.sha256(args.raw.read_bytes()).hexdigest()
    args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
    print(json.dumps(result))
