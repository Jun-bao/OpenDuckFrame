"""Accumulate-mask 4.25 teacher and factor-only student experiment.

Only block3/block4's eight residual branches are factored.  The CPU/FP64
factorization algebra is reused from K1LowRank; its replace-mask reference and
exporter are deliberately not reused.  The lab's strict original-weight reader
and complete tier-aware reference forward remain the source of deployment math.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import sys

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F


GRAPH_ID = "odf-ifnet425-acc-b3r32-b4r16-v1"
DIAGNOSTIC_GRAPH_ID = "odf-ifnet425-acc-b3r64-b4r32-diag-v1"
RANKS = (32, 16)
GRAPHS = {GRAPH_ID: RANKS, DIAGNOSTIC_GRAPH_ID: (64, 32)}
MASK_UPDATE = "accumulate"
BASE_MODEL = "rife-v4.25"
CHANNELS = (192, 128, 96, 64, 32)
SCALES = (16, 8, 4, 2, 1)
CHECKPOINT_FORMAT = "odf-k1-accumulate-student-v1"


def _algebra_module():
    # Load the owning file even when this module is run from a script directory.
    name = "_odf_k1_lowrank_algebra"
    if name not in sys.modules:
        path = Path(__file__).resolve().parents[1] / "K1LowRank" / "lowrank.py"
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def load_lab(lab_root):
    """Return the existing lab's strict original RMW reader and IFNet module."""
    return _algebra_module().load_lab(lab_root)


def _graph_id(ranks):
    ranks = tuple(ranks)
    for graph, expected in GRAPHS.items():
        if ranks == expected:
            return graph
    raise ValueError(f"unsupported student ranks: {ranks!r}")


