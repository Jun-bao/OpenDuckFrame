"""Run the bounded phase-0/1/2 experiment against real weights and native MPS.

Output stays in a user-selected data directory. This does not install a model
into the app, train on test data, simulate another Mac, or accept video quality.
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
from datetime import datetime, timezone

import numpy as np
import torch
from torch.nn import functional as F

import lowrank as lr


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()


def scene(width, height, time):
    """Analytic motion: target RGB is rendered independently at its exact time."""
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    image = np.stack((0.32 + 0.13 * np.sin((xx - 48 * time) / 11),
                      0.38 + 0.16 * np.cos((yy + 24 * time) / 17),
                      0.40 + 0.12 * np.sin((xx + yy - 32 * time) / 19)), -1)
    rect = (xx > width * 0.26 + 70 * time) & (xx < width * 0.48 + 70 * time) & (yy > height * 0.26) & (yy < height * 0.62)
    image[rect] = (0.95, 0.23, 0.12)
    circle = (xx - (width * 0.68 - 40 * time)) ** 2 + (yy - height * 0.62) ** 2 < (height * 0.11) ** 2
    image[circle] = (0.11, 0.83, 0.93)
    image[(yy > 24) & (yy < 29) & (xx > 30) & (xx < width - 30)] = (0.95, 0.95, 0.95)
    rgb = np.rint(np.clip(image, 0, 1) * 255).astype(np.uint8)
    return np.concatenate((rgb[:, :, ::-1], np.full((height, width, 1), 255, np.uint8)), 2)


def stats(samples):
    x = np.array([s["host_ms"] for s in samples])
    return dict(n=len(x), median_ms=float(np.median(x)), mean_ms=float(x.mean()), p95_ms=float(np.quantile(x, .95)))


def paired_speed(base, candidate):
    a = np.array([s["host_ms"] for s in base])
    b = np.array([s["host_ms"] for s in candidate])
    difference = a - b
    rng = np.random.default_rng(1106)
    means = difference[rng.integers(0, len(a), size=(5000, len(a)))].mean(1)
    low, high = np.quantile(means, [.025, .975])
    return dict(mean_saved_ms=float(difference.mean()), mean_saved_ms_ci95=[float(low), float(high)],
                median_speedup_percent=float((1 - np.median(b) / np.median(a)) * 100),
                timing_advantage_observed=bool(low > 0),
                note="paired interleaved timing trials in one device window, not independent video-quality samples")


def errors(a, b):
    x, y = np.asarray(a, np.float64), np.asarray(b, np.float64)
    difference = x - y
    mse = float(np.mean(difference ** 2))
    return dict(mae=float(np.mean(np.abs(difference))), max_abs=float(np.max(np.abs(difference))),
                rmse=math.sqrt(mse), psnr_db=None if mse == 0 else -10 * math.log10(mse))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lab-root", type=Path, required=True)
    ap.add_argument("--lab-native", type=Path, required=True)
    ap.add_argument("--product-worktree", type=Path, required=True)
    ap.add_argument("--product-native", type=Path, required=True)
    ap.add_argument("--native-bin", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--gpu-lock", type=Path, required=True)
    ap.add_argument("--rounds", type=int, default=40)
    args = ap.parse_args()
    torch.set_num_threads(4)
    args.output.mkdir(parents=True, exist_ok=True)
    rmw, _ = lr.load_lab(args.lab_root)
    baseline = args.lab_native / "Sources/RifeMetal/Resources/rife-v4.25.rmw"
    urls = [baseline, *(args.output / "models" / (g + ".rmw") for g in lr.GRAPHS)]
    env = os.environ.copy()
    env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("RIFE_DUMP_DIR", "RIFE_FIX_ACCUMULATION_ROUNDING"):
        env.pop(key, None)
    prereg = dict(created_at=datetime.now(timezone.utc).isoformat(), width=1920, height=1080,
                   padded_hw=[1280, 2048], internal_hw=[320, 512], tier="fast", K=1,
                   alphas=[.25, .5, .75], warmup=4, rounds=args.rounds,
                   order="alternating forward and reverse model order, paired by trial index",
                   performance_metric="synchronous host complete call including one new Head and one query",
                   speed_screen="per-alpha lower bound of paired-bootstrap 95% mean saving must exceed zero",
                   formal_quality_accepted=False, quality_margin_authorized=None,
                   quality_probe="one analytic motion scene, engineering diagnostic only; no independent-video claim",
                   graphs=["rife-v4.25", *lr.GRAPHS], weights_sha256={str(p): lr.sha(p) for p in urls})
    prereg_path = args.output / "phase2-prereg.json"
    if prereg_path.exists():
        raise ValueError("use a new output directory or preserve the existing run; prereg already exists")
    write_json(prereg_path, prereg)
    relative = ["Sources/RifeMetalCore/IFBlockBuilder.swift", "Sources/RifeMetalCore/GraphHelpers.swift",
                "Sources/RifeMetalCore/IFNetGraph.swift", "Sources/RifeMetalCore/WeightStore.swift"]
    baseline_report = dict(product_commit=git(args.product_worktree, "rev-parse", "HEAD"),
                           product_branch=git(args.product_worktree, "branch", "--show-current"),
                           product_native_commit=git(args.product_native, "rev-parse", "HEAD"),
                           product_native_status=git(args.product_native, "status", "--porcelain"),
                           product_native_sha256={p: lr.sha(args.product_native / p) for p in relative},
                           lab_native_sha256={p: lr.sha(args.lab_native / p) for p in relative},
                           baseline_weights_sha256=lr.sha(baseline), baseline_mask="replace",
                           product_mask="accumulate (distinct reference, not used as the candidate teacher)",
                           product_dependency_resolution=json.loads((args.product_worktree / "Apps/Mac/OpenDuckFrame.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text()),
                           models={g: json.loads((args.output / "models" / (g + ".manifest.json")).read_text()) for g in lr.GRAPHS},
                           numpy=np.__version__, torch=torch.__version__, os=platform.platform(),
                           device_scope="this Apple silicon Mac only; no M1/Air performance claim",
                           simulation_enabled=False, load_average_before=os.getloadavg(),
                           native_bin_sha256=lr.sha(args.native_bin), benchmark_source_sha256=lr.sha(__file__))
    write_json(args.output / "baseline.json", baseline_report)

    def native(mode, models=urls, **extra):
        directory = args.output / mode
        directory.mkdir(exist_ok=True)
        config = dict(mode=mode, models=[str(p.resolve()) for p in models], output_dir=str(directory.resolve()),
                      warmup=prereg["warmup"], rounds=args.rounds, **extra)
        config_path = directory / "config.json"
        write_json(config_path, config)
        with (directory / "execution.log").open("w") as log:
            result = subprocess.run([str(args.native_bin.resolve()), str(config_path.resolve())], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"native {mode} failed ({result.returncode}); see {directory / 'execution.log'}")
        print(f"{mode} completed", flush=True)
        return json.loads((directory / (mode + ".json")).read_text())

    native("validate")
    # Validate the native reader, not merely the writer's own schema assertions.
    raw = urls[1].read_bytes()
    length = struct.unpack_from("<I", raw, 8)[0]
    header = json.loads(raw[12:12 + length])
    blob = raw[(12 + length + 15) // 16 * 16:]
    rejections = []
    with tempfile.TemporaryDirectory(prefix="schema-cases-", dir=args.output) as temporary:
        temp = Path(temporary)
        for name in ("unknown_graph", "wrong_shape", "wrong_mask", "missing_tensor", "trailing_payload"):
            h = copy.deepcopy(header)
            if name == "unknown_graph": h["graph_id"] = "unknown"
            if name == "wrong_shape": h["tensors"][110]["shape"] = [1]
            if name == "wrong_mask": h["mask_update"] = "accumulate"
            if name == "missing_tensor": h["tensors"].pop()
            encoded = json.dumps(h, sort_keys=True).encode()
            prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
            path = temp / (name + ".rmw")
            path.write_bytes(prefix + b"\0" * (-len(prefix) % 16) + blob + (b"x" if name == "trailing_payload" else b""))
            config = temp / "config.json"
            write_json(config, dict(mode="validate", models=[str(path)], output_dir=str(temp)))
            result = subprocess.run([str(args.native_bin.resolve()), str(config)], env=env, capture_output=True, text=True)
            rejections.append(dict(case=name, returncode=result.returncode, error=result.stderr.strip()))
            if result.returncode == 0: raise AssertionError(f"native reader accepted {name}")
    write_json(args.output / "native-schema-rejections.json", rejections)
    with args.gpu_lock.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        micro = native("micro")
        for label, time in (("first", 0), ("second", 1)):
            scene(1920, 1080, time).tofile(args.output / (label + ".bgra"))
        stream = native("stream", width=1920, height=1080, tier="fast", alphas=prereg["alphas"],
                        first=str(args.output / "first.bgra"), second=str(args.output / "second.bgra"))
        fcntl.flock(lock, fcntl.LOCK_UN)

    source_state = rmw.read_rmw(baseline).state_dict
    graph_states = [source_state]
    for g in lr.GRAPHS:
        checkpoint = torch.load(args.output / "models" / (g + ".pt"), map_location="cpu", weights_only=True)
        graph_states.append({n: t.half() for n, t in checkpoint["state_dict"].items()})
    numerical = []
    for row in micro["rows"]:
        index = [str(p) for p in urls].index(row["model_path"])
        state = graph_states[index]
        shape = tuple(row["shape_nhwc"])
        values = np.arange(math.prod(shape)) % 997
        x = (np.sin(values.astype(np.float32) * np.float32(.017)) * np.float32(.25)).astype(np.float16).astype(np.float32).reshape(shape)
        x = torch.from_numpy(x.transpose(0, 3, 1, 2).copy())
        for j in range(row["depth"]):
            p = f"block{row['stage']}.convblock.{j}."
            if index == 0:
                branch = F.conv2d(x, state[p + "conv.weight"].float(), state[p + "conv.bias"].float(), padding=1) * state[p + "beta"].float()
            else:
                branch = F.conv2d(F.conv2d(x, state[p + "conv_a.weight"].float(), padding=1),
                                  state[p + "conv_b.weight"].float(), state[p + "conv_b.bias"].float())
            x = F.leaky_relu(x + branch, .2)
        actual = np.fromfile(row["output_f16"], dtype="<f2").reshape(shape).astype(np.float32)
        numerical.append(dict(stage=row["stage"], depth=row["depth"], graph_id=row["graph_id"],
                              comparison="native FP16 vs CPU FP32 using the same FP16-quantized tensors",
                              errors=errors(actual, x.detach().numpy().transpose(0, 2, 3, 1))))
    quality, speed = [], []
    for alpha in prereg["alphas"]:
        rows = [r for r in stream["rows"] if r["alpha"] == alpha]
        frames = [np.fromfile(r["output_bgra"], dtype=np.uint8).reshape(1080, 1920, 4)[:, :, :3].astype(np.float32) / 255 for r in rows]
        gt = scene(1920, 1080, alpha)[:, :, :3].astype(np.float32) / 255
        quality.append(dict(alpha=alpha, baseline_vs_gt=errors(frames[0], gt), student_vs_gt=errors(frames[1], gt),
                            full_rank_vs_baseline=errors(frames[2], frames[0]), student_vs_baseline=errors(frames[1], frames[0])))
        speed.append(dict(alpha=alpha, baseline=stats(rows[0]["samples"]), student=stats(rows[1]["samples"]),
                          full_rank_diagnostic=stats(rows[2]["samples"]), **paired_speed(rows[0]["samples"], rows[1]["samples"])))
    summary = dict(baseline_commit=baseline_report["product_commit"], K=1, quality_accepted=False,
                   performance_screen_passed=all(r["timing_advantage_observed"] for r in speed),
                   speed=speed, analytic_scene_diagnostics=quality, native_reference_layer_diagnostics=numerical,
                   completed=["phase0 baseline identity", "phase1 graph/schema/factorization", "phase2 real-shape native screening"],
                   pending=["independent real-video quality and noninferiority", "training if native costs justify it",
                            "K2..4", "Rs", "product integration and presentation deadlines", "other Mac hardware"],
                   conclusion="Untrained candidate only. No product adoption or same-quality speed claim.")
    write_json(args.output / "summary.json", summary)
    print(json.dumps(dict(performance_screen_passed=summary["performance_screen_passed"], speed=speed), ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
