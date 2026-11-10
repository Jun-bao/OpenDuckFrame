#!/usr/bin/env python3
"""Prepare/build the existing Apple FRC engine in a fresh CPU-only native target.

Copies canonical sources, injects setup-only observation, offline-compiles the
existing shader and compiles three Objective-C++ translation units (CPU <=3).
Never runs the executable, creates a VT session, or requests GPU work.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


VIDEO = "Modules/VideoEnhancement"
BRIDGE = "Modules/MediaCore/Bridge"
INPUTS = [f"{VIDEO}/{name}" for name in (
    "SPFRCEngine.h", "SPFRCEngine.mm", "SPFrameBudgetMetal.h", "SPFrameBudgetMetal.mm",
    "SPFrameBudgetPlanner.hpp", "SPMotionFrameCompatibility.hpp", "SPFRCContinuity.hpp",
    "Shaders/FrameBudget.metal")]
INPUTS += [f"{BRIDGE}/{name}" for name in (
    "SPRuntimeGates.hpp", "SPPlanarPixelFormat.h", "SPDoviFrame.h", "SPShaderUniforms.h", "SPDoviUniformLayout.hpp")]


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1: raise ValueError(f"expected one observation anchor: {old[:80]!r}")
    return text.replace(old, new, 1)


def prepare(source, output):
    source, output = Path(source).resolve(strict=True), Path(output).resolve()
    if output.exists() or output == source:
        raise ValueError("fresh output distinct from canonical source required")
    here = Path(__file__).resolve().parent
    original = {name: sha(source / name) for name in INPUTS}
    output.mkdir(parents=True)
    copied = output / "source"
    for name in INPUTS:
        target = copied / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    engine = copied / VIDEO / "SPFRCEngine.mm"
    text = engine.read_text()
    declaration = '\nextern "C" void ODFAppleFRCObserveSetup(NSDictionary *event);\n'
    text = once(text, '#import "SPFRCEngine.h"\n', '#import "SPFRCEngine.h"\n' + declaration)
    observation = '''        ODFAppleFRCObserveSetup(@{
            @"stage": @"actual_configuration", @"width": @(cfg.frameWidth), @"height": @(cfg.frameHeight),
            @"qualityPrioritization": @(cfg.qualityPrioritization), @"revision": @(cfg.revision),
            @"usePrecomputedFlow": @(cfg.usePrecomputedFlow),
            @"frameSupportedPixelFormats": cfg.frameSupportedPixelFormats,
            @"sourcePixelBufferAttributes": cfg.sourcePixelBufferAttributes,
            @"destinationPixelBufferAttributes": cfg.destinationPixelBufferAttributes,
            @"origin": @"Actual openSlot configuration, not a second probe configuration" });
'''
    anchor = '        VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];\n'
    text = once(text, anchor, observation + anchor)
    call = '        if (![proc startSessionWithConfiguration:cfg error:&e]) {\n'
    replacement = '''        const BOOL odfSessionStarted = [proc startSessionWithConfiguration:cfg error:&e];
        ODFAppleFRCObserveSetup(@{ @"stage": @"actual_session_start", @"started": @(odfSessionStarted),
            @"errorDomain": e.domain ?: @"", @"errorCode": @(e.code), @"errorDescription": e.localizedDescription ?: @"" });
        if (!odfSessionStarted) {
'''
    text = once(text, call, replacement)
    restored = text.replace(declaration, "", 1).replace(observation, "", 1).replace(replacement, call, 1)
    if restored != engine.read_text(): raise ValueError("observation patch does not reverse byte-for-byte")
    engine.write_text(text)
    shutil.copyfile(here / "native/main.mm", output / "main.mm")
    env = dict(os.environ)
    if not env.get("DEVELOPER_DIR"):
        raise ValueError("set DEVELOPER_DIR to the existing full Xcode developer directory")
    commands = []
    def run(command, logfile):
        commands.append(command)
        with (output / logfile).open("w") as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode: raise RuntimeError(f"CPU build failed; see {output / logfile}")
    run(["xcrun", "--sdk", "macosx", "metal", "-c", str(copied / VIDEO / "Shaders/FrameBudget.metal"),
         "-o", str(output / "FrameBudget.air")], "metal-compile.log")
    run(["xcrun", "--sdk", "macosx", "metallib", str(output / "FrameBudget.air"),
         "-o", str(output / "FrameBudget.metallib")], "metallib-link.log")
    common = ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-O2", "-fobjc-arc", "-fblocks",
              "-mmacosx-version-min=13.0", "-Wno-deprecated-declarations",
              "-I", str(copied / VIDEO), "-I", str(copied / BRIDGE)]
    units = [(output / "main.mm", "main"), (engine, "SPFRCEngine"),
             (copied / VIDEO / "SPFrameBudgetMetal.mm", "SPFrameBudgetMetal")]
    def compile_unit(unit):
        path, name = unit
        run(common + ["-c", str(path), "-o", str(output / f"{name}.o")], f"{name}-compile.log")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(compile_unit, units))
    frameworks = ["Foundation", "CoreVideo", "CoreMedia", "VideoToolbox", "Metal", "IOSurface"]
    link = ["xcrun", "--sdk", "macosx", "clang++", "-mmacosx-version-min=13.0"]
    link += [str(output / f"{name}.o") for _, name in units]
    for framework in frameworks: link += ["-framework", framework]
    link += ["-o", str(output / "air-apple-frc")]
    run(link, "link.log")
    for name, value in original.items():
        if sha(source / name) != value: raise ValueError(f"canonical input changed: {name}")
        if name != f"{VIDEO}/SPFRCEngine.mm" and sha(copied / name) != value:
            raise ValueError(f"copy changed: {name}")
    receipt = dict(format="odf-air-apple-frc-native-build-v1", built=True, cpuWorkers=3,
        nativeExecuted=False, sessionCreated=False, gpuExecuted=False, sourceRoot=str(source),
        canonicalSHA256=original, generatedEngineSHA256=sha(engine), reversibleSetupObservation=True,
        preparerSHA256=sha(__file__), driverSHA256=sha(here / "native/main.mm"), commands=commands,
        executableSHA256=sha(output / "air-apple-frc"), shaderSHA256=sha(output / "FrameBudget.metallib"),
        requiredPortableFiles=["air-apple-frc", "FrameBudget.metallib", "cpu-build-receipt.json"],
        scope="Canonical Apple engine and converters, with setup-only metadata; no runtime or performance validation.")
    (output / "cpu-build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return {"output": str(output), "executableSHA256": receipt["executableSHA256"],
            "shaderSHA256": receipt["shaderSHA256"], "gpuExecuted": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(prepare(arguments.source_root, arguments.output)))
