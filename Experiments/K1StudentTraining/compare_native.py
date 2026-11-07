"""Compare exported accumulate graphs with their actual Metal FP16 execution.

Takes one JSON configuration. This is a development numerical/GT diagnostic,
not a performance measurement or independent quality acceptance.
"""
from __future__ import annotations

import json
import hashlib
import math
import os
from pathlib import Path
import subprocess
import sys

import numpy as np
from PIL import Image
import torch

import data as dataset
import model
from train import gpu_lock, write_json, checkpoint, psnr


LSB_METRICS = ("max_abs_lsb", "fraction_pixels_ge2_lsb", "mean_abs_lsb")
NUMERICAL_MULTIPLIER = 2.0
QUANTIZATION = dict(
    reference="RGB float32 -> clamp [0,1] -> float32 * 255 -> numpy.rint -> uint8 -> BGRA; alpha=255",
    rounding="round to nearest, ties to even (explicit reference quantization choice)",
    comparison="actual native BGRA8 versus quantized reference, B/G/R only; alpha excluded",
    fraction_pixels_ge2_lsb_denominator="H*W pixels; any RGB channel with absolute difference >=2",
    mean_abs_lsb_denominator="3*H*W RGB channel values")
HISTOGRAM_CONTRACT = dict(
    bins=256, values="integer absolute B/G/R channel differences, 0..255 LSB; alpha excluded",
    pooled_fraction="sum(pixels_ge2_lsb) / sum(pixel_count), any RGB channel >=2 LSB",
    p99_99="pooled RGB-channel histogram; nearest-rank empirical quantile at ceil(0.9999*N)")


def select_evaluation(manifest, evaluation_set="gt"):
    """Keep the old GT-only default; both uses the fixed 48 adjacent + 12 GT rows."""
    if evaluation_set not in ("gt", "both"):
        raise ValueError("evaluation_set must be 'gt' (default) or 'both'")
    rows = []
    groups = ("distillation_evaluation", "evaluation") if evaluation_set == "both" else ("evaluation",)
    for group in groups:
        rows.extend(dict(row, evaluation_group=group, has_gt=group == "evaluation")
                    for row in manifest[group])
    if len({row["id"] for row in rows}) != len(rows):
        raise ValueError("evaluation sample ids must be distinct")
    if evaluation_set == "both" and (len(manifest["distillation_evaluation"]) != 48
                                      or len(manifest["evaluation"]) != 12):
        raise ValueError("both requires the fixed 48 adjacent queries and 12 GT queries")
    return rows


def native_case_id(row):
    # case_id labels the old window and is deliberately NOT an endpoint identity.
    return f"{row['clip']}-f{row['first_index']:04d}-f{row['second_index']:04d}"


def endpoint_cases(rows):
    cases = {}
    for row in rows:
        name = native_case_id(row)
        if name in cases:
            prior = cases[name]
            if any(prior[key] != row[key] for key in ("first", "second", "width", "height")):
                raise ValueError(f"endpoint identity has inconsistent source frames: {name}")
        else:
            cases[name] = row
    return cases


def reference_bgra8(reference):
    rgb = np.asarray(reference, dtype=np.float32)
    rgb8 = np.rint(np.clip(rgb, 0, 1) * np.float32(255)).astype(np.uint8)
    pixels = np.empty((*rgb8.shape[:2], 4), dtype=np.uint8)
    pixels[:, :, :3] = rgb8[:, :, ::-1]
    pixels[:, :, 3] = 255
    return pixels


def lsb_metrics(native_pixels, reference):
    expected = reference_bgra8(reference)
    difference = np.abs(native_pixels[:, :, :3].astype(np.int16) - expected[:, :, :3].astype(np.int16))
    histogram = np.bincount(difference.reshape(-1), minlength=256)
    pixel_count = difference.shape[0] * difference.shape[1]
    tail_count = int(np.count_nonzero(np.any(difference >= 2, axis=2)))
    return dict(max_abs_lsb=int(difference.max()),
                fraction_pixels_ge2_lsb=float(np.mean(np.any(difference >= 2, axis=2))),
                mean_abs_lsb=float(difference.mean()), lsb_histogram=histogram.tolist(),
                pixel_count=pixel_count, pixels_ge2_lsb=tail_count,
                rgb_channel_count=int(difference.size),
                abs_delta_p99_99_lsb=histogram_quantile(histogram))


