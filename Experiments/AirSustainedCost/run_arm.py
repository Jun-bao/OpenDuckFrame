"""Run one sustained arm after read-only session and project cooldown checks."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_utc(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def process_snapshot():
    rows = []
    for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,pcpu=,comm="], text=True).splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append({"pid": int(fields[0]), "cpu_percent": float(fields[1]),
                         "executable": Path(fields[2]).name})
    rows.sort(key=lambda row: row["cpu_percent"], reverse=True)
    return {"utc": utc_now(), "scope": "Top8 CPU snapshots only; not GPU utilization or cause", "processes": rows[:8]}


def run(config_path):
    config = json.loads(config_path.read_text())
    root = config_path.resolve().parent
    state_path = root / "coordinator-state.json"
    if state_path.exists():
        raise SystemExit("Existing coordinator retained; this arm cannot be repeated")
    state = {"schema": "odf.sustained-arm-coordinator.v1", "started_utc": utc_now(),
             "status": "starting", "arm": config["arm"], "attempts": [],
             "formal_measurements_started": 0, "prefix_attempts_used": 0, "system_settings_changed": False}
    runtime = Path(tempfile.mkdtemp(prefix="odf-sustained-arm-"))
    prefs = [Path(p).expanduser() for p in config.get("preference_paths", [])]
    def prefhash():
        return {str(p): sha(p) if p.exists() else None for p in prefs}
    state["preferences_before"] = prefhash()
    def save():
        temporary = state_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(state_path)
    def progress(status, **details):
        state.update(status=status, **details)
        save()
        print(json.dumps({"status": status, **details}), flush=True)
    save()
    preflight_log = (root / "preflight-records.jsonl").open("x")
    lock = None
    observer = None
    try:
        binary = Path(config["binary"]).expanduser().resolve(strict=True)
        model = Path(config["model_path"]).expanduser().resolve(strict=True)
        helper = Path(config["preflight_helper"]).expanduser().resolve(strict=True)
        real_work = config.get("real_work_fill_enabled", False)
        if not isinstance(real_work, bool):
            raise RuntimeError("Real-work filler requires an explicit boolean")
        filler = Path(config["filler_model_path"]).expanduser().resolve(strict=True) if real_work else None
        expected = {"binary": config["binary_sha256"], "model": config["model_sha256"]}
        actual = {"binary": sha(binary), "model": sha(model)}
        if filler is not None:
            expected["filler"] = config["filler_model_sha256"]
            actual["filler"] = sha(filler)
        state["expected_sha256"] = expected
        state["actual_sha256"] = actual
        if actual != expected:
            raise RuntimeError("Frozen binary/model hash mismatch; no native run")
        if config["mode"] not in ("paced24", "continuous"):
            raise RuntimeError("Unknown frozen mode")
        gap_fill = config.get("gap_fill_enabled", False)
        if not isinstance(gap_fill, bool) or (gap_fill and config["mode"] != "paced24"):
            raise RuntimeError("Gap fill requires an explicit boolean and paced24 mode")
        if real_work and (gap_fill or config["mode"] != "paced24"):
            raise RuntimeError("Real-work filler requires paced24 and cannot use ALU gap fill")
        resident_keepalive = config.get("resident_keepalive_enabled", False)
        if not isinstance(resident_keepalive, bool):
            raise RuntimeError("Resident keepalive requires an explicit boolean")
        if resident_keepalive and (real_work or gap_fill or config["mode"] != "paced24" or config["seconds"] != 180):
            raise RuntimeError("Resident keepalive requires paced24/180 with both filler modes disabled")
        observer_config = config.get("metrics_observer")
        if observer_config is not None and not isinstance(observer_config, dict):
            raise RuntimeError("Metrics observer requires an explicit configuration object")
        if observer_config is not None and (real_work or gap_fill):
            raise RuntimeError("Observed A/B keeps both filler modes disabled")
        if resident_keepalive and observer_config is None:
            raise RuntimeError("Resident keepalive requires the frozen hardware observer")
        allowed_seconds = (180, 600) if gap_fill else ((180,) if config["mode"] == "paced24" else (120,))
        if config["seconds"] not in allowed_seconds:
            raise RuntimeError("Duration differs from the approved arm")
        state["gap_fill_enabled"] = gap_fill
        state["real_work_fill_enabled"] = real_work
        state["resident_keepalive_enabled"] = resident_keepalive
        lock_path = Path(config["gpu_lock"]).expanduser()
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock = lock_path.open("a")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        last_gpu_end = parse_utc(config["project_last_gpu_end_utc"])
        if config.get("predecessor_state"):
            predecessor = json.loads(Path(config["predecessor_state"]).expanduser().read_text())
            if predecessor.get("status") != "complete":
                raise RuntimeError("Predecessor arm not complete; do not start this arm")
            last_gpu_end = max(last_gpu_end, parse_utc(predecessor["gpu_last_end_utc"]))
        native_env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}
        native_env.pop("ODF_AIR_FOURSTAGE_MODEL_PATH", None)
        native_env.pop("RIFE_DUMP_DIR", None)
        native_env.update(ODF_AIR_SERVICE_TRACE="1", ODF_PERF_PROFILE="off",
                          ODF_K1_PROFILE="0", RIFE_VERBOSE="0",
                          ODF_AIR_GAP_FILL_DIAGNOSTIC="1" if gap_fill else "0",
                          ODF_AIR_REAL_WORK_FILL_DIAGNOSTIC="1" if real_work else "0",
                          ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC="1" if resident_keepalive else "0")
        state["native_environment_overrides"] = {
            k: native_env[k] for k in ("ODF_AIR_SERVICE_TRACE", "ODF_PERF_PROFILE", "ODF_K1_PROFILE", "RIFE_VERBOSE", "ODF_AIR_GAP_FILL_DIAGNOSTIC", "ODF_AIR_REAL_WORK_FILL_DIAGNOSTIC", "ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC")}
        state["App_model_override_unset"] = True
        state["RIFE_dump_directory_unset"] = True
        save()

        preflight_serial = 0
        state["preflight_runtime_directory"] = str(runtime)

        def preflight(stage):
            nonlocal preflight_serial
            preflight_serial += 1
            # The real helper refuses an existing output path, including preflight-only.
            target = runtime / ("preflight-" + str(preflight_serial).zfill(5) + ".json")
            result = subprocess.run([str(helper), "--output", str(target), "--preflight-only",
                                     "--source-fps", "24", "--capture-format", "nv12",
                                     "--minimum-idle-seconds", "300"],
                                    capture_output=True, text=True, timeout=30)
            data = json.loads(target.read_text()) if target.exists() else None
            row = {"utc": utc_now(), "stage": stage, "exit_code": result.returncode,
                   "output_path": str(target), "result": data, "stderr": result.stderr}
            preflight_log.write(json.dumps(row) + "\n")
            preflight_log.flush()
            if "first_preflight" not in state:
                state["first_preflight"] = row
            state["last_preflight"] = row
            if result.returncode not in (0, 1) or data is None:
                state["failureKind"] = "helper_error"
                raise RuntimeError("Preflight helper invocation failed: exit " + str(result.returncode))
            return result.returncode == 0 and data.get("ok") is True, data.get("preflight", {})

        wait_deadline = time.monotonic() + config.get("max_wait_seconds", 1800)
        for attempt_index in range(1, config.get("max_prefix_attempts", 3) + 1):
            while True:
                ready, pre = preflight("cooldown")
                cooldown_remaining = max(0.0, last_gpu_end + 300 - time.time())
                if pre.get("displayAsleep") or pre.get("explicitLock"):
                    progress("precondition_unresolved", reason="Display asleep or locked; no wake/unlock")
                    return 0
                if ready and cooldown_remaining == 0:
                    break
                if time.monotonic() >= wait_deadline:
                    progress("precondition_unresolved", reason="Read-only wait limit reached")
                    return 0
                progress("waiting_readonly", cooldown_remaining_seconds=round(cooldown_remaining, 3))
                time.sleep(15)
            for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,pcpu=,command="], text=True).splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3 and "/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame" in fields[2]:
                    if float(fields[1]) > 10:
                        raise RuntimeError("Original trial app is busy; no sustained run")
            if prefhash() != state["preferences_before"]:
                raise RuntimeError("Trial preferences changed while waiting; stop without restoring")
            attempt_dir = root / ("attempt-" + str(attempt_index).zfill(2))
            attempt_dir.mkdir(exist_ok=False)
            result_path = attempt_dir / "native.json"
            cancel = attempt_dir / "CANCEL"
            args = [str(binary), "--output", str(result_path), "--mode", config["mode"],
                    "--seconds", str(config["seconds"]), "--baseline-seconds", "5",
                    "--model-path", str(model), "--model-sha256", config["model_sha256"],
                    "--cancel-file", str(cancel)]
            if filler is not None:
                args.extend(["--filler-model-path", str(filler),
                             "--filler-model-sha256", config["filler_model_sha256"]])
            row = {"index": attempt_index, "started_utc": utc_now(), "args": args,
                   "preflight_before": state["last_preflight"], "process_cpu_before": process_snapshot(),
                   "result": str(result_path), "status": "native_running"}
            state["attempts"].append(row)
            state["formal_measurements_started"] = None
            if observer_config is not None:
                from observe_metrics import MetricsObserver
                observer = MetricsObserver(observer_config, attempt_dir)
                observer.start()
                lead_deadline = time.monotonic() + 45
                progress("observer_preroll", active_attempt=attempt_index)
                while not observer.ready_for_native(minimum_lead_seconds=10):
                    observer.poll()
                    observer.clock_if_due()
                    row["metrics_observer"] = observer.snapshot()
                    if row["metrics_observer"].get("first_error"):
                        raise RuntimeError("Metrics observer failed before native launch")
                    ready, _ = preflight("observer-preroll")
                    if not ready:
                        raise RuntimeError("Session/display/input changed before native launch")
                    if time.monotonic() >= lead_deadline:
                        raise RuntimeError("Metrics observer did not become ready within 45 seconds")
                    save()
                    time.sleep(1)
                row["metrics_observer"] = observer.snapshot()
                if prefhash() != state["preferences_before"]:
                    raise RuntimeError("Trial preferences changed during observer preroll")
            progress("native_preparing", active_attempt=attempt_index)
            cancel_reason = None
            cancel_started = None
            with (attempt_dir / "stdout.jsonl").open("x") as stdout, (attempt_dir / "stderr.log").open("x") as stderr:
                process = subprocess.Popen(args, env=native_env, stdout=stdout, stderr=stderr)
                row["pid"] = process.pid
                start = time.monotonic()
                next_update = start
                try:
                    if observer is not None:
                        try:
                            observer.mark_native_started(pid=process.pid)
                        except Exception as error:
                            row.setdefault("metrics_observer_start_mark_error", str(error))
                    save()
                    while process.poll() is None:
                        if observer is not None:
                            try:
                                observer.poll()
                                observer.clock_if_due()
                            except Exception as error:
                                row.setdefault("metrics_observer_poll_error", str(error))
                        if cancel_reason is None:
                            try:
                                ready, _ = preflight("native-watch")
                                if not ready:
                                    state["failureKind"] = "precondition_change"
                                    row["failureKind"] = "precondition_change"
                                    cancel_reason = "Session/display/user-input precondition changed"
                            except Exception as error:
                                state["failureKind"] = "helper_error"
                                row["failureKind"] = "helper_error"
                                cancel_reason = "Preflight watch failed: " + str(error)
                            if time.monotonic() - start > config["seconds"] + 90:
                                cancel_reason = "Native wall-time limit exceeded"
                            if cancel_reason:
                                cancel.write_text(cancel_reason + "\n")
                                cancel_started = time.monotonic()
                                row["cancel_requested_utc"] = utc_now()
                                row["cancel_reason"] = cancel_reason
                                save()
                        if cancel_started is not None and time.monotonic() - cancel_started > 30:
                            process.terminate()
                            row["only_own_native_terminated"] = process.pid
                        if time.monotonic() >= next_update:
                            progress("native_running", active_attempt=attempt_index,
                                     elapsed_native_seconds=round(time.monotonic() - start, 3))
                            next_update = time.monotonic() + 15
                        time.sleep(1)
                finally:
                    if process.poll() is None:
                        if not cancel.exists():
                            cancel.write_text("Coordinator stopped\n")
                        try:
                            process.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            process.terminate()
                            row["only_own_native_terminated"] = process.pid
                            try:
                                process.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                row["only_own_native_killed"] = process.pid
                                process.wait(timeout=10)
                    if observer is not None:
                        try:
                            observer.mark_native_finished(returncode=process.returncode)
                            observer.stop_after_native(post_seconds=10)
                        except Exception as error:
                            row.setdefault("metrics_observer_stop_error", str(error))
                        row["metrics_observer"] = observer.snapshot()
            row["exit_code"] = process.returncode
            row["completed_utc"] = utc_now()
            row["process_cpu_after"] = process_snapshot()
            try:
                preflight("native-end-observation")
                row["preflight_after"] = state["last_preflight"]
            except Exception as error:
                row["end_preflight_observation_error"] = str(error)
            state["gpu_last_end_utc"] = row["completed_utc"]
            last_gpu_end = parse_utc(row["completed_utc"])
            if not result_path.exists():
                raise RuntimeError("Native result missing; retain first failure, no retry")
            native = json.loads(result_path.read_text())
            row["native_status"] = native.get("status")
            row["native_failureKind"] = native.get("failureKind")
            if isinstance(native.get("formalStarted"), bool):
                state["formal_measurements_started"] = int(native["formalStarted"])
            if native.get("status") in ("complete", "baseline_not_ready") or native.get("baselineGate", {}).get("sampleCount", 0) > 0:
                state["prefix_attempts_used"] += 1
            if native.get("status") == "calibration_failed":
                state["failureKind"] = "calibration_failed"
                row["failureKind"] = "calibration_failed"
            row["native_sha256"] = sha(result_path)
            row["status"] = "finished"
            observer_failed = observer is not None and bool(
                row.get("metrics_observer", {}).get("first_error")
                or row.get("metrics_observer_start_mark_error")
                or row.get("metrics_observer_poll_error")
                or row.get("metrics_observer_stop_error"))
            row["metrics_observer_failed"] = observer_failed
            if native.get("status") == "complete" and process.returncode == 0 and not cancel_reason:
                state["formal_measurements_started"] = 1
                if observer_failed:
                    progress("observation_incomplete", reason="Native retained; observer failed; no further run")
                    return 0
                progress("complete")
                return 0
            if native.get("status") == "baseline_not_ready" and process.returncode == 3 and not cancel_reason:
                state["formal_measurements_started"] = 0
                if "first_baseline_failure" not in state:
                    state["first_baseline_failure"] = dict(row)
                if observer_failed:
                    progress("observation_incomplete", reason="Prefix retained; observer failed; no retry")
                    return 0
                progress("baseline_not_ready", active_attempt=attempt_index)
                if time.monotonic() >= wait_deadline:
                    break
                continue
            raise RuntimeError("Native stopped or failed; no repeated formal measurement")
        progress("precondition_unresolved", reason="Allowed baseline prefixes retained; no formal run")
        return 0
    except Exception as error:
        state["first_error"] = str(error)
        progress("incomplete")
        return 1
    finally:
        if observer is not None:
            try:
                observer.close()
                state["last_metrics_observer"] = observer.snapshot()
                if state["last_metrics_observer"].get("first_error") and state["status"] == "complete":
                    state["status"] = "observation_incomplete"
            except Exception as error:
                state.setdefault("metrics_observer_cleanup_error", str(error))
                if state["status"] == "complete":
                    state["status"] = "observation_incomplete"
        state["completed_utc"] = utc_now()
        state["preferences_after"] = prefhash()
        state["preferences_unchanged"] = state["preferences_after"] == state["preferences_before"]
        save()
        preflight_log.close()
        if lock is not None:
            lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.config))


if __name__ == "__main__":
    main()
