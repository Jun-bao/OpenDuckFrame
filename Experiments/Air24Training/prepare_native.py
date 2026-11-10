"""Add the private four-stage contract to a fresh pinned product-native copy.

IFNetGraph already compiles and executes its header's scale list. No convolution,
warp, IO or mask math is changed here; original five-stage RMW1 remains the control.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare(source, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != "ac6408022eb6bc1a53181f5b2716a9f5ded507c2":
        raise ValueError("expected pinned RifeMetal0.1.8 source")
    changes = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--",
        "Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins", "LICENSE"], text=True)
    if changes:
        raise ValueError("pinned source has changes in the copied scope")
    here = Path(__file__).resolve().parent
    prior = here.parent / "K1Execution/prepare_product_native.py"
    subprocess.run([sys.executable, "-B", str(prior), "--source", str(source), "--output", str(output)],
                   check=True, stdout=subprocess.PIPE, text=True)
    core = output / "Sources/RifeMetalCore"
    store = core / "WeightStore.swift"
    text = store.read_text()
    if text.count("NarrowGraphContract.validate") != 1:
        raise ValueError("expected one private RMW2 contract anchor")
    store.write_text(text.replace("NarrowGraphContract.validate", "FourStageGraphContract.validate"))
    (core / "NarrowGraphContract.swift").unlink()
    shutil.copyfile(here / "native/FourStageGraphContract.swift", core / "FourStageGraphContract.swift")
    cost = output / "Sources/air24-cost"
    cost.mkdir()
    shutil.copyfile(here / "native/cost.swift", cost / "main.swift")
    package = output / "Package.swift"
    text = package.read_text()
    product = '.executable(name: "k1-runtime", targets: ["k1-runtime"])'
    target = '.executableTarget(name: "k1-runtime", dependencies: ["RifeMetal", "RifeMetalCore"])'
    if text.count(product) != 1 or text.count(target) != 1:
        raise ValueError("expected private product harness package anchors")
    text = text.replace(product, product + ',\n .executable(name: "air24-cost", targets: ["air24-cost"])')
    text = text.replace(target, target + ',\n .executableTarget(name: "air24-cost", dependencies: ["RifeMetal", "RifeMetalCore"])')
    package.write_text(text)
    origin_path = output / "source-origin.json"
    prior_origin = json.loads(origin_path.read_text())
    origin = dict(format="odf-air24-native-v1", source_commit=commit,
                  product_preparation=prior_origin, product_preparer_sha256=sha(prior),
                  preparer_sha256=sha(__file__), graph_id="odf-ifnet425-fourstage-acc-v1",
                  stage_scales=[16, 8, 4, 2], mask_update="accumulate", tensors=128,
                  native_math_changes=False, library_only_product_unchanged=True,
                  contract_sha256=sha(core / "FourStageGraphContract.swift"),
                  package_sha256=sha(package), cost_driver_sha256=sha(cost / "main.swift"),
                  generated_source_sha256={str(p.relative_to(output)): sha(p)
                      for p in (output / "Sources").rglob("*") if p.is_file()},
                  note="Only generated RMW2 validator differs from existing private product harness. "
                       "Four stages come from the candidate header. All IO flags must match the control.")
    origin_path.write_text(json.dumps(origin, indent=2) + "\n")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.source, args.output))
