"""One development-only native FP16 alignment, with uninstrumented hash control.

The actual128-tensor export is reloaded into the FP32 reference. The private
state-dump binary is never used for cost. No optimizer or holdout is opened.
"""
from __future__ import annotations

from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

import numpy as np
import torch
from torch.nn import functional as F

import data
import model
import train_a


def run(config):
    started=time.monotonic()
    root=Path(config["output_dir"]);root.mkdir(exist_ok=False)
    deadline=datetime.fromisoformat(config["deadline_utc"]).timestamp()
    def check():
        if time.time()>=deadline:raise TimeoutError("B0/native combined20minute budget exhausted")
        if Path(config["cancel_file"]).exists():raise RuntimeError("cancel marker present")
    torch.set_num_threads(4)
    manifest=json.loads(Path(config["data_manifest"]).read_text())
    if model.sha(manifest["frozen_inventory"])!=data.FROZEN_SHA:raise ValueError("frozen inventory changed")
    old=json.loads(Path(manifest["frozen_inventory"]).read_text())
    rows=[dict(row,diagnostic_group="40ms") for row in manifest["development"]]
    rows += [dict(row,diagnostic_group="80ms") for row in old["evaluation"] if row["alpha"]==.5]
    if len(rows)!=16:raise ValueError("expected12+4 development rows")
    images=train_a.Images(16);inputs=root/"inputs";inputs.mkdir()
    bindings={};cases=[]
    for row in rows:
        check();paths=[]
        for key in ("first","second"):
            path=row[key]
            if path not in bindings:
                if model.sha(path)!=manifest["images"][path]:raise ValueError("source PNG hash changed")
                rgb=images.get(path).permute(1,2,0).numpy()
                bgra=np.concatenate((rgb[:,:,::-1],np.full((*rgb.shape[:2],1),255,dtype=np.uint8)),axis=2)
                target=inputs/f"{row['clip']}-{Path(path).stem}.bgra";target.write_bytes(bgra.tobytes())
                bindings[path]=dict(path=str(target),sha256=model.sha(target),source_sha256=manifest["images"][path])
            paths.append(bindings[path]["path"])
        cases.append(dict(id=row["id"],first=paths[0],second=paths[1]))
    candidate_state=model.read_export(config["model"],config["lab_root"])
    reference,_,_=model.create(config["source"],config["lab_root"])
    reference.load_state_dict(candidate_state,strict=True)
    binding=model.export(candidate_state,config["lab_root"],root/"torch-binding/student.rmw",
                         source_sha256=model.BASE_SHA256,trained=False)
    if binding["weights_sha256"]!=model.sha(config["model"]):raise ValueError("FP16 payload roundtrip differs")
    report=dict(status="prepared",started_utc=datetime.now(timezone.utc).isoformat(),
                scope="16development numerical queries only; not quality/cost/holdout acceptance",
                optimizer_created=False,holdout_accessed=False,config=config,
                config_sha256=model.sha(config["config_path"]),runner_sha256=model.sha(__file__),
                model_sha256=model.sha(config["model"]),source_sha256=model.sha(config["source"]),
                exact_FP16_payload_reloaded_and_roundtrip_SHA_equal=True,inputs=bindings,
                uninstrumented_binary_sha256=model.sha(config["native_binary"]),
                state_probe_binary_sha256=model.sha(config["probe_binary"]),
                probe_source_origin_sha256=model.sha(config["probe_source_origin"]),
                cost_binary_sha256_before=model.sha(config["immutable_cost_binary"]),rows=[])
    train_a.write(root/"report.json",report)
    base=dict(mode="quality",width=1920,height=1080,tier="fast",app_entrypoints=True,
              save_outputs=True,target_sets=[[.5]],cases=cases,
              variants=[dict(id="initial",model=config["model"],gpu_input_padding=True,direct_crop=True,
                             fused_warp=False,trim_final_features=False,defer_commits=False)])
    env=dict(os.environ,ODF_PERF_PROFILE="off",ODF_K1_PROFILE="0",RIFE_VERBOSE="0")
    env.pop("RIFE_DUMP_DIR",None);env.pop("ODF_STUDENT_STATE_DUMP_DIR",None)
    with Path(config["gpu_lock"]).open("a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:
            for label,binary in (("uninstrumented",config["native_binary"]),("state-probe",config["probe_binary"])):
                check();out=root/label
                native=dict(base,output_dir=str(out));config_path=root/f"{label}-config.json"
                train_a.write(config_path,native)
                child_env=dict(env)
                if label=="state-probe":child_env["ODF_STUDENT_STATE_DUMP_DIR"]=str(root/"states")
                with (root/f"{label}.stdout.log").open("w") as stdout,(root/f"{label}.stderr.log").open("w") as stderr:
                    process=subprocess.run([binary,str(config_path)],env=child_env,stdout=stdout,stderr=stderr,
                        timeout=min(180,max(1,deadline-time.time())))
                report[f"{label}_returncode"]=process.returncode
                train_a.write(root/"report.json",report)
                if process.returncode:raise RuntimeError(f"{label} process failed; preserved stdout/stderr")
            raw=json.loads((root/"uninstrumented/quality.json").read_text())
            dump=json.loads((root/"state-probe/quality.json").read_text())
            native={row["case_id"]:row for row in raw["rows"]};instrumented={row["case_id"]:row for row in dump["rows"]}
            if len(native)!=16 or len(instrumented)!=16:raise ValueError("incomplete native query set")
            reference.to("mps").eval()
            with torch.no_grad():
                for row in rows:
                    check();case=row["id"];normal=native[case];traced=instrumented[case]
                    normal_sha=model.sha(normal["output_bgra"]);traced_sha=model.sha(traced["output_bgra"])
                    hashes_equal=normal_sha==traced_sha==normal["output_sha256"]==traced["output_sha256"]
                    a,b=(images.get(row[k]).unsqueeze(0).to(device="mps",dtype=torch.float32)/255 for k in ("first","second"))
                    output,stages=model.forward(reference,a,b)
                    rgb=np.fromfile(normal["output_bgra"],dtype=np.uint8).reshape(1080,1920,4)[:,:,:3][:,:,::-1].copy().astype(np.float32)/255
                    expected=output.detach().cpu().numpy().transpose(0,2,3,1)[0]
                    mse=float(np.mean((rgb.astype(np.float64)-expected)**2))
                    psnr=-10*math.log10(max(mse,1e-20))
                    state=root/"states"/case/"initial/alpha-0.5"
                    flow=np.load(state/"stage3_flow.npy",allow_pickle=False)
                    mask=np.load(state/"stage3_mask.npy",allow_pickle=False)
                    torch_flow=stages[3][0].detach().cpu().numpy().transpose(0,2,3,1)
                    torch_mask=stages[3][1].detach().cpu().numpy().transpose(0,2,3,1)
                    if flow.shape!=torch_flow.shape or mask.shape!=torch_mask.shape:raise ValueError("native/torch state shape mismatch")
                    error=np.abs(flow[:,:270,:480]-torch_flow[:,:270,:480]).astype(np.float64)*4
                    p99=float(np.quantile(error,.99))
                    finite=bool(np.isfinite(flow).all() and np.isfinite(mask).all() and np.isfinite(expected).all()
                                and np.isfinite(torch_flow).all() and np.isfinite(torch_mask).all())
                    item=dict(id=case,group=row["diagnostic_group"],clip=row["clip"],native_output_sha256=normal_sha,
                              probe_output_sha256=traced_sha,probe_preserves_output_hash=hashes_equal,
                              rgb_psnr_db=psnr,fullpixel_flow_absolute_p99=p99,
                              fullpixel_flow_absolute_max=float(error.max()),all_states_finite=finite,
                              rgb_psnr_ge40=psnr>=40,flow_p99_le0_5=p99<=.5)
                    report["rows"].append(item);train_a.write(root/"report.json",report)
                    print(json.dumps(item),flush=True)
            report["gates"]=dict(queries16=len(report["rows"])==16,
                probe_outputs_bitwise_equal=all(x["probe_preserves_output_hash"] for x in report["rows"]),
                all_states_finite=all(x["all_states_finite"] for x in report["rows"]),
                every_RGB_PSNR_ge40=all(x["rgb_psnr_ge40"] for x in report["rows"]),
                every_fullpixel_flow_p99_le0_5=all(x["flow_p99_le0_5"] for x in report["rows"]))
            report["numerical_alignment_passed"]=all(report["gates"].values())
            report["status"]="completed"
        except Exception as error:
            report.update(status="failed",first_failure=f"{type(error).__name__}: {error}")
            raise
        finally:
            torch.mps.synchronize()
            report["cost_binary_unchanged"]=model.sha(config["immutable_cost_binary"])==report["cost_binary_sha256_before"]
            report["elapsed_seconds"]=time.monotonic()-started
            train_a.write(root/"report.json",report)
            fcntl.flock(lock,fcntl.LOCK_UN)
    print(json.dumps(dict(gates=report["gates"],numerical_alignment_passed=report["numerical_alignment_passed"])),flush=True)


if __name__=="__main__":
    p=Path(sys.argv[1]).resolve();config=json.loads(p.read_text());config["config_path"]=str(p);run(config)
