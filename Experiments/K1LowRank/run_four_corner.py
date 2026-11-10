"""Same-window real-input four-corner cost probe with fixed whole-block analysis."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import random
import subprocess

import numpy as np

from analyze_controlled import estimate
from lowrank import sha


def analyze(report, variants, primary="d34", baseline="d0"):
    rows = report["result"]["records"]
    n = len({r["block"] for r in rows})
    rng = np.random.default_rng(20261106)
    iid = rng.integers(n, size=(30000, n))
    starts = rng.integers(n, size=(30000, (n + 2) // 3))
    moving = ((starts[:, :, None] + np.arange(3)) % n).reshape(30000, -1)[:, :n]
    by_cadence = {}
    for cadence in ("continuous", "30Hz"):
        values, descriptive = {}, {}
        for key in variants:
            selected = [r for r in rows if r["cadence"] == cadence and r["variant"] == key]
            values[key] = np.array([np.mean([np.mean([s["host_ms"] for s in r["samples"]])
                                            for r in selected if r["block"] == block]) for block in range(n)])
            samples = [s for r in selected for s in r["samples"]]
            descriptive[key] = dict(n_calls=len(samples), mean_ms=float(values[key].mean()),
                p95_ms=float(np.quantile([s["host_ms"] for s in samples], .95)),
                thermal_states=sorted({r["thermal_state"] for r in selected}))
        comparisons = {key: estimate(values["d0"], values[key], iid, moving) for key in variants if key != "d0"}
        result = dict(descriptive=descriptive, comparisons=comparisons)
        result["primary_contrast"] = estimate(values[baseline], values[primary], iid, moving)
        if set(("d3", "d4", "d34")).issubset(values):
            kappa = values["d34"] - values["d3"] - values["d4"] + values["d0"]
            result["interaction"] = dict(kappa_ms=float(kappa.mean()),
                whole_block_ci95_ms=np.quantile(kappa[iid].mean(1), [.025, .975]).tolist(),
                moving_block_length3_ci95_ms=np.quantile(kappa[moving].mean(1), [.025, .975]).tolist(),
                definition="T34-T3-T4+T0; positive is less saving than additive, no unique causal attribution")
        by_cadence[cadence] = result
    return dict(blocks=n, by_cadence=by_cadence,
        primary=f"continuous / {baseline} minus {primary}, equal target and clip weight; other contrasts and 30Hz are diagnostic",
        uncertainty="whole temporal block bootstrap; paired within block, adjacent blocks remain dependent; short-window descriptive only",
        input_scope="five old development clips, one five-frame window each, repeated alternating endpoints; not sustained natural playback or product deadlines")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--native-bin", type=Path, required=True)
    ap.add_argument("--native-source", type=Path, required=True)
    ap.add_argument("--inputs", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--gpu-lock", type=Path, required=True)
    ap.add_argument("--variants", default="d0,d3,d4,d34")
    ap.add_argument("--primary", default="d34")
    ap.add_argument("--baseline", default="d0")
    ap.add_argument("--passes", type=int, default=2)
    ap.add_argument("--frames-per-arm", type=int, default=12)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    inputs = json.loads(args.inputs.read_text())
    keys = args.variants.split(",")
    assert args.primary in keys and args.baseline in keys and "d0" in keys
    variants = [dict(id=k, model=inputs["models"][k], defer_commits=False) for k in keys]
    rng = random.Random(20261106)
    schedule = []
    for repeat in range(args.passes):
        cases = inputs["cases"].copy()
        rng.shuffle(cases)
        for case in cases:
            block = repeat * len(cases) + cases.index(case)
            cells = [(c, a) for c in ("continuous", "30Hz") for a in (.25, .5, .75)]
            rng.shuffle(cells)
            for cadence, alpha in cells:
                order = keys.copy()
                rng.shuffle(order)
                schedule.append(dict(block=block, case_id=case["id"], cadence=cadence, alpha=alpha,
                                     period_ms=1000 / 30 if cadence == "30Hz" else 0, order=order))
    config = dict(mode="controlled", models=[v["model"] for v in variants], cases=inputs["cases"],
        variants=variants, schedule=schedule, width=1920, height=1080, tier="fast", warmup_per_arm=4,
        frames_per_arm=args.frames_per_arm, output_dir=str(args.output.resolve()))
    config_path = args.output / "config.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    sources = Path(__file__).parent
    prereg = dict(created_at=datetime.now(timezone.utc).isoformat(), random_seed=20261106,
        primary=f"continuous {args.baseline} minus {args.primary}; all other contrasts diagnostic, no product acceptance",
        native_bin_sha256=sha(args.native_bin), configuration=config, config_sha256=sha(config_path),
        source_sha256={str(p.relative_to(sources)): sha(p) for p in sources.rglob("*") if p.is_file() and "__pycache__" not in p.parts},
        native_source_sha256={str(p.relative_to(args.native_source)): sha(p) for p in (args.native_source / "Sources").rglob("*") if p.is_file()},
        input_sha256={c[k]: sha(c[k]) for c in inputs["cases"] for k in ("first", "second")},
        weights_sha256={v["model"]: sha(v["model"]) for v in variants},
        uncertainty="whole block bootstrap, moving block length3 sensitivity; five clips and repeated temporal blocks are not independent acceptance sessions",
        paced_scope="30Hz is a mechanism cadence; true endpoint spacing is 80ms; next-arrival check is not a presentation deadline")
    (args.output / "prereg.json").write_text(json.dumps(prereg, indent=2) + "\n")
    env = os.environ.copy()
    env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("ODF_K1_PROFILE", "RIFE_DUMP_DIR"):
        env.pop(key, None)
    with args.gpu_lock.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with (args.output / "execution.log").open("w") as log:
            subprocess.run([str(args.native_bin.resolve()), str(config_path.resolve())], env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    report = json.loads((args.output / "controlled.json").read_text())
    records = report["result"]["records"]
    assert len(records) == len(schedule) * len(variants)
    assert sum(len(r["samples"]) for r in records) == len(schedule) * len(variants) * args.frames_per_arm
    assert not report["profiling_enabled"] and not report["simulation_enabled"]
    result = analyze(report, keys, args.primary, args.baseline)
    (args.output / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    for cadence, value in result["by_cadence"].items():
        print(cadence, json.dumps(value), flush=True)
