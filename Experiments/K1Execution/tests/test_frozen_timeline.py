"""Small exhaustive CPU oracles for the frozen-time audit; no media or GPU work."""
from copy import deepcopy
from fractions import Fraction
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import analyze_frozen_timeline as audit


def exhaustive_deliveries(windows, period):
    """Enumerate all skip/time assignments, independent of earliest-finish DP."""
    best = 0
    for assignment in itertools.product(*[[None, *range(lo, hi + 1)] for lo, hi in windows]):
        chosen = [x for x in assignment if x is not None]
        if all(b - a >= period for a, b in zip(chosen, chosen[1:])):
            best = max(best, len(chosen))
    return best


def exhaustive_grid(targets, period, tolerance):
    """Enumerate half-unit phases and every assignment to physical slots.

    Integer-window endpoints make half-unit samples sufficient for every open
    interval; this oracle does not use the production residue-breakpoint list.
    """
    best = 0
    for phase2 in range(2 * period):
        phase = Fraction(phase2, 2)
        slots = [phase + n * period for n in range(-1, max(targets) // period + 3)]
        choices = [[None] + [s for s in slots if t <= s <= t + tolerance] for t in targets]
        for assignment in itertools.product(*choices):
            chosen = [x for x in assignment if x is not None]
            if all(b > a for a, b in zip(chosen, chosen[1:])):
                best = max(best, len(chosen))
    return best


def frame(identity, pts, target, *, outcome="positive", actual=.110, selected=True):
    return {"frameID": identity, "type": "synth", "ptsNum": pts.numerator, "ptsDen": pts.denominator,
            "targetHost": target, "readyHost": target - 20, "presentationEnqueueHost": target - 19,
            "modelCompleteHost": target - 21, "outcome": outcome, "actualTime": actual,
            "SDK_V": .110, "tau": .093333, "displaySelectionHost": 92 if selected else None,
            "context": dict(generation=1, configVersion=1, measurementEpoch=1, clockEpoch=0)}


def document():
    source_a = frame(1, Fraction(0), 100)
    source_b = frame(3, Fraction(1), 120)
    synth = frame(2, Fraction(1, 2), 112, actual=.113)
    return {"schema": "ODF-frozen-cohort-plan-v1", "timebase": {"numer": 1_000_000, "denom": 1},
            "frames": [synth], "pairs": [{"jobID": 7, "sourceA": source_a, "synthetic": synth,
                                          "sourceB": source_b, "alpha": None}]}


class FrozenTimelineTests(unittest.TestCase):
    def test_overlapping_conflicts_are_not_summed(self):
        targets = [0, 6, 12]
        self.assertEqual(audit.maximum_min_spacing(targets, [2, 8, 14], 10), 2)
        self.assertEqual(audit.adjacent_conflicts(targets, 10, 2), {
            "conflicting_adjacent_pairs": 2,
            "omission_lower_bound_from_adjacent_pairs_only": 1})

    def test_dp_matches_exhaustive_assignments_including_nonmonotone_and_empty_windows(self):
        cases = [([(0, 2), (8, 10)], 10), ([(0, 2), (7, 9)], 10),
                 ([(6, 8), (0, 2), (12, 14)], 6), ([(0, 0), (0, 0)], 2),
                 ([(3, 2), (4, 5), (7, 8)], 3), ([(0, 1), (1, 2), (2, 3), (4, 5)], 2)]
        for windows, period in cases:
            with self.subTest(windows=windows, period=period):
                self.assertEqual(audit.maximum_min_spacing([a for a, b in windows], [b for a, b in windows], period),
                                 exhaustive_deliveries(windows, period))

    def test_fixed_phase_includes_closed_wrap_boundary_and_one_frame_per_slot(self):
        # Only phase zero can deliver both 0 and 8 in their closed +2 windows.
        for targets in ([0, 8], [9, 10, 19], [0, 1, 10], [0, 13, 26], [2, 7, 12, 18]):
            with self.subTest(targets=targets):
                self.assertEqual(audit.maximum_fixed_phase(targets, 10, 2)["maximum_matched"],
                                 exhaustive_grid(targets, 10, 2))
        self.assertEqual(audit.maximum_fixed_phase([0, 8], 10, 2)["maximizing_phase_in_doubled_units"], 0)

    def test_fixed_phase_is_stronger_condition_not_unconditional_spacing(self):
        targets = [0, 13, 26]
        self.assertEqual(audit.maximum_min_spacing(targets, [t + 2 for t in targets], 10), 3)
        self.assertEqual(audit.maximum_fixed_phase(targets, 10, 2)["maximum_matched"], 1)
        result = audit.audit_document(document())
        self.assertIn("not an unconditional", result["fixed_phase"]["condition"])

    def test_pair_exact_fraction_does_not_invent_model_alpha_or_expand_denominator(self):
        data = document()
        original = deepcopy(data)
        result = audit.audit_document(data)
        self.assertEqual(data, original)
        self.assertEqual(result["denominator"], 1)
        pairs = result["pairs"]
        self.assertEqual(pairs["derived_alpha_time_counts"], {"1/2": 1})
        self.assertEqual(pairs["observed_model_alpha_n"], 0)
        self.assertEqual(pairs["extrema"]["minimum"]["error_ns_exact"], {"num": 2_000_000, "den": 1})
        self.assertIsNone(data["pairs"][0]["alpha"])

    def test_superseded_ticket_is_not_a_selected_slot_and_zero_is_not_success(self):
        data = document()
        a = frame(10, Fraction(0), 110, outcome="superseded", actual=None, selected=False)
        b = frame(11, Fraction(1), 120, outcome="zero", actual=0)
        c = frame(12, Fraction(2), 110, actual=.120)
        data["frames"] = [a, b, c]
        data["pairs"] = []
        timing = audit.audit_document(data)["timing"]
        self.assertEqual(timing["selected_frames"], 2)
        self.assertEqual(timing["actual_on_time_not_early"], 0)
        self.assertEqual(sum(x["n"] for x in timing["selected_SDK_window_vs_actual"]), 2)
        self.assertIn({"SDK_window": "SDK_in_old_window", "actual_category": "late", "n": 1}, timing["selected_SDK_window_vs_actual"])

    def test_diagnostic_window_boundary_is_closed_but_early_is_not_success(self):
        data = document()
        data["pairs"] = []
        data["frames"] = [frame(10, Fraction(0), 110, actual=.110),
                          frame(11, Fraction(1), 120, actual=.122),
                          frame(12, Fraction(2), 130, actual=.129999)]
        result = audit.audit_document(data)["timing"]
        self.assertEqual(result["actual_on_time_not_early"], 2)
        self.assertEqual(result["actual_early"], 1)

    def test_clock_mix_and_duplicate_identity_are_not_silently_merged(self):
        data = document()
        data["frames"].append(deepcopy(data["frames"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            audit.audit_document(data)
        data["frames"][1]["context"]["clockEpoch"] = 1
        with self.assertRaisesRegex(ValueError, "clock epoch"):
            audit.audit_document(data)

    def test_cli_records_input_hash_and_refuses_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, output = root / "cohort-plan.json", root / "new-result"
            raw = json.dumps(document()).encode()
            source.write_bytes(raw)
            command = [sys.executable, "-B", audit.__file__, "--input", str(source), "--output", str(output)]
            subprocess.run(command, check=True, capture_output=True)
            result = json.loads((output / "analysis.json").read_bytes())
            self.assertEqual(result["input"]["sha256"], hashlib.sha256(raw).hexdigest())
            saved = (output / "analysis.json").read_bytes()
            retry = subprocess.run(command, capture_output=True)
            self.assertNotEqual(retry.returncode, 0)
            self.assertEqual((output / "analysis.json").read_bytes(), saved)
            self.assertEqual(source.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
