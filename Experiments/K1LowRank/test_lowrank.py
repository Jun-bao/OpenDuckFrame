"""Focused algebra and reference-graph checks, independent of video acceptance."""
import argparse
import unittest

import torch
from torch.nn import functional as F

import lowrank as lr


class AlgebraTests(unittest.TestCase):
    def test_full_rank_preserves_folded_bias_skip_and_nonlinearity(self):
        gen = torch.Generator().manual_seed(34)
        for channels in (4, 8):
            w = torch.randn(channels, channels, 3, 3, generator=gen, dtype=torch.float64)
            b = torch.randn(channels, generator=gen, dtype=torch.float64)
            beta = torch.randn(1, channels, 1, 1, generator=gen, dtype=torch.float64)
            beta[:, 0] = 0  # nonzero bias with zero beta must also vanish
            a, up, bias, _ = lr.factorize(w, b, beta, channels)
            x = torch.randn(1, channels, 9, 11, generator=gen, dtype=torch.float64)
            expected = F.leaky_relu(F.conv2d(x, w, b, padding=1) * beta + x, 0.2)
            actual = F.leaky_relu(F.conv2d(F.conv2d(x, a, padding=1), up, bias) + x, 0.2)
            torch.testing.assert_close(expected, actual, rtol=1e-10, atol=1e-10)

    def test_half_rank_matches_svd_tail(self):
        gen = torch.Generator().manual_seed(52)
        w = torch.randn(8, 8, 3, 3, generator=gen, dtype=torch.float64)
        a, b, _, row = lr.factorize(w, torch.zeros(8), torch.ones(1, 8, 1, 1), 4)
        error = (w.reshape(8, -1) - b.reshape(8, 4) @ a.reshape(4, -1)).square().sum()
        tail = sum(s * s for s in row["singular_values"][4:])
        self.assertAlmostEqual(float(error), tail, places=9)


class GraphTests(unittest.TestCase):
    def test_explicit_schema_and_reference_mask_contract(self):
        base = self.rmw.read_rmw(self.source)
        state, _ = lr.initialize(self.rmw, base, lr.STUDENT)
        schema = lr.schema(self.rmw, lr.STUDENT)
        self.assertEqual(len(schema), 158)
        self.assertEqual(sum(t.numel() for t in state.values()), 5500168)
        self.assertNotIn("block3.convblock.0.beta", schema)
        self.assertEqual(schema["block3.convblock.0.conv_a.weight"], (32, 64, 3, 3))
        net = lr.reference(self.ifnet, lr.STUDENT, state)
        x = torch.zeros(1, 3, 64, 64)
        with self.assertRaisesRegex(ValueError, "replace"):
            net.estimate(x, x, 0.3, mask_update="accumulate")
        with torch.inference_mode():
            y = net(x, x, timestep=0.3)
        self.assertEqual(y.shape, x.shape)
        self.assertTrue(torch.isfinite(y).all())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--lab-root", required=True)
    ap.add_argument("--source", required=True)
    args, extra = ap.parse_known_args()
    torch.set_num_threads(4)
    GraphTests.rmw, GraphTests.ifnet = lr.load_lab(args.lab_root)
    GraphTests.source = args.source
    unittest.main(argv=[__file__, *extra])