def histogram_quantile(histogram):
    counts = np.asarray(histogram, dtype=np.int64)
    total = int(counts.sum())
    if total <= 0:
        raise ValueError("an LSB histogram must contain RGB channel observations")
    rank = (9999 * total + 9999) // 10000
    return int(np.searchsorted(np.cumsum(counts), rank, side="left"))


def aggregate_lsb(rows):
    histogram = np.sum([row["lsb_histogram"] for row in rows], axis=0, dtype=np.int64)
    channels = sum(row["rgb_channel_count"] for row in rows)
    pixels = sum(row["pixel_count"] for row in rows)
    tail = sum(row["pixels_ge2_lsb"] for row in rows)
    if histogram.shape != (256,) or int(histogram.sum()) != channels or channels != 3 * pixels:
        raise ValueError("LSB histogram counts differ from their pixel/channel denominators")
    return dict(samples=len(rows), lsb_histogram=histogram.tolist(), rgb_channel_count=channels,
        pixel_count=pixels, pixels_ge2_lsb=tail, fraction_pixels_ge2_lsb=tail / pixels,
        mean_abs_lsb=float(np.dot(histogram, np.arange(256, dtype=np.int64))) / channels,
        max_abs_lsb=int(np.flatnonzero(histogram)[-1]), abs_delta_p99_99_lsb=histogram_quantile(histogram))


def gt_metrics(row, actual, reference):
    if not row["has_gt"]:
        return {}
    gt = np.asarray(Image.open(row["gt"]).convert("RGB"), dtype=np.float32) / 255
    return dict(gt_sha256=row["gt_sha256"],
        native_gt_psnr_db=psnr(float(np.mean((actual.astype(np.float64) - gt) ** 2))),
        torch_gt_psnr_db=psnr(float(np.mean((reference.astype(np.float64) - gt) ** 2))))


def d0_lookup(report):
    lookup = {}
    for row in report["rows"]:
        if row["variant"] == "d0":
            if row["id"] in lookup:
                raise ValueError(f"duplicate D0 sample in numerical baseline: {row['id']}")
            lookup[row["id"]] = row
    return lookup


def same_sample(first, second):
    return all(first[key] == second[key]
               for key in ("id", "clip", "first_index", "second_index", "alpha"))


def annotate_numerical(rows, baseline):
    """Record implementation flags only. Exceeding them does not fail a quality gate."""
    for row in rows:
        if row["variant"] == "d0":
            continue
        teacher = baseline[row["id"]]
        if not same_sample(row, teacher):
            raise ValueError(f"numerical baseline endpoints/alpha differ for {row['id']}")
        limits = {key: teacher[key] * NUMERICAL_MULTIPLIER for key in LSB_METRICS}
        exceeded = [key for key in LSB_METRICS if row[key] > limits[key]]
        row.update(numerical_baseline_d0={key: teacher[key] for key in LSB_METRICS},
                   numerical_baseline_d0_output_sha256=teacher["output_sha256"],
                   numerical_limits_2x_d0=limits, numerical_exceeded_metrics=exceeded,
                   numerical_within_2x_d0=not exceeded)


