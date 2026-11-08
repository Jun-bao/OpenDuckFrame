"""CPU-only sample identity, BGRA rounding, and report-flag checks; no forwards."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np


LAB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB))
SPEC = importlib.util.spec_from_file_location("student_compare_native", LAB / "compare_native.py")
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)


def manifest():
    groups = dict(distillation_evaluation=[], evaluation=[])
    for clip in ("clip_a", "clip_b"):
        for block, start in ((0, 62), (2, 309)):
            case_id = f"{clip}-b{block}"
            for first, second in [(i, i + 1) for i in range(start, start + 4)] + [(start, start + 4)]:
                has_gt = second - first == 4
                for alpha in (0.25, 0.5, 0.75):
                    name = f"{case_id}-a{alpha:g}" if has_gt else f"{clip}-f{first:04d}-f{second:04d}-a{alpha:g}"
                    row = dict(id=name, case_id=case_id, clip=clip, first_index=first, second_index=second,
                               first=f"{clip}/{first}.png", second=f"{clip}/{second}.png", width=2, height=1,
                               delta_seconds=(second - first) / 50, first_sha256="a" * 64,
                               second_sha256="b" * 64, alpha=alpha)
                    if has_gt:
                        row.update(gt=f"{clip}/{first + 1}.png", gt_sha256="c" * 64)
                    groups["evaluation" if has_gt else "distillation_evaluation"].append(row)
    return groups


def report_row(sample, variant="student", **values):
    row = dict(sample, variant=variant, native_case_id=compare.native_case_id(sample),
               reference_psnr_db=50.0, reference_mae=0.001, max_abs_lsb=3,
               fraction_pixels_ge2_lsb=0.1, mean_abs_lsb=0.2, output_sha256="d" * 64)
    row.update(values)
    return row


class SampleIdentityTests(unittest.TestCase):
    def test_default_retains_12_gt_and_both_has_60_samples_20_endpoint_cases(self):
        source = manifest()
        gt = compare.select_evaluation(source)
        both = compare.select_evaluation(source, "both")
        self.assertEqual((len(gt), len(compare.endpoint_cases(gt))), (12, 4))
        self.assertEqual((len(both), len(compare.endpoint_cases(both))), (60, 20))
        self.assertEqual(sum(row["has_gt"] for row in both), 12)
        self.assertEqual(len({row["id"] for row in both}), 60)
        window = [row for row in both if row["case_id"] == "clip_a-b0"]
        self.assertEqual(len({compare.native_case_id(row) for row in window}), 5)
        self.assertEqual(len({row["case_id"] for row in window}), 1)
        self.assertNotIn("has_gt", source["evaluation"][0])

    def test_case_ids_depend_on_clip_and_endpoint_indices_not_repeated_window(self):
        rows = compare.select_evaluation(manifest(), "both")
        first = rows[0]
        same_endpoints = dict(first, case_id="a-different-window", alpha=0.75)
        self.assertEqual(compare.native_case_id(first), compare.native_case_id(same_endpoints))
        self.assertNotEqual(compare.native_case_id(first), compare.native_case_id(dict(first, second_index=66)))
        with self.assertRaisesRegex(ValueError, "inconsistent source frames"):
            compare.endpoint_cases([first, dict(first, second="another.png")])

    def test_old_d0_hash_checks_never_match_adjacent_pair_by_shared_window_case_id(self):
        rows = compare.select_evaluation(manifest(), "both")
        adjacent = report_row(rows[0], "d0", output_sha256="wrong-adjacent-hash")
        gt = report_row(next(row for row in rows if row["has_gt"]), "d0", output_sha256="old-gt-hash")
        frozen = dict(rows=[dict(variant="d0", case_id=gt["case_id"], alpha=gt["alpha"], output_sha256="old-gt-hash")])
        checked = compare.frozen_d0_checks([adjacent, gt], frozen)
        self.assertEqual(len(checked), 1)
        self.assertEqual((checked[0]["id"], checked[0]["matches"]), (gt["id"], True))
        self.assertEqual(checked[0]["delta_seconds"], 0.08)


class NumericalTests(unittest.TestCase):
    def test_quantization_clamps_and_uses_bgra_nearest_even(self):
        rgb = np.array([[[-1, 0.5 / 255, 1.5 / 255], [2.5 / 255, 254.5 / 255, 2]]], dtype=np.float32)
        expected = np.array([[[2, 0, 0, 255], [255, 254, 2, 255]]], dtype=np.uint8)
        np.testing.assert_array_equal(compare.reference_bgra8(rgb), expected)
        self.assertIn("ties to even", compare.QUANTIZATION["rounding"])

    def test_lsb_fraction_counts_pixels_with_any_rgb_channel_and_mean_counts_channels(self):
        native = np.array([[[0, 0, 0, 0], [1, 0, 0, 20], [0, 2, 0, 90], [0, 0, 3, 255]]], dtype=np.uint8)
        values = compare.lsb_metrics(native, np.zeros((1, 4, 3), dtype=np.float32))
        self.assertEqual({key: values[key] for key in compare.LSB_METRICS},
                         dict(max_abs_lsb=3, fraction_pixels_ge2_lsb=0.5, mean_abs_lsb=0.5))
        self.assertEqual(values["lsb_histogram"][:4], [9, 1, 1, 1])
        self.assertEqual((len(values["lsb_histogram"]), sum(values["lsb_histogram"])), (256, 12))
        self.assertEqual((values["pixel_count"], values["pixels_ge2_lsb"], values["rgb_channel_count"]), (4, 2, 12))

    def test_non_gt_rows_never_open_or_require_a_gt_file(self):
        sample = dict(compare.select_evaluation(manifest(), "both")[0])
        self.assertFalse(sample["has_gt"])
        with patch.object(compare.Image, "open", side_effect=AssertionError("GT must not be read")):
            self.assertEqual(compare.gt_metrics(sample, None, None), {})

    def test_each_same_sample_d0_metric_has_independent_exact_two_times_limit(self):
        sample = compare.select_evaluation(manifest(), "both")[0]
        base = report_row(sample, "d0")
        equal_limits = report_row(sample, max_abs_lsb=6, fraction_pixels_ge2_lsb=0.2, mean_abs_lsb=0.4)
        exceeds = report_row(sample, variant="last", max_abs_lsb=7, fraction_pixels_ge2_lsb=0.21, mean_abs_lsb=0.41)
        rows = [base, equal_limits, exceeds]
        compare.annotate_numerical(rows, {sample["id"]: base})
        self.assertNotIn("numerical_within_2x_d0", base)
        self.assertTrue(equal_limits["numerical_within_2x_d0"])
        self.assertFalse(exceeds["numerical_within_2x_d0"])
        self.assertEqual(exceeds["numerical_exceeded_metrics"], list(compare.LSB_METRICS))
        self.assertEqual(exceeds["numerical_baseline_d0_output_sha256"], base["output_sha256"])

    def test_zero_baseline_has_zero_limit_and_endpoint_mismatch_is_rejected(self):
        sample = compare.select_evaluation(manifest(), "both")[0]
        base = report_row(sample, "d0", max_abs_lsb=0, fraction_pixels_ge2_lsb=0, mean_abs_lsb=0)
        student = report_row(sample, max_abs_lsb=1, fraction_pixels_ge2_lsb=0, mean_abs_lsb=0)
        compare.annotate_numerical([student], {sample["id"]: base})
        self.assertEqual(student["numerical_exceeded_metrics"], ["max_abs_lsb"])
        with self.assertRaisesRegex(ValueError, "endpoints/alpha differ"):
            compare.annotate_numerical([dict(student, second_index=66)], {sample["id"]: base})

    def test_summary_gt_denominator_and_external_d0_native_deltas(self):
        samples = compare.select_evaluation(manifest(), "both")
        adjacent = report_row(samples[0])
        gt_sample = next(row for row in samples if row["has_gt"])
        gt = report_row(gt_sample, native_gt_psnr_db=28, torch_gt_psnr_db=29)
        base = report_row(gt_sample, "d0", native_gt_psnr_db=30, torch_gt_psnr_db=31)
        result = compare.summarize([adjacent, gt], ["student"], {base["id"]: base})["student"]
        self.assertEqual((result["samples"], result["gt_samples"]), (2, 1))
        self.assertEqual(result["mean_native_gt_psnr_db"], 28)
        self.assertEqual(result["mean_native_gt_delta_to_d0_db"], -2)
        self.assertEqual((gt["native_gt_delta_to_d0_db"], gt["torch_gt_delta_to_d0_db"]), (-2, -2))
        self.assertNotIn("native_gt_delta_to_d0_db", adjacent)

    def test_histogram_quantile_uses_integer_nearest_rank_for_rare_tails(self):
        hist = [0] * 256
        hist[0], hist[50] = 9999, 1
        self.assertEqual(compare.histogram_quantile(hist), 0)
        hist[0], hist[50] = 9998, 2
        self.assertEqual(compare.histogram_quantile(hist), 50)

    def test_aggregation_pools_pixel_counts_and_rgb_channel_histograms(self):
        a = compare.lsb_metrics(np.array([[[0, 2, 0, 255]]], dtype=np.uint8), np.zeros((1, 1, 3)))
        b = compare.lsb_metrics(np.zeros((1, 3, 4), dtype=np.uint8), np.zeros((1, 3, 3)))
        pooled = compare.aggregate_lsb([a, b])
        self.assertEqual((pooled["pixel_count"], pooled["pixels_ge2_lsb"], pooled["rgb_channel_count"]), (4, 1, 12))
        self.assertEqual(pooled["fraction_pixels_ge2_lsb"], 0.25)
        self.assertAlmostEqual(pooled["mean_abs_lsb"], 2 / 12)
        self.assertEqual(pooled["abs_delta_p99_99_lsb"], 2)

    def test_v2_preserves_v1_flags_and_uses_fullrank_pooled_tail_baseline(self):
        samples = compare.select_evaluation(manifest(), "both")
        pixels = np.array([[[0, 2, 0, 255], [0, 0, 0, 255]]], dtype=np.uint8)
        metrics = compare.lsb_metrics(pixels, np.zeros((1, 2, 3)))
        controls = [report_row(row, "fullrank", **metrics) for row in samples]
        students = [report_row(row, "initial", **metrics) for row in samples]
        d0 = {row["id"]: report_row(row, "d0", **metrics) for row in samples}
        compare.annotate_numerical(students, d0)
        # Preserve an existing unresolved v1 tail flag even when v2 is in bounds.
        students[0].update(numerical_within_2x_d0=False, numerical_exceeded_metrics=["max_abs_lsb"])
        old_flag = copy.deepcopy(students[0]["numerical_exceeded_metrics"])
        result = compare.numerical_v2(students, ["initial"], d0, dict(rows=controls), "posthoc_diagnostic")
        self.assertEqual(result["status"], "diagnostic_only")
        self.assertFalse(result["prior_v1_reclassified"])
        self.assertFalse(result["max_abs_lsb_gate_applied"])
        self.assertTrue(result["by_variant"]["initial"]["within_diagnostic_limits"])
        self.assertFalse(students[0]["numerical_within_2x_d0"])
        self.assertEqual(students[0]["numerical_exceeded_metrics"], old_flag)
        self.assertEqual(result["by_variant"]["initial"]["aggregate"]["pixel_count"], 120)

    def test_v2_flags_mean_and_pooled_tails_without_relabeling_quality(self):
        samples = compare.select_evaluation(manifest(), "both")
        zero = np.zeros((1, 2, 3))
        control_metrics = compare.lsb_metrics(np.zeros((1, 2, 4), dtype=np.uint8), zero)
        candidate_metrics = compare.lsb_metrics(np.full((1, 2, 4), 3, dtype=np.uint8), zero)
        controls = [report_row(row, "fullrank", **control_metrics) for row in samples]
        students = [report_row(row, "last", **candidate_metrics) for row in samples]
        d0 = {row["id"]: report_row(row, "d0", **control_metrics) for row in samples}
        result = compare.numerical_v2(students, ["last"], d0, dict(rows=controls), "post_training_diagnostic")
        self.assertEqual(set(result["by_variant"]["last"]["flagged_metrics"]),
                         {"fraction_pixels_ge2_lsb", "abs_delta_p99_99_lsb", "per_sample_mean_abs_lsb"})
        self.assertFalse(result["quality_gate_applied"])
        self.assertEqual(len(result["by_variant"]["last"]["mean_lsb_flagged_sample_ids"]), 60)

    def test_old_fullrank_without_histograms_is_unavailable_not_accepted(self):
        samples = compare.select_evaluation(manifest(), "both")
        controls = [report_row(row, "fullrank") for row in samples]
        result = compare.numerical_v2([], ["initial"], {"placeholder": {}}, dict(rows=controls), "posthoc_diagnostic")
        self.assertEqual(result["status"], "unavailable_fullrank_requires_60_histograms")
        self.assertEqual(result["by_variant"], {})


class ReuseNativeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="student-reuse-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report_path = self.root / "old/native/quality.json"
        self.report_path.parent.mkdir(parents=True)
        self.sample = compare.select_evaluation(manifest(), "both")[0]
        self.weights, self.binary, self.manifest = [self.root / name for name in ("weights.rmw", "native-bin", "manifest.json")]
        for path in (self.weights, self.binary, self.manifest):
            path.write_bytes(path.name.encode())
        first, second = self.root / "first.bgra", self.root / "second.bgra"
        first.write_bytes(bytes(8))
        second.write_bytes(bytes([1] * 8))
        self.native_config = dict(mode="quality", app_entrypoints=True, width=2, height=1, tier="fast",
            variants=[dict(id="d0", model=str(self.weights), direct_crop=True, gpu_input_padding=True,
                           fused_warp=False, trim_final_features=False, defer_commits=False)],
            cases=[dict(id=compare.native_case_id(self.sample), first=str(first), second=str(second))])
        self.native_report = dict(rows=[dict(case_id=compare.native_case_id(self.sample), variant="d0",
                                             alpha=self.sample["alpha"], output_sha256="d" * 64)])
        self.report_path.write_text(json.dumps(self.native_report))
        self.analysis = dict(tier="fast", native_report_sha256=compare.model.sha(self.report_path),
            native_bin_sha256=compare.model.sha(self.binary), data_manifest_sha256=compare.model.sha(self.manifest),
            model_sha256={"d0": compare.model.sha(self.weights)}, rows=[report_row(self.sample, "d0")])
        self.native_config_path = self.root / "old/native-config.json"
        self.analysis_path = self.root / "old/analysis.json"
        self.native_config_path.write_text(json.dumps(self.native_config))
        self.analysis_path.write_text(json.dumps(self.analysis))
        self.config = dict(reuse_native_report=str(self.report_path), native_bin=str(self.binary),
            data_manifest=str(self.manifest), tier="fast", models={"d0": dict(weights=str(self.weights))})

    def test_reuse_is_read_only_and_binds_prior_report_model_inputs_and_geometry(self):
        before = {str(path): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        with patch.object(compare.subprocess, "run", side_effect=AssertionError("native must not run")):
            report, path, metadata = compare.reuse_native(self.config, [self.sample])
        after = {str(path): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(report, self.native_report)
        self.assertEqual(path, self.report_path.resolve())
        self.assertFalse(metadata["native_execution_performed"])
        self.assertFalse(metadata["native_outputs_copied"])
        self.assertEqual(len(metadata["current_bgra_input_sha256"]), 2)

    def test_changed_model_report_dimension_or_source_hash_rejects_reuse(self):
        with self.assertRaises(ValueError):
            compare.reuse_native(dict(self.config, tier="balanced"), [self.sample])
        self.weights.write_bytes(b"different weights")
        with self.assertRaisesRegex(ValueError, "model SHA differs"):
            compare.reuse_native(self.config, [self.sample])
        self.weights.write_bytes(self.weights.name.encode())
        changed = dict(self.sample, first_sha256="changed-png")
        with self.assertRaisesRegex(ValueError, "sample identity or hashes differ"):
            compare.reuse_native(self.config, [changed])
        self.report_path.write_text(json.dumps(dict(rows=[])))
        with self.assertRaisesRegex(ValueError, "provenance"):
            compare.reuse_native(self.config, [self.sample])


if __name__ == "__main__":
    unittest.main()
