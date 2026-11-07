"""CPU schema/algebra/serialization checks; no real frames or model forwards."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model


LAB_ROOT = os.environ.get("ODF_VFI_LAB_ROOT")


class SchemaTests(unittest.TestCase):
    def test_primary_schema_has_exact_ranks_folded_branches_and_parameter_total(self):
        shapes = model.schema()
        self.assertEqual(len(shapes), 158)
        self.assertEqual(sum(math.prod(s) for s in shapes.values()), 5_500_168)
        self.assertEqual(shapes["block3.convblock.0.conv_a.weight"], (32, 64, 3, 3))
        self.assertEqual(shapes["block4.convblock.7.conv_b.weight"], (32, 16, 1, 1))
        self.assertEqual(shapes["block4.convblock.7.conv_b.bias"], (32,))
        self.assertNotIn("block3.convblock.0.beta", shapes)
        self.assertNotIn("block3.convblock.0.conv_a.bias", shapes)
        self.assertEqual(shapes["block2.convblock.0.beta"], (1, 96, 1, 1))
        self.assertNotIn(model.GRAPH_ID, model._algebra_module().GRAPHS)
        with self.assertRaisesRegex(ValueError, "unsupported student ranks"):
            model.schema((16, 8))

    def test_stage_helper_uses_actual_forward_contract_and_retains_trace_objects(self):
        rgb = object()
        flow = torch.tensor(1.0, requires_grad=True)
        mask, feat = object(), object()
        calls = []

        def fake(first, second, **kwargs):
            calls.append((first, second, kwargs))
            for stage in range(5):
                kwargs["trace"](stage, flow, mask, feat)
            return rgb

        actual, stages = model.forward_with_stages(fake, "first", "second", 0.25, "fast")
        self.assertIs(actual, rgb)
        self.assertEqual(set(stages), set(range(5)))
        self.assertIs(stages[3][0], flow)
        self.assertTrue(stages[3][0].requires_grad)
        self.assertEqual(calls[0][:2], ("first", "second"))
        self.assertEqual(calls[0][2]["mask_update"], "accumulate")
        self.assertEqual(calls[0][2]["timestep"], 0.25)
        self.assertEqual(calls[0][2]["tier"], "fast")


class ModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LAB_ROOT:
            raise unittest.SkipTest("pass --lab-root or set ODF_VFI_LAB_ROOT")
        cls.rmw, cls.ifnet = model.load_lab(LAB_ROOT)
        gen = torch.Generator(device="cpu").manual_seed(20261106)
        original = {n: torch.zeros(s, dtype=torch.float32) for n, s in cls.rmw.state_schema().items()}
        # Synthetic weights only. Nontrivial beta signs and zero beta expose an
        # incorrect fold of the bias or an accidental surviving outer beta.
        for stage in (3, 4):
            c = model.CHANNELS[stage]
            for layer in range(8):
                p = f"block{stage}.convblock.{layer}."
                original[p + "conv.weight"] = torch.randn(c, c, 3, 3, generator=gen) * 0.02
                original[p + "conv.bias"] = torch.randn(c, generator=gen) * 0.03
                beta = torch.linspace(-0.8, 1.2, c).reshape(1, c, 1, 1)
                beta[:, 0] = 0
                original[p + "beta"] = beta
        for name in ("encode.cnn0.weight", "encode.cnn3.weight", "block2.convblock.0.beta"):
            original[name] = torch.arange(math.prod(original[name].shape), dtype=torch.float32).reshape_as(
                original[name]) * 0.0001
        cls.source = cls.rmw.Weights(model.BASE_MODEL, original)
        cls.state, cls.rows = model.initialize(cls.source, LAB_ROOT)
        cls.diagnostic, _ = model.initialize(cls.source, LAB_ROOT, ranks=(64, 32))

    def test_initialize_preserves_all_unfactored_original_tensors_exactly(self):
        self.assertEqual(len(self.rows), 16)
        self.assertEqual({r["rank"] for r in self.rows}, {32, 16})
        self.assertEqual(model.schema(), model._algebra_module().schema(self.rmw, model._algebra_module().STUDENT))
        for name, tensor in self.source.state_dict.items():
            if name.startswith(("block3.convblock.", "block4.convblock.")):
                continue
            self.assertTrue(torch.equal(self.state[name], tensor), name)
            self.assertNotEqual(self.state[name].data_ptr(), tensor.data_ptr(), name)
        self.assertIn("block3.convblock.0.beta", self.source.state_dict)
        self.assertNotIn("block3.convblock.0.beta", self.state)

    def test_full_rank_algebra_preserves_beta_weight_and_bias_without_forward(self):
        for stage in (3, 4):
            c = model.CHANNELS[stage]
            for layer in range(8):
                p = f"block{stage}.convblock.{layer}."
                original = self.source.state_dict
                effective = original[p + "beta"].reshape(c, 1).double() * original[p + "conv.weight"].double().reshape(c, -1)
                a = self.diagnostic[p + "conv_a.weight"].reshape(c, -1)
                b = self.diagnostic[p + "conv_b.weight"].reshape(c, c)
                torch.testing.assert_close(b @ a, effective, rtol=1e-10, atol=1e-11)
                bias = original[p + "beta"].reshape(c).double() * original[p + "conv.bias"].double()
                torch.testing.assert_close(self.diagnostic[p + "conv_b.bias"], bias, rtol=0, atol=0)
                self.assertEqual(float(self.diagnostic[p + "conv_b.bias"][0]), 0)

    def test_only_16_factor_pairs_and_output_biases_are_trainable(self):
        net = model.student(self.state, LAB_ROOT)
        names = model.trainable_names(net)
        expected = {f"block{s}.convblock.{j}.{suffix}"
                    for s in (3, 4) for j in range(8)
                    for suffix in ("conv_a.weight", "conv_b.weight", "conv_b.bias")}
        self.assertEqual(set(names), expected)
        self.assertEqual(len(names), 48)
        self.assertEqual(sum(p.numel() for p in net.parameters() if p.requires_grad), 205_568)
        self.assertEqual(net.graph_id, model.GRAPH_ID)
        self.assertEqual(net.mask_update, "accumulate")
        self.assertFalse(net.training)
        loaded = net.state_dict()
        for name, tensor in self.state.items():
            self.assertTrue(torch.equal(loaded[name], tensor.float()), name)
        for stage in (3, 4):
            self.assertEqual(len(getattr(net, f"block{stage}").convblock), 8)
            for branch in getattr(net, f"block{stage}").convblock:
                self.assertEqual(list(branch._modules), ["conv_a", "conv_b"])
                self.assertIsNone(branch.conv_a.bias)
                self.assertFalse(hasattr(branch, "beta"))

    def test_teacher_is_frozen_and_both_networks_reject_replace_before_computation(self):
        teacher = model.teacher(self.source, LAB_ROOT)
        self.assertEqual(model.trainable_names(teacher), [])
        self.assertEqual(teacher.model_identity, "rife-v4.25")
        for net in (teacher, model.student(self.state, LAB_ROOT)):
            with self.assertRaisesRegex(ValueError, "requires accumulate"):
                net.estimate(None, None, 0.5, mask_update="replace")
            with self.assertRaisesRegex(ValueError, "requires accumulate"):
                net.forward(None, None, mask_update="replace")
            with mock.patch.object(self.ifnet.IFNetStudent, "estimate", return_value=("flow", "mask")) as estimate:
                self.assertEqual(net.estimate("first", "second", 0.3), ("flow", "mask"))
                self.assertEqual(estimate.call_args.kwargs["mask_update"], "accumulate")
            with mock.patch.object(self.ifnet.IFNetStudent, "forward", return_value="rgb") as forward:
                self.assertEqual(net.forward("first", "second", tier="balanced", timestep=0.25), "rgb")
                self.assertEqual(forward.call_args.kwargs["mask_update"], "accumulate")
                self.assertEqual(forward.call_args.kwargs["tier"], "balanced")

    def test_original_426_and_invalid_student_schema_are_rejected(self):
        wrong = self.rmw.Weights("rife-v4.26", self.source.state_dict)
        with self.assertRaisesRegex(ValueError, "original rife-v4.25"):
            model.initialize(wrong, LAB_ROOT)
        with self.assertRaisesRegex(ValueError, "original rife-v4.25"):
            model.teacher(wrong, LAB_ROOT)
        bad = dict(self.state)
        bad.pop("encode.cnn0.bias")
        with self.assertRaisesRegex(ValueError, "missing or extra"):
            model.student(bad, LAB_ROOT)
        bad = dict(self.state)
        bad["block3.convblock.0.conv_a.weight"] = bad["block3.convblock.0.conv_a.weight"][:16]
        with self.assertRaisesRegex(ValueError, "unsupported student ranks"):
            model.student(bad, LAB_ROOT)

    def test_export_roundtrip_is_native_rmw2_and_safe_checkpoint_for_both_graphs(self):
        with tempfile.TemporaryDirectory() as folder:
            for graph, state, ranks in ((model.GRAPH_ID, self.state, (32, 16)),
                                        (model.DIAGNOSTIC_GRAPH_ID, self.diagnostic, (64, 32))):
                path = Path(folder) / f"{graph}.rmw"
                manifest = model.export(state, "a" * 64, path, trained=False,
                                        extra_manifest={"unit_test_synthetic_weights": True})
                raw = path.read_bytes()
                self.assertEqual(raw[:4], b"RMW1")
                version, length = struct.unpack_from("<II", raw, 4)
                self.assertEqual(version, 2)
                end = 12 + length
                start = (end + 15) // 16 * 16
                self.assertEqual(raw[end:start], b"\0" * (start - end))
                header = json.loads(raw[12:end])
                self.assertEqual(set(header), {"model", "graph_id", "mask_update", "ifblock_channels",
                                               "scale_list", "input_layout", "tensors"})
                self.assertEqual(header["model"], graph)
                self.assertEqual(header["graph_id"], graph)
                self.assertEqual(header["mask_update"], "accumulate")
                self.assertEqual(header["ifblock_channels"], [192, 128, 96, 64, 32])
                self.assertEqual(header["scale_list"], [16, 8, 4, 2, 1])
                self.assertEqual(header["input_layout"], "NHWC")
                offset = 0
                for (name, shape), entry in zip(model.schema(ranks).items(), header["tensors"]):
                    native_shape = ((1, 1, 1, shape[1]) if name.endswith(".beta") else
                                    (shape[2], shape[3], shape[1], shape[0]) if len(shape) == 4 else shape)
                    size = math.prod(shape) * 2
                    self.assertEqual(entry, dict(name=name, dtype="f16", shape=list(native_shape), offset=offset, size=size))
                    array = np.frombuffer(raw, dtype="<f2", count=size // 2, offset=start + offset).reshape(native_shape)
                    if name.endswith(".beta"):
                        tensor = torch.from_numpy(array.copy()).reshape(shape)
                    elif len(shape) == 4:
                        tensor = torch.from_numpy(array.transpose(3, 2, 0, 1).copy())
                    else:
                        tensor = torch.from_numpy(array.copy())
                    self.assertTrue(torch.equal(tensor, state[name].half()), name)
                    # Independent coordinate check of ordinary and transposed
                    # convolutions; both use the same existing native permutation.
                    if name in ("encode.cnn0.weight", "encode.cnn3.weight"):
                        self.assertEqual(float(array[1, 2, 1, 3]), float(state[name].half()[3, 1, 1, 2]))
                    offset += size
                self.assertEqual(len(header["tensors"]), 158)
                self.assertEqual(start + offset, len(raw))
                checkpoint = torch.load(path.with_suffix(".pt"), map_location="cpu", weights_only=True)
                self.assertEqual(checkpoint["format"], model.CHECKPOINT_FORMAT)
                self.assertEqual(checkpoint["graph_id"], graph)
                self.assertEqual(checkpoint["mask_update"], "accumulate")
                self.assertEqual(checkpoint["source_sha256"], "a" * 64)
                for name, tensor in state.items():
                    self.assertTrue(torch.equal(checkpoint["state_dict"][name], tensor), name)
                sidecar = json.loads(path.with_suffix(".manifest.json").read_text())
                self.assertEqual(sidecar, manifest)
                self.assertEqual(sidecar["weights_sha256"], model.sha(path))
                self.assertEqual(sidecar["checkpoint_sha256"], model.sha(path.with_suffix(".pt")))
                self.assertFalse(sidecar["quality_accepted"])
                with self.assertRaisesRegex(self.rmw.RMWError, "unsupported RMW version"):
                    model.initialize(path, LAB_ROOT)

    def test_export_rejects_nonfinite_overflow_and_contract_overrides(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.rmw"
            for value, error in ((float("nan"), "nonfinite"), (100_000.0, "FP16 overflow")):
                bad = dict(self.state)
                bad["encode.cnn0.bias"] = torch.full((16,), value)
                with self.assertRaisesRegex(ValueError, error):
                    model.export(bad, "a" * 64, path, trained=False)
                self.assertFalse(path.exists())
            with self.assertRaisesRegex(ValueError, "cannot override contract fields"):
                model.export(self.state, "a" * 64, path, False,
                             extra_manifest={"mask_update": "replace"})
            self.assertFalse(path.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab-root", required=True)
    args, remaining = parser.parse_known_args()
    LAB_ROOT = args.lab_root
    torch.set_num_threads(2)
    unittest.main(argv=[__file__, *remaining])