def numerical_v2(rows, variants, d0_baseline, fullrank_report, phase):
    """Separate v2 diagnostics. Historical v1 fields/results remain untouched."""
    if phase not in ("posthoc_diagnostic", "post_training_diagnostic"):
        raise ValueError("numerical_v2_phase must be posthoc_diagnostic or post_training_diagnostic")
    result = dict(version=2, phase=phase, report_only=True, quality_gate_applied=False,
        prior_v1_reclassified=False, max_abs_lsb_gate_applied=False,
        multiplier=NUMERICAL_MULTIPLIER, status="not_configured", by_variant={})
    if fullrank_report is None:
        return result
    if d0_baseline is None:
        result["status"] = "unavailable_missing_D0_baseline"
        return result
    fullrank_rows = [row for row in fullrank_report["rows"] if row["variant"] == "fullrank"]
    if len(fullrank_rows) != 60 or any("lsb_histogram" not in row for row in fullrank_rows):
        result["status"] = "unavailable_fullrank_requires_60_histograms"
        return result
    lookup = {row["id"]: row for row in fullrank_rows}
    control = aggregate_lsb(fullrank_rows)
    result.update(status="diagnostic_only", fullrank_aggregate=control)
    for name in variants:
        if name in ("d0", "fullrank"):
            continue
        selected = [row for row in rows if row["variant"] == name]
        if len(selected) != 60 or {row["id"] for row in selected} != set(lookup):
            raise ValueError("v2 comparison requires the same fixed 60 sample ids as fullrank")
        for row in selected:
            if not same_sample(row, lookup[row["id"]]) or not same_sample(row, d0_baseline[row["id"]]):
                raise ValueError(f"v2 baseline endpoint mismatch for {row['id']}")
            limit = d0_baseline[row["id"]]["mean_abs_lsb"] * NUMERICAL_MULTIPLIER
            row.update(numerical_v2_phase=phase, numerical_v2_mean_lsb_limit_2x_d0=limit,
                numerical_v2_mean_within_2x_d0=row["mean_abs_lsb"] <= limit)
        pooled = aggregate_lsb(selected)
        limits = {key: control[key] * NUMERICAL_MULTIPLIER
                  for key in ("fraction_pixels_ge2_lsb", "abs_delta_p99_99_lsb")}
        flagged = [key for key, limit in limits.items() if pooled[key] > limit]
        mean_flags = [row["id"] for row in selected if not row["numerical_v2_mean_within_2x_d0"]]
        if mean_flags:
            flagged.append("per_sample_mean_abs_lsb")
        result["by_variant"][name] = dict(aggregate=pooled, fullrank_limits_2x=limits,
            mean_lsb_flagged_sample_ids=mean_flags, flagged_metrics=flagged,
            within_diagnostic_limits=not flagged,
            disposition="posthoc only; does not reclassify prior v1 flags" if phase == "posthoc_diagnostic"
                        else "post-training implementation diagnostic; no quality acceptance")
    return result


def frozen_d0_checks(rows, baseline):
    lookup = {(row["case_id"], row["alpha"]): row["output_sha256"]
              for row in baseline["rows"] if row["variant"] == "d0"}
    checks = []
    for row in rows:
        # The historical io-fast-parity outputs have the 80 ms GT endpoints.
        if (row["variant"] != "d0" or not row["has_gt"]
                or not math.isclose(row["delta_seconds"], 0.08, abs_tol=1e-9)):
            continue
        key = row["case_id"], row["alpha"]
        if key in lookup:
            checks.append(dict(id=row["id"], case_id=row["case_id"],
                native_case_id=row["native_case_id"], delta_seconds=row["delta_seconds"],
                matches=row["output_sha256"] == lookup[key]))
    return checks


def summarize(rows, variants, numerical_baseline=None):
    teachers = dict(numerical_baseline or {})
    teachers.update({row["id"]: row for row in rows if row["variant"] == "d0"})
    summaries = {}
    for name in variants:
        selected = [row for row in rows if row["variant"] == name]
        gt_rows = [row for row in selected if row["has_gt"]]
        summary = dict(samples=len(selected), gt_samples=len(gt_rows),
            min_reference_psnr_db=min(row["reference_psnr_db"] for row in selected),
            mean_reference_mae=sum(row["reference_mae"] for row in selected) / len(selected),
            max_reference_mae=max(row["reference_mae"] for row in selected),
            max_abs_lsb=max(row["max_abs_lsb"] for row in selected),
            mean_abs_lsb=sum(row["mean_abs_lsb"] for row in selected) / len(selected),
            max_fraction_pixels_ge2_lsb=max(row["fraction_pixels_ge2_lsb"] for row in selected))
        if gt_rows:
            summary["mean_native_gt_psnr_db"] = sum(row["native_gt_psnr_db"] for row in gt_rows) / len(gt_rows)
        if name != "d0":
            for row in gt_rows:
                teacher = teachers.get(row["id"])
                if teacher is not None:
                    if not same_sample(row, teacher):
                        raise ValueError(f"GT D0 comparison has different endpoints for {row['id']}")
                    row["native_gt_delta_to_d0_db"] = row["native_gt_psnr_db"] - teacher["native_gt_psnr_db"]
                    row["torch_gt_delta_to_d0_db"] = row["torch_gt_psnr_db"] - teacher["torch_gt_psnr_db"]
            deltas = [row["native_gt_delta_to_d0_db"] for row in gt_rows if "native_gt_delta_to_d0_db" in row]
            if deltas:
                summary.update(native_gt_d0_compared=len(deltas),
                    mean_native_gt_delta_to_d0_db=sum(deltas) / len(deltas),
                    worst_native_gt_delta_to_d0_db=min(deltas))
            checked = [row for row in selected if "numerical_within_2x_d0" in row]
            if checked:
                summary.update(numerical_checked=len(checked),
                    numerical_flagged=sum(not row["numerical_within_2x_d0"] for row in checked),
                    numerical_flagged_by_metric={key: sum(key in row["numerical_exceeded_metrics"] for row in checked)
                                                for key in LSB_METRICS})
        summaries[name] = summary
        if all("lsb_histogram" in row for row in selected):
            summary["lsb_aggregate"] = aggregate_lsb(selected)
    return summaries


