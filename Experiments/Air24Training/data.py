"""Derive midpoint40ms development triplets from the frozen50Hz PNG inventory.

The result is25->50FPS training material, not exact24Hz validation. Images stay
read-only at their existing paths. No independent holdout is discovered/opened.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
import torch

TRAIN = ("park_joy", "crowd_run", "ducks_take_off")
DEVELOPMENT = ("in_to_tree", "old_town_cross")
FROZEN_SHA = "2c4153f12eab22cb0a65e7f1698a01066a52b922b473de56e7fffb93b3099d5e"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def freeze(source, output):
    source, output = Path(source), Path(output)
    if output.exists():
        raise FileExistsError(output)
    if sha(source) != FROZEN_SHA:
        raise ValueError("expected the existing frozen development inventory")
    old = json.loads(source.read_text())
    if (old["train_clips"] != list(TRAIN) or old["evaluation_clips"] != list(DEVELOPMENT)
            or old["source_fps"] != 50 or old["independent_holdout_accessed"]):
        raise ValueError("unexpected development split or cadence")
    groups = {"training": [], "development": []}
    images = {}
    for inventory in old["inventory"]:
        clip = inventory["clip"]
        if clip not in TRAIN + DEVELOPMENT:
            raise ValueError("inventory outside the named development clips")
        frames = {row["index"]: row for row in inventory["frames"]}
        for row in frames.values():
            if row["source_fps"] != 50 or sha(row["path"]) != row["sha256"]:
                raise ValueError("source PNG hash/cadence changed")
            images[row["path"]] = row["sha256"]
        split = "training" if clip in TRAIN else "development"
        for index in sorted(frames):
            if index + 1 not in frames or index + 2 not in frames:
                continue
            a, gt, b = (frames[i] for i in (index, index + 1, index + 2))
            groups[split].append(dict(id=f"{clip}-f{index:04d}-f{index+2:04d}", clip=clip,
                first=a["path"], second=b["path"], gt=gt["path"], alpha=0.5,
                first_index=index, second_index=index+2, gt_index=index+1,
                width=a["width"], height=a["height"], endpoint_seconds=0.04,
                source_fps=50, input_fps=25, output_fps=50))
    if len(groups["training"]) != 36 or len(groups["development"]) != 12 or len(images) != 80:
        raise ValueError("expected36 training/12 development queries from80 frozen PNGs")
    result = dict(format="odf-air24-midpoint-dev-v1", created_utc=datetime.now(timezone.utc).isoformat(),
                  frozen_inventory=str(source), frozen_inventory_sha256=sha(source),
                  source_fps=50, endpoint_seconds=0.04, approximation="25->50, not exact24->48",
                  training_clips=list(TRAIN), development_clips=list(DEVELOPMENT),
                  train_development_overlap=False, holdout_accessed=False,
                  source_images_read_only=True, source_images_copied=False,
                  images=images, **groups)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as handle:
        json.dump(result, handle, indent=2, allow_nan=False)
        handle.write("\n")
    return result


def load_rgb(path):
    with Image.open(path) as image:
        value = np.asarray(image.convert("RGB"), dtype=np.uint8).copy()
    return torch.from_numpy(value).permute(2, 0, 1).unsqueeze(0).float() / 255


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frozen", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    value = freeze(args.frozen, args.output)
    print(json.dumps(dict(training=len(value["training"]), development=len(value["development"]),
                          source_fps=value["source_fps"], approximation=value["approximation"])))
