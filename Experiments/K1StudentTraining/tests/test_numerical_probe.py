"""CPU source-patch tests; no Metal device, reference forward, or model execution."""
import importlib.util
from pathlib import Path
import unittest


LAB = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("student_numerical_probe", LAB / "numerical_probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class ProbePreparationTests(unittest.TestCase):
    def test_quality_probe_keeps_original_entrypoints_and_requires_special_switch(self):
        original = (LAB.parent / "K1Execution/native/main.swift").read_text()
        generated = probe.patch_main(original)
        self.assertIn('guard mode == "quality"', generated)
        self.assertIn("try StudentStateDump.requireConfigured()", generated)
        self.assertEqual(generated.count("try StudentStateDump.begin("), 1)
        self.assertEqual(generated.count("try StudentStateDump.finish()"), 1)
        self.assertIn('environment["RIFE_DUMP_DIR"] == nil', generated)
        self.assertIn("stream.push(b, into: output)", generated)
        self.assertIn("stream.push(b, timesteps: targets.map(Float.init))", generated)

    def test_stage_filter_only_changes_the_existing_dump_conditions(self):
        original = "if let dumpDir = dumpDir {\nkeep_one()\n}\nif let dumpDir = dumpDir {\nkeep_two()\n}"
        generated = probe.patch_graph(original)
        self.assertEqual(generated.replace(
            "if let dumpDir = dumpDir, i == 3 || i == 4 {", "if let dumpDir = dumpDir {"), original)

    def test_unknown_source_anchors_fail_instead_of_patching_another_path(self):
        with self.assertRaises(ValueError):
            probe.patch_main("another executable")
        with self.assertRaises(ValueError):
            probe.patch_graph("another graph")


if __name__ == "__main__":
    unittest.main()
