#!/usr/bin/env python3
"""Compare GPU BGRA padding with CPU edge padding plus the original conversion.

All machine-specific inputs come from command-line options or environment.
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
        ("--padded-metal", "K1_PADDED_METAL", "PaddedFrameConvert.metal"),
        ("--padded-swift", "K1_PADDED_SWIFT", "PaddedFrameConvert.swift"),
        ("--build-dir", "K1_PADDED_CHECK_BUILD", "Dedicated compiler and checker output directory"),
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
    for source, output in [(args.padded_metal, "padded.air"), (args.product_metal, "baseline.air")]:
        subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-c",
                        str(source.expanduser().resolve()), "-o", str(build / output)],
                       env=env, check=True)
    subprocess.run(["xcrun", "-sdk", "macosx", "metallib", str(build / "padded.air"),
                    str(build / "baseline.air"), "-o", str(build / "default.metallib")],
                   env=env, check=True)
    test_source = Path(__file__).with_name("PaddedFrameConvertBitwise.swift").read_text()
    source = args.padded_swift.expanduser().read_text() + "\n" + test_source
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