def bgra(source, destination):
    rgb = np.asarray(Image.open(source).convert("RGB"))
    pixels = np.empty((*rgb.shape[:2], 4), dtype=np.uint8)
    pixels[:, :, :3] = rgb[:, :, ::-1]
    pixels[:, :, 3] = 255
    destination.write_bytes(pixels.tobytes())


def reuse_native(config, evaluation):
    """Reuse one frozen compare run's outputs, bound to its recorded provenance."""
    report_path = Path(config["reuse_native_report"]).resolve()
    prior = report_path.parent.parent
    analysis_path, native_config_path = prior / "analysis.json", prior / "native-config.json"
    analysis = json.loads(analysis_path.read_text())
    native_config = json.loads(native_config_path.read_text())
    report = json.loads(report_path.read_text())
    width, height = evaluation[0]["width"], evaluation[0]["height"]
    if (analysis["native_report_sha256"] != model.sha(report_path)
            or analysis["native_bin_sha256"] != model.sha(config["native_bin"])
            or analysis["data_manifest_sha256"] != model.sha(config["data_manifest"])
            or analysis["tier"] != config["tier"]
            or (native_config["width"], native_config["height"], native_config["tier"]) != (width, height, config["tier"])
            or native_config["mode"] != "quality" or not native_config["app_entrypoints"]):
        raise ValueError("reused native report provenance, tier, or dimensions differ")
    variants = {row["id"]: row for row in native_config["variants"]}
    source_cases = {row["id"]: row for row in native_config["cases"]}
    numerical_rows = {(row["id"], row["variant"]): row for row in analysis["rows"]}
    native_rows = {(row["case_id"], row["variant"], row["alpha"]): row for row in report["rows"]}
    for name, value in config["models"].items():
        if analysis["model_sha256"][name] != model.sha(value["weights"]):
            raise ValueError(f"reused native model SHA differs for {name}")
        if value.get("checkpoint") and analysis["checkpoint_sha256"][name] != model.sha(value["checkpoint"]):
            raise ValueError(f"reused reference checkpoint SHA differs for {name}")
        variant = variants[name]
        if not (variant.get("direct_crop") and variant.get("gpu_input_padding")
                and not variant.get("fused_warp", False) and not variant.get("trim_final_features", False)
                and not variant.get("defer_commits", False)):
            raise ValueError("reused native IO flags differ from this diagnostic contract")
        for row in evaluation:
            old = numerical_rows[row["id"], name]
            actual = native_rows[native_case_id(row), name, row["alpha"]]
            if (not same_sample(row, old)
                    or row["first_sha256"] != old["first_sha256"]
                    or row["second_sha256"] != old["second_sha256"]
                    or old["output_sha256"] != actual["output_sha256"]):
                raise ValueError(f"reused native sample identity or hashes differ for {row['id']}")
    cases = endpoint_cases(evaluation)
    inputs = {source_cases[name][key]: model.sha(source_cases[name][key])
              for name in cases for key in ("first", "second")}
    provenance = dict(native_report=str(report_path), native_report_sha256=model.sha(report_path),
        prior_analysis=str(analysis_path), prior_analysis_sha256=model.sha(analysis_path),
        native_config=str(native_config_path), native_config_sha256=model.sha(native_config_path),
        original_png_hashes="matched per sample against the original analysis and current frozen manifest",
        current_bgra_input_sha256=inputs, native_execution_performed=False, native_outputs_copied=False,
        reference_recomputed=True, note="only downstream reference/numerical analysis is recomputed")
    return report, report_path, provenance


