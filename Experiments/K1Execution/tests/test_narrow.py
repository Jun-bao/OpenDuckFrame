"""Contract and CPU-only gradient checks; no training/optimizer or GPU use."""
from copy import deepcopy
from io import BytesIO
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import narrow
import narrow_train


def header_and_blob(data):
    size = struct.unpack_from("<I", data, 8)[0]
    end = 12 + size
    return json.loads(data[12:end]), data[(end + 15) // 16 * 16:]


def repack(header, blob):
    encoded = json.dumps(header, sort_keys=True).encode()
    prefix = b"RMW1" + struct.pack("<II", 2, len(encoded)) + encoded
    return prefix + b"\0" * (-len(prefix) % 16) + blob


class NarrowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(4)
        cls.graph = list(narrow.GRAPHS)[0]
        cls.state = {n: torch.zeros(s, dtype=torch.float16) for n, s in narrow.schema(cls.graph).items()}
        for name in ("encode.cnn3.weight", "block4.lastconv.0.weight"):
            cls.state[name] = torch.arange(cls.state[name].numel(), dtype=torch.float32).reshape(cls.state[name].shape).half()
        cls.state["block4.convblock.0.beta"] = torch.arange(16, dtype=torch.float16).reshape(1, 16, 1, 1)
        cls.data = narrow.dumps_rmw(cls.graph, cls.state)

    def test_canonical_shapes_and_layout(self):
        header, blob = header_and_blob(self.data)
        self.assertEqual(set(header), narrow.HEADER_KEYS)
        self.assertEqual(header["model"], self.graph)
        self.assertEqual(len(header["tensors"]), 158)
        self.assertEqual(header["mask_update"], "accumulate")
        self.assertEqual(narrow.schema(self.graph)["block4.conv0.0.0.weight"], (8, 28, 3, 3))
        c24 = list(narrow.GRAPHS)[1]
        self.assertEqual(narrow.schema(c24)["block4.conv0.1.0.weight"], (24, 12, 3, 3))
        for name in ("encode.cnn3.weight", "block4.lastconv.0.weight"):
            entry = next(e for e in header["tensors"] if e["name"] == name)
            actual = np.frombuffer(blob[entry["offset"]:entry["offset"] + entry["size"]], dtype="<f2").reshape(entry["shape"])
            np.testing.assert_array_equal(actual, self.state[name].numpy().transpose(2, 3, 1, 0))
        beta = next(e for e in header["tensors"] if e["name"] == "block4.convblock.0.beta")
        self.assertEqual(beta["shape"], [1, 1, 1, 16])

    def test_roundtrip_and_safe_checkpoint(self):
        restored = narrow.loads_rmw(self.data)
        self.assertEqual(narrow.dumps_rmw(restored.graph_id, restored.state_dict), self.data)
        for name in self.state:
            self.assertTrue(torch.equal(self.state[name], restored.state_dict[name]), name)
        # Exercise the exact primitive/tensor wrapper in memory with safe loading.
        buffer = BytesIO()
        narrow.save_checkpoint(buffer, self.graph, self.state, source_sha256="1" * 64)
        buffer.seek(0)
        saved, source_sha = narrow.load_checkpoint(buffer)
        self.assertEqual(source_sha, "1" * 64)
        self.assertEqual(narrow.dumps_rmw(saved.graph_id, saved.state_dict), self.data)

    def test_rejects_contract_and_table_mutations(self):
        original, blob = header_and_blob(self.data)
        edits = [
            lambda h: h.update(model="rife-v4.25"),
            lambda h: h.update(graph_id="unknown"),
            lambda h: h.update(mask_update="replace"),
            lambda h: h.update(extra=True),
            lambda h: h.update(input_layout="NCHW"),
            lambda h: h.update(ifblock_channels=[192, 128, 96, 64, 24]),
            lambda h: h.update(scale_list=[16, 8, 4, 2, 1.0]),
            lambda h: h["tensors"].pop(),
            lambda h: h["tensors"].append(h["tensors"][0]),
            lambda h: h["tensors"].__setitem__(slice(0, 2), list(reversed(h["tensors"][:2]))),
            lambda h: h["tensors"][0].update(offset=True),
            lambda h: h["tensors"][0].update(offset=-1),
            lambda h: h["tensors"][0].update(size=1),
            lambda h: h["tensors"][0].update(dtype="f32"),
            lambda h: h["tensors"][0].update(extra=True),
            lambda h: h["tensors"][0].update(shape=[3, 3, 3, 8]),
        ]
        for index, edit in enumerate(edits):
            with self.subTest(index=index):
                value = deepcopy(original)
                edit(value)
                with self.assertRaises(narrow.NarrowError):
                    narrow.loads_rmw(repack(value, blob))

    def test_rejects_prefix_duplicates_nonfinite_and_trailing(self):
        with self.assertRaises(narrow.NarrowError):
            narrow.loads_rmw(b"RMW2" + self.data[4:])
        with self.assertRaises(narrow.NarrowError):
            narrow.loads_rmw(self.data[:4] + struct.pack("<I", 1) + self.data[8:])
        for value in (self.data[:-1], self.data + b"\0"):
            with self.assertRaises(narrow.NarrowError):
                narrow.loads_rmw(value)
        header, blob = header_and_blob(self.data)
        damaged = bytearray(blob)
        damaged[:2] = np.array([np.nan], dtype="<f2").tobytes()
        with self.assertRaises(narrow.NarrowError):
            narrow.loads_rmw(repack(header, damaged))
        encoded = json.dumps(header).removesuffix("}") + ', "model": "' + self.graph + '"}'
        prefix = b"RMW1" + struct.pack("<II", 2, len(encoded.encode())) + encoded.encode()
        with self.assertRaises(narrow.NarrowError):
            narrow.loads_rmw(prefix + b"\0" * (-len(prefix) % 16) + blob)

    def test_initialization_slices_a_shared_residual_subspace(self):
        source_state = {n: t.clone() for n, t in self.state.items()}
        for name, shape in list(narrow.schema(self.graph).items()):
            if name.startswith("block4."):
                shape = tuple(32 if x == 16 else 16 if x == 8 else x for x in shape)
                # lastconv has dimension 4, never interpreted as a channel width.
                source_state[name] = torch.arange(np.prod(shape), dtype=torch.float32).reshape(shape).remainder(1024).half()
        source = SimpleNamespace(model="rife-v4.25", state_dict=source_state)
        calibration = dict(first_channel_energy=list(range(16)), residual_pooled_channel_energy=list(range(32)))
        state, choice = narrow.initialize(source, self.graph, calibration)
        self.assertEqual(choice["first_channel_indices"], list(range(8, 16)))
        self.assertEqual(choice["residual_channel_indices"], list(range(16, 32)))
        for layer in range(8):
            p = f"block4.convblock.{layer}."
            self.assertTrue(torch.equal(state[p + "conv.weight"], source_state[p + "conv.weight"][16:, 16:]))
            self.assertTrue(torch.equal(state[p + "beta"], source_state[p + "beta"][:, 16:]))
        self.assertTrue(torch.equal(state["block4.lastconv.0.weight"], source_state["block4.lastconv.0.weight"][16:]))
        self.assertEqual(narrow.unchanged_prefix(source, state)["equal_fp16_tensors"], 128)

    def test_cost_gate_and_lock_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "screen.json"
            path.write_text(json.dumps(dict(cost_screen_passed=True, graph_id=self.graph, weights_sha256="2" * 64)))
            self.assertEqual(len(narrow_train.validate_cost_screen(path, self.graph, "2" * 64)), 64)
            with self.assertRaises(narrow.NarrowError):
                narrow_train.validate_cost_screen(path, self.graph, "3" * 64)
            path.write_text(json.dumps(dict(cost_screen_passed=False, graph_id=self.graph, weights_sha256="2" * 64)))
            with self.assertRaises(narrow.NarrowError):
                narrow_train.validate_cost_screen(path, self.graph, "2" * 64)
            lock_path = Path(tmp) / "gpu.lock"
            with narrow_train.project_lock(lock_path):
                with self.assertRaises(narrow.NarrowError):
                    with narrow_train.project_lock(lock_path):
                        self.fail("second lock acquisition unexpectedly succeeded")
            with narrow_train.project_lock(lock_path):
                pass  # released even after the inner failure
            with self.assertRaises(KeyboardInterrupt):
                with narrow_train.project_lock(lock_path):
                    raise KeyboardInterrupt()
            with narrow_train.project_lock(lock_path):
                pass  # cancellation also releases the shared resource


@unittest.skipUnless(os.environ.get("NARROW_LAB_ROOT"), "set NARROW_LAB_ROOT for the read-only reference probe")
class RealReferenceCPUChecks(unittest.TestCase):
    """Small synthetic frames, forward/backward only; no optimizer or GPU."""

    def test_real_input_capture_render_and_rgb_gradient(self):
        torch.set_num_threads(4)
        _rmw, ifnet = narrow.load_lab(os.environ["NARROW_LAB_ROOT"])
        torch.manual_seed(7)
        teacher = ifnet.IFNetStudent().eval()
        teacher.model_identity = "rife-v4.25"
        first, second, gt = (torch.randint(0, 256, (1, 3, 48, 64)).float().div(255) for _ in range(3))
        cached = narrow_train.capture_teacher(teacher, first, second, gt, 0.25)
        item = narrow_train.to_device(cached, torch.device("cpu"), rgb=True)
        exact = narrow_train.render(ifnet, item, cached["target_delta"], cached["target_new_mask"])
        self.assertTrue(torch.equal(exact, cached["teacher_rgb"]))
        calibration = dict(first_channel_energy=list(range(16)), residual_pooled_channel_energy=list(range(32)))
        source = SimpleNamespace(model="rife-v4.25", state_dict=teacher.state_dict())
        for graph in narrow.GRAPHS:
            state, _ = narrow.initialize(source, graph, calibration)
            net = narrow.reference(ifnet, graph, state)
            net.requires_grad_(False)
            net.block4.requires_grad_(True)
            delta, mask, flow_loss, mask_loss = narrow_train.local_outputs(net.block4, item)
            output = narrow_train.render(ifnet, item, delta, mask)
            loss = torch.nn.functional.l1_loss(output, gt) + 0.01 * (flow_loss + 0.1 * mask_loss)
            loss.backward()
            self.assertEqual(output.shape, gt.shape)
            self.assertTrue(torch.isfinite(output).all())
            self.assertTrue(all(p.grad is None for n, p in net.named_parameters() if not n.startswith("block4.")))
            grads = [p.grad for p in net.block4.parameters() if p.grad is not None]
            self.assertTrue(grads and all(torch.isfinite(g).all() for g in grads))
            with self.assertRaises(narrow.NarrowError):
                net(first, second, tier="fast", mask_update="replace")


if __name__ == "__main__":
    unittest.main()
