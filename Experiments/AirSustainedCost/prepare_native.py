#!/usr/bin/env python3
"""Add a sustained-cost executable to a fresh copy of the frozen trace runtime.

This copies a pinned diagnostic metallib when supplied, otherwise compiles the
independent diagnostic shader offline, then prepares Swift source. It never
executes GPU work, replaces a model, or modifies the input runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one package anchor: {old!r}")
    return text.replace(old, new, 1)


def prepare(source: Path, output: Path, gap_fill_metallib: Path | None = None) -> dict[str, object]:
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.exists() or output == source or source in output.parents or output in source.parents:
        raise ValueError("output must be a fresh directory outside the source runtime")
    if gap_fill_metallib is not None:
        gap_fill_metallib = gap_fill_metallib.resolve(strict=True)
        if sha(gap_fill_metallib) != "ccea3d2f9675947963f446fb08ad3718164ef7624b4075a280f31edff716d67e":
            raise ValueError("diagnostic metallib must match the frozen original shader artifact")
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
                '        .executableTarget(name: "air-sustained-cost", dependencies: ["RifeMetal", "RifeMetalCore"], resources: [.copy("Resources/gap-fill.metallib")]),\n')
    package.write_text(text)
    target = output / "Sources/air-sustained-cost"
    target.mkdir()
    shutil.copyfile(here / "native/sustained.swift", target / "main.swift")
    shutil.copyfile(here / "native/GapFill.swift", target / "GapFill.swift")
    shutil.copyfile(here / "native/RealWorkFill.swift", target / "RealWorkFill.swift")
    shutil.copyfile(here / "native/ResidentKeepAlive.swift", target / "ResidentKeepAlive.swift")
    resources = target / "Resources"
    resources.mkdir()
    shader_build = output / "GapFillShaderBuild"
    shader_build.mkdir()
    shutil.copyfile(here / "native/GapFill.metal", shader_build / "GapFill.metal")
    shader_commands = []
    if gap_fill_metallib is not None:
        shutil.copyfile(gap_fill_metallib, resources / "gap-fill.metallib")
    else:
        shader_commands = [
            ["xcrun", "--sdk", "macosx", "metal", "-c", str(shader_build / "GapFill.metal"),
             "-o", str(shader_build / "GapFill.air")],
            ["xcrun", "--sdk", "macosx", "metallib", str(shader_build / "GapFill.air"),
             "-o", str(resources / "gap-fill.metallib")],
        ]
        with (output / "gap-fill-shader-build.log").open("w") as log:
            for command in shader_commands:
                completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
                if completed.returncode:
                    raise RuntimeError(f"offline diagnostic shader compilation failed: {command[3]}")
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
        "gapFillDriverSHA256": sha(here / "native/GapFill.swift"),
        "realWorkFillDriverSHA256": sha(here / "native/RealWorkFill.swift"),
        "residentKeepAliveDriverSHA256": sha(here / "native/ResidentKeepAlive.swift"),
        "gapFillShaderSHA256": sha(here / "native/GapFill.metal"),
        "gapFillMetallibSHA256": sha(resources / "gap-fill.metallib"),
        "gapFillOfflineShaderCommands": shader_commands,
        "gapFillMetallibSource": str(gap_fill_metallib) if gap_fill_metallib is not None else None,
        "gapFillMetallibCopiedByteIdentical": gap_fill_metallib is not None and
            sha(gap_fill_metallib) == sha(resources / "gap-fill.metallib"),
        "gapFillRuntimeShaderCompilation": False,
        "packageSHA256": sha(package),
        "runtimeSourcesByteIdentical": True,
        "modelResourcesUnchanged": True,
        "built": False,
        "gpuExecuted": False,
        "scope": "New trace-bearing executable; not the old cost binary. Same synthetic fixture, caller output, and push wall scope.",
    }
    (output / "air-sustained-native-origin.json").write_text(json.dumps(result, indent=2) + "\n")
    return {"output": str(output), "runtimeFilesVerified": len(original),
            "driverSHA256": result["driverSHA256"], "swiftBuilt": False,
            "diagnosticShaderCompiledOffline": gap_fill_metallib is None,
            "diagnosticMetallibCopied": gap_fill_metallib is not None, "gpuExecuted": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="frozen combined trace runtime")
    parser.add_argument("--output", type=Path, required=True, help="fresh generated package directory")
    parser.add_argument("--gap-fill-metallib", type=Path, help="reuse the frozen original diagnostic metallib")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.gap_fill_metallib)))


if __name__ == "__main__":
    main()
