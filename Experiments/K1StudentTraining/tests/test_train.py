"""CPU toy checks for the budget and gradient contract, without real IFNet."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import train


class TrainingContractTests(unittest.TestCase):
    def test_valid_flow_region_excludes_right_and_bottom_padding(self):
        rgb = torch.zeros(1, 3, 8, 12)
        flow = torch.ones(1, 4, 4, 4)
        mask = torch.ones(1, 1, 4, 4)
        flow[..., :2, :3] = 0
        mask[..., :2, :3] = 0
        actual = {i: (flow, mask, None) for i in (3, 4)}
        expected = {i: (torch.zeros_like(flow), torch.zeros_like(mask), None) for i in (3, 4)}
        terms = train.loss_terms(rgb, actual, rgb, expected, "fast")
        self.assertTrue(all(float(value) == 0 for value in terms.values()))

    def test_four_microbatches_match_one_mean_gradient(self):
        x, y = torch.tensor([1., 2., 3., 5.]), torch.tensor([2., 1., 7., 4.])
        accumulated = torch.tensor(0.75, requires_grad=True)
        batched = accumulated.detach().clone().requires_grad_()
        for a, b in zip(x, y):
            (((accumulated * a - b) ** 2) / 4).backward()
        ((batched * x - y).square().mean()).backward()
        torch.testing.assert_close(accumulated.grad, batched.grad)

    def test_deadline_is_checked_after_image_loading_before_teacher(self):
        class Net:
            training = True
            def eval(self):
                pass

        clock = [0.]
        teacher_calls = []
        def load_pair(*_):
            clock[0] = 2.
            return None, None

        with patch.object(train.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(train, "pair", side_effect=load_pair), \
             patch.object(train.model, "forward_with_stages", side_effect=lambda *_: teacher_calls.append(1)):
            with self.assertRaisesRegex(train.TrainingStop, "time_budget_exhausted"):
                train.evaluate(Net(), object(), [{"alpha": .5}], "cpu", "fast", deadline=1.)
        self.assertEqual(teacher_calls, [])

    def test_cancel_does_not_need_a_time_deadline(self):
        with self.assertRaisesRegex(train.TrainingStop, "cancelled"):
            train.check_deadline(None, lambda: True)


if __name__ == "__main__":
    unittest.main()
