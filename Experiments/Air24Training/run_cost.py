"""Run the fixed private Air cost package once; no UI/capture/permission changes.

The caller coordinates Air idle/session preflight and excludes other benchmarks.
Default --preflight-only checks the package without starting a Metal process.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

import analyze_cost


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--preflight-only", action="store_true")
    args=ap.parse_args()
    if args.run and args.preflight_only:raise ValueError("choose run or preflight only")
    root=Path(__file__).resolve().parent
    manifest=json.loads((root/"package-manifest.json").read_text())
    for name,digest in manifest["files_sha256"].items():
        if sha(root/name)!=digest:raise ValueError(f"package SHA mismatch:{name}")
    config=json.loads((root/"config-template.json").read_text())
    for key in ("original_model","student_model"):
        config[key]=str(root/config[key])
    print(json.dumps(dict(package_valid=True,code_unchanged=True,source="deterministic owned BGRA inputs",
                         width=config["width"],height=config["height"],
                         GPU_started=False,original_sha256=config["original_sha256"],
                         student_sha256=config["student_sha256"])),flush=True)
    if not args.run:return
    result=root/"result"
    result.mkdir(exist_ok=False)
    config["output"]=str(result/"raw.json")
    write(result/"run-config.json",config)
    status=dict(status="starting",started_utc=datetime.now(timezone.utc).isoformat(),
                package_manifest_sha256=sha(root/"package-manifest.json"),
                scope="Air native model cost only; no App/capture/presenter/Safari or24FPS acceptance")
    write(result/"run-status.json",status)
    env=dict(os.environ,ODF_PERF_PROFILE="off",ODF_K1_PROFILE="0",RIFE_VERBOSE="0")
    env.pop("RIFE_DUMP_DIR",None)
    env.pop("ODF_STUDENT_STATE_DUMP_DIR",None)
    started=time.monotonic()
    with (root.parent/"gpu-measurement.lock").open("a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:
            with (result/"native.stdout.log").open("w") as stdout,(result/"native.stderr.log").open("w") as stderr:
                process=subprocess.run([str(root/"air24-cost"),str(result/"run-config.json")],cwd=root,
                                       env=env,stdout=stdout,stderr=stderr,timeout=180)
            status["native_exit_code"]=process.returncode
            if process.returncode:raise RuntimeError("native cost process failed; preserved raw/logs")
            raw=json.loads((result/"raw.json").read_text())
            analysis=analyze_cost.analyze(raw)
            analysis["raw_sha256"]=sha(result/"raw.json")
            write(result/"analysis.json",analysis)
            status.update(status="completed",cost_screen_passed=analysis["cost_screen_passed"])
        except Exception as error:
            status.update(status="failed",first_failure=f"{type(error).__name__}: {error}")
            raise
        finally:
            status["elapsed_seconds"]=time.monotonic()-started
            write(result/"run-status.json",status)
            fcntl.flock(lock,fcntl.LOCK_UN)
    print(json.dumps(analysis),flush=True)


if __name__=="__main__":main()
