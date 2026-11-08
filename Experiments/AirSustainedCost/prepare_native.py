#!/usr/bin/env python3
"""Add a sustained-cost executable to a fresh copy of the frozen trace runtime.

This prepares source only. It never builds, runs Metal, replaces a model, or
modifies the input runtime. Build with SwiftPM --jobs 4 after preparation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one package anchor: {old!r}")
    return text.replace(old, new, 1)


def prepare(source: Path, output: Path) -> dict[str, object]:
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.exists() or output == source or source in output.parents or output in source.parents:
        raise ValueError("output must be a fresh directory outside the source runtime")
    here = Path(__file__).resolve().parent
    required = ("Package.swift", "Sources", "Plugins", "LICENSE", "THIRD-PARTY.md",
                "source-origin.json", "air-service-trace-source.json",
                "air-fourstage-runtime-origin.json")
    for name in required:
        if not (source / name).exists():
            raise ValueError(f"frozen combined-runtime input missing: {name}")
    interpolator = (source / "Sources/RifeMetal/RifeInterpolator.swift").read_text()
    for anchor in ("public func airServiceTraceBegin", "public var airServiceTraceCount",
                   "public func airServiceTraceRecord", "public var airDiagnosticModelIdentity",
                   '"sha256": weights.airDiagnosticSourceSHA256'):
        if anchor not in interpolator:
            raise ValueError(f"combined runtime API missing: {anchor}")
    original = {str(p.relative_to(source)): sha(p)
                for name in required for p in
                (sorted((source / name).rglob("*")) if (source / name).is_dir() else [source / name])
                if p.is_file()}
    output.mkdir(parents=True)
    for name in required:
        item = source / name
        if item.is_dir():
            shutil.copytree(item, output / name)
        else:
            shutil.copy2(item, output / name)
    package = output / "Package.swift"
    text = package.read_text()
    text = once(text, '        .library(name: "RifeMetal", targets: ["RifeMetal", "RifeMetalCore"]),',
                '        .library(name: "RifeMetal", targets: ["RifeMetal", "RifeMetalCore"]),\n'
                '        .executable(name: "air-sustained-cost", targets: ["air-sustained-cost"]),')
    text = once(text, '    targets: [\n', '    targets: [\n'
                '        .executableTarget(name: "air-sustained-cost", dependencies: ["RifeMetal", "RifeMetalCore"]),\n')
    package.write_text(text)
    target = output / "Sources/air-sustained-cost"
    target.mkdir()
    shutil.copyfile(here / "native/sustained.swift", target / "main.swift")
    for relative, expected in original.items():
        if sha(source / relative) != expected:
            raise ValueError(f"input changed during preparation: {relative}")
        if relative != "Package.swift" and sha(output / relative) != expected:
            raise ValueError(f"runtime copy differs: {relative}")
    result = {
        "format": "odf-air-sustained-native-v1",
        "sourceRuntime": str(source),
        "sourceSHA256": original,
        "preparerSHA256": sha(Path(__file__)),
        "driverSHA256": sha(here / "native/sustained.swift"),
        "packageSHA256": sha(package),
        "runtimeSourcesByteIdentical": True,
        "modelResourcesUnchanged": True,
        "built": False,
        "gpuExecuted": False,
        "scope": "New trace-bearing executable; not the old cost binary. Same synthetic fixture, caller output, and push wall scope.",
    }
    (output / "air-sustained-native-origin.json").write_text(json.dumps(result, indent=2) + "\n")
    return {"output": str(output), "runtimeFilesVerified": len(original),
            "driverSHA256": result["driverSHA256"], "sourceOnly": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="frozen combined trace runtime")
    parser.add_argument("--output", type=Path, required=True, help="fresh generated package directory")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output)))


if __name__ == "__main__":
    main()
