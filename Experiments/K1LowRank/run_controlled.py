"""Predetermined four-arm short-window experiment, reusing original inputs.

Submission experiment primary: default D0 vs default Ds at 30 Hz.
Native-activation experiment primary: unchanged D0 vs D0 with native activation.
Each experiment declares its primary before acquiring its own samples.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--native-bin", type=Path, required=True)
    ap.add_argument("--native-source", type=Path, required=True)
    ap.add_argument("--prior-results", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--gpu-lock", type=Path, required=True)
    ap.add_argument("--blocks", type=int, default=12)
    ap.add_argument("--frames-per-arm", type=int, default=20)
    ap.add_argument("--intervention", choices=("submission", "native-leaky"), default="submission")
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    prior = json.loads((args.prior_results / "stream/config.json").read_text())
    base, student = prior["models"][:2]
    suffix = "native" if args.intervention == "native-leaky" else "deferred"
    variants = [dict(id="d0", model=base, defer_commits=False), dict(id="ds", model=student, defer_commits=False),
                dict(id="d0_" + suffix, model=base, defer_commits=args.intervention == "submission", native_leaky=args.intervention == "native-leaky"),
                dict(id="ds_" + suffix, model=student, defer_commits=args.intervention == "submission", native_leaky=args.intervention == "native-leaky")]
    rng = random.Random(20261106)
    schedule = []
    for block in range(args.blocks):
        cells = [(cadence, alpha) for cadence in ("continuous", "30Hz") for alpha in (.25, .5, .75)]
        rng.shuffle(cells)
        for cadence, alpha in cells:
            order = [v["id"] for v in variants]
            rng.shuffle(order)
            schedule.append(dict(block=block, cadence=cadence, alpha=alpha, order=order,
                                 period_ms=1000 / 30 if cadence == "30Hz" else 0))
    config = dict(mode="controlled", models=[base, student], output_dir=str(args.output.resolve()), variants=variants,
                  schedule=schedule, frames_per_arm=args.frames_per_arm, warmup_per_arm=4,
                  width=1920, height=1080, tier="fast", first=prior["first"], second=prior["second"])
    config_file = args.output / "config.json"
    config_file.write_text(json.dumps(config, indent=2) + "\n")
    source_dir = Path(__file__).resolve().parent
    primary = ("block mean D0-expanded minus D0-native-activation host call ms at 30Hz, alpha equal-weighted"
               if args.intervention == "native-leaky" else "block mean D0-default minus Ds-default host call ms at 30Hz, alpha equal-weighted")
    prereg = dict(created_at=datetime.now(timezone.utc).isoformat(), random_seed=20261106, intervention=args.intervention,
                  primary=primary,
                  secondary="continuous; other four-arm contrasts and interactions; no post-hoc primary replacement",
                  statistical_unit="whole time block, not frame or command buffer; short-window temporal dependence remains a limitation",
                  performance_gate="primary positive lower confidence bound conditional on block-independence approximation; no formal product acceptance",
                  quality_gate="same-weight baseline/intervention output hashes must match; no new student quality acceptance",
                  native_bin_sha256=sha(args.native_bin.resolve()),
                  source_sha256={str(p.relative_to(source_dir)): sha(p) for p in source_dir.rglob("*")
                                 if p.is_file() and "__pycache__" not in p.parts},
                  native_source_sha256={str(p.relative_to(args.native_source)): sha(p) for p in (args.native_source / "Sources").rglob("*") if p.is_file()},
                  weights_sha256={p: sha(Path(p)) for p in (base, student)},
                  input_sha256={p: sha(Path(p)) for p in (prior["first"], prior["second"])},
                  config_sha256=sha(config_file), configuration=config)
    (args.output / "prereg.json").write_text(json.dumps(prereg, indent=2) + "\n")
    env = os.environ.copy()
    env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("ODF_K1_PROFILE", "RIFE_DUMP_DIR"):
        env.pop(key, None)
    with args.gpu_lock.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with (args.output / "execution.log").open("w") as log:
            subprocess.run([str(args.native_bin.resolve()), str(config_file.resolve())], env=env,
                           stdout=log, stderr=subprocess.STDOUT, timeout=180, check=True)
    report = json.loads((args.output / "controlled.json").read_text())
    rows = report["result"]["records"]
    expected = args.blocks * 6 * 4 * args.frames_per_arm
    actual = sum(len(r["samples"]) for r in rows)
    assert actual == expected
    checks = []
    for cell in schedule:
        found = {r["variant"]: r for r in rows if r["block"] == cell["block"] and r["cadence"] == cell["cadence"] and r["alpha"] == cell["alpha"]}
        for graph in ("d0", "ds"):
            checks.append(dict(block=cell["block"], cadence=cell["cadence"], alpha=cell["alpha"], graph=graph,
                               byte_hash_equal=found[graph]["last_output_sha256"] == found[graph + "_" + suffix]["last_output_sha256"]))
    validation = dict(expected_samples=expected, actual_samples=actual, checks=checks,
                      same_graph_pixel_hashes_equal=all(c["byte_hash_equal"] for c in checks),
                      profiling_enabled=report["profiling_enabled"])
    (args.output / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
    print(json.dumps({k: v for k, v in validation.items() if k != "checks"}), flush=True)
