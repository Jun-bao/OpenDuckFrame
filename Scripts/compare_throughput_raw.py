#!/usr/bin/env python3
"""Compare selected tightly packed same-format outputs after timing; optional synthetic GT."""
import hashlib
import json
import sys

if len(sys.argv) not in (3, 4):
    raise SystemExit("usage: python3 Scripts/compare_throughput_raw.py BASE.raw CANDIDATE.raw [GT.raw]")
paths = sys.argv[1:]
data = [open(path, "rb").read() for path in paths]
if not data[0] or any(len(item) != len(data[0]) for item in data):
    raise SystemExit("raw sizes differ or are empty; compare only matching engine, format, pair, pattern and quality")
def compare(a, b):
    delta = [abs(x-y) for x, y in zip(a, b)]
    return {"mae_8bit": sum(delta)/len(delta), "max_8bit": max(delta), "bytes": len(delta)}
result = {"scope": "post-timing byte comparison; includes alpha for BGRA or chroma for NV12; inspect image artifacts separately",
          "sha256": [hashlib.sha256(item).hexdigest() for item in data], "candidate_vs_baseline": compare(data[0], data[1])}
if len(data) == 3:
    result["baseline_vs_synthetic_gt"] = compare(data[0], data[2])
    result["candidate_vs_synthetic_gt"] = compare(data[1], data[2])
print(json.dumps(result, indent=2))
