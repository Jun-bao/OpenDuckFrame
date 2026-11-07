"""CPU patch/config checks only. No Swift build, Metal, model, or trace launch."""
import importlib.util
from pathlib import Path
import unittest


LAB = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("student_trace_prepare", LAB / "prepare_trace.py")
trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trace)


class TracePreparationTests(unittest.TestCase):
    def test_signpost_wraps_only_original_measured_push_outside_host_timestamps(self):
        before = '''warmup: try pushFrame(i.isMultiple(of: 2) ? second : first)
                let start = now()
                let result = try pushFrame(frame.isMultiple(of: 2) ? second : first)
                let end = now()
record: samples.append(sample)'''
        after = trace.patch_bench(before)
        self.assertIn(before.splitlines()[0], after)
        self.assertEqual(after.count("StudentK1Trace.begin("), 1)
        self.assertLess(after.index("StudentK1Trace.begin("), after.index("let start = now()"))
        self.assertLess(after.index("let start = now()"), after.index("result = try pushFrame(frame"))
        self.assertLess(after.index("let end = now()"), after.rindex("StudentK1Trace.end(traceID)"))
        self.assertIn("catch {\n                    StudentK1Trace.end(traceID)\n                    throw error", after)

    def test_main_keeps_positional_controlled_interface_and_labels_attribution_only(self):
        source = (LAB.parent / "K1Execution/native/main.swift").read_text()
        patched = trace.patch_main(source)
        self.assertIn('CommandLine.arguments.count == 2', patched)
        self.assertIn("try StudentK1Trace.validate(config: config)", patched)
        self.assertIn('report["trace_attribution_only"] = true', patched)
        self.assertIn('report["cost_adoption_authorized"] = false', patched)
        self.assertEqual(patched.count("try runControlled(config: config, outputDir: outputDir)"), 1)

    def test_config_is_one_midpoint_provided_output_arm_with_exact_32_plus_100(self):
        reference = dict(width=1920, height=1080, tier="fast")
        case = dict(id="park_joy-b0", first="first.bgra", second="second.bgra")
        variant = dict(id="trained", model="best.rmw", direct_crop=True, gpu_input_padding=True)
        config = trace.trace_config(reference, case, variant, "/tmp/trace-runtime-output")
        self.assertEqual(config["mode"], "controlled")
        self.assertTrue(config["app_entrypoints"])
        self.assertEqual((config["warmup_per_arm"], config["frames_per_arm"]), (32, 100))
        self.assertEqual((len(config["cases"]), len(config["variants"]), len(config["schedule"])), (1, 1, 1))
        self.assertEqual(config["schedule"][0], dict(block=0, case_id="park_joy-b0", alpha=0.5,
            cadence="continuous", period_ms=0, order=["trained"]))
        self.assertFalse(config["cost_adoption_authorized"])

    def test_unknown_or_duplicate_patch_anchors_fail(self):
        with self.assertRaises(ValueError):
            trace.patch_bench("another runtime")
        with self.assertRaises(ValueError):
            trace.patch_main("another main")
        with self.assertRaises(ValueError):
            trace.once("same same", "same", "other")


if __name__ == "__main__":
    unittest.main()
