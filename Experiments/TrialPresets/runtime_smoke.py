"""Build or run the small synthetic RifeExperimentOptions function smoke."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, default=Path(__file__).resolve().parents[2] / "ThirdParty/rife-metal/runtime")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--gpu-lock", type=Path)
    parser.add_argument("--run", action="store_true", help="explicitly run after building, under the nonblocking project GPU lock")
    args = parser.parse_args()
    if args.run and (args.config is None or args.gpu_lock is None):
        parser.error("--run requires --config and --gpu-lock")
    workspace, runtime = args.workspace.resolve(), args.runtime.resolve()
    marker = workspace / "trial-smoke-source.json"
    if workspace.exists() and not marker.is_file():
        raise FileExistsError("workspace exists without this smoke's ownership marker")
    source = Path(__file__).with_name("RuntimeSmoke.swift")
    target = workspace / "Sources/runtime-trial-smoke/main.swift"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(source.read_bytes())
    (workspace / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RuntimeTrialSmoke", platforms: [.macOS(.v13)],
    dependencies: [.package(name: "RifeMetal", path: ''' + json.dumps(str(runtime)) + ''')],
    targets: [.executableTarget(name: "runtime-trial-smoke", dependencies: [.product(name: "RifeMetal", package: "RifeMetal")])])
''')
    marker.write_text(json.dumps(dict(source_sha256=sha(source), runtime=str(runtime),
        runtime_origin_sha256=sha(runtime / "source-origin.json")), indent=2) + "\n")
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    subprocess.run(["swift", "build", "-c", "release", "--jobs", "4"], cwd=workspace, env=env, check=True)
    binary = workspace / ".build/release/runtime-trial-smoke"
    if args.run:
        env.update(ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
        for key in ("ODF_K1_PROFILE", "RIFE_DUMP_DIR"):
            env.pop(key, None)
        with args.gpu_lock.open("a+") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SystemExit("GPU lock is busy; smoke was not run")
            subprocess.run([str(binary), str(args.config.resolve())], env=env, check=True)
    print(json.dumps(dict(binary=str(binary), binary_sha256=sha(binary), gpu_run=args.run)))


if __name__ == "__main__":
    main()
