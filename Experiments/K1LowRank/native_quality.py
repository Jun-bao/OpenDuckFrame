"""Actual Metal FP16 outputs versus GT on the fixed old development diagnosis.

This is distinct from, and does not establish, product/independent acceptance.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image

from lowrank import sha


def read_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--native-bin", type=Path, required=True)
    ap.add_argument("--experiment", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--gpu-lock", type=Path, required=True)
    ap.add_argument("--inventory", type=Path)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    design = json.loads((args.experiment / "design.json").read_text())
    inventory = json.loads((args.inventory or args.experiment / "all-models.json").read_text())
    keys = list(inventory["models"])
    cases = [c for c in design["cases"] if c["partition"] == "diagnostic"]
    prereg = dict(created_at=datetime.now(timezone.utc).isoformat(),
        design_sha256=sha(args.experiment / "design.json"), native_bin_sha256=sha(args.native_bin),
        script_sha256=sha(__file__), keys=keys, cases=[c["id"] for c in cases], alphas=design["alphas"],
        weights_sha256={k: sha(p) for k, p in inventory["models"].items()},
        scope="four fixed windows / two old development clips / twelve target times; native FP16 with replace mask; no app or independent quality acceptance")
    (args.output / "prereg.json").write_text(json.dumps(prereg, indent=2) + "\n")
    env = os.environ.copy()
    env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("ODF_K1_PROFILE", "RIFE_DUMP_DIR"):
        env.pop(key, None)
    rows = []
    with args.gpu_lock.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for case in cases:
            destination = args.output / case["id"]
            destination.mkdir()
            paths = []
            for name, index in (("first", 0), ("second", 4)):
                rgb = np.asarray(Image.open(case["frames"][index]).convert("RGB"))
                bgra = np.concatenate((rgb[:, :, ::-1], np.full((*rgb.shape[:2], 1), 255, np.uint8)), axis=2)
                path = destination / (name + ".bgra")
                path.write_bytes(bgra.tobytes())
                paths.append(str(path))
            config = dict(mode="stream", models=list(inventory["models"].values()), first=paths[0], second=paths[1],
                width=1920, height=1080, tier="fast", warmup=2, rounds=1, alphas=design["alphas"], output_dir=str(destination))
            config_path = destination / "config.json"
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            with (destination / "execution.log").open("w") as log:
                subprocess.run([str(args.native_bin.resolve()), str(config_path)], env=env,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            report = json.loads((destination / "stream.json").read_text())
            for alpha, index in zip(design["alphas"], (1, 2, 3)):
                gt = read_rgb(case["frames"][index])
                outputs = {}
                for key in keys:
                    result = next(r for r in report["rows"] if r["model"] == inventory["models"][key] and r["alpha"] == alpha)
                    outputs[key] = np.fromfile(result["output_bgra"], dtype=np.uint8).reshape(1080, 1920, 4)[:, :, [2, 1, 0]].astype(np.float32) / 255
                metrics = {}
                for key, output in outputs.items():
                    mse = float(np.mean(np.square(output - gt), dtype=np.float64))
                    metrics[key] = dict(gt_psnr_db=-10 * math.log10(max(mse, 1e-20)),
                                        teacher_mse=float(np.mean(np.square(output - outputs["d0"]), dtype=np.float64)))
                    if "r4" in outputs:
                        metrics[key]["r4_mse"] = float(np.mean(np.square(output - outputs["r4"]), dtype=np.float64))
                rows.append(dict(case_id=case["id"], alpha=alpha, models=metrics))
            print("native diagnosis", case["id"], flush=True)
    summary = {}
    for key in keys:
        deltas = [r["models"][key]["gt_psnr_db"] - r["models"]["d0"]["gt_psnr_db"] for r in rows]
        summary[key] = dict(mean_gt_psnr_db=float(np.mean([r["models"][key]["gt_psnr_db"] for r in rows])),
            mean_delta_to_teacher_db=float(np.mean(deltas)), worst_delta_to_teacher_db=min(deltas),
            mean_teacher_mse=float(np.mean([r["models"][key]["teacher_mse"] for r in rows])))
        if "r4" in keys:
            summary[key]["mean_r4_mse"] = float(np.mean([r["models"][key]["r4_mse"] for r in rows]))
            summary[key]["max_abs_gt_psnr_difference_to_r4_db"] = max(abs(
                r["models"][key]["gt_psnr_db"] - r["models"]["r4"]["gt_psnr_db"]) for r in rows)
    (args.output / "quality.json").write_text(json.dumps(dict(prereg=prereg, summary=summary, rows=rows), indent=2) + "\n")
    print(json.dumps(summary), flush=True)
