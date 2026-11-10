"""Four-stage accumulated-mask student; original tier geometry and synthesis.

Only the fifth refinement stage is removed. The existing read-only deployment
reference owns padding, sampling, flow units and the final full-resolution warp.
This graph is not an old low-rank model and is not loaded by production builds.
"""
from __future__ import annotations

import hashlib
import importlib
import json
import math
from pathlib import Path
import struct
import sys

import numpy as np
import torch

GRAPH_ID = "odf-ifnet425-fourstage-acc-v1"
FORMAT = "odf-air24-fourstage-state-v1"
BASE_SHA256 = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
CHANNELS = (192, 128, 96, 64)
SCALES = (16, 8, 4, 2)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_lab(root):
    sys.path.insert(0, str(Path(root).resolve()))
    return importlib.import_module("rmw"), importlib.import_module("ifnet")


def schema(lab_root):
    rmw, _ = load_lab(lab_root)
    return {name: shape for name, shape in rmw.state_schema().items()
            if not name.startswith("block4.")}


def create(source, lab_root):
    if sha(source) != BASE_SHA256:
        raise ValueError("four-stage source must be the pinned original4.25")
    rmw, ifnet = load_lab(lab_root)
    original = rmw.read_rmw(source)

    class FourStage(ifnet.IFNetStudent):
        def __init__(self):
            super().__init__()
            del self.block4
            self.model_identity = GRAPH_ID

        def estimate(self, first, second, timestep, *, mask_update="accumulate", trace=None):
            if mask_update != "accumulate":
                raise ValueError("four-stage graph requires accumulated masks")
            f0, f1 = self.encode(first), self.encode(second)
            t = torch.full_like(first[:, :1], timestep)
            flow, mask, feat = None, None, None
            for i, scale in enumerate(SCALES):
                if flow is None:
                    x = torch.cat((first, second, f0, f1, t), dim=1)
                else:
                    x = torch.cat((ifnet.warp(first, flow[:, :2]), ifnet.warp(second, flow[:, 2:]),
                                   ifnet.warp(f0, flow[:, :2]), ifnet.warp(f1, flow[:, 2:]),
                                   t, mask, feat), dim=1)
                delta, new_mask, feat = getattr(self, f"block{i}")(x, flow, scale)
                flow = delta if flow is None else flow + delta
                mask = new_mask if mask is None else mask + new_mask
                if trace is not None:
                    trace(i, flow, mask, feat)
            return flow, mask

    student = FourStage()
    student.load_state_dict({name: tensor for name, tensor in original.state_dict.items()
                             if not name.startswith("block4.")}, strict=True)
    student.requires_grad_(False)
    student.block3.requires_grad_(True)
    teacher = ifnet.IFNetStudent.from_rmw(source)
    teacher.requires_grad_(False)
    return student.eval(), teacher.eval(), ifnet


def forward(net, a, b, alpha=0.5):
    stages = {}

    def trace(i, flow, mask, feat):
        stages[i] = (flow, mask, feat)

    rgb = net(a, b, tier="fast", timestep=alpha, mask_update="accumulate", trace=trace)
    return rgb, stages


def state(net):
    return {name: tensor.detach().cpu().clone() for name, tensor in net.state_dict().items()}


def read_export(path, lab_root):
    """Read the actual FP16 payload for an FP32 deployment-parity reference."""
    raw = Path(path).read_bytes()
    if raw[:4] != b"RMW1":
        raise ValueError("missing RMW magic")
    version, length = struct.unpack_from("<II", raw, 4)
    header = json.loads(raw[12:12+length])
    start = (12+length+15)//16*16
    if (version != 2 or header["model"] != GRAPH_ID or header["graph_id"] != GRAPH_ID
            or header["mask_update"] != "accumulate" or header["ifblock_channels"] != list(CHANNELS)
            or header["scale_list"] != list(SCALES) or header["input_layout"] != "NHWC"):
        raise ValueError("unexpected four-stage export contract")
    expected = schema(lab_root)
    if len(header["tensors"]) != len(expected):
        raise ValueError("unexpected export tensor count")
    state_dict, offset = {}, 0
    for entry, (name, shape) in zip(header["tensors"], expected.items()):
        stored = (1, 1, 1, shape[1]) if name.endswith(".beta") else (shape[2], shape[3], shape[1], shape[0]) if len(shape) == 4 else shape
        size = math.prod(shape)*2
        if entry != dict(name=name, dtype="f16", shape=list(stored), offset=offset, size=size):
            raise ValueError(f"noncanonical export entry:{name}")
        value = np.frombuffer(raw, dtype="<f2", count=math.prod(shape), offset=start+offset).reshape(stored)
        value = value.reshape(shape) if name.endswith(".beta") else value.transpose(3, 2, 0, 1) if len(shape) == 4 else value
        state_dict[name] = torch.from_numpy(value.astype(np.float32).copy())
        if not torch.isfinite(state_dict[name]).all():
            raise ValueError(f"nonfinite exported tensor:{name}")
        offset += size
    if start+offset != len(raw) or any(raw[12+length:start]):
        raise ValueError("unexpected export payload or padding")
    return state_dict


def export(state_dict, lab_root, output, *, source_sha256, trained, extra=None):
    """Strict128-tensor FP16 RMW2 export and weights-only-loadable checkpoint."""
    expected = schema(lab_root)
    if set(state_dict) != set(expected):
        raise ValueError("expected exactly128 four-stage tensors")
    blob, entries = bytearray(), []
    checkpoint_state = {}
    for name, shape in expected.items():
        value = state_dict[name].detach().cpu()
        if tuple(value.shape) != shape or not torch.isfinite(value).all():
            raise ValueError(f"invalid or nonfinite tensor:{name}")
        array = value.half().numpy()
        if name.endswith(".beta"):
            array = array.reshape(1, 1, 1, -1)
        elif len(shape) == 4:
            array = array.transpose(2, 3, 1, 0)
        array = np.ascontiguousarray(array, dtype="<f2")
        if not np.isfinite(array).all():
            raise ValueError(f"FP16 overflow:{name}")
        entries.append(dict(name=name, dtype="f16", shape=list(array.shape),
                            offset=len(blob), size=array.nbytes))
        blob.extend(array.tobytes())
        checkpoint_state[name] = value.clone()
    header = dict(model=GRAPH_ID, graph_id=GRAPH_ID, mask_update="accumulate",
                  ifblock_channels=list(CHANNELS), scale_list=list(SCALES),
                  input_layout="NHWC", tensors=entries)
    encoded = json.dumps(header, sort_keys=True, allow_nan=False).encode()
    prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
    output = Path(output).with_suffix(".rmw")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(prefix + b"\0" * (-len(prefix) % 16) + blob)
    checkpoint = output.with_suffix(".pt")
    torch.save(dict(format=FORMAT, graph_id=GRAPH_ID, mask_update="accumulate",
                    source_sha256=source_sha256, trained=bool(trained),
                    state_dict=checkpoint_state), checkpoint)
    report = dict(graph_id=GRAPH_ID, source_sha256=source_sha256, trained=bool(trained),
                  stages=4, tensors=len(entries), mask_update="accumulate", tier="fast",
                  weights=str(output), weights_sha256=sha(output), checkpoint=str(checkpoint),
                  checkpoint_sha256=sha(checkpoint), exporter_sha256=sha(__file__),
                  quality_accepted=False, product_FPS_accepted=False)
    if extra:
        if set(extra) & set(report):
            raise ValueError("extra metadata overlaps canonical export fields")
        report.update(extra)
    output.with_suffix(".manifest.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return report
