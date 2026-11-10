"""Bounded B0: fixed-crop recovery reference and16 development GT diagnostics.

No optimizer, checkpoint selection, new training examples or independent holdout.
Teacher loss is a reference, not a mathematical lower bound.
"""
from __future__ import annotations

from datetime import datetime, timezone
import fcntl
import json
import math
from pathlib import Path
import statistics
import sys
import time

import torch
from torch.nn import functional as F

import data
import model
import train_a


def fixed_crops(rows, specifications, images):
    by_id={row["id"]:row for row in rows}
    values=[[],[],[]]
    for spec in specifications:
        row=by_id[spec["id"]];y,x=spec["y"],spec["x"]
        tensors=[images.get(row[key])[:,y:y+512,x:x+512] for key in ("first","second","gt")]
        dims=tuple(i for i,enabled in ((1,spec["vertical"]),(2,spec["horizontal"])) if enabled)
        if dims:tensors=[value.flip(dims) for value in tensors]
        if spec["reverse"]:tensors[0],tensors[1]=tensors[1],tensors[0]
        for output,value in zip(values,tensors):output.append(value)
    return tuple(torch.stack(value).float().div_(255) for value in values)


def clip_means(rows):
    clips=sorted({row["clip"] for row in rows})
    fields=("teacher_gt_psnr_db","initial_gt_psnr_db","A_last_gt_psnr_db")
    per_clip={clip:{field:statistics.fmean(row[field] for row in rows if row["clip"]==clip)
                    for field in fields} for clip in clips}
    return dict(per_clip=per_clip,clip_equal_means={field:statistics.fmean(per_clip[c][field] for c in clips)
                                                   for field in fields})


def psnr(a,b):
    return -10*math.log10(max(float(F.mse_loss(a,b)),1e-20))


