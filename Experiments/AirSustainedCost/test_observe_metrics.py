"""CPU-fake checks only; never launches macmon, a model, or a GPU workload."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("odf_metrics_observer", HERE / "observe_metrics.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
MetricsObserver = MODULE.MetricsObserver
BASE = None
FAKE = r'''
import datetime as dt,json,os,signal,sys,time
mode=sys.argv[1]
if mode=="ignore":signal.signal(signal.SIGTERM,signal.SIG_IGN)
print("fake stderr; CLPC="+os.environ.get("MACMON_FORCE_CLPC","missing"),file=sys.stderr,flush=True)
if mode=="long":
 print("x"*10000,flush=True);time.sleep(20);sys.exit(0)
base=dt.datetime.now(dt.timezone.utc)
for i in range(400):
 stamp=(base+dt.timedelta(seconds=3*i)) if mode=="gap" else dt.datetime.now(dt.timezone.utc)
 payload={"timestamp":stamp.isoformat(),"gpu_freq_mhz":400,"gpu_active_ratio":.25,
          "marker":"raw field unchanged","soc":{"chip_name":"CPU fake"},
          "cpu_tiers":[{"label":"E","freq_mhz":1000,"active_ratio":.2}]}
 print(json.dumps(payload),flush=True)
 if mode=="eof" and i==1:sys.exit(0)
 if mode=="bad" and i==4:print("not-json",flush=True)
 if mode=="gap" and i==1:time.sleep(20);sys.exit(0)
 time.sleep(.02)
'''


class ObserverCPUChecks(unittest.TestCase):
    def setUp(self):
        self.directory = BASE / self._testMethodName
        self.directory.mkdir()
        self.observers = []

    def tearDown(self):
        for observer in self.observers:
            observer.close()

    def observer(self, mode="good", limits=None):
        attempt = self.directory / ("attempt" + str(len(self.observers)))
        value = MetricsObserver({"binary_path": sys.executable}, attempt,
            _test_command=[sys.executable, "-u", str(BASE / "fake_sampler.py"), mode],
            _test_limits=dict(anchor_interval_seconds=.03, **(limits or {})))
        self.observers.append(value)
        return value

    def pump(self, observer, predicate, seconds=2):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            observer.poll(); observer.clock_if_due()
            if predicate(): return
            time.sleep(.01)
        self.fail("bounded CPU-fake condition did not arrive: " + str(observer.snapshot()))

    def lines(self, observer, name):
        return [json.loads(line) for line in (observer.directory / name).read_text().splitlines()]

    def test_exact_timestamp_fraction_and_offset(self):
        left = MODULE._utc_ns("2026-11-09T08:00:00.123456789+08:00")
        right = MODULE._utc_ns("2026-11-09T00:00:00.123456789Z")
        self.assertEqual(left, right)
        self.assertEqual(left % MODULE.NS, 123456789)
        with self.assertRaises(ValueError): MODULE._utc_ns("no-zone")

    def test_lifecycle_raw_stderr_receive_and_discard(self):
        observer = self.observer(); observer.start()
        self.pump(observer, lambda: observer.ready_for_native(.03))
        observer.mark_native_started(pid=12345)
        time.sleep(.03); observer.poll(); observer.mark_native_finished(returncode=0)
        result = observer.stop_after_native(.04)
        self.assertIsNone(result["first_error"])
        self.assertTrue(result["post_roll_satisfied"])
        self.assertEqual(result["status"], "stopped")
        self.assertIn("CLPC=1", (observer.directory / "stderr.raw").read_text())
        samples = self.lines(observer, "samples.jsonl")
        self.assertTrue(samples[0]["discard"])
        self.assertTrue(all(not item["discard"] for item in samples[1:]))
        self.assertEqual(sum(item["discard"] for item in samples), 1)
        for sample in samples:
            self.assertEqual(json.loads(sample["raw_line"]), sample["payload"])
            self.assertEqual(sample["payload"]["marker"], "raw field unchanged")
            self.assertGreater(sample["receive_monotonic_ns"], 0)
            self.assertGreater(sample["receive_utc_ns"], 0)
        self.assertGreaterEqual(result["termination"]["monotonic_ns"]-result["native_end"]["monotonic_ns"], 40_000_000)
        old = observer.snapshot(); observer.close()
        self.assertEqual(old, observer.snapshot())

    def test_start_no_replay_and_abort_without_native(self):
        observer = self.observer(); observer.start()
        observer.abort("CPU preflight refusal")
        self.assertIsNone(observer.snapshot()["native_start"])
        self.assertIsNone(observer.snapshot()["native_end"])
        with self.assertRaises(RuntimeError): observer.start()
        before = (observer.directory / "metadata.json").read_bytes()
        replay = MetricsObserver({"binary_path": sys.executable}, observer.directory.parent,
            _test_command=[sys.executable, "-u", str(BASE / "fake_sampler.py"), "good"])
        with self.assertRaises(FileExistsError): replay.start()
        replay.close()
        self.assertEqual(before, (observer.directory / "metadata.json").read_bytes())

    def test_eof_is_error_without_restart(self):
        observer = self.observer("eof"); observer.start(); pid = observer.process.pid
        self.pump(observer, lambda: observer.snapshot()["first_error"] is not None)
        self.assertFalse(observer.ready_for_native(0))
        observer.close(); self.assertEqual(pid, observer.snapshot()["sampler_pid"])
        self.assertEqual(observer.snapshot()["sample_count"], 2)

    def test_fault_during_native_preserves_independent_native_file(self):
        observer = self.observer("bad"); observer.start()
        native = observer.directory.parent / "native.json"
        native.write_text('{"status":"complete","CPU_fake_native":true}\n')
        before = native.read_bytes()
        self.pump(observer, lambda: observer.snapshot()["usable_sample_count"] >= 1)
        observer.mark_native_started(pid=98765)
        self.pump(observer, lambda: observer.snapshot()["first_error"] is not None)
        self.assertEqual(observer.snapshot()["first_error"]["kind"], "invalid_sample")
        self.assertTrue(observer.snapshot()["first_error"]["native_started"])
        observer.mark_native_finished(returncode=0); observer.stop_after_native(.02)
        self.assertEqual(before, native.read_bytes())

    def test_line_bound_keeps_raw_prefix_and_stops_own_child(self):
        observer = self.observer("long", dict(max_line_bytes=128)); observer.start()
        self.pump(observer, lambda: observer.snapshot()["first_error"] is not None)
        observer.close()
        self.assertEqual(observer.snapshot()["first_error"]["kind"], "line_limit")
        self.assertGreater((observer.directory / "stdout.raw").stat().st_size, 128)
        self.assertIsNotNone(observer.process.returncode)

    def test_sample_limit(self):
        observer = self.observer(limits=dict(sample_limit=3)); observer.start()
        self.pump(observer, lambda: observer.snapshot()["first_error"] is not None)
        observer.close()
        self.assertEqual(observer.snapshot()["sample_count"], 3)
        self.assertEqual(observer.snapshot()["first_error"]["kind"], "sample_limit")

    def test_clock_bracket_sequence_and_units(self):
        observer = self.observer(); observer.start()
        self.pump(observer, lambda: observer.snapshot()["anchor_count"] >= 3)
        observer.close()
        anchors = self.lines(observer, "anchors.jsonl")
        for point in anchors:
            self.assertLessEqual(point["monotonic_before_ns"], point["monotonic_after_ns"])
            self.assertLessEqual(point["mach_before_ticks"], point["mach_after_ticks"])
            self.assertEqual(point["mach_before_ns"], point["mach_before_ticks"]*point["timebase_numer"]//point["timebase_denom"])
            self.assertIn("mach_before,UTC_time_ns,mach_after", point["read_order"])
        self.assertEqual([x["anchor_seq"] for x in anchors], list(range(1, len(anchors)+1)))

    def test_source_gap_has_no_fabricated_sample(self):
        observer = self.observer("gap"); observer.start()
        self.pump(observer, lambda: observer.snapshot()["sample_count"] == 2)
        observer.close()
        self.assertEqual(len(self.lines(observer, "samples.jsonl")), 2)
        self.assertTrue(any(x["kind"] == "sample_gap" for x in self.lines(observer, "events.jsonl")))

    def test_only_owned_pid_killed(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"])
        try:
            observer = self.observer("ignore"); observer.start()
            self.pump(observer, lambda: observer.snapshot()["sample_count"] >= 2)
            observer.abort("CPU fake stubborn child")
            self.assertIsNone(unrelated.poll())
            self.assertIsNotNone(observer.process.returncode)
        finally:
            unrelated.terminate(); unrelated.wait(timeout=2)

    def test_normal_wrong_binary_never_executes(self):
        observer = MetricsObserver({"binary_path": sys.executable}, self.directory / "normal")
        self.observers.append(observer)
        with self.assertRaises(RuntimeError): observer.start()
        self.assertIsNone(observer.process)
        self.assertEqual(observer.snapshot()["first_error"]["kind"], "start_failed")

    def test_wall_bound(self):
        observer = self.observer(limits=dict(wall_timeout_seconds=.08)); observer.start()
        self.pump(observer, lambda: observer.snapshot()["first_error"] is not None)
        observer.close()
        self.assertEqual(observer.snapshot()["first_error"]["kind"], "observer_wall_timeout")

    def test_provider_environment_not_inherited(self):
        code = ('import datetime,json,os,time; '
                'print(json.dumps({"timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat(),'
                '"gpu_freq_mhz":400,"gpu_active_ratio":0.25,'
                '"provider_dummy_present":"ANTHROPIC_OBSERVER_CPU_DUMMY" in os.environ,'
                '"forced_clpc":os.environ.get("MACMON_FORCE_CLPC")=="1"}),flush=True);time.sleep(20)')
        observer = MetricsObserver({"binary_path": sys.executable}, self.directory / "dummy-attempt",
            _test_command=[sys.executable, "-u", "-c", code])
        self.observers.append(observer)
        with patch.dict(os.environ, {"ANTHROPIC_OBSERVER_CPU_DUMMY": "not-a-secret"}):
            observer.start()
        self.pump(observer, lambda: observer.snapshot()["sample_count"] == 1)
        observer.abort("single CPU environment check")
        payload = self.lines(observer, "samples.jsonl")[0]["payload"]
        self.assertFalse(payload["provider_dummy_present"])
        self.assertTrue(payload["forced_clpc"])
        self.assertTrue(observer.snapshot()["sampler"]["provider_environment_removed"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="fresh private CPU evidence directory")
    parser.add_argument("--case", help="run one named CPU-fake check without replaying prior cases")
    args = parser.parse_args(); BASE = args.output_dir.resolve(); BASE.mkdir(parents=True, exist_ok=False)
    (BASE / "fake_sampler.py").write_text(FAKE)
    suite = (unittest.TestSuite([ObserverCPUChecks(args.case)]) if args.case
             else unittest.defaultTestLoader.loadTestsFromTestCase(ObserverCPUChecks))
    with (BASE / "checks.log").open("w") as log:
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    print((BASE / "checks.log").read_text())
    receipt = dict(format="odf-metrics-observer-cpu-fake-v1", tests=result.testsRun,
        failures=len(result.failures), errors=len(result.errors), passed=result.wasSuccessful(),
        macmonExecuted=False, modelExecuted=False, gpuWorkloadExecuted=False,
        sourceSHA256=hashlib.sha256((HERE / "observe_metrics.py").read_bytes()).hexdigest(),
        checksSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (BASE / "receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)
