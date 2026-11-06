"""Count convolution MACs from real reference-module calls at 1080p Fast.

The reference encodes both endpoints; the warm-stream ledger subtracts exactly
one Head. This is static arithmetic accounting, not a device speed estimate.
"""
import argparse
import json
from pathlib import Path

import torch
from torch import nn

import lowrank as lr


def count(net):
    rows, handles = [], []
    for name, module in net.named_modules():
        if not isinstance(module, (nn.Conv2d, nn.ConvTranspose2d)):
            continue

        def hook(layer, inputs, output, name=name):
            tensor = inputs[0] if isinstance(layer, nn.ConvTranspose2d) else output
            sites = tensor.shape[0] * tensor.shape[2] * tensor.shape[3]
            mac = sites * layer.in_channels * layer.out_channels * layer.kernel_size[0] * layer.kernel_size[1] // layer.groups
            rows.append(dict(name=name, input_shape=list(inputs[0].shape), output_shape=list(output.shape), mac=mac))

        handles.append(module.register_forward_hook(hook))
    with torch.inference_mode():
        image = torch.zeros(1, 3, 1080, 1920)
        net(image, image, tier="fast", timestep=.5, mask_update="replace")
    for handle in handles:
        handle.remove()
    head = sum(r["mac"] for r in rows if r["name"].startswith("encode.")) // 2
    trunk_rows = [r for r in rows if r["name"].startswith("block")]
    trunk = sum(r["mac"] for r in trunk_rows)
    return dict(head_once_mac=head, trunk_mac=trunk, warm_K1_mac=head + trunk,
                trunk_convolution_calls=len(trunk_rows), rows=rows,
                note="logical convolution MACs only; excludes warp, resize, activation, IO and execution-algorithm transformations")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lab-root", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--candidate-checkpoint", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    torch.set_num_threads(4)
    rmw, ifnet = lr.load_lab(args.lab_root)
    baseline = ifnet.IFNetStudent.from_rmw(args.source)
    checkpoint = torch.load(args.candidate_checkpoint, map_location="cpu", weights_only=True)
    student = lr.reference(ifnet, checkpoint["graph_id"], checkpoint["state_dict"])
    result = dict(baseline=count(baseline), student=count(student), base_weights_sha256=lr.sha(args.source),
                  candidate_checkpoint_sha256=lr.sha(args.candidate_checkpoint), audit_source_sha256=lr.sha(__file__))
    assert result["baseline"]["warm_K1_mac"] == 3391841280
    assert result["student"]["warm_K1_mac"] == 2720752640
    assert (result["baseline"]["trunk_convolution_calls"], result["student"]["trunk_convolution_calls"]) == (55, 71)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: {n: v for n, v in r.items() if n != "rows"} for k, r in result.items() if k in ("baseline", "student")}))
