"""Prepare a new two-arm controlled runtime for external launch + attach.

CPU-only preparation. Does not build, launch, attach or open a gate. The target
owns the existing project GPU flock while warming, waiting and recording.
Original launch-trace source/preparer and all prior outputs remain unchanged.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil

import prepare_trace as prior


def patch_bench(text):
    text = prior.patch_bench(text).replace("StudentK1Trace", "StudentAttachTrace")
    text = prior.once(text, '    let count = config["frames_per_arm"] as! Int, warmup = config["warmup_per_arm"] as! Int',
        '    let count = config["frames_per_arm"] as! Int')
    text = prior.once(text, '        cold.append(["variant": id, "load_or_reuse_and_make_stream_ms": elapsed(start)])',
        '''        cold.append(["variant": id, "load_or_reuse_and_make_stream_ms": elapsed(start)])
        try StudentAttachTrace.mark("STREAM_READY", extra: ["variant": id])''')
    text = prior.once(text, "    var records: [[String: Any]] = []", '''    try StudentAttachTrace.warm(config: config, inputs: inputs, streams: streams, count: 32, reset: true)
    try StudentAttachTrace.readyAndWait()
    try StudentAttachTrace.warm(config: config, inputs: inputs, streams: streams, count: 8, reset: false)
    try StudentAttachTrace.recordingBegin()
    var records: [[String: Any]] = []''')
    old = '''            stream.reset()
            _ = try stream.push(first, timesteps: [])
            for i in 0..<warmup {
                _ = try pushFrame(i.isMultiple(of: 2) ? second : first)
            }
            // An even warmup returns the source cache to A. Every measured push
            // now adds exactly one new Head; there is no per-frame rebase.
            guard warmup.isMultiple(of: 2) else { throw BenchError.configuration("warmup must be even") }'''
    text = prior.once(text, old, '''            // Both streams are already warm and cached at A after the even 32+8 calls.
            // Preserve their caches across the CPU gate; no per-arm reset/rebase here.''')
    text = prior.once(text, '            let nominalBase = now()',
        '            try StudentAttachTrace.mark("ARM_RECORD_BEGIN", extra: ["variant": id])\n            let nominalBase = now()')
    text = prior.once(text, '            let row: [String: Any] = ["block": block,',
        '            try StudentAttachTrace.mark("ARM_RECORD_END", extra: ["variant": id, "calls": count])\n            let row: [String: Any] = ["block": block,')
    return prior.once(text, "    K1BenchmarkSubmission.deferIntermediateCommits = false\n    return",
        "    try StudentAttachTrace.recordingEnd()\n    K1BenchmarkSubmission.deferIntermediateCommits = false\n    return")


def patch_main(text):
    text = prior.once(text, "do {\n    guard CommandLine.arguments.count == 2",
        "do {\n    try StudentAttachTrace.start()\n    guard CommandLine.arguments.count == 2")
    text = prior.once(text, '    let mode = config["mode"] as! String',
        '    let mode = config["mode"] as! String\n    try StudentAttachTrace.configure(config)')
    text = prior.once(text, "    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)",
        '''    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    try StudentAttachTrace.mark("OUTPUT_DIRECTORY_CREATED")
    try StudentAttachTrace.mark("METAL_DEVICE_BEGIN")''')
    text = prior.once(text, '        report["result"] = try runControlled(config: config, outputDir: outputDir)',
        '''        try StudentAttachTrace.mark("METAL_DEVICE_READY")
        report["trace_attribution_only"] = true
        report["trace_signpost_subsystem"] = StudentAttachTrace.subsystem
        report["trace_signpost_name"] = "K1 provided-output"
        report["cost_adoption_authorized"] = false
        report["result"] = try runControlled(config: config, outputDir: outputDir)''')
    text = prior.once(text, '    print(file.path)', '    try StudentAttachTrace.finished(report: file)\n    print(file.path)')
    return prior.once(text, '} catch {\n    FileHandle.standardError.write',
        '} catch {\n    StudentAttachTrace.failed(error)\n    FileHandle.standardError.write')


def attach_config(reference, case, variants, root, name, gpu_lock):
    root = Path(root).resolve()
    control = root / "control" / name
    return dict(mode="controlled", app_entrypoints=True,
        output_dir=str(root / "results" / name), width=reference["width"], height=reference["height"],
        tier=reference["tier"], cases=[case], variants=variants,
        warmup_per_arm=32, rewarm_per_arm=8, frames_per_arm=100,
        schedule=[dict(block=0, case_id=case["id"], alpha=0.5, cadence="continuous", period_ms=0,
                       order=["d0", "trained"])],
        gpu_lock=str(Path(gpu_lock).resolve()), attach_gate=str(control / "GO"),
        attach_progress=str(control / "progress.jsonl"), attach_run_name=name,
        attach_phase="preflight" if name.startswith("preflight-") else "trace",
        trace_attribution_only=True, cost_adoption_authorized=False)


def prepare(source, output, plan_root, fast_cost, balanced_cost, trained_weights, gpu_lock, case_id="park_joy-b0"):
    source, output, plan_root = (Path(path).resolve() for path in (source, output, plan_root))
    if output.exists() or plan_root.exists():
        raise FileExistsError("attach source and plan roots must both be new paths")
    origin_path = source / "source-origin.json"
    origin = json.loads(origin_path.read_text())
    if origin.get("graph_contracts", {}).get("odf-ifnet425-acc-b3r32-b4r16-v1") != [32, 16]:
        raise ValueError("source must be the original prepared student runtime, not either earlier probe")
    original = {str(path.relative_to(source)): prior.sha(path)
                for folder in ("Sources", "Plugins") for path in (source / folder).rglob("*") if path.is_file()}
    if any(original.get(name) != digest for name, digest in origin["generated"].items()):
        raise ValueError("original prepared source no longer matches its source manifest")
    runs = []
    for tier, path in (("fast", fast_cost), ("balanced", balanced_cost)):
        arms = [prior.reference_arm(path, tier, variant, case_id, trained_weights) for variant in ("d0", "trained")]
        reference, case = arms[0][0], arms[0][1]
        for phase in ("preflight", "trace"):
            name = f"{phase}-{tier}"
            config = attach_config(reference, case, [arm[2] for arm in arms], plan_root, name, gpu_lock)
            capture = plan_root / "captures" / name
            runs.append(dict(name=name, phase=phase, tier=tier, config=config,
                config_path=str(plan_root / "configs" / f"{name}.json"),
                progress_path=config["attach_progress"], gate_path=config["attach_gate"],
                output_dir=config["output_dir"], stdout_path=str(capture / "stdout.log"),
                stderr_path=str(capture / "stderr.log"), trace_path=str(capture / "capture.trace"),
                required_environment={"ODF_K1_ATTACH_PROGRESS": config["attach_progress"],
                    "ODF_K1_SIGNPOST_TRACE": "1", "ODF_PERF_PROFILE": "off", "RIFE_VERBOSE": "0"},
                old_cost_references={arm[2]["id"]: arm[3] for arm in arms}))
    output.mkdir(parents=True, exist_ok=False)
    for folder in ("Sources", "Plugins"):
        shutil.copytree(source / folder, output / folder)
    for name in ("Package.swift", "LICENSE"):
        shutil.copyfile(source / name, output / name)
    main, bench = (output / "Sources/k1-runtime" / name for name in ("main.swift", "K1ControlledBench.swift"))
    for path in (main, bench):
        path.chmod(path.stat().st_mode | 0o200)
    main.write_text(patch_main(main.read_text()))
    bench.write_text(patch_bench(bench.read_text()))
    helper = Path(__file__).resolve().parent / "native/StudentAttachTrace.swift"
    shutil.copyfile(helper, output / "Sources/k1-runtime/StudentAttachTrace.swift")
    generated = {str(path.relative_to(output)): prior.sha(path)
                 for folder in ("Sources", "Plugins") for path in (output / folder).rglob("*") if path.is_file()}
    changed = sorted(name for name in original.keys() | generated.keys() if original.get(name) != generated.get(name))
    expected = sorted(f"Sources/k1-runtime/{name}" for name in
                      ("main.swift", "K1ControlledBench.swift", "StudentAttachTrace.swift"))
    if changed != expected:
        raise ValueError(f"unexpected copied-runtime edits: {changed}")
    receipt = dict(source=str(source), source_origin_sha256=prior.sha(origin_path),
        original_sources_sha256=original, generated_sources_sha256=generated, changed_sources=changed,
        graph_kernel_weights_unchanged=True, preparer_sha256=prior.sha(__file__), helper_sha256=prior.sha(helper),
        prior_preparer_sha256=prior.sha(Path(prior.__file__)), compiled=False, gpu_run=False, trace_run=False)
    (output / "attach-source-origin.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for run in runs:
        for path in (Path(run["config_path"]).parent, Path(run["progress_path"]).parent,
                     Path(run["stdout_path"]).parent, Path(run["output_dir"]).parent):
            path.mkdir(parents=True, exist_ok=True)
        path = Path(run["config_path"])
        path.write_text(json.dumps(run.pop("config"), indent=2) + "\n")
        run["config_sha256"] = prior.sha(path)
    plan = dict(scope="same-binary untraced preflights, then two external-start/attach attribution captures only",
        native_source=str(output), native_binary=str(output / ".build/release/k1-runtime"), runs=runs,
        gpu_lock_owner="target process; launcher must not pre-acquire this flock",
        phases="each arm warm32 -> fsynced READY -> CPU gate -> each arm rewarm8 without signposts -> two POI events bracketing 200 K1 intervals -> controlled.json fsync -> fsynced DONE",
        gate_poll_seconds=0.02, signpost_subsystem="app.openduckframe.k1-attribution",
        signpost_name="K1 provided-output", poi_events=["K1 recording begin", "K1 recording end"],
        unset_environment=["ODF_K1_PROFILE", "RIFE_DUMP_DIR", "ODF_STUDENT_STATE_DUMP_DIR"],
        controller_protocol=dict(preflight="normal Popen, separate stdout/stderr, wait READY then delay/open gate; no xctrace",
            attach="normal Popen; wait READY; attach; wait recording-start hint +2 seconds; create this run's GO file",
            done="after DONE wait 1 second, SIGINT xctrace and wait for clean trace save; target exits itself",
            timeout="if no DONE within 30 seconds after gate, SIGINT xctrace and record invalid attempt"),
        trace_budget=dict(original=4, consumed_invalid_launch=1, planned_attach=2, maximum_remaining=3,
            spare="only for a confirmed and repaired harness/control flow error",
            stop="attach rejection, cumulative second invalid trace, or two valid traces; no permission/system changes"),
        validity="controlled.json complete; 200 labeled K1 intervals; target GPU rows aligned to them; RunIssues retained",
        timing="compare each traced arm against matching same-binary untraced preflight; >10% deviation means shares only; also retain comparison with old 96-call means",
        first_launch_failure="output directory absent before first Metal initialization; stderr not separately captured; exact stop point/cause remains undetermined",
        independent_holdout_accessed=False, graph_kernel_weights_unchanged=True, cost_adoption_authorized=False)
    path = plan_root / "attach-plan.json"
    path.write_text(json.dumps(plan, indent=2) + "\n")
    return dict(native_source=str(output), plan=str(path), configs=[run["config_path"] for run in runs])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--plan-root", type=Path, required=True)
    parser.add_argument("--fast-cost", type=Path, required=True)
    parser.add_argument("--balanced-cost", type=Path, required=True)
    parser.add_argument("--trained-weights", type=Path, required=True)
    parser.add_argument("--gpu-lock", type=Path, required=True)
    parser.add_argument("--case-id", default="park_joy-b0")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.plan_root, args.fast_cost,
        args.balanced_cost, args.trained_weights, args.gpu_lock, args.case_id), indent=2))


if __name__ == "__main__":
    main()
