"""Coordinate one Apple FRC native run without changing the user's app or settings."""
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


def run(config_path):
    config = json.loads(config_path.read_text())
    root = config_path.resolve().parent
    state_path = root / "coordinator-state.json"
    if state_path.exists():
        raise SystemExit("Existing coordinator retained; no repeat or overwrite")
    state = {"schema": "odf.apple-frc-native-coordinator.v1", "started_utc": utc_now(),
             "status": "starting", "native_launches": 0, "formal_measurements_started": None,
             "performance_accepted": False, "system_settings_changed": False,
             "scope": "One native diagnostic, not App output-FPS or quality acceptance"}
    runtime = Path(tempfile.mkdtemp(prefix="odf-apple-frc-preflight-"))
    prefs = [Path(p).expanduser() for p in config.get("preference_paths", [])]
    prefhash = lambda: {str(p): sha(p) if p.exists() else None for p in prefs}
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
    try:
        binary = Path(config["binary"]).expanduser().resolve(strict=True)
        helper = Path(config["preflight_helper"]).expanduser().resolve(strict=True)
        if config["seconds"] != 120 or config["baseline_seconds"] != 5:
            raise RuntimeError("Duration differs from the frozen single-run contract")
        state["expected_binary_sha256"] = config["binary_sha256"]
        state["actual_binary_sha256"] = sha(binary)
        if state["actual_binary_sha256"] != state["expected_binary_sha256"]:
            raise RuntimeError("Frozen native binary hash mismatch")
        lock_path = Path(config["gpu_lock"]).expanduser()
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock = lock_path.open("a")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        last_end = dt.datetime.fromisoformat(config["project_last_gpu_end_utc"].replace("Z", "+00:00")).timestamp()
        native_env = {k: v for k, v in os.environ.items()
                      if not k.startswith(("ANTHROPIC_", "ODF_AIR_"))}
        native_env.pop("RIFE_DUMP_DIR", None)
        native_env.pop("CHUANFLOW_FRC_CONTINUOUS", None)
        state["RIFE_environment_removed"] = True
        state["continuous_FRC_override_removed"] = True
        state["preflight_runtime_directory"] = str(runtime)
        serial = 0

        def preflight(stage):
            nonlocal serial
            serial += 1
            target = runtime / ("preflight-" + str(serial).zfill(5) + ".json")
            result = subprocess.run([str(helper), "--output", str(target), "--preflight-only",
                                     "--source-fps", "24", "--capture-format", "nv12",
                                     "--minimum-idle-seconds", "300"],
                                    capture_output=True, text=True, timeout=30, env=native_env)
            data = json.loads(target.read_text()) if target.exists() else None
            row = {"utc": utc_now(), "stage": stage, "exit_code": result.returncode,
                   "output_path": str(target), "result": data, "stderr": result.stderr}
            preflight_log.write(json.dumps(row) + "\n")
            preflight_log.flush()
            state.setdefault("first_preflight", row)
            state["last_preflight"] = row
            if result.returncode not in (0, 1) or data is None:
                state["failureKind"] = "helper_error"
                raise RuntimeError("Preflight helper failed; no stale-output reuse")
            return result.returncode == 0 and data.get("ok") is True, data.get("preflight", {})

        deadline = time.monotonic() + config.get("max_wait_seconds", 1800)
        while True:
            ready, pre = preflight("cooldown")
            remaining = max(0.0, last_end + 300 - time.time())
            if pre.get("displayAsleep") or pre.get("explicitLock"):
                progress("precondition_unresolved", reason="Display asleep or locked; no wake/unlock")
                return 0
            if ready and remaining == 0:
                break
            if time.monotonic() >= deadline:
                progress("precondition_unresolved", reason="Read-only wait limit reached")
                return 0
            progress("waiting_readonly", cooldown_remaining_seconds=round(remaining, 3))
            time.sleep(15)
        if prefhash() != state["preferences_before"]:
            raise RuntimeError("Trial preferences changed while waiting; stop without restoring")
        for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,pcpu=,command="], text=True).splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and "/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame" in fields[2]:
                state["original_trial_CPU_before"] = {"pid": int(fields[0]), "cpu_percent": float(fields[1]),
                    "scope": "CPU snapshot only; neither GPU-exclusive nor inactive proof"}
                if float(fields[1]) > 10:
                    raise RuntimeError("Original trial app is busy; stop without changing it")
        result_path = root / "native.json"
        cancel = root / "CANCEL"
        args = [str(binary), "--output", str(result_path), "--seconds", "120",
                "--baseline-seconds", "5", "--cancel-file", str(cancel)]
        state.update(args=args, native_launch_prepared_utc=utc_now(), launch_attempts=1,
                     preflight_before=state["last_preflight"])
        progress("preparing_native")
        reason = None
        cancel_started = None
        with (root / "native.stdout.jsonl").open("x") as stdout, (root / "native.stderr.log").open("x") as stderr:
            process = subprocess.Popen(args, env=native_env, stdout=stdout, stderr=stderr)
            state.update(pid=process.pid, native_launches=1, native_started_utc=utc_now())
            save()
            start = time.monotonic()
            next_update = start
            try:
                while process.poll() is None:
                    if reason is None:
                        try:
                            ready, _ = preflight("native-watch")
                            if not ready:
                                state["failureKind"] = "precondition_change"
                                reason = "Session/display/input precondition changed"
                        except Exception as error:
                            state["failureKind"] = "helper_error"
                            reason = "Preflight watch failed: " + str(error)
                        if time.monotonic() - start > 210:
                            reason = "Native wall-time limit exceeded"
                        if reason:
                            cancel.write_text(reason + "\n")
                            cancel_started = time.monotonic()
                            state.update(cancel_reason=reason, cancel_requested_utc=utc_now())
                            save()
                    if cancel_started is not None and time.monotonic() - cancel_started > 30:
                        process.terminate()
                        state["only_own_native_terminated"] = process.pid
                    if time.monotonic() >= next_update:
                        progress("native_running", elapsed_native_seconds=round(time.monotonic() - start, 3))
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
                        state["only_own_native_terminated"] = process.pid
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            state["only_own_native_killed"] = process.pid
                            process.wait(timeout=10)
        state.update(exit_code=process.returncode, gpu_last_end_utc=utc_now())
        try:
            preflight("native-end-observation")
            state["preflight_after"] = state["last_preflight"]
        except Exception as error:
            state["end_preflight_observation_error"] = str(error)
        if not result_path.exists():
            raise RuntimeError("Native result missing; retain first failure, no retry")
        native = json.loads(result_path.read_text())
        state.update(native_sha256=sha(result_path), native_status=native.get("status"),
                     formal_measurements_started=int(native["formalStarted"]) if isinstance(native.get("formalStarted"), bool) else None)
        if native.get("status") != "complete" or native.get("formalStarted") is not True or process.returncode != 0 or reason:
            raise RuntimeError("Native failed or stopped; no repeated formal measurement")
        progress("complete")
        return 0
    except Exception as error:
        state["first_error"] = str(error)
        if state["native_launches"] == 0:
            state.setdefault("failureKind", "coordinator_startup")
        progress("incomplete")
        return 1
    finally:
        state.update(completed_utc=utc_now(), preferences_after=prefhash())
        state["preferences_unchanged"] = state["preferences_before"] == state["preferences_after"]
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
