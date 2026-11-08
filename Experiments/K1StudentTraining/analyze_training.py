"""Audit the completed bounded run and optionally render its training curves.

Only reads existing logs/manifests. Does not load images, weights or PyTorch.
Matplotlib is optional and can live in a separate plotting environment.
"""
from __future__ import annotations

import argparse
from collections import deque
import csv
import hashlib
import json
import math
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def analyze(run_root, output):
    run = run_root / "training-r1"
    manifest = json.loads((run / "manifest.json").read_text())
    if manifest["status"] == "running":
        raise ValueError("training is still running; this is not a final report")
    steps = [json.loads(line) for line in (run / "steps.jsonl").read_text().splitlines() if line]
    data = json.loads(Path(manifest["config"]["data_manifest"]).read_text())
    allowed = {row["id"] for row in data["train_pairs"]}
    evaluations = manifest["evaluations"]
    initial = evaluations[0]
    best = min(evaluations, key=lambda row: row["means"]["teacher_rgb_l1"])
    last = evaluations[-1]
    checks = dict(
        logged_steps_are_contiguous=[row["step"] for row in steps] == list(range(1, len(steps) + 1)),
        completed_steps_match=len(steps) == manifest["completed_steps"],
        every_step_has_batch4=all(len(row["samples"]) == 4 for row in steps),
        all_optimizer_samples_are_training_only=all(sample["pair"] in allowed for row in steps for sample in row["samples"]),
        all_losses_gradients_finite=all(math.isfinite(row[key]) for row in steps for key in ("loss", "rgb", "flow3", "mask3", "flow4", "mask4", "grad_norm", "lr")),
        frozen_parameters_unchanged=manifest["frozen_tensor_changes"] == [],
        original_weights_unchanged=manifest["source_unchanged"],
        actual_best_selection_matches=best["step"] == manifest["best_step"],
        holdout_not_accessed=manifest["holdout_accessed"] is False,
    )
    result = dict(status=manifest["status"], trained=manifest["trained"],
        optimizer_steps=manifest["completed_steps"], optimizer_samples=len(steps) * 4,
        trainable_parameter_count=manifest["trainable_parameter_count"],
        elapsed_seconds=manifest["elapsed_seconds"], artifact_flush_seconds=manifest["artifact_flush_seconds"],
        best_step=best["step"], last_evaluated_step=last["step"],
        initial_teacher_rgb_l1=initial["means"]["teacher_rgb_l1"],
        best_teacher_rgb_l1=best["means"]["teacher_rgb_l1"],
        best_rgb_l1_reduction_percent=100 * (1 - best["means"]["teacher_rgb_l1"] / initial["means"]["teacher_rgb_l1"]),
        initial_mean_teacher_rgb_psnr_db=initial["means"]["teacher_rgb_psnr_db"],
        best_mean_teacher_rgb_psnr_db=best["means"]["teacher_rgb_psnr_db"],
        checks=checks, log_contract_passed=all(checks.values()),
        best_checkpoint=manifest["best_checkpoint"], last_weights=manifest["last_weights"]["weights_path"],
        hashes={"training_manifest": sha(run / "manifest.json"), "steps": sha(run / "steps.jsonl"),
                "data_manifest": sha(manifest["config"]["data_manifest"]), "analyzer": sha(__file__)},
        scope="48 fixed adjacent development queries; teacher agreement, not independent quality or application FPS acceptance")
    output.mkdir(parents=True, exist_ok=False)
    (output / "summary.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    with (output / "evaluations.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["step", "elapsed_seconds", *initial["means"]])
        writer.writeheader()
        for row in evaluations:
            writer.writerow(dict(step=row["step"], elapsed_seconds=row["elapsed_seconds"], **row["means"]))
    return result, steps, evaluations


def plot(output, result, steps, evaluations):
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import pyplot as plt

    fig, axes = plt.subplots(3, 1, figsize=(10, 9), constrained_layout=True)
    queue, total, smooth = deque(), 0., []
    for row in steps:
        queue.append(row["loss"])
        total += row["loss"]
        if len(queue) > 50:
            total -= queue.popleft()
        smooth.append(total / len(queue))
    x = [row["step"] for row in steps]
    axes[0].plot(x, [row["loss"] for row in steps], color="#8aadc6", alpha=.25, linewidth=.5)
    axes[0].plot(x, smooth, color="#22577a", linewidth=1.5, label="50-step moving mean")
    axes[0].set_ylabel("Normalized distillation loss")
    axes[0].legend()
    ex = [row["step"] for row in evaluations]
    axes[1].plot(ex, [row["means"]["teacher_rgb_l1"] for row in evaluations], "o-", color="#26734d")
    axes[1].scatter([result["best_step"]], [result["best_teacher_rgb_l1"]], color="#bd4f32", s=65, label="Selected best", zorder=3)
    axes[1].set_ylabel("Development teacher RGB L1")
    axes[1].legend()
    axes[2].plot(x, [row["lr"] for row in steps], color="#765ba7")
    axes[2].set_ylabel("Learning rate")
    axes[2].set_xlabel("Optimizer update (effective batch 4)")
    for axis in axes:
        axis.grid(alpha=.2)
    fig.suptitle("Product-aligned RIFE student: bounded distillation\n48 fixed development queries; no independent quality/FPS acceptance", fontsize=12)
    fig.savefig(output / "training-curves.png", dpi=160)
    fig.savefig(output / "training-curves.svg")
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--plot", action="store_true")
    args = parser.parse_args()
    result, steps, evaluations = analyze(args.run_root, args.output)
    if args.plot:
        plot(args.output, result, steps, evaluations)
    print(json.dumps(result, ensure_ascii=False))
