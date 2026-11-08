"""CPU-only attach harness patch/config checks; never builds or runs a model."""
import importlib.util
from pathlib import Path
import sys
import unittest


LAB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB))
SPEC = importlib.util.spec_from_file_location("student_attach_prepare", LAB / "prepare_attach_trace.py")
attach = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(attach)


class AttachPreparationTests(unittest.TestCase):
    def test_main_logs_start_before_config_and_done_only_after_report_write(self):
        source = (LAB.parent / "K1Execution/native/main.swift").read_text()
        patched = attach.patch_main(source)
        self.assertLess(patched.index("StudentAttachTrace.start()"), patched.index("JSONSerialization.jsonObject"))
        self.assertLess(patched.index("StudentAttachTrace.configure(config)"), patched.index("MTLCreateSystemDefaultDevice()"))
        self.assertLess(patched.index("options: .atomic)"), patched.index("StudentAttachTrace.finished(report: file)"))
        self.assertIn("StudentAttachTrace.failed(error)", patched)
        self.assertIn('CommandLine.arguments.count == 2', patched)

    def test_four_configs_have_distinct_control_output_paths_and_fixed_two_arm_schedule(self):
        reference = dict(width=1920, height=1080, tier="fast")
        case = dict(id="park_joy-b0", first="a.bgra", second="b.bgra")
        variants = [dict(id=name, model=f"{name}.rmw") for name in ("d0", "trained")]
        configs = []
        for phase in ("preflight", "trace"):
            for tier in ("fast", "balanced"):
                config = attach.attach_config(dict(reference, tier=tier), case, variants,
                    "/tmp/attach-plan-test", f"{phase}-{tier}", "/tmp/project-gpu.lock")
                configs.append(config)
                self.assertEqual((config["warmup_per_arm"], config["rewarm_per_arm"], config["frames_per_arm"]), (32, 8, 100))
                self.assertEqual(config["schedule"], [dict(block=0, case_id="park_joy-b0", alpha=0.5,
                    cadence="continuous", period_ms=0, order=["d0", "trained"])])
                self.assertEqual(config["attach_phase"], phase)
                self.assertTrue(config["app_entrypoints"])
        for key in ("output_dir", "attach_gate", "attach_progress"):
            self.assertEqual(len({config[key] for config in configs}), 4)

    def test_unknown_or_already_attach_instrumented_main_is_not_silently_repatched(self):
        with self.assertRaises(ValueError):
            attach.patch_main("another main")
        source = (LAB.parent / "K1Execution/native/main.swift").read_text()
        with self.assertRaises(ValueError):
            attach.patch_main(attach.patch_main(source))

    def test_gpu_lock_uses_the_c_flock_symbol_not_the_conflicting_swift_struct(self):
        helper = (LAB / "native/StudentAttachTrace.swift").read_text()
        self.assertIn('@_silgen_name("flock")', helper)
        self.assertIn("private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32", helper)
        self.assertIn("systemFlock(descriptor, LOCK_EX | LOCK_NB)", helper)
        self.assertIn("systemFlock(lockDescriptor, LOCK_UN)", helper)
        self.assertNotIn("Darwin.flock(", helper)


class PreparedBenchPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = LAB.parents[1] / ".build/k1-student-native-20261107/Sources/k1-runtime/K1ControlledBench.swift"
        if not path.is_file():
            raise unittest.SkipTest("requires the original prepared runtime source; no binary execution")
        cls.source = path.read_text()

    def test_both_warms_and_cpu_gate_precede_all_recorded_intervals(self):
        patched = attach.patch_bench(self.source)
        warm = patched.index("count: 32, reset: true")
        ready = patched.index("StudentAttachTrace.readyAndWait()")
        rewarm = patched.index("count: 8, reset: false")
        begin = patched.index("StudentAttachTrace.recordingBegin()")
        self.assertTrue(warm < ready < rewarm < begin < patched.index("StudentAttachTrace.begin("))
        self.assertEqual(patched.count("StudentAttachTrace.recordingBegin()"), 1)
        self.assertEqual(patched.count("StudentAttachTrace.recordingEnd()"), 1)

    def test_existing_provided_output_push_and_host_timestamps_are_retained(self):
        patched = attach.patch_bench(self.source)
        self.assertIn("return try stream.push(frame, into: providedOutput!) ? [providedOutput!] : []", patched)
        self.assertNotIn("stream.reset()", patched)
        self.assertNotIn("for i in 0..<warmup", patched)
        self.assertNotIn('warmup = config["warmup_per_arm"]', patched)
        self.assertLess(patched.index("StudentAttachTrace.begin("), patched.index("let start = now()", patched.index("StudentAttachTrace.begin(")))
        last_end = patched.index("let end = now()", patched.index("StudentAttachTrace.begin("))
        self.assertLess(last_end, patched.index("StudentAttachTrace.end(traceID)", last_end))


if __name__ == "__main__":
    unittest.main()
