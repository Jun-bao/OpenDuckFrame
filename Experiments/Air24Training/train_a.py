"""One bounded crop feasibility run from the fixed four-stage training contract.

No native/cost/holdout acceptance is inferred here. The A checkpoint only tests
the pipeline and does not select a full-resolution B checkpoint.
"""
from __future__ import annotations

from collections import OrderedDict
from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import random
import signal
import sys
import time

import numpy as np
from PIL import Image
import torch
from torch.nn import functional as F

import model


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


class Stop(Exception):
    pass


class Images:
    """Bounded read-only CPU uint8 cache; no full-image copy on disk."""
    def __init__(self, capacity=16):
        self.capacity, self.values = capacity, OrderedDict()

    def get(self, path):
        if path not in self.values:
            with Image.open(path) as image:
                value = np.asarray(image.convert("RGB"), dtype=np.uint8).copy()
            self.values[path] = torch.from_numpy(value).permute(2, 0, 1)
            while len(self.values) > self.capacity:
                self.values.popitem(last=False)
        self.values.move_to_end(path)
        return self.values[path]


def batch(rows, images, rng, count, *, crop=512):
    values = [[], [], []]
    sample_ids = []
    for _ in range(count):
        row = rows[rng.randrange(len(rows))]
        y, x = rng.randrange(row["height"]-crop+1), rng.randrange(row["width"]-crop+1)
        horizontal, vertical, reverse = (bool(rng.randrange(2)) for _ in range(3))
        tensors = [images.get(row[k])[:, y:y+crop, x:x+crop] for k in ("first", "second", "gt")]
        dims = tuple(i for i, enabled in ((1, vertical), (2, horizontal)) if enabled)
        if dims:
            tensors = [value.flip(dims) for value in tensors]
        if reverse:
            tensors[0], tensors[1] = tensors[1], tensors[0]
        for target, value in zip(values, tensors):
            target.append(value)
        sample_ids.append(dict(id=row["id"], x=x, y=y, horizontal=horizontal, vertical=vertical, reverse=reverse))
    return tuple(torch.stack(value).float().div_(255) for value in values), sample_ids


def teacher_features(teacher, a, b):
    captured = {}

    def before(_module, inputs):
        captured["x"] = inputs[0].detach()
        captured["previous_flow"] = inputs[1].detach()
        captured["previous_mask"] = inputs[0][:, 15:16].detach()

    handle = teacher.block3.register_forward_pre_hook(before)
    try:
        with torch.no_grad():
            rgb, stages = model.forward(teacher, a, b)
            captured.update(target_rgb=rgb.detach(), target_flow=stages[4][0].detach(),
                            target_mask=stages[4][1].detach())
    finally:
        handle.remove()
    return captured


def student_output(student, ref, item, a, b):
    delta, new_mask, _unused_features = student.block3(item["x"], item["previous_flow"], 2)
    flow = item["previous_flow"] + delta
    mask = item["previous_mask"] + new_mask
    height, width = a.shape[-2:]
    padding = (0, -width % 256, 0, -height % 256)
    full0, full1 = (F.pad(value, padding, mode="replicate") for value in (a, b))
    full_flow = ref.resize(flow, size=full0.shape[-2:]) / 0.25
    alpha = torch.sigmoid(ref.resize(mask, size=full0.shape[-2:]))
    rgb = ref.warp(full0, full_flow[:, :2]) * alpha + ref.warp(full1, full_flow[:, 2:]) * (1-alpha)
    return rgb[:, :, :height, :width], flow, mask


def losses(output, flow, mask, gt, item):
    def charb(a, b):
        return ((a-b).square() + 1e-6).sqrt().mean()

    height, width = gt.shape[-2:]
    vh, vw = math.ceil(height * 0.25), math.ceil(width * 0.25)
    # Raw flow uses internal Fast-grid pixels. Convert to full-res pixels, then
    # divide by the unpadded full-image width as specified by the contract.
    flow_term = F.l1_loss(flow[..., :vh, :vw], item["target_flow"][..., :vh, :vw]) / (0.25 * width)
    mask_term = F.l1_loss(torch.sigmoid(mask[..., :vh, :vw]),
                          torch.sigmoid(item["target_mask"][..., :vh, :vw]))
    terms = dict(gt_charb=charb(output, gt), teacher_charb=charb(output, item["target_rgb"]),
                 normalized_full_flow_l1=flow_term, sigmoid_mask_l1=mask_term)
    total = terms["gt_charb"] + .25*terms["teacher_charb"] + .05*flow_term + .05*mask_term
    return total, terms


