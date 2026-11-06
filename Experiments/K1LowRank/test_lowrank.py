"""Focused algebra and reference-graph checks, independent of video acceptance."""
import argparse
import unittest

import torch
from torch.nn import functional as F

import lowrank as lr
from materialize import materialize, fold_original


class AlgebraTests(unittest.TestCase):
    def test_patch_order_matches_beta_folded_convolution_including_padding(self):
        gen = torch.Generator().manual_seed(120)
        x = torch.randn(1, 4, 9, 11, generator=gen, dtype=torch.float64)
        w = torch.randn(4, 4, 3, 3, generator=gen, dtype=torch.float64)
        bias = torch.randn(4, generator=gen, dtype=torch.float64)
        beta = torch.randn(4, generator=gen, dtype=torch.float64)
        z = F.unfold(x, 3, padding=1)[0]
        response = (beta[:, None] * w.reshape(4, -1)) @ z + (beta * bias)[:, None]
        expected = F.conv2d(x, w, bias, padding=1) * beta.reshape(1, 4, 1, 1)
        torch.testing.assert_close(response.reshape_as(expected), expected, rtol=1e-12, atol=1e-12)

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

    def test_response_weighting_improves_its_declared_objective(self):
        gen = torch.Generator().manual_seed(83)
        w = torch.randn(8, 8, 3, 3, generator=gen, dtype=torch.float64)
        q = torch.diag(torch.logspace(-4, 3, 72, dtype=torch.float64))
        args = (w, torch.randn(8, generator=gen), torch.ones(1, 8, 1, 1), 4)
        a, b, bias, row = lr.factorize_response(*args, q)
        a0, b0, _, _ = lr.factorize(*args)
        m = w.reshape(8, -1)
        def loss(down, up):
            delta = m - up.half().double().reshape(8, 4) @ down.half().double().reshape(4, -1)
            return torch.trace(delta @ q @ delta.T)
        self.assertLess(float(loss(a, b)), float(loss(a0, b0)))
        self.assertAlmostEqual(row["response_relative_mse_fp16_weights"], float(loss(a, b) / torch.trace(m @ q @ m.T)))
        torch.testing.assert_close(bias, args[1].double())

    def test_response_factorization_full_rank_and_regularized_tail(self):
        gen = torch.Generator().manual_seed(111)
        w = torch.randn(4, 4, 3, 3, generator=gen, dtype=torch.float64)
        z = torch.randn(36, 48, generator=gen, dtype=torch.float64)
        q = z @ z.T / z.shape[1]
        args = (w, torch.zeros(4), torch.ones(1, 4, 1, 1))
        full_a, full_b, _, _ = lr.factorize_response(*args, 4, q)
        m = w.reshape(4, -1)
        torch.testing.assert_close(full_b.reshape(4, 4) @ full_a.reshape(4, -1), m, rtol=1e-10, atol=1e-10)
        a, b, _, _ = lr.factorize_response(*args, 2, q)
        delta = m - b.reshape(4, 2) @ a.reshape(2, -1)
        reg = q + 1e-5 * q.trace() / q.shape[0] * torch.eye(q.shape[0])
        vals, vectors = torch.linalg.eigh(reg)
        root = (vectors * vals.sqrt()) @ vectors.T
        tail = torch.linalg.svdvals(m @ root)[2:].square().sum()
        torch.testing.assert_close(torch.trace(delta @ reg @ delta.T), tail, rtol=1e-10, atol=1e-10)
        with self.assertRaisesRegex(ValueError, "positive response energy"):
            lr.factorize_response(*args, 2, torch.zeros_like(q))


class GraphTests(unittest.TestCase):
    def test_original_beta_fold_has_no_rank_approximation(self):
        base = self.rmw.read_rmw(self.source)
        state, rows = fold_original(base, (0, 1, 2, 3, 4))
        self.assertEqual(len(rows), 40)
        for stage in range(5):
            for layer in range(8):
                p = f"block{stage}.convblock.{layer}."
                beta = base.state_dict[p + "beta"].double()
                c = beta.numel()
                expected = (beta.reshape(c, 1, 1, 1) * base.state_dict[p + "conv.weight"].double()).half().float()
                self.assertTrue(torch.equal(state[p + "conv.weight"], expected))
                self.assertTrue(torch.equal(state[p + "beta"], torch.ones_like(beta)))
        self.assertEqual(set(state), set(lr.schema(self.rmw, lr.MATERIALIZED)))

    def test_materialized_probe_uses_exported_factors_and_retains_untouched_weights(self):
        base = self.rmw.read_rmw(self.source)
        graph = list(lr.GRAPHS)[3]
        factors, _ = lr.initialize(self.rmw, base, graph)
        state, rows = materialize(base, dict(graph_id=graph, state_dict=factors))
        self.assertEqual(set(state), set(lr.schema(self.rmw, lr.MATERIALIZED)))
        self.assertEqual(len(rows), 8)
        for name in base.state_dict:
            if not name.startswith("block4.convblock."):
                self.assertTrue(torch.equal(state[name], base.state_dict[name]))
        for layer in range(8):
            p = f"block4.convblock.{layer}."
            down = factors[p + "conv_a.weight"].half().double().reshape(16, -1)
            up = factors[p + "conv_b.weight"].half().double().reshape(32, 16)
            expected = (up @ down).reshape(32, 32, 3, 3).half().float()
            self.assertTrue(torch.equal(state[p + "conv.weight"], expected))
            self.assertTrue(torch.equal(state[p + "beta"], torch.ones(1, 32, 1, 1)))
        model = lr.reference(self.ifnet, lr.MATERIALIZED, state)
        with torch.inference_mode():
            x = torch.zeros(1, 3, 64, 64)
            self.assertTrue(torch.isfinite(model(x, x)).all())

    def test_partial_graph_retains_the_other_dense_stage_exactly(self):
        base = self.rmw.read_rmw(self.source)
        for graph, dense_stage in ((list(lr.GRAPHS)[2], 4), (list(lr.GRAPHS)[3], 3)):
            state, _ = lr.initialize(self.rmw, base, graph)
            for key in base.state_dict:
                if key.startswith(f"block{dense_stage}."):
                    self.assertTrue(torch.equal(state[key], base.state_dict[key]), key)
            net = lr.reference(self.ifnet, graph, state)
            with torch.inference_mode():
                out = net(torch.zeros(1, 3, 64, 64), torch.zeros(1, 3, 64, 64), timestep=0.5)
            self.assertTrue(torch.isfinite(out).all())

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
