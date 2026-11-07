"""Block4-only C16/C24 IFNet 4.25 candidates with accumulation-mask semantics.

Keep the eight dense residual layers and the original encoder/block0..3.
RMW version 2 uses the existing RMW1 magic and a distinct model/graph identity.
Paths to the read-only reference implementation, weights and data are CLI inputs.
"""
from __future__ import annotations

import argparse
from collections.abc import Mapping
from dataclasses import dataclass
import hashlib
import importlib
import json
import math
from pathlib import Path
import struct
import sys
import time

import numpy as np
from PIL import Image
import torch


GRAPHS = {f"odf-ifnet425-b4c{c}-accumulate-v1": c for c in (16, 24)}
SCALES = (16, 8, 4, 2, 1)
TRAIN_CLIPS = ("park_joy", "crowd_run", "ducks_take_off")
DIAGNOSTIC_CLIPS = ("in_to_tree", "old_town_cross")
HEADER_KEYS = {"model", "graph_id", "mask_update", "ifblock_channels",
               "scale_list", "input_layout", "tensors"}
CHECKPOINT_FORMAT = "odf-ifnet425-narrow-state-v1"


class NarrowError(ValueError):
    """Invalid candidate graph, state or data contract."""


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_lab(root):
    sys.path.insert(0, str(Path(root).resolve()))
    return importlib.import_module("rmw"), importlib.import_module("ifnet")


def channels(graph):
    try:
        return (192, 128, 96, 64, GRAPHS[graph])
    except (KeyError, TypeError) as error:
        raise NarrowError(f"unsupported graph: {graph!r}") from error


