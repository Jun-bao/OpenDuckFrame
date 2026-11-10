#!/usr/bin/env python3
"""Link the actual local production package and compare outputs with frozen d0 hashes.

No production sources are copied or edited. The only new SPM target lives in
the supplied build directory. The result directory must not already exist.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def package_inventory(package):
    files = [package / "Package.swift"]
    for folder in ("Sources", "Plugins"):
        files.extend(p for p in (package / folder).rglob("*") if p.is_file())
    entries = {str(p.relative_to(package)): sha(p) for p in sorted(files)}
    tree_hash = hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"tree_sha256": tree_hash, "files": entries}


def write_if_changed(path, text):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = [
        ("--package", "ODF_PRODUCTION_PACKAGE", "Actual production RifeMetal Swift package directory"),
        ("--config", "ODF_PROBE_CONFIG", "Frozen io-fast-parity/config.json"),
        ("--baseline", "ODF_PROBE_BASELINE", "Frozen io-fast-parity/quality.json; only d0 rows are used"),
        ("--build-dir", "ODF_PROBE_BUILD", "Probe-only package and compiler output directory"),
        ("--output-dir", "ODF_PROBE_OUTPUT", "New result directory (must not exist)"),
        ("--gpu-lock", "ODF_GPU_LOCK", "Shared non-blocking GPU measurement lock"),
    ]
    for flag, variable, description in options:
        default = os.environ.get(variable)
        parser.add_argument(flag, type=Path, default=default, required=not default,
                            help=f"{description}; environment: {variable}")
    parser.add_argument("--developer-dir", default=os.environ.get("DEVELOPER_DIR"),
                        help="Xcode developer directory; defaults to DEVELOPER_DIR or xcrun selection")
    parser.add_argument("--compile-only", action="store_true", help="Build without creating results or running GPU work")
    args = parser.parse_args()
    package = args.package.expanduser().resolve()
    config_path = args.config.expanduser().resolve()
    baseline_path = args.baseline.expanduser().resolve()
    build = args.build_dir.expanduser().resolve()
    output = args.output_dir.expanduser().resolve()
    config = json.loads(config_path.read_text())
    baseline = json.loads(baseline_path.read_text())
    if config["tier"] != "fast" or not config.get("app_entrypoints"):
        raise ValueError("expected the unchanged Fast app-entrypoint configuration")
    if not any(row["variant"] == "d0" for row in baseline["rows"]):
        raise ValueError("frozen baseline contains no d0 rows")
    before = package_inventory(package)
    build.mkdir(parents=True, exist_ok=True)
    temporary = build / "package"
    sources = temporary / "Sources/ProductionRuntimeProbe"
    sources.mkdir(parents=True, exist_ok=True)
    probe_source = Path(__file__).with_name("ProductionRuntimeProbe.swift")
    write_if_changed(sources / "ProductionRuntimeProbe.swift", probe_source.read_text())
    manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "ProductionRuntimeProbe", platforms: [.macOS(.v13)],
    products: [.executable(name: "production-runtime-probe", targets: ["ProductionRuntimeProbe"])],
    dependencies: [.package(name: "ProductionRifeMetal", path: %s)],
    targets: [.executableTarget(name: "ProductionRuntimeProbe", dependencies: [
        .product(name: "RifeMetal", package: "ProductionRifeMetal")
    ])]
)
''' % json.dumps(str(package), ensure_ascii=False)
    write_if_changed(temporary / "Package.swift", manifest)
    env = dict(os.environ)
    if args.developer_dir:
        env["DEVELOPER_DIR"] = str(Path(args.developer_dir).expanduser().resolve())
    env["ODF_PERF_PROFILE"] = "off"
    env.pop("RIFE_DUMP_DIR", None)
    env.pop("ODF_K1_PROFILE", None)
    command = ["xcrun", "swift", "build", "--package-path", str(temporary),
               "--scratch-path", str(build / "swift-build"), "-c", "release", "--jobs", "4"]
    log_path = build / "build.log"
    with log_path.open("a") as log:
        log.write(f"\nBuild attempt {datetime.now(timezone.utc).isoformat()}\n")
        log.flush()
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        print(f"Build failed; log: {log_path}", file=sys.stderr)
        return result.returncode
    bin_dir = Path(subprocess.check_output(command + ["--show-bin-path"], text=True, env=env).strip())
    binary = bin_dir / "production-runtime-probe"
    after_build = package_inventory(package)
    if before != after_build:
        raise RuntimeError("production source identity changed while building; probe not run")
    if args.compile_only:
        print(f"Production probe compiled; GPU not run: {binary}")
        return 0

    with args.gpu_lock.expanduser().open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("GPU probe not run: measurement lock is held", file=sys.stderr)
            return 2
        output.mkdir(parents=True, exist_ok=False)
        shutil.copyfile(log_path, output / "build.log")
        shutil.copyfile(config_path, output / "config.json")
        provenance = {
            "started_at_utc": datetime.now(timezone.utc).isoformat(),
            "production_package": str(package), "package_before_build": before,
            "package_after_build": after_build,
            "probe_swift_sha256": sha(probe_source), "runner_sha256": sha(Path(__file__)),
            "generated_manifest_sha256": sha(temporary / "Package.swift"),
            "binary_path": str(binary), "binary_sha256": sha(binary),
            "config_path": str(config_path), "config_sha256": sha(config_path),
            "baseline_path": str(baseline_path), "baseline_sha256": sha(baseline_path),
            "baseline_variant": "d0", "build_command": command,
            "developer_dir": env.get("DEVELOPER_DIR"), "performance_measured": False,
            "input_sha256": {item[key]: sha(Path(item[key])) for item in config["cases"] for key in ("first", "second")},
        }
        original_model = Path(next(variant["model"] for variant in config["variants"] if variant["id"] == "d0"))
        provenance["frozen_config_original_model"] = str(original_model)
        provenance["original_model_sha256"] = sha(original_model)
        report_path = output / "quality.json"
        run = subprocess.run([str(binary), str(config_path), str(baseline_path), str(report_path)],
                             capture_output=True, text=True, env=env)
        (output / "runtime.stdout.log").write_text(run.stdout)
        (output / "runtime.stderr.log").write_text(run.stderr)
        after_run = package_inventory(package)
        provenance["package_after_run"] = after_run
        provenance["package_unchanged"] = before == after_run
        provenance["runtime_returncode"] = run.returncode
        provenance["completed_at_utc"] = datetime.now(timezone.utc).isoformat()
        if report_path.exists():
            provenance["quality_sha256"] = sha(report_path)
            quality = json.loads(report_path.read_text())
            provenance["bundled_model_matches_original"] = quality["bundled_model_sha256"] == provenance["original_model_sha256"]
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2, ensure_ascii=False) + "\n")
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if before != after_run:
            print("Production source identity changed during probe", file=sys.stderr)
            return 1
        if provenance.get("bundled_model_matches_original") is not True:
            print("Bundled model identity was not verified against the frozen config's original weights", file=sys.stderr)
            return 1
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
