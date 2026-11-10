"""Freeze the existing five-clip development data without copying source images.

Only three old calibration clips supply training pairs. The two remaining old
development clips supply the fixed GT diagnostics; they are not acceptance data.
This module never discovers or opens an independent holdout directory.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re

from PIL import Image


TRAIN_CLIPS = ("park_joy", "crowd_run", "ducks_take_off")
EVALUATION_CLIPS = ("in_to_tree", "old_town_cross")
ALPHAS = (0.25, 0.5, 0.75)
BLOCKS = (0, 2)
FRAME_NAME = re.compile(r"frame(\d+)\.png\Z")


def sha256(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _pair(first: dict, second: dict) -> dict:
    return {
        "id": f"{first['clip']}-f{first['index']:04d}-f{second['index']:04d}",
        "clip": first["clip"], "overlap_group": first["clip"],
        "first": first["path"], "second": second["path"],
        "first_index": first["index"], "second_index": second["index"],
        "first_sha256": first["sha256"], "second_sha256": second["sha256"],
        "first_timestamp_seconds": first["timestamp_seconds"],
        "second_timestamp_seconds": second["timestamp_seconds"],
        "delta_seconds": (second["index"] - first["index"]) / 50,
        "source_fps": 50, "baseline_fps": 50 / (second["index"] - first["index"]),
        "width": first["width"], "height": first["height"],
    }


def _add_distillation_evaluation(manifest: dict) -> None:
    """Use the same four diagnostic windows for adjacent-pair teacher selection.

    The 48 queries have no ground-truth fields. The old 12 GT queries are kept
    exclusively for initial/best/last reporting, separate from model selection.
    """
    if (manifest["train_clips"] != list(TRAIN_CLIPS)
            or manifest["evaluation_clips"] != list(EVALUATION_CLIPS)
            or manifest["source_fps"] != 50):
        raise ValueError("Only the fixed five-clip 50 Hz development split can be derived")
    frames = {(row["clip"], frame["index"]): frame for row in manifest["inventory"]
              if row["clip"] in EVALUATION_CLIPS for frame in row["frames"]}
    cases = {row["case_id"]: row for row in manifest["evaluation"]}
    expected = {f"{clip}-b{block}" for clip in EVALUATION_CLIPS for block in BLOCKS}
    if set(cases) != expected:
        raise ValueError("The four existing b0/b2 diagnostic windows are required")
    queries = []
    for clip in EVALUATION_CLIPS:
        for block in BLOCKS:
            case = cases[f"{clip}-b{block}"]
            first_index = case["first_index"]
            if case["second_index"] - first_index != 4 or case["delta_seconds"] != 0.08:
                raise ValueError("GT reporting must retain its original 80 ms endpoints")
            window = [frames[clip, index] for index in range(first_index, first_index + 5)]
            for first, second in zip(window, window[1:]):
                pair = _pair(first, second)
                for alpha in ALPHAS:
                    queries.append({**pair, "id": f"{pair['id']}-a{alpha:g}",
                                    "case_id": case["case_id"], "block": block, "alpha": alpha})
    builder_path = Path(__file__).absolute()
    builder = {"path": str(builder_path), "sha256": sha256(builder_path)}
    manifest.update(schema_version=2, distillation_evaluation=queries,
        distillation_evaluation_protocol={
            "purpose": "periodic development model selection using teacher RGB L1; not acceptance",
            "source_fps": 50, "endpoint_delta_seconds": 0.02, "baseline_fps": 50,
            "alphas": list(ALPHAS), "adjacent_pairs": 16, "queries": len(queries),
            "ground_truth_used": False,
        },
        evaluation_usage="12 original 80 ms GT targets: initial/best/last reporting only; not model selection")
    manifest["counts"]["distillation_evaluation_queries"] = len(queries)
    manifest["provenance"]["manifest_builder_source"] = builder
    manifest["input_hashes"][builder["path"]] = builder["sha256"]


def derive_manifest(frozen_path: str | Path, output_path: str | Path) -> dict:
    """Create v2 from a frozen inventory, without opening or rehashing any PNG."""
    frozen_path, output_path = Path(frozen_path).absolute(), Path(output_path).absolute()
    if output_path.exists():
        raise FileExistsError(output_path)
    raw = frozen_path.read_bytes()
    manifest = json.loads(raw)
    frozen = {"path": str(frozen_path), "sha256": hashlib.sha256(raw).hexdigest()}
    manifest["original_png_hashes_verified_at_utc"] = manifest["created_at_utc"]
    manifest["created_at_utc"] = datetime.now(timezone.utc).isoformat()
    manifest["derivation"] = {
        "frozen_manifest": frozen, "original_pngs_reopened": False,
        "original_png_hash_validation": "reused the prior frozen inventory verification; no new image reads",
    }
    manifest["provenance"]["prior_frozen_manifest"] = frozen
    manifest["input_hashes"][frozen["path"]] = frozen["sha256"]
    _add_distillation_evaluation(manifest)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("x") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    return manifest


def _design_cases(design: dict) -> tuple[dict, Path]:
    if design["calibration_clips"] != list(TRAIN_CLIPS):
        raise ValueError("Training is limited to the three fixed old calibration clips")
    if design["diagnostic_clips"] != list(EVALUATION_CLIPS):
        raise ValueError("Evaluation is limited to the two fixed old diagnostic clips")
    if (design["calibration_blocks"] != list(BLOCKS)
            or design["diagnostic_blocks"] != list(BLOCKS)
            or design["alphas"] != list(ALPHAS)):
        raise ValueError("The fixed b0/b2 diagnostic windows and three alphas must be preserved")
    expected = {f"{clip}-b{block}" for clip in TRAIN_CLIPS + EVALUATION_CLIPS
                for block in BLOCKS}
    cases = {case["id"]: case for case in design["cases"]}
    if set(cases) != expected or len(design["cases"]) != len(expected):
        raise ValueError("The design must contain exactly the ten authorized development cases")
    data_root = None
    for case in cases.values():
        clip = case["clip"]
        expected_partition = "calibration" if clip in TRAIN_CLIPS else "diagnostic"
        if (case["partition"] != expected_partition or case["block"] not in BLOCKS
                or case["id"] != f"{clip}-b{case['block']}"):
            raise ValueError("A case crosses the fixed training/evaluation partition")
        frames = [Path(name) for name in case["frames"]]
        if len(frames) != 5:
            raise ValueError("Each diagnostic design window must contain five original frames")
        indices = []
        for frame in frames:
            match = FRAME_NAME.fullmatch(frame.name)
            if not frame.is_absolute() or frame.parent.name != clip or not match or ".." in frame.parts:
                raise ValueError("Frame paths must stay in their named development clip directory")
            if data_root is None:
                data_root = frame.parent.parent
            if frame.parent.parent != data_root:
                raise ValueError("All authorized clips must use the same original data root")
            indices.append(int(match[1]))
        if indices != list(range(indices[0], indices[0] + 5)):
            raise ValueError("A design window is not five consecutive original frame indices")
    return cases, data_root


def _development_source(design: dict, data_root: Path) -> tuple[dict, dict]:
    # The originating run's artifact table binds the data manifest to the same
    # SHA recorded by the feasibility design. No recursive filesystem search.
    run_path = data_root.parent / "manifest.json"
    run = json.loads(run_path.read_text())
    manifest_path = data_root / "manifest.json"
    expected_sha = design["dev_manifest_sha256"]
    linked = [row for row in run["artifacts"]
              if row["path"] == str(manifest_path) and row["sha256"] == expected_sha]
    if len(linked) != 1 or sha256(manifest_path) != expected_sha:
        raise ValueError("The old development manifest does not match its frozen provenance")
    source = json.loads(manifest_path.read_text())
    protocol = source["protocol"]
    allowed = TRAIN_CLIPS + EVALUATION_CLIPS
    if (protocol["clips"] != list(allowed) or protocol["source_fps"] != [50, 1]
            or {row["name"] for row in source["sequences"]} != set(allowed)):
        raise ValueError("Only the five original 50 Hz development clips are authorized")
    for row in source["sequences"]:
        if row["fields"]["F"] != "50:1" or " F50:1 " not in row["header"]:
            raise ValueError(f"Original 50 Hz header provenance is missing for {row['name']}")
    if any(row["sequence"] not in allowed for row in source["frames"]):
        raise ValueError("The source inventory contains a clip outside the development partition")
    return source, {
        "development_manifest": {"path": str(manifest_path), "sha256": expected_sha},
        "originating_run_manifest": {"path": str(run_path), "sha256": sha256(run_path)},
        "development_manifest_binding": "originating_run_manifest.artifacts and design.dev_manifest_sha256",
        "fps_evidence": "development_manifest.protocol.source_fps and sequences[*].fields.F/header",
        "original_source_fps": 50,
        "source_index": source["source_index"],
        "sampling": protocol["sampling"],
        "rgb_quantization": protocol["rgb_quantization"],
        "color": protocol["color"],
    }


def build_manifest(design_path: str | Path, output_path: str | Path) -> dict:
    """Inventory existing original PNGs, verify provenance, and write a new freeze.

    Training uses every available adjacent 20 ms pair in the three training
    directories. Evaluation opens only the four design windows: 48 teacher
    selection queries and the original 12 GT reporting queries share 20 PNGs.
    Existing output files are never overwritten, including by the CLI.
    """
    design_path, output_path = Path(design_path).absolute(), Path(output_path).absolute()
    if output_path.exists():
        raise FileExistsError(output_path)
    design_hash = sha256(design_path)
    design = json.loads(design_path.read_text())
    cases, data_root = _design_cases(design)
    source, provenance = _development_source(design, data_root)
    provenance["design"] = {"path": str(design_path), "sha256": design_hash}
    report_path = design_path.parent / "implementation-report.md"
    if report_path.is_file():
        provenance["feasibility_report"] = {"path": str(report_path), "sha256": sha256(report_path)}
    source_frames = {(row["sequence"], row["index"]): row for row in source["frames"]}
    sequences = {row["name"]: row for row in source["sequences"]}
    geometry = source["protocol"]["frame_geometry"]
    files = {}

    def record(clip: str, path: Path) -> dict:
        if str(path) in files:
            return files[str(path)]
        if path.parent != data_root / clip or path.parent.is_symlink() or path.is_symlink():
            raise ValueError("Source PNGs must be direct files in their authorized clip directory")
        index = int(FRAME_NAME.fullmatch(path.name)[1])
        original = source_frames.get((clip, index))
        if original is None or original["png"] != str(path):
            raise ValueError(f"No original-frame provenance for {path}")
        digest = sha256(path)
        if digest != original["png_sha256"]:
            raise ValueError(f"Original PNG hash changed: {path}")
        if not math.isclose(original["timestamp_seconds"], index / 50, abs_tol=1e-9):
            raise ValueError(f"Original timestamp is inconsistent with 50 Hz: {path}")
        with Image.open(path) as image:
            width, height = image.size
            mode, image_format = image.mode, image.format
        if [width, height] != geometry or image_format != "PNG" or mode != "RGB":
            raise ValueError(f"Original RGB PNG geometry or format changed: {path}")
        row = {
            "path": str(path), "clip": clip, "overlap_group": clip,
            "index": index, "timestamp_seconds": original["timestamp_seconds"],
            "sha256": digest, "bytes": path.stat().st_size,
            "width": width, "height": height, "mode": mode, "source_fps": 50,
            "source_url": sequences[clip]["url"], "raw_sha256": original["raw_sha256"],
        }
        files[str(path)] = row
        return row

    # Verify every design hash before using any window for calibration or GT.
    for case in cases.values():
        for name in case["frames"]:
            frame = record(case["clip"], Path(name))
            if frame["sha256"] != case["frame_sha256"][name]:
                raise ValueError(f"Feasibility design PNG hash changed: {name}")

    inventory, train_pairs = [], []

    for clip in TRAIN_CLIPS + EVALUATION_CLIPS:
        if clip in TRAIN_CLIPS:
            # Listing is limited to these three directories, never the archive.
            paths = sorted((p for p in (data_root / clip).iterdir() if FRAME_NAME.fullmatch(p.name)),
                           key=lambda p: int(FRAME_NAME.fullmatch(p.name)[1]))
            frames = [record(clip, path) for path in paths]
        else:
            names = {name for case in cases.values() if case["clip"] == clip for name in case["frames"]}
            frames = sorted((record(clip, Path(name)) for name in names), key=lambda row: row["index"])
        indices = [row["index"] for row in frames]
        gaps = [{"after_index": a, "before_index": b, "missing_indices": b - a - 1}
                for a, b in zip(indices, indices[1:]) if b != a + 1]
        clip_pairs = [_pair(a, b) for a, b in zip(frames, frames[1:]) if b["index"] == a["index"] + 1]
        if clip in TRAIN_CLIPS:
            train_pairs.extend(clip_pairs)
        inventory.append({
            "clip": clip, "overlap_group": clip,
            "partition": "training" if clip in TRAIN_CLIPS else "development_diagnostic",
            "directory": str(data_root / clip),
            "listed_scope": "all available original PNGs" if clip in TRAIN_CLIPS else "only design b0/b2 frames",
            "observed_png_count": len(frames), "indices": indices,
            "gaps": gaps, "adjacent_pairs": len(clip_pairs), "frames": frames,
            "original_source_fps": 50, "source_url": sequences[clip]["url"],
            "original_y4m_header": sequences[clip]["header"],
            "source_frame_count_from_metadata": sequences[clip]["frame_count"],
        })

    train_by_indices = {(p["clip"], p["first_index"], p["second_index"]): p for p in train_pairs}
    calibration_pairs, evaluation = [], []
    for clip in TRAIN_CLIPS:
        for block in BLOCKS:
            case = cases[f"{clip}-b{block}"]
            first, second = [files[name] for name in case["frames"][:2]]
            calibration_pairs.append(train_by_indices[clip, first["index"], second["index"]])
    for clip in EVALUATION_CLIPS:
        for block in BLOCKS:
            case = cases[f"{clip}-b{block}"]
            first, *targets, second = [files[name] for name in case["frames"]]
            for alpha, gt in zip(ALPHAS, targets):
                evaluation.append({**_pair(first, second),
                    "id": f"{case['id']}-a{alpha:g}", "case_id": case["id"],
                    "gt": gt["path"], "gt_index": gt["index"], "gt_sha256": gt["sha256"],
                    "gt_timestamp_seconds": gt["timestamp_seconds"], "alpha": alpha,
                })
    input_hashes = {row["path"]: row["sha256"] for row in provenance.values()
                    if isinstance(row, dict) and "path" in row and "sha256" in row}
    file_hashes = {path: row["sha256"] for path, row in sorted(files.items())}
    input_hashes.update(file_hashes)
    manifest = {
        "schema_version": 1, "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "bounded student-distillation development only; not independent acceptance",
        "source_images_read_only": True, "source_images_copied": False,
        "independent_holdout_accessed": False, "input_hashes_frozen_before_training": True,
        "training_started_by_manifest_builder": False,
        "train_clips": list(TRAIN_CLIPS), "evaluation_clips": list(EVALUATION_CLIPS),
        "overlap_groups": {"training": list(TRAIN_CLIPS), "evaluation": list(EVALUATION_CLIPS)},
        "train_evaluation_overlap_groups": [], "alphas": list(ALPHAS),
        "source_fps": 50, "train_delta_seconds": 0.02, "evaluation_delta_seconds": 0.08,
        "full_source_videos_assumed_available": False,
        "provenance": provenance, "inventory": inventory,
        "train_pairs": train_pairs, "calibration_pairs": calibration_pairs,
        "calibration": {"purpose": "low-rank initialization subset only; not a generalization evaluation",
                        "selection": "first adjacent pair in each training clip's design b0/b2 window",
                        "alphas": list(ALPHAS), "teacher_response_queries": len(calibration_pairs) * len(ALPHAS),
                        "patches_per_layer_per_query": 512},
        "evaluation": evaluation,
        "file_sha256": file_hashes, "input_hashes": input_hashes,
        "counts": {"training_clips": 3, "evaluation_clips": 2,
                   "training_pngs": sum(row["observed_png_count"] for row in inventory[:3]),
                   "evaluation_pngs": sum(row["observed_png_count"] for row in inventory[3:]),
                   "train_pairs": len(train_pairs), "calibration_pairs": len(calibration_pairs),
                   "evaluation_queries": len(evaluation), "hashed_original_pngs": len(files)},
    }
    _add_distillation_evaluation(manifest)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("x") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    return manifest


def load_rgb(path: str | Path):
    """Return a contiguous CPU float32 [1, 3, H, W] tensor in [0, 1]."""
    import numpy as np
    import torch

    torch.set_num_threads(min(4, torch.get_num_threads()))
    with Image.open(path) as image:
        values = np.asarray(image.convert("RGB"), dtype=np.float32) / np.float32(255)
    return torch.from_numpy(values.transpose(2, 0, 1).copy()).unsqueeze(0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--design", type=Path)
    inputs.add_argument("--from-frozen", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = (derive_manifest(args.from_frozen, args.output) if args.from_frozen
                else build_manifest(args.design, args.output))
    print(json.dumps({"output": str(args.output), **manifest["counts"]}))


if __name__ == "__main__":
    main()
