"""Isolated 4.25 beta-folded ResConv experiment; never relabels a v1 model.

Uses the existing ODF-VFI lab's strict RMW reader and reference network.
All factorization runs on CPU in float64. Exports are explicitly FP16 RMW2.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import math
from pathlib import Path
import struct
import sys

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

GRAPHS = {
    "odf-ifnet425-b3r32-b4r16-betafold-v1": (32, 16),
    "odf-ifnet425-b3r64-b4r32-betafold-diag-v1": (64, 32),
    "odf-ifnet425-b3r32-b4dense-betafold-v1": (32, 0),
    "odf-ifnet425-b3dense-b4r16-betafold-v1": (0, 16),
    "odf-ifnet425-dense-folded-probe-v1": (0, 0),
}
STUDENT = next(iter(GRAPHS))
DIAGNOSTIC = list(GRAPHS)[1]
MATERIALIZED = list(GRAPHS)[4]


def load_lab(root):
    sys.path.insert(0, str(Path(root).resolve()))
    return importlib.import_module("rmw"), importlib.import_module("ifnet")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def schema(rmw, graph):
    ranks = GRAPHS[graph]
    shapes = {}
    for name, shape in rmw.state_schema().items():
        stage = int(name[5]) if name.startswith("block") else -1
        if stage in (3, 4) and ranks[stage - 3] > 0 and ".convblock." in name:
            if name.endswith(".conv.weight"):
                p = name.removesuffix("conv.weight")
                c, r = shape[0], ranks[stage - 3]
                shapes[p + "conv_a.weight"] = (r, c, 3, 3)
                shapes[p + "conv_b.weight"] = (c, r, 1, 1)
                shapes[p + "conv_b.bias"] = (c,)
        else:
            shapes[name] = shape
    return shapes


def factorize(weight, bias, beta, rank):
    c = weight.shape[0]
    effective = beta.reshape(c, 1).double() * weight.reshape(c, -1).double()
    folded_bias = beta.reshape(c).double() * bias.double()
    u, s, vh = torch.linalg.svd(effective, full_matrices=False)
    root = s[:rank].sqrt()
    a = (root[:, None] * vh[:rank]).reshape(rank, c, 3, 3)
    b = (u[:, :rank] * root).reshape(c, rank, 1, 1)
    restored = b.reshape(c, rank) @ a.reshape(rank, -1)
    return a, b, folded_bias, {
        "singular_values": s.tolist(),
        "tail_energy_fraction": float(s[rank:].square().sum() / s.square().sum()) if s.any() else 0.0,
        "kernel_relative_l2": float(torch.linalg.norm(effective - restored) / torch.linalg.norm(effective)) if s.any() else 0.0,
        "kernel_max_abs": float((effective - restored).abs().max()),
    }


def factorize_response(weight, bias, beta, rank, covariance, ridge_relative=1e-5):
    """Fixed-bias rank-r optimum for Q + ridge*I; diagnostics use actual Q.

    Q is the uncentered second moment of zero-padded input patches, not a
    centered covariance. FP16 storage error is included in response diagnostics.
    """
    c = weight.shape[0]
    effective = beta.reshape(c, 1).double() * weight.reshape(c, -1).double()
    folded_bias = beta.reshape(c).double() * bias.double()
    q = covariance.double()
    ridge = float(q.trace() / q.shape[0]) * ridge_relative
    if ridge <= 0:
        raise ValueError("calibration has no positive response energy")
    eigenvalues, eigenvectors = torch.linalg.eigh(q)
    regularized = eigenvalues.clamp_min(0) + ridge
    root = (eigenvectors * regularized.sqrt()) @ eigenvectors.T
    inverse_root = (eigenvectors * regularized.rsqrt()) @ eigenvectors.T
    u, s, vh = torch.linalg.svd(effective @ root, full_matrices=False)
    a = ((s[:rank].sqrt()[:, None] * vh[:rank]) @ inverse_root).reshape(rank, c, 3, 3)
    b = (u[:, :rank] * s[:rank].sqrt()).reshape(c, rank, 1, 1)
    approximate = b.half().double().reshape(c, rank) @ a.half().double().reshape(rank, -1)
    delta = effective - approximate
    denominator = torch.trace(effective @ q @ effective.T)
    return a, b, folded_bias, dict(
        ridge_relative=ridge_relative, ridge_absolute=ridge,
        q_min_eigenvalue=float(eigenvalues.min()),
        regularized_condition_number=float(regularized.max() / regularized.min()),
        response_relative_mse_fp16_weights=float(torch.trace(delta @ q @ delta.T) / denominator),
        response_error_scope="linear branch with fixed exact folded bias; exported bias quantization assessed end to end",
    )


def initialize(rmw, source, graph, covariances=None):
    if graph == MATERIALIZED:
        raise ValueError("materialized probe requires existing exported factors; use materialize.py")
    if source.model != "rife-v4.25":
        raise ValueError("This graph is bound to 4.25 with replace-mask semantics")
    state = {n: t.clone() for n, t in source.state_dict.items()}
    rows = []
    for stage, rank in zip((3, 4), GRAPHS[graph]):
        if rank == 0:
            continue  # retain this stage's original dense weights and beta
        for layer in range(8):
            p = f"block{stage}.convblock.{layer}."
            args = (state.pop(p + "conv.weight"), state.pop(p + "conv.bias"), state.pop(p + "beta"), rank)
            a, b, bias, row = (factorize(*args) if covariances is None else
                               factorize_response(*args, covariances[p[:-1]]))
            state.update({p + "conv_a.weight": a, p + "conv_b.weight": b, p + "conv_b.bias": bias})
            rows.append(dict(layer=p[:-1], rank=rank, **row))
    expected = schema(rmw, graph)
    assert set(state) == set(expected)
    assert all(tuple(state[n].shape) == shape for n, shape in expected.items())
    return state, rows


def export_rmw(rmw, graph, state, output):
    shapes = schema(rmw, graph)
    if set(state) != set(shapes):
        raise ValueError("missing or extra low-rank weights")
    entries, blob = [], bytearray()
    for name, shape in shapes.items():
        if tuple(state[name].shape) != shape or not torch.isfinite(state[name]).all():
            raise ValueError(f"invalid tensor {name}")
        x = state[name].detach().cpu().half().numpy()
        if name.endswith(".beta"):
            x = x.reshape(1, 1, 1, -1)
        elif x.ndim == 4:
            x = x.transpose(2, 3, 1, 0)
        x = np.ascontiguousarray(x, dtype="<f2")
        if not np.isfinite(x).all():
            raise ValueError(f"FP16 overflow in {name}")
        entries.append(dict(name=name, dtype="f16", shape=list(x.shape), offset=len(blob), size=x.nbytes))
        blob.extend(x.tobytes())
    header = dict(model=graph, graph_id=graph, mask_update="replace", ifblock_channels=[192, 128, 96, 64, 32],
                  scale_list=[16, 8, 4, 2, 1], input_layout="NHWC", tensors=entries)
    encoded = json.dumps(header, sort_keys=True).encode()
    prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
    Path(output).write_bytes(prefix + b"\0" * (-len(prefix) % 16) + blob)
    return header


class LowRankResConv(nn.Module):
    def __init__(self, channels, rank):
        super().__init__()
        self.conv_a = nn.Conv2d(channels, rank, 3, padding=1, bias=False)
        self.conv_b = nn.Conv2d(rank, channels, 1)

    def forward(self, x):
        return F.leaky_relu(x + self.conv_b(self.conv_a(x)), 0.2)


def reference(ifnet, graph, state):
    class LowRankStudent(ifnet.IFNetStudent):
        # Explicit new graph contract: do not let the old model-tag fallback
        # silently change the new student's replacement-mask semantics.
        def estimate(self, first, second, timestep, *, mask_update="replace", trace=None):
            if mask_update != "replace":
                raise ValueError("this student graph requires replace mask")
            f0, f1 = self.encode(first), self.encode(second)
            t = torch.full_like(first[:, :1], timestep)
            flow = mask = feat = None
            for i, scale in enumerate((16, 8, 4, 2, 1)):
                x = (torch.cat((first, second, f0, f1, t), 1) if flow is None else
                     torch.cat((ifnet.warp(first, flow[:, :2]), ifnet.warp(second, flow[:, 2:]),
                                ifnet.warp(f0, flow[:, :2]), ifnet.warp(f1, flow[:, 2:]), t, mask, feat), 1))
                delta, mask, feat = getattr(self, f"block{i}")(x, flow, scale)
                flow = delta if flow is None else flow + delta
                if trace is not None:
                    trace(i, flow, mask, feat)
            return flow, mask

        def forward(self, first, second, **kwargs):
            kwargs.setdefault("mask_update", "replace")
            return super().forward(first, second, **kwargs)

    net = LowRankStudent()
    for stage, rank in zip((3, 4), GRAPHS[graph]):
        if rank == 0:
            continue
        block = getattr(net, f"block{stage}")
        block.convblock = nn.Sequential(*(LowRankResConv((64, 32)[stage - 3], rank) for _ in range(8)))
    net.load_state_dict(state, strict=True)
    net.graph_id = graph
    return net.eval()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lab-root", type=Path, required=True)
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    torch.set_num_threads(4)
    rmw, _ = load_lab(args.lab_root)
    source = rmw.read_rmw(args.source)
    args.output.mkdir(parents=True, exist_ok=True)
    for graph in GRAPHS:
        if graph == MATERIALIZED:
            continue
        state, rows = initialize(rmw, source, graph)
        path = args.output / (graph + ".rmw")
        header = export_rmw(rmw, graph, state, path)
        torch.save(dict(graph_id=graph, base_sha256=sha(args.source), state_dict=state), path.with_suffix(".pt"))
        manifest = dict(graph_id=graph, weights_sha256=sha(path), base_sha256=sha(args.source),
                        base_model=source.model, ranks=GRAPHS[graph], beta_strategy="fold_weight_and_bias_no_outer_beta",
                        mask_update="replace", dtype="float16", tensors=len(header["tensors"]),
                        parameter_count=sum(math.prod(s) for s in schema(rmw, graph).values()),
                        initialization="float64_svd_sqrt_split_then_fp16_export", trained=False,
                        quality_accepted=False, diagnostics=rows,
                        sources={n: sha(args.lab_root / n) for n in ("rmw.py", "ifnet.py")},
                        exporter_sha256=sha(__file__))
        path.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({k: v for k, v in manifest.items() if k not in ("diagnostics", "sources")}))


if __name__ == "__main__":
    main()
