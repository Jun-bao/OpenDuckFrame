"""Old-development-only response calibration and bounded quality diagnostics.

No formal holdout, original weights, app code or previous run is modified.
Teacher features are a local initialization proxy, not a quality guarantee.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image
import torch
from torch.nn import functional as F

import lowrank as lr


def rgb(path):
    return torch.from_numpy(np.array(Image.open(path).convert("RGB"))).permute(2, 0, 1).unsqueeze(0).float() / 255


def internal(ifnet, image):
    h, w = image.shape[-2:]
    return ifnet.resize(F.pad(image, (0, -w % 256, 0, -h % 256), mode="replicate"), scale=.25)


def patches(x, generator, count=512):
    # F.unfold ordering is C, kernel-y, kernel-x, matching OIHW flattening.
    z = F.unfold(x.detach(), 3, padding=1)[0]
    ids = torch.randperm(z.shape[1], generator=generator)[:count]
    return z[:, ids].double()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def save_model(rmw, source, graph, directory, covariances=None):
    state, diagnostics = lr.initialize(rmw, source, graph, covariances)
    state = {k: v.half().float() for k, v in state.items()}
    path = directory / (graph + ".rmw")
    lr.export_rmw(rmw, graph, state, path)
    torch.save(dict(graph_id=graph, state_dict=state), path.with_suffix(".pt"))
    dump(path.with_suffix(".manifest.json"), dict(graph_id=graph, sha256=lr.sha(path),
         initialization="response_weighted_svd" if covariances is not None else "kernel_svd",
         trained=False, quality_accepted=False, diagnostics=diagnostics))
    return str(path)


def prepare(args, manifest, rmw, source):
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "svd").mkdir()
    (args.output / "inputs").mkdir()
    clips = manifest["protocol"]["clips"]
    calibration, diagnostic = clips[:3], clips[3:]
    design = dict(created_at=datetime.now(timezone.utc).isoformat(), source_sha256=lr.sha(args.source),
        dev_manifest_sha256=lr.sha(args.dev_manifest), calibration_clips=calibration, diagnostic_clips=diagnostic,
        calibration_blocks=[0, 2], diagnostic_blocks=[0, 2], alphas=[.25, .5, .75],
        sampling="old development clips only; first and fifth frames with true intermediate GT",
        patch_sampling="512 distinct positions/layer/query, seed 20261106, zero padding, uncentered second moment",
        ridge_relative=1e-5, selection_scope="exploratory development diagnostics, not an independent acceptance set",
        mask_update="replace", tier="fast", source_semantics="12.5Hz endpoints, one independently queried target per K1 call",
        quality_gate="retain original quality requirement; diagnostics cannot establish formal noninferiority",
        source_sha256_by_file={p.name: lr.sha(p) for p in Path(__file__).parent.glob("*.py")})
    cases = []
    for clip in clips:
        for block in (0, 2):
            t0 = next(t for t in manifest["triplets"] if t["sequence"] == clip and t["block"] == block and t["id"].endswith("t0"))
            t1 = next(t for t in manifest["triplets"] if t["sequence"] == clip and t["block"] == block and t["id"].endswith("t1"))
            paths = [t0["previous"], t0["gt"], t0["current"], t1["gt"], t1["current"]]
            cases.append(dict(id=f"{clip}-b{block}", clip=clip, block=block, frames=paths,
                frame_sha256={p: lr.sha(p) for p in paths}, partition="calibration" if clip in calibration else "diagnostic"))
    design["cases"] = cases
    dump(args.output / "design.json", design)  # fixed before reading any model response
    native_cases = []
    for case in cases:
        if case["block"] != 0:
            continue
        item = dict(id=case["id"])
        for key, path in zip(("first", "second"), (case["frames"][0], case["frames"][4])):
            pixels = np.array(Image.open(path).convert("RGB"))
            bgra = np.concatenate((pixels[:, :, ::-1], np.full((*pixels.shape[:2], 1), 255, np.uint8)), axis=2)
            output = args.output / "inputs" / (case["id"] + "-" + key + ".bgra")
            output.write_bytes(bgra.tobytes())
            item[key] = str(output)
        native_cases.append(item)
    partial = [g for g, ranks in lr.GRAPHS.items() if 0 in ranks]
    models = dict(d0=str(args.source), d3=save_model(rmw, source, partial[0], args.output / "svd"),
                  d4=save_model(rmw, source, partial[1], args.output / "svd"), d34=str(args.prior_student))
    dump(args.output / "four-corner-inputs.json", dict(cases=native_cases, models=models))
    print("prepared four corners and ten fixed real-video development cases", flush=True)


def calibrate(args, rmw, ifnet, source):
    design = json.loads((args.output / "design.json").read_text())
    teacher = ifnet.IFNetStudent.from_rmw(args.source)
    generator = torch.Generator().manual_seed(20261106)
    sums, counts = {}, {}
    def collect(name):
        def hook(module, inputs):
            z = patches(inputs[0], generator)
            sums[name] = sums.get(name, 0) + z @ z.T
            counts[name] = counts.get(name, 0) + z.shape[1]
        return hook
    handles = [module.register_forward_pre_hook(collect(name)) for name, module in teacher.named_modules()
               if name.startswith(("block3.convblock.", "block4.convblock.")) and isinstance(module, ifnet.ResConv)]
    with torch.inference_mode():
        for case in design["cases"]:
            if case["partition"] != "calibration":
                continue
            a, b = (internal(ifnet, rgb(case["frames"][i])) for i in (0, 4))
            for alpha in design["alphas"]:
                teacher.estimate(a, b, alpha, mask_update="replace")
            print("calibrated", case["id"], flush=True)
    for handle in handles:
        handle.remove()
    q = {n: sums[n] / counts[n] for n in sums}
    torch.save(dict(second_moment=q, counts=counts), args.output / "teacher-second-moments.pt")
    destination = args.output / "response"
    destination.mkdir(exist_ok=False)
    response = {}
    for key, graph in (("r3", list(lr.GRAPHS)[2]), ("r4", list(lr.GRAPHS)[3]), ("r34", lr.STUDENT)):
        response[key] = save_model(rmw, source, graph, destination, q)
    inventory = json.loads((args.output / "four-corner-inputs.json").read_text())
    inventory["models"].update(response)
    dump(args.output / "all-models.json", inventory)
    print("response models exported; starting fixed development quality diagnostics", flush=True)
    rows = []
    for case in design["cases"]:
        if case["partition"] != "diagnostic":
            continue
        a, b = (rgb(case["frames"][i]) for i in (0, 4))
        for alpha, index in zip(design["alphas"], (1, 2, 3)):
            target = rgb(case["frames"][index])
            with torch.inference_mode():
                base = teacher(a, b, tier="fast", timestep=alpha, mask_update="replace")
            row = dict(case_id=case["id"], alpha=alpha, models={})
            for key, path in inventory["models"].items():
                local = {}
                if key == "d0":
                    prediction = base
                else:
                    saved = torch.load(Path(path).with_suffix(".pt"), map_location="cpu", weights_only=True)
                    state = {k: v.half().float() for k, v in saved["state_dict"].items()}
                    model = lr.reference(ifnet, saved["graph_id"], state)
                    def compare(name):
                        def hook(module, inputs):
                            z = patches(inputs[0], generator)
                            p = name + "."
                            c = source.state_dict[p + "beta"].reshape(-1, 1).double()
                            m = c * source.state_dict[p + "conv.weight"].reshape(c.shape[0], -1).double()
                            bias = c * source.state_dict[p + "conv.bias"].reshape(-1, 1).double()
                            expected = m @ z + bias
                            actual = module.conv_b.weight.detach().double().reshape(c.shape[0], -1) @ (
                                module.conv_a.weight.detach().double().reshape(module.conv_a.out_channels, -1) @ z
                            ) + module.conv_b.bias.detach().double().reshape(-1, 1)
                            local[name] = float((actual - expected).square().sum() / expected.square().sum())
                        return hook
                    hooks = [module.register_forward_pre_hook(compare(name)) for name, module in model.named_modules()
                             if isinstance(module, lr.LowRankResConv)]
                    with torch.inference_mode():
                        prediction = model(a, b, tier="fast", timestep=alpha)
                    for hook in hooks:
                        hook.remove()
                mse = float((prediction.clamp(0, 1) - target).square().mean())
                teacher_mse = float((prediction - base).square().mean())
                row["models"][key] = dict(gt_psnr_db=-10 * math.log10(max(mse, 1e-20)),
                    teacher_mse=teacher_mse, local_branch_relative_mse_on_student_inputs=local)
            rows.append(row)
            dump(args.output / "dev-quality-progress.json", dict(rows=rows))
            print("diagnosed", case["id"], alpha, {k: round(v["gt_psnr_db"], 3) for k, v in row["models"].items()}, flush=True)
    summary = {}
    for key in inventory["models"]:
        values = [r["models"][key] for r in rows]
        deltas = [r["models"][key]["gt_psnr_db"] - r["models"]["d0"]["gt_psnr_db"] for r in rows]
        summary[key] = dict(mean_gt_psnr_db=float(np.mean([v["gt_psnr_db"] for v in values])),
            mean_delta_to_teacher_db=float(np.mean(deltas)), worst_delta_to_teacher_db=min(deltas),
            mean_teacher_mse=float(np.mean([v["teacher_mse"] for v in values])))
    dump(args.output / "dev-quality.json", dict(summary=summary, rows=rows, scope="FP32 reference with FP16-stored weights; 2 old development clips, 4 frame windows, 12 target queries; no native or independent quality acceptance"))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lab-root", type=Path, required=True)
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--prior-student", type=Path, required=True)
    ap.add_argument("--dev-manifest", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--stage", choices=("prepare", "calibrate"), required=True)
    args = ap.parse_args()
    torch.set_num_threads(4)
    rmw, ifnet = lr.load_lab(args.lab_root)
    source = rmw.read_rmw(args.source)
    if args.stage == "prepare":
        prepare(args, json.loads(args.dev_manifest.read_text()), rmw, source)
    else:
        calibrate(args, rmw, ifnet, source)