def run(config):
    started=time.monotonic()
    root=Path(config["output_dir"]);root.mkdir(exist_ok=False)
    torch.set_num_threads(4)
    torch.manual_seed(config["seed"])
    manifest=json.loads(Path(config["data_manifest"]).read_text())
    A=json.loads(Path(config["A_manifest"]).read_text())
    original_path=Path(manifest["frozen_inventory"])
    if model.sha(original_path)!=data.FROZEN_SHA:raise ValueError("frozen inventory changed")
    original=json.loads(original_path.read_text())
    guard=[row for row in original["evaluation"] if row["alpha"]==.5]
    if len(guard)!=4 or len(manifest["development"])!=12 or len(A["probe_samples"])!=8:
        raise ValueError("B0 scope must be8 fixed crops plus12+4 development targets")
    initial,teacher,ref=model.create(config["source"],config["lab_root"])
    last,_,_=model.create(config["source"],config["lab_root"])
    checkpoint=torch.load(config["A_checkpoint"],map_location="cpu",weights_only=True)
    if checkpoint["graph_id"]!=model.GRAPH_ID or checkpoint["source_sha256"]!=model.BASE_SHA256:
        raise ValueError("A checkpoint identity differs")
    last.load_state_dict(checkpoint["state_dict"],strict=True)
    images=train_a.Images(16)
    probe=fixed_crops(manifest["training"],A["probe_samples"],images)
    report=dict(status="running",started_utc=datetime.now(timezone.utc).isoformat(),
                optimizer_created=False,training_steps=0,holdout_accessed=False,
                source_sha256=model.sha(config["source"]),config=config,
                config_sha256=model.sha(config["config_path"]),diagnostic_source_sha256=model.sha(__file__),
                trainer_loss_source_sha256=model.sha(train_a.__file__),
                data_manifest_sha256=model.sha(config["data_manifest"]),
                A_checkpoint_sha256=model.sha(config["A_checkpoint"]),
                teacher_reference_is_absolute_lower_bound=False)
    train_a.write(root/"report.json",report)
    def check():
        if time.monotonic()-started>=config["max_seconds"]:raise TimeoutError("B0 time budget exhausted")
        if Path(config["cancel_file"]).exists():raise RuntimeError("cancel marker present")
    with Path(config["gpu_lock"]).open("a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:
            for net in (initial,teacher,last):net.to("mps").eval()
            with torch.no_grad():
                check();a,b,gt=(value.to("mps") for value in probe)
                item=train_a.teacher_features(teacher,a,b)
                teacher_loss,teacher_terms=train_a.losses(item["target_rgb"],item["target_flow"],item["target_mask"],gt,item)
                losses={"teacher_reference":float(teacher_loss)}
                for name,net in (("initial",initial),("A_last",last)):
                    output,flow,mask=train_a.student_output(net,ref,item,a,b)
                    loss,_=train_a.losses(output,flow,mask,gt,item)
                    losses[name]=float(loss)
                denominator=losses["initial"]-losses["teacher_reference"]
                recovery=(losses["initial"]-losses["A_last"])/denominator if denominator>0 else None
                report["fixed_crop"]=dict(losses=losses,teacher_reference_terms={k:float(v) for k,v in teacher_terms.items()},
                    denominator=denominator,recovery_fraction=recovery,
                    recovery_defined=denominator>0,recovery_undefined_reason=None if denominator>0 else "initial<=teacher_reference",
                    A_initial_loss_reproduction_delta=losses["initial"]-A["initial_fixed_probe_loss"],
                    A_final_loss_reproduction_delta=losses["A_last"]-A["final_fixed_probe_loss"],
                    specs=A["probe_samples"])
                train_a.write(root/"report.json",report)
                print(json.dumps({"fixed_crop":{k:v for k,v in report["fixed_crop"].items() if k!="specs"}}),flush=True)
                del a,b,gt,item,output,flow,mask
                groups={}
                for label,rows in (("40ms",manifest["development"]),("80ms",guard)):
                    result=[]
                    for row in rows:
                        check()
                        a,b,gt=(images.get(row[k]).unsqueeze(0).to(device="mps",dtype=torch.float32)/255 for k in ("first","second","gt"))
                        teacher_rgb,_=model.forward(teacher,a,b)
                        initial_rgb,_=model.forward(initial,a,b)
                        last_rgb,_=model.forward(last,a,b)
                        result.append(dict(id=row["id"],clip=row["clip"],teacher_gt_psnr_db=psnr(teacher_rgb,gt),
                                           initial_gt_psnr_db=psnr(initial_rgb,gt),A_last_gt_psnr_db=psnr(last_rgb,gt)))
                        print(json.dumps(dict(group=label,**result[-1])),flush=True)
                    groups[label]=dict(rows=result,**clip_means(result))
                report["development"]=groups
                m40=groups["40ms"]["clip_equal_means"];m80=groups["80ms"]["clip_equal_means"]
                gap=m40["teacher_gt_psnr_db"]-m40["initial_gt_psnr_db"]
                guard_ok=m80["initial_gt_psnr_db"]>=m80["teacher_gt_psnr_db"]
                noB=gap<=.1 and guard_ok
                branch="untrained_candidate_no_B_needed" if noB else "B_from_original_block3" if recovery is not None and recovery>=.5 else "stop_training_keep_structural_candidate"
                report["decision"]=dict(teacher_minus_initial_40ms_db=gap,
                    initial_minus_teacher_80ms_db=m80["initial_gt_psnr_db"]-m80["teacher_gt_psnr_db"],
                    untrained_40ms_within0_1dB_signed_gap=gap<=.1,untrained_80ms_not_worse=guard_ok,
                    A_recovery_fraction=recovery,A_recovery_ge50pct=recovery is not None and recovery>=.5,
                    branch=branch,new_training_started=False)
                report["status"]="completed"
        except Exception as error:
            report.update(status="failed",first_failure=f"{type(error).__name__}: {error}")
            raise
        finally:
            torch.mps.synchronize()
            report["elapsed_seconds"]=time.monotonic()-started
            train_a.write(root/"report.json",report)
            fcntl.flock(lock,fcntl.LOCK_UN)
    print(json.dumps(report["decision"]),flush=True)


if __name__=="__main__":
    p=Path(sys.argv[1]).resolve();config=json.loads(p.read_text());config["config_path"]=str(p)
    run(config)
