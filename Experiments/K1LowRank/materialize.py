"""Same exported rank-r factors, materialized as a dense convolution probe.

Exact real-arithmetic branch equivalence; FP16 storage/intermediate rounding
differs and requires a native quality comparison. No new approximation rank.
"""
import argparse
import json
from pathlib import Path

import torch

import lowrank as lr


def materialize(source, saved):
    graph = saved["graph_id"]
    state = {n: t.clone() for n, t in source.state_dict.items()}
    rows = []
    for stage, rank in zip((3, 4), lr.GRAPHS[graph]):
        if rank == 0:
            continue
        for j in range(8):
            p = f"block{stage}.convblock.{j}."
            # Reconstruct from the actual FP16-exported factors, not their
            # higher precision initializer. The native convolution stores FP16.
            down = saved["state_dict"][p + "conv_a.weight"].half().double()
            up = saved["state_dict"][p + "conv_b.weight"].half().double()
            c = down.shape[1]
            effective = up.reshape(c, rank) @ down.reshape(rank, -1)
            state[p + "conv.weight"] = effective.reshape(c, c, 3, 3).half().float()
            state[p + "conv.bias"] = saved["state_dict"][p + "conv_b.bias"].half().float()
            state[p + "beta"] = torch.ones(1, c, 1, 1)
            rows.append(dict(layer=p[:-1], materialized_kernel_quantization_relative_l2=float(
                (effective - effective.half().double()).norm() / effective.norm())))
    return state, rows


def fold_original(source, stages):
    """Fold beta into original dense W and bias; no rank approximation."""
    state = {n: t.clone() for n, t in source.state_dict.items()}
    rows = []
    for stage in stages:
        for j in range(8):
            p = f"block{stage}.convblock.{j}."
            beta = state[p + "beta"].double()
            c = beta.numel()
            effective = beta.reshape(c, 1, 1, 1) * state[p + "conv.weight"].double()
            state[p + "conv.weight"] = effective.half().float()
            state[p + "conv.bias"] = (beta.reshape(c) * state[p + "conv.bias"].double()).half().float()
            state[p + "beta"] = torch.ones_like(beta).float()
            rows.append(dict(layer=p[:-1], folded_kernel_quantization_relative_l2=float(
                (effective - effective.half().double()).norm() / effective.norm())))
    return state, rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lab-root", type=Path, required=True)
    ap.add_argument("--source", type=Path, required=True)
    choice = ap.add_mutually_exclusive_group(required=True)
    choice.add_argument("--checkpoint", type=Path)
    choice.add_argument("--fold-original", action="store_true")
    ap.add_argument("--fold-stages", default="0,1,2,3,4")
    ap.add_argument("--inventory", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    torch.set_num_threads(4)
    rmw, _ = lr.load_lab(args.lab_root)
    source = rmw.read_rmw(args.source)
    args.output.mkdir(parents=True, exist_ok=False)
    if args.fold_original:
        stages = [int(s) for s in args.fold_stages.split(",")]
        assert stages and all(0 <= s <= 4 for s in stages)
        state, rows = fold_original(source, stages)
    else:
        saved = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
        state, rows = materialize(source, saved)
    path = args.output / (lr.MATERIALIZED + ".rmw")
    lr.export_rmw(rmw, lr.MATERIALIZED, state, path)
    torch.save(dict(graph_id=lr.MATERIALIZED, state_dict=state), path.with_suffix(".pt"))
    manifest = dict(graph_id=lr.MATERIALIZED, weights_sha256=lr.sha(path), source_sha256=lr.sha(args.source),
        materializer_sha256=lr.sha(__file__), diagnostics=rows,
        purpose="original dense beta fold, no rank approximation" if args.fold_original else
                "execution-expression counterfactual; dense MAC restored, not a low-MAC candidate", quality_accepted=False)
    if not args.fold_original:
        manifest.update(factor_checkpoint_sha256=lr.sha(args.checkpoint), factor_rmw_sha256=lr.sha(args.checkpoint.with_suffix(".rmw")))
    path.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    inventory = json.loads(args.inventory.read_text())
    inventory["models"] = ({"d0": inventory["models"]["d0"]} if args.fold_original else
                           {k: inventory["models"][k] for k in ("d0", "r4")})
    inventory["models"]["f0" if args.fold_original else "m4"] = str(path)
    (args.output / "inputs.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print(json.dumps(manifest), flush=True)
