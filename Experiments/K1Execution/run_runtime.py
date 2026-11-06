"""Paired native product-runtime quality/cost checks, with unchanged weights."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "K1LowRank"))
from analyze_controlled import estimate
from run_four_corner import analyze


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--native-bin", type=Path, required=True)
    ap.add_argument("--native-source", type=Path, required=True)
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--inputs", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--gpu-lock", type=Path, required=True)
    ap.add_argument("--mode", choices=("quality", "profile", "cost"), required=True)
    ap.add_argument("--tier", choices=("fast", "balanced", "hq"), default="fast")
    ap.add_argument("--passes", type=int, default=4)
    ap.add_argument("--frames-per-arm", type=int, default=24)
    ap.add_argument("--variants-file", type=Path)
    ap.add_argument("--primary", default="warp")
    ap.add_argument("--baseline", default="d0")
    ap.add_argument("--screen-baseline")
    ap.add_argument("--warmup-per-arm", type=int, default=32)
    ap.add_argument("--save-outputs", action="store_true")
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    cases = json.loads(args.inputs.read_text())["cases"]
    variants = [dict(id="d0", model=str(args.model.resolve()), defer_commits=False, fused_warp=False),
                dict(id="warp", model=str(args.model.resolve()), defer_commits=False, fused_warp=True)]
    if args.variants_file:
        variants = json.loads(args.variants_file.read_text())["variants"]
    keys = [v["id"] for v in variants]
    assert args.primary in keys and args.baseline in keys and "d0" in keys
    config = dict(mode="controlled" if args.mode == "cost" else args.mode,
        app_entrypoints=True,
        output_dir=str(args.output.resolve()), width=1920, height=1080, tier=args.tier,
        variants=variants, cases=cases, warmup_per_arm=args.warmup_per_arm, frames_per_arm=args.frames_per_arm,
        target_sets=[[.25], [.5], [.75], [.1, .7], [.25, .5, .75], [.2, .4, .6, .8]], save_outputs=args.save_outputs)
    if args.mode == "cost":
        rng = random.Random(20261106)
        schedule = []
        for repeat in range(args.passes):
            items = cases.copy()
            rng.shuffle(items)
            for index, case in enumerate(items):
                cells = [(c, a) for c in ("continuous", "30Hz") for a in (.25, .5, .75)]
                rng.shuffle(cells)
                for cadence, alpha in cells:
                    order = [v["id"] for v in variants]
                    rng.shuffle(order)
                    schedule.append(dict(block=repeat * len(cases) + index, case_id=case["id"], alpha=alpha,
                        cadence=cadence, period_ms=1000 / 30 if cadence == "30Hz" else 0, order=order))
        config["schedule"] = schedule
    config_path = args.output / "config.json"
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    changed_weights = len({sha(v["model"]) for v in variants}) != 1
    prereg = dict(created_at=datetime.now(timezone.utc).isoformat(), mode=args.mode,
        primary=f"complete continuous K1 {args.baseline} minus {args.primary}, all three fixed phases must have positive paired whole-block CI; paced is diagnostic",
        candidate_selection="fixed finite cost screens; prefer widest passing trunk then confirm trained cost" if changed_weights else "fixed finite equivalent execution candidates; primary prespecified and other paths are controls",
        secondary_screen_baseline=args.screen_baseline,
        warmup_scope="each arm warms without pacing before measurement; steady continuous throughput and paced diagnostic, cold behavior separate",
        quality_gate="separate GT quality recovery/acceptance required; output equality is descriptive" if changed_weights else "exact output byte hashes at every target and K=1..4; no invented loss tolerance",
        mask_update="accumulate", weights_sha256={v["id"]: sha(v["model"]) for v in variants}, native_bin_sha256=sha(args.native_bin),
        input_sha256={c[k]: sha(c[k]) for c in cases for k in ("first", "second")},
        source_sha256={str(p.relative_to(args.native_source)): sha(p) for p in (args.native_source / "Sources").rglob("*") if p.is_file()},
        driver_sha256=sha(__file__), analysis_sha256=sha(Path(__file__).parent.parent / "K1LowRank/run_four_corner.py"),
        configuration=config, timing_scope="synchronous one-new-Head plus complete K1 call; no product presentation deadline claim",
        uncertainty="whole paired temporal blocks, repeated clips and adjacent blocks are not independent acceptance sessions")
    (args.output / "prereg.json").write_text(json.dumps(prereg, indent=2) + "\n")
    env = os.environ.copy()
    env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("ODF_K1_PROFILE", "RIFE_DUMP_DIR"):
        env.pop(key, None)
    with args.gpu_lock.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with (args.output / "execution.log").open("w") as log:
            subprocess.run([str(args.native_bin.resolve()), str(config_path)], env=env,
                stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    report = json.loads((args.output / (config["mode"] + ".json")).read_text())
    if args.mode != "cost":
        rows = report["rows"]
        pairs = {}
        for row in rows:
            key = (row["case_id"], row["K"], row["alpha"])
            pairs.setdefault(key, {})[row["variant"]] = row
        checks = [dict(case_id=k[0], K=k[1], alpha=k[2], candidate=key,
                       byte_equal=v["d0"]["output_sha256"] == v[key]["output_sha256"]) for k, v in pairs.items() for key in keys if key != "d0"]
        assert len(checks) == len(cases) * 12 * (len(variants) - 1)
        summary = dict(checks=checks, n_outputs=len(rows), n_pairs=len(checks),
                       all_outputs_byte_equal=all(c["byte_equal"] for c in checks), tier=args.tier)
    else:
        records = report["result"]["records"]
        assert len(records) == len(schedule) * len(variants)
        assert sum(len(r["samples"]) for r in records) == len(schedule) * len(variants) * args.frames_per_arm
        assert not report["profiling_enabled"] and not report["simulation_enabled"]
        summary = analyze(report, keys, args.primary, args.baseline)
        screens = {}
        for key in keys:
            if key in ("d0", args.baseline):
                continue
            by_alpha = {}
            baseline = args.baseline if key == args.primary else (args.screen_baseline or args.baseline)
            for alpha in (.25, .5, .75):
                filtered = {**report, "result": {**report["result"], "records": [r for r in records if r["alpha"] == alpha]}}
                by_alpha[str(alpha)] = analyze(filtered, keys, key, baseline)["by_cadence"]["continuous"]["primary_contrast"]
            screens[key] = dict(baseline=baseline, by_alpha=by_alpha, passed=all(
                x["whole_block_ci95_ms"][0] > 0 and x["moving_block_length3_ci95_ms"][0] > 0 for x in by_alpha.values()))
        summary["cost_screens"] = screens
        summary["continuous_by_alpha"] = screens[args.primary]["by_alpha"]
        summary["cost_screen_passed"] = screens[args.primary]["passed"]
        # Cost arms also compare the final bytes under matching direction/cache state.
        cells = {}
        for r in records:
            key = (r["block"], r["cadence"], r["alpha"])
            cells.setdefault(key, {})[r["variant"]] = r["last_output_sha256"]
        summary["all_arm_last_outputs_equal"] = all(v["d0"] == v[key] for v in cells.values() for key in keys if key != "d0")
        summary["arm_output_equality_to_d0"] = {key: all(v["d0"] == v[key] for v in cells.values()) for key in keys if key != "d0"}
    (args.output / "analysis.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