def run(config):
    torch.set_num_threads(4)
    manifest = json.loads(Path(config["data_manifest"]).read_text())
    evaluation_set = config.get("evaluation_set", "gt")
    evaluation = select_evaluation(manifest, evaluation_set)
    numerical_baseline = None
    numerical_baseline_provenance = None
    if config.get("numerical_baseline"):
        baseline_path = Path(config["numerical_baseline"])
        baseline_report = json.loads(baseline_path.read_text())
        if (baseline_report["tier"] != config["tier"]
                or baseline_report["data_manifest_sha256"] != model.sha(config["data_manifest"])
                or baseline_report["quantization"] != QUANTIZATION):
            raise ValueError("numerical D0 baseline must use the same tier, manifest, and quantization")
        numerical_baseline = d0_lookup(baseline_report)
        for row in evaluation:
            base = numerical_baseline[row["id"]]
            if not same_sample(row, base) or any(key not in base for key in LSB_METRICS):
                raise ValueError(f"missing or incompatible numerical D0 baseline for {row['id']}")
        numerical_baseline_provenance = dict(path=str(baseline_path), sha256=model.sha(baseline_path),
            multiplier=NUMERICAL_MULTIPLIER, application="per sample, each of the three LSB metrics independently",
            disposition="report flags only; implementation diagnostic, not a quality gate")
    fullrank_report, fullrank_provenance = None, None
    if config.get("fullrank_baseline"):
        fullrank_path = Path(config["fullrank_baseline"])
        fullrank_report = json.loads(fullrank_path.read_text())
        if (fullrank_report["tier"] != config["tier"]
                or fullrank_report["data_manifest_sha256"] != model.sha(config["data_manifest"])
                or fullrank_report["quantization"] != QUANTIZATION):
            raise ValueError("fullrank baseline must use the same tier, manifest, and quantization")
        fullrank_provenance = dict(path=str(fullrank_path), sha256=model.sha(fullrank_path))
    output = Path(config["output_dir"])
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / "config.json", config)
    cases = endpoint_cases(evaluation)
    reuse_provenance = None
    native_report, native_report_path = None, output / "native/quality.json"
    native_cases = []
    if config.get("reuse_native_report"):
        native_report, native_report_path, reuse_provenance = reuse_native(config, evaluation)
        write_json(output / "reuse-native.json", reuse_provenance)
    else:
        inputs = output / "inputs"
        inputs.mkdir()
        for name, row in cases.items():
            item = dict(id=name)
            for key in ("first", "second"):
                destination = inputs / f"{name}-{key}.bgra"
                bgra(row[key], destination)
                item[key] = str(destination)
            native_cases.append(item)
    variants = [dict(id=name, model=value["weights"], direct_crop=True, gpu_input_padding=True,
                     fused_warp=False, trim_final_features=False, defer_commits=False)
                for name, value in config["models"].items()]
    width, height = next(iter(cases.values()))["width"], next(iter(cases.values()))["height"]
    native_config = dict(mode="quality", width=width, height=height, tier=config["tier"],
        cases=native_cases, variants=variants, target_sets=[[0.5], [0.25], [0.75]],
        app_entrypoints=True, save_outputs=True, output_dir=str(output / "native"))
    if native_report is None:
        write_json(output / "native-config.json", native_config)
    env = dict(os.environ, ODF_PERF_PROFILE="off", RIFE_VERBOSE="0")
    for key in ("RIFE_DUMP_DIR", "ODF_K1_PROFILE"):
        env.pop(key, None)
    with gpu_lock(config["gpu_lock"]):
        if native_report is None:
            with (output / "native.log").open("w") as log:
                result = subprocess.run([config["native_bin"], str(output / "native-config.json")],
                                        env=env, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"native diagnostic failed with exit {result.returncode}")
            native_report = json.loads(native_report_path.read_text())
        native_rows = {(row["case_id"], row["variant"], row["alpha"]): row for row in native_report["rows"]}
        rows = []
        for name, value in config["models"].items():
            if value.get("checkpoint"):
                saved = checkpoint(value["checkpoint"])
                # Compare native FP16 with the EXACT exported FP16 factors,
                # not the optimizer's higher-precision shadow checkpoint.
                quantized = {key: tensor.half().float() for key, tensor in saved["state_dict"].items()}
                net = model.student(quantized, config["lab_root"], device=config["device"])
            else:
                net = model.teacher(config["source"], config["lab_root"], device=config["device"])
            with torch.no_grad():
                for row in evaluation:
                    a, b = (dataset.load_rgb(row[key]).to(config["device"]) for key in ("first", "second"))
                    reference = net(a, b, tier=config["tier"], timestep=row["alpha"])
                    reference = reference[0].permute(1, 2, 0).cpu().numpy()
                    native_row = native_rows[native_case_id(row), name, row["alpha"]]
                    native_pixels = np.fromfile(native_row["output_bgra"], dtype=np.uint8).reshape(height, width, 4)
                    actual_hash = hashlib.sha256(native_pixels.tobytes()).hexdigest()
                    if actual_hash != native_row["output_sha256"]:
                        raise ValueError(f"native output file hash differs from report: {row['id']}")
                    actual = native_pixels[:, :, [2, 1, 0]].astype(np.float32) / 255
                    difference = actual.astype(np.float64) - reference
                    item = dict(id=row["id"], case_id=row["case_id"], native_case_id=native_case_id(row),
                        clip=row["clip"], first_index=row["first_index"], second_index=row["second_index"],
                        first_sha256=row["first_sha256"], second_sha256=row["second_sha256"],
                        delta_seconds=row["delta_seconds"], evaluation_group=row["evaluation_group"], has_gt=row["has_gt"],
                        variant=name, alpha=row["alpha"],
                        reference_psnr_db=psnr(float(np.mean(difference ** 2))),
                        reference_mae=float(np.mean(np.abs(difference))),
                        reference_max_abs=float(np.max(np.abs(difference))),
                        output_sha256=actual_hash, output_bgra=native_row["output_bgra"],
                        entrypoint=native_row["entrypoint"], **lsb_metrics(native_pixels, reference))
                    item.update(gt_metrics(row, actual, reference))
                    rows.append(item)
            del net
            if config["device"] == "mps":
                torch.mps.synchronize()
                torch.mps.empty_cache()
            print(json.dumps({"compared_variant": name, "outputs": len(evaluation)}), flush=True)
    baseline_checks = []
    if config.get("frozen_baseline"):
        baseline = json.loads(Path(config["frozen_baseline"]).read_text())
        baseline_checks = frozen_d0_checks(rows, baseline)
    if numerical_baseline is not None:
        annotate_numerical(rows, numerical_baseline)
    summaries = summarize(rows, config["models"], numerical_baseline)
    v2 = numerical_v2(rows, config["models"], numerical_baseline, fullrank_report,
                      config.get("numerical_v2_phase", "posthoc_diagnostic"))
    report = dict(scope="old development diagnostic only; FP32 reference versus actual FP16/BGRA8; no independent quality/FPS acceptance",
        mask_update="accumulate", tier=config["tier"], rows=rows, summary=summaries,
        evaluation_set=evaluation_set, sample_ids=[row["id"] for row in evaluation],
        evaluation_counts=dict(samples=len(evaluation), native_endpoint_cases=len(cases),
            distillation_samples=sum(not row["has_gt"] for row in evaluation),
            gt_samples=sum(row["has_gt"] for row in evaluation)),
        quantization=QUANTIZATION, numerical_baseline=numerical_baseline_provenance,
        histogram_contract=HISTOGRAM_CONTRACT, fullrank_baseline=fullrank_provenance, numerical_v2=v2,
        quality_gate_applied=False,
        reference_precision={name: ("exported FP16-rounded checkpoint weights, FP32 computation" if value.get("checkpoint")
                                   else "original RMW FP16 weights decoded to FP32, FP32 computation")
                             for name, value in config["models"].items()},
        frozen_D0_checks=baseline_checks,
        frozen_D0_mismatches=sum(not check["matches"] for check in baseline_checks),
        native_bin_sha256=model.sha(config["native_bin"]),
        data_manifest_sha256=model.sha(config["data_manifest"]),
        model_sha256={name: model.sha(value["weights"]) for name, value in config["models"].items()},
        checkpoint_sha256={name: model.sha(value["checkpoint"]) for name, value in config["models"].items()
                           if value.get("checkpoint")},
        compare_source_sha256=model.sha(__file__), native_report_sha256=model.sha(native_report_path),
        reused_native=reuse_provenance,
        holdout_accessed=False)
    write_json(output / "analysis.json", report)
    print(json.dumps(dict(summary=summaries, frozen_D0_checked=len(baseline_checks),
                          frozen_D0_mismatches=report["frozen_D0_mismatches"])), flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: compare_native.py CONFIG.json")
    run(json.loads(Path(sys.argv[1]).read_text()))
