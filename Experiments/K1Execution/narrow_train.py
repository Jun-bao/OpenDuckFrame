"""Finite block4 training from real frozen-prefix teacher inputs.

`cache` uses CPU only. `train` requires a passing native cost-screen JSON,
explicit step/time budgets and an exclusive project GPU lock. It first distils
local flow/mask, then optimizes full-resolution ground-truth RGB with auxiliary
teacher losses. Diagnostic clips never enter the optimizer. No training is
started by importing this module or by showing CLI help.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
from pathlib import Path
import random
import signal
import sys
import time

import torch
from torch.nn import functional as F

import narrow


CACHE_FORMAT = "odf-ifnet425-block4-cache-v1"


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def rgb8(rgb):
    # These values originated in eight-bit PNGs; preserve them without half rounding.
    return rgb.mul(255).round().to(torch.uint8)


def rgb_float(rgb, device):
    return rgb.to(device=device, dtype=torch.float32).div(255)


def capture_teacher(teacher, first, second, gt, alpha):
    captured = {}

    def before(_module, inputs):
        x, flow, scale = inputs
        if x.shape[1] != 24 or flow.shape[1] != 4 or scale != 1:
            raise narrow.NarrowError("unexpected real block4 input contract")
        captured.update(x=x.detach().cpu(), prev_flow=flow.detach().cpu())

    def after(_module, _inputs, outputs):
        delta, mask, _feat = outputs
        captured.update(target_delta=delta.detach().cpu(), target_new_mask=mask.detach().cpu())

    def trace(stage, flow, mask, _feat):
        if stage == 3:
            captured.update(prev_mask=mask.detach().cpu(), traced_prev_flow=flow.detach().cpu())

    handles = [teacher.block4.register_forward_pre_hook(before), teacher.block4.register_forward_hook(after)]
    try:
        # Cached tensors will become autograd inputs/targets for block4 later.
        # no_grad keeps ordinary tensors, unlike inference_mode's tensor flag.
        with torch.no_grad():
            target = teacher(first, second, tier="fast", timestep=alpha,
                             mask_update="accumulate", trace=trace)
    finally:
        for handle in handles:
            handle.remove()
    if (not torch.equal(captured["x"][:, 15:16], captured["prev_mask"])
            or not torch.equal(captured.pop("traced_prev_flow"), captured["prev_flow"])):
        raise narrow.NarrowError("cached input does not match teacher's actual preceding state")
    captured.update(first_rgb8=rgb8(first), second_rgb8=rgb8(second), gt_rgb8=rgb8(gt),
                    teacher_rgb=target.detach().cpu(), alpha=alpha)
    return captured


def build_cache(args):
    torch.set_num_threads(4)
    digest = narrow.sha(args.source)
    if digest != args.expected_source_sha256:
        raise narrow.NarrowError("teacher SHA256 does not match authorized source")
    _rmw, ifnet = narrow.load_lab(args.lab_root)
    teacher = ifnet.IFNetStudent.from_rmw(args.source, device="cpu", dtype=torch.float32)
    if teacher.model_identity != "rife-v4.25":
        raise narrow.NarrowError("cache teacher must be the original rife-v4.25")
    samples = narrow.windows(args.data_manifest, narrow.TRAIN_CLIPS + narrow.DIAGNOSTIC_CLIPS, tuple(args.blocks))
    args.output_dir.mkdir(parents=True, exist_ok=False)
    manifest = dict(format=CACHE_FORMAT, source_sha256=digest,
                    data_manifest_sha256=narrow.sha(args.data_manifest), tier="fast",
                    mask_update="accumulate", train_clips=list(narrow.TRAIN_CLIPS),
                    diagnostic_clips=list(narrow.DIAGNOSTIC_CLIPS), blocks=args.blocks,
                    alphas=[0.25, 0.5, 0.75], entries=[], status="running",
                    sources={n: narrow.sha(args.lab_root / n) for n in ("ifnet.py", "rmw.py")})
    started = time.monotonic()
    try:
        for sample in samples:
            first, second = (narrow.load_rgb(sample["frames"][i]) for i in (0, 4))
            frame_hashes = [narrow.sha(p) for p in sample["frames"]]
            for frame_index, alpha in enumerate((0.25, 0.5, 0.75), start=1):
                gt = narrow.load_rgb(sample["frames"][frame_index])
                captured = capture_teacher(teacher, first, second, gt, alpha)
                name = f"{sample['id']}-a{frame_index}.pt"
                split = "train" if sample["clip"] in narrow.TRAIN_CLIPS else "diagnostic"
                item = dict(id=f"{sample['id']}-a{frame_index}", clip=sample["clip"],
                            block=sample["block"], alpha=alpha, split=split, file=name,
                            source_frame_indices=sample["source_frame_indices"], frame_sha256=frame_hashes)
                torch.save(dict(format=CACHE_FORMAT, source_sha256=digest,
                                metadata=item, **captured), args.output_dir / name)
                item["sha256"] = narrow.sha(args.output_dir / name)
                manifest["entries"].append(item)
            print(json.dumps(dict(cached=sample["id"], entries=len(manifest["entries"]))), flush=True)
        manifest["status"] = "complete"
    except KeyboardInterrupt:
        manifest["status"] = "cancelled"
        raise
    except Exception as error:
        manifest.update(status="failed", error=str(error))
        raise
    finally:
        manifest["elapsed_seconds"] = time.monotonic() - started
        write_json(args.output_dir / "manifest.json", manifest)
    return 0


def validate_cache(cache_dir, source_sha):
    if "pilot-p01" in cache_dir.resolve().parts:
        raise narrow.NarrowError("reserved pilot-p01 data is outside training")
    manifest = json.loads((cache_dir / "manifest.json").read_text())
    if (manifest.get("format") != CACHE_FORMAT or manifest.get("status") != "complete"
            or manifest.get("source_sha256") != source_sha or manifest.get("tier") != "fast"
            or manifest.get("mask_update") != "accumulate"):
        raise narrow.NarrowError("cache is incomplete or uses a different teacher/tier/mask")
    groups = {"train": [], "diagnostic": []}
    ids = set()
    for row in manifest["entries"]:
        expected_split = ("train" if row["clip"] in narrow.TRAIN_CLIPS else
                          "diagnostic" if row["clip"] in narrow.DIAGNOSTIC_CLIPS else None)
        if expected_split is None or row["split"] != expected_split or row["id"] in ids:
            raise narrow.NarrowError("invalid or duplicate development split entry")
        if Path(row["file"]).name != row["file"] or row["alpha"] not in (0.25, 0.5, 0.75):
            raise narrow.NarrowError("invalid cache file/alpha")
        ids.add(row["id"])
        path = (cache_dir / row["file"]).resolve()
        if path.parent != cache_dir.resolve() or narrow.sha(path) != row["sha256"]:
            raise narrow.NarrowError("cache artifact path/hash mismatch")
        groups[expected_split].append(row)
    if (set(r["clip"] for r in groups["train"]) != set(narrow.TRAIN_CLIPS)
            or set(r["clip"] for r in groups["diagnostic"]) != set(narrow.DIAGNOSTIC_CLIPS)):
        raise narrow.NarrowError("expected all three train clips and both diagnostic clips")
    return manifest, groups


def load_cache_item(cache_dir, row, source_sha):
    value = torch.load(cache_dir / row["file"], map_location="cpu", weights_only=True)
    expected_metadata = {k: v for k, v in row.items() if k != "sha256"}
    if (value.get("format") != CACHE_FORMAT or value.get("source_sha256") != source_sha
            or value.get("metadata") != expected_metadata):
        raise narrow.NarrowError("cache payload metadata mismatch")
    x = value["x"]
    height, width = x.shape[-2:]
    expected = {"x": (1, 24, height, width), "prev_flow": (1, 4, height, width),
                "prev_mask": (1, 1, height, width), "target_delta": (1, 4, height, width),
                "target_new_mask": (1, 1, height, width)}
    rgb_shape = value["first_rgb8"].shape
    if len(rgb_shape) != 4 or rgb_shape[:2] != (1, 3):
        raise narrow.NarrowError("invalid cached full-resolution RGB shape")
    expected.update({n: tuple(rgb_shape) for n in ("first_rgb8", "second_rgb8", "gt_rgb8", "teacher_rgb")})
    for name, shape in expected.items():
        tensor = value[name]
        dtype = torch.uint8 if name.endswith("rgb8") else torch.float32
        if not isinstance(tensor, torch.Tensor) or tuple(tensor.shape) != shape or tensor.dtype != dtype:
            raise narrow.NarrowError(f"invalid cached tensor: {name}")
        if tensor.is_floating_point() and not torch.isfinite(tensor).all():
            raise narrow.NarrowError(f"nonfinite cached tensor: {name}")
    padded_h, padded_w = ((int(d) + 255) // 256 * 256 for d in rgb_shape[-2:])
    if (height, width) != (padded_h // 4, padded_w // 4) or not torch.equal(x[:, 15:16], value["prev_mask"]):
        raise narrow.NarrowError("cache is not a real Fast-tier block4 state")
    return value


def to_device(item, device, *, rgb):
    names = ("x", "prev_flow", "prev_mask", "target_delta", "target_new_mask")
    value = {n: item[n].to(device=device) for n in names}
    if rgb:
        value.update({n.removesuffix("8"): rgb_float(item[n], device)
                      for n in ("first_rgb8", "second_rgb8", "gt_rgb8")})
        value["teacher_rgb"] = item["teacher_rgb"].to(device=device)
    return value


def local_outputs(block, item):
    delta, new_mask, _feat = block(item["x"], item["prev_flow"], 1)
    flow_loss = F.smooth_l1_loss(delta, item["target_delta"])
    mask_loss = F.smooth_l1_loss(new_mask, item["target_new_mask"])
    return delta, new_mask, flow_loss, mask_loss


def render(ifnet, item, delta, new_mask):
    first, second = item["first_rgb"], item["second_rgb"]
    height, width = first.shape[-2:]
    padding = (0, -width % 256, 0, -height % 256)
    full0, full1 = (F.pad(x, padding, mode="replicate") for x in (first, second))
    flow = ifnet.resize(item["prev_flow"] + delta, size=full0.shape[-2:]) / 0.25
    mask = ifnet.resize(item["prev_mask"] + new_mask, size=full0.shape[-2:])
    alpha = torch.sigmoid(mask)
    output = ifnet.warp(full0, flow[:, :2]) * alpha + ifnet.warp(full1, flow[:, 2:]) * (1 - alpha)
    return output[:, :, :height, :width]


def psnr(first, second):
    return -10 * math.log10(max(float(F.mse_loss(first, second)), 1e-12))


def diagnose(net, ifnet, cache_dir, rows, source_sha, device):
    result = []
    with torch.inference_mode():
        for row in rows:
            item = to_device(load_cache_item(cache_dir, row, source_sha), device, rgb=True)
            delta, mask, flow_loss, mask_loss = local_outputs(net.block4, item)
            output = render(ifnet, item, delta, mask)
            result.append(dict(id=row["id"], clip=row["clip"], alpha=row["alpha"],
                               flow_smooth_l1=float(flow_loss), mask_smooth_l1=float(mask_loss),
                               student_gt_psnr=psnr(output, item["gt_rgb"]),
                               teacher_gt_psnr=psnr(item["teacher_rgb"], item["gt_rgb"]),
                               student_teacher_rgb_l1=float(F.l1_loss(output, item["teacher_rgb"]))))
    return result


@contextmanager
def project_lock(path):
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise narrow.NarrowError("project GPU lock is held; training did not start") from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def validate_cost_screen(path, graph, initial_sha):
    result = json.loads(path.read_text())
    if (result.get("cost_screen_passed") is not True or result.get("graph_id") != graph
            or result.get("weights_sha256") != initial_sha):
        raise narrow.NarrowError("native cost screen must pass for this exact graph and initial weights")
    return narrow.sha(path)


def train(args):
    if (args.distill_steps < 1 or args.rgb_steps < 1 or not math.isfinite(args.max_seconds)
            or args.max_seconds <= 0 or not math.isfinite(args.lr) or args.lr <= 0):
        raise narrow.NarrowError("both phases need explicit positive finite step/time/lr budgets")
    torch.set_num_threads(4)
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    source_sha = narrow.sha(args.source)
    _rmw, ifnet = narrow.load_lab(args.lab_root)
    source = _rmw.read_rmw(args.source)
    if args.initial.suffix == ".pt":
        initial, initial_source = narrow.load_checkpoint(args.initial)
        if initial_source != source_sha:
            raise narrow.NarrowError("initial checkpoint was made from different original weights")
    else:
        initial = narrow.read_rmw(args.initial)
    prefix = narrow.unchanged_prefix(source, initial.state_dict)
    initial_rmw_sha = hashlib.sha256(narrow.dumps_rmw(initial.graph_id, initial.state_dict)).hexdigest()
    cost_sha = validate_cost_screen(args.cost_screen, initial.graph_id, initial_rmw_sha)
    cache_manifest, groups = validate_cache(args.cache_dir, source_sha)
    if args.device == "mps" and not torch.backends.mps.is_available():
        raise narrow.NarrowError("MPS is unavailable; training did not start")
    net = narrow.reference(ifnet, initial.graph_id, initial.state_dict)
    net.requires_grad_(False)
    net.block4.requires_grad_(True)
    trainable = [n for n, p in net.named_parameters() if p.requires_grad]
    if any(not n.startswith("block4.") for n in trainable):
        raise narrow.NarrowError("a frozen-prefix parameter is trainable")
    device = torch.device(args.device)
    # Acquire before creating MPS tensors or optimizer state. CPU smoke runs use
    # the same contract so a dry run cannot be mistaken for approved training.
    with project_lock(args.gpu_lock):
        args.output_dir.mkdir(parents=True, exist_ok=False)
        net.to(device=device, dtype=torch.float32)
        optimizer = torch.optim.Adam(net.block4.parameters(), lr=args.lr)
        report = dict(graph_id=initial.graph_id, source_sha256=source_sha,
                      initial_weights_sha256=initial_rmw_sha, cost_screen_sha256=cost_sha,
                      cache_manifest_sha256=narrow.sha(args.cache_dir / "manifest.json"),
                      mask_update="accumulate", tier="fast", device=args.device,
                      distill_steps=args.distill_steps, rgb_steps=args.rgb_steps,
                      max_seconds=args.max_seconds, seed=args.seed, lr=args.lr,
                      train_clips=list(narrow.TRAIN_CLIPS), diagnostic_clips=list(narrow.DIAGNOSTIC_CLIPS),
                      training_samples=len(groups["train"]), diagnostic_samples=len(groups["diagnostic"]),
                      trainable_parameters=trainable, unchanged_prefix_initial=prefix,
                      loss="local: flow SmoothL1 + 0.1*mask SmoothL1; RGB: GT L1 + 0.1*teacher RGB L1 + 0.01*local",
                      quality_accepted=False, native_quality_accepted=False, status="running", completed_steps=0,
                      sources=cache_manifest["sources"], trainer_sha256=narrow.sha(__file__))
        history = args.output_dir / "steps.jsonl"
        started = time.monotonic()
        old_term = signal.signal(signal.SIGTERM, lambda _s, _f: (_ for _ in ()).throw(KeyboardInterrupt()))
        error = None
        try:
            report["initial_diagnostic"] = diagnose(net, ifnet, args.cache_dir, groups["diagnostic"], source_sha, device)
            # Retain only training examples in this optimizer-side cache.
            items = {r["id"]: load_cache_item(args.cache_dir, r, source_sha) for r in groups["train"]}
            schedule = []
            with history.open("x") as log:
                for phase, steps in (("local_distill", args.distill_steps), ("rgb", args.rgb_steps)):
                    for step in range(steps):
                        if time.monotonic() - started >= args.max_seconds:
                            report["status"] = "time_budget_exhausted"
                            break
                        if not schedule:
                            schedule = list(groups["train"])
                            random.shuffle(schedule)
                        row = schedule.pop()
                        item = to_device(items[row["id"]], device, rgb=phase == "rgb")
                        optimizer.zero_grad(set_to_none=True)
                        delta, mask, flow_loss, mask_loss = local_outputs(net.block4, item)
                        local = flow_loss + 0.1 * mask_loss
                        metrics = dict(flow_smooth_l1=float(flow_loss.detach()), mask_smooth_l1=float(mask_loss.detach()))
                        if phase == "rgb":
                            output = render(ifnet, item, delta, mask)
                            gt_loss = F.l1_loss(output, item["gt_rgb"])
                            teacher_loss = F.l1_loss(output, item["teacher_rgb"])
                            loss = gt_loss + 0.1 * teacher_loss + 0.01 * local
                            metrics.update(gt_rgb_l1=float(gt_loss.detach()), teacher_rgb_l1=float(teacher_loss.detach()))
                        else:
                            loss = local
                        if not torch.isfinite(loss):
                            raise narrow.NarrowError("nonfinite training loss")
                        loss.backward()
                        torch.nn.utils.clip_grad_norm_(net.block4.parameters(), 1.0, error_if_nonfinite=True)
                        optimizer.step()
                        report["completed_steps"] += 1
                        record = dict(phase=phase, phase_step=step + 1, step=report["completed_steps"],
                                      sample=row["id"], loss=float(loss.detach()),
                                      elapsed_seconds=time.monotonic() - started, **metrics)
                        log.write(json.dumps(record, allow_nan=False) + "\n")
                        log.flush()
                        if (step + 1) % 10 == 0 or step + 1 == steps:
                            print(json.dumps(record), flush=True)
                    if report["status"] == "time_budget_exhausted":
                        break
            if report["status"] == "running":
                report["status"] = "completed"
            if report["status"] == "completed":
                report["final_diagnostic"] = diagnose(net, ifnet, args.cache_dir, groups["diagnostic"], source_sha, device)
        except KeyboardInterrupt:
            report["status"] = "cancelled"
        except Exception as caught:
            report.update(status="failed", error=str(caught))
            error = caught
        finally:
            signal.signal(signal.SIGTERM, old_term)
            if args.device == "mps":
                torch.mps.synchronize()
            state = {n: t.detach().cpu().half() for n, t in net.state_dict().items()}
            report["unchanged_prefix_final"] = narrow.unchanged_prefix(source, state)
            report["trained"] = report["completed_steps"] > 0
            report["elapsed_seconds"] = time.monotonic() - started
            output = args.output_dir / (initial.graph_id + ".rmw")
            narrow.export_rmw(initial.graph_id, state, output)
            narrow.save_checkpoint(output.with_suffix(".pt"), initial.graph_id, state, source_sha256=source_sha)
            report.update(weights_sha256=narrow.sha(output), checkpoint_sha256=narrow.sha(output.with_suffix(".pt")))
            write_json(args.output_dir / "manifest.json", report)
        print(json.dumps({k: v for k, v in report.items() if k not in ("initial_diagnostic", "final_diagnostic", "trainable_parameters")}), flush=True)
        if error is not None:
            raise error
        return 0 if report["status"] == "completed" else 130 if report["status"] == "cancelled" else 3


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    cache = sub.add_parser("cache", help="CPU4 real teacher states; no optimizer/GPU")
    cache.add_argument("--lab-root", type=Path, required=True)
    cache.add_argument("--source", type=Path, required=True)
    cache.add_argument("--expected-source-sha256", required=True)
    cache.add_argument("--data-manifest", type=Path, required=True)
    cache.add_argument("--output-dir", type=Path, required=True)
    cache.add_argument("--blocks", nargs="+", type=int, choices=range(4), default=[0, 2])
    fit = sub.add_parser("train", help="explicitly execute finite two-phase block4 training")
    for name in ("lab-root", "source", "initial", "cache-dir", "output-dir", "gpu-lock", "cost-screen"):
        fit.add_argument("--" + name, type=Path, required=True)
    fit.add_argument("--device", choices=("mps", "cpu"), default="mps")
    fit.add_argument("--distill-steps", type=int, required=True)
    fit.add_argument("--rgb-steps", type=int, required=True)
    fit.add_argument("--max-seconds", type=float, required=True)
    fit.add_argument("--lr", type=float, default=1e-4)
    fit.add_argument("--seed", type=int, default=0)
    args = ap.parse_args(argv)
    return build_cache(args) if args.command == "cache" else train(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, narrow.NarrowError) as error:
        print(f"narrow-train: {error}", file=sys.stderr)
        raise SystemExit(2)
