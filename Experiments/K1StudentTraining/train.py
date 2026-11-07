"""Bounded accumulate-mask factor distillation on the fixed development split.

Usage: python3 -u -B train.py CONFIG.json
Modes initialize/train/evaluate share the real reference and explicit GPU lock.
Neither training nor importing this module changes the product package.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import math
from pathlib import Path
import random
import signal
import sys
import time

import torch
from torch.nn import functional as F

import data as dataset
import model


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


@contextmanager
def gpu_lock(path):
    with Path(path).open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def sync(device):
    if device == "mps":
        torch.mps.synchronize()


def state(net, *, quantized=False):
    return {name: (tensor.detach().cpu().half().float() if quantized else
                   tensor.detach().cpu().clone()) for name, tensor in net.state_dict().items()}


def checkpoint(path):
    value = torch.load(path, map_location="cpu", weights_only=True)
    if value["format"] != model.CHECKPOINT_FORMAT or value["mask_update"] != "accumulate":
        raise ValueError("expected this experiment's accumulate checkpoint")
    return value


def pair(row, device, dtype=torch.float32):
    return tuple(dataset.load_rgb(row[key]).to(device=device, dtype=dtype)
                 for key in ("first", "second"))


def psnr(mse):
    return -10 * math.log10(max(mse, 1e-20))


class TrainingStop(Exception):
    pass


def check_deadline(deadline, cancelled):
    if cancelled():
        raise TrainingStop("cancelled")
    if deadline is not None and time.monotonic() >= deadline:
        raise TrainingStop("time_budget_exhausted")


def loss_terms(output, stages, target, target_stages, tier):
    scale = {"fast": 0.25, "balanced": 0.5, "hq": 1.0}[tier]
    valid_h, valid_w = (math.ceil(size * scale) for size in output.shape[-2:])
    terms = {"rgb": F.l1_loss(output, target)}
    for stage in (3, 4):
        for name, index in (("flow", 0), ("mask", 1)):
            actual = stages[stage][index][..., :valid_h, :valid_w]
            expected = target_stages[stage][index][..., :valid_h, :valid_w]
            terms[f"{name}{stage}"] = F.l1_loss(actual, expected)
    return terms


def evaluate(net, teacher, rows, device, tier, *, deadline=None, cancelled=lambda: False):
    """Per-target development diagnostics; GT never enters the optimizer."""
    was_training = net.training
    net.eval()
    result = []
    with torch.no_grad():
        for row in rows:
            check_deadline(deadline, cancelled)
            a, b = pair(row, device)
            check_deadline(deadline, cancelled)
            target, target_stages = model.forward_with_stages(teacher, a, b, row["alpha"], tier)
            check_deadline(deadline, cancelled)
            output, stages = model.forward_with_stages(net, a, b, row["alpha"], tier)
            rgb_mse = float(F.mse_loss(output, target))
            item = dict(id=row["id"], clip=row["clip"], alpha=row["alpha"],
                        teacher_rgb_mse=rgb_mse, teacher_rgb_psnr_db=psnr(rgb_mse),
                        teacher_rgb_l1=float(F.l1_loss(output, target)))
            if "gt" in row:
                gt = dataset.load_rgb(row["gt"]).to(device=device)
                item.update(gt_psnr_db=psnr(float(F.mse_loss(output, gt))),
                            teacher_gt_psnr_db=psnr(float(F.mse_loss(target, gt))))
                item["gt_delta_to_teacher_db"] = item["gt_psnr_db"] - item["teacher_gt_psnr_db"]
            scale = {"fast": 0.25, "balanced": 0.5, "hq": 1.0}[tier]
            vh, vw = (math.ceil(size * scale) for size in output.shape[-2:])
            for stage in (3, 4):
                flow, mask = (tensor[..., :vh, :vw] for tensor in stages[stage][:2])
                target_flow, target_mask = (tensor[..., :vh, :vw] for tensor in target_stages[stage][:2])
                difference = (flow - target_flow).reshape(flow.shape[0], 2, 2, *flow.shape[-2:])
                item[f"stage{stage}_flow_epe_pixels"] = float(difference.square().sum(dim=2).sqrt().mean())
                item[f"stage{stage}_mask_l1"] = float(F.l1_loss(mask, target_mask))
            result.append(item)
    net.train(was_training)
    fields = [key for key in result[0] if key not in ("id", "clip", "alpha")]
    summary = dict(rows=result, means={key: sum(row[key] for row in result) / len(result) for key in fields},
                   scope="fixed development diagnostics; no holdout or quality acceptance")
    if "gt" in rows[0]:
        summary["worst_gt_delta_to_teacher_db"] = min(row["gt_delta_to_teacher_db"] for row in result)
    return summary


def initialize(config, manifest, output):
    source, lab = config["source"], config["lab_root"]
    source_sha = model.sha(source)
    initial, diagnostics = model.initialize(source, lab)
    # Native deployment starts with FP16 factors, not unrounded FP64 SVD values.
    initial = {name: tensor.half().float() for name, tensor in initial.items()}
    svd = model.export(initial, source_sha, output / "svd" / "student.rmw", False,
                       {"initialization": "kernel_svd_fp16", "diagnostics": diagnostics})
    teacher = model.teacher(source, lab, device=config["device"])
    generator = torch.Generator().manual_seed(config["seed"])
    sums, counts = {}, {}

    def collect(name):
        def hook(_module, inputs):
            patches = F.unfold(inputs[0].detach().cpu(), 3, padding=1)[0]
            indices = torch.randperm(patches.shape[1], generator=generator)[:config["patches_per_query"]]
            patches = patches[:, indices].double()
            sums[name] = sums.get(name, 0) + patches @ patches.T
            counts[name] = counts.get(name, 0) + patches.shape[1]
        return hook

    handles = [module.register_forward_pre_hook(collect(name))
               for name, module in teacher.named_modules()
               if name.startswith(("block3.convblock.", "block4.convblock."))
               and name.count(".") == 2]
    try:
        with torch.no_grad():
            for row in manifest["calibration_pairs"]:
                a, b = pair(row, config["device"])
                for alpha in (0.25, 0.5, 0.75):
                    teacher(a, b, timestep=alpha, tier=config["tier"])
                print(json.dumps({"calibrated": row["id"]}), flush=True)
    finally:
        for handle in handles:
            handle.remove()
    if len(sums) != 16:
        raise ValueError("calibration did not observe all sixteen residual branches")
    moments = {name: sums[name] / counts[name] for name in sums}
    torch.save(dict(second_moment=moments, counts=counts, mask_update="accumulate"), output / "moments.pt")
    calibrated, diagnostics = model.initialize(source, lab, moments)
    calibrated = {name: tensor.half().float() for name, tensor in calibrated.items()}
    response = model.export(calibrated, source_sha, output / "response" / "student.rmw", False,
                            {"initialization": "accumulate_response_weighted_svd_fp16", "diagnostics": diagnostics,
                             "data_manifest_sha256": model.sha(config["data_manifest"])})
    write_json(output / "report.json", dict(svd=svd, response=response, calibration_counts=counts,
        data_manifest_sha256=model.sha(config["data_manifest"]), trained=False,
        initialization_mask="accumulate", holdout_accessed=False))


def train(config, manifest, output):
    saved = checkpoint(config["initial_checkpoint"])
    source_sha = model.sha(config["source"])
    if saved["source_sha256"] != source_sha:
        raise ValueError("initial state is bound to different original weights")
    device, tier = config["device"], config["tier"]
    net = model.student(saved["state_dict"], config["lab_root"], device=device)
    teacher = model.teacher(config["source"], config["lab_root"], device=device)
    names = model.trainable_names(net)
    initial_state = state(net)
    parameters = [parameter for parameter in net.parameters() if parameter.requires_grad]
    optimizer = torch.optim.AdamW(parameters, lr=config["lr"], betas=(0.9, 0.999), weight_decay=0)
    rng = random.Random(config["seed"])
    record = dict(status="running", graph_id=model.GRAPH_ID, mask_update="accumulate",
        source_sha256=source_sha, initial_checkpoint_sha256=model.sha(config["initial_checkpoint"]),
        data_manifest_sha256=model.sha(config["data_manifest"]), config=config, trainable_names=names,
        trainable_parameter_count=sum(parameter.numel() for parameter in parameters),
        trained=False, completed_steps=0, holdout_accessed=False, quality_accepted=False,
        cost_accepted=False, started_utc=datetime.now(timezone.utc).isoformat(), evaluations=[],
        batch_execution="effective batch4; scalar-alpha reference uses four microbatches, averaging gradients before one AdamW update")
    write_json(output / "manifest.json", record)
    images = {path: dataset.load_rgb(path) for path in sorted({row[key] for row in manifest["train_pairs"] for key in ("first", "second")})}
    started = time.monotonic()
    deadline = started + config["max_seconds"]
    stopped = False

    def cancelled():
        return stopped

    def cancel(_signum, _frame):
        nonlocal stopped
        stopped = True

    old_term = signal.signal(signal.SIGTERM, cancel)
    old_int = signal.signal(signal.SIGINT, cancel)
    error = None
    best_score = math.inf
    best_weights = None
    stale_evaluations = regressions = 0
    try:
        # Claude's fixed loss normalizers: all48 train pairs, midpoint, no augment.
        net.eval()
        sums = {key: 0.0 for key in ("rgb", "flow3", "mask3", "flow4", "mask4")}
        with torch.no_grad():
            for row in manifest["train_pairs"]:
                check_deadline(deadline, cancelled)
                a, b = (images[row[key]].to(device=device) for key in ("first", "second"))
                check_deadline(deadline, cancelled)
                target, target_stages = model.forward_with_stages(teacher, a, b, 0.5, tier)
                check_deadline(deadline, cancelled)
                prediction, stages = model.forward_with_stages(net, a, b, 0.5, tier)
                for key, value in loss_terms(prediction, stages, target, target_stages, tier).items():
                    sums[key] += float(value)
        normalizers = {key: value / len(manifest["train_pairs"]) for key, value in sums.items()}
        if any(not math.isfinite(value) or value <= 0 for value in normalizers.values()):
            raise FloatingPointError("nonpositive/nonfinite initial loss normalizer")
        record["loss_normalizers"] = normalizers
        write_json(output / "loss-normalizers.json", normalizers)
        initial_evaluation = evaluate(net, teacher, manifest["distillation_evaluation"], device, tier,
                                      deadline=deadline, cancelled=cancelled)
        initial_evaluation.update(step=0, elapsed_seconds=time.monotonic() - started)
        record["evaluations"].append(initial_evaluation)
        write_json(output / "evaluation-000000.json", initial_evaluation)
        gt_initial = evaluate(net, teacher, manifest["evaluation"], device, tier,
                              deadline=deadline, cancelled=cancelled)
        write_json(output / "gt-init.json", gt_initial)
        initial_export = model.export(state(net), source_sha, output / "checkpoints" / "step-000000.rmw", False,
                                      {"step": 0, "data_manifest_sha256": record["data_manifest_sha256"]})
        best_score = initial_evaluation["means"]["teacher_rgb_l1"]
        initial_score = best_score
        best_weights = initial_export["checkpoint_path"]
        record.update(best_checkpoint=best_weights, best_step=0, best_teacher_rgb_l1=best_score)
        write_json(output / "manifest.json", record)
        print(json.dumps({"initial_D_rgb_l1": best_score, "normalizers": normalizers}), flush=True)
        net.train()
        with (output / "steps.jsonl").open("x") as log:
            for step in range(1, config["max_steps"] + 1):
                check_deadline(deadline, cancelled)
                optimizer.zero_grad(set_to_none=True)
                chosen = rng.sample(manifest["train_pairs"], config["batch_size"])
                aggregate = {key: 0.0 for key in ("loss", "rgb", "flow3", "mask3", "flow4", "mask4")}
                samples = []
                for sample_index, row in enumerate(chosen):
                    check_deadline(deadline, cancelled)
                    alpha = 0.5 if sample_index < config["batch_size"] // 2 else rng.uniform(0.05, 0.95)
                    a, b = (images[row[key]].to(device=device) for key in ("first", "second"))
                    flip, reverse = rng.random() < 0.5, rng.random() < 0.5
                    if flip:
                        a, b = a.flip(-1), b.flip(-1)
                    if reverse:
                        a, b, alpha = b, a, 1 - alpha
                    check_deadline(deadline, cancelled)
                    with torch.no_grad():
                        target, target_stages = model.forward_with_stages(teacher, a, b, alpha, tier)
                    check_deadline(deadline, cancelled)
                    prediction, stages = model.forward_with_stages(net, a, b, alpha, tier)
                    terms = loss_terms(prediction, stages, target, target_stages, tier)
                    loss = terms["rgb"] / normalizers["rgb"] + 0.25 * sum(
                        terms[key] / normalizers[key] for key in ("flow3", "mask3", "flow4", "mask4"))
                    if not torch.isfinite(loss):
                        raise FloatingPointError("nonfinite distillation loss")
                    (loss / config["batch_size"]).backward()
                    aggregate["loss"] += float(loss.detach()) / config["batch_size"]
                    for key, value in terms.items():
                        aggregate[key] += float(value.detach()) / config["batch_size"]
                    samples.append(dict(pair=row["id"], alpha=alpha, flip=flip, reverse=reverse))
                check_deadline(deadline, cancelled)
                grad_norm = torch.nn.utils.clip_grad_norm_(parameters, 1.0, error_if_nonfinite=True)
                if step <= config["warmup_steps"]:
                    lr = config["lr"] * step / config["warmup_steps"]
                else:
                    fraction = (step - config["warmup_steps"]) / (config["max_steps"] - config["warmup_steps"])
                    lr = config["min_lr"] + 0.5 * (config["lr"] - config["min_lr"]) * (1 + math.cos(math.pi * fraction))
                for group in optimizer.param_groups:
                    group["lr"] = lr
                check_deadline(deadline, cancelled)
                optimizer.step()
                record["completed_steps"] = step
                item = dict(step=step, samples=samples, grad_norm=float(grad_norm), lr=lr,
                            elapsed_seconds=time.monotonic() - started, **aggregate)
                log.write(json.dumps(item, allow_nan=False) + "\n")
                log.flush()
                if step % 25 == 0 or step == 1:
                    print(json.dumps(item), flush=True)
                if step % config["eval_interval"] == 0 or step == config["max_steps"]:
                    check_deadline(deadline, cancelled)
                    evaluation = evaluate(net, teacher, manifest["distillation_evaluation"], device, tier,
                                          deadline=deadline, cancelled=cancelled)
                    evaluation.update(step=step, elapsed_seconds=time.monotonic() - started)
                    record["evaluations"].append(evaluation)
                    write_json(output / f"evaluation-{step:06d}.json", evaluation)
                    exported = model.export(state(net), source_sha, output / "checkpoints" / f"step-{step:06d}.rmw", True,
                        {"step": step, "data_manifest_sha256": record["data_manifest_sha256"], "loss_normalizers": normalizers})
                    score = evaluation["means"]["teacher_rgb_l1"]
                    previous_best = best_score
                    if score < best_score:
                        best_score, best_weights = score, exported["checkpoint_path"]
                        record["best_step"] = step
                    stale_evaluations = 0 if score <= previous_best * 0.99 else stale_evaluations + 1
                    regressions = regressions + 1 if score > initial_score else 0
                    record.update(best_checkpoint=best_weights, best_teacher_rgb_l1=best_score,
                                  stale_evaluations=stale_evaluations, consecutive_regressions=regressions)
                    print(json.dumps({"evaluation_step": step, "D_rgb_l1": score,
                                      "stale_evaluations": stale_evaluations, "regressions": regressions}), flush=True)
                    write_json(output / "manifest.json", record)
                    if regressions >= 2:
                        raise TrainingStop("diagnostic_regression")
                    if stale_evaluations >= 3:
                        raise TrainingStop("no_improvement")
            record["status"] = "step_budget_exhausted"
    except TrainingStop as stop:
        record["status"] = str(stop)
    except Exception as caught:
        error = caught
        record.update(status="failed", error=repr(caught))
    finally:
        signal.signal(signal.SIGTERM, old_term)
        signal.signal(signal.SIGINT, old_int)
        record["elapsed_seconds"] = time.monotonic() - started
        sync(device)
        final_state = state(net)
        changed_frozen = [name for name in final_state if name not in names and not torch.equal(final_state[name], initial_state[name])]
        record.update(trained=record["completed_steps"] > 0,
                      frozen_tensor_changes=changed_frozen, best_checkpoint=best_weights)
        if changed_frozen:
            record.update(status="failed", error="frozen tensors changed")
        final = model.export(final_state, source_sha, output / "last.rmw", record["trained"],
                             {"step": record["completed_steps"], "run_status": record["status"]})
        record["last_weights"] = final
        record["source_unchanged"] = model.sha(config["source"]) == source_sha
        record["artifact_flush_seconds"] = time.monotonic() - started - record["elapsed_seconds"]
        write_json(output / "manifest.json", record)
        print(json.dumps({k: record.get(k) for k in ("status", "completed_steps", "trained", "elapsed_seconds", "best_checkpoint")}), flush=True)
    if error is not None:
        raise error


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: train.py CONFIG.json")
    config = json.loads(Path(sys.argv[1]).read_text())
    torch.set_num_threads(4)
    torch.manual_seed(config["seed"])
    if config["device"] == "mps" and not torch.backends.mps.is_available():
        config["requested_device"] = "mps"
        config["device"] = "cpu"
        print("MPS unavailable: using Claude's CPU float32 fallback with unchanged limits", flush=True)
    manifest = json.loads(Path(config["data_manifest"]).read_text())
    if manifest["train_clips"] != ["park_joy", "crowd_run", "ducks_take_off"]:
        raise ValueError("unexpected optimizer split")
    if config["mode"] == "train":
        for key in ("max_steps", "max_seconds", "eval_interval"):
            if not math.isfinite(config[key]) or config[key] <= 0:
                raise ValueError("explicit finite positive training limits required")
    output = Path(config["output_dir"])
    with gpu_lock(config["gpu_lock"]):
        output.mkdir(parents=True, exist_ok=False)
        write_json(output / "config.json", config)
        if config["mode"] == "initialize":
            initialize(config, manifest, output)
        elif config["mode"] == "train":
            train(config, manifest, output)
        elif config["mode"] == "evaluate":
            saved = checkpoint(config["checkpoint"])
            net = model.student(saved["state_dict"], config["lab_root"], device=config["device"])
            teacher = model.teacher(config["source"], config["lab_root"], device=config["device"])
            write_json(output / "evaluation.json", evaluate(net, teacher, manifest["evaluation"], config["device"], config["tier"]))
        else:
            raise ValueError("unknown experiment mode")


if __name__ == "__main__":
    main()