def schema(ranks=RANKS):
    """Canonical PyTorch schema for the two explicitly named student graphs.

    Kept independent of process-global lab imports so standalone export has the
    same native contract.  initialize checks it against the lab's base schema.
    """
    _graph_id(ranks)
    shapes = {}
    for i, shape in enumerate(((16, 3, 3, 3), (16, 16, 3, 3),
                               (16, 16, 3, 3), (16, 4, 4, 4))):
        shapes[f"encode.cnn{i}.weight"] = shape
        shapes[f"encode.cnn{i}.bias"] = (4 if i == 3 else 16,)
    for stage, (c, inputs) in enumerate(zip(CHANNELS, (15, 28, 28, 28, 28))):
        p = f"block{stage}."
        shapes[p + "conv0.0.0.weight"] = (c // 2, inputs, 3, 3)
        shapes[p + "conv0.0.0.bias"] = (c // 2,)
        shapes[p + "conv0.1.0.weight"] = (c, c // 2, 3, 3)
        shapes[p + "conv0.1.0.bias"] = (c,)
        for layer in range(8):
            branch = p + f"convblock.{layer}."
            if stage in (3, 4):
                rank = ranks[stage - 3]
                shapes[branch + "conv_a.weight"] = (rank, c, 3, 3)
                shapes[branch + "conv_b.weight"] = (c, rank, 1, 1)
                shapes[branch + "conv_b.bias"] = (c,)
            else:
                shapes[branch + "conv.weight"] = (c, c, 3, 3)
                shapes[branch + "conv.bias"] = (c,)
                shapes[branch + "beta"] = (1, c, 1, 1)
        shapes[p + "lastconv.0.weight"] = (c, 52, 4, 4)
        shapes[p + "lastconv.0.bias"] = (52,)
    return shapes


def _state_ranks(state):
    ranks = tuple(state[f"block{stage}.convblock.0.conv_a.weight"].shape[0]
                  for stage in (3, 4))
    _graph_id(ranks)
    return ranks


def _validate_state(state, ranks):
    expected = schema(ranks)
    if set(state) != set(expected):
        raise ValueError("missing or extra accumulate-student weights")
    for name, shape in expected.items():
        t = state[name]
        if (not isinstance(t, torch.Tensor) or tuple(t.shape) != shape
                or not t.is_floating_point() or t.layout != torch.strided):
            raise ValueError(f"invalid student tensor {name}: expected {shape}")


def _original(source, rmw):
    weights = rmw.read_rmw(source) if isinstance(source, (str, Path)) else source
    if weights.model != BASE_MODEL:
        raise ValueError("accumulate student requires original rife-v4.25 weights")
    rmw.validate_state(weights.state_dict)
    return weights


def initialize(source, lab_root, covariances=None, *, ranks=RANKS):
    """Initialize from original 4.25, never from a legacy replace-mask export.

    Optional covariances are uncentered input-patch second moments keyed by
    ``blockN.convblock.M``. All decomposition runs on CPU in float64. Other
    tensors are detached clones of the original and retain their exact values.
    """
    graph = _graph_id(ranks)
    rmw, _ = load_lab(lab_root)
    original = _original(source, rmw)
    algebra = _algebra_module()
    state = {name: t.detach().cpu().clone() for name, t in original.state_dict.items()}
    diagnostics = []
    for stage, rank in zip((3, 4), ranks):
        for layer in range(8):
            p = f"block{stage}.convblock.{layer}."
            args = (state.pop(p + "conv.weight"), state.pop(p + "conv.bias"),
                    state.pop(p + "beta"), rank)
            if covariances is None:
                a, b, bias, row = algebra.factorize(*args)
            else:
                q = covariances[p[:-1]].detach().cpu().double()
                a, b, bias, row = algebra.factorize_response(*args, q)
            state.update({p + "conv_a.weight": a, p + "conv_b.weight": b,
                          p + "conv_b.bias": bias})
            diagnostics.append(dict(layer=p[:-1], rank=rank, **row))
    # Use the existing schema transformation only for shape comparison; it does
    # not select this experiment's graph identity or mask policy.
    old_graph = algebra.STUDENT if graph == GRAPH_ID else algebra.DIAGNOSTIC
    if schema(ranks) != algebra.schema(rmw, old_graph):
        raise ValueError("lab schema differs from the pinned student/native contract")
    _validate_state(state, ranks)
    return state, diagnostics


class LowRankResConv(nn.Module):
    """A 3x3 down projection and 1x1 up projection, then residual activation."""
    def __init__(self, channels, rank):
        super().__init__()
        self.conv_a = nn.Conv2d(channels, rank, 3, padding=1, bias=False)
        self.conv_b = nn.Conv2d(rank, channels, 1)

    def forward(self, x):
        return F.leaky_relu(x + self.conv_b(self.conv_a(x)), 0.2)


def _accumulate_class(ifnet):
    class AccumulateIFNet(ifnet.IFNetStudent):
        def estimate(self, first, second, timestep, *, mask_update=MASK_UPDATE, trace=None):
            if mask_update != MASK_UPDATE:
                raise ValueError("this experiment requires accumulate mask")
            return super().estimate(first, second, timestep, mask_update=MASK_UPDATE, trace=trace)

        def forward(self, first, second, *, tier="hq", timestep=0.5,
                    mask_update=MASK_UPDATE, trace=None):
            if mask_update != MASK_UPDATE:
                raise ValueError("this experiment requires accumulate mask")
            return super().forward(first, second, tier=tier, timestep=timestep,
                                   mask_update=MASK_UPDATE, trace=trace)
    return AccumulateIFNet


def teacher(source, lab_root, device="cpu", dtype=torch.float32):
    """Frozen original 4.25 teacher, explicitly bound to product accumulation."""
    rmw, ifnet = load_lab(lab_root)
    original = _original(source, rmw)
    net = _accumulate_class(ifnet)()
    net.load_state_dict(original.state_dict, strict=True)
    net.model_identity = BASE_MODEL
    net.mask_update = MASK_UPDATE
    net.requires_grad_(False)
    return net.to(device=device, dtype=dtype).eval()


def _factor_names():
    return [f"block{stage}.convblock.{layer}.{suffix}"
            for stage in (3, 4) for layer in range(8)
            for suffix in ("conv_a.weight", "conv_b.weight", "conv_b.bias")]


def student(state, lab_root, device="cpu", dtype=torch.float32):
    """Build only a named accumulate student; freeze every non-factor tensor."""
    ranks = _state_ranks(state)
    _validate_state(state, ranks)
    _, ifnet = load_lab(lab_root)
    net = _accumulate_class(ifnet)()
    for stage, rank in zip((3, 4), ranks):
        getattr(net, f"block{stage}").convblock = nn.Sequential(
            *(LowRankResConv(CHANNELS[stage], rank) for _ in range(8)))
    net.load_state_dict(state, strict=True)
    net.graph_id = _graph_id(ranks)
    net.model_identity = net.graph_id
    net.mask_update = MASK_UPDATE
    allowed = set(_factor_names())
    for name, parameter in net.named_parameters():
        parameter.requires_grad_(name in allowed)
    return net.to(device=device, dtype=dtype).eval()


def trainable_names(net):
    return [name for name, parameter in net.named_parameters() if parameter.requires_grad]


def forward_with_stages(net, a, b, alpha, tier):
    """Return RGB plus all five internal stage states without detaching gradients.

    Geometry and full-resolution warp are executed by the unchanged lab forward.
    Stage tensors use the tier's internal working resolution.
    """
    stages = {}

    def trace(stage, flow, mask, feat):
        stages[stage] = (flow, mask, feat)

    rgb = net(a, b, timestep=alpha, tier=tier, mask_update=MASK_UPDATE, trace=trace)
    return rgb, stages


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def export(state, source_sha, path, trained, extra_manifest=None):
    """Write explicit FP16 RMW2, a weights-only-loadable checkpoint and sidecar.

    The .pt preserves supplied tensor precision for resuming; .rmw quantizes to
    FP16 using the existing native layout (RMW1 magic, version field 2).
    Neither format claims visual or business acceptance.
    """
    ranks = _state_ranks(state)
    graph = _graph_id(ranks)
    _validate_state(state, ranks)
    shapes = schema(ranks)
    entries, blob = [], bytearray()
    checkpoint_state = {}
    for name, shape in shapes.items():
        tensor = state[name].detach().cpu().contiguous()
        if not torch.isfinite(tensor).all():
            raise ValueError(f"nonfinite tensor {name}")
        array = tensor.half().numpy()
        if name.endswith(".beta"):
            array = array.reshape(1, 1, 1, -1)
        elif len(shape) == 4:
            array = array.transpose(2, 3, 1, 0)
        array = np.ascontiguousarray(array, dtype="<f2")
        if not np.isfinite(array).all():
            raise ValueError(f"FP16 overflow in {name}")
        entries.append(dict(name=name, dtype="f16", shape=list(array.shape),
                            offset=len(blob), size=array.nbytes))
        blob.extend(array.tobytes())
        checkpoint_state[name] = tensor.clone()
    header = dict(model=graph, graph_id=graph, mask_update=MASK_UPDATE,
                  ifblock_channels=list(CHANNELS), scale_list=list(SCALES),
                  input_layout="NHWC", tensors=entries)
    encoded = json.dumps(header, sort_keys=True).encode("utf-8")
    prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
    payload = prefix + b"\0" * (-len(prefix) % 16) + blob
    path = Path(path).with_suffix(".rmw")
    checkpoint_path = path.with_suffix(".pt")
    manifest_path = path.with_suffix(".manifest.json")
    manifest = dict(graph_id=graph, model=graph, mask_update=MASK_UPDATE,
                    base_model=BASE_MODEL, source_sha256=source_sha, base_sha256=source_sha,
                    ranks=list(ranks), dtype="float16", tensors=len(entries),
                    parameter_count=sum(math.prod(s) for s in shapes.values()),
                    trainable_parameter_count=sum(math.prod(shapes[n]) for n in _factor_names()),
                    trainable_names=_factor_names(),
                    beta_strategy="fold_weight_and_bias_no_outer_beta",
                    trained=bool(trained), quality_accepted=False,
                    weights_path=str(path), checkpoint_path=str(checkpoint_path),
                    manifest_path=str(manifest_path), exporter_sha256=sha(__file__))
    if extra_manifest:
        overlap = set(extra_manifest) & set(manifest)
        if overlap:
            raise ValueError(f"extra manifest cannot override contract fields: {sorted(overlap)!r}")
        manifest.update(extra_manifest)
    # Validate optional metadata before creating any artifact.
    json.dumps(manifest, allow_nan=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    torch.save(dict(format=CHECKPOINT_FORMAT, graph_id=graph, mask_update=MASK_UPDATE,
                    base_model=BASE_MODEL, source_sha256=source_sha, ranks=list(ranks),
                    trained=bool(trained), state_dict=checkpoint_state), checkpoint_path)
    manifest.update(weights_sha256=sha(path), checkpoint_sha256=sha(checkpoint_path))
    manifest_path.write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    return manifest