def run(config):
    torch.set_num_threads(4)
    torch.manual_seed(config["seed"])
    rng = random.Random(config["seed"])
    root = Path(config["output_dir"])
    root.mkdir(parents=True, exist_ok=False)
    cancelled = [False]
    previous = signal.signal(signal.SIGTERM, lambda *_: cancelled.__setitem__(0, True))
    marker = Path(config["cancel_file"])
    manifest = json.loads(Path(config["data_manifest"]).read_text())
    if len(manifest["training"]) != 36 or manifest["holdout_accessed"]:
        raise ValueError("unexpected training data")
    student, teacher, ref = model.create(config["source"], config["lab_root"])
    initial = model.state(student)
    images = Images(16)
    probe_cpu, probe_samples = batch(manifest["training"], images, random.Random(config["seed"]+1), 8)
    report = dict(status="starting", phase="A", pid=os.getpid(), started_utc=datetime.now(timezone.utc).isoformat(),
        config=config, config_sha256=model.sha(config["config_path"]), model_code_sha256=model.sha(model.__file__),
        trainer_sha256=model.sha(__file__), data_manifest_sha256=model.sha(config["data_manifest"]),
        source_sha256=model.sha(config["source"]), graph_id=model.GRAPH_ID, completed_steps=0,
        native_finite_gate="pending external native diagnostic", holdout_accessed=False,
        training_is_25_to_50_approximation=True, B_checkpoint_selection=False,
        loss="GT Charb+.25teacher Charb+.05normalized full-flow L1+.05sigmoid-mask L1",
        frozen_prefix_unchanged=True, outputs_finite=True, probe_samples=probe_samples)
    write(root/"config.json", config)
    write(root/"manifest.json", report)
    started = time.monotonic()

    def check():
        if cancelled[0] or marker.exists():
            raise Stop("cancelled")
        if time.monotonic()-started >= config["max_seconds"]:
            raise Stop("time_budget_exhausted")

    with Path(config["gpu_lock"]).open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            if not torch.backends.mps.is_available():
                raise ValueError("MPS unavailable")
            check()
            student.to("mps"); teacher.to("mps")
            optimizer = torch.optim.AdamW(student.block3.parameters(), lr=1e-4, weight_decay=0)
            probe = tuple(value.to("mps") for value in probe_cpu)
            fixed_features = teacher_features(teacher, *probe[:2])
            with torch.no_grad():
                output, flow, mask = student_output(student, ref, fixed_features, *probe[:2])
                first, _ = losses(output, flow, mask, probe[2], fixed_features)
                report["initial_fixed_probe_loss"] = float(first)
            report["initial_export"] = model.export(initial, config["lab_root"], root/"initial/student.rmw",
                                                     source_sha256=report["source_sha256"], trained=False)
            report["status"] = "training"
            write(root/"manifest.json", report)
            with (root/"steps.jsonl").open("x") as log:
                for step in range(config["max_steps"]):
                    check()
                    values, sample_ids = batch(manifest["training"], images, rng, 8)
                    check()
                    a, b, gt = (value.to("mps") for value in values)
                    item = teacher_features(teacher, a, b)
                    check()
                    optimizer.zero_grad(set_to_none=True)
                    output, flow, mask = student_output(student, ref, item, a, b)
                    total, terms = losses(output, flow, mask, gt, item)
                    if not torch.isfinite(total):
                        raise ValueError("nonfinite training loss")
                    total.backward()
                    norm = torch.nn.utils.clip_grad_norm_(student.block3.parameters(), 1., error_if_nonfinite=True)
                    warmup = min(1., (step+1)/100)
                    cosine = .5*(1+math.cos(math.pi*max(0,step+1-100)/max(1,config["max_steps"]-100)))
                    lr = 1e-4*warmup if step < 100 else 1e-6+(1e-4-1e-6)*cosine
                    for group in optimizer.param_groups:
                        group["lr"] = lr
                    check()
                    optimizer.step()
                    report["completed_steps"] = step+1
                    row = dict(step=step+1, elapsed_seconds=time.monotonic()-started, loss=float(total.detach()),
                               lr=lr, grad_norm=float(norm), samples=sample_ids,
                               **{name:float(value.detach()) for name,value in terms.items()})
                    log.write(json.dumps(row,allow_nan=False)+"\n");log.flush()
                    if (step+1)%10==0 or step==0:
                        write(root/"manifest.json",report)
                        print(json.dumps({k:v for k,v in row.items() if k!="samples"}),flush=True)
            with torch.no_grad():
                output, flow, mask = student_output(student, ref, fixed_features, *probe[:2])
                last,_ = losses(output,flow,mask,probe[2],fixed_features)
                report["final_fixed_probe_loss"] = float(last)
            report["fixed_probe_relative_loss_reduction"] = 1-report["final_fixed_probe_loss"]/report["initial_fixed_probe_loss"]
            report["A_loss_gate_passed"] = report["fixed_probe_relative_loss_reduction"] >= .2
            report["status"] = "A_loss_pass_native_pending" if report["A_loss_gate_passed"] else "A_loss_gate_failed_stop"
        except Stop as error:
            report["status"] = str(error)
        except Exception as error:
            report.update(status="failed",first_failure=f"{type(error).__name__}: {error}")
            raise
        finally:
            torch.mps.synchronize()
            last_state = model.state(student)
            report["frozen_prefix_unchanged"] = all(torch.equal(value,last_state[name]) for name,value in initial.items() if not name.startswith("block3."))
            report["source_unchanged"] = model.sha(config["source"]) == report["source_sha256"]
            report["last_export"] = model.export(last_state,config["lab_root"],root/"last/student.rmw",
                source_sha256=report["source_sha256"],trained=report["completed_steps"]>0,
                extra=dict(completed_steps=report["completed_steps"],phase="A",not_B_selection=True))
            report["elapsed_seconds"] = time.monotonic()-started
            write(root/"manifest.json",report)
            fcntl.flock(lock,fcntl.LOCK_UN)
            signal.signal(signal.SIGTERM,previous)
    print(json.dumps({k:v for k,v in report.items() if k not in ("initial_export","last_export","probe_samples","config")}),flush=True)
    return 0 if report["status"]=="A_loss_pass_native_pending" else 3


if __name__ == "__main__":
    config_path = Path(sys.argv[1]).resolve()
    config = json.loads(config_path.read_text())
    config["config_path"] = str(config_path)
    if config["max_steps"] != 200 or config["max_seconds"] != 900:
        raise ValueError("A contract is exactly200 steps or900 seconds, whichever first")
    raise SystemExit(run(config))
