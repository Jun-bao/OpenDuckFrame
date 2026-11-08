"""Copy the prepared student runtime and add whole-K1 attribution signposts.

No build, launch, Metal device, trace, graph, kernel or weight changes. Keep the
existing positional k1-runtime CONFIG.json and controlled provided-output path.
Prepare exactly four configs: original D0 / trained best x Fast / Balanced.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one original runtime anchor: {old[:75]!r}")
    return text.replace(old, new)


def patch_bench(text):
    old = '''                let start = now()
                let result = try pushFrame(frame.isMultiple(of: 2) ? second : first)
                let end = now()'''
    new = '''                let traceID = StudentK1Trace.begin(caseID: caseID, variant: id, frame: frame, alpha: alpha)
                let start = now()
                let result: [CVPixelBuffer]
                do {
                    result = try pushFrame(frame.isMultiple(of: 2) ? second : first)
                } catch {
                    StudentK1Trace.end(traceID)
                    throw error
                }
                let end = now()
                StudentK1Trace.end(traceID)'''
    return once(text, old, new)


def patch_main(text):
    text = once(text, '    let mode = config["mode"] as! String',
                '    let mode = config["mode"] as! String\n    try StudentK1Trace.validate(config: config)')
    return once(text, '        report["result"] = try runControlled(config: config, outputDir: outputDir)',
        '''        report["trace_attribution_only"] = true
        report["trace_signpost_subsystem"] = StudentK1Trace.subsystem
        report["trace_signpost_name"] = "K1 provided-output"
        report["cost_adoption_authorized"] = false
        report["result"] = try runControlled(config: config, outputDir: outputDir)''')


def reference_arm(config_path, tier, variant_id, case_id, trained_weights):
    """Bind the fixed trace to the matching prior uninstrumented cost samples."""
    config_path = Path(config_path).resolve()
    config = json.loads(config_path.read_text())
    report_path = config_path.with_name("controlled.json")
    report = json.loads(report_path.read_text())
    if (config["mode"] != "controlled" or config["tier"] != tier
            or report["profiling_enabled"] or report["simulation_enabled"]):
        raise ValueError("reference must be the matching unprofiled controlled cost run")
    case = next(row for row in config["cases"] if row["id"] == case_id)
    variant = dict(next(row for row in config["variants"] if row["id"] == variant_id))
    if not (variant.get("direct_crop") and variant.get("gpu_input_padding")
            and not any(variant.get(key, False) for key in
                        ("fused_warp", "trim_final_features", "defer_commits", "native_leaky"))):
        raise ValueError("reference runtime flags differ from the fixed native IO contract")
    model_path = Path(variant["model"]).resolve()
    if variant_id == "trained":
        if sha(model_path) != sha(trained_weights):
            raise ValueError("trained trace weight SHA differs from the original cost arm")
        model_path = Path(trained_weights).resolve()
    variant["model"] = str(model_path)
    selected = [row for row in report["result"]["records"]
                if row["case_id"] == case_id and row["variant"] == variant_id
                and row["cadence"] == "continuous" and row["alpha"] == 0.5]
    if not selected or any(row["entrypoint"] != "into" for row in selected):
        raise ValueError("reference must contain the actual midpoint provided-output arm")
    samples = [sample["host_ms"] for row in selected for sample in row["samples"]]
    provenance = dict(config=str(config_path), config_sha256=sha(config_path),
        controlled_report=str(report_path), controlled_report_sha256=sha(report_path),
        tier=tier, variant=variant_id, case_id=case_id, alpha=0.5, entrypoint="into",
        samples=len(samples), mean_host_ms=math.fsum(samples) / len(samples),
        model_sha256=sha(model_path), input_sha256={case[key]: sha(case[key]) for key in ("first", "second")})
    return config, case, variant, provenance


def trace_config(reference, case, variant, output):
    return dict(mode="controlled", app_entrypoints=True,
        output_dir=str(Path(output).resolve()), width=reference["width"], height=reference["height"],
        tier=reference["tier"], cases=[case], variants=[variant],
        warmup_per_arm=32, frames_per_arm=100,
        schedule=[dict(block=0, case_id=case["id"], alpha=0.5, cadence="continuous",
                       period_ms=0, order=[variant["id"]])],
        trace_attribution_only=True, cost_adoption_authorized=False)


def prepare(source, output, trace_root, fast_cost, balanced_cost, trained_weights, case_id="park_joy-b0"):
    source, output, trace_root = (Path(path).resolve() for path in (source, output, trace_root))
    if output.exists() or trace_root.exists():
        raise FileExistsError("trace source and trace output root must both be new paths")
    origin_path = source / "source-origin.json"
    origin = json.loads(origin_path.read_text())
    if origin.get("graph_contracts", {}).get("odf-ifnet425-acc-b3r32-b4r16-v1") != [32, 16]:
        raise ValueError("source must be the original prepared accumulated-mask student runtime")
    original = {str(path.relative_to(source)): sha(path)
                for folder in ("Sources", "Plugins") for path in (source / folder).rglob("*") if path.is_file()}
    for name, digest in origin["generated"].items():
        if original.get(name) != digest:
            raise ValueError(f"prepared source differs from its original source manifest: {name}")
    # Resolve/bind every reference before creating either new destination.
    runs = []
    for tier, config_path in (("fast", fast_cost), ("balanced", balanced_cost)):
        for variant_id in ("d0", "trained"):
            reference, case, variant, prior = reference_arm(config_path, tier, variant_id, case_id, trained_weights)
            name = f"{variant_id}-{tier}"
            config = trace_config(reference, case, variant, trace_root / "results" / name)
            runs.append(dict(name=name, config=config, uninstrumented_reference=prior,
                config_path=str(trace_root / "configs" / f"{name}.json"),
                trace_path=str(trace_root / "traces" / f"{name}.trace")))
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
    helper = Path(__file__).resolve().parent / "native/StudentK1Trace.swift"
    shutil.copyfile(helper, output / "Sources/k1-runtime/StudentK1Trace.swift")
    generated = {str(path.relative_to(output)): sha(path)
                 for folder in ("Sources", "Plugins") for path in (output / folder).rglob("*") if path.is_file()}
    changed = sorted(name for name in original.keys() | generated.keys() if original.get(name) != generated.get(name))
    expected = sorted(f"Sources/k1-runtime/{name}" for name in
                      ("main.swift", "K1ControlledBench.swift", "StudentK1Trace.swift"))
    if changed != expected:
        raise ValueError(f"unexpected copied-runtime edits: {changed}")
    receipt = dict(source=str(source), original_source_origin_sha256=sha(origin_path),
        original_sources_sha256=original, generated_sources_sha256=generated,
        changed_sources=changed, graph_kernel_weight_sources_unchanged=True,
        source_binary_sha256=sha(source / ".build/release/k1-runtime")
            if (source / ".build/release/k1-runtime").is_file() else None,
        helper_sha256=sha(helper), preparer_sha256=sha(__file__),
        package_sha256=sha(output / "Package.swift"), license_sha256=sha(output / "LICENSE"),
        compiled=False, gpu_run=False, trace_run=False, cost_adoption_authorized=False)
    (output / "trace-source-origin.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for folder in ("configs", "results", "traces"):
        (trace_root / folder).mkdir(parents=True, exist_ok=False)
    for run in runs:
        path = Path(run["config_path"])
        path.write_text(json.dumps(run.pop("config"), indent=2) + "\n")
        run["config_sha256"] = sha(path)
    plan = dict(scope="four Metal System Trace attribution captures only; not cost adoption or product acceptance",
        native_source=str(output), native_binary=str(output / ".build/release/k1-runtime"),
        required_environment={"ODF_K1_SIGNPOST_TRACE": "1", "ODF_PERF_PROFILE": "off", "RIFE_VERBOSE": "0"},
        unset_environment=["ODF_K1_PROFILE", "RIFE_DUMP_DIR", "ODF_STUDENT_STATE_DUMP_DIR"],
        signpost_subsystem="app.openduckframe.k1-attribution", signpost_name="K1 provided-output",
        signpost_context=["case", "variant", "frame 0..99", "alpha=0.5"],
        recorded_calls_per_trace=100, warmup_calls_per_trace=32, cases=[case_id],
        call_contract="one previous Head cached, one new Head + complete K1, synchronous provided-output return; alternating A/B",
        host_timing="original DispatchTime start/end retained; signpost begin/end sit outside those timestamps",
        interpretation=dict(relative_mean_deviation_threshold=0.10,
            rule="if abs(traced mean / matched original mean - 1) > 0.10, use only time shares for attribution",
            gpu_busy="union of observed GPU work intervals clipped to recorded K1 intervals; do not sum overlapping events",
            gaps="gaps inside recorded K1 intervals and GPU envelopes; distinguish CPU encoding from waiting",
            mapping_limit="MPSGraph may fuse or rename operations; unresolved dense/factor layer mapping remains an attribution gap; do not split graphs or rerun layers"),
        residual_targets=[dict(stage=stage, layer=layer, channels=c, rank=rank,
            logical_prefix=f"block{stage}.convblock.{layer}.", dense="3x3 C->C + beta",
            factor="bias-free 3x3 C->r, 1x1 r->C + folded bias; skip/Leaky unchanged")
            for stage, c, rank in ((3, 64, 32), (4, 32, 16)) for layer in range(8)],
        nonconvolution_targets=["BGRA conversion/input padding", "resize/concat/slice", "flow and mask accumulation",
            "stage flow split/backward warp/feature packing", "full-resolution flow/mask resize, final RGB warp/blend/output"],
        runs=runs, independent_holdout_accessed=False, graph_kernel_weight_sources_unchanged=True)
    plan_path = trace_root / "trace-plan.json"
    plan_path.write_text(json.dumps(plan, indent=2) + "\n")
    return dict(native_source=str(output), plan=str(plan_path), configs=[run["config_path"] for run in runs])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--trace-root", type=Path, required=True)
    parser.add_argument("--fast-cost", type=Path, required=True, help="original Fast cost config.json")
    parser.add_argument("--balanced-cost", type=Path, required=True, help="original Balanced cost config.json")
    parser.add_argument("--trained-weights", type=Path, required=True)
    parser.add_argument("--case-id", default="park_joy-b0")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.trace_root, args.fast_cost,
                             args.balanced_cost, args.trained_weights, args.case_id), indent=2))


if __name__ == "__main__":
    main()