def schema(graph):
    """158 PyTorch tensors in the original RMW canonical order."""
    shapes = {}
    for i, shape in enumerate(((16, 3, 3, 3), (16, 16, 3, 3),
                               (16, 16, 3, 3), (16, 4, 4, 4))):
        shapes[f"encode.cnn{i}.weight"] = shape
        shapes[f"encode.cnn{i}.bias"] = (4 if i == 3 else 16,)
    for i, (c, inputs) in enumerate(zip(channels(graph), (15, 28, 28, 28, 28))):
        p = f"block{i}"
        shapes[f"{p}.conv0.0.0.weight"] = (c // 2, inputs, 3, 3)
        shapes[f"{p}.conv0.0.0.bias"] = (c // 2,)
        shapes[f"{p}.conv0.1.0.weight"] = (c, c // 2, 3, 3)
        shapes[f"{p}.conv0.1.0.bias"] = (c,)
        for j in range(8):
            base = f"{p}.convblock.{j}"
            shapes[f"{base}.conv.weight"] = (c, c, 3, 3)
            shapes[f"{base}.conv.bias"] = (c,)
            shapes[f"{base}.beta"] = (1, c, 1, 1)
        shapes[f"{p}.lastconv.0.weight"] = (c, 52, 4, 4)
        shapes[f"{p}.lastconv.0.bias"] = (52,)
    return shapes


def rmw_shape(name, shape):
    if name.endswith(".beta"):
        return (1, 1, 1, shape[1])
    # ConvTranspose [I,O,H,W] uses the SAME permutation as Conv2d [O,I,H,W].
    return (shape[2], shape[3], shape[1], shape[0]) if len(shape) == 4 else shape


def validate_state(graph, state):
    expected = schema(graph)
    if not isinstance(state, Mapping) or set(state) != set(expected):
        raise NarrowError("state must contain exactly the 158 canonical tensors")
    for name, shape in expected.items():
        x = state[name]
        if (not isinstance(x, torch.Tensor) or tuple(x.shape) != shape
                or not x.is_floating_point() or x.layout != torch.strided):
            raise NarrowError(f"invalid tensor/shape: {name}; expected {shape}")
        if not torch.isfinite(x).all():
            raise NarrowError(f"nonfinite tensor: {name}")


def dumps_rmw(graph, state):
    validate_state(graph, state)
    blob, entries = bytearray(), []
    for name in schema(graph):
        x = state[name].detach().cpu().half().numpy()
        if name.endswith(".beta"):
            x = x.reshape(1, 1, 1, -1)
        elif x.ndim == 4:
            x = x.transpose(2, 3, 1, 0)
        x = np.ascontiguousarray(x, dtype="<f2")
        if not np.isfinite(x).all():
            raise NarrowError(f"FP16 overflow: {name}")
        entries.append(dict(name=name, dtype="f16", shape=list(x.shape),
                            offset=len(blob), size=x.nbytes))
        blob.extend(x.tobytes())
    header = dict(model=graph, graph_id=graph, mask_update="accumulate",
                  ifblock_channels=list(channels(graph)), scale_list=list(SCALES),
                  input_layout="NHWC", tensors=entries)
    encoded = json.dumps(header, sort_keys=True, allow_nan=False).encode("utf-8")
    prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
    return prefix + b"\0" * (-len(prefix) % 16) + blob


def _unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise NarrowError(f"duplicate JSON key: {key}")
        out[key] = value
    return out


def _json_exact(actual, expected):
    # Python equality otherwise treats True == 1 and 16.0 == 16 as equal.
    return json.dumps(actual, sort_keys=True, allow_nan=False) == json.dumps(expected, sort_keys=True)


@dataclass
class Weights:
    graph_id: str
    state_dict: dict[str, torch.Tensor]


def loads_rmw(data):
    if len(data) < 12 or data[:4] != b"RMW1":
        raise NarrowError("missing RMW1 magic")
    version, length = struct.unpack_from("<II", data, 4)
    if version != 2:
        raise NarrowError("narrow graphs require RMW version 2")
    header_end = 12 + length
    blob_start = (header_end + 15) // 16 * 16
    if blob_start > len(data):
        raise NarrowError("truncated header/padding")
    try:
        header = json.loads(data[12:header_end].decode("utf-8"),
                            object_pairs_hook=_unique_object,
                            parse_constant=lambda x: (_ for _ in ()).throw(NarrowError(f"invalid JSON: {x}")))
    except (ValueError, UnicodeDecodeError) as error:
        raise NarrowError("invalid JSON header") from error
    if not isinstance(header, dict) or set(header) != HEADER_KEYS:
        raise NarrowError("expected exactly seven header keys")
    graph = header["graph_id"]
    expected_header = dict(model=graph, graph_id=graph, mask_update="accumulate",
                           ifblock_channels=list(channels(graph)), scale_list=list(SCALES),
                           input_layout="NHWC", tensors=header["tensors"])
    if not _json_exact(header, expected_header):
        raise NarrowError("invalid graph/model/mask/layout/channels/scales contract")
    if any(data[header_end:blob_start]):
        raise NarrowError("padding must be zero")
    entries = header["tensors"]
    if not isinstance(entries, list) or len(entries) != 158:
        raise NarrowError("expected exactly 158 tensor entries")
    state, offset = {}, 0
    for (name, shape), entry in zip(schema(graph).items(), entries):
        size = math.prod(shape) * 2
        expected = dict(name=name, dtype="f16", shape=list(rmw_shape(name, shape)), offset=offset, size=size)
        if not _json_exact(entry, expected):
            raise NarrowError(f"invalid tensor entry: {name}")
        if blob_start + offset + size > len(data):
            raise NarrowError(f"truncated tensor: {name}")
        x = np.frombuffer(data, dtype="<f2", count=size // 2, offset=blob_start + offset).reshape(expected["shape"])
        if not np.isfinite(x).all():
            raise NarrowError(f"nonfinite FP16 data: {name}")
        if name.endswith(".beta"):
            x = x.reshape(shape)
        elif len(shape) == 4:
            x = x.transpose(3, 2, 0, 1)
        state[name] = torch.from_numpy(np.array(x, dtype=np.float16, order="C", copy=True))
        offset += size
    if blob_start + offset != len(data):
        raise NarrowError("unexpected trailing bytes")
    return Weights(graph, state)


def read_rmw(path):
    return loads_rmw(Path(path).read_bytes())


def export_rmw(graph, state, output):
    data = dumps_rmw(graph, state)
    Path(output).write_bytes(data)
    return read_rmw(output)


def save_checkpoint(path, graph, state, *, source_sha256):
    validate_state(graph, state)
    # Tensor + primitive-only wrapper, loadable with weights_only=True.
    torch.save(dict(format=CHECKPOINT_FORMAT, graph_id=graph, mask_update="accumulate",
                    source_sha256=source_sha256,
                    state_dict={n: state[n].detach().cpu().half().clone() for n in schema(graph)}), path)


def load_checkpoint(path):
    saved = torch.load(path, map_location="cpu", weights_only=True)
    keys = {"format", "graph_id", "mask_update", "source_sha256", "state_dict"}
    if (not isinstance(saved, dict) or set(saved) != keys or saved["format"] != CHECKPOINT_FORMAT
            or saved["mask_update"] != "accumulate"):
        raise NarrowError("invalid narrow checkpoint wrapper")
    digest = saved["source_sha256"]
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise NarrowError("invalid source SHA256")
    validate_state(saved["graph_id"], saved["state_dict"])
    return Weights(saved["graph_id"], saved["state_dict"]), digest


def reference(ifnet, graph, state):
    validate_state(graph, state)

    class NarrowStudent(ifnet.IFNetStudent):
        def estimate(self, first, second, timestep, *, mask_update="accumulate", trace=None):
            if mask_update != "accumulate":
                raise NarrowError("narrow graph requires accumulation-mask semantics")
            return super().estimate(first, second, timestep, mask_update="accumulate", trace=trace)

    net = NarrowStudent()
    net.block4 = ifnet.IFBlock(28, GRAPHS[graph])
    net.load_state_dict(state, strict=True)
    net.graph_id = net.model_identity = graph
    return net.eval()


def windows(manifest, clips=TRAIN_CLIPS, blocks=(0, 2)):
    """Reassemble each original five-frame window from its t0/t1 triplets."""
    path = Path(manifest).resolve()
    if "pilot-p01" in path.parts:
        raise NarrowError("reserved pilot-p01 data is outside this experiment")
    data = json.loads(path.read_text())
    result = []
    for clip in clips:
        if clip not in TRAIN_CLIPS + DIAGNOSTIC_CLIPS:
            raise NarrowError(f"clip outside development split: {clip}")
        for block in blocks:
            rows = [x for x in data["triplets"] if x["sequence"] == clip and x["block"] == block]
            if len(rows) != 2:
                raise NarrowError(f"expected t0/t1 triplets for {clip} block{block}")
            frames = {}
            for row in rows:
                for index, key in zip(row["source_frame_indices"], ("previous", "gt", "current")):
                    frame = Path(row[key])
                    if not frame.is_absolute():
                        frame = path.parent / frame
                    frame = frame.resolve()
                    if "pilot-p01" in frame.parts:
                        raise NarrowError("reserved pilot-p01 frame is outside this experiment")
                    if index in frames and frames[index] != frame:
                        raise NarrowError("inconsistent overlapping triplet frame")
                    frames[index] = frame
            indices = sorted(frames)
            if len(indices) != 5 or indices != list(range(indices[0], indices[0] + 5)):
                raise NarrowError("expected five consecutive original frames")
            result.append(dict(id=f"{clip}-b{block}", clip=clip, block=block,
                               source_frame_indices=indices, frames=[frames[i] for i in indices]))
    return result


def load_rgb(path):
    with Image.open(path) as image:
        array = np.array(image.convert("RGB"), dtype=np.float32, copy=True) / 255.0
    return torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0)


def calibrate(teacher, samples):
    sums = {"conv0_first": torch.zeros(16, dtype=torch.float64)}
    sums.update({f"res{j}": torch.zeros(32, dtype=torch.float64) for j in range(8)})
    counts = dict.fromkeys(sums, 0)

    def hook(key):
        def collect(_module, _inputs, output):
            sums[key].add_(output.detach().float().square().mean(dim=(0, 2, 3)).double().cpu())
            counts[key] += 1
        return collect

    handles = [teacher.block4.conv0[0].register_forward_hook(hook("conv0_first"))]
    handles += [layer.register_forward_hook(hook(f"res{j}")) for j, layer in enumerate(teacher.block4.convblock)]
    queries = []
    try:
        with torch.inference_mode():
            for sample in samples:
                first, second = (load_rgb(sample["frames"][i]) for i in (0, 4))
                for alpha in (0.25, 0.5, 0.75):
                    teacher(first, second, tier="fast", timestep=alpha, mask_update="accumulate")
                    queries.append(dict(window=sample["id"], alpha=alpha))
                print(json.dumps(dict(calibrated=sample["id"], queries=len(queries))), flush=True)
    finally:
        for handle in handles:
            handle.remove()
    if not queries or any(n != len(queries) for n in counts.values()):
        raise NarrowError("missing teacher calibration activations")
    energy = {k: sums[k] / counts[k] for k in sums}
    pooled = torch.stack([energy[f"res{j}"] for j in range(8)]).mean(dim=0)
    return dict(metric="mean squared post-LeakyReLU activation; spatial/batch mean, equal query mean",
                residual_pooling="equal mean over all eight ResConv outputs, shared channel indices",
                query_count=len(queries), queries=queries,
                first_channel_energy=energy["conv0_first"].tolist(),
                residual_layer_channel_energy={f"res{j}": energy[f"res{j}"].tolist() for j in range(8)},
                residual_pooled_channel_energy=pooled.tolist())


def select_channels(scores, count):
    if len(scores) < count or any(not math.isfinite(x) or x < 0 for x in scores):
        raise NarrowError("invalid calibration channel energies")
    ranked = sorted(range(len(scores)), key=lambda i: (-scores[i], i))[:count]
    # Preserve the source channel order inside every selected tensor.
    return sorted(ranked)


def initialize(source, graph, calibration):
    if source.model != "rife-v4.25":
        raise NarrowError("narrow graph is bound to the original rife-v4.25 weights")
    c = GRAPHS[graph]
    first = select_channels(calibration["first_channel_energy"], c // 2)
    residual = select_channels(calibration["residual_pooled_channel_energy"], c)
    a, b = torch.tensor(first), torch.tensor(residual)
    state = {n: t.detach().cpu().half().clone() for n, t in source.state_dict.items()}
    p = "block4."
    state[p + "conv0.0.0.weight"] = state[p + "conv0.0.0.weight"].index_select(0, a)
    state[p + "conv0.0.0.bias"] = state[p + "conv0.0.0.bias"].index_select(0, a)
    state[p + "conv0.1.0.weight"] = state[p + "conv0.1.0.weight"].index_select(0, b).index_select(1, a)
    state[p + "conv0.1.0.bias"] = state[p + "conv0.1.0.bias"].index_select(0, b)
    for j in range(8):
        base = p + f"convblock.{j}."
        state[base + "conv.weight"] = state[base + "conv.weight"].index_select(0, b).index_select(1, b)
        state[base + "conv.bias"] = state[base + "conv.bias"].index_select(0, b)
        state[base + "beta"] = state[base + "beta"].index_select(1, b)
    state[p + "lastconv.0.weight"] = state[p + "lastconv.0.weight"].index_select(0, b)
    validate_state(graph, state)
    return state, dict(first_channel_indices=first, residual_channel_indices=residual)


def unchanged_prefix(source, state):
    names = [n for n in source.state_dict if not n.startswith("block4.")]
    equal = sum(torch.equal(source.state_dict[n].cpu().half(), state[n].cpu().half()) for n in names)
    if equal != len(names):
        raise NarrowError("encoder or block0..3 changed")
    return dict(tensors=len(names), equal_fp16_tensors=equal, all_equal=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="CPU-only channel-energy calibration and untrained exports")
    init.add_argument("--lab-root", type=Path, required=True)
    init.add_argument("--source", type=Path, required=True)
    init.add_argument("--expected-source-sha256", required=True)
    init.add_argument("--data-manifest", type=Path, required=True)
    init.add_argument("--output-dir", type=Path, required=True)
    init.add_argument("--threads", type=int, default=4, choices=(4,))
    check = sub.add_parser("inspect", help="strict validation of an existing narrow RMW2 file")
    check.add_argument("source", type=Path)
    dump = sub.add_parser("schema", help="print canonical state/storage schema")
    dump.add_argument("graph", choices=GRAPHS)
    args = ap.parse_args(argv)
    if args.command == "schema":
        print(json.dumps(dict(graph_id=args.graph, tensors=[dict(name=n, pytorch_shape=s, rmw_shape=rmw_shape(n, s))
                                                           for n, s in schema(args.graph).items()]), indent=2))
        return 0
    if args.command == "inspect":
        weights = read_rmw(args.source)
        print(json.dumps(dict(graph_id=weights.graph_id, tensors=len(weights.state_dict), sha256=sha(args.source))))
        return 0
    torch.set_num_threads(args.threads)
    digest = sha(args.source)
    if digest != args.expected_source_sha256:
        raise NarrowError("source SHA256 does not match the authorized original")
    rmw, ifnet = load_lab(args.lab_root)
    source = rmw.read_rmw(args.source)
    if list(source.state_dict) != list(schema(next(iter(GRAPHS)))):
        raise NarrowError("reference canonical tensor order changed")
    samples = windows(args.data_manifest)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    teacher = ifnet.IFNetStudent.from_rmw(args.source, device="cpu", dtype=torch.float32)
    calibration = calibrate(teacher, samples)
    calibration.update(data_manifest_sha256=sha(args.data_manifest), source_sha256=digest,
                       tier="fast", mask_update="accumulate", cpu_threads=args.threads,
                       clips=list(TRAIN_CLIPS), blocks=[0, 2], endpoints=[0, 4], alphas=[0.25, 0.5, 0.75],
                       frames=[dict(window=s["id"], source_frame_indices=s["source_frame_indices"],
                                    files=[dict(path=str(p), sha256=sha(p)) for p in s["frames"]]) for s in samples])
    (args.output_dir / "calibration.json").write_text(json.dumps(calibration, indent=2, allow_nan=False) + "\n")
    for graph in GRAPHS:
        state, selection = initialize(source, graph, calibration)
        path = args.output_dir / (graph + ".rmw")
        decoded = export_rmw(graph, state, path)
        if any(not torch.equal(state[n], decoded.state_dict[n]) for n in schema(graph)):
            raise NarrowError("RMW2 roundtrip changed initialized FP16 values")
        save_checkpoint(path.with_suffix(".pt"), graph, state, source_sha256=digest)
        saved, saved_sha = load_checkpoint(path.with_suffix(".pt"))
        if saved_sha != digest or dumps_rmw(saved.graph_id, saved.state_dict) != path.read_bytes():
            raise NarrowError("safe checkpoint does not reproduce the RMW2 export")
        # Verify the reference graph accepts the exact 158 shapes; no quality claim.
        reference(ifnet, graph, decoded.state_dict)
        manifest = dict(graph_id=graph, model=graph, base_model=source.model, source_sha256=digest,
                        weights_sha256=sha(path), checkpoint_sha256=sha(path.with_suffix(".pt")),
                        calibration_sha256=sha(args.output_dir / "calibration.json"),
                        mask_update="accumulate", channels=list(channels(graph)), tensors=158,
                        parameter_count=sum(math.prod(s) for s in schema(graph).values()),
                        unchanged_prefix=unchanged_prefix(source, decoded.state_dict),
                        selection=selection, initialization="teacher activation energy, shared residual channel subset",
                        trained=False, quality_accepted=False, cost_accepted=False,
                        sources={n: sha(args.lab_root / n) for n in ("ifnet.py", "rmw.py")},
                        exporter_sha256=sha(__file__), elapsed_seconds=time.monotonic() - started)
        path.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
        print(json.dumps(manifest), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, NarrowError) as error:
        print(f"narrow: {error}", file=sys.stderr)
        raise SystemExit(2)
