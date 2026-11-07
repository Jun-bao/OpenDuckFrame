#!/usr/bin/env python3
"""Compile the original and fused shaders, then compare four fp16 outputs.

All machine-specific inputs come from command-line options or environment.
The GPU lock is non-blocking and is held only while the checker executes.
The build directory receives default.metallib, check, and validation.log.
"""

import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    options = [
        ("--product-metal", "K1_PRODUCT_METAL", "Original pinned product Shaders/BackwardWarp.metal"),
        ("--fused-metal", "K1_FUSED_METAL", "FusedStageWarp.metal"),
        ("--fused-swift", "K1_FUSED_SWIFT", "FusedStageWarp.swift"),
        ("--build-dir", "K1_WARP_CHECK_BUILD", "Dedicated compiler and checker output directory"),
        ("--gpu-lock", "K1_GPU_LOCK", "Shared GPU measurement lock file"),
    ]
    for flag, variable, description in options:
        default = os.environ.get(variable)
        parser.add_argument(flag, type=Path, default=default, required=not default,
                            help=f"{description}; environment: {variable}")
    parser.add_argument("--developer-dir", default=os.environ.get("DEVELOPER_DIR"),
                        help="Xcode developer directory; defaults to DEVELOPER_DIR or xcrun selection")
    parser.add_argument("--compile-only", action="store_true", help="Compile without running GPU work")
    args = parser.parse_args()

    build = args.build_dir.expanduser().resolve()
    build.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    if args.developer_dir:
        env["DEVELOPER_DIR"] = str(Path(args.developer_dir).expanduser().resolve())
    for source, output in [(args.fused_metal, "fused.air"), (args.product_metal, "baseline.air")]:
        subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-c",
                        str(source.expanduser().resolve()), "-o", str(build / output)],
                       env=env, check=True)
    subprocess.run(["xcrun", "-sdk", "macosx", "metallib", str(build / "fused.air"),
                    str(build / "baseline.air"), "-o", str(build / "default.metallib")],
                   env=env, check=True)

    test_source = Path(__file__).with_name("FusedStageWarpBitwise.swift").read_text()
    # A single source input avoids consuming stdin in two Swift frontend jobs.
    source = args.fused_swift.expanduser().read_text() + "\n" + test_source
    subprocess.run(["xcrun", "-sdk", "macosx", "swiftc", "-O", "-parse-as-library",
                    "-", "-o", str(build / "check")],
                   input=source, text=True, env=env, check=True)
    if args.compile_only:
        print("Metal and Swift compilation passed; GPU check not run")
        return 0

    with args.gpu_lock.expanduser().open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("GPU check not run: measurement lock is held", file=sys.stderr)
            return 2
        result = subprocess.run([str(build / "check")], capture_output=True, text=True, env=env)
        (build / "validation.log").write_text(result.stdout + result.stderr)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
